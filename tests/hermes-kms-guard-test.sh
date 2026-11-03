#!/usr/bin/env bash
# ==============================================================================
# tests/hermes-kms-guard-test.sh — self-contained tests for scripts/hermes-kms-guard
#
# Fully hermetic: every test runs the guard against a temporary fake sysfs tree,
# fake /proc/modules, fake device nodes and fake external commands (git, make,
# dkms, modprobe, modinfo, lsmod, fuser, hermes-kmsctl). It NEVER loads/unloads
# a real kernel module, touches the real /sys or /dev, or kills any process.
#
# The guard exposes GUARD_SYSFS_ROOT / GUARD_DEV_DRI / GUARD_PROC_MODULES for
# exactly this purpose, plus GUARD_TEST_ALLOW_NONROOT to exercise privileged
# code paths without root.
#
# Usage: bash tests/hermes-kms-guard-test.sh
# ==============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../scripts/hermes-kms-guard"

PASS=0
FAIL=0
SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()    { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
notok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
skip()  { SKIP=$((SKIP + 1)); printf 'skip - %s\n' "$1"; }

eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else notok "$1 (expected '$3', got '$2')"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else notok "$1 (expected to contain '$3'; got '$2')"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else notok "$1 (expected NOT to contain '$3')"; fi; }

envn=0
ENV=""

# --- fake command factory ----------------------------------------------------
mkfake_bin() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/hermes-kmsctl" <<'EOS'
#!/usr/bin/env bash
# Fake hermes-kmsctl; only the "version" query matters here.
if [[ "${*:-}" == *version* ]]; then
  printf 'driver_version=%s\nuapi_version=%s\n' "${KMSCTL_VER:-0.4.1}" "${KMSCTL_UAPI:-14}"
fi
exit 0
EOS

  cat > "$bin/modinfo" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == "-F" && "${2:-}" == "version" ]]; then printf '%s\n' "${MODINFO_VER:-0.4.1}"; fi
exit 0
EOS

  cat > "$bin/lsmod" <<'EOS'
#!/usr/bin/env bash
printf 'Module Size Used by\n'
if [[ "${LSMOD_USED:-0}" != "0" ]]; then printf 'hermes_kms 131072 %s\n' "$LSMOD_USED"; fi
exit 0
EOS

  cat > "$bin/fuser" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS

  cat > "$bin/modprobe" <<'EOS'
#!/usr/bin/env bash
printf 'modprobe %s\n' "$*" >> "${FAKELOG:-/dev/null}"
exit 0
EOS

  cat > "$bin/rmmod" <<'EOS'
#!/usr/bin/env bash
printf 'rmmod %s\n' "$*" >> "${FAKELOG:-/dev/null}"
exit 0
EOS

  cat > "$bin/dkms" <<'EOS'
#!/usr/bin/env bash
printf 'dkms %s\n' "$*" >> "${FAKELOG:-/dev/null}"
if [[ "${1:-}" == "status" ]]; then
  printf 'hermes-kms/%s, %s, x86_64: installed\n' "${DKMS_VER:-0.4.1}" "$(uname -r)"
fi
exit 0
EOS

  cat > "$bin/make" <<'EOS'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> "${FAKELOG:-/dev/null}"
exit 0
EOS

  cat > "$bin/git" <<'EOS'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${FAKELOG:-/dev/null}"
