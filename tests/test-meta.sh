#!/bin/bash
#
# Unit tests for tty2oled-meta.sh
# Runs on any workstation - no MiSTer, no hardware, no serial port.
#
#   ./tests/test-meta.sh
#
# Exits non-zero on the first category of failure so CI can gate on it.

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
FIX="${HERE}/fixtures"
TMP="${FIX}/tmp"

mkdir -p "${TMP}"

# Point the library at the fixture tree instead of /tmp and /media/fat.
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

# shellcheck source=../tty2oled-meta.sh
. "${ROOT}/tty2oled-meta.sh"

PASS=0; FAIL=0

ok() {
  local label="${1}" got="${2}" want="${3}"
  if [ "${got}" = "${want}" ]; then
    PASS=$((PASS+1))
    printf '  \033[32mok\033[0m   %s\n' "${label}"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n' "${label}" "${want}" "${got}"
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "${1}"; }

# Reset all the fake /tmp state between scenarios.
clear_state() {
  rm -f "${TMP}/CORENAME" "${TMP}/RBFNAME" "${TMP}/STARTPATH" \
        "${TMP}/FULLPATH" "${TMP}/CURRENTPATH" "${TMP}/FILESELECT" \
        "${TMP}/GAMEID" "${TMP}/titleindex" "${TMP}/coretypes"
}

# ---------------------------------------------------------------------------
section "parse_mra"
# ---------------------------------------------------------------------------
parse_mra "${FIX}/mra/dkong.mra"
ok "name"            "${MRA_NAME}"         "Donkey Kong (US set 1)"
ok "year"            "${MRA_YEAR}"         "1981"
ok "manufacturer"    "${MRA_MANUFACTURER}" "Nintendo of America"
ok "category"        "${MRA_CATEGORY}"     "Platform"
ok "setname"         "${MRA_SETNAME}"      "dkong"
ok "mameversion"     "${MRA_MAMEVER}"      "0216"

parse_mra "${FIX}/mra/sf2.mra"
ok "title with colon" "${MRA_NAME}"        "Street Fighter II: The World Warrior (World 910522)"

parse_mra "${FIX}/mra/amp.mra"
ok "entity &amp;"     "${MRA_NAME}"        "Rock & Roll Racing <proto>"
ok "entity &apos;"    "${MRA_MANUFACTURER}" "Tim & Tom's Games"

parse_mra "${FIX}/mra/noname.mra"
ok "missing <name> falls back to filename" "${MRA_NAME}" "noname"

parse_mra "${FIX}/mra/does-not-exist.mra"
ok "absent file returns empty" "${MRA_NAME}" ""

# A full jotego-style MRA: everything the arcade card can show is in there.
parse_mra "${FIX}/mra/tmnt.mra"
ok "players"      "${MRA_PLAYERS}"     "4"
ok "joystick"     "${MRA_JOYSTICK}"    "8-way"
ok "rotation"     "${MRA_ROTATION}"    "horizontal"
ok "region"       "${MRA_REGION}"      "World"
ok "platform"     "${MRA_PLATFORM}"    "TMNT"
ok "catver"       "${MRA_CATVER}"      "Fighter / 2.5D"
ok "version"      "${MRA_VERSION}"     "1.1"
ok "rbf"          "${MRA_RBF}"         "jttmnt"
# Attributes, not element text: <buttons names=... count=...> and <about author=...>.
ok "button names" "${MRA_BUTTONS}"     "Attack,Jump,-,Start,Coin,Pause"
ok "button count" "${MRA_BUTTONCOUNT}" "2"
ok "about author" "${MRA_AUTHOR}"      "jotego"

# Tags absent from an MRA must not carry over from the one parsed before it.
parse_mra "${FIX}/mra/dkong.mra"
ok "players not inherited" "${MRA_PLAYERS}" ""
ok "author not inherited"  "${MRA_AUTHOR}"  ""
ok "catver not inherited"  "${MRA_CATVER}"  ""

# ---------------------------------------------------------------------------
section "clean_romname"
# ---------------------------------------------------------------------------
clean_romname "/media/fat/games/SNES/Super Mario World (USA).sfc"
ok "no-intro title"   "${ROM_TITLE}"  "Super Mario World"
ok "no-intro region"  "${ROM_REGION}" "USA"
ok "no-intro ext"     "${ROM_EXT}"    "sfc"

