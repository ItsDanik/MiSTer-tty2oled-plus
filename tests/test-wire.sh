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
mkdir -p "${TMP}" "${TMP}/pics/icon" "${TMP}/pics/banner" "${TMP}/pics/arcade" "${TMP}/pics/user"

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
SHOW_METADATA="yes"
METADATA_INTERVAL="12"
debug="false"
debugfile="${TMP}/debuglog"
iconfolder="${TMP}/pics/icon"
bannerfolder="${TMP}/pics/banner"
userbannerfolder="${TMP}/pics/user"
wheelpack="${TMP}/pics/arcade/wheels.bin"
wheelindex="${TMP}/pics/arcade/wheels.idx"

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
skip() { printf "  \033[33mskip\033[0m %s (%s)\n" "${1}" "${2}"; }

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
contains "nine paired, two pinned" "${out}" "CMDMETA,1,12,2,9,"
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

findicon "NoSuchCore"
ok "missing icon returns empty" "${ICONFILE}" ""

# An icon has one home. pics/user is 256x64 banners named after the core, so
# an 86x64 file of the same name in there is indistinguishable from one until
# the firmware has read 2752 bytes of an 8192-byte picture.
printf '#\n#\n#\n00\n' > "${userbannerfolder}/SNES.gsc"
findicon "SNES"
ok "a user banner is never read as an icon" "${ICONFILE}" "${iconfolder}/SNES.gsc"
rm -f "${userbannerfolder}/SNES.gsc"

# ---------------------------------------------------------------------------
section "banners: pics/user, pics/banner and the order between them"
# ---------------------------------------------------------------------------
# The folders were flattened in 0.5.8b. pics/user is the user's own and is the
# one folder no update writes into, which is what makes it the right place for
# a replacement picture - editing pics/banner is undone by the next release.
printf '#\n#\n#\n00\n' > "${bannerfolder}/NES.gsc"
printf '#\n#\n#\n11\n' > "${userbannerfolder}/NES.gsc"

PRIORITIZE_USER_BANNERS="yes"
findbanner "NES"
ok "yours wins by default" "${BANNERFILE}" "${userbannerfolder}/NES.gsc"
PRIORITIZE_USER_BANNERS="no"
findbanner "NES"
ok "and the pack wins when told to" "${BANNERFILE}" "${bannerfolder}/NES.gsc"
rm -f "${userbannerfolder}/NES.gsc"
findbanner "NES"
ok "either way the other is the fallback" "${BANNERFILE}" "${bannerfolder}/NES.gsc"
PRIORITIZE_USER_BANNERS="yes"
findbanner "NES"
ok "both ways round" "${BANNERFILE}" "${bannerfolder}/NES.gsc"

# The core name is trimmed a character at a time, so a core whose name carries
# a suffix still finds the base picture.
findbanner "NESabc"
ok "a longer core name trims down to the base picture" "${BANNERFILE}" "${bannerfolder}/NES.gsc"

# ...and the trimming runs per folder rather than across both, which is what
# makes the priority absolute. Searching both folders at each length instead
# would let the pack's longer match win over a shorter banner of yours - not
# wrong exactly, but not something anyone could predict from a setting called
# PRIORITIZE_USER_BANNERS.
printf '#\n#\n#\n11\n' > "${userbannerfolder}/NES.gsc"
printf '#\n#\n#\n11\n' > "${bannerfolder}/NESabc.gsc"
findbanner "NESabc"
ok "your shorter name still beats the pack's exact one" "${BANNERFILE}" "${userbannerfolder}/NES.gsc"
PRIORITIZE_USER_BANNERS="no"
findbanner "NESabc"
ok "and the other way round when the pack comes first" "${BANNERFILE}" "${bannerfolder}/NESabc.gsc"
PRIORITIZE_USER_BANNERS="yes"
rm -f "${bannerfolder}/NESabc.gsc"
rm -f "${userbannerfolder}/NES.gsc"

findbanner "NoSuchCore"
ok "no banner at all returns empty" "${BANNERFILE}" ""

# "exact" turns the trimming off. update_all is looked up whole, or the prefix
# search settles on some unrelated arcade set starting with "upd".
printf '#\n#\n#\n00\n' > "${bannerfolder}/upd.gsc"
findbanner "update_all" exact
ok "an exact lookup does not trim" "${BANNERFILE}" ""
findbanner "update_all"
ok "and the trimming one would have" "${BANNERFILE}" "${bannerfolder}/upd.gsc"
rm -f "${bannerfolder}/upd.gsc"

# ---------------------------------------------------------------------------
section "arcade: the wheel pack, by whole set name"
# ---------------------------------------------------------------------------
# Three frames, each one byte value throughout so a frame is recognisable on
# the wire: 0a (a lone newline, like the picture fixtures above), 11 and 22.
{ head -c 8192 /dev/zero | tr '\0' '\n'
  head -c 8192 /dev/zero | tr '\0' '\021'
  head -c 8192 /dev/zero | tr '\0' '\042'; } > "${wheelpack}"
cat > "${wheelindex}" <<'EOIDX'
# tty2oled+ picture index for wheels.bin, written by tools/gscpack.py
# frames 3
dkong|0
gunlock|2
nes|1
pacman|1
rayforcej|2
sf2|0
sf2ua|0
EOIDX
frame_bytes() { dd if="${wheelpack}" bs=8192 skip="${1}" count=1 2>/dev/null | od -An -tx1 | tr -s ' \n' ' ' | cut -c1-12; }

reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
findpicture "sf2"
ok "an arcade set is found in the pack" "${PICFRAME}:${PICFILE}" "0:"
findpicture "sf2ua"
ok "a set that shares its parent's picture points at the same frame" "${PICFRAME}" "0"
findpicture "rayforcej"
ok "and one whose picture is kept under an unrelated name" "${PICFRAME}" "2"
findpicture "SF2"
ok "the name is matched without case, as exFAT file names were" "${PICFRAME}" "0"

# Never trimmed: two thirds of the MAME sets share a picture, and a prefix of
# a set name finds a different game's wheel for hundreds of them.
findpicture "sf2xyz"; r=$?
ok "a set the pack does not have is not trimmed to one it does" "${r}:${PICFRAME}:${PICFILE}" "1::"
# And the banner folder is never searched for an arcade core: it holds
# console and computer banners only, and nothing there is a game.
printf '#\n#\n#\n00\n' > "${bannerfolder}/sf2xyz.gsc"
findpicture "sf2xyz"; r=$?
ok "nor looked for among the core banners" "${r}:${PICFILE}" "1:"
rm -f "${bannerfolder}/sf2xyz.gsc"

