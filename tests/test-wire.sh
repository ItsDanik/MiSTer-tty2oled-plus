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
  rm -f "${TMP}/STARTPATH" "${TMP}/FULLPATH" "${TMP}/CURRENTPATH" \
        "${TMP}/FILESELECT" "${TMP}/GAMEID" "${TMP}/titleindex" "${TMP}/coretypes"
  # sendmeta now suppresses an identical repeat, so clear that memory too or
  # tests would silently depend on the order they run in.
  META_WIRE_LAST=""
  corenamefile="${MISTER_CORENAME}"
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
# kind, interval, then the two counts: how many fields are pinned and how
# many the card pairs two to a row.
contains "kind 1, interval 12" "${out}" "CMDMETA,1,12,2,6,"
contains "title"               "${out}" "Donkey Kong (US set 1)"
contains "year field"          "${out}" "|Year=1981"
contains "abbreviated label"   "${out}" "|Manufctr=Nintendo of America"
contains "setname field"       "${out}" "|Set=dkong"

# A full MRA puts eleven fields on one line - more than the card has rows,
# which is the point: the firmware pages through them. It still has to be a
# single command, and still comma-free after the header.
reset_capture
printf '%s\n' "${FIX}/mra/tmnt.mra" > "${TMP}/STARTPATH"
sendmeta "tmnt"
out="$(captured)"
ok "still one command line" "$(sync_capture; wc -l < "${CAPTURE}")" "1"
ok "eleven fields" "$(printf '%s' "${out}" | tr -cd '|' | wc -c)" "11"
contains "eight paired, two pinned" "${out}" "CMDMETA,1,12,2,8,"
contains "players"  "${out}" "|Players=4"
contains "controls" "${out}" "|Controls=8-way"
contains "buttons"  "${out}" "|Buttons=Attack/Jump"
# Everything past the header is comma-free, which is what makes the two
# counts in it unambiguous.
ok "no comma past the header" \
   "$(printf '%s' "${out}" | cut -d, -f6- | tr -cd ',' | wc -c)" "0"

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
contains "separators neutralised" "$(captured)" ",Evil Game Name Here|"

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
section "identical metadata is not resent"
# ---------------------------------------------------------------------------
# The daemon now wakes on game-state changes too, and MiSTer rewrites those
# files while the user is only browsing. Resending the same line would restart
# the card's scroll and animation for no reason.
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
sendmeta "dkong"
ok "first send goes out"      "$(sync_capture; wc -l < "${CAPTURE}")" "1"
sendmeta "dkong"
ok "identical repeat suppressed" "$(sync_capture; wc -l < "${CAPTURE}")" "1"
sendmeta "dkong" force
ok "force resends"            "$(sync_capture; wc -l < "${CAPTURE}")" "2"

reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
sendmeta "dkong"
printf '%s\n' "${FIX}/mra/sf2.mra" > "${TMP}/STARTPATH"
sendmeta "sf2"
ok "a real change still sends" "$(sync_capture; wc -l < "${CAPTURE}")" "2"

# ---------------------------------------------------------------------------
section "stale game state from a previous core is ignored"
# ---------------------------------------------------------------------------
# MiSTer never clears FULLPATH/FILESELECT/GAMEID, so a core started from the
# menu used to inherit the previous core's game and show its title and CRC
# before anything had been loaded.
reset_capture
mkdir -p "${TMP}/games"
printf '%s\n' "${TMP}/games/Some Old Game (USA).sfc" > "${TMP}/FULLPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
printf 'CRC32: CBC7131F\n' > "${TMP}/GAMEID"
sleep 0.05
printf 'GAMEBOY\n' > "${TMP}/CORENAME"          # core written AFTER the game state
printf 'GAMEBOY\n' > "${TMP}/RBFNAME"
printf 'console\n' > "${TMP}/coretypes" 2>/dev/null || true
printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
sendmeta "GAMEBOY" force            # a core change, which is when this applies
out="$(captured)"
contains "metadata mode turned off" "${out}" "CMDMETAOFF"
case "${out}" in
  *CBC7131F*) FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m stale CRC leaked into the card\n' ;;
  *) PASS=$((PASS+1)); printf '  \033[32mok\033[0m   stale CRC not shown\n' ;;
