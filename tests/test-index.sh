#!/bin/bash
#
# Title index: the libretro DAT parser, the index emitter, and the lookup.
#
# No network. The fixtures are real records copied out of libretro-database,
# trimmed to a handful of games.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0; FAIL=0
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { if [ "$2" = "$3" ]; then printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1));
         else printf '  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi; }

export CORETYPE_MAP="${TMP}/coretypes"
export TITLE_INDEX_DIR="${TMP}/titleindex"
export TITLE_INDEX="${TMP}/legacy.txt"
mkdir -p "${TITLE_INDEX_DIR}"
# shellcheck disable=SC1091
. "${REPO}/tty2oled-meta.sh"

# ---------------------------------------------------------------------------
section "dat2index.awk - libretro clrmamepro format"
# ---------------------------------------------------------------------------
cat > "${TMP}/year.dat" <<'EOF'
clrmamepro (
	name "Nintendo - Nintendo Entertainment System"
	description "Nintendo - Nintendo Entertainment System"
)

game (
	comment "10-Yard Fight (Japan)"
	releaseyear "1985"
	rom ( crc 44AA3EEB )
)

game (
	comment "Legend of Zelda, The (USA)"
	releaseyear "1987"
	rom ( crc 3ADA8E8A )
)

game (
	comment "No Year Here (USA)"
	rom ( crc DEADBEEF )
)

game (
	comment "No Crc Here (USA)"
	releaseyear "1999"
)
EOF

out="$(awk -v field=releaseyear -f "${REPO}/tools/dat2index.awk" "${TMP}/year.dat")"
ok "record count"        "$(printf '%s\n' "${out}" | wc -l)" "2"
ok "crc uppercased"      "$(printf '%s\n' "${out}" | head -1 | cut -f1)" "44AA3EEB"
ok "comment captured"    "$(printf '%s\n' "${out}" | head -1 | cut -f2)" "10-Yard Fight (Japan)"
ok "value captured"      "$(printf '%s\n' "${out}" | head -1 | cut -f3)" "1985"
ok "no value is skipped" "$(printf '%s\n' "${out}" | grep -c DEADBEEF)" "0"
ok "no crc is skipped"   "$(printf '%s\n' "${out}" | grep -c 'No Crc')" "0"

awk -v field=releaseyear -f "${REPO}/tools/dat2index.awk" /dev/null >/dev/null 2>&1
ok "empty input exits non-zero" "$?" "1"

# A lowercase crc in the dat must still index as uppercase, because the lookup
# keys on the uppercase CRC32 MiSTer reports.
printf 'game (\n\tcomment "Lower (USA)"\n\treleaseyear "1990"\n\trom ( crc abcd1234 )\n)\n' > "${TMP}/low.dat"
ok "lowercase crc normalised" \
   "$(awk -v field=releaseyear -f "${REPO}/tools/dat2index.awk" "${TMP}/low.dat" | cut -f1)" \
   "ABCD1234"

# ---------------------------------------------------------------------------
section "index-emit.awk - merge and clean"
# ---------------------------------------------------------------------------
{
  printf 'year\t44AA3EEB\t10-Yard Fight (Japan)\t1985\n'
  printf 'publisher\t44AA3EEB\t10-Yard Fight (Japan)\tNintendo\n'
  printf 'genre\t44AA3EEB\t10-Yard Fight (Japan)\tSports\n'
  printf 'developer\t44AA3EEB\t10-Yard Fight (Japan)\tIrem\n'
  printf 'year\t3ADA8E8A\tLegend of Zelda, The (USA)\t1987\n'
  printf 'publisher\t3ADA8E8A\tLegend of Zelda, The (USA)\tNintendo\n'
  printf 'year\tC986CDA2\t10-Yard Fight (USA, Europe)\t1985\n'
} > "${TMP}/tagged"

emitted="$(awk -f "${REPO}/tools/index-emit.awk" "${TMP}/tagged" | sort)"
printf '%s\n' "${emitted}" > "${TITLE_INDEX_DIR}/NES.idx"

ok "all four categories merge onto one line" \
   "$(printf '%s\n' "${emitted}" | grep '^44AA3EEB' )" \
   "44AA3EEB|10-Yard Fight|Japan|1985|Nintendo|Sports|Irem|"