# pics/user comes first, as it does for every core - a picture of your own
# for a set beats the pack's - and PRIORITIZE_USER_BANNERS turns it round.
printf '#\n#\n#\n33\n' > "${userbannerfolder}/pacman.gsc"
PRIORITIZE_USER_BANNERS="yes"
findpicture "pacman"
ok "yours beats the pack" "${PICFILE}:${PICFRAME}" "${userbannerfolder}/pacman.gsc:"
PRIORITIZE_USER_BANNERS="no"
findpicture "pacman"
ok "and the pack wins when told to" "${PICFILE}:${PICFRAME}" ":1"
findpicture "puckman"; r=$?
ok "with yours as the fallback, by the same trimming as any banner of yours" \
   "${r}:${PICFILE}" "1:"
PRIORITIZE_USER_BANNERS="yes"
rm -f "${userbannerfolder}/pacman.gsc"

# A console core never looks in the pack, even for a name it holds.
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '#\n#\n#\n00\n' > "${bannerfolder}/NES.gsc"
findpicture "NES"
ok "a console core's picture is its banner" "${PICFILE}:${PICFRAME}" "${bannerfolder}/NES.gsc:"
rm -f "${bannerfolder}/NES.gsc"

# An index from one run beside a pack from another: a frame past the end of
# the .bin would leave the firmware waiting for bytes that never come.
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
printf 'gone|3\n' >> "${wheelindex}"
findpicture "gone"; r=$?
ok "a frame the .bin does not have is not sent" "${r}:${PICFRAME}" "1:"
mv "${wheelpack}" "${wheelpack}.away"
findpicture "sf2"; r=$?
ok "and no pack at all is no picture, not an error" "${r}:${PICFRAME}" "1:"
mv "${wheelpack}.away" "${wheelpack}"

# On the wire: the header, then exactly the frame's 8192 bytes.
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
TRANSITION="-1"; BOOTSCREEN_AS_MENU="yes"
SHOW_METADATA="no"; META_KIND="left-alone"
senddata "pacman" >/dev/null 2>&1
SHOW_METADATA="yes"
ok "the wheel goes out as CMDCOR and its frame" \
   "$(captured | head -c 40 | head -n1)" "CMDCOR,pacman,${TRANSITION}"
ok "8192 bytes of it, and nothing else" \
   "$(captured | tail -n +2 | wc -c | tr -d ' ')" "8192"
ok "the right frame" "$(captured | tail -n +2 | od -An -tx1 | tr -s ' \n' ' ' | cut -c1-12)" \
   "$(frame_bytes 1)"
# With the metadata display off, META_KIND is never set - the lookup asks
# the core's kind itself, and leaves META_KIND as it found it.
ok "without touching META_KIND" "${META_KIND}" "left-alone"
META_KIND=""

reset_capture
SHOW_METADATA="no"
senddata "notinpack" >/dev/null 2>&1
SHOW_METADATA="yes"
ok "a set the pack lacks goes out as its name, as text" "$(captured)" "notinpack"

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
ok "DEL and the other control bytes removed" "$(metasanitize "$(printf 'a\001b\037c\177d')")" "abcd"
ok "a letter beyond ASCII kept, byte for byte" "$(metasanitize 'Café')" "Café"
metasan SAN 'x|y,z=w'
ok "metasan: the same, into a variable" "${SAN}" "x y z w"
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
# A core change resends regardless: its CMDMETAOFF has just reset the firmware.
senddata "dkong" >/dev/null 2>&1
ok "a core change resends"    "$(captured | grep -ac '^CMDMETA,')" "2"

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
senddata "GAMEBOY" >/dev/null 2>&1  # a core change, which is when this applies
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

# The fade-slides' numbers come from the header that defines them, so the ini
# and the firmware cannot drift apart about what is a fade and what is a wipe.
FT="${ROOT}/MiSTer_SSD1322_USB/fadetransition.h"
SLIDE_FIRST="$(sed -n 's/^#define EFFECT_SLIDE_FIRST  *\([0-9]*\).*/\1/p' "${FT}")"
SLIDE_LAST="$(sed -n 's/^#define EFFECT_SLIDE_LAST  *\([0-9]*\).*/\1/p' "${FT}")"

# The shipped defaults: full brightness, dimming to 80 of 255.
ok "CONTRAST defaults to full" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${CONTRAST}")" "255"
ok "DIM_CONTRAST defaults to 80" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${DIM_CONTRAST}")" "80"
ok "the system ini no longer sets DIM_PERCENT" "$(grep -c '^DIM_PERCENT=' "${ROOT}/tty2oled-system.ini")" "0"
ok "going dim defaults to 6s" "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${DIM_FADE_MS}")" "6000"
# The shipped TRANSITION is a fade of some kind rather than a wipe - -2, or
# one of the fade-slides - which is the whole of this fork's picture-changing
# story. Which one is a matter of taste and may move between releases; that it
# is not a wipe is not. Pinned against the firmware's own range so the ini and
# the header cannot disagree about what counts.
SHIPPED_T="$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${TRANSITION}")"
ok "TRANSITION ships as a fade, not a wipe" \
   "$([ "${SHIPPED_T}" = "-2" ] || { [ "${SHIPPED_T}" -ge "${SLIDE_FIRST}" ] 2>/dev/null && [ "${SHIPPED_T}" -le "${SLIDE_LAST}" ]; } && echo yes || echo no)" "yes"
