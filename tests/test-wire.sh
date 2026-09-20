#!/bin/bash
#
# End-to-end wire-protocol tests for the daemon.
#
# Captures everything the daemon would write to the serial device into a plain
# file and asserts the exact command sequence, so the bytes that reach the
# firmware are verified without a MiSTer, an ESP32 or a serial port.
#
#   ./tests/test-wire.sh

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
FIX="${HERE}/fixtures"
TMP="${FIX}/tmp"
mkdir -p "${TMP}" "${TMP}/pics/ICON" "${TMP}/pics_pri/ICON"

# Some containers have no xxd; tests/bin provides a stand-in. MiSTer has the
# real thing, which is what the daemon uses.
PATH="${HERE}/bin:${PATH}"
export PATH

# --- Fake MiSTer state ------------------------------------------------------
export MISTER_CORENAME="${TMP}/CORENAME"
export MISTER_RBFNAME="${TMP}/RBFNAME"
export MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH"
export MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT"
export MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_INI="${TMP}/MiSTer.ini"
export TITLE_INDEX="${TMP}/titleindex"
export CORETYPE_MAP="${TMP}/coretypes"

. "${ROOT}/tty2oled-meta.sh"

# --- Serial capture ---------------------------------------------------------
# The daemon writes each command with ">", which on a real character device
# appends to the stream but on a regular file would truncate it. A FIFO with a
# re-opening reader models the device faithfully, so the captured bytes are
# exactly what the firmware would see.
CAPTURE="${TMP}/tty-capture"
FIFO="${TMP}/tty-fifo"
rm -f "${FIFO}" "${CAPTURE}"
mkfifo "${FIFO}"
: > "${CAPTURE}"
( while :; do cat "${FIFO}"; done >> "${CAPTURE}" ) 2>/dev/null &
READER_PID=$!
cleanup() { kill "${READER_PID}" 2>/dev/null; rm -f "${FIFO}"; }
trap cleanup EXIT

# Give the reader a moment to drain before asserting on what was written.
sync_capture() { sleep 0.25; }

# --- Daemon settings the functions read -------------------------------------
TTYDEV="${FIFO}"
WAITSECS="0"
USBMODE="yes"
SHOW_METADATA="yes"
METADATA_INTERVAL="12"
debug="false"
debugfile="${TMP}/debuglog"
iconfolder="${TMP}/pics/ICON"
iconfolder_pri="${TMP}/pics_pri/ICON"

dbug() { :; }

# Load only the function definitions from the daemon, stopping at the main
# block so sourcing it does not start the daemon itself.
eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"

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

reset_capture() {
  sync_capture
  : > "${CAPTURE}"
  rm -f "${TMP}/STARTPATH" "${TMP}/FULLPATH" "${TMP}/FILESELECT" \
        "${TMP}/GAMEID" "${TMP}/titleindex" "${TMP}/coretypes"
}
captured() { sync_capture; cat "${CAPTURE}"; }

# ---------------------------------------------------------------------------
section "arcade: CMDMETA carries the MRA metadata"
# ---------------------------------------------------------------------------
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
sendmeta "dkong"
out="$(captured)"
ok "single command line" "$(sync_capture; wc -l < "${CAPTURE}")" "1"
contains "kind 1, interval 12" "${out}" "CMDMETA,1,12,"
contains "title"               "${out}" "Donkey Kong (US set 1)"
contains "year field"          "${out}" "|Year=1981"
contains "manufacturer field"  "${out}" "|Manufacturer=Nintendo of America"
contains "category field"      "${out}" "|Category=Platform"
contains "setname field"       "${out}" "|Set=dkong"

# ---------------------------------------------------------------------------
section "console: CMDMETA plus icon transfer"
# ---------------------------------------------------------------------------
reset_capture
printf '/media/fat/_Console/SNES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/SNES/Super Mario World (USA).sfc\n' > "${TMP}/FULLPATH"
printf 'selected\n' > "${TMP}/FILESELECT"

