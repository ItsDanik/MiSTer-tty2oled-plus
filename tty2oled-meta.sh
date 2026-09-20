#!/bin/bash
#
# tty2oled-meta.sh - Game metadata extraction library
#
# Part of the tty2oled game-metadata fork.
# Sourced by tty2oled.sh; contains no top-level side effects so it can also be
# sourced by the test harness and run on a normal workstation.
#
# Responsibilities:
#   classify_core   - decide whether the running core is arcade/console/computer
#   parse_mra       - pull name/year/manufacturer/category out of an .mra file
#   clean_romname   - turn a ROM filename into a display title + region
#   read_gameid     - read CRC32/serial that MiSTer wrote to /tmp/GAMEID
#   lookup_crc      - resolve a CRC32 against the optional local title index
#   build_meta      - top-level: produce the field list for the current game
#
# All functions write their results into well-known globals rather than echoing,
# to avoid a subshell per call in the hot path (core switching should feel
# instant).
#
# Requires MiSTer.ini to contain:  log_file_entry=1
# Without it MiSTer never writes FULLPATH/STARTPATH/GAMEID and only core-level
# display is possible. check_mister_ini() reports this once.

# ---------------------------------------------------------------------------
# State files written by MiSTer's Main binary (see user_io.cpp / menu.cpp).
# All except CORENAME/RBFNAME require log_file_entry=1.
# ---------------------------------------------------------------------------
: "${MISTER_CORENAME:=/tmp/CORENAME}"     # core name, or MRA <setname> for arcade
: "${MISTER_RBFNAME:=/tmp/RBFNAME}"       # core's own name from its confstr
: "${MISTER_STARTPATH:=/tmp/STARTPATH}"   # .mra path (arcade) or .rbf path
: "${MISTER_FULLPATH:=/tmp/FULLPATH}"     # full path of the selected ROM/disk
: "${MISTER_CURRENTPATH:=/tmp/CURRENTPATH}" # basename of the selected item
: "${MISTER_FILESELECT:=/tmp/FILESELECT}" # active | selected | cancelled
: "${MISTER_GAMEID:=/tmp/GAMEID}"         # CRC32: / Serial: lines
: "${MISTER_INI:=/media/fat/MiSTer.ini}"

# MiSTer's core renaming file. Lines are "<key>:<display name>", where the key
# is the core's .rbf/.mgl basename - with or without the _YYYYMMDD build date.
# It is what the MiSTer menu itself shows, so a display that says "GBA" while
# the menu says "Nintendo GameBoy Advance" is showing the wrong name.
: "${NAMES_TXT:=/media/fat/names.txt}"

# Optional CRC32 -> canonical title index, built by tools/build-title-index.
# Format: one record per line, "CRC32|Title|Region|Year|Publisher".
# Where games live. MiSTer reports FULLPATH relative to the SD card, so
# "games/GBA" is on the SD and "../usb0/games/PSX" is on USB - but a ROM set
# can be installed on either, and the same relative path is valid on both.
# Searched in order, first hit wins; missing roots are skipped.
: "${GAME_ROOTS:=/media/fat /media/usb0 /media/usb1 /media/usb2 /media/usb3 /media/usb4 /media/usb5 /media/fat/cifs}"

: "${TITLE_INDEX_DIR:=/media/fat/tty2oled/titleindex}"

# Legacy single-file index. Searched only when there is no per-core file, so an
# existing hand-made index keeps working.
: "${TITLE_INDEX:=/media/fat/tty2oled/titleindex.txt}"

# ---------------------------------------------------------------------------
# Outputs. Cleared by meta_reset, populated by build_meta.
# ---------------------------------------------------------------------------
META_KIND=""        # arcade | console | computer | unknown
META_TITLE=""       # primary display line
META_FIELDS=()      # ordered "Label\tValue" pairs for the console layout
META_ICON=""        # icon key used to find the 86x64 art
META_SOURCE=""      # where the title came from: mra | index | filename | core
META_GAME="no"      # yes when a real game is loaded, not just a core

# The selection rejected as leftover at the last core change, as
# "<romref>|<CURRENTPATH mtime>". Polls keep rejecting exactly this one until
# the selection changes; see the guard in build_meta for why it is latched
# rather than re-tested.
META_STALE_REF=""

# The selection that was actually loaded. MiSTer rewrites FILESELECT away from
# "selected" whenever the OSD is opened afterwards, so this is what keeps the
# running game on screen instead of dropping back to the artwork.
META_LAST_SELECTED=""

meta_reset() {
  META_KIND=""
  META_TITLE=""
  META_FIELDS=()
  META_ICON=""
  META_SOURCE=""
  META_GAME="no"        # yes once an actual game, not just a core, is identified
}