clean_romname "/games/NES/Legend of Zelda, The (USA) (Rev 1).nes"
ok "article moved"    "${ROM_TITLE}"  "The Legend of Zelda"
ok "rev stripped"     "${ROM_REGION}" "USA"

clean_romname "/games/Genesis/Sonic The Hedgehog 2 (World).md"
ok "world region"     "${ROM_TITLE}"  "Sonic The Hedgehog 2"
ok "world tag"        "${ROM_REGION}" "World"

clean_romname "/games/C64/Boulder Dash (1984)(First Star Software)(US)[cr JEDI].d64"
ok "tosec title"      "${ROM_TITLE}"  "Boulder Dash"
ok "tosec region"     "${ROM_REGION}" "USA"
ok "tosec tags"       "${ROM_TAGS}"   "cr JEDI"

clean_romname "/games/SNES/Final_Fantasy_III_(USA).sfc"
ok "underscores"      "${ROM_TITLE}"  "Final Fantasy III"

clean_romname "/games/misc/PlainName.bin"
ok "no tags at all"   "${ROM_TITLE}"  "PlainName"
ok "no region"        "${ROM_REGION}" ""

clean_romname "/games/x/Game (Japan, USA) (Beta).rom"
ok "multi-region picks specific" "${ROM_REGION}" "Japan, USA"

# ---------------------------------------------------------------------------
section "classify_core"
# ---------------------------------------------------------------------------
clear_state
printf '/media/fat/_Arcade/Donkey Kong.mra\n' > "${TMP}/STARTPATH"
classify_core "dkong"
ok "mra extension => arcade" "${META_KIND}" "arcade"

clear_state
printf '/media/fat/_Console/SNES_20240101.rbf\n' > "${TMP}/STARTPATH"
classify_core "SNES"
ok "_Console folder"         "${META_KIND}" "console"

clear_state
printf '/media/fat/_Computer/Amiga_20240101.rbf\n' > "${TMP}/STARTPATH"
classify_core "Minimig"
ok "_Computer folder"        "${META_KIND}" "computer"

clear_state
printf '/media/fat/_Other/Something.rbf\n' > "${TMP}/STARTPATH"
classify_core "Something"
ok "unknown folder"          "${META_KIND}" "unknown"

clear_state
classify_core "SNES"
ok "no STARTPATH at all"     "${META_KIND}" "unknown"

clear_state
printf '/media/fat/_Other/Odd.rbf\n' > "${TMP}/STARTPATH"
printf 'Odd=console\n' > "${TMP}/coretypes"
classify_core "Odd"
ok "user override map"       "${META_KIND}" "console"

# ---------------------------------------------------------------------------
section "read_gameid + lookup_crc"
# ---------------------------------------------------------------------------
clear_state
printf 'CRC32: B19ED489\nSerial: SNS-MW-USA\n' > "${TMP}/GAMEID"
read_gameid
ok "crc parsed"    "${GAME_CRC32}"  "B19ED489"
ok "serial parsed" "${GAME_SERIAL}" "SNS-MW-USA"

printf 'B19ED489|Super Mario World|USA|1990|Nintendo\n' > "${TMP}/titleindex"
lookup_crc "B19ED489"
ok "index title"     "${IDX_TITLE}"     "Super Mario World"
ok "index year"      "${IDX_YEAR}"      "1990"
ok "index publisher" "${IDX_PUBLISHER}" "Nintendo"

lookup_crc "b19ed489"
ok "index lookup is case-insensitive" "${IDX_TITLE}" "Super Mario World"

lookup_crc "DEADBEEF"
ok "index miss is empty" "${IDX_TITLE}" ""