# A fake 86x64 icon: 3 header lines then 2752 bytes of hex, as .gsc files are
# stored (the daemon skips the header with tail -n +4).
{
  echo "#define icon_width 86"
  echo "#define icon_height 64"
  echo "static unsigned char icon_bits[] = {"
  head -c 2752 /dev/zero | xxd -p
} > "${iconfolder}/SNES.gsc"

sendmeta "SNES"
out="$(captured)"
contains "kind 2"        "${out}" "CMDMETA,2,12,"
contains "title"         "${out}" "Super Mario World"
contains "system field"  "${out}" "|System=SNES"
contains "region field"  "${out}" "|Region=USA"

reset_capture
printf '/media/fat/_Console/SNES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/SNES/Super Mario World (USA).sfc\n' > "${TMP}/FULLPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
sendmeta "SNES" >/dev/null
sync_capture; : > "${CAPTURE}"
sendicon "SNES"
ok "icon payload is exactly 2752 bytes" \
   "$(sync_capture; stat -c%s "${CAPTURE}" | awk '{print $1-8}')" "2752"
contains "CMDICON sent" "$(sync_capture; head -c 7 "${CAPTURE}")" "CMDICON"

# ---------------------------------------------------------------------------
section "console: pics_pri icon overrides the generated one"
# ---------------------------------------------------------------------------
{
  echo "#define icon_width 86"; echo "#define icon_height 64"
  echo "static unsigned char icon_bits[] = {"
  head -c 2752 /dev/zero | xxd -p
} > "${iconfolder_pri}/SNES.gsc"
findicon "SNES"
ok "pri folder wins" "${ICONFILE}" "${iconfolder_pri}/SNES.gsc"
rm -f "${iconfolder_pri}/SNES.gsc"
findicon "SNES"
ok "falls back to generated" "${ICONFILE}" "${iconfolder}/SNES.gsc"

findicon "NoSuchCore"
ok "missing icon returns empty" "${ICONFILE}" ""

# ---------------------------------------------------------------------------
section "computer cores turn metadata mode off"
# ---------------------------------------------------------------------------
reset_capture
printf '/media/fat/_Computer/Amiga_20240101.rbf\n' > "${TMP}/STARTPATH"
sendmeta "Minimig"
rc=$?
ok "returns non-zero"   "${rc}" "1"
ok "sends CMDMETAOFF"   "$(sync_capture; tr -d '\r\n' < "${CAPTURE}")" "CMDMETAOFF"

# ---------------------------------------------------------------------------
section "sanitising: protocol characters cannot escape a field"
# ---------------------------------------------------------------------------
ok "pipe removed"   "$(metasanitize 'a|b')"  "a b"
ok "comma removed"  "$(metasanitize 'a,b')"  "a b"
ok "equals removed" "$(metasanitize 'a=b')"  "a b"
ok "newline removed" "$(printf '%s' "$(metasanitize "$(printf 'a\nb')")")" "ab"
ok "tab removed"     "$(printf '%s' "$(metasanitize "$(printf 'a\tb')")")" "ab"
ok "plain text untouched" "$(metasanitize 'Street Fighter II: The World Warrior')" \
                          "Street Fighter II: The World Warrior"

# A title full of protocol characters must still produce exactly one line.
reset_capture
cat > "${TMP}/evil.mra" <<'EOF'
<misterromdescription>
	<name>Evil|Game,Name=Here</name>
	<setname>evil</setname>
	<year>1984</year>
</misterromdescription>
EOF
printf '%s\n' "${TMP}/evil.mra" > "${TMP}/STARTPATH"
sendmeta "evil"
ok "still one line"        "$(sync_capture; wc -l < "${CAPTURE}")" "1"
contains "separators neutralised" "$(captured)" "CMDMETA,1,12,Evil Game Name Here|"

# ---------------------------------------------------------------------------
section "master switch"
# ---------------------------------------------------------------------------
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
SHOW_METADATA="no"
sendmeta "dkong"
ok "disabled sends nothing" "$(sync_capture; stat -c%s "${CAPTURE}")" "0"
SHOW_METADATA="yes"

reset_capture
USBMODE="no"
sendmeta "dkong"
ok "SD mode sends nothing" "$(sync_capture; stat -c%s "${CAPTURE}")" "0"
USBMODE="yes"

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