# Read a file into a variable, tolerating absence. Avoids a subshell.
_slurp() {
  local __var="${1}" __file="${2}" __val=""
  [ -r "${__file}" ] && IFS= read -r __val <"${__file}" 2>/dev/null
  printf -v "${__var}" '%s' "${__val}"
}

# ---------------------------------------------------------------------------
# check_mister_ini - warn once if log_file_entry is not enabled.
# MiSTer's cfg_parse() memsets the config to zero, so the option defaults to
# off and every path below except the core name goes dark without it.
# ---------------------------------------------------------------------------
MISTER_LOGFILEENTRY="unknown"
check_mister_ini() {
  if [ ! -r "${MISTER_INI}" ]; then
    MISTER_LOGFILEENTRY="unknown"
    return 0
  fi
  # Match log_file_entry=1 with optional spaces, ignoring commented lines.
  if grep -qiE '^[[:space:]]*log_file_entry[[:space:]]*=[[:space:]]*1' "${MISTER_INI}"; then
    MISTER_LOGFILEENTRY="yes"
  else
    MISTER_LOGFILEENTRY="no"
  fi
}

# ---------------------------------------------------------------------------
# find_rompath - locate the file or folder a selection refers to.
#
# MiSTer gives the containing folder in FULLPATH and the entry in CURRENTPATH,
# and the folder is relative to the SD card: "games/GBA", or "../usb0/games/PSX"
# for a USB set. Resolving it from /media/fat alone therefore works only for
# whichever root the user happened to install on, so every root in GAME_ROOTS
# is tried and the same relative path is looked for under each.
#
# The entry may have no extension - MiSTer strips it for any core declaring a
# single one - so a "<name>.*" glob is tried after the literal name. The name
# is kept quoted throughout because real ROM names contain glob characters:
# "After Burner 32X (JU) [!]" is a bracket expression if it is not.
#
# Sets: ROM_PATH ("" when nothing was found)
# ---------------------------------------------------------------------------
ROM_PATH=""
find_rompath() {
  local dir="${1:-}" name="${2:-}" root="" cand=""
  ROM_PATH=""
  [ -n "${name}" ] || return 1

  # An absolute FULLPATH needs no root; use it as given.
  if [ "${dir:0:1}" = "/" ]; then
    for cand in "${dir}/${name}" "${dir}/${name}".*; do
      if [ -e "${cand}" ]; then ROM_PATH="${cand}"; return 0; fi
    done
    return 1
  fi

  for root in ${GAME_ROOTS}; do
    [ -d "${root}" ] || continue
    for cand in "${root}/${dir}/${name}" "${root}/${dir}/${name}".*; do
      if [ -e "${cand}" ]; then ROM_PATH="${cand}"; return 0; fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# display_corename - the name the user has configured for this core.
#
# Looks the core up in names.txt, which MiSTer uses to rename cores in its own
# menu. Several keys are tried because the file is keyed on the core file and
# we hold the core name: the reported CORENAME, RBFNAME, and the STARTPATH
# basename both with and without its _YYYYMMDD build date. A Game Gear core
# started through "_Console/Game Gear.mgl" is keyed "Game Gear"; a GBA core in
# "GBA_20260530.rbf" is keyed "GBA".
#
# Falls back to the core name itself, so this is safe with no names.txt.
# Sets: DISPLAY_CORENAME
# ---------------------------------------------------------------------------
DISPLAY_CORENAME=""
display_corename() {
  local corename="${1}" rbfname="${2:-}" key="" base="" hit=""
  DISPLAY_CORENAME="${corename}"

  [ "${USE_NAMES_TXT:-yes}" = "yes" ] || return 0
  [ -r "${NAMES_TXT:-}" ] || return 0

  base="${CORE_STARTPATH##*/}"      # "GBA_20260530.rbf", "Game Gear.mgl"
  base="${base%.*}"                 # "GBA_20260530",     "Game Gear"

  for key in "${corename}" "${rbfname}" "${base}" "${base%_*}"; do
    [ -n "${key}" ] || continue
    # Exact key match on the part before the first colon, no globbing: core
    # names contain spaces and punctuation ("Neo Geo MVS/AES", "PC Engine/CD").
    hit="$(awk -F':' -v k="${key,,}" '
      /^[[:space:]]*[#;]/ { next }
      {
        n = $1
        sub(/^[[:space:]]+/, "", n); sub(/[[:space:]]+$/, "", n)
        if (tolower(n) != k) next
        v = substr($0, index($0, ":") + 1)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (v != "") { print v; exit }
      }
    ' "${NAMES_TXT:-}" 2>/dev/null)"
    if [ -n "${hit}" ]; then
      DISPLAY_CORENAME="${hit}"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# classify_core - decide how to present the running core.
#
# A .mra in STARTPATH is definitive: MiSTer only ever puts an XML there for
# arcade cores (user_io.cpp: strcpy(core_path, xml ? xml : path)).
# Otherwise fall back to the standard SD layout folder, then to a user map.
#
# Sets: META_KIND, and CORE_STARTPATH for later reuse.
# ---------------------------------------------------------------------------
CORE_STARTPATH=""
classify_core() {
  local corename="${1}" startpath="" dir="" lower=""

  _slurp startpath "${MISTER_STARTPATH}"
  CORE_STARTPATH="${startpath}"

  # 1. Definitive arcade signal.
  case "${startpath,,}" in
    *.mra) META_KIND="arcade"; return 0 ;;
  esac

  # 2. User override map wins over folder guessing, so odd setups can be fixed
  #    without patching the script. Format: "corename=kind" per line.
  if [ -n "${corename}" ] && [ -r "${CORETYPE_MAP}" ]; then
    local mapped=""
    mapped="$(grep -iE "^[[:space:]]*${corename}[[:space:]]*=" "${CORETYPE_MAP}" 2>/dev/null | head -n1)"
    if [ -n "${mapped}" ]; then
      mapped="${mapped#*=}"
      mapped="${mapped//[[:space:]]/}"
      case "${mapped,,}" in
        arcade|console|computer) META_KIND="${mapped,,}"; return 0 ;;
      esac
    fi
  fi

  # 3. Standard MiSTer SD layout: _Arcade / _Console / _Computer / _Other.
  if [ -n "${startpath}" ]; then
    dir="${startpath%/*}"
    lower="${dir,,}"
    case "${lower}" in
      */_arcade*)   META_KIND="arcade";   return 0 ;;
      */_console*)  META_KIND="console";  return 0 ;;
      */_computer*) META_KIND="computer"; return 0 ;;
    esac
  fi

  META_KIND="unknown"
  return 0
}

