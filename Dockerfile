##############################################################################
# Hermes (Sunshine-compatible game streaming host) — Docker image
#
# Base : cachyos/cachyos (official Arch/CachyOS rootfs)
# App  : https://github.com/MrOz59/Hermes  (Apollo/Sunshine derived host)
#
# Instead of compiling from source, this image downloads the prebuilt Arch
# package (hermes-*-x86_64.pkg.tar.zst) published on the Hermes GitHub releases
# and installs it with `pacman -U`, which pulls in all runtime dependencies
# (FFmpeg, boost, VAAPI, ...) from the repos. This keeps the build tiny and fast.
#
# The runtime runs a WAYLAND session (the sway wlroots compositor). The virtual
# monitor is provided by the Hermes-KMS kernel module loaded on the HOST: sway
# drives its DRM output (HERMES-1) and Hermes captures the scanout zero-copy
# from the hermes_kms render node. When that module/device is absent it falls
# back to the wlroots headless (software) backend. XWayland is available for
# X11-only applications.
##############################################################################

ARG BASE_IMAGE=cachyos/cachyos:latest

FROM ${BASE_IMAGE} AS runtime

LABEL org.opencontainers.image.title="hermes-sunshine" \
    org.opencontainers.image.description="Dockerized Sunshine/Hermes game streaming host on CachyOS" \
    org.opencontainers.image.source="https://github.com/MrOz59/Hermes"

ARG HERMES_REPO=MrOz59/Hermes
ARG HERMES_REF=latest
ARG USE_CN_MIRROR=true
ENV LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/tmp/runtime \
    HOME=/config \
    HERMES_KMS=auto \
    DISPLAY_WIDTH=1920 \
    DISPLAY_HEIGHT=1080 \
    DISPLAY_REFRESH=60 \
    START_COMPOSITOR=true \
    START_PIPEWIRE=true \
    START_AVAHI=true \
    ENABLE_XWAYLAND=true

# Configure mirrors for runtime stage, multilib, NoExtract, and disable ALPM sandbox network
RUN set -eu; \
    if [ "${USE_CN_MIRROR}" = "true" ]; then \
        prepend() { f="$1"; shift; [ -f "$f" ] || return 0; t="$(mktemp)"; \
        { for s in "$@"; do echo "Server = $s"; done; cat "$f"; } > "$t" && mv "$t" "$f"; }; \
        prepend /etc/pacman.d/mirrorlist \
            'https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch' \
            'https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch'; \
        prepend /etc/pacman.d/cachyos-mirrorlist \
            'https://mirrors.ustc.edu.cn/cachyos/repo/$arch/$repo' \
            'https://mirrors.tuna.tsinghua.edu.cn/cachyos/repo/$arch/$repo'; \
        prepend /etc/pacman.d/cachyos-v3-mirrorlist \
            'https://mirrors.ustc.edu.cn/cachyos/repo/$arch_v3/$repo' \
            'https://mirrors.tuna.tsinghua.edu.cn/cachyos/repo/$arch_v3/$repo'; \
    fi; \
    sed -i '/^\[options\]/a NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/gtk-doc/* usr/share/help/* usr/share/locale/* !usr/share/locale/locale.alias' /etc/pacman.conf; \
    sed -i '/^\[options\]/a DisableSandboxNetwork' /etc/pacman.conf; \
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

# Install all packages in a single layer with BuildKit cache mounts
# sway (wlroots) is the session compositor. It renders on the real GPU
# (WLR_RENDER_DRM_DEVICE) while scanning out on the Hermes-KMS card, which is the
# only combination that streams smoothly here, and sway >= 1.12 is also what
# drives HDR on the virtual output.
RUN --mount=type=cache,target=/var/cache/pacman,sharing=locked \
    set -eu; \
    pacman -Sy --noconfirm; \
    ref="${HERMES_REF}"; \
    if [ "${ref}" = "latest" ]; then \
        ref="$(curl -fsSLI --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' https://github.com/${HERMES_REPO}/releases/latest | sed 's#.*/tag/##')"; \
    fi; \
    echo "Hermes release tag: ${ref}"; \
    path="$(curl -fsSL --retry 3 --retry-delay 2 "https://github.com/${HERMES_REPO}/releases/expanded_assets/${ref}" | grep -oE "/${HERMES_REPO}/releases/download/[^\"]+x86_64\.pkg\.tar\.zst" | head -n1)"; \
    if [ -z "${path}" ]; then echo 'ERROR: no x86_64 Arch package asset found' >&2; exit 1; fi; \
    echo "Downloading https://github.com${path}"; \
    curl -fL --retry 3 -o /tmp/hermes.pkg.tar.zst "https://github.com${path}"; \
    pacman -U --noconfirm /tmp/hermes.pkg.tar.zst; \
    rm -f /tmp/hermes.pkg.tar.zst; \
    pacman -S --noconfirm --needed \
        curl libva-utils dbus avahi mesa sway seatd xorg-xhost xorg-xwayland xorg-xauth xorg-xdpyinfo \
        wl-clipboard xclip foot wofi jq \
        pipewire pipewire-pulse pipewire-audio wireplumber libpulse tzdata \
        steam gamescope noto-fonts wqy-zenhei \
        vulkan-radeon lib32-vulkan-radeon lib32-mesa \
        vulkan-icd-loader lib32-vulkan-icd-loader lib32-libva-mesa-driver lib32-libpulse; \
    setcap cap_sys_admin+p /usr/bin/hermes || true; \
    setcap cap_sys_admin+ep /usr/bin/sway || true; \
    useradd --system --user-group --home-dir / --shell /usr/bin/nologin --comment Avahi avahi 2>/dev/null || true; \
    useradd --uid 1000 --user-group --create-home --home-dir /home/steam --shell /bin/bash steam; \
    for g in video render audio input seat; do \
        getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" steam || true; \
    done; \
    yes | pacman -Scc; \
    rm -rf /usr/share/man/* /usr/share/doc/* /usr/share/info/* /usr/share/gtk-doc/* /usr/share/help/* 2>/dev/null || true; \
    find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'zh*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr -type f -name '*.a' -delete 2>/dev/null || true; \
    rm -rf /var/lib/pacman/sync/* /var/log/pacman.log /tmp/* /var/tmp/*; \
    if [ -f /usr/bin/wl-copy ]; then mv -f /usr/bin/wl-copy /usr/bin/wl-copy.real; fi; \
    if [ -f /usr/bin/xclip ]; then mv -f /usr/bin/xclip /usr/bin/xclip.real; fi

COPY rootfs/ /
RUN chmod +x /usr/local/bin/* /usr/bin/wl-copy /usr/bin/xclip 2>/dev/null || true

EXPOSE 47984-47990/tcp 48010/tcp 47998-48000/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -kso /dev/null --max-time 4 https://localhost:47990 || exit 1

VOLUME ["/config"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]