ok "and it is one the ini lists" \
   "$(sed -n '/^# How one picture replaces the last/,/^TRANSITION=/p' "${ROOT}/tty2oled-system.ini" \
      | grep -cE "(^#|[[:space:]]) +${SHIPPED_T}  [A-Za-z]")" "1"
# Every fade time the ini ships has to be inside the firmware's cap, or the
# firmware silently clamps it and the ini is describing something else.
TCAP="$(sed -n 's/^#define TFADE_MS_MAX  *\([0-9]*\).*/\1/p' "${ROOT}/MiSTer_SSD1322_USB/fadetransition.h")"
BAD=""
for v in CONTRAST_FADE_MS TRANSITION_FADE_MS TRANSITION_BLANK_MS; do
  n="$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; eval echo "\${${v}}")"
  { [ "${n}" -ge 0 ] && [ "${n}" -le "${TCAP}" ]; } 2>/dev/null || BAD="${BAD} ${v}=${n}"
done
ok "every shipped fade time is one the firmware will take" "${BAD}" ""

# ---------------------------------------------------------------------------
section "the artwork pack is one folder of one format"
# ---------------------------------------------------------------------------
# 0.4.10b finished upstream's half-done migration from 1bpp .xbm to 4bpp .gsc.
# The daemon looks in pics/user, pics/banner and pics/icon for files, and in
# the wheel pack in pics/arcade, and nowhere else, so anything that is not a
# .gsc among the banners is unreachable by construction, and a .gsc that does
# not decode to exactly 8192 bytes is dropped by the firmware as a truncated
# transfer - silently, which is why it is worth a test.
ok "pics/ holds the four folders" "$(ls "${ROOT}/pics" | tr '\n' ' ')" "arcade banner icon user "
ok "and nothing among the banners and icons but .gsc files" \
   "$(find "${ROOT}/pics/banner" "${ROOT}/pics/icon" -type f ! -name '*.gsc' | head -n3 | tr '\n' ' ')" ""
ok "pics/arcade is the pack and its index, nothing else" \
   "$(ls "${ROOT}/pics/arcade" | tr '\n' ' ')" "wheels.bin wheels.idx "

# The alternatives and the dice between them are gone, and so are the arcade
# marquees: an arcade core's picture is its wheel, and pics/banner is never
# searched for one, so a marquee left there would be 128KB of card for a
# picture nothing can reach.
ok "no alternatives among the banners" "$(ls "${ROOT}/pics/banner" | grep -c '_alt')" "0"
# N64, NEOGEO and Saturn are MAME set names too, and console cores in
# coretypes.ini: those are banners, and stay.
MARQUEES="$(ls "${ROOT}/pics/banner" | sed 's/\.gsc$//' | tr 'A-Z' 'a-z' \
            | grep -Fxf <(grep -v '^#' "${ROOT}/pics/arcade/wheels.idx" | cut -d'|' -f1) \
            | grep -vixFf <(grep -v '^[[:space:]]*#' "${ROOT}/coretypes.ini" | grep '=' | cut -d= -f1) \
            | head -n5 | tr '\n' ' ')"
ok "and no banner but a core's is named after a set the wheel pack has" "${MARQUEES}" ""

# The pack itself: every frame whole, every line pointing inside it, every
# frame used, and names lower case and unique - the lookup lower-cases a core
# name, and a line it could never match is a picture nobody sees.
PACKCHECK="$(python3 - "${ROOT}/pics/arcade" <<'EOPY'
import os, sys
d = sys.argv[1]
size = os.path.getsize(os.path.join(d, "wheels.bin"))
frames, names, used, bad = None, set(), set(), []
for line in open(os.path.join(d, "wheels.idx")):
    line = line.rstrip("\n")
    if line.startswith("# frames "):
        frames = int(line.split()[2])
    if line.startswith("#"):
        continue
    name, _, frame = line.partition("|")
    if name != name.lower(): bad.append(f"{name}:case")
    if name in names: bad.append(f"{name}:twice")
    names.add(name)
    used.add(int(frame))
if frames is None: bad.append("no frames line")
elif size != frames * 8192: bad.append(f"bin is {size} bytes, not {frames} x 8192")
elif used != set(range(frames)): bad.append(f"{frames - len(used)} frames unused, or a line past the end")
print(" ".join(bad[:5]))
EOPY
)"
ok "the wheel pack and its index agree" "${PACKCHECK}" ""

# The banners at large, since a picture that is not exactly 8192 bytes is a
# short readBytes in the firmware, which draws the transfer-error bitmap - the
# core looks broken rather than unpainted. upstream's invinco.gsc was one: 6976
# bytes of what renders as static, and it had been showing a transfer error for
# as long as it has been in the pack. One python pass rather than a pipe per
# file, which is the difference between a second and a minute.
#
# The frontends' pictures, and update_all's, may also be 256x54 - 6912 bytes:
# the daemon sends those as their top 54 rows and a black band, whatever the
# file's height (senddata, sendupdateall).
SHORT="$(python3 - "${ROOT}/pics/banner" <<'EOPY'
import glob, os, sys
def decode(b):
    out = bytearray(); pending = None
    for ch in b.decode('ascii', 'ignore'):
        if ch in '0123456789abcdefABCDEF':
            if pending is None: pending = ch
            else: out.append(int(pending + ch, 16)); pending = None
        elif ch.isspace(): continue
        else: pending = None
    return out
bad = []
files = [f for d in sys.argv[1:] for f in sorted(glob.glob(os.path.join(d, '*.gsc')))]
for f in files:
    with open(f, 'rb') as fh:
        body = fh.read().split(b'\n', 3)
    n = len(decode(body[3])) if len(body) > 3 else 0
    name = os.path.splitext(os.path.basename(f))[0].lower()
    ok = (8192, 6912) if name in ('menu', 'misterzine', 'degauss', 'update_all') else (8192,)
    if n not in ok: bad.append(f'{os.path.basename(f)}:{n}')
print(' '.join(bad))
EOPY
)"
ok "and every banner is a whole 8192-byte picture, or a frontend's 6912" "${SHORT}" ""

# The suite's own xxd stand-in, for machines with no real one. It has to agree
# with the real thing on the pack's "0X1f,0Xa2," spelling, and it did not: it
# stripped whitespace and called bytes.fromhex, which raises on the first
# comma, so every real picture failed to decode wherever the shim was used.
# tests/bin is first on PATH, so the real one has to be looked up without it.
SHIM="${HERE}/bin/xxd"
REALXXD="$(PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "${HERE}/bin" | paste -sd:)" \
           command -v xxd 2>/dev/null || true)"
MISMATCH=""
if [ -n "${REALXXD}" ]; then
  for probe in '0X1f,0Xa2,' '0x00,0xff,' 'abc' 'a bc d' '0xa,' 'a,b,'; do
    r="$(printf '%s' "${probe}" | "${REALXXD}" -r -p | od -An -tx1 | tr -d ' \n')"
    m="$(printf '%s' "${probe}" | "${SHIM}" -r -p | od -An -tx1 | tr -d ' \n')"
    [ "${r}" = "${m}" ] || MISMATCH="${MISMATCH} ${probe}[real=${r} shim=${m}]"
  done
  ok "the xxd shim decodes exactly as the real xxd does" "${MISMATCH}" ""