ok "article moved to the front" \
   "$(printf '%s\n' "${emitted}" | grep '^3ADA8E8A' | cut -d'|' -f2)" \
   "The Legend of Zelda"
ok "missing categories stay empty" \
   "$(printf '%s\n' "${emitted}" | grep '^3ADA8E8A')" \
   "3ADA8E8A|The Legend of Zelda|USA|1987|Nintendo|||"
ok "longest region alternative wins" \
   "$(printf '%s\n' "${emitted}" | grep '^C986CDA2' | cut -d'|' -f3)" \
   "USA, Europe"

# ---------------------------------------------------------------------------
section "index titles match clean_romname"
# ---------------------------------------------------------------------------
# The index title and the filename fallback must produce the same string for
# the same game, or a CRC hit would visibly rename a game the user already
# knows by its filename-derived title.
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  printf 'year\tAAAAAAAA\t%s\t1990\n' "${name}" > "${TMP}/one"
  awk_title="$(awk -f "${REPO}/tools/index-emit.awk" "${TMP}/one" | cut -d'|' -f2)"
  awk_region="$(awk -f "${REPO}/tools/index-emit.awk" "${TMP}/one" | cut -d'|' -f3)"
  clean_romname "${name}.nes"
  ok "title: ${name}"  "${awk_title}"  "${ROM_TITLE}"
  ok "region: ${name}" "${awk_region}" "${ROM_REGION}"
done <<'EOF'
Legend of Zelda, The (USA)
10-Yard Fight (Japan)
Super Mario Bros. (World)
Contra (USA) [!]
Mega Man 2 (USA, Europe)
Castlevania III - Dracula's Curse (USA)
Adventures of Lolo, An (Europe)
Bio Miracle Bokutte Upa (Japan) (Rev 1)
EOF

# ---------------------------------------------------------------------------
section "lookup_crc - per-core index"
# ---------------------------------------------------------------------------
lookup_crc "44AA3EEB" "NES"
ok "found"        "$?"                "0"
ok "title"        "${IDX_TITLE}"      "10-Yard Fight"
ok "region"       "${IDX_REGION}"     "Japan"
ok "year"         "${IDX_YEAR}"       "1985"
ok "publisher"    "${IDX_PUBLISHER}"  "Nintendo"
ok "genre"        "${IDX_GENRE}"      "Sports"
ok "developer"    "${IDX_DEVELOPER}"  "Irem"

lookup_crc "44aa3eeb" "NES"
ok "lowercase crc from GAMEID still hits" "${IDX_TITLE}" "10-Yard Fight"

lookup_crc "FFFFFFFF" "NES"
ok "miss returns non-zero" "$?" "1"
ok "miss clears the fields" "${IDX_TITLE}" ""

lookup_crc "44AA3EEB" "SNES"
ok "wrong core does not hit" "$?" "1"

# The legacy single-file index is the fallback when no per-core file exists.
printf '99999999|Legacy Game|USA|1991|Someone\n' > "${TITLE_INDEX}"
lookup_crc "99999999" "NOSUCHCORE"
ok "legacy file still works"     "${IDX_TITLE}"  "Legacy Game"
ok "legacy five-field line"      "${IDX_PUBLISHER}" "Someone"
ok "legacy genre stays empty"    "${IDX_GENRE}"  ""

# ---------------------------------------------------------------------------
section "mamexml2index.awk - arcade-lineage consoles"
# ---------------------------------------------------------------------------
# The Neo Geo AES/MVS is arcade hardware, so none of libretro's four metadata
# categories carry it and the MAME set is the source instead.
cat > "${TMP}/mame.xml" <<'XMLEOF'
<mame>
	<game name="neogeo">
		<description>Neo-Geo BIOS</description>
		<year>1990</year>
		<manufacturer>SNK</manufacturer>
	</game>
	<game name="sonicwi3" romof="neogeo">
		<description>Aero Fighters 3 / Sonic Wings 3</description>
		<year>1995</year>
		<manufacturer>Video System Co.</manufacturer>
	</game>
	<game name="mslug" romof="neogeo">
		<description>Metal Slug - Super Vehicle-001</description>
		<year>1996</year>
		<manufacturer>Nazca</manufacturer>
	</game>
	<game name="ampersand" romof="neogeo">
		<description>Pop &amp; Rock</description>
		<year>1994</year>
		<manufacturer>A &amp; B</manufacturer>
	</game>
	<game name="galaga" romof="namcosys">
		<description>Galaga</description>
		<year>1981</year>
		<manufacturer>Namco</manufacturer>
	</game>
