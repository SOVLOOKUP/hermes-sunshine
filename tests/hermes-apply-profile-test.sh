#!/usr/bin/env bash
# Hermetic fixture tests for hermes-apply-profile (control-plane limits).
# Style follows tests/hermes-register-games-library-test.sh (ok/fail/skip
# counters, mktemp sandbox, trap cleanup, exit code = number of failures).
# shellcheck disable=SC2015
# SC2015: the `A && ok "..." || notok "..."` idiom is safe here because ok/notok
#         only mutate counters and cannot themselves fail.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="${1:-${HERE}/../rootfs/usr/local/bin/hermes-apply-profile.sh}"
[ -f "${HELPER}" ] || { echo "helper not found: ${HELPER}" >&2; exit 99; }

pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$*"; }
notok(){ fail=$((fail + 1)); printf 'FAIL - %s\n' "$*"; }
skipc(){ skip=$((skip + 1)); printf 'SKIP - %s\n' "$*"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hap-test.XXXXXX")"
cleanup() { chmod -R u+rwX "${ROOT}" 2>/dev/null; rm -rf "${ROOT}"; }
trap cleanup EXIT

CASE=0
# new_case -> fresh sandbox with one app carrying an existing MANGOHUD_CONFIG
new_case() {
    CASE=$((CASE + 1))
    D="${ROOT}/c${CASE}"
    mkdir -p "${D}"
    cat >"${D}/apps.json" <<'JSON'
{"apps":[{"name":"Steam","env":["MANGOHUD_CONFIG=position=top-left,no_display","DXVK_FRAME_RATE=120","FOO=1"]},
         {"name":"NoEnv"}]}
JSON
    printf 'apps = keep\n' >"${D}/hermes.conf"
    cp "${D}/apps.json" "${D}/apps.orig"
    cp "${D}/hermes.conf" "${D}/conf.orig"
    OUT="${D}/out.txt"
    ERR="${D}/err.txt"
}

# run [VAR=value ...] -> helper exit code; stdout in $OUT, stderr in $ERR
run() {
    env -u HERMES_MAX_BITRATE_KBPS -u HERMES_MAX_FPS -u HERMES_FEC_PERCENTAGE \
        APPS_JSON="${D}/apps.json" HERMES_CONFIG="${D}/hermes.conf" "$@" \
        bash "${HELPER}" >"${OUT}" 2>&1
}
run_split() {
    env -u HERMES_MAX_BITRATE_KBPS -u HERMES_MAX_FPS -u HERMES_FEC_PERCENTAGE \
        APPS_JSON="${D}/apps.json" HERMES_CONFIG="${D}/hermes.conf" "$@" \
        bash "${HELPER}" >"${OUT}" 2>"${ERR}"
}

conf_has() { grep -qxF "$1" "${D}/hermes.conf"; }
env_has()  { jq -e --arg e "$1" 'any(.apps[] | (.env // [])[]; . == $e)' "${D}/apps.json" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || { echo "jq is required for these tests" >&2; exit 99; }

# ------------------------------------------------------------------
echo "== case: nothing in the environment =="
new_case
run && ok "exit 0 with no limits" || notok "expected exit 0"
cmp -s "${D}/apps.orig" "${D}/apps.json" && ok "apps.json untouched" || notok "apps.json changed"
cmp -s "${D}/conf.orig" "${D}/hermes.conf" && ok "hermes.conf untouched" || notok "hermes.conf changed"
grep -q "no usable per-client limits" "${OUT}" && ok "says why nothing happened" || notok "missing no-op message"

# ------------------------------------------------------------------
echo "== case: bitrate ceiling =="
new_case
run HERMES_MAX_BITRATE_KBPS=20000 && conf_has "max_bitrate = 20000" \
    && ok "max_bitrate written" || notok "max_bitrate not written"
cp "${D}/hermes.conf" "${D}/conf.once"
run HERMES_MAX_BITRATE_KBPS=20000 && cmp -s "${D}/conf.once" "${D}/hermes.conf" \
    && ok "idempotent on re-run" || notok "re-run changed the file"
grep -q "already in effect" "${OUT}" && ok "re-run reports no change" || notok "re-run message wrong"

new_case
run_split HERMES_MAX_BITRATE_KBPS=500 && conf_has "max_bitrate = 1000" \
    && ok "below floor clamped to 1000" || notok "below floor not clamped"
grep -q "below the host floor" "${ERR}" && ok "clamp warned" || notok "clamp warning missing"

new_case
run_split HERMES_MAX_BITRATE_KBPS=12x && cmp -s "${D}/conf.orig" "${D}/hermes.conf" \
    && ok "non-numeric ignored, file untouched" || notok "non-numeric wrote something"
grep -q "non-numeric" "${ERR}" && ok "non-numeric warned" || notok "non-numeric warning missing"

# ------------------------------------------------------------------
echo "== case: frame-rate ceiling =="
new_case
run HERMES_MAX_FPS=60 && ok "exit 0 with fps ceiling" || notok "fps run failed"
env_has "MANGOHUD_CONFIG=position=top-left,no_display,fps_limit=60" \
    && ok "existing MANGOHUD options preserved" || notok "MANGOHUD options lost"
env_has "DXVK_FRAME_RATE=60" && ok "DXVK_FRAME_RATE updated" || notok "DXVK_FRAME_RATE wrong"
env_has "VKD3D_FRAME_RATE=60" && ok "VKD3D_FRAME_RATE added" || notok "VKD3D_FRAME_RATE missing"
env_has "FOO=1" && ok "unrelated env entries kept" || notok "unrelated env entry lost"
cp "${D}/apps.json" "${D}/apps.once"
run HERMES_MAX_FPS=60 && cmp -s "${D}/apps.once" "${D}/apps.json" \
    && ok "fps rewrite is idempotent" || notok "fps rewrite not idempotent"

new_case
run HERMES_MAX_FPS=60 && run HERMES_MAX_FPS=30 \
    && env_has "MANGOHUD_CONFIG=position=top-left,no_display,fps_limit=30" \
    && ok "changing the ceiling replaces fps_limit in place" || notok "fps_limit not replaced"
[ "$(jq -r '[.apps[].env[]? | select(startswith("MANGOHUD_CONFIG="))] | length' "${D}/apps.json")" = "1" ] \
    && ok "exactly one MANGOHUD_CONFIG per app" || notok "multiple MANGOHUD_CONFIG entries"

new_case
run_split HERMES_MAX_FPS=abc && cmp -s "${D}/apps.orig" "${D}/apps.json" \
    && ok "non-numeric fps ignored" || notok "non-numeric fps rewrote apps"
grep -q "expected a positive integer" "${ERR}" && ok "bad fps warned" || notok "bad fps warning missing"

new_case
run_split HERMES_MAX_FPS=0 && cmp -s "${D}/apps.orig" "${D}/apps.json" \
    && ok "fps 0 rejected" || notok "fps 0 accepted"

# ------------------------------------------------------------------
echo "== case: FEC =="
new_case
run HERMES_FEC_PERCENTAGE=15 && conf_has "fec_percentage = 15" \
    && ok "fec_percentage written" || notok "fec_percentage not written"
new_case
run_split HERMES_FEC_PERCENTAGE=99 && cmp -s "${D}/conf.orig" "${D}/hermes.conf" \
    && ok "out-of-range FEC ignored" || notok "out-of-range FEC written"
grep -q "expected 1-50" "${ERR}" && ok "FEC range warned" || notok "FEC warning missing"

# ------------------------------------------------------------------
echo "== case: non-array env is left alone =="
new_case
jq '.apps = [{"name":"Obj","env":{"A":"b"}}]' "${D}/apps.json" >"${D}/tmp" && mv "${D}/tmp" "${D}/apps.json"
cp "${D}/apps.json" "${D}/apps.orig"
run HERMES_MAX_FPS=60 && cmp -s "${D}/apps.orig" "${D}/apps.json" \
    && ok "object env untouched" || notok "object env rewritten"

# ------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
exit "${fail}"
