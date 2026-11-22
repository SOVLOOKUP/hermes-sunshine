#!/usr/bin/env bash
# Fold the per-client limits the control plane hands us into Hermes' own config.
#
# The control plane passes them as container env at start (HERMES_MAX_BITRATE_KBPS,
# HERMES_MAX_FPS, HERMES_FEC_PERCENTAGE). Hermes reads max_bitrate and
# fec_percentage when a stream starts, so writing them here — once, before the
# process launches — is enough and needs no protocol change.
#
# Contract:
#   • unset or empty  → leave the user's value alone (no surprises on upgrade)
#   • out of range    → clamp and say so, never fail the boot
#   • idempotent      → re-running with the same env changes nothing
set -euo pipefail

HERMES_CONFIG="${HERMES_CONFIG:-/config/hermes.conf}"
APPS_JSON="${APPS_JSON:-/config/.config/hermes/apps.json}"

log() { printf 'hermes-apply-profile: %s\n' "$*"; }
warn() { printf 'hermes-apply-profile: warning: %s\n' "$*" >&2; }

is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Same merge semantics as the entrypoint's helper: rewrite in place when the key
# exists, append when it does not.
set_conf_key() {
    local key="$1" val="$2" current
    current="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)/\1/p" "${HERMES_CONFIG}" 2>/dev/null | head -n1)"
    current="$(printf '%s' "${current}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "${current}" ]; then
        [ "${current}" = "${val}" ] && return 0
        sed -i -E "s/^[[:space:]]*${key}[[:space:]]*=.*/${key} = ${val}/" "${HERMES_CONFIG}"
        log "config: ${key} ${current} -> ${val}"
    else
        printf '%s = %s\n' "${key}" "${val}" >>"${HERMES_CONFIG}"
        log "config: ${key} = ${val}"
    fi
    changed=1
}

mkdir -p "$(dirname "${HERMES_CONFIG}")"
[ -f "${HERMES_CONFIG}" ] || : >"${HERMES_CONFIG}"

changed=0   # something in hermes.conf / apps.json actually changed
saw_limit=0 # the control plane sent at least one usable limit

# --- bitrate ceiling ---------------------------------------------------------
if [ -n "${HERMES_MAX_BITRATE_KBPS:-}" ]; then
    if is_uint "${HERMES_MAX_BITRATE_KBPS}"; then
        bitrate="${HERMES_MAX_BITRATE_KBPS}"
        # Hermes' own floor is 1000 kbps; below that it refuses the value.
        if [ "${bitrate}" -lt 1000 ]; then
            warn "HERMES_MAX_BITRATE_KBPS=${bitrate} is below the host floor, using 1000"
            bitrate=1000
        fi
        if [ "${bitrate}" -gt 1000000 ]; then
            warn "HERMES_MAX_BITRATE_KBPS=${bitrate} is implausible, clamping to 1000000"
            bitrate=1000000
        fi
        set_conf_key max_bitrate "${bitrate}"
        saw_limit=1
    else
        warn "ignoring non-numeric HERMES_MAX_BITRATE_KBPS=${HERMES_MAX_BITRATE_KBPS}"
    fi
fi

# --- FEC ---------------------------------------------------------------------
# The host-side adaptive controller owns this value while it runs; a fixed value
# from a profile is the operator's explicit override and wins.
if [ -n "${HERMES_FEC_PERCENTAGE:-}" ]; then
    if is_uint "${HERMES_FEC_PERCENTAGE}" && [ "${HERMES_FEC_PERCENTAGE}" -ge 1 ] && [ "${HERMES_FEC_PERCENTAGE}" -le 50 ]; then
        set_conf_key fec_percentage "${HERMES_FEC_PERCENTAGE}"
        saw_limit=1
    else
        warn "ignoring HERMES_FEC_PERCENTAGE=${HERMES_FEC_PERCENTAGE} (expected 1-50)"
    fi
fi

# --- frame-rate ceiling ------------------------------------------------------
# Hermes has no fps config key: the ceiling is applied per app through the
# runtime frame limiters the games already honour, exactly like Hermes' own
# per-app limit-fps switch.
if [ -n "${HERMES_MAX_FPS:-}" ] && ! { is_uint "${HERMES_MAX_FPS}" && [ "${HERMES_MAX_FPS}" -ge 1 ]; }; then
    warn "ignoring HERMES_MAX_FPS=${HERMES_MAX_FPS} (expected a positive integer)"
elif [ -n "${HERMES_MAX_FPS:-}" ]; then
    saw_limit=1
    if command -v jq >/dev/null 2>&1 && [ -f "${APPS_JSON}" ]; then
        tmp="$(mktemp)"
        if jq --arg fps "${HERMES_MAX_FPS}" '
            def drop($prefix): map(select(startswith($prefix) | not));
            # Merge into the app'\''s existing MANGOHUD_CONFIG instead of
            # replacing it: users put real settings there (position, gpu_temp,
            # no_display ...) and a blind overwrite silently drops them.
            def set_mangohud($fps):
                ([.[] | select(startswith("MANGOHUD_CONFIG=")) | sub("^MANGOHUD_CONFIG="; "")] | join(",")) as $cur
                | ($cur | split(",") | map(select(length > 0 and (startswith("fps_limit=") | not)))) as $keys
                | (map(select(startswith("MANGOHUD_CONFIG=") | not))
                   + ["MANGOHUD_CONFIG=" + (($keys + ["fps_limit=" + $fps]) | join(","))]);
            .apps |= map(
                if (.env | type) == "array" then
                    .env |= (drop("DXVK_FRAME_RATE=")
                             | drop("VKD3D_FRAME_RATE=")
                             | set_mangohud($fps)
                             | . + ["DXVK_FRAME_RATE=" + $fps, "VKD3D_FRAME_RATE=" + $fps])
                else . end)
        ' "${APPS_JSON}" >"${tmp}" 2>/dev/null; then
            if ! cmp -s "${tmp}" "${APPS_JSON}"; then
                cat "${tmp}" >"${APPS_JSON}"
                log "apps: fps ceiling ${HERMES_MAX_FPS} applied to every app"
                changed=1
            fi
        else
            warn "could not rewrite ${APPS_JSON} for the fps ceiling"
        fi
        rm -f "${tmp}"
    else
        warn "jq or ${APPS_JSON} missing; fps ceiling ${HERMES_MAX_FPS} not applied"
    fi
fi

if [ "${saw_limit}" -eq 0 ]; then
    log "no usable per-client limits in the environment; config untouched"
elif [ "${changed}" -eq 0 ]; then
    log "per-client limits already in effect; nothing to change"
fi