# ---------------------------------------------------------------------------
# parse_mra - extract display metadata from an .mra file.
#
# MRA is small XML with the interesting fields at the top level. MiSTer itself
# only reads <rbf>, <setname> and <rotation>; name/year/manufacturer/category
# are present on disk and unused. Parsed with sed rather than a real XML
# reader: these are single-line tags in every MRA in the wild, and this runs on
# every core change.
#
# Sets: MRA_NAME MRA_YEAR MRA_MANUFACTURER MRA_CATEGORY MRA_SETNAME MRA_MAMEVER
# ---------------------------------------------------------------------------
MRA_NAME=""; MRA_YEAR=""; MRA_MANUFACTURER=""; MRA_CATEGORY=""
MRA_SETNAME=""; MRA_MAMEVER=""

_xml_tag() {
  # _xml_tag <file> <tag> -> first occurrence's text content, entities decoded.
  #
  # Entity decoding is done inside sed rather than with bash parameter
  # substitution on purpose. Bash 5.2 made a bare "&" in the replacement of
  # ${var//pat/repl} mean "the matched text" (patsub_replacement, on by
  # default), so ${val//&amp;/&} silently becomes a no-op there while still
  # working on the older bash MiSTer ships. sed's "\&" escape behaves the same
  # on GNU sed and busybox sed, so it is the portable option.
  #
  # &amp; is decoded LAST so that an encoded entity such as "&amp;lt;" survives
  # as the literal text "&lt;" instead of being decoded twice into "<".
  local file="${1}" tag="${2}" val=""
  val="$(sed -n \
    -e "s|.*<${tag}>\(.*\)</${tag}>.*|\1|Ip" "${file}" 2>/dev/null \
    | head -n1 \
    | sed -e 's/&lt;/</g'   \
          -e 's/&gt;/>/g'   \
          -e 's/&quot;/"/g' \
          -e "s/&apos;/'/g" \
          -e 's/&#3[49];/'"'"'/g' \
          -e 's/&amp;/\&/g')"
  # Trim surrounding whitespace (MRA files are commonly tab-indented).
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "${val}"
}