# ---------------------------------------------------------------------------
section "build_meta - arcade"
# ---------------------------------------------------------------------------
clear_state
printf '%s\n' "${FIX}/mra/dkong.mra" > "${TMP}/STARTPATH"
build_meta "dkong"
ok "kind"        "${META_KIND}"   "arcade"
ok "title"       "${META_TITLE}"  "Donkey Kong (US set 1)"
ok "source"      "${META_SOURCE}" "mra"
# Only what this MRA carries: no players, buttons, region or author in it,
# and a field with nothing behind it is never emitted.
ok "field count" "${#META_FIELDS[@]}" "6"
ok "field 1"     "${META_FIELDS[0]}" "$(printf 'Year\t1981')"
# Labels are abbreviated to fit half a row.
ok "field 2"     "${META_FIELDS[1]}" "$(printf 'Manufctr\tNintendo of America')"
ok "orientation cased" "${META_FIELDS[2]}" "$(printf 'Orient\tVertical')"
ok "all six pair up"   "${META_COMPACT_COUNT}" "6"
ok "two pinned"        "${META_PINNED_COUNT}"  "2"

# The full MRA: the paired fields in ARCADE_FIELDS order, then the wide ones.
clear_state
printf '%s\n' "${FIX}/mra/tmnt.mra" > "${TMP}/STARTPATH"
build_meta "tmnt"
ok "all fields"  "${#META_FIELDS[@]}"    "11"
ok "paired"      "${META_COMPACT_COUNT}" "8"
ok "pinned"      "${META_PINNED_COUNT}"  "2"
ok "grid row 1"  "${META_FIELDS[0]}"  "$(printf 'Year\t1989')"
ok "grid row 1 right" "${META_FIELDS[1]}" "$(printf 'Manufctr\tKonami')"
ok "grid row 4 right" "${META_FIELDS[7]}" "$(printf 'MAME\t0229')"
# The wide list follows the paired one, in its own order.
ok "wide 1"      "${META_FIELDS[8]}"  "$(printf 'Players\t4')"
ok "wide 2"      "${META_FIELDS[9]}"  "$(printf 'Controls\t8-way')"
# Only the first <buttons count> names are the game's; "Start", "Coin" and
# "Pause" belong to the cabinet, and "-" is a placeholder. "/" rather than ","
# because metasanitize turns a comma into a space on the wire.
ok "wide 3"      "${META_FIELDS[10]}" "$(printf 'Buttons\tAttack/Jump')"
# Genre is known but not in either default list.
ok "genre not shown by default" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | grep -c '^Genre')" "0"

# Both lists pick and order their own fields, as METADATA_FIELDS does for the
# console layout. A name neither list knows is ignored.
ARCADE_FIELDS="Genre year Format" ARCADE_FIELDS_WIDE="Players" build_meta "tmnt"
ok "lists are honoured"  "${#META_FIELDS[@]}"    "3"
ok "paired counted"      "${META_COMPACT_COUNT}" "2"
ok "unlisted name ignored" "${META_FIELDS[1]}"   "$(printf 'Year\t1989')"
ok "genre on request"    "${META_FIELDS[0]}"     "$(printf 'Genre\tFighter / 2.5D')"
ok "wide list honoured"  "${META_FIELDS[2]}"     "$(printf 'Players\t4')"
# Year is pinned but is no longer first, so nothing may be pinned: the pinned
# row is the top of the grid, and it cannot start halfway down the list.
ok "pinning needs the first fields" "${META_PINNED_COUNT}" "0"

# A pinned name that is never shown - Version is in neither list - must not
# reserve a place, but must not stop the ones that are shown from pinning
# either: Year is still the first field on the grid.
ARCADE_PINNED="Version Year" build_meta "tmnt"
ok "unshown pinned name skipped" "${META_PINNED_COUNT}" "1"

unset ARCADE_FIELDS ARCADE_FIELDS_WIDE ARCADE_PINNED

# Arcade with log_file_entry off: no STARTPATH, must still work.
clear_state
build_meta "dkong"
ok "no startpath title"  "${META_TITLE}"  "dkong"
ok "no startpath source" "${META_SOURCE}" "core"

# ---------------------------------------------------------------------------
section "build_meta - console"
# ---------------------------------------------------------------------------
clear_state
printf '/media/fat/_Console/SNES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/SNES/Super Mario World (USA).sfc\n' > "${TMP}/FULLPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
build_meta "SNES"
ok "kind"         "${META_KIND}"   "console"
ok "title"        "${META_TITLE}"  "Super Mario World"
ok "source"       "${META_SOURCE}" "filename"
ok "system field" "${META_FIELDS[0]}" "$(printf 'System\tSNES')"
ok "region field" "${META_FIELDS[1]}" "$(printf 'Region\tUSA')"