</mame>
XMLEOF

awk -v family=neogeo -f "${REPO}/tools/mamexml2index.awk" "${TMP}/mame.xml" > "${TMP}/ng"
awk -f "${REPO}/tools/index-emit.awk" "${TMP}/ng" | sort -u > "${TITLE_INDEX_DIR}/NEOGEO.idx"

ok "other hardware excluded" \
   "$(grep -ci galaga "${TITLE_INDEX_DIR}/NEOGEO.idx")" "0"
ok "the bios set is excluded" \
   "$(grep -ci 'neo-geo bios' "${TITLE_INDEX_DIR}/NEOGEO.idx")" "0"

lookup_name "Aero Fighters 3" "" "NEOGEO"
ok "primary title"      "${IDX_YEAR}|${IDX_PUBLISHER}" "1995|Video System Co."
lookup_name "Sonic Wings 3" "" "NEOGEO"
ok "alias after the slash resolves too" "${IDX_YEAR}" "1995"
ok "and keeps its own title"            "${IDX_TITLE}" "Sonic Wings 3"

lookup_name "Metal Slug - Super Vehicle-001" "" "NEOGEO"
ok "a hyphen is not an alias separator" "${IDX_PUBLISHER}" "Nazca"

lookup_name "Pop & Rock" "" "NEOGEO"
ok "xml entities decoded in the title"     "$?" "0"
ok "xml entities decoded in the publisher" "${IDX_PUBLISHER}" "A & B"

awk -v family=nosuchfamily -f "${REPO}/tools/mamexml2index.awk" "${TMP}/mame.xml" >/dev/null 2>&1
ok "unknown family exits non-zero" "$?" "1"

rm -f "${TITLE_INDEX_DIR}/NEOGEO.idx"

# ---------------------------------------------------------------------------
section "png2gsc.py - artwork for the display"
# ---------------------------------------------------------------------------
if python3 -c "import PIL" 2>/dev/null; then
  python3 - "${TMP}/src.png" <<'PILEOF'
