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
mkdir -p "${TMP}" "${TMP}/pics/icon" "${TMP}/pics/banner" "${TMP}/pics/alt" "${TMP}/pics/user"

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
altbannerfolder="${TMP}/pics/alt"
userbannerfolder="${TMP}/pics/user"

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
section "banners: the alternatives, and that they are off by default"
# ---------------------------------------------------------------------------
printf '#\n#\n#\n00\n' > "${altbannerfolder}/NES_alt1.gsc"
printf '#\n#\n#\n00\n' > "${altbannerfolder}/NES_alt2.gsc"

unset RANDOMIZE_ALT_BANNERS
PICKED=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  PICKED="${PICKED}$(randomalt "${bannerfolder}/NES.gsc")\n"
done
ok "off by default: twenty loads, one picture" \
   "$(printf "${PICKED}" | sort -u | wc -l | tr -d ' ')" "1"
ok "and it is the banner itself" \
   "$(randomalt "${bannerfolder}/NES.gsc")" "${bannerfolder}/NES.gsc"

# On, every candidate has to be reachable - the primary included, which is
# what upstream's "RANDOM % (count + 1)" amounted to. Twenty rolls of a fair
# three-sided die miss a face about one time in 3000, and RANDOM is seeded
# from the shell, so this is run until it has seen them all or given up.
RANDOMIZE_ALT_BANNERS="yes"
PICKED=""
for i in $(seq 1 60); do
  PICKED="${PICKED}$(randomalt "${bannerfolder}/NES.gsc")\n"
done
ok "on: the banner and both alternatives all come up" \
   "$(printf "${PICKED}" | sort -u | tr '\n' ' ')" \
   "${altbannerfolder}/NES_alt1.gsc ${altbannerfolder}/NES_alt2.gsc ${bannerfolder}/NES.gsc "

# Alternatives of your own live beside your own banner, since pics/alt is the
# pack's and an update replaces it.
printf '#\n#\n#\n11\n' > "${userbannerfolder}/NES_alt9.gsc"
PICKED=""
for i in $(seq 1 60); do
  PICKED="${PICKED}$(randomalt "${bannerfolder}/NES.gsc")\n"
done
contains "yours in pics/user are diced in too" \
   "$(printf "${PICKED}" | sort -u | tr '\n' ' ')" "${userbannerfolder}/NES_alt9.gsc"
rm -f "${userbannerfolder}/NES_alt9.gsc"

# The alternatives are named after the picture that was found, not after the
# core - it may have been trimmed down to a prefix on the way.
findbanner "NESabc"
ok "a trimmed match still finds its own alternatives" \
   "$(for i in $(seq 1 60); do randomalt "${BANNERFILE}"; echo; done | sort -u | wc -l | tr -d ' ')" "3"

RANDOMIZE_ALT_BANNERS="no"
rm -f "${altbannerfolder}/NES_alt1.gsc" "${altbannerfolder}/NES_alt2.gsc" "${bannerfolder}/NES.gsc"

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
# The daemon looks in pics/user, pics/banner, pics/alt and pics/icon and
# nowhere else, so anything that is not a .gsc in the pack is unreachable by
# construction, and a .gsc that does not decode to exactly 8192 bytes is
# dropped by the firmware as a truncated transfer - silently, which is why it
# is worth a test.
ok "pics/ holds the four folders" "$(ls "${ROOT}/pics" | tr '\n' ' ')" "alt banner icon user "
ok "and nothing in them but .gsc files" \
   "$(find "${ROOT}/pics/banner" "${ROOT}/pics/alt" "${ROOT}/pics/icon" -type f ! -name '*.gsc' | head -n3 | tr '\n' ' ')" ""

# Alternatives are in pics/alt and nowhere else: the banner folder is one file
# per core, which is what lets findbanner trim a core name down to a prefix
# without ever landing on a variant.
ok "no alternatives left among the banners" \
   "$(ls "${ROOT}/pics/banner" | grep -c '_alt')" "0"
ok "and the alt folder is nothing but" \
   "$(ls "${ROOT}/pics/alt" | grep -vc '_alt[0-9]*\.gsc$')" "0"

# The fifteen converted from .xbm, by name: these are the ones that would have
# gone blank had the conversion been skipped, so they are pinned rather than
# sampled. Decoded through the daemon's own reader.
CONVERTED="A.ARKANOID a.astdelux A.COSMIC alienaru arkanoiduo"
CONVERTED="${CONVERTED} contrae Cotton HyperOlympic jtsdram48 jtsdram96 quartet2a tokiob"
BAD=""
for n in ${CONVERTED} "Clean Sweep" "Diet Go Go" "Yie Ar Kung Fu"; do
  f="${ROOT}/pics/banner/${n}.gsc"
  if [ ! -e "${f}" ]; then BAD="${BAD} ${n}:missing"; continue; fi
  b="$(tail -n +4 "${f}" | xxd -r -p | wc -c)"
  [ "${b}" = "8192" ] || BAD="${BAD} ${n}:${b}"
done
ok "every picture converted from .xbm is a full 8192-byte .gsc" "${BAD}" ""

# And the pack at large, since a picture that is not exactly 8192 bytes is a
# short readBytes in the firmware, which draws the transfer-error bitmap - the
# core looks broken rather than unpainted. upstream's invinco.gsc was one: 6976
# bytes of what renders as static, and it had been showing a transfer error for
# as long as it has been in the pack. One python pass rather than 1905 pipes,
# which is the difference between a second and a minute.
SHORT="$(python3 - "${ROOT}/pics/banner" "${ROOT}/pics/alt" <<'EOPY'
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
    if n != 8192: bad.append(f'{os.path.basename(f)}:{n}')
print(' '.join(bad))
EOPY
)"
ok "and so is every other picture in the pack" "${SHORT}" ""

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
RANDOMIZE_ALT_BANNERS="no"
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
ok "the daemon sends an icon on a game change, not just a core change" \
   "$(grep -c 'sendicon "\${META_ICON}"' "${ROOT}/tty2oled.sh")" "2"
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

# Order matters as much as the command: the icon composes the split layout as
# soon as it lands, so it has to come after the hold is armed or it would draw
# the layout a moment before the artwork replaced it.
ok "the hold is armed before the icon is sent" \
   "$(grep -n 'sendcoreboot$\|sendicon "\${META_ICON}"' "${ROOT}/tty2oled.sh" \
      | head -n2 | cut -d: -f2 | sed 's/^ *//;s/\[.*&& //' | paste -sd' ')" \
   "sendcoreboot sendicon \"\${META_ICON}\""

# ---------------------------------------------------------------------------
section "BOOTSCREEN_AS_MENU: the menu asks for the boot screen, and sends no picture"
# ---------------------------------------------------------------------------
RANDOMIZE_ALT_BANNERS="no"
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
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
