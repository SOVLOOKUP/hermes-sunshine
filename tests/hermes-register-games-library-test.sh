#!/usr/bin/env bash
# Hermetic fixture tests for hermes-register-games-library.
# Style follows tests/hermes-kms-guard-test.sh (ok/fail/skip counters,
# mktemp sandbox, trap cleanup, exit code = number of failures).
#
# NOTE: run as a NON-ROOT user for the read-only fixtures to be meaningful
# (root bypasses file permissions). On a root machine those cases self-skip.
# shellcheck disable=SC2015,SC2010,SC2317
# SC2015: the A && ok "..." || notok "..." assertion idiom is safe here because
#         ok/notok only mutate counters and cannot themselves fail.
# SC2010: ls | grep targets a controlled mktemp sandbox with fixed dot-prefixed
#         probe names; no untrusted filenames occur.
# SC2317: ok/notok/skipc/cleanup/run_helper are invoked indirectly (trap,
#         assertion chains) — same false positive the shipped launcher scripts
#         already tolerate.
set -u

HELPER="${1:-/tmp/hermes-games-staging/rootfs/usr/local/bin/hermes-register-games-library}"
[ -x "${HELPER}" ] || [ -e "${HELPER}" ] || { echo "helper not found: ${HELPER}" >&2; exit 99; }

pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$*"; }
notok(){ fail=$((fail + 1)); printf 'FAIL - %s\n' "$*"; }
skipc(){ skip=$((skip + 1)); printf 'SKIP - %s\n' "$*"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rgl-test.XXXXXX")"
cleanup() { chmod -R u+rwX "${ROOT}" 2>/dev/null; rm -rf "${ROOT}"; }
trap cleanup EXIT

OUT="${ROOT}/out.txt"

# run_helper HOME HERMES_GAMES_DIR -> rc in $? (always expect 0), log in $OUT
run_helper() {
    HOME="$1" sh "${HELPER}" >"${OUT}" 2>&1
}

vdf_of() { printf '%s\n' "$1/.local/share/Steam/config/libraryfolders.vdf"; }

# ------------------------------------------------------------------
echo "== case: HERMES_GAMES_DIR unset / empty (silent no-op) =="
H="${ROOT}/home_unset"; mkdir -p "${H}"
HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 && [ ! -s "${OUT}" ] && [ ! -e "$(vdf_of "${H}")" ] \
    && ok "unset: silent, zero output, no side effects" || notok "unset: expected silence"
HERMES_GAMES_DIR="" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 && [ ! -s "${OUT}" ] \
    && ok "empty string: silent" || notok "empty: expected silence"

# ------------------------------------------------------------------
echo "== case: HERMES_GAMES_DIR points at missing directory =="
H="${ROOT}/home_missing"; mkdir -p "${H}"
rc=0; HERMES_GAMES_DIR="${ROOT}/no_such_dir" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] && grep -q 'not a directory' "${OUT}" && [ ! -e "$(vdf_of "${H}")" ] \
    && ok "missing dir: warn + exit 0, no file created" || notok "missing dir behavior wrong (rc=${rc})"

# ------------------------------------------------------------------
echo "== case: first start (no libraryfolders.vdf) seeds fresh layout =="
H="${ROOT}/home_first"; G="${ROOT}/games_first"; mkdir -p "${H}" "${G}"
rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
V="$(vdf_of "${H}")"
[ "${rc}" -eq 0 ] && [ -f "${V}" ] \
    && ok "first start: exit 0, file created" || notok "first start: file missing (rc=${rc})"
[ -d "${G}/steamapps" ] && ok "first start: steamapps created under games dir" || notok "steamapps missing"
grep -q 'seeded fresh' "${OUT}" && ok "first start: logged seed" || notok "seed log line missing"
# slot 0 = default steam root, slot 1 = games dir, in that order
z0="$(grep -n '^[[:space:]]*"0"[[:space:]]*$' "${V}" | cut -d: -f1)"
z1="$(grep -n '^[[:space:]]*"1"[[:space:]]*$' "${V}" | cut -d: -f1)"
p0="$(grep -nF "\"${H}/.local/share/Steam\"" "${V}" | head -1 | cut -d: -f1)"
p1="$(grep -nF "\"${G}\"" "${V}" | head -1 | cut -d: -f1)"
if [ -n "${z0}" ] && [ -n "${z1}" ] && [ -n "${p0}" ] && [ -n "${p1}" ] \
    && [ "${z0}" -lt "${z1}" ] && [ "${p0}" -gt "${z0}" ] && [ "${p0}" -lt "${z1}" ] \
    && [ "${p1}" -gt "${z1}" ]; then
    ok "first start: slot 0 = default steam root, slot 1 = games (correct order)"