parse_mra() {
  local mra="${1}"
  MRA_NAME=""; MRA_YEAR=""; MRA_MANUFACTURER=""; MRA_CATEGORY=""
  MRA_SETNAME=""; MRA_MAMEVER=""
  [ -r "${mra}" ] || return 1

  MRA_NAME="$(_xml_tag "${mra}" name)"
  MRA_YEAR="$(_xml_tag "${mra}" year)"
  MRA_MANUFACTURER="$(_xml_tag "${mra}" manufacturer)"
  MRA_CATEGORY="$(_xml_tag "${mra}" category)"
  MRA_SETNAME="$(_xml_tag "${mra}" setname)"
  MRA_MAMEVER="$(_xml_tag "${mra}" mameversion)"

  # An MRA with no <name> is malformed; fall back to the filename.
  if [ -z "${MRA_NAME}" ]; then
    MRA_NAME="${mra##*/}"
    MRA_NAME="${MRA_NAME%.[mM][rR][aA]}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# clean_romname - derive a display title and region from a ROM filename.
#
# Handles the two dominant naming conventions:
#   No-Intro:  Super Mario World (USA) (Rev 1).sfc
#   TOSEC:     Super Mario World (1990)(Nintendo)(US)[cr].sfc
# Strips dump-status tags, collapses whitespace, and pulls out the region.
#
# Sets: ROM_TITLE ROM_REGION ROM_EXT ROM_TAGS
# ---------------------------------------------------------------------------
ROM_TITLE=""; ROM_REGION=""; ROM_EXT=""; ROM_TAGS=""

clean_romname() {
  local path="${1}" base="" work="" seg="" upper=""
  ROM_TITLE=""; ROM_REGION=""; ROM_EXT=""; ROM_TAGS=""
  [ -n "${path}" ] || return 1

  base="${path##*/}"
  ROM_EXT="${base##*.}"
  # Only treat it as an extension if it looks like one.
  if [ "${ROM_EXT}" = "${base}" ] || [ "${#ROM_EXT}" -gt 4 ]; then
    ROM_EXT=""
  else
    base="${base%.*}"
  fi

  work="${base}"

  # Pull region out of any (...) group before we discard the groups.
  # Longest/most specific names first so "USA, Europe" doesn't match just "USA".
  local regions="World|USA, Europe|USA|Europe|Japan, USA|Japan|Germany|France|Spain|Italy|Australia|Korea|Brazil|Sweden|Netherlands|Canada|China|Taiwan|Asia|UK|US|EU|JP"
  local found=""
  found="$(printf '%s' "${work}" | grep -oiE "\((${regions})\)" | head -n1)"
  if [ -n "${found}" ]; then
    ROM_REGION="${found#(}"
    ROM_REGION="${ROM_REGION%)}"
    # Normalise the short forms.
    case "${ROM_REGION^^}" in
      US) ROM_REGION="USA" ;;
      EU) ROM_REGION="Europe" ;;
      JP) ROM_REGION="Japan" ;;
    esac
  fi

  # Collect dump-status tags in [...] for optional display.
  ROM_TAGS="$(printf '%s' "${work}" | grep -oE '\[[^]]*\]' | tr -d '[]' | paste -sd',' - 2>/dev/null)"

  # Remove every (...) and [...] group - these are metadata, not title.
  work="$(printf '%s' "${work}" | sed -E 's/\([^)]*\)//g; s/\[[^]]*\]//g')"

  # Collapse separators and whitespace.
  work="${work//_/ }"
  work="$(printf '%s' "${work}" | tr -s ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*-[[:space:]]*$//')"

  # "Legend of Zelda, The" -> "The Legend of Zelda"
  case "${work}" in
    *", The")  work="The ${work%, The}" ;;
    *", A")    work="A ${work%, A}" ;;
    *", An")   work="An ${work%, An}" ;;
    *", Le")   work="Le ${work%, Le}" ;;
    *", La")   work="La ${work%, La}" ;;
    *", Les")  work="Les ${work%, Les}" ;;
    *", Der")  work="Der ${work%, Der}" ;;
    *", Die")  work="Die ${work%, Die}" ;;
    *", Das")  work="Das ${work%, Das}" ;;
  esac

  ROM_TITLE="${work}"
  [ -n "${ROM_TITLE}" ] || ROM_TITLE="${base}"
  return 0
}

# ---------------------------------------------------------------------------
# read_gameid - read the CRC32/serial MiSTer computed for the loaded ROM.
# MiSTer skips BIOS files, so an absent/stale file is normal and not an error.
#
# Sets: GAME_CRC32 GAME_SERIAL
# ---------------------------------------------------------------------------
GAME_CRC32=""; GAME_SERIAL=""
read_gameid() {
  GAME_CRC32=""; GAME_SERIAL=""
  [ -r "${MISTER_GAMEID}" ] || return 1
  local line=""
  while IFS= read -r line; do
    case "${line}" in
      CRC32:*)  GAME_CRC32="${line#CRC32:}"; GAME_CRC32="${GAME_CRC32//[[:space:]]/}" ;;
      Serial:*) GAME_SERIAL="${line#Serial:}"; GAME_SERIAL="${GAME_SERIAL#"${GAME_SERIAL%%[![:space:]]*}"}" ;;
    esac
  done <"${MISTER_GAMEID}"
  return 0
}

