#!/bin/bash
#
# One version across the scripts and the firmware.
#
# The number lives in VERSION and is copied into two files that cannot read it
# at build time - the ini and the sketch. Copies drift silently, so this suite
# is what makes them not.
#
#   ./tests/test-version.sh

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp"
mkdir -p "${TMP}"

PASS=0; FAIL=0
ok() {
  local label="${1}" got="${2}" want="${3}"
  if [ "${got}" = "${want}" ]; then
    PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "${label}"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n' "${label}" "${want}" "${got}"
  fi
}
contains() {
  local label="${1}" hay="${2}" needle="${3}"
  case "${hay}" in
    *"${needle}"*) PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "${label}" ;;
    *) FAIL=$((FAIL+1))
       printf '  \033[31mFAIL\033[0m %s\n       expected to contain: [%s]\n       got: [%s]\n' "${label}" "${needle}" "${hay}" ;;
  esac
}
section() { printf '\n\033[1m%s\033[0m\n' "${1}"; }

VERSION="$(tr -d ' \t\n\r' < "${ROOT}/VERSION")"

# ---------------------------------------------------------------------------
section "every copy of the version agrees with VERSION"
# ---------------------------------------------------------------------------
"${ROOT}/tools/bump-version.sh" --check >/dev/null 2>&1
ok "bump-version.sh --check passes" "$?" "0"

ok "the ini carries it" \
   "$(sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${ROOT}/tty2oled-system.ini")" "${VERSION}"
ok "the sketch carries it" \
   "$(sed -n 's/^#define BuildVersion "\([^"]*\)".*/\1/p' "${ROOT}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino")" \
   "${VERSION}"

case "${VERSION}" in
  [0-9]*.[0-9]*.[0-9]*) ok "VERSION looks like major.minor.patch" "yes" "yes" ;;
  *) ok "VERSION looks like major.minor.patch" "${VERSION}" "major.minor.patch" ;;
esac

# ---------------------------------------------------------------------------
section "bump-version.sh arithmetic"
# ---------------------------------------------------------------------------
# A sandbox with the same three files, so the real ones are never touched.
SAND="${TMP}/version-sandbox"
rm -rf "${SAND}"
mkdir -p "${SAND}/MiSTer_SSD1322_USB"
sandbox() {
  printf '%s\n' "${1}" > "${SAND}/VERSION"
  printf 'TTY2OLED_VERSION="%s"\nTTY2OLED_PATH="/media/fat/tty2oledplus"\n' "${1}" \
    > "${SAND}/tty2oled-system.ini"
  printf '#define BuildVersion "%s"\n' "${1}" \
    > "${SAND}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
}
sandver()  { tr -d ' \t\n\r' < "${SAND}/VERSION"; }
sandini()  { sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${SAND}/tty2oled-system.ini"; }
sandino()  { sed -n 's/^#define BuildVersion "\([^"]*\)".*/\1/p' "${SAND}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"; }
bump()     { REPO="${SAND}" "${ROOT}/tools/bump-version.sh" "${@}" >/dev/null 2>&1; }

sandbox "0.4.0b"
bump
ok "the last digit increments"   "$(sandver)" "0.4.1b"
ok "the beta mark is kept"       "$(sandini)" "0.4.1b"
ok "the sketch moves with it"    "$(sandino)" "0.4.1b"

bump
bump
ok "and keeps incrementing"      "$(sandver)" "0.4.3b"

sandbox "0.4.9b"
bump
ok "past nine, no carry"         "$(sandver)" "0.4.10b"

sandbox "0.4.7b"
bump --release
ok "--release drops the mark"    "$(sandver)" "0.4.7"
ok "...in the sketch too"        "$(sandino)" "0.4.7"
bump
ok "a release bumps plainly"     "$(sandver)" "0.4.8"

bump --release
ok "--release on a release fails" "$?" "1"
ok "...and changes nothing"       "$(sandver)" "0.4.8"

bump --set 1.0.0b
ok "--set takes what it is given" "$(sandver)" "1.0.0b"

bump --set "1.0"
ok "a malformed --set fails"      "$?" "1"
ok "...and changes nothing"       "$(sandver)" "1.0.0b"

# A drifted copy has to be caught: that is the whole job.
printf '#define BuildVersion "0.0.1"\n' > "${SAND}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
bump --check
ok "--check catches a drifted sketch" "$?" "1"

# ---------------------------------------------------------------------------
section "the daemon reports both versions and flags a mismatch"
# ---------------------------------------------------------------------------
# Load only the daemon's functions, as test-wire.sh does, and give checkversion
# a FIFO to talk to instead of a serial port.
TTYDEV="${TMP}/version-fifo"
WAITSECS="0"
USBMODE="yes"
debug="false"
debugfile="${TMP}/debuglog"
dbug() { :; }
eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"

# The firmware answers "HW<board>;<version>;" and acks everything else with
# "ttyack;" - including the CMDHWINF that asks, and whatever the daemon wrote
# before it. The reply is fed through the same FIFO the daemon writes to, so
# the function has to pick its answer out of that traffic.
ask_version() {
  local reply="${1}"
  rm -f "${TTYDEV}"; mkfifo "${TTYDEV}"
  ( printf '%s' "${reply}" > "${TTYDEV}" ) &
  local out=""
  out="$(TTY2OLED_VERSION="${VERSION}" checkversion 2>&1)"
  wait 2>/dev/null
  printf '%s' "${out}"
}

out="$(ask_version "ttyack;HWLOLIN32;${VERSION};")"
contains "reports the script version" "${out}" "tty2oled+ ${VERSION}"
contains "reports the firmware version" "${out}" "firmware ${VERSION}"
case "${out}" in
  *DIFFER*) ok "matching versions are not flagged" "flagged" "quiet" ;;
  *)        ok "matching versions are not flagged" "quiet" "quiet" ;;
esac

out="$(ask_version "ttyack;HWLOLIN32;9.9.9;")"
contains "a different firmware is flagged" "${out}" "VERSIONS DIFFER"
contains "...and says how to fix it"       "${out}" "--firmware --flash"

# A display that says nothing must not be reported as a mismatch.
out="$(ask_version "ttyack;")"
contains "silence is reported as silence" "${out}" "did not answer"
case "${out}" in
  *DIFFER*) ok "silence is not a mismatch" "flagged" "quiet" ;;
  *)        ok "silence is not a mismatch" "quiet" "quiet" ;;
esac
rm -f "${TTYDEV}"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
