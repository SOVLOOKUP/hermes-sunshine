#!/usr/bin/env bash
#
# build-hermes-kms.sh — one-shot Hermes-KMS host-module manager for the
# hermes-sunshine container.
#
# Why this exists: the container's Hermes speaks a specific Hermes-KMS UAPI
# version, and a mismatching module *partially* works (device detection,
# SET_OUTPUT) while every capture ioctl dies — the stream then fails with
# "Failed to initialize video capture/encoding". Two past failures combined
# here:
#   * a bare `git clone` installs the main branch (0.4.x-dev, UAPI 13), not the
#     release tag the container needs (UAPI 9);
#   * `dkms status`/`modinfo` describe files on disk — the kernel may still be
#     running a stale instance, so nothing but querying the live driver counts
#     as proof.
#
# What it does, in order:
#   1. fetch the requested Hermes-KMS release tag (direct GitHub first, then
#      China mirrors) or reuse an existing source tree;
#   2. IF the running kernel's headers lack <drm/drm_dumb_buffers.h> (trimmed
#      kernels), patch the source: replace drm_mode_size_dumb() with the
#      self-contained dumb_create that upstream's main branch uses — version
#      independent, idempotent, a no-op on stock kernels;
#   3. build + install via DKMS for the RUNNING kernel;
#   4. swap the loaded module (the container is stopped first: sway/hermes
#      hold card1 and keep modprobe -r busy otherwise);
#   5. verify what the kernel is ACTUALLY running via a static hermes-kmsctl
#      (driver version + UAPI version must match expectations);
#   6. start the container again.
#
# Usage:
#   sudo ./build-hermes-kms.sh                 # install v0.3.2 (UAPI 9; pairs with Hermes 0.5.x)
#   sudo ./build-hermes-kms.sh v0.3.2          # explicit tag
#   sudo ./build-hermes-kms.sh verify          # only re-check the RUNNING module
#
# Environment overrides:
#   CONTAINER_NAME=sunshine      container to stop/start around the module swap
#   INITIAL_ENABLED=1            module param at modprobe time (see repo README)
#   EXPECTED_UAPI=9              skip auto-derivation and pin the expectation
#   WORKDIR=/tmp/hermes-kms-build
set -euo pipefail

TAG="${1:-v0.3.2}"
CONTAINER_NAME="${CONTAINER_NAME:-sunshine}"
INITIAL_ENABLED="${INITIAL_ENABLED:-0}"
EXPECTED_UAPI="${EXPECTED_UAPI:-}"
WORKDIR="${WORKDIR:-/tmp/hermes-kms-build}"
REPO=MrOz59/Hermes-KMS

log()  { printf '\033[0;36m[build-hermes-kms]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[build-hermes-kms]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[build-hermes-kms]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"

container_exists() {
    command -v docker >/dev/null 2>&1 \
        && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

# --- verify-only mode --------------------------------------------------------
# Builds kmsctl if a source tree is around, then checks the LIVE module.
verify_running() {
    local kmsctl="$WORKDIR/kmsctl"
    [ -x "$kmsctl" ] || die "no kmsctl at $kmsctl — run a full build first"
    local out uapi ver
    out="$("$kmsctl" version --verbose)" || die "kmsctl could not reach the driver (is the module loaded?)"
    printf '%s\n' "$out"
    uapi="$(sed -n 's/^uapi_version=//p' <<<"$out")"
    ver="$(sed -n 's/^driver_version=//p' <<<"$out")"
    [ -n "$uapi" ] || die "could not parse uapi_version from: $out"

    if [ -n "$EXPECTED_UAPI" ] && [ "$uapi" != "$EXPECTED_UAPI" ]; then
        die "LIVE module reports UAPI $uapi but this container line needs $EXPECTED_UAPI — reload: modprobe -r hermes_kms && modprobe hermes_kms initial_enabled=$INITIAL_ENABLED"
    fi
    if [ -n "$ver" ] && [ "$ver" != "${TAG#v}" ]; then
        warn "LIVE module is $ver, expected ${TAG#v} — the on-disk install may be newer than the loaded instance"
        die "reload the module (modprobe -r hermes_kms && modprobe hermes_kms initial_enabled=$INITIAL_ENABLED) and re-run verify"
    fi
    log "OK: live module driver=$ver UAPI=$uapi matches expectations"
}

if [ "$TAG" = "verify" ]; then
    TAG="${HERMES_KMS_TAG:-v0.3.2}"
    verify_running
    exit 0
fi

case "$TAG" in
    v*) VER="${TAG#v}" ;;
    *)  VER="$TAG"; TAG="v$TAG" ;;