else
    notok "first start: slot layout wrong (z0=${z0} p0=${p0} z1=${z1} p1=${p1})"
fi
grep -c '"apps"' "${V}" | grep -q '^2$' && ok "first start: both slots carry empty apps block" || notok "apps blocks wrong"
# second run: byte-identical + already-registered log (idempotent on seed)
before="$(cat "${V}")"; out2="${ROOT}/out2.txt"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${out2}" 2>&1
after="$(cat "${V}")"
[ "${before}" = "${after}" ] && grep -q 'already registered' "${out2}" \
    && ok "first start: rerun byte-identical + 'already registered'" || notok "seed not idempotent"

# ------------------------------------------------------------------
echo "== case: existing file with default slot only -> append slot 1 =="
H="${ROOT}/home_def"; G="${ROOT}/games_def"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
V="$(vdf_of "${H}")"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t\t"label"\t\t""\n\t\t"content_id"\t\t"1234567890"\n\t\t"apps"\n\t\t{\n\t\t\t"228980"\t\t""\n\t\t}\n\t}\n}\n' "${H}" >"${V}"
cp "${V}" "${V}.orig"
# show before/after bytes for this representative case
echo '--- before ---'; cat -A "${V}"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
echo '--- after ----'; cat -A "${V}"
echo '------------'
head -n 10 "${V}.orig" >"${ROOT}/prefix.txt"; head -n 10 "${V}" >"${ROOT}/prefix2.txt"
cmp -s "${ROOT}/prefix.txt" "${ROOT}/prefix2.txt" \
    && ok "default-only: original first 10 lines byte-preserved (incl. apps entry)" || notok "prefix bytes changed"
grep -q "\"${G}\"" "${V}" && ok "default-only: games path registered" || notok "games path missing"
grep -Eq '^[[:space:]]*"1"[[:space:]]*$' "${V}" && ok "default-only: appended as slot 1" || notok "slot 1 missing"
grep -q 'registered shared library' "${OUT}" && ok "default-only: logged registration" || notok "no log"
# idempotent second run byte-identical
md5a="$(md5sum "${V}" | cut -d' ' -f1)"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
md5b="$(md5sum "${V}" | cut -d' ' -f1)"
[ "${md5a}" = "${md5b}" ] && grep -q 'already registered' "${OUT}" \
    && ok "default-only: rerun byte-identical (no duplicate slot)" || notok "duplicate/rewrite on rerun"