# Same, but with a CRC index hit - the index title must win.
printf 'CRC32: B19ED489\n' > "${TMP}/GAMEID"
printf 'B19ED489|Super Mario World|USA|1990|Nintendo\n' > "${TMP}/titleindex"
build_meta "SNES"
ok "index overrides filename" "${META_TITLE}"  "Super Mario World"
ok "source is index"          "${META_SOURCE}" "index"

# Browsing the file list must NOT be treated as a load.
clear_state
printf '/media/fat/_Console/SNES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/SNES\n' > "${TMP}/FULLPATH"
printf 'active\n' > "${TMP}/FILESELECT"
build_meta "SNES"
ok "browsing is not a load" "${META_TITLE}"  "SNES"
ok "browsing source"        "${META_SOURCE}" "core"

# Launching a core from the menu is a file selection too - MiSTer writes
# FILESELECT=selected with the core's own .rbf. That is not a game, and taking
# it as one brought the split layout up on a freshly booted, empty core.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/FULLPATH"
printf 'NES_20240101.rbf\n'                     > "${TMP}/CURRENTPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
build_meta "NES"
ok   "rbf is not a game"      "${META_GAME}"   "no"
ok   "rbf title is the core"  "${META_TITLE}"  "NES"
ok   "rbf source is the core" "${META_SOURCE}" "core"

# An .mra selection is the arcade equivalent. Arcade cores classify from
# STARTPATH, so reach the console branch with a console STARTPATH.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf 'Donkey Kong.mra\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'        > "${TMP}/FILESELECT"
build_meta "NES"
ok   "mra is not a game"     "${META_GAME}"  "no"

# The same core file under a name that does not end in .rbf is still the core:
# STARTPATH names it, so the basename match has to catch it.
clear_state
printf '/media/fat/_Console/NES_core\n' > "${TMP}/STARTPATH"
printf 'NES_core\n' > "${TMP}/CURRENTPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
build_meta "NES"
ok   "startpath basename is not a game" "${META_GAME}" "no"

# ...but a real ROM sitting next to it still counts.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf 'Airwolf (USA).nes\n' > "${TMP}/CURRENTPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
build_meta "NES"
ok   "a real rom is still a game" "${META_GAME}"  "yes"
ok   "rom title"                  "${META_TITLE}" "Airwolf"

# The real core-launch case, taken from a diag capture. MiSTer writes the menu
# selection 3.3s before it writes CORENAME, so during that window the freshness
# check compares against the PREVIOUS core's CORENAME and the selection looks
# fresh. What is selected is the core's menu label, not a file.
clear_state
printf '/media/fat/_Console/Gameboy_20260603.rbf\n' > "${TMP}/STARTPATH"
printf '_Console\n'          > "${TMP}/FULLPATH"
printf 'Nintendo GameBoy\n'  > "${TMP}/CURRENTPATH"
printf 'selected\n'          > "${TMP}/FILESELECT"
build_meta "GAMEBOY"
ok   "menu label is not a game"  "${META_GAME}"   "no"
ok   "falls back to the core"    "${META_TITLE}"  "GAMEBOY"
ok   "core source"               "${META_SOURCE}" "core"

# MiSTer strips the extension from CURRENTPATH for any core that declares a
# single one, so these are complete selections, not menu labels. Requiring an
# extension rejected every load on these systems. Taken from a capture.
while IFS='|' read -r core folder entry want; do
  [ -n "${core}" ] || continue
  clear_state
  printf '/media/fat/_Console/%s.rbf\n' "${core}" > "${TMP}/STARTPATH"
  printf '%s\n' "${folder}" > "${TMP}/FULLPATH"
  printf '%s\n' "${entry}"  > "${TMP}/CURRENTPATH"
  printf 'selected\n'       > "${TMP}/FILESELECT"
  build_meta "${core}"
  ok "${core}: ${entry}" "${META_GAME}|${META_TITLE}" "yes|${want}"