esac

# Expected UAPI per Hermes-KMS line: 0.3.x speaks UAPI 9 (Hermes 0.5.x),
# 0.4.x speaks UAPI 13 (needs a container with Hermes 0.6.0+ — update BOTH).
if [ -z "$EXPECTED_UAPI" ]; then
    case "$VER" in
        0.3.*) EXPECTED_UAPI=9 ;;
        0.4.*) EXPECTED_UAPI=13 ;;
        *)     warn "unknown version line $VER — skipping the UAPI expectation check" ;;
    esac
fi

command -v curl >/dev/null 2>&1 || die "curl required"
command -v gcc  >/dev/null 2>&1 || die "gcc required (static hermes-kmsctl for the verification gate)"
command -v python3 >/dev/null 2>&1 || die "python3 required (source patcher)"
dkms_ok() { command -v dkms >/dev/null 2>&1; }
KVER="$(uname -r)"
KHDR="/lib/modules/$KVER/build/include/drm/drm_dumb_buffers.h"

# --- 1. source tree ----------------------------------------------------------
SRCDIR="$WORKDIR/Hermes-KMS-$VER"
if [ -d "$SRCDIR" ]; then
    log "reusing existing source: $SRCDIR"
else
    mkdir -p "$WORKDIR"
    local_tgz="$WORKDIR/Hermes-KMS-$TAG.tar.gz"
    urls=(
        "https://codeload.github.com/$REPO/tar.gz/refs/tags/$TAG"
        "https://gh-proxy.com/https://codeload.github.com/$REPO/tar.gz/refs/tags/$TAG"
        "https://ghfast.top/https://codeload.github.com/$REPO/tar.gz/refs/tags/$TAG"
        "https://ghproxy.net/https://codeload.github.com/$REPO/tar.gz/refs/tags/$TAG"
    )
    ok=""
    for u in "${urls[@]}"; do
        log "downloading $u"
        if curl -fsSL --max-time 120 -o "$local_tgz" "$u" && tar tzf "$local_tgz" >/dev/null 2>&1; then
            ok=1; break
        fi
        warn "download failed, trying next mirror"
    done
    [ -n "$ok" ] || die "could not download $TAG from any mirror"
    tar xzf "$local_tgz" -C "$WORKDIR"
    [ -d "$SRCDIR" ] || die "tarball did not contain Hermes-KMS-$VER (tag mismatch?)"
fi

