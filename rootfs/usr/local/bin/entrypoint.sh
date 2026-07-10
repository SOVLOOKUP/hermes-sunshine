#!/usr/bin/env bash
# Entrypoint for the Hermes (Sunshine-compatible) streaming host.
# Brings up a headless Wayland session (sway) + audio, then launches hermes.
set -euo pipefail

log()  { printf '\033[0;36m[hermes]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[hermes][warn]\033[0m %s\n' "$*" >&2; }

HERMES_CONFIG="${HERMES_CONFIG:-/config/sunshine.conf}"
SWAY_TEMPLATE="/etc/sway/config"
SWAY_CONFIG="/run/hermes/sway.config"
PIDS=()

cleanup() {
    log "shutting down..."
    for pid in "${PIDS[@]:-}"; do
        [ -n "${pid}" ] && kill "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# --- timezone ---------------------------------------------------------------
# Precedence: an explicit TZ wins; otherwise inherit whatever /etc/localtime the
# host bind-mounted (it reflects the user's location). glibc reads the TZ env
# var directly, so exporting it is what actually matters; rewriting the files is
# best-effort since they may be read-only bind mounts.
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    export TZ
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
    echo "${TZ}" > /etc/timezone 2>/dev/null || true
    log "timezone: ${TZ} (explicit)"
elif [ -n "${TZ:-}" ]; then
    warn "TZ='${TZ}' is not a known zone (missing /usr/share/zoneinfo/${TZ}); ignoring"
elif [ -e /etc/localtime ]; then
    log "timezone: inherited from host /etc/localtime"
else
    log "timezone: UTC (default; set TZ or mount /etc/localtime to change)"
fi

# --- base directories -------------------------------------------------------
mkdir -p /config /config/sway.d /run/hermes "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

# --- system dbus (needed by avahi) -----------------------------------------
start_dbus() {
    dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || true
    mkdir -p /run/dbus
    if [ ! -S /run/dbus/system_bus_socket ]; then
        dbus-daemon --system --fork 2>/dev/null \
            && log "dbus system bus started" \
            || warn "dbus failed to start"
    fi
}

# --- mDNS discovery (Moonlight auto-discovery) ------------------------------
start_avahi() {
    avahi-daemon --no-chroot -D 2>/dev/null \
        && log "avahi-daemon started" \
        || warn "avahi-daemon failed to start (discovery via manual IP still works)"
}

# --- device detection: Hermes-KMS virtual display + real render GPU ---------
HERMES_KMS_CARD=""   # DRM card node backed by the host hermes_kms.ko module
RENDER_NODE=""       # real GPU render node used for rendering + encoding

drm_driver() {
    # Print the kernel driver name for a /dev/dri/<node> (card* or renderD*).
    basename "$(readlink -f "/sys/class/drm/$(basename "$1")/device/driver" 2>/dev/null)" 2>/dev/null || true
}

detect_devices() {
    local node
    # The virtual display card is the DRM card whose driver is "hermes_kms".
    # The HOST must have loaded hermes_kms.ko (initial_enabled=1) and passed
    # /dev/dri into the container.
    for node in /dev/dri/card[0-9]*; do
        [ -e "${node}" ] || continue
        if [ "$(drm_driver "${node}")" = "hermes_kms" ]; then
            HERMES_KMS_CARD="${node}"
            break
        fi
    done

    # Real render node for GPU rendering + hardware encoding: the first
    # renderD* that is NOT provided by hermes_kms (which is not a render GPU).
    for node in /dev/dri/renderD*; do
        [ -e "${node}" ] || continue
        [ "$(drm_driver "${node}")" = "hermes_kms" ] && continue
        RENDER_NODE="${node}"
        break
    done

    if [ -n "${HERMES_KMS_CARD}" ]; then
        log "Hermes-KMS virtual display: ${HERMES_KMS_CARD}"
    else
        warn "no hermes_kms DRM card found — is the host module loaded and /dev/dri passed in?"
    fi
    if [ -n "${RENDER_NODE}" ]; then
        log "render/encode GPU node: ${RENDER_NODE}"
    else
        warn "no real render node — GPU rendering/encoding will not work."
    fi
}

# --- Wayland compositor (sway) on the Hermes-KMS output ---------------------
start_compositor() {
    # Build the effective sway config from the template (resolution is applied
    # afterwards via swaymsg, since the output name depends on the backend).
    local xw="xwayland disable"
    [ "${ENABLE_XWAYLAND}" = "true" ] && xw="xwayland enable"
    sed -e "s/__XWAYLAND__/${xw}/g" "${SWAY_TEMPLATE}" > "${SWAY_CONFIG}"

    # Prefer the Hermes-KMS DRM output; fall back to the wlroots headless
    # backend (software output) when the module/device is absent.
    local use_kms="false"
    case "${HERMES_KMS:-auto}" in
        on)  use_kms="true" ;;
        off) use_kms="false" ;;
        *)   [ -n "${HERMES_KMS_CARD}" ] && use_kms="true" ;;
    esac

    # libseat's "builtin" backend opens DRM/input directly as root, so no
    # seatd/logind session is needed inside the container.
    export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-builtin}"
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=sway

    if [ "${use_kms}" = "true" ] && [ -n "${HERMES_KMS_CARD}" ]; then
        log "starting sway on the Hermes-KMS DRM output (${HERMES_KMS_CARD})"
        export WLR_DRM_DEVICES="${HERMES_KMS_CARD}"
        export WLR_RENDERER="${WLR_RENDERER:-gles2}"
        [ -n "${RENDER_NODE}" ] && \
            export WLR_RENDER_DRM_DEVICE="${WLR_RENDER_DRM_DEVICE:-${RENDER_NODE}}"
        unset WLR_BACKEND WLR_HEADLESS_OUTPUTS
        sway -c "${SWAY_CONFIG}" > /var/log/sway.log 2>&1 &
    else
        warn "falling back to the wlroots HEADLESS backend (software virtual display)."
        warn "For the low-latency KMS path, load hermes_kms.ko on the host and pass /dev/dri."
        if [ -n "${RENDER_NODE}" ]; then
            export WLR_RENDERER="${WLR_RENDERER:-gles2}"
        else
            export WLR_RENDERER="${WLR_RENDERER:-pixman}"
        fi
        WLR_BACKEND=headless \
        WLR_LIBINPUT_NO_DEVICES=1 \
        WLR_HEADLESS_OUTPUTS=1 \
            sway -c "${SWAY_CONFIG}" > /var/log/sway.log 2>&1 &
    fi
    PIDS+=("$!")

    # Wait for the Wayland socket to appear.
    local sock=""
    for _ in $(seq 1 40); do
        sock="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n1 || true)"
        [ -n "${sock}" ] && break
        sleep 0.25
    done
    if [ -z "${sock}" ]; then
        warn "sway did not create a Wayland socket; see /var/log/sway.log"
        tail -n 40 /var/log/sway.log >&2 || true
        return 1
    fi
    export WAYLAND_DISPLAY="$(basename "${sock}")"
    export XDG_SESSION_TYPE=wayland
    log "Wayland session up on WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"

    # Apply the requested mode on whatever output the backend created.
    local out
    out="$(swaymsg -t get_outputs 2>/dev/null \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
        | sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -n "${out}" ]; then
        log "compositor output: ${out} -> ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}Hz"
        swaymsg output "${out}" mode "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}Hz" >/dev/null 2>&1 \
            || swaymsg output "${out}" resolution "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}Hz" >/dev/null 2>&1 \
            || warn "could not set mode ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${DISPLAY_REFRESH}Hz on ${out}"
    else
        warn "could not determine the compositor output name (see /var/log/sway.log)"
    fi

    # Surface the XWayland DISPLAY for X11-only apps launched by the host.
    if [ "${ENABLE_XWAYLAND}" = "true" ]; then
        export DISPLAY="${DISPLAY:-:0}"
        log "XWayland enabled (DISPLAY=${DISPLAY}) for X11 application compatibility"
    fi
}