esac
case "${out}" in
  *"Some Old Game"*) FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m stale title leaked into the card\n' ;;
  *) PASS=$((PASS+1)); printf '  \033[32mok\033[0m   stale title not shown\n' ;;
esac
case "${out}" in
  *CMDMETA,*) FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m sent a metadata card with no game loaded\n' ;;
  *) PASS=$((PASS+1)); printf '  \033[32mok\033[0m   no card sent, artwork stays\n' ;;
esac

reset_capture
printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
printf 'GAMEBOY\n' > "${TMP}/CORENAME"
printf 'GAMEBOY\n' > "${TMP}/RBFNAME"
sleep 0.05
printf '%s\n' "${TMP}/games/Tetris (World).gb" > "${TMP}/FULLPATH"   # game AFTER the core
printf 'selected\n' > "${TMP}/FILESELECT"
sendmeta "GAMEBOY"
contains "a freshly loaded game is used" "$(captured)" "Tetris"

# ---------------------------------------------------------------------------
section "watch list covers only files that exist"
# ---------------------------------------------------------------------------
# inotifywait exits immediately on a missing path, which would spin the loop.
reset_capture
printf 'GAMEBOY\n' > "${TMP}/CORENAME"
rm -f "${TMP}/FULLPATH" "${TMP}/GAMEID" "${TMP}/FILESELECT" "${TMP}/STARTPATH"
watch="$(metawatchlist)"
ok "only CORENAME watched" "${watch}" "${TMP}/CORENAME"
printf 'x\n' > "${TMP}/FULLPATH"
watch="$(metawatchlist)"
contains "FULLPATH picked up once it appears" "${watch}" "${TMP}/FULLPATH"
for f in ${watch}; do
  [ -e "${f}" ] || { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m watch list names a missing file: %s\n' "${f}"; }
done
PASS=$((PASS+1)); printf '  \033[32mok\033[0m   every watched path exists\n'

# ---------------------------------------------------------------------------
section "MiSTer splits the selection across FULLPATH and CURRENTPATH"
# ---------------------------------------------------------------------------
# Taken verbatim from a real MiSTer: FULLPATH is the containing folder and
# CURRENTPATH the file name. Reading FULLPATH alone titled the game "GAMEBOY".
reset_capture
printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
printf 'GAMEBOY\n' > "${TMP}/CORENAME"
printf 'GAMEBOY\n' > "${TMP}/RBFNAME"
sleep 0.05
printf 'games/GAMEBOY\n'               > "${TMP}/FULLPATH"
printf 'A-mazing Tater (USA).gb\n'     > "${TMP}/CURRENTPATH"
printf 'selected\n'                    > "${TMP}/FILESELECT"
printf 'CRC32: D229AC62\n'             > "${TMP}/GAMEID"
sendmeta "GAMEBOY"
out="$(captured)"
contains "title comes from the file name" "${out}" "A-mazing Tater"
contains "region parsed"                  "${out}" "Region=USA"
contains "format parsed"                  "${out}" "Format=GB"
case "${out}" in
  *"CMDMETA,2,12,GAMEBOY|"*) FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m titled from the folder again\n' ;;
  *) PASS=$((PASS+1)); printf '  \033[32mok\033[0m   not titled from the folder\n' ;;
esac

# Fallback: a setup where FULLPATH really does hold the whole path.
reset_capture
printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
printf 'GAMEBOY\n' > "${TMP}/CORENAME"
sleep 0.05
printf '/media/fat/games/GAMEBOY/Tetris (World).gb\n' > "${TMP}/FULLPATH"
rm -f "${TMP}/CURRENTPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
sendmeta "GAMEBOY"
contains "falls back to FULLPATH" "$(captured)" "Tetris"

# ---------------------------------------------------------------------------
section "console core with no game keeps the full-screen artwork"
# ---------------------------------------------------------------------------
# A console core sitting at its menu has nothing to describe. sendmeta must
# return non-zero so senddata falls through to upstream's picture path.
reset_capture
printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
printf 'GAMEBOY\n' > "${TMP}/CORENAME"
printf 'GAMEBOY\n' > "${TMP}/RBFNAME"
rm -f "${TMP}/FULLPATH" "${TMP}/FILESELECT" "${TMP}/GAMEID"
if sendmeta "GAMEBOY"; then
  FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m returned success, caller would skip the picture\n'