else
  skip "the xxd shim matches the real xxd" "no real xxd to compare against"
fi

# ---------------------------------------------------------------------------
section "transitions: -2 reaches the firmware, and the ini lists every effect"
# ---------------------------------------------------------------------------
reset_capture
TRANSITION="-2"
newcore="NES"; META_ICON=""
printf '#\n#\n#\n00\n' > "${TMP}/pics/banner/NES.gsc"
senddata "NES" >/dev/null 2>&1
contains "CMDCOR carries -2 as it is" "$(captured | grep -a '^CMDCOR')" "CMDCOR,NES,-2"
rm -f "${TMP}/pics/banner/NES.gsc"
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
# The fade-slides are not oled_drawlogo cases - they are the Fade with a
# drift - so their numbers come from the header (derived above).
SLIDES="$(seq "${SLIDE_FIRST}" "${SLIDE_LAST}" | tr '\n' ' ')"
ok "the sketch's effects are 1..maxEffect" "${CASES}" "$(seq 1 "${MAXEFFECT}" | tr '\n' ' ')"
ok "and the ini lists exactly those, plus -2, -1, 0 and the fade-slides" \
   "${LISTED}" "-2 -1 0 ${CASES}${SLIDES}"
# They have to sit clear of the wipes, or adding a wipe would collide with one.
ok "the fade-slides start above the last wipe" \
   "$([ "${SLIDE_FIRST}" -gt "${MAXEFFECT}" ] && echo yes || echo no)" "yes"
ok "and there are ten of them" "$((SLIDE_LAST - SLIDE_FIRST + 1))" "10"
# The ini is what people read instead of the sketch, so each one has to say
# which way it goes.
DESCRIBED="$(sed -n '/^#   30  /,/^#   34  /p' "${ROOT}/tty2oled-system.ini" | grep -cE 'sliding (left|right|up|down|a random way)')"
ok "each fade-slide says which way it goes" "${DESCRIBED}" "5"

# ---------------------------------------------------------------------------
section "an icon must not cut to the layout the transition is about to reach"
# ---------------------------------------------------------------------------
# refreshmeta sends an icon after every CMDMETA, game changes included. The
# firmware used to compose the split layout the moment one landed, which cut
# straight to the new game and cleared metaNeedsDraw before meta_tick could
# transition into it - so loading a ROM into a core that was already running
# changed the screen with no transition at all. The draw is for an icon
# arriving for a layout that is already up, and nothing else.
INO="${ROOT}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
# Three: the core change, the game change, and an icon arriving after its
# game's layout (ScummVM's, converted in the background).
ok "the daemon sends an icon on a game change, not just a core change" \
   "$(grep -c 'sendicon "\${META_ICON}"' "${ROOT}/tty2oled.sh")" "3"
ok "so the icon only draws when nothing is owed a first draw" \
   "$(grep -c 'metaKind==MKIND_CONSOLE && !coreBootHolding && !metaNeedsDraw' "${INO}")" "1"

# ---------------------------------------------------------------------------
section "an icon transfer must not freeze a fade"
# ---------------------------------------------------------------------------
# sendicon writes the header line, sleeps WAITSECS, then streams 2752 bytes -
# so the read blocks the firmware's loop for the best part of half a second at
# 115200 baud. The icon lands immediately after the metadata that started the
# fade, so a Fade did two or three of its sixteen palette steps, froze, and
# then jumped straight to black when the clock caught up. The transfer cannot
# be interrupted, so the tickers are brought to it.
INO="${ROOT}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
ok "the icon is read with the ticking reader" \
   "$(grep -c 'serial_readTicking(iconBin, ICON_BYTES)' "${INO}")" "1"
ok "which advances the fade while it waits" \
   "$(sed -n '/^static size_t serial_readTicking/,/^}/p' "${INO}" | grep -c 'transition_tick()')" "1"
ok "and still gives up on silence, so a short transfer is dropped" \
   "$(sed -n '/^static size_t serial_readTicking/,/^}/p' "${INO}" | grep -c 'TIMEOUT_MS')" "2"
# The picture reads keep the plain blocking call on purpose: logoBin and metaBin
# are what a transition renders from when it reaches its black phase, and
# advancing one while overwriting them could draw half a picture.
ok "the core picture is not read that way" \
   "$(grep -c 'Serial.readBytes((char\*)logoBin' "${INO}")" "1"

# ---------------------------------------------------------------------------
section "core_bootscreen_time: the core's artwork before the game's layout"
# ---------------------------------------------------------------------------
# CMDCBOOT is the daemon's decision, not a setting the firmware keeps: it goes
# out only on a core change, and only for a console core that already knows its
# game. Sending it at all is what asks for the hold, so a core with no game, an
# arcade core, and a game loaded into a core that was already running must not
# produce one.
reset_capture
META_KIND="console"; META_GAME="yes"; core_bootscreen_time="3000"
sendcoreboot
contains "a console core with its game sends CMDCBOOT" "$(captured)" "CMDCBOOT,3000"

reset_capture
core_bootscreen_time="0"
sendcoreboot
ok "0 sends nothing at all" "$(sync_capture; stat -c%s "${CAPTURE}")" "0"
core_bootscreen_time="3000"

# Not conditional on the game. MiSTer publishes the core a second or two before
# the game, so at the moment of a core change there is usually nothing to show
# but the artwork - and that is exactly what the hold is protecting. Requiring
# a game here meant CMDCBOOT was never sent on a real MiSTer at all.
reset_capture
META_GAME="no"
sendcoreboot
contains "a console core with no game yet still arms the hold" "$(captured)" "CMDCBOOT,3000"
META_GAME="yes"

reset_capture
META_KIND="arcade"
sendcoreboot
ok "and nor does an arcade core" "$(sync_capture; stat -c%s "${CAPTURE}")" "0"
META_KIND="console"

# A value that is not a number must not reach the wire as one.
reset_capture
core_bootscreen_time="soon"
sendcoreboot
ok "a value that is not a number sends nothing" "$(sync_capture; stat -c%s "${CAPTURE}")" "0"
core_bootscreen_time="3000"

