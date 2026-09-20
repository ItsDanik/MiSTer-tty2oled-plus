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

# Optional CRC32 -> canonical title index, built by tools/build-title-index.
# Format: one record per line, "CRC32|Title|Region|Year|Publisher".
: "${TITLE_INDEX:=/media/fat/tty2oled/titleindex}"

# ---------------------------------------------------------------------------
# Outputs. Cleared by meta_reset, populated by build_meta.
# ---------------------------------------------------------------------------
META_KIND=""        # arcade | console | computer | unknown
META_TITLE=""       # primary display line
META_FIELDS=()      # ordered "Label\tValue" pairs for the console layout
META_ICON=""        # icon key used to find the 86x64 art
META_SOURCE=""      # where the title came from: mra | index | filename | core

meta_reset() {
  META_KIND=""
  META_TITLE=""
  META_FIELDS=()
  META_ICON=""
  META_SOURCE=""
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
# Sets: IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER
# ---------------------------------------------------------------------------
IDX_TITLE=""; IDX_REGION=""; IDX_YEAR=""; IDX_PUBLISHER=""
lookup_crc() {
  local crc="${1^^}" hit=""
  IDX_TITLE=""; IDX_REGION=""; IDX_YEAR=""; IDX_PUBLISHER=""
  [ -n "${crc}" ] || return 1
  [ -r "${TITLE_INDEX}" ] || return 1

  hit="$(grep -m1 -i "^${crc}|" "${TITLE_INDEX}" 2>/dev/null)"
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER <<<"${hit}"
  return 0
}

# ---------------------------------------------------------------------------
# meta_addfield - append a "Label\tValue" pair, skipping empty values.
# ---------------------------------------------------------------------------
meta_addfield() {
  local label="${1}" value="${2}"
  [ -n "${value}" ] || return 0
  META_FIELDS+=("${label}"$'\t'"${value}")
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
  local corename="${1}" fullpath="" fileselect="" rbfname=""

  meta_reset
  classify_core "${corename}"

  case "${META_KIND}" in

    arcade)
      if parse_mra "${CORE_STARTPATH}"; then
        META_TITLE="${MRA_NAME}"
        META_SOURCE="mra"
        meta_addfield "Year"         "${MRA_YEAR}"
        meta_addfield "Manufacturer" "${MRA_MANUFACTURER}"
        meta_addfield "Category"     "${MRA_CATEGORY}"
        meta_addfield "Set"          "${MRA_SETNAME:-${corename}}"
        meta_addfield "MAME"         "${MRA_MAMEVER}"
      else
        # STARTPATH missing (log_file_entry off) - fall back to the corename,
        # which for arcade is already the MRA setname.
        META_TITLE="${corename}"
        META_SOURCE="core"
        meta_addfield "Set" "${corename}"
      fi
      META_ICON="${corename}"
      ;;

    console)
      _slurp fullpath   "${MISTER_FULLPATH}"
      _slurp fileselect "${MISTER_FILESELECT}"
      _slurp rbfname    "${MISTER_RBFNAME}"

      # FULLPATH is also written while merely browsing the file list
      # (MENU_FILE_SELECT1 writes it with FILESELECT="active"). Only trust it
      # once something was actually chosen.
      if [ "${fileselect}" != "selected" ]; then
        fullpath=""
      fi

      # FULLPATH, FILESELECT and GAMEID persist in /tmp across a core change -
      # MiSTer writes them when a game is loaded and never clears them. A core
      # started from the menu would otherwise inherit the previous core's game,
      # showing a stale title and CRC before anything has been loaded. Only
      # trust them when they were written after the core name was.
      if [ -n "${fullpath}" ] && [ -e "${MISTER_CORENAME}" ] &&
         [ ! "${MISTER_FULLPATH}" -nt "${MISTER_CORENAME}" ]; then
        fullpath=""
      fi

      if [ -n "${fullpath}" ]; then
        clean_romname "${fullpath}"
        META_TITLE="${ROM_TITLE}"
        META_SOURCE="filename"

        # Upgrade to the canonical title when the CRC is indexed. The index
        # wins over the filename because it is correct for renamed or badly
        # tagged dumps.
        read_gameid
        if [ -n "${GAME_CRC32}" ] && lookup_crc "${GAME_CRC32}"; then
          [ -n "${IDX_TITLE}" ] && META_TITLE="${IDX_TITLE}" && META_SOURCE="index"
          [ -n "${IDX_REGION}" ] && ROM_REGION="${IDX_REGION}"
        fi

        meta_addfield "System"  "${corename}"
        meta_addfield "Region"  "${ROM_REGION}"
        meta_addfield "Year"    "${IDX_YEAR}"
        meta_addfield "Company" "${IDX_PUBLISHER}"
        meta_addfield "Format"  "${ROM_EXT^^}"
        # CRC32 is deliberately not shown. It is how the title index is keyed,
        # not something a player wants on screen, and it crowds out real
        # fields on the four rows the split layout has.
      else
        # Console core with nothing loaded yet.
        META_TITLE="${corename}"
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
