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

# Hermes release to install: "latest" (default) or a specific tag such as "v0.4.0".
ARG HERMES_REPO=MrOz59/Hermes
ARG HERMES_REF=latest
# Use fast China mirrors (USTC + Tsinghua) for pacman. Set to "false" when
# building outside China (e.g. GitHub Actions) so the default global CDN is used.
ARG USE_CN_MIRROR=true

ENV LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/tmp/runtime \
    HOME=/config \
    # Virtual display source: "auto" uses the host Hermes-KMS DRM card when
    # present and otherwise falls back to a wlroots headless (software) output.
    # Force with "on" / "off".
    HERMES_KMS=auto \
    # Virtual output geometry
    DISPLAY_WIDTH=1920 \
    DISPLAY_HEIGHT=1080 \
    DISPLAY_REFRESH=60 \
    # Feature toggles handled by the entrypoint
    START_COMPOSITOR=true \
    START_PULSE=true \
    START_AVAHI=true \
    ENABLE_XWAYLAND=true
# TZ is intentionally left unset: with no explicit TZ the entrypoint follows
# /etc/localtime (bind-mount it from the host to inherit the user's timezone).

# Point pacman at China mirrors (USTC primary, Tsinghua secondary) when enabled.
# The original mirrors are kept as fallback. $repo/$arch/$arch_v3 are pacman
# variables and MUST stay literal, hence the single quotes. `prepend` only
# touches files that exist, so it works across CachyOS base image variants.
RUN if [ "${USE_CN_MIRROR}" = "true" ]; then set -eu; \
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
    fi

# Trim the install size: never extract man pages, texinfo, docs, gtk-doc, help
# pages, or app locale (.mo) files for the packages installed below. The
# container runs in C.UTF-8 with no doc/man reader, so these are pure weight.
# (locale.alias is kept for the few libs that read it.)
RUN sed -i '/^\[options\]/a NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/gtk-doc/* usr/share/help/* usr/share/locale/* !usr/share/locale/locale.alias' /etc/pacman.conf

# Download the prebuilt Hermes Arch package from GitHub releases and install it
# with `pacman -U` (which resolves + installs its runtime deps from the repos),
# then add the headless Wayland session stack (sway/wlroots, PulseAudio, dbus,
# avahi, Mesa/VAAPI, XWayland) plus the clipboard tools Hermes shells out to
# (wl-clipboard's wl-copy/wl-paste on Wayland, xclip on X11).
#
# We resolve the release WITHOUT the GitHub REST API (it 403s for unauthenticated
# datacenter IPs). "latest" is resolved via the /releases/latest redirect, and
# the exact asset URL is scraped from the /releases/expanded_assets/<tag> HTML.
RUN pacman -Syu --noconfirm --needed curl \
    && ref="${HERMES_REF}" \
    && if [ "${ref}" = "latest" ]; then \
    ref="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/${HERMES_REPO}/releases/latest | sed 's#.*/tag/##')"; \
    fi \
    && echo "Hermes release tag: ${ref}" \
    && path="$(curl -fsSL "https://github.com/${HERMES_REPO}/releases/expanded_assets/${ref}" | grep -oE "/${HERMES_REPO}/releases/download/[^\"]+x86_64\.pkg\.tar\.zst" | head -n1)" \
    && if [ -z "${path}" ]; then echo 'ERROR: no x86_64 Arch package asset found' >&2; exit 1; fi \
    && echo "Downloading https://github.com${path}" \
    && curl -fL --retry 3 -o /tmp/hermes.pkg.tar.zst "https://github.com${path}" \
    && pacman -U --noconfirm /tmp/hermes.pkg.tar.zst \
    && rm -f /tmp/hermes.pkg.tar.zst \
    && pacman -S --noconfirm --needed \
    libva-utils \
    dbus \
    mesa \
    sway \
    seatd \
    wlr-randr \
    xorg-xwayland \
    wl-clipboard \
    xclip \
    foot \
    jq \
    pulseaudio \
    pulseaudio-alsa \
    tzdata \
    && pacman -Scc --noconfirm \
    && rm -rf /var/lib/pacman/sync/* /var/log/pacman.log /tmp/* /var/tmp/*

# The pulseaudio (system mode) and avahi daemons drop privileges to dedicated
# system users that Arch normally creates via systemd-sysusers — which does not
# run during an image build. Create them here so both daemons can start. root
# joins pulse-access so the entrypoint's pactl can reach the system daemon.
RUN useradd --system --user-group --home-dir /var/run/pulse \
    --shell /usr/bin/nologin --comment PulseAudio pulse 2>/dev/null || true; \
    groupadd --system pulse-access 2>/dev/null || true; \
    usermod -aG audio,pulse-access pulse 2>/dev/null || true; \
    install -d -o pulse -g pulse /var/run/pulse /var/lib/pulse; \
    useradd --system --user-group --home-dir / \
    --shell /usr/bin/nologin --comment Avahi avahi 2>/dev/null || true; \
    usermod -aG pulse-access root 2>/dev/null || true

# KMS/DRM capture path needs CAP_SYS_ADMIN; grant it as a file capability
# (mirrors hermes.install do_setcap). Requires --cap-add=SYS_ADMIN at runtime.
RUN setcap cap_sys_admin+p /usr/bin/hermes || true

# Runtime configs + entrypoint.
COPY rootfs/ /
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/hermes-steam-session

# --- optional: Steam Big Picture variant ------------------------------------
# Published as a parallel image tag (…-steam). When INSTALL_STEAM=true this
# enables the [multilib] repo, installs Steam + gamescope and the 32-bit AMD
# graphics stack, and creates a dedicated non-root "steam" user — Steam refuses
# to run as root and its container runtime (pressure-vessel) misbehaves as root.
# The entrypoint registers "Steam Big Picture" as a per-session Hermes app: when
# a client streams it, Hermes runs the launcher at the client's negotiated
# resolution (toggle with AUTOSTART_STEAM). Declared last so the ARG only
# invalidates this layer and the base image below still shares all cache above.
# The `sed` uncomments the [multilib] block (a no-op if it is already enabled).
ARG INSTALL_STEAM=false
RUN if [ "${INSTALL_STEAM}" = "true" ]; then set -eu; \
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf; \
    pacman -Syu --noconfirm --needed \
    steam \
    gamescope \
    noto-fonts noto-fonts-cjk \
    vulkan-radeon lib32-vulkan-radeon \
    lib32-mesa \
    vulkan-icd-loader lib32-vulkan-icd-loader \
    lib32-libva-mesa-driver \
    lib32-libpulse; \
    useradd --uid 1000 --user-group --create-home --home-dir /home/steam \
    --shell /bin/bash steam; \
    for g in video render audio input pulse-access seat; do \
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" steam || true; \
    done; \
    pacman -Scc --noconfirm; \
    rm -rf /var/lib/pacman/sync/* /var/log/pacman.log /tmp/* /var/tmp/*; \
    fi

# Sunshine/Moonlight ports:
#   47984-47990/tcp : RTSP, control, web UI (47990)
#   48010/tcp       : RTSP
#   47998-48000/udp : video/audio/control
EXPOSE 47984-47990/tcp 48010/tcp 47998-48000/udp

VOLUME ["/config"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