# ---------------------------------------------------------------------------
# lookup_crc - resolve a CRC32 against the optional local title index.
# The index is plain text so it can be grepped without loading it into memory;
# a full No-Intro set is a few MB and greps in well under the serial latency.
#
# Sets: IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER IDX_GENRE IDX_DEVELOPER
# ---------------------------------------------------------------------------
IDX_TITLE=""; IDX_REGION=""; IDX_YEAR=""; IDX_PUBLISHER=""
IDX_GENRE=""; IDX_DEVELOPER=""; IDX_SERIAL=""
# Clear the index outputs. They are globals so build_meta can read them after
# the lookup, which means a call that does not run a lookup would otherwise
# show the previous game's year and publisher next to this game's title.
idx_reset() {
  IDX_TITLE=""; IDX_REGION=""; IDX_YEAR=""; IDX_PUBLISHER=""
  IDX_GENRE=""; IDX_DEVELOPER=""; IDX_SERIAL=""
}

# Core names that mean the same index. MiSTer's CORENAME is whatever the core
# puts in its confstr, which is not the name the index was built under: the
# Mega Drive core reports MEGADRIVE where libretro calls it Genesis, and one
# core often covers several systems (the Game Boy core plays Game Boy Color).
# Right side is the index file's base name.
#
# Add a line if a core of yours is missing - tty2oled-diag.sh prints the name
# your MiSTer actually reports, which is the left side.
_index_alias() {
  case "${1^^}" in
    MEGADRIVE|MEGADRIVE32X|SEGAGENESIS|SEGAMD) echo "GENESIS" ;;
    GBC|GAMEBOYCOLOR|GAMEBOY2|SGB)             echo "GAMEBOY" ;;
    ATARILYNX)                                 echo "LYNX" ;;
    WSWAN|WONDERSWANCOLOR|WSC)                 echo "WONDERSWAN" ;;
    GAMEGEAR|GG|SEGAGG|SG1000|SEGASG1000)      echo "SMS" ;;
    MASTERSYSTEM|SEGASMS)                      echo "SMS" ;;
    PCE|PCECD|TGFX16CD|TURBOGRAFX16)           echo "TGFX16" ;;
    SUPERGRAFX|SGX)                            echo "TGFX16" ;;
    32X|SEGA32X)                               echo "S32X" ;;
    NEOGEOPOCKETCOLOR|NGPC)                    echo "NGP" ;;
    VIRTUALBOY)                                echo "VIRTUALBOY" ;;
    NINTENDO64)                                echo "N64" ;;
    GAMEBOYADVANCE)                            echo "GBA" ;;
    COLECOVISION)                              echo "COLECO" ;;
    A2600|ATARI2600)                           echo "ATARI2600" ;;
    A5200|ATARI5200)                           echo "ATARI5200" ;;
    A7800|ATARI7800)                           echo "ATARI7800" ;;
    *) return 1 ;;
  esac
}

# Which index file covers this core. Tried in order: the core name as given,
# its alias, then a case-insensitive directory match - MiSTer is not
# consistent about capitalisation and a file named Genesis.idx should still
# answer for a core calling itself GENESIS.
_index_file() {
  local corename="${1:-}" alias="" cand="" f="" base=""

  if [ -n "${corename}" ]; then
    alias="$(_index_alias "${corename}")" || alias=""
    # Each candidate gets both spellings tried: exact first because it is a
    # single stat, then a case-insensitive sweep of the directory.
    for cand in "${corename}" ${alias:+"${alias}"}; do
      [ -n "${cand}" ] || continue
      if [ -r "${TITLE_INDEX_DIR}/${cand}.idx" ]; then
        printf '%s' "${TITLE_INDEX_DIR}/${cand}.idx"; return 0
      fi
      for f in "${TITLE_INDEX_DIR}"/*.idx; do
        [ -r "${f}" ] || continue
        base="${f##*/}"; base="${base%.idx}"
        if [ "${base,,}" = "${cand,,}" ]; then
          printf '%s' "${f}"; return 0
        fi
      done
    done
  fi

  [ -r "${TITLE_INDEX}" ] || return 1
  printf '%s' "${TITLE_INDEX}"
}

# ---------------------------------------------------------------------------
# lookup_name - resolve a cleaned title against the index.
#
# The fallback for when the CRC misses, which happens system-wide wherever
# MiSTer and No-Intro disagree about whether a header is part of the file.
# Matching is on the cleaned title, which both sides derive the same way
# (tests/test-index.sh pins that), so this is an exact comparison rather than
# a fuzzy one. A region hint breaks ties between regional releases; without
# one the first match wins.
#
# Sets the same IDX_* globals as lookup_crc.
# ---------------------------------------------------------------------------
lookup_name() {
  local title="${1}" region="${2:-}" corename="${3:-}" idx="" hit=""
  idx_reset
  [ -n "${title}" ] || return 1
  idx="$(_index_file "${corename}")" || return 1

  # awk rather than grep: a title is a plain string and may contain regex
  # metacharacters - "Super Mario Bros. 3", "Boulder Dash (Ltd.)".
  hit="$(awk -F'|' -v t="${title,,}" -v r="${region,,}" '
    tolower($2) != t { next }
    { if (best == "") best = $0 }
    r != "" && tolower($3) == r { print $0; found = 1; exit }
    END { if (!found && best != "") print best }
  ' "${idx}" 2>/dev/null)"
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER \
                   IDX_GENRE IDX_DEVELOPER IDX_SERIAL <<<"${hit}"
  return 0
}