# ---------------------------------------------------------------------------
section "a core change sends its picture before the game's details"
# ---------------------------------------------------------------------------
# The firmware acts on each command as it lands. When CMDMETA went first, a core
# launched with its game had the transition to the layout started before the
# CMDCBOOT behind it arrived; the 8KB picture's blocking read then froze that
# fade, and the panel jumped to black. So on a core change: leave the old
# layout, send the picture, and only then the game.
#
# The hold goes between the two. Ahead of the picture, the firmware's first
# idle tick - in the 50ms before CMDCOR - started its clock, and the transfer
# and a Fade used the whole of it up: the artwork faded in and straight out.
#
# The same-second mtimes are what a launch that brings its game looks like -
# a frontend, a .mgl, Recents - and what build_meta accepts on a core change.
launch_with_game() {
  reset_capture
  printf 'GBA=console\n'                          > "${TMP}/coretypes"
  printf '/media/fat/_Console/GBA_20240101.rbf\n' > "${TMP}/STARTPATH"
  printf '/media/fat/games/GBA\n'                 > "${TMP}/FULLPATH"
  printf 'Advance Wars (USA).gba\n'               > "${TMP}/CURRENTPATH"
  printf 'selected\n'                             > "${TMP}/FILESELECT"
  printf 'GBA\n'                                  > "${TMP}/CORENAME"
  touch -r "${TMP}/CURRENTPATH" "${TMP}/CORENAME" "${TMP}/FULLPATH"
}
# The command names in the order they reached the port. The picture fixture
# decodes to a lone newline, so no payload byte can run into a command.
wire_order() { captured | grep -aoE '^CMD[A-Z]+' | paste -sd' '; }

TRANSITION="-2"; BOOTSCREEN_AS_MENU="yes"
printf '#\n#\n#\n0a\n' > "${bannerfolder}/GBA.gsc"
{ echo "#"; echo "#"; echo "#"; head -c 2752 /dev/zero | xxd -p; } > "${iconfolder}/GBA.gsc"

launch_with_game
core_bootscreen_time="3000"
senddata "GBA" >/dev/null 2>&1
ok "with a hold: off, picture, hold, then the game and its icon" \
   "$(wire_order)" "CMDMETAOFF CMDCOR CMDCBOOT CMDMETA CMDICON"
contains "and the game did reach the wire" "$(captured | grep -a '^CMDMETA,')" "Advance Wars"

# With no hold the artwork would fade in only to fade straight out again, so it
# is stored without being drawn - upstream's CMDAPD - and the layout is the one
# transition. Still ahead of the metadata, for the same reason.
launch_with_game
core_bootscreen_time="0"
senddata "GBA" >/dev/null 2>&1
ok "without one: the picture is stored, not drawn, before the game" \
   "$(wire_order)" "CMDMETAOFF CMDAPD CMDMETA CMDICON"
contains "carrying the transition the layout will use" \
   "$(captured | grep -a '^CMDAPD')" "CMDAPD,GBA,-2"
core_bootscreen_time="3000"

# The usual case on real hardware: the core first, the game later. The artwork
# is drawn and held, and nothing else goes out - one CMDMETAOFF, not two.
launch_with_game
rm -f "${TMP}/CURRENTPATH" "${TMP}/FULLPATH" "${TMP}/FILESELECT"
senddata "GBA" >/dev/null 2>&1
ok "a core with no game yet: off, picture, hold and nothing more" \
   "$(wire_order)" "CMDMETAOFF CMDCOR CMDCBOOT"

# Arcade: no hold, and the card's metadata after the wheel too. dkong is
# frame 0 of the fixture pack, newlines throughout, so the card's command
# still starts a line of its own.
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
senddata "dkong" >/dev/null 2>&1
ok "an arcade core: off, wheel, then the card" \
   "$(wire_order)" "CMDMETAOFF CMDCOR CMDMETA"

# The menu keeps its own picture request, and has nothing to describe.
reset_capture
senddata "MENU" >/dev/null 2>&1
ok "the menu: off, then the boot screen as its picture" \
   "$(wire_order)" "CMDMETAOFF CMDBOOTPIC"

# A game change within the core is unchanged: details only, no picture.
launch_with_game
META_WIRE_LAST="OFF"
refreshmeta "GBA" >/dev/null 2>&1
ok "a game change in a running core sends only the details" \
   "$(wire_order)" "CMDMETA CMDICON"

rm -f "${bannerfolder}/GBA.gsc" "${iconfolder}/GBA.gsc"
TRANSITION="-1"

# test_meta_layout replays this order against the firmware, with the sketch's
# picture handling written out, since the sketch itself does not compile on the
# host. These hold the sketch to what the replay assumes.
INO="${ROOT}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"
ok "CMDAPD stores the picture and draws nothing" \
   "$(grep -A2 'startsWith("CMDAPD")' "${INO}" | sed -n 2p | sed 's/ *\/\/.*//;s/^ *//')" \
   "oled_readlogo();"
ok "CMDCOR composes the layout only for a console with no hold armed" \
   "$(grep -c 'if (metaKind==MKIND_CONSOLE && !coreBootHolding) {' "${INO}")" "1"
# The status line comes ten times a second, and the ack delay stops loop():
# it is acknowledged at once, and it alone.
ACK="$(sed -n '/if (sendTTYACK) {  *\/\/ Send ACK?/,/^    }/p' "${INO}" | grep -v '^ *//' | tr -s ' ')"
ok "CMDBUSYLINE is acknowledged without the delay, and only it" \
   "$(printf '%s\n' "${ACK}" | grep -B1 'delay(cDelay);' | tr '\n' '~')" \
   ' if (!newCommand.startsWith("CMDBUSYLINE,"))~ delay(cDelay); // Command Response Delay~'
ok "and the acknowledgement itself still goes" "$(printf '%s\n' "${ACK}" | grep -c 'Serial.print("ttyack;")')" "1"

# ---------------------------------------------------------------------------
section "BOOTSCREEN_AS_MENU: the menu asks for the boot screen, and sends no picture"
# ---------------------------------------------------------------------------
META_ICON=""; TRANSITION="-2"
printf '#\n#\n#\n00\n' > "${bannerfolder}/MENU.gsc"
printf '#\n#\n#\n00\n' > "${bannerfolder}/NES.gsc"

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
rm -f "${bannerfolder}/MENU.gsc" "${bannerfolder}/NES.gsc"
TRANSITION="-1"