import sys
from PIL import Image, ImageDraw
im = Image.new("RGBA", (200, 150), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
for i in range(16):
    d.rectangle([i * 12, 0, i * 12 + 11, 40], fill=(i * 17,) * 3 + (255,))
im.save(sys.argv[1])
PILEOF

  "${REPO}/tools/png2gsc.py" --out "${TMP}/icon.gsc" "${TMP}/src.png" >/dev/null
  ok "icon header width"  "$(sed -n '1p' "${TMP}/icon.gsc")" "#define icon_width 86"
  ok "icon header height" "$(sed -n '2p' "${TMP}/icon.gsc")" "#define icon_height 64"
  # The daemon sends the file through exactly this pipeline, and the firmware
  # reads a fixed ICON_BYTES - a byte out and it is dropped as truncated.
  ok "icon wire bytes" \
     "$(tail -n +4 "${TMP}/icon.gsc" | xxd -r -p | wc -c)" "2752"

  "${REPO}/tools/png2gsc.py" --boot --out "${TMP}/boot.gsc" "${TMP}/src.png" >/dev/null
  ok "boot header width" "$(sed -n '1p' "${TMP}/boot.gsc")" "#define icon_width 256"
  ok "boot wire bytes" \
     "$(tail -n +4 "${TMP}/boot.gsc" | xxd -r -p | wc -c)" "8192"

  # Only 0-f may appear; a stray character would desynchronise xxd.
  ok "hex nibbles only" \
     "$(tail -n +4 "${TMP}/icon.gsc" | tr -d '\n' | tr -d '0-9a-f' | wc -c)" "0"
  # A 16-level ramp must survive as 16 distinct levels.
  ok "all 16 grey levels preserved" \
     "$(tail -n +4 "${TMP}/icon.gsc" | tr -d '\n' | fold -w1 | sort -u | tr -d '\n')" \
     "0123456789abcdef"
else
  printf '  \033[33mskip\033[0m png2gsc: Pillow not installed\n'
fi

# ---------------------------------------------------------------------------
section "_index_file - core name to index file"
# ---------------------------------------------------------------------------
rm -f "${TITLE_INDEX}"
: > "${TITLE_INDEX_DIR}/GENESIS.idx"
: > "${TITLE_INDEX_DIR}/Gameboy.idx"

ok "exact name"      "$(_index_file GENESIS)"   "${TITLE_INDEX_DIR}/GENESIS.idx"
ok "alias"           "$(_index_file MEGADRIVE)" "${TITLE_INDEX_DIR}/GENESIS.idx"
ok "case-insensitive file match" \
                     "$(_index_file GAMEBOY)"   "${TITLE_INDEX_DIR}/Gameboy.idx"
ok "alias then case-insensitive" \
                     "$(_index_file GBC)"       "${TITLE_INDEX_DIR}/Gameboy.idx"
_index_file NOSUCHCORE >/dev/null
ok "unknown core with no legacy file" "$?" "1"

printf 'X|Y|Z\n' > "${TITLE_INDEX}"
ok "unknown core falls back to legacy" "$(_index_file NOSUCHCORE)" "${TITLE_INDEX}"
rm -f "${TITLE_INDEX}" "${TITLE_INDEX_DIR}/GENESIS.idx" "${TITLE_INDEX_DIR}/Gameboy.idx"

# ---------------------------------------------------------------------------
section "lookup_name - fallback when the CRC misses"
# ---------------------------------------------------------------------------
cat > "${TITLE_INDEX_DIR}/NES.idx" <<'EOF'
07135006|Airwolf|Japan||Acclaim|Shooter|Beam Software
23380680|Airwolf|Europe|1988|Acclaim|Shooter|Beam Software
44AA3EEB|10-Yard Fight|Japan|1985|Nintendo|Sports|Irem
3ADA8E8A|The Legend of Zelda|USA|1987|Nintendo|Role-playing (RPG)|Nintendo
99AA0011|Boulder Dash (Ltd.) 2.0|USA|1990|First Star|Puzzle|First Star
EOF

lookup_name "10-Yard Fight" "" "NES"
ok "name hit"            "$?"               "0"
ok "name hit year"       "${IDX_YEAR}"      "1985"
ok "name hit publisher"  "${IDX_PUBLISHER}" "Nintendo"

lookup_name "Airwolf" "Europe" "NES"
ok "region breaks the tie" "${IDX_YEAR}" "1988"
lookup_name "Airwolf" "Japan" "NES"
ok "other region"          "${IDX_PUBLISHER}" "Acclaim"
lookup_name "Airwolf" "" "NES"
ok "no region hint takes the first" "${IDX_REGION}" "Japan"

lookup_name "airwolf" "" "NES"
ok "match is case insensitive" "$?" "0"

# A title is a plain string, not a pattern. Regex metacharacters in it must
# match literally or not at all - never as a wildcard.
lookup_name "Boulder Dash (Ltd.) 2.0" "" "NES"
ok "metacharacters match literally" "${IDX_YEAR}" "1990"
lookup_name "Boulder Dash (Ltd.) 2X0" "" "NES"
ok "dot is not a wildcard" "$?" "1"

lookup_name "No Such Game" "" "NES"
ok "name miss returns non-zero" "$?" "1"
ok "name miss clears fields"    "${IDX_YEAR}" ""

# ---------------------------------------------------------------------------
section "lookup_serial - disc systems"
# ---------------------------------------------------------------------------
# redump gives a title, a region and a serial and nothing else, because
# libretro has no releaseyear/publisher/genre/developer for disc systems.
cat > "${TITLE_INDEX_DIR}/PSX.idx" <<'EOF'
000D989C|Pop n' Pop|Europe|||||SLES-01971
0014420D|Revolution X - Music Is the Weapon|Europe|||||SLES-00129
8ACD8FB1|Final Fantasy VII|USA|||||SLUS-00594
EOF

lookup_serial "SLUS-00594" "PSX"
ok "serial hit"        "$?"             "0"
ok "serial title"      "${IDX_TITLE}"   "Final Fantasy VII"
ok "serial region"     "${IDX_REGION}"  "USA"
ok "serial echoed"     "${IDX_SERIAL}"  "SLUS-00594"
ok "no year upstream"  "${IDX_YEAR}"    ""

lookup_serial "slus-00594" "PSX"
ok "serial is case insensitive" "$?" "0"

lookup_serial "SLUS-99999" "PSX"
ok "serial miss" "$?" "1"

# The serial is the eighth column; a seven-column reader would have left it in
# the developer field instead.
lookup_crc "8ACD8FB1" "PSX"
ok "crc read does not put serial in developer" "${IDX_DEVELOPER}" ""
ok "crc read fills serial"                     "${IDX_SERIAL}"    "SLUS-00594"

# A title with an apostrophe must survive the awk round trip.
lookup_name "Pop n' Pop" "" "PSX"
ok "apostrophe in title" "${IDX_SERIAL}" "SLES-01971"

# MiSTer writes Serial: for discs and CRC32: for cartridges; build_meta must
# reach the serial path when the CRC is absent.
export MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH"
export MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT"
export MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_CORENAME="${TMP}/CORENAME"
printf 'PSX
' > "${TMP}/CORENAME"
printf '/media/fat/_Console/PSX_20240101.rbf
' > "${TMP}/STARTPATH"
printf '/media/fat/games/PSX
' > "${TMP}/FULLPATH"
printf 'selected
' > "${TMP}/FILESELECT"
printf 'Some Badly Named Dump.chd
' > "${TMP}/CURRENTPATH"
sleep 0.01
printf 'Serial: SLUS-00594
' > "${TMP}/GAMEID"
METADATA_FIELDS="System Region Format" build_meta "PSX"
ok "serial upgraded the title" "${META_TITLE}"  "Final Fantasy VII"
ok "source is the index"       "${META_SOURCE}" "index"
ok "region came from the index" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | grep '^Region' | cut -f2)" "USA"