done <<'EOF'
GBA|games/GBA|007 - Everything or Nothing (USA, Europe) (En,Fr,De)|007 - Everything or Nothing
VirtualBoy|games/VirtualBoy|3-D Tetris (USA)|3-D Tetris
GameGear|games/GameGear|Aladdin (USA, Europe)|Aladdin
S32X|games/S32X|After Burner 32X (JU) [!]|After Burner 32X
NEOGEO|games/NEOGEO|Aero Fighters 3|Aero Fighters 3
TGFX16|../usb0/games/TGFX16-CD|Bonk III - Bonk's Big Adventure (USA)|Bonk III - Bonk's Big Adventure
PSX|../usb0/games/PSX|007 - The World Is Not Enough (USA).chd|007 - The World Is Not Enough
EOF

# ...while the core browser's own entries, which look identical bar the
# folder, are still rejected. This is the rule doing the real work.
while IFS='|' read -r core entry; do
  [ -n "${core}" ] || continue
  clear_state
  printf '/media/fat/_Console/%s.rbf\n' "${core}" > "${TMP}/STARTPATH"
  printf '_Console\n'      > "${TMP}/FULLPATH"
  printf '%s\n' "${entry}" > "${TMP}/CURRENTPATH"
  printf 'selected\n'      > "${TMP}/FILESELECT"
  build_meta "${core}"
  ok "core launch: ${entry}" "${META_GAME}" "no"
done <<'EOF'
GBA|Nintendo GameBoy Advance
NEOGEO|Neo Geo MVS/AES
3DO|Panasonic 3DO
GameGear|SEGA Game Gear
TGFX16|PC Engine/CD
VirtualBoy|Nintendo Virtual Boy
EOF

# A .mgl launches a core just as a .rbf does - the Game Gear entry is one.
clear_state
printf '/media/fat/_Console/Game Gear.mgl\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/GameGear\n' > "${TMP}/FULLPATH"
printf 'Game Gear.mgl\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'      > "${TMP}/FILESELECT"
build_meta "GameGear"
ok "an .mgl is not a game" "${META_GAME}" "no"

# Directory entries are not games either.
for e in . ..; do
  clear_state
  printf '/media/fat/_Console/TGFX16.rbf\n' > "${TMP}/STARTPATH"
  printf 'games/TGFX16\n' > "${TMP}/FULLPATH"
  printf '%s\n' "${e}"    > "${TMP}/CURRENTPATH"
  printf 'selected\n'     > "${TMP}/FILESELECT"
  build_meta "TGFX16"
  ok "[${e}] is not a game" "${META_GAME}" "no"
done

# Opening the OSD after a load rewrites FILESELECT to "cancelled" with
# CURRENTPATH unchanged. The game is still running; the card must stay.
clear_state
printf '/media/fat/_Console/PSX.rbf\n' > "${TMP}/STARTPATH"
printf '../usb0/games/PSX\n' > "${TMP}/FULLPATH"
printf '007 - The World Is Not Enough (USA).chd\n' > "${TMP}/CURRENTPATH"
printf 'selected\n' > "${TMP}/FILESELECT"
build_meta "PSX"
ok "loaded"  "${META_GAME}" "yes"
printf 'cancelled\n' > "${TMP}/FILESELECT"
build_meta "PSX"
ok "survives an OSD open/close" "${META_GAME}"  "yes"
ok "and is still the same game" "${META_TITLE}" "007 - The World Is Not Enough"

# But browsing to something else is not a load.
printf 'Some Other Game (USA).chd\n' > "${TMP}/CURRENTPATH"
printf 'active\n' > "${TMP}/FILESELECT"
build_meta "PSX"
ok "browsing elsewhere is not a load" "${META_GAME}" "no"

# A selection from a core folder is never a ROM, extension or not.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '_Computer\n'   > "${TMP}/FULLPATH"
printf 'Thing.nes\n'   > "${TMP}/CURRENTPATH"
printf 'selected\n'    > "${TMP}/FILESELECT"
build_meta "NES"
ok   "core folder is not a game" "${META_GAME}" "no"

# A ROM in a normal games folder is unaffected by either rule.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/NES\n'  > "${TMP}/FULLPATH"
printf 'Airwolf (USA).nes\n'     > "${TMP}/CURRENTPATH"
printf 'selected\n'              > "${TMP}/FILESELECT"
build_meta "NES"
ok   "real rom survives both rules" "${META_GAME}"  "yes"
ok   "real rom title"               "${META_TITLE}" "Airwolf"