# ---------------------------------------------------------------------------
section "Degauss: degauss.gsc by that exact name, else the name as text"
# ---------------------------------------------------------------------------
# Degauss runs over the menu core, so STARTPATH is the menu's rbf and the
# kind is unknown - a banner, no card. The daemon names it "degauss" in
# place of MENU while it runs (test-daemon.sh); this is what that name sends.
META_ICON=""; TRANSITION="-2"
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
printf '#\n#\n#\n00\n' > "${bannerfolder}/deg.gsc"
printf '#\n#\n#\n00\n' > "${userbannerfolder}/d.gsc"
findpicture "degauss"; r=$?
ok "no degauss.gsc: no picture, not one a trimmed name would find" "${r}:${PICFILE}" "1:"

reset_capture
senddata "degauss" >/dev/null 2>&1
ok "so the name goes out as text" "$(captured | grep -av '^CMD' | tr -d '\r')" "degauss"
ok "after metadata off, and nothing else" "$(wire_order)" "CMDMETAOFF"

printf '#\n#\n#\n00\n' > "${bannerfolder}/degauss.gsc"
findpicture "degauss"
ok "degauss.gsc in pics/banner is its picture" "${PICFILE}" "${bannerfolder}/degauss.gsc"
reset_capture
senddata "degauss" >/dev/null 2>&1
ok "sent as a core's picture, transitioned" "$(wire_order)" "CMDMETAOFF CMDCOR"
contains "under its own name" "$(captured | grep -a '^CMDCOR')" "CMDCOR,degauss,-2"

printf '#\n#\n#\n00\n' > "${userbannerfolder}/degauss.gsc"
PRIORITIZE_USER_BANNERS="yes"
findpicture "degauss"
ok "yours in pics/user comes first" "${PICFILE}" "${userbannerfolder}/degauss.gsc"
PRIORITIZE_USER_BANNERS="no"
findpicture "degauss"
ok "unless PRIORITIZE_USER_BANNERS says otherwise" "${PICFILE}" "${bannerfolder}/degauss.gsc"
PRIORITIZE_USER_BANNERS="yes"
rm -f "${bannerfolder}/deg.gsc" "${userbannerfolder}/d.gsc" \
      "${bannerfolder}/degauss.gsc" "${userbannerfolder}/degauss.gsc"
TRANSITION="-1"

# ---------------------------------------------------------------------------
section "frontends: 54 rows of picture, and the band under it"
# ---------------------------------------------------------------------------
# The menu, MisterZine and Degauss keep the boot screen's band for the
# display's notices: their picture goes out marked ",band", as its top 54
# rows and 1280 black bytes, whatever height the file is.
for c in MENU menu MisterZine MISTERZINE misterzine degauss; do
  frontend_core "${c}"; ok "${c} is a frontend" "${?}" "0"
done
for c in NES MENUX misterzin update_all ""; do
  frontend_core "${c}"; ok "'${c}' is not" "${?}" "1"
done

# A .gsc of <rows> rows: every byte 11, the last ten rows' ff so the band
# shows on the wire if it is not blacked. No 0a: the bytes are read back
# after the command line.
mkgsc() {  # mkgsc <file> <rows>
  { printf '#define icon_width 256\n#define icon_height %s\n#\n' "${2}"
    { head -c $(( (${2} - 10) * 128 )) /dev/zero | tr '\0' '\021'
      head -c 1280 /dev/zero | tr '\0' '\377'; } | xxd -p; } > "${1}"
}
# The bytes after the picture's command line, as hex.
picbytes() { captured | sed -n '/^CMDCOR/,$p' | tail -n +2 | xxd -p | tr -d '\n'; }
EXPECT="$( { head -c 6912 /dev/zero | tr '\0' '\021'; head -c 1280 /dev/zero; } | xxd -p | tr -d '\n')"

META_ICON=""; TRANSITION="-2"
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
mkgsc "${bannerfolder}/misterzine.gsc" 64
reset_capture
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
senddata "misterzine" >/dev/null 2>&1
ok "MisterZine's picture is marked band" "$(captured | grep -a '^CMDCOR' | tr -d '\r')" "CMDCOR,misterzine,-2,band"
ok "a 256x64 one goes out as its top 54 rows, the band black" "$(picbytes)" "${EXPECT}"

mkgsc "${bannerfolder}/misterzine.gsc" 54
# A 256x54 file's last ten rows are its picture's, not a band: all 11.
{ printf '#\n#\n#\n'; head -c 6912 /dev/zero | tr '\0' '\021' | xxd -p; } > "${bannerfolder}/misterzine.gsc"
reset_capture
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
senddata "misterzine" >/dev/null 2>&1
ok "a 256x54 one is padded to a whole 8192 with the band" "$(picbytes)" "${EXPECT}"

mkgsc "${bannerfolder}/degauss.gsc" 64
reset_capture
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
senddata "degauss" >/dev/null 2>&1
ok "Degauss is marked band too" "$(captured | grep -a '^CMDCOR' | tr -d '\r')" "CMDCOR,degauss,-2,band"
ok "and cut to 54 rows" "$(picbytes)" "${EXPECT}"

mkgsc "${bannerfolder}/MENU.gsc" 64
BOOTSCREEN_AS_MENU="no"
reset_capture
printf '/media/fat/menu.rbf\n' > "${TMP}/STARTPATH"
senddata "MENU" >/dev/null 2>&1
ok "the menu's MENU.gsc, with BOOTSCREEN_AS_MENU off, too" "$(captured | grep -a '^CMDCOR' | tr -d '\r')" "CMDCOR,MENU,-2,band"
ok "cut the same" "$(picbytes)" "${EXPECT}"
BOOTSCREEN_AS_MENU="yes"

mkgsc "${bannerfolder}/NES.gsc" 64
reset_capture
senddata "NES" >/dev/null 2>&1
ok "a core's picture is not marked" "$(captured | grep -a '^CMDCOR' | tr -d '\r')" "CMDCOR,NES,-2"
ok "and goes out whole, its bottom rows and all" "$(picbytes)" \
   "$( { head -c 6912 /dev/zero | tr '\0' '\021'; head -c 1280 /dev/zero | tr '\0' '\377'; } | xxd -p | tr -d '\n')"
rm -f "${bannerfolder}/misterzine.gsc" "${bannerfolder}/degauss.gsc" \
      "${bannerfolder}/MENU.gsc" "${bannerfolder}/NES.gsc"
TRANSITION="-1"