rm -f "${TITLE_INDEX_DIR}/PSX.idx"

# ---------------------------------------------------------------------------
section "stale GAMEID is not the current game"
# ---------------------------------------------------------------------------
export MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH"
export MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT"
export MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_CORENAME="${TMP}/CORENAME"
printf 'NES
' > "${TMP}/CORENAME"
printf '/media/fat/_Console/NES_20240101.rbf
' > "${TMP}/STARTPATH"
printf '/media/fat/games/NES
' > "${TMP}/FULLPATH"
printf 'selected
' > "${TMP}/FILESELECT"

# MiSTer writes the CRC a moment AFTER the selection, so right after a load
# GAMEID still holds the previous game's CRC. Taking it showed the previous
# game's year and publisher beside the new game's title, until the real CRC
# landed and replaced them.
printf 'CRC32: 3ADA8E8A
' > "${TMP}/GAMEID"          # the game before this one
sleep 0.01
printf '10-Yard Fight (Japan).nes
' > "${TMP}/CURRENTPATH"   # newer than GAMEID
METADATA_FIELDS="System Year Company" build_meta "NES"
ok "stale CRC is not used for the title" "${META_TITLE}" "10-Yard Fight"
ok "stale CRC year is not shown"    "$(printf '%s
' "${META_FIELDS[@]}" | grep -c '^Year')" "1"
ok "and the year is this game's"    "$(printf '%s
' "${META_FIELDS[@]}" | grep '^Year' | cut -f2)" "1985"

# Once MiSTer writes the real CRC, GAMEID is no longer older than the
# selection and the CRC path takes over again.
sleep 0.01
printf 'CRC32: 44AA3EEB
' > "${TMP}/GAMEID"
METADATA_FIELDS="System Year Company" build_meta "NES"
ok "fresh CRC is used"        "${META_SOURCE}" "index"
ok "fresh CRC gives the year"    "$(printf '%s
' "${META_FIELDS[@]}" | grep '^Year' | cut -f2)" "1985"

# A CRC that hits nothing must not leave the previous lookup's fields behind.
sleep 0.01
printf 'CRC32: DEADBEEF
' > "${TMP}/GAMEID"
printf 'The Legend of Zelda (USA).nes
' > "${TMP}/CURRENTPATH"
sleep 0.01
printf 'CRC32: DEADBEEF
' > "${TMP}/GAMEID"
METADATA_FIELDS="System Year Company" build_meta "NES"
ok "unknown CRC falls back to the name" "${META_TITLE}" "The Legend of Zelda"
ok "and gets that game's year"    "$(printf '%s
' "${META_FIELDS[@]}" | grep '^Year' | cut -f2)" "1987"
ok "not the previous game's"    "$(printf '%s
' "${META_FIELDS[@]}" | grep -c '1985')" "0"

