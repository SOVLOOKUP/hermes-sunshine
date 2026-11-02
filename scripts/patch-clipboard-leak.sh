#!/usr/bin/env bash
# ==============================================================================
# scripts/patch-clipboard-leak.sh
#
# Hotfix patch for running Hermes/Sunshine container:
# Permanently resolves the clipboard file descriptor leak (where wl-copy/xclip
# inherit ENet UDP 47999 socket and lock it in the kernel as a background daemon,
# causing RTSP HANDSHAKE 500 on subsequent stream connections).
#
# Usage:
#   sudo ./scripts/patch-clipboard-leak.sh [CONTAINER_NAME]
# ==============================================================================

set -euo pipefail

CONTAINER_NAME="${1:-sunshine}"

log()  { printf "\033[1;32m[patch]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[patch:warn]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[patch:err]\033[0m %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log "target container: ${CONTAINER_NAME}"

# 1. Kill any rogue host or container clipboard daemons holding sockets
log "step 1: sweeping rogue clipboard daemons on host..."
killall -9 wl-copy wl-paste xclip 2>/dev/null || true

if command -v ss >/dev/null 2>&1; then
    stray_pids="$(ss -ulpn 'sport = :47999' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
    if [ -n "${stray_pids}" ]; then
        warn "found process(es) holding UDP 47999: ${stray_pids}"
        for pid in ${stray_pids}; do
            log "killing pid ${pid}..."
            kill -9 "${pid}" 2>/dev/null || true
        done
    fi
fi

# 2. Check if container is running
if ! docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q "true"; then
    warn "container '${CONTAINER_NAME}' is not running. Patched source tree will take effect upon next image build."
    exit 0
fi

log "step 2: killing rogue clipboard daemons inside container..."
docker exec -u root "${CONTAINER_NAME}" killall -9 wl-copy wl-paste xclip 2>/dev/null || true

# 3. Divert existing real binaries inside container if not already diverted
log "step 3: diverting original binaries inside container..."
docker exec -u root "${CONTAINER_NAME}" bash -c '
    for bin in wl-copy wl-paste xclip; do
        if [ -f "/usr/bin/${bin}" ] && [ ! -f "/usr/bin/${bin}.real" ]; then
            # Verify it is not already our shell wrapper
            if ! head -n 2 "/usr/bin/${bin}" | grep -q "/proc/self/fd"; then
                mv -f "/usr/bin/${bin}" "/usr/bin/${bin}.real"
            fi
        fi
    done
'

# 4. Copy FD-sanitizing wrappers into /usr/bin and /usr/local/bin
log "step 4: installing FD-sanitizing wrappers and updated session scripts..."
docker cp "${ROOT_DIR}/rootfs/usr/bin/wl-copy" "${CONTAINER_NAME}:/usr/bin/wl-copy"
docker cp "${ROOT_DIR}/rootfs/usr/bin/wl-paste" "${CONTAINER_NAME}:/usr/bin/wl-paste"
docker cp "${ROOT_DIR}/rootfs/usr/bin/xclip" "${CONTAINER_NAME}:/usr/bin/xclip"

docker cp "${ROOT_DIR}/rootfs/usr/local/bin/wl-copy" "${CONTAINER_NAME}:/usr/local/bin/wl-copy"
docker cp "${ROOT_DIR}/rootfs/usr/local/bin/wl-paste" "${CONTAINER_NAME}:/usr/local/bin/wl-paste"
docker cp "${ROOT_DIR}/rootfs/usr/local/bin/xclip" "${CONTAINER_NAME}:/usr/local/bin/xclip"

docker cp "${ROOT_DIR}/rootfs/usr/local/bin/hermes-steam-session" "${CONTAINER_NAME}:/usr/local/bin/hermes-steam-session"
docker cp "${ROOT_DIR}/rootfs/usr/local/bin/hermes-focus-watch" "${CONTAINER_NAME}:/usr/local/bin/hermes-focus-watch"
docker cp "${ROOT_DIR}/rootfs/usr/local/bin/entrypoint.sh" "${CONTAINER_NAME}:/usr/local/bin/entrypoint.sh"

docker exec -u root "${CONTAINER_NAME}" chmod +x \
    /usr/bin/wl-copy /usr/bin/wl-paste /usr/bin/xclip \
    /usr/local/bin/wl-copy /usr/local/bin/wl-paste /usr/local/bin/xclip \
    /usr/local/bin/hermes-steam-session /usr/local/bin/hermes-focus-watch \
    /usr/local/bin/entrypoint.sh

# Ensure Hermes-KMS render node is strictly read-only (0644) inside the live container
docker exec -u root "${CONTAINER_NAME}" bash -c '
    for node in /dev/dri/renderD*; do
        [ -e "${node}" ] || continue
        base="${node##*/}"
        drv="$(readlink -f "/sys/class/drm/${base}/device/driver" 2>/dev/null || true)"
        if [ -z "${drv}" ]; then
            drv="$(sed -n "s/^DRIVER=//p" "/sys/class/drm/${base}/device/uevent" 2>/dev/null || true)"
        fi
        if [[ "${drv##*/}" =~ hermes[-_]kms ]]; then
            chmod 0644 "${node}" 2>/dev/null || true
        fi
    done
'

# 5. Final check
log "step 5: verifying UDP 47999 status..."
if command -v ss >/dev/null 2>&1; then
    status="$(ss -ulpn 'sport = :47999' 2>/dev/null || true)"
    if [ -n "${status}" ]; then
        warn "port 47999 is still reported by ss:\n${status}"
    else
        log "SUCCESS: UDP 47999 is completely free and clean!"
    fi
fi

log "all patches successfully applied to running container '${CONTAINER_NAME}'."