# ---------------------------------------------------------------------------
# lookup_serial - resolve a disc serial against the index.
#
# The disc systems' key. Their CRC is computed per track and never matches
# what MiSTer hashes from a .chd or .cue, but MiSTer writes the disc serial
# ("SLUS-00594") to /tmp/GAMEID, and redump records it. Matched on the last
# column, exactly, case-insensitively.
# ---------------------------------------------------------------------------
lookup_serial() {
  local serial="${1}" corename="${2:-}" idx="" hit=""
  idx_reset
  [ -n "${serial}" ] || return 1
  idx="$(_index_file "${corename}")" || return 1

  hit="$(awk -F'|' -v s="${serial,,}" '
    tolower($8) == s { print; exit }
  ' "${idx}" 2>/dev/null)"
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER \
                   IDX_GENRE IDX_DEVELOPER IDX_SERIAL <<<"${hit}"
  return 0
}

lookup_crc() {
  local crc="${1^^}" corename="${2:-}" hit=""
  local idx=""
  idx_reset
  [ -n "${crc}" ] || return 1

  # One index file per core rather than one big one: a MiSTer greps this on
  # every game load, and a per-core file is a few hundred KB where a combined
  # one would be tens of MB. The legacy single file is the fallback.
  idx="$(_index_file "${corename}")" || return 1

  hit="$(grep -m1 -i "^${crc}|" "${idx}" 2>/dev/null)"
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER \
                   IDX_GENRE IDX_DEVELOPER IDX_SERIAL <<<"${hit}"
  return 0
}

# ---------------------------------------------------------------------------
# meta_addfield - append a "Label\tValue" pair, skipping empty values.
# ---------------------------------------------------------------------------
# Which console fields to show, in this order. The split layout has three rows
# and pages through anything past that, so listing all seven means the display
# spends its time cycling. Set METADATA_FIELDS in the ini to choose and to
# order them - the first three listed are the ones visible without waiting for
# the pager. Empty or unset means all of them, which is what older configs
# expect. Arcade fields have their own vocabulary and are not filtered by this.
: "${METADATA_FIELDS:=}"

# The order used when METADATA_FIELDS is not set.
_FIELD_ORDER_DEFAULT="System Region Year Company Genre Developer Format"

meta_addfield() {
  local label="${1}" value="${2}"
  [ -n "${value}" ] || return 0
  META_FIELDS+=("${label}"$'\t'"${value}")
}