# --- audio ------------------------------------------------------------------
start_pulse() {
    log "starting PulseAudio (system mode) with a virtual sink"
    pulseaudio --system --daemonize=true --disallow-exit=true \
        --exit-idle-time=-1 --log-target=stderr \
        --realtime=false --high-priority=false 2>/dev/null \
        || { warn "PulseAudio failed to start"; return 1; }

    export PULSE_SERVER="${PULSE_SERVER:-unix:/run/pulse/native}"
    for _ in $(seq 1 20); do
        pactl info >/dev/null 2>&1 && break
        sleep 0.3
    done
    if pactl info >/dev/null 2>&1; then
        pactl load-module module-null-sink \
            sink_name=hermes sink_properties=device.description=Hermes-Virtual-Sink \
            >/dev/null 2>&1 || true
        pactl set-default-sink hermes >/dev/null 2>&1 || true
        log "virtual audio sink 'hermes' ready"
    else
        warn "PulseAudio control socket not reachable"
    fi
}

# --- bring up the session ---------------------------------------------------
start_dbus
[ "${START_AVAHI}" = "true" ] && start_avahi || true
if [ "${START_COMPOSITOR}" = "true" ]; then
    detect_devices
    start_compositor || warn "continuing without a Wayland session (capture will fail)"
fi
[ "${START_PULSE}" = "true" ] && { start_pulse || warn "continuing without audio"; }

# --- hardware encode diagnostics (non-fatal) --------------------------------
if [ -d /dev/dri ]; then
    log "GPU nodes: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
    vainfo 2>/dev/null | grep -E 'Driver version|VAProfile' | head -n 5 || \
        warn "VAAPI not usable inside the container (check /dev/dri passthrough and drivers)"
else
    warn "/dev/dri not present — no GPU. Wayland capture/hardware encoding will not work."
fi

log "launching hermes with config: ${HERMES_CONFIG}"
log "web UI will be available at https://<host>:47990"
cd /config
exec /usr/bin/hermes "${HERMES_CONFIG}" "$@"