exit 1
EOS

  chmod +x "$bin"/*
}

# --- fake sysfs factory ------------------------------------------------------
mk_sysfs() {
  local sys="$1"
  mkdir -p "$sys/module/hermes_kms/parameters" "$sys/class/drm" \
           "$sys/bus/platform/drivers" "$sys/devices/platform"
  printf 'Y\n' > "$sys/module/hermes_kms/parameters/hdr_enable"
  printf '10\n' > "$sys/module/hermes_kms/parameters/color_depth"
  printf '0\n' > "$sys/module/hermes_kms/refcnt"
}

# add_render SYS BASE DRIVER [ROLE]
add_render() {
  local sys="$1" base="$2" drv="$3" role="${4:-general}"
  local pdev="$sys/devices/platform/${drv}.${base}"
  mkdir -p "$sys/class/drm/$base" "$pdev" "$sys/bus/platform/drivers/$drv"
  printf '%s\n' "$role" > "$pdev/hermes_kms_role"
  ln -s "$sys/bus/platform/drivers/$drv" "$pdev/driver"
  ln -s "$pdev" "$sys/class/drm/$base/device"
}

# --- per-test environment ----------------------------------------------------
setup_env() {
  envn=$((envn + 1))
  ENV="$TMP/env$envn"
  SYS="$ENV/sys"
  DEV="$ENV/dev/dri"
  BIN="$ENV/bin"
  PROC="$ENV/proc_modules"
  FAKELOG="$ENV/fake.log"
  SRC="$ENV/src"
  mkdir -p "$DEV" "$SRC"
  : > "$FAKELOG"
  : > "$PROC"
  mkfake_bin "$BIN"
  mk_sysfs "$SYS"
  printf 'all:\n\t@true\n' > "$SRC/Makefile"

  # defaults for fake-command behaviour
  KMSCTL_UAPI=14
  KMSCTL_VER=0.4.1
  LSMOD_USED=0
  ALLOW_NR=1
}

# Run the guard hermetically; captures stdout in OUT, stderr in ERRTXT, code in RC.
rung() {
  OUT="$(GUARD_SYSFS_ROOT="$SYS" \
         GUARD_DEV_DRI="$DEV" \
         GUARD_PROC_MODULES="$PROC" \
         GUARD_SOURCE="$SRC" \
         GUARD_STATE_DIR="$ENV/state" \
         GUARD_TEST_ALLOW_NONROOT="$ALLOW_NR" \
         PATH="$BIN:$PATH" \
         FAKELOG="$FAKELOG" \
         KMSCTL_UAPI="$KMSCTL_UAPI" \
         KMSCTL_VER="$KMSCTL_VER" \
         LSMOD_USED="$LSMOD_USED" \
         "$GUARD" "$@" 2>"$ENV/err")"
  RC=$?
  ERRTXT="$(cat "$ENV/err")"
}

json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      ok "$2"
    else
      notok "$2 (invalid JSON)"
    fi
  else
    # Fallback heuristic when python3 is absent.
    has "$2" "$1" '{'
  fi
}

json_field() {
  # json_field <json> <dotted.path>
  printf '%s' "$1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in sys.argv[1].split("."):
    d = d[int(p)] if isinstance(d, list) else d[p]
print(d)
' "$2" 2>/dev/null
}

# =============================================================================
# Tests
# =============================================================================

# --- CLI surface -------------------------------------------------------------
OUT="$("$GUARD" --help 2>&1)"; RC=$?
eq "help exits 0" "$RC" "0"
has "help shows USAGE" "$OUT" "USAGE"
has "help shows COMMANDS" "$OUT" "COMMANDS"
has "help shows exit codes" "$OUT" "EXIT CODES"

OUT="$("$GUARD" --version 2>&1)"; RC=$?
eq "version exits 0" "$RC" "0"
has "version prints version" "$OUT" "hermes-kms-guard"

OUT="$("$GUARD" nonsense 2>&1)"; RC=$?
eq "unknown command exits 2" "$RC" "2"

OUT="$("$GUARD" status --bogus 2>&1)"; RC=$?
eq "unknown option exits 2" "$RC" "2"

# --- healthy status ----------------------------------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
rung status --json
eq "healthy status exit 0" "$RC" "0"
json_ok "$OUT" "healthy status is valid JSON"
eq "healthy status is ok" "$(json_field "$OUT" status)" "ok"
eq "healthy module loaded" "$(json_field "$OUT" module.loaded)" "True"
eq "healthy uapi 14" "$(json_field "$OUT" uapi.version)" "14"
has "healthy render node is renderD128" "$(json_field "$OUT" render.primary)" "renderD128"
eq "healthy exit_code field 0" "$(json_field "$OUT" exit_code)" "0"

# verify (text) reflects ok
rung verify
eq "verify healthy exit 0" "$RC" "0"
has "verify prints [ok]" "$OUT" "[ok"
has "verify prints result line" "$OUT" "result: ok"

# --- module missing ----------------------------------------------------------
setup_env
rm -rf "$SYS/module/hermes_kms"   # no module dir -> truly not loaded
rung status --json
eq "module missing exit 6" "$RC" "6"
json_ok "$OUT" "module-missing JSON valid"
eq "module missing status error" "$(json_field "$OUT" status)" "error"
eq "module missing exit_code 6" "$(json_field "$OUT" exit_code)" "6"
eq "module missing loaded false" "$(json_field "$OUT" module.loaded)" "False"

# --- module loaded, no render node ------------------------------------------
setup_env
# sysfs has the module dir but no /class/drm/renderD* entries
rung status --json
eq "render missing exit 7" "$RC" "7"
eq "render missing exit_code 7" "$(json_field "$OUT" exit_code)" "7"

# --- render node writable ----------------------------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0666 "$DEV/renderD128"
rung status --json
eq "writable render node exit 8" "$RC" "8"
eq "writable node readonly=false" "$(json_field "$OUT" render.nodes.0.readonly)" "False"

# --- render node read-only group (0640) is fine ------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0640 "$DEV/renderD128"
rung status --json
eq "0640 node accepted (exit 0)" "$RC" "0"
eq "0640 node readonly=true" "$(json_field "$OUT" render.nodes.0.readonly)" "True"

# --- hdr_enable unreadable ---------------------------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
chmod 000 "$SYS/module/hermes_kms/parameters/hdr_enable"
if [[ "$(id -u)" -eq 0 ]]; then
  skip "hdr_enable unreadable (root can read 000; skipped)"
else
  rung status --json
  eq "hdr unreadable exit 9" "$RC" "9"
  eq "hdr readable=false" "$(json_field "$OUT" hdr.readable)" "False"
fi

# --- UAPI mismatch -----------------------------------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
KMSCTL_UAPI=9
rung status --json
eq "uapi mismatch exit 10" "$RC" "10"
eq "uapi mismatch exit_code 10" "$(json_field "$OUT" exit_code)" "10"
eq "uapi mismatch expected 14" "$(json_field "$OUT" uapi.expected)" "14"

# --- render-node identification is never assumed (no renderD129) -------------
setup_env
add_render "$SYS" renderD128 amdgpu general
add_render "$SYS" renderD129 amdgpu general
add_render "$SYS" renderD130 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
: > "$DEV/renderD129"; chmod 0644 "$DEV/renderD129"
: > "$DEV/renderD130"; chmod 0644 "$DEV/renderD130"
rung status --json
eq "detects hermes node not fixed index (exit 0)" "$RC" "0"
eq "detects exactly one hermes node" "$(json_field "$OUT" render.count)" "1"
has "picks renderD130 (hermes), not 129" "$(json_field "$OUT" render.primary)" "renderD130"
hasnt "does not pick amdgpu renderD129" "$(json_field "$OUT" render.primary)" "renderD129"

# --- install: root required --------------------------------------------------
setup_env
if [[ "$(id -u)" -eq 0 ]]; then
  skip "install requires root (already root; skipped)"
else
  ALLOW_NR=0
  rung install
  eq "install without root exits 3" "$RC" "3"
fi

# --- source checkout paths cannot traverse out of workdir ---------------------
setup_env
SRC=""
rung install --workdir "$ENV/work" --ref '../../escape'
eq "unsafe ref clone fails through fake git" "$RC" "4"
hasnt "raw ref never reaches checkout path" "$(cat "$FAKELOG")" "$ENV/work/../../escape"
has "sanitized ref stays in verified workdir" "$(cat "$FAKELOG")" "$ENV/work/Hermes-KMS-.._.._escape"

# --- install: wraps upstream make dkms-install -------------------------------
setup_env
rung install
eq "install (fake) exit 0" "$RC" "0"
has "install runs upstream dkms-install" "$(cat "$FAKELOG")" "dkms-install"

# --- uninstall: wraps upstream make dkms-uninstall + safe unload -------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
rung uninstall
eq "uninstall (fake) exit 0" "$RC" "0"
has "uninstall runs upstream dkms-uninstall" "$(cat "$FAKELOG")" "dkms-uninstall"
has "uninstall unloads idle module" "$(cat "$FAKELOG")" "modprobe -r hermes_kms"

# --- uninstall --no-unload leaves module alone -------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
rung uninstall --no-unload
eq "uninstall --no-unload exit 0" "$RC" "0"
has "uninstall --no-unload still removes DKMS" "$(cat "$FAKELOG")" "dkms-uninstall"
hasnt "uninstall --no-unload does not rmmod" "$(cat "$FAKELOG")" "modprobe -r"

# --- rebuild refuses a busy module (must NOT rmmod / must NOT build) ---------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
printf '1\n' > "$SYS/module/hermes_kms/refcnt"
rung rebuild
eq "busy rebuild exits 5" "$RC" "5"
hasnt "busy rebuild does not unload" "$(cat "$FAKELOG")" "modprobe -r"
hasnt "busy rebuild does not build" "$(cat "$FAKELOG")" "dkms-install"

# --- rebuild on idle module (unload -> build -> load) ------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
printf '0\n' > "$SYS/module/hermes_kms/refcnt"
rung rebuild
eq "idle rebuild exits 0" "$RC" "0"
log="$(cat "$FAKELOG")"
has "idle rebuild unloads first" "$log" "modprobe -r hermes_kms"
has "idle rebuild runs dkms-install" "$log" "dkms-install"
has "idle rebuild loads module" "$log" "modprobe hermes_kms"
ul="$(grep -n 'modprobe -r hermes_kms' "$FAKELOG" | head -n1 | cut -d: -f1)"
bi="$(grep -n 'dkms-install' "$FAKELOG" | head -n1 | cut -d: -f1)"
lo="$(grep -n 'modprobe hermes_kms' "$FAKELOG" | head -n1 | cut -d: -f1)"
if [[ -n "$ul" && -n "$bi" && -n "$lo" && "$ul" -lt "$bi" && "$bi" -lt "$lo" ]]; then
  ok "rebuild order: unload < build < load"
else
  notok "rebuild order (unload=$ul build=$bi load=$lo)"
fi

# --- watch: unhealthy, bounded, alerts, preserves state ---------------------
setup_env   # module missing env
rm -rf "$SYS/module/hermes_kms"
rung watch --cycles 1 --interval 1
eq "watch unhealthy bounded exit 6" "$RC" "6"
has "watch emits actionable alert" "$ERRTXT" "[alert]"
has "watch suggests remediation" "$ERRTXT" "remediation"
if [[ -f "$ENV/state/last-status.json" ]]; then
  ok "watch preserves status file"
  json_ok "$(cat "$ENV/state/last-status.json")" "watch status file is valid JSON"
else
  notok "watch preserves status file (missing $ENV/state/last-status.json)"
fi

# --- watch: healthy bounded run exits 0 -------------------------------------
setup_env
add_render "$SYS" renderD128 hermes-kms general
: > "$DEV/renderD128"; chmod 0644 "$DEV/renderD128"
rung watch --cycles 1 --interval 1
eq "watch healthy exit 0" "$RC" "0"
has "watch healthy reports ok" "$OUT" "status=ok"

# --- watch --rebuild on unhealthy but non-root: skips, preserves -------------
setup_env   # module missing env
rm -rf "$SYS/module/hermes_kms"
ALLOW_NR=0
rung watch --cycles 1 --interval 1 --rebuild
# is_root() is false in CI; watch should skip rebuild and keep status 6
if [[ "$(id -u)" -eq 0 ]]; then
  skip "watch --rebuild non-root skip (already root; skipped)"
else
  eq "watch --rebuild non-root still exits 6" "$RC" "6"
  has "watch --rebuild non-root warns about root" "$ERRTXT" "needs root"
fi

# =============================================================================
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
