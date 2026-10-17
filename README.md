# Hermes — Dockerized Sunshine game streaming host

A container image that installs and runs [**Hermes**](https://github.com/MrOz59/Hermes)
— an Apollo/Sunshine-derived, Moonlight-compatible game streaming host — on top of
the official `cachyos/cachyos` (Arch/CachyOS) image.

Rather than compiling from source, the image downloads the prebuilt **Arch
package** (`hermes-*-x86_64.pkg.tar.zst`) from the Hermes GitHub releases and
installs it with `pacman -U`, which pulls in every runtime dependency (FFmpeg,
boost, VAAPI, …) from the repos. The build is therefore tiny and fast.

The image is self-contained: it starts a **Wayland** session (the
[sway](https://swaywm.org/) wlroots compositor), a PipeWire virtual sink, and
mDNS discovery, then launches the host. The virtual monitor comes from the
[**Hermes-KMS**](https://github.com/MrOz59/Hermes-KMS) kernel module loaded on
the **host**: the session compositor drives its DRM output (connector `Virtual-1`) and Hermes captures the
scanout zero-copy from the `hermes_kms` render node straight into the GPU
encoder. You pair and configure everything from the web UI, exactly like stock
Sunshine. Clients: **Moonlight**, **Artemis**, or **Hestia**.

> **Host kernel module required.** The virtual display is created by the
> Hermes-KMS module on the host (see [Virtual display](#virtual-display--hermes-kms)).
> Pass `/dev/dri` through so the container sees both the virtual card and the
> real GPU. If the module is absent the container automatically falls back to a
> wlroots **headless** (software) output — usable for testing, but not the
> low-latency path. XWayland is included for X11-only applications.

## How it compares

The popular ways to run a headless Steam/desktop over **Moonlight** are this
image, **[Wolf](https://github.com/games-on-whales/wolf)** (Games-on-Whales), and
**[steam-headless](https://github.com/Steam-Headless/docker-steam-headless)**.
They aim at different trade-offs:

|                   | **Hermes-Sunshine** (this image)                                                               | **Wolf** (Games-on-Whales)                                   | **steam-headless**                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- |
| Display backend   | **Wayland** (KWin by default, sway fallback) on a real **KMS** virtual card                                      | **Wayland** (custom micro-compositor)                        | **X11** (Xorg virtual output)                                       |
| Capture path      | **Zero-copy** DMA-BUF from the `hermes_kms` scanout into the encoder                           | Raw compositor framebuffer → GStreamer encode                | Sunshine grabs the X11 framebuffer                                  |
| Client resolution | Rendered at the client's **negotiated native** res per session — no upscaling, no dummy plug   | Adaptive per session                                         | Fixed virtual output; adaptive res needs xrandr overlays            |
| Audio             | **PipeWire** virtual sink                                                                      | PulseAudio (embedded / sidecar)                              | PulseAudio                                                          |
| Out of the box    | Boots into **Steam Big Picture** (console-like); desktop fallback                              | Generic app runner — pick/define apps (Steam image incl.)    | Full **Xfce desktop** + NoVNC browser access; launch Steam yourself |
| Concurrency       | Single session                                                                                 | **Multiple** isolated sessions / users                       | Single session                                                      |
| Configuration     | Stock **Sunshine web UI** (pair by PIN)                                                        | TOML file + Wolf UI app                                      | Sunshine web UI + NoVNC                                             |
| Orchestration     | One self-contained container                                                                   | Spawns per-app containers — needs **`/var/run/docker.sock`** | One container                                                       |
| Main dependency   | **Host kernel module** (Hermes-KMS) for the low-latency path; auto software fallback otherwise | No kernel module                                             | No kernel module                                                    |
| Base image        | **CachyOS** (perf-tuned Arch)                                                                  | Ubuntu-based                                                 | Debian + Xfce                                                       |

**Choose this image if** you want a Steam-console experience that streams a
**true KMS scanout, zero-copy** into the GPU encoder at the client's native
resolution, driven from the familiar Sunshine web UI, in a **single container
that never touches your Docker socket**.

**Consider [Wolf](https://github.com/games-on-whales/wolf) instead if** you need
several people streaming different apps at once, or a solution that needs no host
kernel module — at the cost of running per-app containers through the Docker
socket.

**Consider [steam-headless](https://github.com/Steam-Headless/docker-steam-headless)
instead if** you mainly want a full, always-on Linux desktop you can also reach
from a browser (NoVNC) and don't mind X11's resolution quirks.

## Contents

```
Dockerfile                                single-stage build (download + install pkg)
docker-compose.yml                        ready-to-run service definition
rootfs/usr/local/bin/entrypoint.sh        session bring-up + launch
rootfs/usr/local/bin/hermes-steam-session per-session Steam Big Picture launcher
rootfs/etc/sway/config                    Wayland session template
rootfs/etc/wireplumber/wireplumber.conf.d/ disable hardware audio monitors (keep Hermes' loopback sinks)
```

## Requirements

- Docker with the **Linux** engine (native Linux, Docker Desktop, or Docker-in-WSL).
- A real GPU exposed via `/dev/dri` for rendering + hardware encoding (AMD/Intel
  VAAPI, or NVIDIA with the NVIDIA Container Toolkit).
- The [**Hermes-KMS**](https://github.com/MrOz59/Hermes-KMS) kernel module loaded
  on the **host** for the low-latency virtual display (see
  [Virtual display](#virtual-display--hermes-kms)). Without it the container
  falls back to a software headless output.

## Virtual display — Hermes-KMS

The virtual monitor is **not** created inside the container. It is provided by
the [Hermes-KMS](https://github.com/MrOz59/Hermes-KMS) DRM/KMS kernel module,
which must be built and loaded on the **host** (it is an out-of-tree module and
cannot be loaded from a container):

```bash
# On the HOST — automated install (recommended). Fetches the pinned release,
# patches the source if the kernel headers are trimmed (e.g. no
# drm/drm_dumb_buffers.h), builds via DKMS, swaps the loaded module (stopping
# the container first) and verifies the LIVE driver version + UAPI with a
# static hermes-kmsctl:
sudo ./host-module/build-hermes-kms.sh            # installs v0.3.2 (UAPI 9)
sudo ./host-module/build-hermes-kms.sh verify    # re-check the running module any time

# Manual equivalent — IMPORTANT: pin the tag. Each Hermes release speaks one
# Hermes-KMS UAPI line: 0.5.x wants UAPI 9 (Hermes-KMS 0.3.x), 0.6.x wants UAPI
# 13/14 (Hermes-KMS 0.4.0). A mismatching module loads fine but capture ioctls
# fail or degrade, and sessions die with "Failed to initialize video capture/
# encoding" / "no active scanout geometry yet" in the container log.
git clone --branch v0.3.2 --depth 1 https://github.com/MrOz59/Hermes-KMS
cd Hermes-KMS
sudo make dkms-install          # or: make && sudo insmod kernel/hermes-kms/hermes_kms.ko

# Load it enabled so a compositor can adopt the output:
sudo modprobe hermes_kms initial_enabled=0
ls -l /dev/dri                  # a new virtual card + render node appears
```

> **Upgrading the host module?** Each Hermes release expects a specific
> Hermes-KMS UAPI line (Hermes 0.5.x ↔ UAPI 7/8/9, i.e. Hermes-KMS 0.3.x;
> Hermes 0.6.x ↔ UAPI 13/14, i.e. Hermes-KMS 0.4.0). The script above derives the expected
> UAPI from the tag and refuses to pass verification on a mismatch, so the same
> command keeps working for future releases — but the container image must be
> updated to the matching Hermes release in the same step. Never install from
> the default branch; always check out the release tag matching your container
> image, and reload the module (`modprobe -r hermes_kms && modprobe hermes_kms
> initial_enabled=0`) before restarting the container.

### HDR (module 0.4.0 / Hermes 0.6.0)

Hermes-KMS 0.4.0 speaks UAPI 14 and is the first line that can carry HDR: with
`hdr_enable=1` (default off, load-time only) the synthetic EDID grows a CTA-861
extension with HDR Static Metadata + BT2020 Colorimetry blocks and the connector
exposes `HDR_OUTPUT_METADATA` and `Colorspace`; `ACQUIRE_FRAME2` then returns
each frame together with its EOTF, static metadata and full-range flag, which is
what lets Hermes 0.6.0 put 10-bit PQ/BT.2020 HEVC Main10 or AV1 into the stream.
`color_depth=10` is the scanout half of the same switch — the module flags that
pairing as untested, so validate it before deploying.

Two things still gate it:

- the compositor has to drive the output in HDR (upstream validates on KDE/KWin;
  a compositor without an HDR output path keeps the stream SDR regardless of how
  the module is loaded), and
- the module and the container must be the matching pair (0.4.0 ↔ Hermes 0.6.0,
  UAPI 14) — a 0.3.x module has no `hdr_enable` at all and UAPI 9 without the
  colour metadata.

The compositor has to drive HDR for this to reach the stream. That is why KWin is
the default session: sway has no HDR output path, and a nested gamescope cannot
provide one either (the session compositor is the one scanning out to
`Virtual-1`).

The default session is already KWin, so HDR only needs:

- Hermes-KMS **0.4.0** loaded with `hdr_enable=1 color_depth=10` (the module flags
  that pairing as untested — validate it), and
- a Moonlight client that asked for HDR.

Diagnostics land in `/var/log/kwin.log` and `/var/log/kscreen-doctor.log`. The
KWin path is still experimental: it has not been validated end to end inside the
container yet, and `COMPOSITOR=sway` remains the fallback.

To make the module load **automatically on system boot**:

```bash
# Create module auto-load configuration
echo "hermes_kms" | sudo tee /etc/modules-load.d/hermes-kms.conf

# Set default module parameters. Leave the connector disconnected (0 — the
# packaged default): this container hotplugs the virtual output per session
# via headless_mode, and hermes 0.5.1 disconnects unowned enabled outputs at
# startup anyway.
echo "options hermes_kms initial_enabled=0" | sudo tee /etc/modprobe.d/hermes-kms.conf
```

Without this, the module must be reloaded manually after each reboot (`sudo modprobe hermes_kms initial_enabled=0`), otherwise the container will fall back to the slower headless (software) output.

Then pass `/dev/dri` into the container (the compose file already does). The data
flow is:

1. `hermes_kms.ko` on the host exposes a virtual DRM card whose connector is
   named `Virtual-1` (the driver's internal output label is `HERMES-1`), plus a
   render node.
2. **the session compositor** (KWin by default, `COMPOSITOR=sway` for wlroots) takes DRM master on that card and scans the
   desktop out to the `Virtual-1` output; a **real GPU** does the rendering.
3. **Hermes** opens the `hermes_kms` render node (masterless) and pulls the
   scanout as DMA-BUFs, which the real GPU encodes — the frame never leaves the
   GPU.

Set the `HERMES_KMS` variable to `on`/`off`/`auto` (default `auto`) to force or
disable this path.

> **Seat activation in a container.** Driving the DRM output needs an _active_
> seat session, which a VT-bound seat can only get from a foreground virtual
> terminal — absent in a container. The entrypoint therefore starts seatd with
> `SEATD_VTBOUND=0`, creating a VT-free seat that activates immediately, so the
> KMS path works without a `/dev/tty0`.
>
> **Automatic headless fallback.** If sway still fails to bring up a Wayland
> socket on the DRM output (it logs `Timeout waiting session to become active` /
> `Failed to start a DRM session`), the entrypoint automatically retries on the
> wlroots **headless** backend, so a Wayland session always comes up and Hermes
> can capture. Set `HERMES_KMS=off` to skip the KMS attempt and go straight to
> headless.

## Quick start

The compose file pulls the prebuilt image from GHCR — no local build needed:

```bash
# pull + run
docker compose up -d

# follow logs
docker compose logs -f
```

**China users:** for a much faster pull, edit `docker-compose.yml` and switch the
`image:` line to the Nanjing University GHCR mirror:

```yaml
# image: ghcr.io/sovlookup/hermes-sunshine:latest
image: ghcr.nju.edu.cn/sovlookup/hermes-sunshine:latest
```

To build the image yourself instead of pulling it, uncomment the `build:` block
at the bottom of `docker-compose.yml` and run `docker compose up -d --build`.

Then open the web UI and set an admin username/password:

```
https://<host-ip>:47990
```

Pair a Moonlight/Artemis/Hestia client by entering the PIN it shows into
_The PIN page_ of the web UI.

## Build arguments

| Arg             | Default                  | Purpose                                                                                          |
| --------------- | ------------------------ | ------------------------------------------------------------------------------------------------ |
| `BASE_IMAGE`    | `cachyos/cachyos:latest` | Base rootfs.                                                                                     |
| `HERMES_REPO`   | `MrOz59/Hermes`          | GitHub `owner/repo` to pull the release from.                                                    |
| `HERMES_REF`    | `latest`                 | Release to install: `latest` or a specific tag (e.g. `v0.4.0`).                                  |
| `USE_CN_MIRROR` | `true`                   | Use fast China mirrors (USTC + Tsinghua) for pacman. Set to `false` when building outside China. |

> **Mirrors.** `USE_CN_MIRROR` defaults to `true` so local builds in China are
> fast (USTC primary, Tsinghua secondary; the global CDN stays as fallback).
> When building **outside China** — including the bundled **GitHub Actions**
> workflow (`.github/workflows/docker-build.yml`), which runs on GitHub-hosted
> runners abroad — pass `USE_CN_MIRROR=false` to use the default global CDN.

Build manually without compose:

```bash
# In China (default): fast USTC/Tsinghua mirrors, latest Hermes release
docker build -t hermes-sunshine:latest .

# Pin a specific release
docker build -t hermes-sunshine:latest \
  --build-arg HERMES_REF=v0.4.0 .

# Outside China: use the global CDN
docker build -t hermes-sunshine:latest \
  --build-arg USE_CN_MIRROR=false .
```

## Published images & auto-updates

The bundled **GitHub Actions** workflow
([`.github/workflows/docker-build.yml`](.github/workflows/docker-build.yml))
builds and pushes images to **GHCR** (`ghcr.io/sovlookup/hermes-sunshine`):

```bash
docker pull ghcr.io/sovlookup/hermes-sunshine:latest          # newest build
docker pull ghcr.io/sovlookup/hermes-sunshine:hermes-v0.4.0   # pinned to a Hermes release

# China: use the Nanjing University GHCR mirror for a faster pull
docker pull ghcr.nju.edu.cn/sovlookup/hermes-sunshine:latest
```

Each build publishes a single image (tags `latest` and `hermes-<tag>`) that boots
straight into **Steam Big Picture** (see below).

It runs on three triggers:

- **push / pull request** — normal CI for changes to this repo.
- **daily schedule** — follows upstream [Hermes](https://github.com/MrOz59/Hermes)
  releases: it resolves the latest release tag and, only if no image has been
  published for it yet, builds one tagged `hermes-<tag>` and refreshes `latest`.
  So a new Hermes release is picked up automatically within a day, and unchanged
  days are skipped (no needless rebuilds).
- **manual** (`workflow_dispatch`) — build a specific `hermes_ref` on demand, with
  a `force` toggle to rebuild even when the tag already exists.

Each build pins the resolved `HERMES_REF`, so the image content always matches
its `hermes-<tag>` tag. Runners are outside China, so the workflow passes
`USE_CN_MIRROR=false` automatically.

## Steam Big Picture

The image boots straight into **Steam Big Picture** on the streamed display —
plug in a controller and it behaves like a console. It bundles Steam,
[gamescope](https://github.com/ValveSoftware/gamescope), and the 32-bit AMD
graphics stack on top of the headless streaming host.

```bash
docker compose up -d
```

How it works and what to know:

- **Per-session launch (native resolution).** "Steam Big Picture" is registered
  as a Hermes app, not a boot-time autostart. When a client streams it, Hermes
  runs `steam -gamepadui` **directly on the session compositor**, at the stream's
  **negotiated resolution/refresh** (`SUNSHINE_CLIENT_WIDTH`/`HEIGHT`/`FPS` —
  Hermes sizes the `Virtual-1` output to it, so the picture is native, no
  upscaling). Set `STEAM_GAMESCOPE=true` to run it nested inside gamescope
  instead, which adds its own resolution/refresh clamping, FSR and HDR at the
  price of one more compositing layer — and of gamescope's Xwayland, from which
  some native Linux ports cannot get a usable GL drawable (`failed to create
  drawable` in the game log). Either way the session is **relaunched fresh per
  connection** (Steam is not kept warm); set `AUTOSTART_STEAM=false` to leave the
  app unregistered and boot to the plain desktop instead.
- **First run is slower.** Because Steam starts fresh each connection, the very
  first stream re-runs Steam's bootstrap ("Setting up Steam content"). That data
  lives in `/config/steam` (below), so every subsequent connection comes up fast.
- **D-Bus session bus.** Since the 2026-10-16 client build Steam boots through the
  SteamRT3 client: the updater re-execs the client into the Steam Linux Runtime,
  and `steam-runtime-launcher-service` needs a D-Bus *session* bus for that
  hand-off. The container only runs a system bus (for avahi), so the per-session
  launcher starts the session through `dbus-run-session`, with the bus socket in
  the `steam` user's runtime dir. Without it the client exits immediately
  (`Steam exited (rc=125) after 0s` in `/var/log/steam.log`, and
  `Can't find session bus` / `Couldn't start subprocess launcher` in
  `/config/steam/.local/share/Steam/logs/console-linux.txt`) and the stream shows
  only the plain desktop.
- **Big Picture must not minimize itself.** `SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0` is
  exported by the per-session launcher. Without it, Big Picture minimizes the
  moment a game window takes focus; in gamescope mode it then has no focused
  window to show and paints its root window, so the stream falls back to the
  desktop while the game keeps running in the background (its `Gamescope WSI`
  surface stays alive).
  See "Big Picture Mode minimizes itself after losing focus" in the ArchWiki
  Steam/Troubleshooting page.
- **Compositor: KWin by default, sway as fallback.** `COMPOSITOR=kwin` (default)
  starts `kwin_wayland --drm` on the Hermes-KMS card, pinned with
  `KWIN_DRM_DEVICES`, with one shared session D-Bus so KScreen can publish the
  output to Hermes. KWin is the session Hermes' HDR path is validated against
  (see [HDR (module 0.4.0 / Hermes 0.6.0)](#hdr-module-040--hermes-060)) and the
  only one in this image that can drive HDR. It is still experimental: if it does
  not come up, the entrypoint falls back to sway and logs why. Set
  `COMPOSITOR=sway` to run the wlroots session Hermes drives over
  wlr-output-management, and build with `--build-arg WITH_KWIN=false` to drop the
  KDE layer entirely (that image always runs sway). KWin needs
  `cap_add: [SYS_NICE]`: its binary carries that file capability, and `execve`
  refuses to run it when the capability is outside the container's bounding set
  ("Operation not permitted"), which surfaces as a KWin→sway fallback. Two more
  KWin-specific quirks are handled automatically: the session runs with
  `KWIN_DRM_NO_AMS=1` (KWin's atomic commit state machine sends a TEST_ONLY
  commit with mode properties but without `ALLOW_MODESET`, which this driver's
  kernel rejects with `Modeset failed: Invalid argument` in a loop — the legacy
  `drmModeSetCrtc` path works), the Xwayland auth cookie is copied to
  `/tmp/.hermes-xauthority` and exported as `XAUTHORITY`. The cookie alone is not
  enough: the X server trusts local connections running as its own uid (root), so
  the unprivileged `steam` user is refused even with a byte-identical cookie --
  the container therefore runs `xhost +SI:localuser:steam` once Xwayland is up
  (falling back to `xhost +local:`), otherwise Steam dies with "unable to open a
  connection to X".

  Two performance/HDR limits are inherent to the virtual card and worth knowing
  before debugging them:

  * Hermes-KMS has no render engine, so KWin composites with llvmpipe unless it
    is handed a real GPU (`KWIN_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1`). That
    makes KWin render on the amdgpu card, but its cross-GPU path then cannot get
    the frame onto `Virtual-1` — Hermes reports "did not commit the requested SDR
    scanout before capture". sway does support the split
    (`WLR_DRM_DEVICES=card1` + `WLR_RENDER_DRM_DEVICE=renderD128`) and streams
    smoothly, but sway/wlroots does not set the HDR colours on the connector.
  * HDR therefore needs KWin (KScreen + KWin's HDR output) and pays the llvmpipe
    price: usable around 1080p60, not at 4K. The module must be loaded with
    `hdr_enable=1 color_depth=10`; Hermes then reports "Display is HDR: true"
    instead of "streaming SDR".
- **Non-root `steam` user.** Steam refuses to run as root (its `pressure-vessel`
  container runtime misbehaves and pollutes config ownership), so it runs as a
  dedicated `steam` user (uid 1000). sway and Hermes stay root; only the Wayland
  and PipeWire (pulse-compatible) sockets are shared across to the `steam` user.
- **Persistent library.** Steam's data (client bootstrap, login, installed games,
  config) lives in `/config/steam`, so it survives container recreation. Games
  can be large — make sure the `/config` volume has room, or bind-mount a bigger
  disk there.
- **Controllers.** Gamepad input arrives through the virtual `/dev/uinput` device
  (already mapped in the compose file) exactly like the streaming input path.

> **Host prerequisite: user namespaces.** Steam's container runtime
> (`pressure-vessel` / `bubblewrap`) creates a nested user + mount namespace and
> recursively remounts `/` (`mount --make-rslave /`) inside it. Two host
> conditions must hold:
>
> 1. **User namespaces enabled** — check with
>    `cat /proc/sys/user/max_user_namespaces` (must be non-zero; it is on modern
>    kernels). On Ubuntu 24.04+ also ensure
>    `sysctl kernel.apparmor_restrict_unprivileged_userns=0`.
> 2. **The recursive remount must be allowed** — a default container locks its
>    masked/read-only system paths (`/proc/kcore`, `/sys/firmware`, …) so the
>    recursive `--make-rslave` fails on them even with `SYS_ADMIN`. The compose
>    file therefore sets `security_opt: systempaths=unconfined` (drops those
>    locked mounts) and `apparmor:unconfined` (Docker's default AppArmor profile
>    denies the same mounts on hosts where AppArmor is loaded).
>
> Without these, Steam exits immediately (`rc=71`) logging `Steam now requires
user namespaces to be enabled` and `bwrap: Failed to make / slave: Permission
denied`.

> **AMD-only graphics stack.** The bundled 32-bit drivers are `vulkan-radeon` /
> `lib32-mesa` (AMD/Intel VAAPI + RADV). NVIDIA users need the NVIDIA Container
> Toolkit and the matching 32-bit NVIDIA libraries, which are not baked in.

## Runtime environment variables

| Variable           | Default                 | Description                                                                                                                                                                     |
| ------------------ | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TZ`               | _(host)_                | Timezone. Unset by default: the container follows the bind-mounted host `/etc/localtime`. Set e.g. `Asia/Shanghai` to override.                                                 |
| `HERMES_KMS`       | `auto`                  | Virtual display source: `auto`/`on`/`off` (host Hermes-KMS card vs. headless fallback).                                                                                         |
| `DISPLAY_WIDTH`    | `1920`                  | Virtual output width.                                                                                                                                                           |
| `DISPLAY_HEIGHT`   | `1080`                  | Virtual output height.                                                                                                                                                          |
| `DISPLAY_REFRESH`  | `60`                    | Virtual output refresh rate (Hz).                                                                                                                                               |
| `START_COMPOSITOR` | `true`                  | Start the Wayland session (KWin by default, see `COMPOSITOR`).                                                                                                                                               |
| `START_PIPEWIRE`   | `true`                  | Start PipeWire (+ WirePlumber + pipewire-pulse) for audio capture. Hermes creates and captures its own loopback sink.                                                           |
| `START_AVAHI`      | `true`                  | Start avahi-daemon for Moonlight auto-discovery.                                                                                                                                |
| `ENABLE_XWAYLAND`  | `true`                  | Run XWayland for X11-only applications.                                                                                                                                         |
| `AUTOSTART_STEAM`  | `true`                  | Register Steam Big Picture as a per-session app (launched at the client's resolution when streamed). Set `false` to leave it unregistered and stream the plain desktop instead. |
| `COMPOSITOR`       | `kwin`                  | Session compositor: `kwin` (`kwin_wayland --drm`, the HDR-capable default) or `sway` (wlroots fallback). Images built with `WITH_KWIN=false` have no KWin and always run sway. |
| `STEAM_GAMESCOPE`  | `false`                 | Run Steam nested inside gamescope (`true`) or directly on the sway session (`false`, the compatible default). See [Steam Big Picture](#steam-big-picture).                       |
| `WLR_RENDERER`     | auto                    | wlroots renderer (`gles2` with GPU, else `pixman`).                                                                                                                             |
| `HERMES_CONFIG`    | `/config/hermes.conf`   | Config file path (state is stored beside it).                                                                                                                                   |

The virtual output resolution is set at runtime from `DISPLAY_WIDTH`/`HEIGHT`/
`REFRESH`. Drop extra sway snippets into `./config/sway.d/*.conf` on the host to
customise the session (they are `include`d by the generated config).

On a fresh `/config` volume the entrypoint seeds `hermes.conf` with sensible
defaults (`address_family = both`, `upnp = enabled`,
`virtual_display_backend = hermes_kms`) before starting Hermes. Volumes created
by older image versions are migrated in place (`/config/sunshine.conf` →
`/config/hermes.conf`, legacy `apps.json` copied into
`/config/.config/hermes/`). The entrypoint only seeds when a key is absent, so
edits you make in the web UI (which Hermes writes back to the same file) are
never overwritten.

## Ports

| Port(s)         | Proto | Purpose                               |
| --------------- | ----- | ------------------------------------- |
| `47984`–`47990` | TCP   | HTTPS/RTSP/control + web UI (`47990`) |
| `48010`         | TCP   | RTSP                                  |
| `47998`–`48000` | UDP   | Video / audio / control               |

Host networking (`network_mode: host`) is the most reliable option for client
auto-discovery; the explicit port mappings in the compose file are the fallback
when host networking is unavailable.

## Devices, capabilities & data

- `--device /dev/dri` — exposes both the host **Hermes-KMS virtual card** (which
  sway drives) and the **real GPU render node** (rendering + VAAPI/NVENC encode).
- `--device /dev/uinput` — virtual gamepad/keyboard/mouse injection.
- `--cap-add SYS_ADMIN` — required for KMS/DRM capture and `uinput`.
- `-v ./config:/config` — persists the config, paired clients, and app list.

## Encoding backends

- **AMD / Intel (VAAPI):** map `/dev/dri`; the image ships `mesa` (which bundles
  the Gallium VAAPI driver for AMD/radeonsi). Run `docker exec hermes vainfo` to
  confirm the encoder is visible. For Intel iHD, also install `intel-media-driver`.
  In the web UI, VAAPI is auto-selected. Hermes-KMS is validated with VAAPI /
  `XRGB8888` today.
- **NVIDIA (NVENC):** install the NVIDIA Container Toolkit and enable the
  `nvidia` runtime block in `docker-compose.yml`. NVENC availability depends on
  whether the prebuilt Hermes package was compiled with CUDA support upstream;
  Hermes-KMS's NVENC/AMF path is not yet validated upstream.

## Notes & limitations

- **Virtual display = host kernel module.** The low-latency path relies on the
  [Hermes-KMS](https://github.com/MrOz59/Hermes-KMS) DRM/KMS module, which is
  out-of-tree and must be built + loaded on the **host** (`modprobe hermes_kms
initial_enabled=0`); it cannot be loaded from inside a container. sway (in the
  container) drives its `Virtual-1` output and Hermes captures the scanout
  zero-copy from the `hermes_kms` render node. See
  [Virtual display](#virtual-display--hermes-kms).
- **Headless fallback.** If no `hermes_kms` card is present, `HERMES_KMS=off`, or
  the KMS DRM session still fails to come up, the entrypoint starts sway with the
  wlroots **headless** backend so the web UI and pairing still work. This
  software path is fine for testing but is not the intended low-latency path.
- **Real GPU still needed.** Hermes-KMS is not a render GPU — rendering and
  encoding run on a real GPU that imports the exported DMA-BUFs, so `/dev/dri`
  must be passed through.
- **EVDI warning is harmless.** EVDI is a _separate_ virtual-display backend
  (DisplayLink-derived) that Hermes probes at startup. This image uses the
  Hermes-KMS path instead, so the "EVDI userspace library is missing" notice in
  the UI is expected and can be ignored. The `evdi` package is AUR-only and its
  kernel module would have to be loaded on the host in place of `hermes_kms`, so
  it is intentionally not bundled. Clipboard sync, however, works out of the box
  (`wl-clipboard` + `xclip` are preinstalled).
- **Root & SYS_ADMIN.** The container runs as root and requests `SYS_ADMIN` so it
  can capture the display and inject input. Treat it like any privileged
  streaming host and keep it on a trusted network / behind a firewall.
- **Config files** written under `/config` are owned by root (the container's
  user); `chown` them on the host if you need non-root ownership there.