# ---------------------------------------------------------------------------
section "METADATA_FIELDS selects and orders console fields"
# ---------------------------------------------------------------------------
export MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH"
export MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT"
export MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_CORENAME="${TMP}/CORENAME"
printf '/media/fat/_Console/NES_20240101.rbf\n' > "${TMP}/STARTPATH"
printf '/media/fat/games/NES\n'   > "${TMP}/FULLPATH"
printf '10-Yard Fight.nes\n'      > "${TMP}/CURRENTPATH"
printf 'selected\n'               > "${TMP}/FILESELECT"
printf 'CRC32: 44AA3EEB\n'        > "${TMP}/GAMEID"

printf 'CRC32: 44AA3EEB\n' > "${TMP}/GAMEID"
sleep 0.01
touch "${TMP}/GAMEID"
METADATA_FIELDS="" build_meta "NES"
ok "default order, all seven present" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f1 | paste -sd, -)" \
   "System,Region,Year,Company,Genre,Developer,Format"
ok "index title won over the filename" "${META_TITLE}"  "10-Yard Fight"
ok "source is the index"               "${META_SOURCE}" "index"

METADATA_FIELDS="Year Company System" build_meta "NES"
ok "ini order is honoured" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f1 | paste -sd, -)" \
   "Year,Company,System"
ok "unlisted fields dropped" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | grep -c Genre)" "0"

METADATA_FIELDS="Year Nonsense Genre" build_meta "NES"
ok "unknown field name ignored" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f1 | paste -sd, -)" \
   "Year,Genre"

# Arcade keeps its own vocabulary regardless of METADATA_FIELDS.
printf '/media/fat/_Arcade/Donkey Kong.mra\n' > "${TMP}/STARTPATH"
cat > "${TMP}/dk.mra" <<'EOF'
<misterromdescription>
  <name>Donkey Kong</name>
  <year>1981</year>
  <manufacturer>Nintendo</manufacturer>
</misterromdescription>
EOF
printf '%s\n' "${TMP}/dk.mra" > "${TMP}/STARTPATH"
METADATA_FIELDS="Year Company System" build_meta "dkong"
ok "arcade is not filtered by METADATA_FIELDS" \
   "$(printf '%s\n' "${META_FIELDS[@]}" | cut -f1 | grep -c Manufacturer)" "1"


# Every stub must be a real .gsc the firmware will accept, not a placeholder
# the daemon sends as a truncated transfer.
section "icon stubs are valid .gsc files"
bad=0
count=0
for f in "${REPO}"/pics_pri/ICON/*.gsc; do
  [ -e "${f}" ] || continue
  count=$((count + 1))
  n="$(tail -n +4 "${f}" | xxd -r -p | wc -c)"
  [ "${n}" -eq 2752 ] || { bad=$((bad + 1)); echo "    ${f##*/}: ${n} bytes"; }
done
ok "there are stubs"            "$([ "${count}" -gt 0 ] && echo yes || echo no)" "yes"
ok "all are 2752 wire bytes"    "${bad}" "0"
# Per file: tail -n +4 on a concatenation would skip only the first file's
# header and count the other 46 headers as pixel data.
nonblack=0
for f in "${REPO}"/pics_pri/ICON/*.gsc; do
  [ -e "${f}" ] || continue
  if tail -n +4 "${f}" | tr -d '\n0' | grep -q .; then
    nonblack=$((nonblack + 1))
  fi
done
ok "all pixels black"           "${nonblack}" "0"
ok "header says 86 wide"        "$(head -1 "${REPO}/pics_pri/ICON/GBA.gsc")" "#define icon_width 86"

# The names must be the ones CORENAME reports, or findicon looks for a file
# that is not there. coretypes.ini is the shared source for both.
for c in GBA VirtualBoy GameGear NEOGEO TGFX16 S32X MegaDrive MegaCD Saturn \
         PSX 3DO GBC AtariLynx WonderSwan WonderSwanColor Atari2600; do
  ok "stub exists: ${c}" "$([ -e "${REPO}/pics_pri/ICON/${c}.gsc" ] && echo yes || echo no)" "yes"
done

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