# Guard against the classic failure: building something other than the tag we
# think we are building (this is how a main-branch 0.4.0 got installed as "0.3.2").
conf_ver="$(sed -n 's/^PACKAGE_VERSION="\?\([^"]*\)"\?/\1/p' "$SRCDIR/dkms.conf")"
[ "$conf_ver" = "$VER" ] || die "$SRCDIR/dkms.conf says version '$conf_ver', expected '$VER' — wrong source tree?"

# --- 2. conditional compat patch (trimmed kernels) ---------------------------
log "kernel $KVER: $([ -e "$KHDR" ] && echo 'has' || echo 'lacks') drm/drm_dumb_buffers.h"
python3 - "$SRCDIR" "$KHDR" <<'PYEOF'
import re, pathlib, sys

src = pathlib.Path(sys.argv[1]) / 'kernel/hermes-kms/hermes_kms.c'
khdr = pathlib.Path(sys.argv[2])
s = src.read_text()

if khdr.exists():
    print(f'kernel headers have {khdr}: no patch needed')
    sys.exit(0)

if 'drm_mode_size_dumb' not in s:
    print(f'{src}: already patched (no drm_mode_size_dumb reference)')
    sys.exit(0)

# Same approach as upstream main: compute pitch/size without the
# drm_mode_size_dumb() helper (a 7.x-era kernel API missing on trimmed
# kernels). Semantically identical to the 0.3.x original: pitch aligned to
# HERMES_KMS_PITCH_ALIGN, backing height padded to
# HERMES_KMS_IMPORT_HEIGHT_ALIGN rows, size page aligned.
new_func = '''static int hermes_kms_dumb_create(struct drm_file *file,
\t\t\t\t  struct drm_device *drm,
\t\t\t\t  struct drm_mode_create_dumb *args)
{
\tstruct drm_gem_shmem_object *shmem;
\tu64 line_bits, pitch, padded_size;
\tint ret;

\tif (args->flags || !args->width || !args->height || !args->bpp)
\t\treturn -EINVAL;
\tif (check_mul_overflow((u64)args->width, (u64)args->bpp, &line_bits))
\t\treturn -EOVERFLOW;
\tpitch = DIV_ROUND_UP_ULL(line_bits, 8);
\tif (check_add_overflow(pitch, (u64)HERMES_KMS_PITCH_ALIGN - 1, &pitch))
\t\treturn -EOVERFLOW;
\tpitch = round_down(pitch, (u64)HERMES_KMS_PITCH_ALIGN);
\tif (!pitch || pitch > U32_MAX)
\t\treturn -E2BIG;
\targs->pitch = pitch;

\tpadded_size = (u64)args->pitch *
\t\t\t      ALIGN(args->height, HERMES_KMS_IMPORT_HEIGHT_ALIGN);
\targs->size = ALIGN(padded_size, PAGE_SIZE);

\tshmem = drm_gem_shmem_create(drm, args->size);
\tif (IS_ERR(shmem))
\t\treturn PTR_ERR(shmem);

\tret = drm_gem_handle_create(file, &shmem->base, &args->handle);
\tdrm_gem_object_put(&shmem->base);
\treturn ret;
}
'''

s = s.replace('#include <drm/drm_dumb_buffers.h>\n', '')
pat = re.compile(r'static int hermes_kms_dumb_create\(.*?\n}\n', re.S)
if not pat.search(s):
    sys.exit(f'FATAL: hermes_kms_dumb_create not found in {src}')
src.write_text(pat.sub(lambda m: new_func, s, count=1))
print(f'patched {src} (trimmed-kernel compat: self-contained dumb_create)')
PYEOF

# --- 3. DKMS build + install for the running kernel --------------------------
# Plain `dkms remove --all` also deletes /usr/src/hermes-kms-$VER, so always
# (re)copy the source; `dkms add` after rm is then always fresh.
log "installing hermes-kms/$VER for kernel $KVER"
dkms remove -m hermes-kms -v "$VER" --all >/dev/null 2>&1 || true
rm -rf "/usr/src/hermes-kms-$VER"
mkdir -p "/usr/src/hermes-kms-$VER"
cp -a "$SRCDIR/." "/usr/src/hermes-kms-$VER/"
dkms add -m hermes-kms -v "$VER"
dkms build -m hermes-kms -v "$VER" -k "$KVER"
dkms install -m hermes-kms -v "$VER" -k "$KVER"
depmod -a

# --- 4. swap the loaded module ------------------------------------------------
if container_exists && [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
    log "stopping container $CONTAINER_NAME (it holds card1; modprobe -r fails otherwise)"
    docker stop "$CONTAINER_NAME" >/dev/null
    STOPPED=1
else
    STOPPED=0
fi

if lsmod | grep -q '^hermes_kms\b'; then
    modprobe -r hermes_kms || die "modprobe -r failed: something besides $CONTAINER_NAME holds the module (lsof /dev/dri/*)"
fi
modprobe hermes_kms "initial_enabled=$INITIAL_ENABLED"
log "module reloaded"

# --- 5. verification gate: query the LIVE driver ------------------------------
log "building static hermes-kmsctl for verification"
gcc -static -O2 -I"$SRCDIR/include/uapi" \
    "$SRCDIR/tools/hermes-kmsctl/hermes_kmsctl.c" -o "$WORKDIR/kmsctl"

out="$( "$WORKDIR/kmsctl" version --verbose )" || die "kmsctl cannot reach the driver — module load failed? (dmesg | grep hermes)"
printf '%s\n' "$out"
uapi="$(sed -n 's/^uapi_version=//p' <<<"$out")"
ver="$(sed -n 's/^driver_version=//p' <<<"$out")"
[ "$ver" = "$VER" ] || die "LIVE module is $ver, not $VER — a stale .ko is still loaded; reboot and re-run verify"
if [ -n "$EXPECTED_UAPI" ] && [ "$uapi" != "$EXPECTED_UAPI" ]; then
    die "LIVE module reports UAPI $uapi, expected $EXPECTED_UAPI"
fi
log "OK: live module driver=$ver UAPI=$uapi"

# --- 6. container back up ------------------------------------------------------
if [ "$STOPPED" = 1 ]; then
    log "starting container $CONTAINER_NAME"
    docker start "$CONTAINER_NAME" >/dev/null
    log "container entrypoint re-detects card1 and restores virtual_display_backend = hermes_kms"
fi

log "done — verify any time with: sudo $WORKDIR/kmsctl version --verbose"