# Cores that rewrite CORENAME as the ROM loads - GBA, Game Gear, Virtual Boy,
# NeoGeo, 32X - put the core name and the selection in the same second, and
# bash's -nt only compares whole seconds. Asking "is the selection newer than
# CORENAME" answered no for every load on those systems and the display never
# left the full-screen artwork.
clear_state
printf '/media/fat/_Console/GBA_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/GBA\n'    > "${TMP}/FULLPATH"
printf 'Advance Wars (USA).gba\n'  > "${TMP}/CURRENTPATH"
printf 'selected\n'                > "${TMP}/FILESELECT"
printf 'GBA\n'                     > "${TMP}/CORENAME"
# Pin the mtimes equal rather than trusting the writes to land in the same
# second - straddling a boundary made this pass or fail by the clock.
touch -r "${TMP}/CURRENTPATH" "${TMP}/CORENAME"
build_meta "GBA" corechange
ok "same-second core rewrite still loads" "${META_GAME}"  "yes"
ok "and gets the title"                   "${META_TITLE}" "Advance Wars"

# A core genuinely launched from the menu lands a second or more later, so it
# is still caught.
clear_state
printf '/media/fat/_Console/GBA_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/GBA\n'    > "${TMP}/FULLPATH"
printf 'Advance Wars (USA).gba\n'  > "${TMP}/CURRENTPATH"
printf 'selected\n'                > "${TMP}/FILESELECT"
printf 'GBA\n' > "${TMP}/CORENAME"
# Explicitly a second later, so "the core started after this selection" is
# the thing under test and not a race.
touch -d '@2000000010' "${TMP}/CORENAME"
touch -d '@2000000000' "${TMP}/CURRENTPATH"
touch -d '@2000000000' "${TMP}/FULLPATH"
build_meta "GBA" corechange
ok "leftover selection still rejected" "${META_GAME}" "no"

# ...and it stays rejected on the polls that follow, which do not pass
# corechange. Without the latch the next poll would accept it.
build_meta "GBA"
ok "leftover stays rejected on a refresh" "${META_GAME}" "no"

# A genuinely new selection in the same core is accepted, latch or not.
printf 'Golden Sun (USA).gba\n' > "${TMP}/CURRENTPATH"
build_meta "GBA"
ok "a new selection is accepted"  "${META_GAME}"  "yes"
ok "and is the new game"          "${META_TITLE}" "Golden Sun"

# ---------------------------------------------------------------------------
section "find_rompath - games on the SD card or on USB"
# ---------------------------------------------------------------------------
# Games may be installed on either, and MiSTer reports the folder relative to
# the SD card, so the same relative path has to be tried under every root.
mkdir -p "${TMP}/fat/games/NES" "${TMP}/usb0/games/GBA" "${TMP}/usb0/games/NEOGEO"
: > "${TMP}/fat/games/NES/Airwolf (USA).nes"
: > "${TMP}/usb0/games/GBA/3-D Tetris (USA).gba"
: > "${TMP}/usb0/games/GBA/After Burner 32X (JU) [!].32x"
mkdir -p "${TMP}/usb0/games/NEOGEO/Aero Fighters 3"
export GAME_ROOTS="${TMP}/fat ${TMP}/usb0 ${TMP}/nonexistent"

find_rompath "games/NES" "Airwolf (USA).nes"
ok "found on the sd card" "${ROM_PATH}" "${TMP}/fat/games/NES/Airwolf (USA).nes"

find_rompath "games/GBA" "3-D Tetris (USA)"
ok "found on usb0 without an extension" \
   "${ROM_PATH}" "${TMP}/usb0/games/GBA/3-D Tetris (USA).gba"

# A ROM name is not a glob. "[!]" is a bracket expression if it leaks into
# pathname expansion, and would match nothing.
find_rompath "games/GBA" "After Burner 32X (JU) [!]"
ok "glob characters in the name are literal" \
   "${ROM_PATH}" "${TMP}/usb0/games/GBA/After Burner 32X (JU) [!].32x"

# NeoGeo games are folders, not files.
find_rompath "games/NEOGEO" "Aero Fighters 3"
ok "a folder counts"  "${ROM_PATH}" "${TMP}/usb0/games/NEOGEO/Aero Fighters 3"

find_rompath "games/NES" "Not Here"
ok "missing returns non-zero" "$?" "1"
ok "and clears ROM_PATH"      "${ROM_PATH}" ""