# ------------------------------------------------------------------
echo "== case: existing with other library (slots 0 and 2) -> new slot 3 =="
H="${ROOT}/home_gaps"; G="${ROOT}/games_gaps"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
V="$(vdf_of "${H}")"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n\t"2"\n\t{\n\t\t"path"\t\t"/mnt/external/steamlib"\n\t\t"label"\t\t"External"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' "${H}" >"${V}"
cp "${V}" "${V}.orig"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
grep -Eq '^[[:space:]]*"3"[[:space:]]*$' "${V}" && ok "gaps: next slot numbered 3 (max+1, no reuse of 1)" || notok "numbering wrong"
grep -q '/mnt/external/steamlib' "${V}" && grep -q '"External"' "${V}" \
    && ok "gaps: foreign library entry untouched" || notok "foreign entry damaged"
# insertion goes strictly before the single closing brace: everything above it
# (the original slot 0 + slot 2 entries) stays byte-for-byte, closer preserved.
cl="$(grep -n '^}$' "${V}.orig" | tail -1 | cut -d: -f1)"
head -n $((cl - 1)) "${V}.orig" >"${ROOT}/o_head"
head -n $((cl - 1)) "${V}" >"${ROOT}/n_head"
cmp -s "${ROOT}/o_head" "${ROOT}/n_head" \
    && ok "gaps: pre-closer bytes preserved verbatim" || notok "pre-closer bytes altered"
cmp -s <(tail -n +1 "${V}.orig" | tail -1) <(tail -1 "${V}") \
    && ok "gaps: closing brace line preserved" || notok "closer altered"

# ------------------------------------------------------------------
echo "== case: already-registered (Steam-style heavy fixture) -> untouched =="
H="${ROOT}/home_reg"; G="${ROOT}/games_reg"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
V="$(vdf_of "${H}")"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t\t"label"\t\t""\n\t\t"content_id"\t\t"1585742340694934269"\n\t\t"totalsize"\t\t"0"\n\t\t"free空间"\t\t"0"\n\t\t"update_filter"\n\t\t{\n\t\t}\n\t\t"apps"\n\t\t{\n\t\t\t"228980"\t\t""\n\t\t}\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"label"\t\t"Shared"\n\t\t"content_id"\t\t"777"\n\t\t"time_updated"\t\t"1730000000"\n\t\t"valid"\t\t"1"\n\t\t"configured"\t\t"1"\n\t\t"apps"\n\t\t{\n\t\t\t"730"\t\t""\n\t\t}\n\t}\n}\n' "${H}" "${G}" >"${V}"
md5a="$(md5sum "${V}" | cut -d' ' -f1)"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
md5b="$(md5sum "${V}" | cut -d' ' -f1)"
[ "${md5a}" = "${md5b}" ] && grep -q 'already registered' "${OUT}" \
    && ok "heavy fixture (extra keys, non-empty apps): byte-identical, no write" || notok "modified an already-registered file"
# no stray tmp files
! ls -A "${H}/.local/share/Steam/config" | grep -q '.hermes' \
    && ok "no .hermes tmp litter" || notok "tmp litter left behind"

# ------------------------------------------------------------------
echo "== case: already-registered with trailing-slash env value =="
out2="${ROOT}/out_ts.txt"
HERMES_GAMES_DIR="${G}/" HOME="${H}" sh "${HELPER}" >"${out2}" 2>&1
md5c="$(md5sum "${V}" | cut -d' ' -f1)"
[ "${md5a}" = "${md5c}" ] && grep -q 'already registered' "${out2}" \
    && ok "trailing slash normalized: still recognized as registered" || notok "trailing slash duplicated slot"

# ------------------------------------------------------------------
echo "== case: weird path with spaces, quotes and backslashes =="
H="${ROOT}/home_weird"; mkdir -p "${H}"
G="${ROOT}/a b\"c\\d"          # -> <tmp>/a b"c\d
mkdir -p "${G}"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
V="$(vdf_of "${H}")"
[ -f "${V}" ] && ok "weird path: first-start file created" || notok "weird path: no file"
grep -Fq 'a b\"c\\d"' "${V}" \
    && ok "weird path: written VDF-escaped (quote as \\\", backslash doubled)" || notok "escaping wrong"
before="$(cat "${V}")"
HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1
after="$(cat "${V}")"
[ "${before}" = "${after}" ] && grep -q 'already registered' "${OUT}" \
    && ok "weird path: re-run recognizes escaped value, byte-identical" || notok "weird path not idempotent"
# append mode on a pre-existing file with weird path
H2="${ROOT}/home_weird2"; mkdir -p "${H2}/.local/share/Steam/config"
V2="$(vdf_of "${H2}")"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' "${H2}" >"${V2}"
HERMES_GAMES_DIR="${G}" HOME="${H2}" sh "${HELPER}" >"${OUT}" 2>&1
grep -Fq 'a b\"c\\d"' "${V2}" && grep -Fq "${H2}/.local/share/Steam" "${V2}" \
    && ok "weird path: append onto existing file keeps both entries" || notok "weird append failed"

# ------------------------------------------------------------------
echo "== case: read-only games mount (mkdir steamapps must fail) =="
if [ "$(id -u)" -eq 0 ]; then
    skipc "read-only fixtures meaningless under root"