# ---------------------------------------------------------------------------
section "CMDNOTE: the band's notice, sent when it changes, to firmware that has it"
# ---------------------------------------------------------------------------
NOTE_SENT="?"
reset_capture; FW_VERSION="0.7.0b"; sendnote "TTY2OLED+ update available"
ok "firmware before 0.7.1b is sent nothing" "$(captured)" ""
ok "and nothing is taken as told" "${NOTE_SENT}" "?"
reset_capture; FW_VERSION=""; sendnote "TTY2OLED+ update available"
ok "nor a display that has not said what it runs" "$(captured)" ""
reset_capture; FW_VERSION="0.7.1b"; sendnote "TTY2OLED+ update available"
ok "0.7.1b is told" "$(captured | tr -d '\r')" "CMDNOTE,TTY2OLED+ update available"
reset_capture; sendnote "TTY2OLED+ update available"
ok "once" "$(captured)" ""
reset_capture; sendnote ""
ok "and when it goes" "$(captured | tr -d '\r')" "CMDNOTE,"
reset_capture; sendnote ""
ok "once" "$(captured)" ""
reset_capture; NOTE_SENT="?"; sendnote ""
ok "a display that may be holding one is told there is none" "$(captured | tr -d '\r')" "CMDNOTE,"
reset_capture; sendnote "$(printf 'New,\tone|%s' "$(printf 'x%.0s' {1..60})")"
line="$(captured | tr -d '\r')"
ok "control characters out, cut to the band's 51 columns" "${line}" \
   "CMDNOTE,New,one|$(printf 'x%.0s' {1..43})"
FW_VERSION=""; NOTE_SENT="?"

# ---------------------------------------------------------------------------
section "scraped metadata: more fields, and the description after the line"
# ---------------------------------------------------------------------------
# What tty2oledplus_scrape.py left in scraped/<system>.txt, one game a line:
#   key|crc|status|title|released|players|rating|genre|developer|publisher|series|description
SCRAPE_DIR="${TMP}/scraped"
rm -rf "${SCRAPE_DIR}"; mkdir -p "${SCRAPE_DIR}"
DESC="A potato must escape a maze. It is harder than it sounds, and it sounds hard."
printf '%s\n' \
  "A-mazing Tater (USA)|d229ac62|ok|A-Mazing Tater|1991-06-01|1|16|Puzzle|Atlus|Atlus|Tater|${DESC}" \
  "Unknown Game (USA)|00000000|missing|||||||||" \
  > "${SCRAPE_DIR}/GAMEBOY.txt"

scraped_game() {  # scraped_game <file name> [crc]
  reset_capture
  printf 'GAMEBOY=console\n' > "${TMP}/coretypes"
  printf 'GAMEBOY\n' > "${TMP}/CORENAME"
  printf 'GAMEBOY\n' > "${TMP}/RBFNAME"
  sleep 0.05
  printf 'games/GAMEBOY\n' > "${TMP}/FULLPATH"
  printf '%s\n' "${1}"     > "${TMP}/CURRENTPATH"
  printf 'selected\n'      > "${TMP}/FILESELECT"
  printf 'CRC32: %s\n' "${2:-FFFFFFFF}" > "${TMP}/GAMEID"
}

unset METADATA_FIELDS; METADATA_FIELDS=""
scraped_game "A-mazing Tater (USA).gb"
sendmeta "GAMEBOY"
out="$(captured)"
line="$(printf '%s' "${out}" | head -n1)"
contains "the scraped title replaces the file name's" "${line}" ",A-Mazing Tater|"
contains "players"                   "${line}" "|Players=1|"
contains "the rating out of ten"     "${line}" "|Rating=8/10|"
contains "the release date"          "${line}" "|Released=1991-06-01|"
contains "the series"                "${line}" "|Series=Tater"
contains "and what the index lacked" "${line}" "|Genre=Puzzle|"
# COMPACT_YEAR_COMPANY's ", " comes through metasanitize as two spaces.
contains "the year, from the date"   "${line}" "|Year=1991  Atlus|"
# Only System is pinned by default: the title stays by itself, and Year is
# the first field under System, on the first page and nowhere else.
contains "one pinned field, System first" "${line}" "CMDMETA,2,12,1,0,A-Mazing Tater|System=GAMEBOY|"
ok "the ini pins System alone" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${METADATA_PINNED}")" "System"
ok "the description follows the line, announced by its length" \
   "$(printf '%s' "${out}" | sed -n 2p | tr -d '\r')" "CMDDESC,${#DESC}"
ok "and then exactly its bytes" \
   "$(sync_capture; tail -c "${#DESC}" "${CAPTURE}")" "${DESC}"
HDR="CMDDESC,${#DESC}"
ok "and nothing else after them" \
   "$(sync_capture; stat -c%s "${CAPTURE}")" "$(( ${#line} + 1 + ${#HDR} + 1 + ${#DESC} ))"

# The resend check covers the description: the same game again sends nothing,
# a changed description sends everything again.
sync_capture; : > "${CAPTURE}"
sendmeta "GAMEBOY"
ok "the same game twice is sent once" "$(captured)" ""
sed -i 's/harder than it sounds/easier than it looks/' "${SCRAPE_DIR}/GAMEBOY.txt"
sendmeta "GAMEBOY"
contains "a new description is news" "$(captured)" "easier than it looks"

# MiSTer strips the extension for single-extension cores; the key has none.
scraped_game "A-mazing Tater (USA)"
sendmeta "GAMEBOY"
contains "found without the extension too" "$(captured)" "|Players=1|"

# The CRC is the fallback, for a renamed file.
scraped_game "tater-renamed.gb" "D229AC62"
sendmeta "GAMEBOY"
contains "found by CRC when the name misses" "$(captured)" "|Players=1|"

# Looked up and not found is not a hit.
scraped_game "Unknown Game (USA).gb" "00000000"
sendmeta "GAMEBOY"
out="$(captured)"
ok "a game recorded as missing gets no scraped fields" "$(printf '%s' "${out}" | grep -c 'Players=')" "0"
ok "and no description" "$(printf '%s' "${out}" | grep -c 'CMDDESC')" "0"

# The Game Boy core plays .gbc files, which the scraper filed under GBC.
mv "${SCRAPE_DIR}/GAMEBOY.txt" "${SCRAPE_DIR}/gbc.txt"
scraped_game "A-mazing Tater (USA).gb"
sendmeta "GAMEBOY"
contains "a sibling system's file is searched, whatever its case" "$(captured)" "|Players=1|"
mv "${SCRAPE_DIR}/gbc.txt" "${SCRAPE_DIR}/GAMEBOY.txt"

SHOW_DESCRIPTION="no"
scraped_game "A-mazing Tater (USA).gb"
sendmeta "GAMEBOY"
out="$(captured)"
ok "SHOW_DESCRIPTION=no sends no description" "$(printf '%s' "${out}" | grep -c 'CMDDESC')" "0"
contains "but still the fields" "${out}" "|Players=1|"
unset SHOW_DESCRIPTION

# Only printable ASCII reaches the panel, and never more than it keeps.
LONG="$(printf 'word%.0s ' $(seq 1 600))"
printf 'Long (USA)|x|ok|Long||||||||%s\tafter a tab\n' "${LONG}" >> "${SCRAPE_DIR}/GAMEBOY.txt"
scraped_game "Long (USA).gb"
sendmeta "GAMEBOY"
ok "cut to the firmware's 2048 bytes" \
   "$(captured | sed -n 2p | tr -d '\r')" "CMDDESC,2048"
SCRAPE_DIR="${TMP}/no-such-dir"

# In the shipped field order, Year is the first field under the one pinned,
# so it is on the first page and nowhere else.
SCRAPE_DIR="${TMP}/scraped"
METADATA_FIELDS="$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${METADATA_FIELDS}")"
scraped_game "A-mazing Tater (USA).gb"
sendmeta "GAMEBOY"
contains "in the shipped order Year is the first field under System" \
   "$(captured | head -n1)" "|System=GAMEBOY|Year=1991  Atlus|Genre="
