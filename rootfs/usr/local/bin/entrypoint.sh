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
    # Prefer the bound-driver symlink, then fall back to the uevent DRIVER=
    # line — virtual DRM devices don't always expose the driver symlink.
    local base sys drv
    base="$(basename "$1")"
    sys="/sys/class/drm/${base}/device"
    drv="$(readlink -f "${sys}/driver" 2>/dev/null || true)"
    drv="${drv##*/}"
    if [ -z "${drv}" ]; then
        drv="$(sed -n 's/^DRIVER=//p' "${sys}/uevent" 2>/dev/null | head -n1 || true)"
    fi
    printf '%s' "${drv}"
}

is_hermes_kms() {
    # The DRM driver reports "hermes-kms" (hyphen) while the platform driver may
    # use "hermes_kms" (underscore); match either, case-insensitively.
    case "$(printf '%s' "${1:-}" | tr 'A-Z-' 'a-z_')" in
        *hermes_kms*) return 0 ;;
        *)            return 1 ;;
    esac
}

detect_devices() {
    local node drv
    # The virtual display card is the DRM card driven by the host hermes_kms.ko
    # module (loaded with initial_enabled=1 and exposed via /dev/dri).
    for node in /dev/dri/card[0-9]*; do
        [ -e "${node}" ] || continue
        drv="$(drm_driver "${node}")"
        log "DRM ${node}: driver=${drv:-unknown}"
        if [ -z "${HERMES_KMS_CARD}" ] && is_hermes_kms "${drv}"; then
            HERMES_KMS_CARD="${node}"
        fi
    done

    # Real render node for GPU rendering + hardware encoding: the first
    # renderD* that is NOT provided by hermes_kms (which is not a render GPU).
    for node in /dev/dri/renderD*; do
        [ -e "${node}" ] || continue
        is_hermes_kms "$(drm_driver "${node}")" && continue
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

# --- seat management (needed by the DRM backend to open the GPU/KMS) --------
start_seat() {
    # wlroots' DRM backend needs a libseat session. This libseat build has no
    # "builtin" backend, so run seatd (works as root, no logind needed) and let
    # libseat talk to it over /run/seatd.sock.
    #
    # SEATD_VTBOUND=0 makes seatd create a seat that is NOT tied to a virtual
    # terminal. A container has no VT (/dev/tty0), so the default VT-bound seat
    # can never be activated — seatd logs "Could not open tty0" and the session
    # stays inactive, making wlroots time out ("waiting session to become
    # active"). A VT-free seat is activated immediately, so the DRM/KMS path can
    # actually come up inside the container.
    if [ -S /run/seatd.sock ]; then
        return 0
    fi
    SEATD_VTBOUND=0 seatd > /var/log/seatd.log 2>&1 &
    PIDS+=("$!")
    local _
    for _ in $(seq 1 40); do
        [ -S /run/seatd.sock ] && break
        sleep 0.1
    done
    if [ -S /run/seatd.sock ]; then
        log "seatd started"
    else
        warn "seatd did not create /run/seatd.sock; see /var/log/seatd.log"
    fi
}

# --- Wayland compositor (sway): KMS output with headless fallback -----------

# Start sway in the background with the currently exported WLR_* environment and
# wait for it to publish a Wayland socket. On success records the PID, exports
# WAYLAND_DISPLAY and returns 0; otherwise kills the failed instance and returns
# 1. wlroots gives up within ~10s when it cannot bring up a backend (e.g. the
# DRM session never becomes active in a container with no foreground VT), so we
# watch the process while polling — no point waiting once it has exited.
launch_sway() {
    sway -c "${SWAY_CONFIG}" > /var/log/sway.log 2>&1 &
    local pid=$! sock="" _
    for _ in $(seq 1 60); do
        kill -0 "${pid}" 2>/dev/null || break
        sock="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -n1 || true)"
        [ -n "${sock}" ] && break
        sleep 0.25
    done
    if [ -n "${sock}" ] && kill -0 "${pid}" 2>/dev/null; then
        PIDS+=("${pid}")
        export WAYLAND_DISPLAY="$(basename "${sock}")"
        # swaymsg locates sway's IPC socket via SWAYSOCK; sway only exports it to
        # its own children, so publish it here (it appears alongside the Wayland
        # socket) — without it swaymsg cannot query/set outputs.
        for _ in $(seq 1 20); do
            SWAYSOCK="$(find "${XDG_RUNTIME_DIR}" -maxdepth 1 -name 'sway-ipc.*.sock' 2>/dev/null | head -n1 || true)"
            [ -n "${SWAYSOCK}" ] && break
            sleep 0.1
        done
        [ -n "${SWAYSOCK}" ] && export SWAYSOCK
        return 0
    fi
    kill "${pid}" 2>/dev/null || true
    return 1
}

# Environment for the DRM (KMS) backend: drive the Hermes-KMS card, render on the
# real GPU, and open the device through a seatd session.
setup_kms_env() {
    start_seat
    export LIBSEAT_BACKEND=seatd
    export WLR_DRM_DEVICES="${HERMES_KMS_CARD}"
    export WLR_RENDERER="${WLR_RENDERER:-gles2}"
    [ -n "${RENDER_NODE}" ] && \
        export WLR_RENDER_DRM_DEVICE="${WLR_RENDER_DRM_DEVICE:-${RENDER_NODE}}"
    export WLR_LIBINPUT_NO_DEVICES=1
    unset WLR_BACKENDS WLR_HEADLESS_OUTPUTS
}

# Environment for the headless backend: a software/GPU-rendered virtual output
# that needs no seat or session — the reliable path inside a container. NOTE:
# the backend selector is WLR_BACKENDS (plural); the singular form is silently
# ignored, which makes wlroots autodetect DRM and fail for lack of a seat.
setup_headless_env() {
    unset LIBSEAT_BACKEND WLR_DRM_DEVICES
    export WLR_BACKENDS=headless
    export WLR_HEADLESS_OUTPUTS=1
    export WLR_LIBINPUT_NO_DEVICES=1
    if [ -n "${RENDER_NODE}" ]; then
        export WLR_RENDERER=gles2
        export WLR_RENDER_DRM_DEVICE="${WLR_RENDER_DRM_DEVICE:-${RENDER_NODE}}"
    else
        export WLR_RENDERER=pixman
    fi
}

start_compositor() {
    # Build the effective sway config from the template (resolution is applied
    # afterwards via swaymsg, since the output name depends on the backend).
    local xw="xwayland disable"
    [ "${ENABLE_XWAYLAND}" = "true" ] && xw="xwayland enable"
    sed -e "s/__XWAYLAND__/${xw}/g" "${SWAY_TEMPLATE}" > "${SWAY_CONFIG}"

    # Prefer the Hermes-KMS DRM output; fall back to the wlroots headless backend.
    local use_kms="false"
    case "${HERMES_KMS:-auto}" in
        on)  use_kms="true" ;;
        off) use_kms="false" ;;
        *)   [ -n "${HERMES_KMS_CARD}" ] && use_kms="true" ;;
    esac

    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=sway

    local started="false"
    if [ "${use_kms}" = "true" ] && [ -n "${HERMES_KMS_CARD}" ]; then
        log "starting sway on the Hermes-KMS DRM output (${HERMES_KMS_CARD})"
        setup_kms_env
        if launch_sway; then
            started="true"
            log "Wayland session up on the Hermes-KMS output (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
        else
            warn "sway could not start on the Hermes-KMS DRM output; see /var/log/sway.log"
            tail -n 20 /var/log/sway.log >&2 || true
            warn "the container has no active DRM session (a seat cannot be activated"
            warn "without a foreground VT); falling back to the wlroots headless backend."
        fi
    fi

    if [ "${started}" != "true" ]; then
        if [ "${use_kms}" != "true" ]; then
            warn "using the wlroots HEADLESS backend (software virtual display)."
            warn "For the low-latency KMS path, load hermes_kms.ko on the host and pass /dev/dri."
        fi
        setup_headless_env
        if launch_sway; then
            started="true"
            log "Wayland session up on a headless output (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
        fi
    fi

    if [ "${started}" != "true" ]; then
        warn "sway did not create a Wayland socket; see /var/log/sway.log"
        tail -n 40 /var/log/sway.log >&2 || true
        return 1
    fi

    # Apply the requested mode on whatever output the backend created.
    local out
    out="$(swaymsg -t get_outputs 2>/dev/null \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
        | sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -z "${out}" ]; then
        # Some wlroots builds start the headless backend with zero outputs;
        # create one explicitly so there is a surface to capture.
        swaymsg create_output >/dev/null 2>&1 || true
        sleep 0.3
        out="$(swaymsg -t get_outputs 2>/dev/null \
            | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
            | sed -E 's/.*"([^"]+)"$/\1/')"
    fi
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
        --realtime=false --high-priority=false 2>/var/log/pulse.log \
        || { warn "PulseAudio failed to start (see /var/log/pulse.log)"; return 1; }

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