else
  PASS=$((PASS+1)); printf '  \033[32mok\033[0m   returns non-zero so the picture is sent\n'
fi
contains "CMDMETAOFF sent" "$(captured)" "CMDMETAOFF"
ok "no metadata card" "$(captured | grep -c 'CMDMETA,' || true)" "0"

# ---------------------------------------------------------------------------
section "brightness: the fade time goes ahead of the first contrast"
# ---------------------------------------------------------------------------
# The firmware fades every contrast change over CONTRAST_FADE_MS. That has to
# arrive before the first CMDCON, or the daemon's very first change fades at
# the firmware's built-in speed instead of the user's.
reset_capture
CONTRAST="255"; CONTRAST_FADE_MS="1200"; TRANSITION_FADE_MS="1500"; TRANSITION_BLANK_MS="700"
stty() { :; }                        # a FIFO has no line settings to set
ROTATE="no"; BAUDRATE="115200"; TTYPARAM="raw"
serialinit
ok "startup sends both fade settings, then the contrast" \
   "$(captured | tr -d '\r' | grep -E '^CMD(FADE|TFADE|CON)' | tr '\n' ' ')" "CMDFADE,1200 CMDTFADE,1500,700 CMDCON,255 "
unset -f stty

reset_capture
unset CONTRAST_FADE_MS
sendfade
ok "an ini without CONTRAST_FADE_MS still gets a fade time" "$(captured | tr -d '\r\n')" "CMDFADE,800"

# ---------------------------------------------------------------------------
section "dimming: DIM_CONTRAST is a level, DIM_PERCENT is gone"
# ---------------------------------------------------------------------------
reset_capture
DIM_AFTER="90"; DIM_CONTRAST="80"; DIM_WAKE="-1"; DIM_FADE_MS="7000"; unset DIM_PERCENT
OUT="$(senddim)"
ok "CMDDIM carries the dim level and its own fade time" "$(captured | tr -d '\r\n')" "CMDDIM,90,80,-1,7000"
ok "and nothing is said about the old setting" "${OUT}" ""

reset_capture
DIM_PERCENT="50"
OUT="$(senddim)"
ok "a leftover DIM_PERCENT is not sent" "$(captured | tr -d '\r\n')" "CMDDIM,90,80,-1,7000"
contains "and the log says what replaced it" "${OUT}" "set DIM_CONTRAST (0..255)"
unset DIM_PERCENT
reset_capture
unset DIM_FADE_MS
senddim >/dev/null
ok "an ini without DIM_FADE_MS still sends the 6s default" "$(captured | tr -d '\r\n')" "CMDDIM,90,80,-1,6000"

# The shipped defaults: full brightness, dimming to 80 of 255.
ok "CONTRAST defaults to full" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${CONTRAST}")" "255"
ok "DIM_CONTRAST defaults to 80" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${DIM_CONTRAST}")" "80"
ok "the system ini no longer sets DIM_PERCENT" "$(grep -c '^DIM_PERCENT=' "${ROOT}/tty2oled-system.ini")" "0"
ok "going dim defaults to 6s" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${DIM_FADE_MS}")" "6000"
ok "TRANSITION ships as the Fade" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${TRANSITION}")" "-2"
ok "every other fade defaults to 0.8s" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${CONTRAST_FADE_MS} ${TRANSITION_FADE_MS}")" "800 800"

# ---------------------------------------------------------------------------
section "transitions: -2 reaches the firmware, and the ini lists every effect"
# ---------------------------------------------------------------------------
reset_capture
TRANSITION="-2"; USBMODE="yes"
picturefolder="${TMP}/pics"; picturefolder_pri="${TMP}/pics_pri"
USE_GSC_PICTURE="yes"; USE_US_PICTURE="no"; USE_TEXT_PICTURE="no"; USE_RANDOM_ALT="no"
newcore="NES"; META_ICON=""
mkdir -p "${TMP}/pics/GSC"
printf '#\n#\n#\n00\n' > "${TMP}/pics/GSC/NES.gsc"
senddata "NES" >/dev/null 2>&1
contains "CMDCOR carries -2 as it is" "$(captured | grep -a '^CMDCOR')" "CMDCOR,NES,-2"
rm -f "${TMP}/pics/GSC/NES.gsc"
TRANSITION="-1"

