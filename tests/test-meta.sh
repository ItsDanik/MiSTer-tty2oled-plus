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
ok "field count" "${#META_FIELDS[@]}" "5"
ok "field 1"     "${META_FIELDS[0]}" "$(printf 'Year\t1981')"
ok "field 2"     "${META_FIELDS[1]}" "$(printf 'Manufacturer\tNintendo of America')"

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