# An absolute FULLPATH is used as given, no roots involved.
find_rompath "${TMP}/fat/games/NES" "Airwolf (USA).nes"
ok "absolute path used directly" "${ROM_PATH}" "${TMP}/fat/games/NES/Airwolf (USA).nes"

# ...and the extension reaches the Format field, which was blank for every
# core that declares a single extension.
clear_state
printf '/media/fat/_Console/GBA_20260530.rbf\n' > "${TMP}/STARTPATH"
printf 'games/GBA\n'        > "${TMP}/FULLPATH"
printf '3-D Tetris (USA)\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'         > "${TMP}/FILESELECT"
METADATA_FIELDS="Format" build_meta "GBA"
ok "Format recovered from the file on usb0" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "GBA"

# A selection that is not on disk still shows, just without a Format.
clear_state
printf '/media/fat/_Console/GBA_20260530.rbf\n' > "${TMP}/STARTPATH"
printf 'games/GBA\n'         > "${TMP}/FULLPATH"
printf 'Not On This Disk\n'  > "${TMP}/CURRENTPATH"
printf 'selected\n'          > "${TMP}/FILESELECT"
METADATA_FIELDS="System Format" build_meta "GBA"
ok "missing file is still a game" "${META_GAME}"  "yes"
ok "title still shown"            "${META_TITLE}" "Not On This Disk"
ok "no Format field"              "$(printf '%s\n' "${META_FIELDS[@]}" | grep -c '^Format')" "0"

# An extension MiSTer did report is not second-guessed.
clear_state
printf '/media/fat/_Console/PSX.rbf\n' > "${TMP}/STARTPATH"
printf 'games/PSX\n'  > "${TMP}/FULLPATH"
printf 'Something (USA).chd\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'   > "${TMP}/FILESELECT"
METADATA_FIELDS="Format" build_meta "PSX"
ok "reported extension kept" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "CHD"

unset GAME_ROOTS
export GAME_ROOTS="/media/fat /media/usb0"

# ---------------------------------------------------------------------------
section "names.txt - show cores by the name the user configured"
# ---------------------------------------------------------------------------
export NAMES_TXT="${TMP}/names.txt"
cat > "${NAMES_TXT}" <<'EOF'
# MiSTer's own format: <core file key>:<display name>
GBA:Nintendo GameBoy Advance
Game Gear:SEGA Game Gear
TGFX16:PC Engine/CD
NEOGEO:Neo Geo MVS/AES
  MegaCD  :  SEGA CD
; a comment
EmptyValue:
EOF

# Keyed on CORENAME.
clear_state
printf '/media/fat/_Console/GBA_20260530.rbf\n' > "${TMP}/STARTPATH"
printf 'games/GBA\n'          > "${TMP}/FULLPATH"
printf '3-D Tetris (USA)\n'   > "${TMP}/CURRENTPATH"
printf 'selected\n'           > "${TMP}/FILESELECT"
METADATA_FIELDS="System" build_meta "GBA"
ok "System uses the configured name" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "Nintendo GameBoy Advance"

# Keyed on the STARTPATH basename, for a core launched through an .mgl.
clear_state
printf '/media/fat/_Console/Game Gear.mgl\n' > "${TMP}/STARTPATH"
printf 'games/GameGear\n'        > "${TMP}/FULLPATH"
printf 'Aladdin (USA, Europe)\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'              > "${TMP}/FILESELECT"
METADATA_FIELDS="System" build_meta "GameGear"
ok "mgl basename key" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "SEGA Game Gear"

# Keyed on the basename with the _YYYYMMDD build date stripped.
clear_state
printf '/media/fat/_Console/TGFX16_20260603.rbf\n' > "${TMP}/STARTPATH"
printf 'games/TGFX16\n'   > "${TMP}/FULLPATH"
printf 'Bonk III (USA)\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'       > "${TMP}/FILESELECT"
METADATA_FIELDS="System" build_meta "SomethingElse"
ok "dated basename key" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "PC Engine/CD"