else
    H="${ROOT}/home_ro"; G="${ROOT}/games_ro"; mkdir -p "${H}" "${G}"
    chmod u-w "${G}"
    rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
    chmod u+w "${G}"
    V="$(vdf_of "${H}")"
    [ "${rc}" -eq 0 ] && grep -q 'cannot create' "${OUT}" && grep -qF "\"${G}\"" "${V}" \
        && ok "read-only mount: warned about steamapps, registration continued, exit 0" || notok "read-only mount case failed (rc=${rc})"

    # ---- case: read-only config dir (cannot write vdf at all) ----
    H="${ROOT}/home_rocfg"; G="${ROOT}/games_rocfg"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
    V="$(vdf_of "${H}")"
    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' "${H}" >"${V}"
    md5a="$(md5sum "${V}" | cut -d' ' -f1)"
    chmod u-w "${H}/.local/share/Steam/config"
    rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
    chmod u+w "${H}/.local/share/Steam/config"
    md5b="$(md5sum "${V}" | cut -d' ' -f1)"
    litter="$(ls -A "${H}/.local/share/Steam/config" | grep '.hermes' || true)"
    [ "${rc}" -eq 0 ] && [ "${md5a}" = "${md5b}" ] && grep -Eq 'cannot|skipping' "${OUT}" && [ -z "${litter}" ] \
        && ok "read-only cfg dir: original untouched, warn, exit 0, no tmp litter" || notok "read-only cfg dir failed (rc=${rc})"

    # ---- case: unreadable vdf (chmod 000) ----
    H="${ROOT}/home_unread"; G="${ROOT}/games_unread"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
    V="$(vdf_of "${H}")"
    printf '"libraryfolders"\n{\n}\n' >"${V}"; chmod 000 "${V}"
    rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
    chmod 600 "${V}"
    [ "${rc}" -eq 0 ] && grep -q 'not readable' "${OUT}" \
        && ok "unreadable vdf: graceful warn, exit 0" || notok "unreadable case failed (rc=${rc})"
fi

# ------------------------------------------------------------------
echo "== case: foreign / legacy format (AppConfig) must never be rewritten =="
H="${ROOT}/home_legacy"; G="${ROOT}/games_legacy"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
V="$(vdf_of "${H}")"
printf '"AppConfig"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n\t}\n}\n' "${H}" >"${V}"
md5a="$(md5sum "${V}" | cut -d' ' -f1)"
rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
md5b="$(md5sum "${V}" | cut -d' ' -f1)"
[ "${rc}" -eq 0 ] && [ "${md5a}" = "${md5b}" ] && grep -Eq 'untouched|libraryfolders VDF' "${OUT}" \
    && ok "legacy AppConfig: detected non-modern top-level, left byte-identical" || notok "legacy file was modified!"

# ------------------------------------------------------------------
echo "== case: truncated/corrupt file must not be rewritten =="
H="${ROOT}/home_corrupt"; G="${ROOT}/games_corrupt"; mkdir -p "${H}/.local/share/Steam/config" "${G}"
V="$(vdf_of "${H}")"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s/.local/share/Steam"\n' "${H}" >"${V}"
md5a="$(md5sum "${V}" | cut -d' ' -f1)"
rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
md5b="$(md5sum "${V}" | cut -d' ' -f1)"
[ "${rc}" -eq 0 ] && [ "${md5a}" = "${md5b}" ] \
    && ok "truncated vdf (unbalanced braces): refused to write, exit 0" || notok "wrote over corrupt file!"
printf '' >"${V}"   # 0-byte file
rc=0; HERMES_GAMES_DIR="${G}" HOME="${H}" sh "${HELPER}" >"${OUT}" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] && [ ! -s "${V}" ] \
    && ok "0-byte vdf: left untouched, exit 0" || notok "0-byte case wrote something"

# ------------------------------------------------------------------
echo "== case: no tmp litter / atomic swap only on change (global check) =="
found_litter="$(find "${ROOT}" -name '.libraryfolders.vdf.hermes.*' 2>/dev/null | head -1)"
[ -z "${found_litter}" ] && ok "no .hermes tmp files anywhere in sandbox" || notok "litter: ${found_litter}"

echo
printf 'pass=%d fail=%d skip=%d\n' "${pass}" "${fail}" "${skip}"
exit "${fail}"