METADATA_FIELDS=""
SCRAPE_DIR="${TMP}/no-such-dir"

# ---------------------------------------------------------------------------
section "scraped metadata: arcade, keyed on the .mra or the set"
# ---------------------------------------------------------------------------
# An arcade game no gamelist describes has no description to send, and its
# card is the MRA's alone.
reset_capture
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
sendmeta "dkong"
out="$(captured)"
contains "arcade with nothing imported sends its card" "${out}" "CMDMETA,1,"
ok "arcade with nothing imported sends no description" "$(printf '%s' "${out}" | grep -c 'CMDDESC')" "0"
ok "and none of the gamelist's fields" "$(printf '%s' "${out}" | grep -c 'Developr=\|Rating=')" "0"

SCRAPE_DIR="${TMP}/scraped"
arcade_game() {  # arcade_game <mra>
  reset_capture
  printf '%s\n' "${1}" > "${TMP}/STARTPATH"
}
# From games/mame/gamelist.xml, so keyed by the set - dkong.mra's <setname>.
ADESC="Climb the girders, jump the barrels, save the girl."
printf '%s\n' \
  "dkong||ok|Donkey Kong|1981-07-09|2|18|Platform, Climbing|Nintendo R&D1, Ikegami|Nintendo|Donkey Kong|${ADESC}" \
  > "${SCRAPE_DIR}/Arcade.txt"
arcade_game "${FIX}/mra/dkong.mra"
sendmeta "dkong"
out="$(captured)"
line="$(printf '%s' "${out}" | head -n1)"
contains "the MRA's title stays"            "${line}" ",Donkey Kong (US set 1)|"
# Players, Rating and Developer are short fields, paired after the pinned row:
# nine of them now, where the MRA alone had six.
contains "the MRA's year and maker win, and the gamelist's short fields follow" \
  "${line}" "CMDMETA,1,12,2,9,Donkey Kong (US set 1)|Year=1981|Manufctr=Nintendo of America|Players=2|Rating=9/10|Developr=Nintendo R&D1 Ikegami|Orient="
ok "the description follows the line" \
   "$(printf '%s' "${out}" | sed -n 2p | tr -d '\r')" "CMDDESC,${#ADESC}"
ok "and then exactly its bytes" \
   "$(sync_capture; tail -c "${#ADESC}" "${CAPTURE}")" "${ADESC}"

# An .mra's own name is not a key: nothing imports _Arcade.
sed -i 's/^dkong|/Donkey Kong (US set 1)|/' "${SCRAPE_DIR}/Arcade.txt"
arcade_game "${FIX}/mra/dkong.mra"
sendmeta "dkong"
ok "a line keyed by the .mra's name is no hit" "$(captured | grep -c 'CMDDESC')" "0"
sed -i 's/^Donkey Kong (US set 1)|/dkong|/' "${SCRAPE_DIR}/Arcade.txt"

arcade_game "${FIX}/mra/dkong.mra"
SHOW_DESCRIPTION="no"
sendmeta "dkong"
out="$(captured)"
ok "SHOW_DESCRIPTION=no sends an arcade game none either" "$(printf '%s' "${out}" | grep -c 'CMDDESC')" "0"
contains "but still the fields" "${out}" "|Developr="
unset SHOW_DESCRIPTION

# The next set, which no gamelist lists, must not inherit this one's.
arcade_game "${FIX}/mra/sf2.mra"
sendmeta "sf2"
out="$(captured)"
contains "the next set sends its card" "${out}" "CMDMETA,1,"
ok "and none of the last one's" \
   "$(printf '%s' "${out}" | grep -c 'CMDDESC\|Developr=')" "0"
SCRAPE_DIR="${TMP}/no-such-dir"

ok "the shipped short list has players, rating and developer after the pinned row" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${ARCADE_FIELDS}")" "Year Manufacturer Players Rating Developer Region Orientation Core Author Set MAME"
ok "and the wide list only what needs a row" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${ARCADE_FIELDS_WIDE}")" "Controls Buttons"

# ---------------------------------------------------------------------------
section "scroll speeds: pixels a second, sent once at startup"
# ---------------------------------------------------------------------------
reset_capture
unset HSCROLL_SPEED VSCROLL_SPEED
sendscroll
ok "the defaults: the old marquee, and 6px a second up" "$(captured | tr -d '\r\n')" "CMDSCROLL,25,6"
reset_capture
HSCROLL_SPEED="40"; VSCROLL_SPEED="2"
sendscroll
ok "and what the ini says"  "$(captured | tr -d '\r\n')" "CMDSCROLL,40,2"
ok "the ini's defaults are those" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${HSCROLL_SPEED},${VSCROLL_SPEED}")" "25,6"
ok "sent with the rest of the startup settings" \
   "$(grep -c '^  sendscroll' "${ROOT}/tty2oled.sh")" "1"

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