# Emit the console fields held in META_AVAIL, honouring METADATA_FIELDS for
# both membership and order. Unknown names in the ini are ignored rather than
# emitted empty, so a typo costs a missing field, not a blank row.
declare -A META_AVAIL=()
meta_addfields_ordered() {
  local order="${METADATA_FIELDS:-${_FIELD_ORDER_DEFAULT}}"
  local want="" label=""
  for want in ${order}; do
    for label in ${_FIELD_ORDER_DEFAULT}; do
      if [ "${label,,}" = "${want,,}" ]; then
        meta_addfield "${label}" "${META_AVAIL[${label}]:-}"
        break
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# build_meta - top level. Produces META_KIND/META_TITLE/META_FIELDS/META_ICON
# for the core named in $1 (normally the contents of /tmp/CORENAME).
#
# Arcade : everything comes from the .mra sitting in STARTPATH.
# Console: filename-derived, upgraded by a CRC32 index hit when available.
# Computer/unknown: core-level only; the caller keeps the existing behaviour.
# ---------------------------------------------------------------------------
build_meta() {
  local corename="${1}" corechange="${2:-}" fullpath="" fileselect="" rbfname=""
  local currentpath="" romref="" _rbf=""

  meta_reset
  [ "${corechange}" = "corechange" ] && META_LAST_SELECTED=""
  classify_core "${corename}"
  _slurp _rbf "${MISTER_RBFNAME}"
  display_corename "${corename}" "${_rbf}"

  case "${META_KIND}" in

    arcade)
      if parse_mra "${CORE_STARTPATH}"; then
        META_TITLE="${MRA_NAME}"
        META_SOURCE="mra"
        META_GAME="yes"
        meta_addfield "Year"         "${MRA_YEAR}"
        meta_addfield "Manufacturer" "${MRA_MANUFACTURER}"
        meta_addfield "Category"     "${MRA_CATEGORY}"
        meta_addfield "Set"          "${MRA_SETNAME:-${corename}}"
        meta_addfield "MAME"         "${MRA_MAMEVER}"
      else
        # STARTPATH missing (log_file_entry off) - fall back to the corename,
        # which for arcade is already the MRA setname. Not names.txt: that is
        # keyed on core files, and an arcade setname is not one.
        META_TITLE="${corename}"
        META_SOURCE="core"
        META_GAME="yes"
        meta_addfield "Set" "${corename}"
      fi
      META_ICON="${corename}"
      ;;

    console)
      _slurp fullpath    "${MISTER_FULLPATH}"
      _slurp currentpath "${MISTER_CURRENTPATH}"
      _slurp fileselect  "${MISTER_FILESELECT}"
      _slurp rbfname     "${MISTER_RBFNAME}"

      # MiSTer splits the selection across two files. FULLPATH holds the
      # containing FOLDER - "games/GAMEBOY" - and CURRENTPATH the file name,
      # "A-mazing Tater (USA).gb". Taking the title from FULLPATH therefore
      # yields the folder name, which is how a Game Boy ROM came out titled
      # "GAMEBOY". CURRENTPATH is the one to read; FULLPATH stays as a fallback
      # for any setup where it does carry a complete path.
      romref="${currentpath:-${fullpath}}"

      # "." and ".." are browser entries, never games.
      case "${romref}" in .|..) romref="" ;; esac

      # Launching a core is itself a file selection: MiSTer writes
      # FILESELECT="selected" with the core's own file, exactly as it does for
      # a ROM. .mgl is here too - a core can be launched through one, as the
      # Game Gear entry "_Console/Game Gear.mgl" is.
      case "${romref,,}" in
        *.rbf|*.mra|*.mgl) romref="" ;;
      esac
      # Same thing by a different route: whatever STARTPATH says the core was
      # started from is the core, whatever it is called.
      if [ -n "${romref}" ] && [ -n "${CORE_STARTPATH}" ] &&
         [ "${romref##*/}" = "${CORE_STARTPATH##*/}" ]; then
        romref=""
      fi

      # The rule that actually separates a core launch from a game. MiSTer
      # keeps cores in top-level folders starting with an underscore, and the
      # core browser sets FULLPATH to that folder - "_Console" - while a game
      # sets it to the games folder, "games/GBA" or "../usb0/games/PSX".
      # Nothing selected from inside a core folder is a ROM, whatever the
      # entry is called, which is what catches the menu labels like
      # "Nintendo GameBoy Advance" and "Neo Geo MVS/AES".
      #
      # There used to be a test that a game must have a file extension. It
      # does not: MiSTer strips the extension from CURRENTPATH for any core
      # declaring a single one, so "3-D Tetris (USA)", "Aladdin (USA, Europe)"
      # and "Aero Fighters 3" are whole selections. That test rejected every
      # load on Game Boy Advance, Virtual Boy, Game Gear, NeoGeo, 32X and PC
      # Engine CD; only disc cores, which accept several extensions and so
      # keep the ".chd", were unaffected.
      case "${fullpath##*/}" in
        _*) romref="" ;;
      esac

      # FULLPATH is also written while merely browsing the file list
      # (MENU_FILE_SELECT1 writes it with FILESELECT="active"), so only
      # "selected" is a load.
      #
      # Afterwards MiSTer rewrites FILESELECT as the user opens and closes the
      # OSD - "cancelled", or "active" while browsing - with CURRENTPATH still
      # naming the game that is running. Keep showing the selection that was
      # actually loaded until a different one is chosen, or the card vanishes
      # the moment the menu is touched.
      if [ -n "${romref}" ]; then
        if [ "${fileselect}" = "selected" ]; then
          META_LAST_SELECTED="${romref}"
        elif [ "${romref}" != "${META_LAST_SELECTED}" ]; then
          romref=""
        fi
      fi

      # FULLPATH, FILESELECT and GAMEID persist in /tmp across a core change -
      # MiSTer writes them when a game is loaded and never clears them. A core
      # started from the menu would otherwise inherit the previous core's game.
      #
      # This only applies ON A CORE CHANGE. Once a core is running there is no
      # previous core to inherit from, and applying it anyway is what stopped
      # whole systems from ever showing a game: the Game Boy Advance, Game
      # Gear, Virtual Boy, NeoGeo and 32X cores rewrite CORENAME as the ROM
      # loads, so the selection was never "newer than" the core name and every
      # load looked like leftover state.
      #
      # The comparison is second-resolution - bash's -nt reads st_mtime, not
      # the nanoseconds - and MiSTer writes this whole set inside one second.
      # So ask whether CORENAME is strictly NEWER than the selection rather
      # than whether the selection is newer than CORENAME: same-second writes
      # then count as current, which is the safe way round. A core launched
      # from the menu lands seconds later and is still caught.
      if [ -n "${romref}" ]; then
        local sel_id=""
        sel_id="${romref}|$(stat -c %Y "${MISTER_CURRENTPATH}" 2>/dev/null || echo 0)"

        if [ "${corechange}" = "corechange" ]; then
          META_STALE_REF=""
          if [ -e "${MISTER_CORENAME}" ] &&
             [ "${MISTER_CORENAME}" -nt "${MISTER_CURRENTPATH}" ] &&
             [ "${MISTER_CORENAME}" -nt "${MISTER_FULLPATH}" ]; then
            # Remember exactly which selection was rejected, so the polls that
            # follow keep rejecting it without re-running a timestamp test that
            # cannot tell this case from a freshly loaded game.
            META_STALE_REF="${sel_id}"
            romref=""
          fi
        elif [ -n "${META_STALE_REF}" ] && [ "${sel_id}" = "${META_STALE_REF}" ]; then
          romref=""
        fi
      fi

      if [ -n "${romref}" ]; then
        clean_romname "${romref}"
        META_TITLE="${ROM_TITLE}"
        META_SOURCE="filename"
        META_GAME="yes"

        # Recover the extension MiSTer stripped, so Format is not blank on
        # every single-extension core. Needs the file itself, which is why
        # GAME_ROOTS covers both the SD card and USB - the ROM set may be on
        # either and the relative path MiSTer reports fits both.
        if [ -z "${ROM_EXT}" ] && find_rompath "${fullpath}" "${romref}"; then
          case "${ROM_PATH##*/}" in
            *.*) ROM_EXT="${ROM_PATH##*.}" ;;
          esac
        fi

        # Upgrade to the canonical title when the game is indexed. The index
        # wins over the filename because it is correct for renamed or badly
        # tagged dumps.
        #
        # GAMEID outlives its game exactly as FULLPATH does, and checking it
        # against CORENAME is not enough: the previous game was also loaded
        # after the core started, so its CRC passes that test. MiSTer writes
        # the selection first and the CRC a moment later, so for those few
        # hundred milliseconds GAMEID still describes the game before this
        # one - which is long enough for the daemon to wake on the selection
        # and display it. A GAMEID older than the selection is the previous
        # game's. Equal mtimes count as fresh: they are written together often
        # enough that requiring strictly newer would throw away good CRCs.
        idx_reset
        GAME_CRC32=""; GAME_SERIAL=""
        if [ ! "${MISTER_CURRENTPATH}" -nt "${MISTER_GAMEID}" ]; then
          read_gameid
        fi

        if [ -n "${GAME_CRC32}" ]; then
          lookup_crc "${GAME_CRC32}" "${corename}"
        fi
        # Disc systems have no usable CRC - MiSTer gives a serial instead.
        if [ -z "${IDX_TITLE}" ] && [ -n "${GAME_SERIAL}" ]; then
          lookup_serial "${GAME_SERIAL}" "${corename}"
        fi
        # The CRC is the precise key, but MiSTer and No-Intro do not always
        # hash the same bytes - an iNES header included in one and not the
        # other is enough to miss every time on a whole system. Fall back to
        # the title the filename gave us, which is the same cleaned form the
        # index stores.
        if [ -z "${IDX_TITLE}" ] && [ -n "${ROM_TITLE}" ]; then
          lookup_name "${ROM_TITLE}" "${ROM_REGION}" "${corename}"
        fi

        if [ -n "${IDX_TITLE}" ]; then
          META_TITLE="${IDX_TITLE}"
          META_SOURCE="index"
          [ -n "${IDX_REGION}" ] && ROM_REGION="${IDX_REGION}"
        fi

        META_AVAIL=(
          [System]="${DISPLAY_CORENAME}"
          [Region]="${ROM_REGION}"
          [Year]="${IDX_YEAR}"
          [Company]="${IDX_PUBLISHER}"
          [Genre]="${IDX_GENRE}"
          [Developer]="${IDX_DEVELOPER}"
          [Format]="${ROM_EXT^^}"
        )
        meta_addfields_ordered
        # CRC32 is deliberately not shown. It is how the title index is keyed,
        # not something a player wants on screen, and it crowds out real
        # fields on the four rows the split layout has.
      else
        # Console core with nothing loaded yet. There is no game to describe,
        # so the split layout would just show the core name next to an empty
        # icon panel. Leave META_GAME unset and the caller falls back to
        # upstream's full-screen artwork, which is the better screen here.
        META_TITLE="${DISPLAY_CORENAME}"
        META_SOURCE="core"
        meta_addfield "System" "${rbfname:-${corename}}"
      fi
      META_ICON="${corename}"
      ;;

    *)
      # computer / unknown - core-level display, unchanged from upstream.
      META_TITLE="${corename}"
      META_SOURCE="core"
      META_ICON="${corename}"
      ;;
  esac

  return 0
}