# Whitespace around key and value is trimmed.
clear_state
printf '/media/fat/_Console/MegaCD_20260603.rbf\n' > "${TMP}/STARTPATH"
printf 'games/MegaCD\n'  > "${TMP}/FULLPATH"
printf 'Snatcher (USA).chd\n' > "${TMP}/CURRENTPATH"
printf 'selected\n'      > "${TMP}/FILESELECT"
METADATA_FIELDS="System" build_meta "MegaCD"
ok "whitespace trimmed" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "SEGA CD"

# A core with no entry keeps its own name, as does an entry with no value.
clear_state
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf 'games/NES\n'      > "${TMP}/FULLPATH"
printf 'Airwolf (USA)\n'  > "${TMP}/CURRENTPATH"
printf 'selected\n'       > "${TMP}/FILESELECT"
METADATA_FIELDS="System" build_meta "NES"
ok "no entry falls back to the core name" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "NES"
METADATA_FIELDS="System" build_meta "EmptyValue"
ok "empty value falls back too" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f2)" "EmptyValue"

# The console core with nothing loaded shows the configured name too.
clear_state
printf '/media/fat/_Console/GBA_20260530.rbf\n' > "${TMP}/STARTPATH"
build_meta "GBA"
ok "no-game title uses the configured name" "${META_TITLE}" "Nintendo GameBoy Advance"
ok "but the icon key stays the core name"   "${META_ICON}"  "GBA"

# Switched off, the core name is used unchanged.
clear_state
printf '/media/fat/_Console/GBA_20260530.rbf\n' > "${TMP}/STARTPATH"
USE_NAMES_TXT="no" build_meta "GBA"
ok "USE_NAMES_TXT=no disables it" "${META_TITLE}" "GBA"

# Missing names.txt must not break anything.
NAMES_TXT="${TMP}/does-not-exist" build_meta "GBA"
ok "missing names.txt is harmless" "${META_TITLE}" "GBA"

export NAMES_TXT="${TMP}/no-names-here"

# ---------------------------------------------------------------------------
section "the shipped coretypes.ini classifies without STARTPATH"
# ---------------------------------------------------------------------------
# classify_core falls back to the _Console / _Computer folder in STARTPATH,
# and a core that publishes no STARTPATH lands on "unknown" - which switches
# the metadata display off and leaves the artwork full-screen with no game
# ever shown. The shipped map makes it explicit for every core we know of.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAVED_MAP="${CORETYPE_MAP}"
export CORETYPE_MAP="${REPO_ROOT}/coretypes.ini"

for c in NES SNES GAMEBOY GBC GBA N64 VirtualBoy MegaDrive MegaCD S32X SMS \
         GameGear TGFX16 PSX 3DO Saturn NEOGEO NGP Atari2600 AtariLynx \
         WonderSwan WonderSwanColor; do
  clear_state                      # no STARTPATH at all
  build_meta "${c}"
  ok "${c} classifies as console" "${META_KIND}" "console"
done

for c in Amiga C64 ZX-Spectrum AO486 AtariST; do
  clear_state
  build_meta "${c}"
  ok "${c} classifies as computer" "${META_KIND}" "computer"
done

# The map must not override the definitive arcade signal.
clear_state
printf '/media/fat/_Arcade/Donkey Kong.mra\n' > "${TMP}/STARTPATH"
build_meta "NES"
ok "an .mra still wins over the map" "${META_KIND}" "arcade"

export CORETYPE_MAP="${SAVED_MAP}"

# ---------------------------------------------------------------------------
section "check_mister_ini"
# ---------------------------------------------------------------------------
clear_state
printf '[MiSTer]\nlog_file_entry=1\n' > "${TMP}/MiSTer.ini"
check_mister_ini
ok "enabled detected"  "${MISTER_LOGFILEENTRY}" "yes"

printf '[MiSTer]\n; log_file_entry=1\n' > "${TMP}/MiSTer.ini"
check_mister_ini
ok "commented out"     "${MISTER_LOGFILEENTRY}" "no"

printf '[MiSTer]\nlog_file_entry = 1\n' > "${TMP}/MiSTer.ini"
check_mister_ini
ok "spaces tolerated"  "${MISTER_LOGFILEENTRY}" "yes"

rm -f "${TMP}/MiSTer.ini"
check_mister_ini
ok "missing ini"       "${MISTER_LOGFILEENTRY}" "unknown"

# ---------------------------------------------------------------------------
clear_state
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