reset_capture
unset TRANSITION_FADE_MS TRANSITION_BLANK_MS
sendtfade
ok "an ini without the Fade settings still sends the defaults" "$(captured | tr -d '\r\n')" "CMDTFADE,800,1000"

# The list in the ini is what people read instead of the sketch, so it has to
# name every effect the sketch has - no more, no fewer.
SKETCH="${ROOT}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
MAXEFFECT="$(sed -n 's/^const uint8_t minEffect=1, maxEffect=\([0-9]*\);.*/\1/p' "${SKETCH}")"
CASES="$(awk '/^void oled_drawlogo\(uint8_t e\) *\{/{on=1} on && /^    case [0-9]+:/{n=$2; sub(":","",n); print n} on && /^    default:/{exit}' "${SKETCH}" | sort -n | tr '\n' ' ')"
LISTED="$(sed -n '/^# How one picture replaces the last/,/^TRANSITION=/p' "${ROOT}/tty2oled-system.ini" \
          | grep -oE '(^#|[[:space:]]) +-?[0-9]+  [A-Za-z]' | grep -oE -- '-?[0-9]+' | sort -n | tr '\n' ' ')"
ok "the sketch's effects are 1..maxEffect" "${CASES}" "$(seq 1 "${MAXEFFECT}" | tr '\n' ' ')"
ok "and the ini lists exactly those, plus -2, -1 and 0" "${LISTED}" "-2 -1 0 ${CASES}"

# ---------------------------------------------------------------------------
section "BOOTSCREEN_AS_MENU: the menu asks for the boot screen, and sends no picture"
# ---------------------------------------------------------------------------
picturefolder="${TMP}/pics"; picturefolder_pri="${TMP}/pics_pri"
USE_GSC_PICTURE="yes"; USE_US_PICTURE="no"; USE_TEXT_PICTURE="no"; USE_RANDOM_ALT="no"
META_ICON=""; TRANSITION="-2"
mkdir -p "${TMP}/pics/GSC"
printf '#\n#\n#\n00\n' > "${TMP}/pics/GSC/MENU.gsc"
printf '#\n#\n#\n00\n' > "${TMP}/pics/GSC/NES.gsc"

reset_capture
BOOTSCREEN_AS_MENU="yes"
senddata "MENU" >/dev/null 2>&1
ok "the menu gets CMDBOOTPIC" "$(captured | grep -a '^CMDBOOTPIC' | tr -d '\r')" "CMDBOOTPIC,MENU,-2"
ok "and no CMDCOR" "$(captured | grep -ac '^CMDCOR')" "0"
ok "and no picture bytes" "$(captured | grep -avc '^CMD')" "0"

reset_capture
senddata "NES" >/dev/null 2>&1
contains "any other core still sends its picture" "$(captured | grep -a '^CMDCOR')" "CMDCOR,NES,-2"

reset_capture
BOOTSCREEN_AS_MENU="no"
senddata "MENU" >/dev/null 2>&1
contains "with the setting off, the menu sends MENU.gsc" "$(captured | grep -a '^CMDCOR')" "CMDCOR,MENU,-2"
ok "and no CMDBOOTPIC" "$(captured | grep -ac '^CMDBOOTPIC')" "0"

reset_capture
unset BOOTSCREEN_AS_MENU
senddata "MENU" >/dev/null 2>&1
ok "an ini without the setting gets it on" "$(captured | grep -ac '^CMDBOOTPIC')" "1"
ok "and the shipped ini has it on" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${BOOTSCREEN_AS_MENU}")" "yes"
rm -f "${TMP}/pics/GSC/MENU.gsc" "${TMP}/pics/GSC/NES.gsc"
TRANSITION="-1"

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
