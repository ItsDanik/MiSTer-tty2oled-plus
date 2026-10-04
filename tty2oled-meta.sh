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
: "${GAME_ROOTS:=/media/fat /media/usb0 /media/usb1 /media/usb2 /media/usb3 /media/usb4 /media/usb5 /media/usb6 /media/usb7 /media/fat/cifs}"

: "${TITLE_INDEX_DIR:=/media/fat/tty2oledplus/titleindex}"

# Legacy single-file index. Searched only when there is no per-core file, so an
# existing hand-made index keeps working.
: "${TITLE_INDEX:=/media/fat/tty2oledplus/titleindex.txt}"

# What tty2oledplus_scrape.py imported from the gamelist.xml files in the
# games folders: one file per system, <system>.txt, one game a line. Written on the
# MiSTer, never shipped, and optional - without it nothing changes.
#
# "|"-separated like the title index, not tab-separated: a tab is whitespace
# to bash's read, which folds a run of them into one and would slide every
# field after an empty one into the wrong place. The importer keeps "|" out
# of the values.
: "${SCRAPE_DIR:=/media/fat/tty2oledplus/scraped}"

# ---------------------------------------------------------------------------
# Outputs. Cleared by meta_reset, populated by build_meta.
# ---------------------------------------------------------------------------
META_KIND=""        # arcade | console | computer | unknown
META_TITLE=""       # primary display line
META_FIELDS=()      # ordered "Label\tValue" pairs for the console layout
META_ICON=""        # icon key used to find the 86x64 art
META_SOURCE=""      # where the title came from: mra | index | scraped | filename | core
META_GAME="no"      # yes when a real game is loaded, not just a core
META_DESC=""        # the game's description, for the description page
META_SHOWCORE=""    # yes when the core's own picture should go back up

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
  # Reset here rather than in meta_addfields_ordered: the arcade path adds its
  # fields directly and would otherwise inherit the last console game's count,
  # pinning rows that are not there.
  META_PINNED_COUNT=0
  META_COMPACT_COUNT=0
  META_KIND=""
  META_TITLE=""
  META_FIELDS=()
  META_ICON=""
  META_SOURCE=""
  META_DESC=""
  META_GAME="no"        # yes once an actual game, not just a core, is identified
  META_SHOWCORE=""      # yes: a game has ended under a running core (ScummVM)
}

# Read a file into a variable, tolerating absence. Avoids a subshell.
_slurp() {
  local __var="${1}" __file="${2}" __val=""
  [ -r "${__file}" ] && IFS= read -r __val 2>/dev/null <"${__file}"
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
# meta_stat - the modification times of everything build_meta reads, in one
# process: META_MTIME[<path>] (seconds), and all of them as META_STATSIG.
#
# One stat a pass, for three things: the selection's time (the leftover-state
# guard), whether names.txt or coretypes.ini need reading again, and - with
# the state files' contents - whether anything changed at all since the last
# pass (meta_inputs), which is most passes: a game being played.
# ---------------------------------------------------------------------------
declare -A META_MTIME=()
META_STATSIG=""
META_STAT_FRESH=""        # "yes": taken this pass, build_meta need not
meta_stat() {
  local l=""
  META_MTIME=(); META_STATSIG=""
  while IFS= read -r l; do
    META_MTIME[${l#* }]="${l%% *}"
    META_STATSIG="${META_STATSIG}${l}|"
  done < <(stat -c '%Y %n' -- "${MISTER_CORENAME}" "${MISTER_RBFNAME}" \
             "${MISTER_STARTPATH}" "${MISTER_FULLPATH}" "${MISTER_CURRENTPATH}" \
             "${MISTER_FILESELECT}" "${MISTER_GAMEID}" "${NAMES_TXT}" \
             "${CORETYPE_MAP:-}" "${SCRAPE_DIR}" "${TITLE_INDEX_DIR}" \
             "${TITLE_INDEX}" "${SCRAPE_DIR}/DVD.txt" "${HYBRID_CORES}" 2>/dev/null)
  return 0
}

# Whether a file read into a table must be read again: its time as the last
# meta_stat saw it, against the time it was read at (the variable named).
# A file meta_stat has not seen - no stat yet, or not there - is always read:
# that costs only a read of a file, and is never wrong.
_table_stale() {  # _table_stale <file> <ref variable>
  local -n _ts_ref="${2}"
  local now="${META_MTIME[${1}]-none}"
  [ "${now}" = "none" ] && { _ts_ref="none"; return 0; }
  [ "${now}" = "${_ts_ref}" ] && return 1
  _ts_ref="${now}"
  return 0
}

# names.txt as a table, key lower-cased -> name; the first of a key wins.
declare -A NAMES_MAP=()
NAMES_REF=""
_names_load() {
  local line="" k="" v=""
  _table_stale "${NAMES_TXT:-}" NAMES_REF || return 0
  NAMES_MAP=()
  [ -r "${NAMES_TXT:-}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "${line}" in '#'*|';'*|'') continue ;; esac
    [[ "${line}" == *:* ]] || continue
    k="${line%%:*}"; v="${line#*:}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ -n "${v}" ] && [ -z "${NAMES_MAP[${k,,}]+set}" ] && NAMES_MAP[${k,,}]="${v}"
  done <"${NAMES_TXT}"
  return 0
}

# coretypes.ini as a table, core lower-cased -> kind; the first of a core wins.
declare -A CORETYPES=()
CORETYPES_REF=""
_coretypes_load() {
  local line="" k="" v=""
  _table_stale "${CORETYPE_MAP:-}" CORETYPES_REF || return 0
  CORETYPES=()
  [ -r "${CORETYPE_MAP:-}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    [[ "${line}" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    [ -n "${k}" ] || continue
    case "${k}" in '#'*|';'*) continue ;; esac
    [ -z "${CORETYPES[${k,,}]+set}" ] && CORETYPES[${k,,}]="${v//[[:space:]]/}"
  done <"${CORETYPE_MAP}"
  return 0
}

# ---------------------------------------------------------------------------
# Hybrid cores - a game on the ARM behind an FPGA core of its own
# (github.com/ItsDanik/Hybrid_MiSTer: Dethrace, ECWolf). The core is the game:
# nothing is ever selected, so MiSTer publishes a core name and no more, and
# what the layout says comes from hybridcores.txt, by that name:
#
#   <corename>|<title>|<label>=<value>|...|<description>
#
# Read into a table when its time changes, as names.txt is; the core name
# lower-cased -> the rest of its line.
# ---------------------------------------------------------------------------
: "${HYBRID_CORES:=${TTY2OLED_PATH:-/media/fat/tty2oledplus}/hybridcores.txt}"
declare -A HYBRID_MAP=()
HYBRID_REF=""
_hybrid_load() {
  local line="" k=""
  _table_stale "${HYBRID_CORES}" HYBRID_REF || return 0
  HYBRID_MAP=()
  [ -r "${HYBRID_CORES}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in '#'*|';'*|'') continue ;; esac
    [[ "${line}" == *'|'* ]] || continue
    k="${line%%|*}"
    [ -n "${k}" ] && [ -z "${HYBRID_MAP[${k,,}]+set}" ] && HYBRID_MAP[${k,,}]="${line#*|}"
  done <"${HYBRID_CORES}"
  return 0
}

hybrid_core() {  # hybrid_core <corename>
  [ -n "${1}" ] || return 1
  _hybrid_load
  [ -n "${HYBRID_MAP[${1,,}]+set}" ]
}

# The console layout for a hybrid core: its title, its rows as the table
# orders them - none pinned, so four to a page - and its description. The
# icon is the core's own, pics/icon/<corename>.
hybrid_meta() {  # hybrid_meta <corename>
  local corename="${1}" rest="" part="" desc=""
  local -a parts=()
  rest="${HYBRID_MAP[${corename,,}]}"
  # The last field is the description, empty or not - taken off first, since
  # read drops an empty field at the end of a line.
  if [[ "${rest}" == *'|'* ]]; then
    desc="${rest##*|}"
    rest="${rest%|*}"
  fi
  IFS='|' read -r -a parts <<<"${rest}"
  META_KIND="console"
  META_SOURCE="hybrid"
  META_GAME="yes"
  META_ICON="${corename}"
  META_PINNED_COUNT=0
  META_TITLE="${parts[0]:-${DISPLAY_CORENAME}}"
  # The fields between are rows, and one that is no <label>=<value> is none.
  for part in "${parts[@]:1}"; do
    [[ "${part}" == *=* ]] && meta_addfield "${part%%=*}" "${part#*=}"
  done
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="${desc}"
  return 0
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

  _names_load
  for key in "${corename}" "${rbfname}" "${base}" "${base%_*}"; do
    [ -n "${key}" ] || continue
    # An exact key, without regard to case: core names have spaces and
    # punctuation in them ("Neo Geo MVS/AES", "PC Engine/CD").
    hit="${NAMES_MAP[${key,,}]:-}"
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
  #    The name is a key, matched exactly without regard to case - it was a
  #    regex, so a "." in a core name matched any character.
  if [ -n "${corename}" ]; then
    local mapped=""
    _coretypes_load
    mapped="${CORETYPES[${corename,,}]:-}"
    case "${mapped,,}" in
      arcade|console|computer) META_KIND="${mapped,,}"; return 0 ;;
    esac
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
# only reads <rbf>, <setname> and <rotation>; everything else is present on
# disk and unused - year, manufacturer, category, catver, players, joystick,
# region, platform, the button names, who packaged the set. The arcade card
# shows the lot, a page at a time.
#
# Parsed with awk rather than a real XML reader: these are single-line tags in
# every MRA in the wild. One pass over the file rather than one sed per tag,
# because this runs on every arcade core change and a process per tag is what
# a core switch would feel like.
#
# Sets: MRA_NAME MRA_YEAR MRA_MANUFACTURER MRA_CATEGORY MRA_CATVER MRA_SETNAME
#       MRA_MAMEVER MRA_RBF MRA_PLAYERS MRA_JOYSTICK MRA_ROTATION MRA_REGION
#       MRA_PLATFORM MRA_VERSION MRA_BUTTONS MRA_BUTTONCOUNT MRA_AUTHOR
# ---------------------------------------------------------------------------
MRA_NAME=""; MRA_YEAR=""; MRA_MANUFACTURER=""; MRA_CATEGORY=""; MRA_CATVER=""
MRA_SETNAME=""; MRA_MAMEVER=""; MRA_RBF=""; MRA_PLAYERS=""; MRA_JOYSTICK=""
MRA_ROTATION=""; MRA_REGION=""; MRA_PLATFORM=""; MRA_VERSION=""
MRA_BUTTONS=""; MRA_BUTTONCOUNT=""; MRA_AUTHOR=""

# The element text is wanted for most of it, but the button names and the
# packager live in attributes: <buttons names="Shot,Jump" count="2"/> and
# <about author="jotego" .../>.
_MRA_TAGS="name setname rbf mameversion year manufacturer category catver players joystick rotation region platform version"

_mra_scan() {
  # _mra_scan <file> -> one "key<TAB>value" line per tag or attribute found,
  # first occurrence only, XML entities decoded.
  #
  # Decoding happens here rather than with bash parameter substitution because
  # bash 5.2 made a bare "&" in the replacement of ${var//pat/repl} mean "the
  # matched text" (patsub_replacement, on by default), so ${val//&amp;/&} is a
  # silent no-op there while still working on the older bash MiSTer ships.
  # awk has the same trap in gsub, and the same escape out of it: "\\&" is a
  # literal ampersand on every awk. &amp; is decoded LAST so an encoded entity
  # such as "&amp;lt;" survives as the text "&lt;" instead of decoding twice.
  awk -v tags="${_MRA_TAGS}" '
    function decode(s) {
      gsub(/&lt;/,   "<",  s); gsub(/&gt;/,   ">",  s)
      gsub(/&quot;/, "\"", s); gsub(/&#34;/,  "\"", s)
      gsub(/&apos;/, "'"'"'",  s); gsub(/&#39;/,  "'"'"'",  s)
      gsub(/&amp;/,  "\\&", s)
      return s
    }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

    # attr - the value of one double-quoted attribute of the first <tag ...>
    # element on this line. line/low are the current line and its lowercased
    # twin; tolower does not change any length, so a position found in one is
    # the same position in the other.
    function attr(tag, name,   a, e, el, q, st, en) {
      a = index(low, "<" tag)
      if (a == 0) return ""
      e  = index(substr(low, a), ">")
      el = (e > 0) ? substr(low, a, e) : substr(low, a)
      q  = index(el, name "=\"")
      if (q == 0) return ""
      st = a + q - 1 + length(name) + 2
      en = index(substr(low, st), "\"")
      if (en == 0) return ""
      return trim(decode(substr(line, st, en - 1)))
    }

    BEGIN { n = split(tags, T, " ") }
    {
      line = $0; low = tolower(line)

      for (i = 1; i <= n; i++) {
        t = T[i]
        if (t in got) continue
        a = index(low, "<" t ">")
        if (a == 0) continue
        a += length(t) + 2
        b = index(substr(low, a), "</" t ">")
        if (b == 0) continue
        got[t] = 1
        print t "\t" trim(decode(substr(line, a, b - 1)))
      }

      if (!("buttons" in got) && index(low, "<buttons")) {
        v = attr("buttons", "names"); if (v != "") print "buttonnames\t" v
        v = attr("buttons", "count"); if (v != "") print "buttoncount\t" v
        got["buttons"] = 1
      }
      if (!("about" in got) && index(low, "<about")) {
        v = attr("about", "author"); if (v != "") print "author\t" v
        got["about"] = 1
      }
    }
  ' "${1}" 2>/dev/null
}

parse_mra() {
  local mra="${1}" key="" val=""
  MRA_NAME=""; MRA_YEAR=""; MRA_MANUFACTURER=""; MRA_CATEGORY=""; MRA_CATVER=""
  MRA_SETNAME=""; MRA_MAMEVER=""; MRA_RBF=""; MRA_PLAYERS=""; MRA_JOYSTICK=""
  MRA_ROTATION=""; MRA_REGION=""; MRA_PLATFORM=""; MRA_VERSION=""
  MRA_BUTTONS=""; MRA_BUTTONCOUNT=""; MRA_AUTHOR=""
  [ -r "${mra}" ] || return 1

  while IFS=$'\t' read -r key val; do
    case "${key}" in
      name)         MRA_NAME="${val}" ;;
      setname)      MRA_SETNAME="${val}" ;;
      rbf)          MRA_RBF="${val}" ;;
      mameversion)  MRA_MAMEVER="${val}" ;;
      year)         MRA_YEAR="${val}" ;;
      manufacturer) MRA_MANUFACTURER="${val}" ;;
      category)     MRA_CATEGORY="${val}" ;;
      catver)       MRA_CATVER="${val}" ;;
      players)      MRA_PLAYERS="${val}" ;;
      joystick)     MRA_JOYSTICK="${val}" ;;
      rotation)     MRA_ROTATION="${val}" ;;
      region)       MRA_REGION="${val}" ;;
      platform)     MRA_PLATFORM="${val}" ;;
      version)      MRA_VERSION="${val}" ;;
      buttonnames)  MRA_BUTTONS="${val}" ;;
      buttoncount)  MRA_BUTTONCOUNT="${val}" ;;
      author)       MRA_AUTHOR="${val}" ;;
    esac
  done < <(_mra_scan "${mra}")

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
# Bash alone, no process: this ran a dozen of them - grep, sed, tr, paste -
# for every game, and a pass rebuilt the game every few seconds. Whatever it
# does, tools/index-emit.awk does too, for the index's titles and regions
# (tests/test-index.sh holds the two to each other).
#
# Sets: ROM_TITLE ROM_REGION ROM_EXT ROM_TAGS
# ---------------------------------------------------------------------------
ROM_TITLE=""; ROM_REGION=""; ROM_EXT=""; ROM_TAGS=""

# One name of a region, as No-Intro and TOSEC write them, into _RG - its
# short forms spelt out - or failure if it is not one.
_region_word() {
  _RG="${1}"
  case "${1^^}" in
    US) _RG="USA" ;; EU) _RG="Europe" ;; JP) _RG="Japan" ;;
    WORLD|USA|EUROPE|JAPAN|ASIA|UK|GERMANY|FRANCE|SPAIN|ITALY|AUSTRALIA|KOREA|\
    BRAZIL|SWEDEN|NETHERLANDS|CANADA|CHINA|TAIWAN|RUSSIA|SCANDINAVIA|\
    "HONG KONG"|GREECE|PORTUGAL|DENMARK|NORWAY|FINLAND|POLAND|BELGIUM|AUSTRIA|\
    SWITZERLAND|"LATIN AMERICA"|"NEW ZEALAND"|INDIA|MEXICO|ARGENTINA|IRELAND|\
    "SOUTH AFRICA") ;;
    *) return 1 ;;
  esac
}

# The region: the first (...) group made only of region names - "(USA)",
# "(USA, Europe)", "(Europe, Australia)" - as written, short forms spelt out.
# A list used to count only as the two pairs the pattern named; any other,
# "(Japan, Europe)", had no region at all.
_region_of() {
  local s="${1}" g="" part="" out="" ok=""
  ROM_REGION=""
  while [[ "${s}" == *"("*")"* ]]; do
    s="${s#*(}"; g="${s%%)*}"; s="${s#*)}"
    out=""; ok="${g}"
    while [ -n "${g}" ]; do
      part="${g%%,*}"
      [ "${part}" = "${g}" ] && g="" || g="${g#*,}"
      part="${part#"${part%%[![:space:]]*}"}"; part="${part%"${part##*[![:space:]]}"}"
      _region_word "${part}" || { ok=""; break; }
      out="${out}${out:+, }${_RG}"
    done
    [ -n "${ok}" ] && [ -n "${out}" ] && { ROM_REGION="${out}"; return 0; }
  done
  return 0
}

clean_romname() {
  local path="${1}" base="" work="" head="" rest="" tag=""
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
  _region_of "${work}"

  # Every (...) group, then every [...] one, is metadata, not title - the
  # square ones kept, comma-joined, as the dump-status tags.
  while [[ "${work}" == *"("*")"* ]]; do
    head="${work%%(*}"; rest="${work#*(}"; work="${head}${rest#*)}"
  done
  while [[ "${work}" == *"["*"]"* ]]; do
    head="${work%%\[*}"; rest="${work#*\[}"
    tag="${rest%%\]*}"; tag="${tag//\[/}"
    ROM_TAGS="${ROM_TAGS}${ROM_TAGS:+,}${tag}"
    work="${head}${rest#*\]}"
  done

  # Collapse separators and whitespace, and a dangling " - " at the end.
  work="${work//_/ }"
  work="${work//$'\t'/ }"
  while [[ "${work}" == *"  "* ]]; do work="${work//  / }"; done
  work="${work#"${work%%[![:space:]]*}"}"; work="${work%"${work##*[![:space:]]}"}"
  if [[ "${work}" == *- ]]; then
    work="${work%-}"; work="${work%"${work##*[![:space:]]}"}"
  fi

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
  _R=""
  case "${1^^}" in
    MEGADRIVE|MEGADRIVE32X|SEGAGENESIS|SEGAMD) _R="GENESIS" ;;
    GBC|GAMEBOYCOLOR|GAMEBOY2|SGB)             _R="GAMEBOY" ;;
    ATARILYNX)                                 _R="LYNX" ;;
    WSWAN|WONDERSWANCOLOR|WSC)                 _R="WONDERSWAN" ;;
    GAMEGEAR|GG|SEGAGG|SG1000|SEGASG1000)      _R="SMS" ;;
    MASTERSYSTEM|SEGASMS)                      _R="SMS" ;;
    PCE|PCECD|TGFX16CD|TURBOGRAFX16)           _R="TGFX16" ;;
    SUPERGRAFX|SGX)                            _R="TGFX16" ;;
    32X|SEGA32X)                               _R="S32X" ;;
    NEOGEOPOCKETCOLOR|NGPC)                    _R="NGP" ;;
    VIRTUALBOY)                                _R="VIRTUALBOY" ;;
    NINTENDO64)                                _R="N64" ;;
    GAMEBOYADVANCE)                            _R="GBA" ;;
    COLECOVISION)                              _R="COLECO" ;;
    A2600|ATARI2600)                           _R="ATARI2600" ;;
    A5200|ATARI5200)                           _R="ATARI5200" ;;
    A7800|ATARI7800)                           _R="ATARI7800" ;;
    *) return 1 ;;
  esac
}

# Which index file covers this core. Tried in order: the core name as given,
# its alias, then a case-insensitive directory match - MiSTer is not
# consistent about capitalisation and a file named Genesis.idx should still
# answer for a core calling itself GENESIS.
#
# Into _R, without a subshell: every lookup starts here.
_index_file_r() {
  local corename="${1:-}" alias="" cand="" f="" base=""
  _R=""

  if [ -n "${corename}" ]; then
    _index_alias "${corename}" && alias="${_R}"
    # Each candidate gets both spellings tried: exact first because it is a
    # single stat, then a case-insensitive sweep of the directory.
    for cand in "${corename}" ${alias:+"${alias}"}; do
      [ -n "${cand}" ] || continue
      if [ -r "${TITLE_INDEX_DIR}/${cand}.idx" ]; then
        _R="${TITLE_INDEX_DIR}/${cand}.idx"; return 0
      fi
      for f in "${TITLE_INDEX_DIR}"/*.idx; do
        [ -r "${f}" ] || continue
        base="${f##*/}"; base="${base%.idx}"
        if [ "${base,,}" = "${cand,,}" ]; then
          _R="${f}"; return 0
        fi
      done
    done
  fi

  _R=""
  [ -r "${TITLE_INDEX}" ] || return 1
  _R="${TITLE_INDEX}"
}

# The same on stdout, for tty2oled-capture.sh and the tests.
_index_file() { _index_file_r "${1:-}" || return 1; printf '%s' "${_R}"; }

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
  _index_file_r "${corename}" || return 1
  idx="${_R}"

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
  _index_file_r "${corename}" || return 1
  idx="${_R}"

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
  _index_file_r "${corename}" || return 1
  idx="${_R}"

  hit="$(grep -m1 -i "^${crc}|" "${idx}" 2>/dev/null)"
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ IDX_TITLE IDX_REGION IDX_YEAR IDX_PUBLISHER \
                   IDX_GENRE IDX_DEVELOPER IDX_SERIAL <<<"${hit}"
  return 0
}

# ---------------------------------------------------------------------------
# lookup_scraped - what the imported gamelist said about this game, if
# anything.
#
# Keyed on the file name without its extension, which is what a gamelist's
# <path> names and what CURRENTPATH carries - with or without the extension,
# since MiSTer strips it for single-extension cores, so both are tried. A CRC
# in the second column is the fallback, for a line that carries one; a
# gamelist does not, and MiSTer's GAMEID is not always the whole file's CRC
# anyway (an iNES header is enough to differ), which is why it is not the key.
#
# A system's games can be run by a core of another name - the Game Boy core
# plays .gbc files, the TurboGrafx core reports TGFX16 for CDs too, and older
# MiSTers call the Mega Drive core Genesis - so the siblings are searched
# after the core's own file.
#
# Only a line whose status is "ok" is a hit.
#
# Sets: SCR_TITLE SCR_RELEASED SCR_PLAYERS SCR_RATING SCR_GENRE SCR_DEVELOPER
#       SCR_PUBLISHER SCR_SERIES SCR_DESC
# ---------------------------------------------------------------------------
scr_reset() {
  SCR_TITLE=""; SCR_RELEASED=""; SCR_PLAYERS=""; SCR_RATING=""; SCR_GENRE=""
  SCR_DEVELOPER=""; SCR_PUBLISHER=""; SCR_SERIES=""; SCR_DESC=""
}
scr_reset

_scrape_systems() {  # the scraped files that may hold this core's games
  case "${1^^}" in
    GENESIS|MEGADRIVE)          _R="MegaDrive" ;;
    GAMEBOY|GB)                 _R="GAMEBOY GBC" ;;
    GBC|GAMEBOYCOLOR)           _R="GBC GAMEBOY" ;;
    TGFX16|PCE)                 _R="TGFX16 TGFX16CD" ;;
    TGFX16CD|TGFX16-CD|PCECD)   _R="TGFX16CD TGFX16" ;;
    NEOGEO)                     _R="NeoGeo" ;;
    *)                          _R="${1}" ;;
  esac
}

_scrape_file() {  # the file for one system name, matched case-insensitively
  local want="${1}" f="" base=""
  _R=""
  [ -r "${SCRAPE_DIR}/${want}.txt" ] && { _R="${SCRAPE_DIR}/${want}.txt"; return 0; }
  for f in "${SCRAPE_DIR}"/*.txt; do
    [ -r "${f}" ] || continue
    base="${f##*/}"; base="${base%.txt}"
    [ "${base,,}" = "${want,,}" ] && { _R="${f}"; return 0; }
  done
  return 1
}

lookup_scraped() {
  local romref="${1:-}" crc="${2:-}" corename="${3:-}" sys="" file="" hit="" name="" bare=""
  scr_reset
  [ -d "${SCRAPE_DIR}" ] || return 1
  name="${romref##*/}"
  bare="${name}"
  # An extension is short and has no spaces; "Super Mario Bros. 3" has none.
  [[ "${name}" =~ \.[A-Za-z0-9]{1,4}$ ]] && bare="${name%.*}"
  [ -n "${bare}" ] || return 1

  _scrape_systems "${corename}"
  for sys in ${_R}; do
    _scrape_file "${sys}" || continue
    file="${_R}"
    # The last line for a key wins, should a file ever carry two. Matched
    # exactly - a file name is a plain string, full of regex metacharacters.
    hit="$(awk -F'|' -v n="${bare,,}" -v f="${name,,}" -v c="${crc,,}" '
      $3 != "ok" { next }
      tolower($1) == n || tolower($1) == f { byname = $0; next }
      c != "" && tolower($2) == c        { bycrc = $0 }
      END { if (byname != "") print byname; else if (bycrc != "") print bycrc }
    ' "${file}" 2>/dev/null)"
    [ -n "${hit}" ] && break
  done
  [ -n "${hit}" ] || return 1

  IFS='|' read -r _ _ _ SCR_TITLE SCR_RELEASED SCR_PLAYERS SCR_RATING SCR_GENRE \
                   SCR_DEVELOPER SCR_PUBLISHER SCR_SERIES SCR_DESC <<<"${hit}"
  return 0
}

# "16" out of 20, as the importer stores a rating, reads better out of ten: "8/10",
# and "7.5/10" for an odd one.
# Into _R.
_scr_rating() {
  local n="${1}"
  _R=""
  case "${n}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${n}" -gt 20 ] && return 0
  if [ $((n % 2)) -eq 0 ]; then _R="$((n / 2))/10"
  else _R="$((n / 2)).5/10"; fi
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

# The order used when METADATA_FIELDS is not set. The last four come only from
# an imported gamelist - a game it does not list simply has none of them.
# Engine, Platform and Language are ScummVM's: no console game has them.
_FIELD_ORDER_DEFAULT="System Region Year Company Genre Developer Format Platform Engine Language Players Rating Released Series"

# The arcade card draws from the MRA, which has a vocabulary of its own - an
# arcade board has players, a joystick and named buttons where a console game
# has a region and a file format.
#
# The card is two lists rather than one, because the values are two shapes.
# The short ones pair up two to a row, four rows to a page:
#
#     Year     1993          Manufctr  Midway
#     Players  4             Rating    8/10
#     Developr Midway        Region    World
#     Orient   Horizontal    Core      blahmid_tunit
#
#     Author   rejectedcoins Set       nbajam
#     MAME     0289
#
# and the long ones - "Turbo/Shoot / Block/Pass / Steal" is 32 characters -
# get a row each on the page after them, under a repeat of the pinned row:
#
#     Year     1993          Manufctr  Midway
#     Controls 8-way
#     Buttons  Turbo/Shoot / Block/Pass / Steal
#
# Genre, Platform and Version are known but unlisted: name them in either ini
# list to show them. Genre belongs in the wide list - "Fighter / 2.5D" does
# not fit half a row.
#
# Developer, Publisher, Rating, Released and Series come from an imported
# gamelist.xml rather than the MRA, as a console game's do - a set no
# gamelist describes has none of them, and their places close up.
_ARCADE_ORDER_DEFAULT="Year Manufacturer Players Rating Developer Region Orientation Core Author Set MAME"
_ARCADE_WIDE_DEFAULT="Controls Buttons"

# Every name either list accepts. A name absent from both is simply not shown.
_ARCADE_KNOWN="Year Manufacturer Genre Players Controls Buttons Region Platform Orientation Set Core MAME Version Author Developer Publisher Rating Released Series"

# The grid row repeated above each wide page, so a page of controls is still
# labelled with the game's year and maker. These must be in ARCADE_FIELDS -
# only a paired field can pin, a wide one is a whole row.
: "${ARCADE_PINNED=Year Manufacturer}"

# A column is about fifteen characters wide, which some of the names are not.
# None is longer than "Manufctr": the value column is measured off the widest
# label on the card, and a ninth letter would move every value on it.
_arcade_display_label() {  # into _R
  case "${1}" in
    Manufacturer) _R='Manufctr' ;;
    Orientation)  _R='Orient'   ;;
    Developer)    _R='Developr' ;;
    Publisher)    _R='Publishr' ;;
    *)            _R="${1}" ;;
  esac
}

# Fields that stay put while the rest page. The layout has four rows, so
# pinning one leaves three cycling underneath. A name here must also appear in
# METADATA_FIELDS to be shown at all.
: "${METADATA_PINNED:=System}"

# Fold the publisher into the year - "1990, Acclaim" on one row instead of
# two. Worth it on four rows; "no" keeps them separate.
: "${COMPACT_YEAR_COMPANY:=yes}"

# How many of the emitted fields are pinned, and - on an arcade card - how
# many of them are paired two to a row. Counted as they are emitted, because a
# field with an empty value is not emitted at all and must not reserve a row
# it will never use.
META_PINNED_COUNT=0
META_COMPACT_COUNT=0

# Canonical spelling of a field name, or failure if it is not one we know.
# The two layouts have separate vocabularies, so each looks its names up in
# its own list and a console name in ARCADE_FIELDS is simply ignored.
#
# Into _R: these ran in a subshell per field, a dozen and more a game.
_canon_label() {
  local want="${1}" list="${2}" label=""
  _R=""
  for label in ${list}; do
    if [ "${label,,}" = "${want,,}" ]; then _R="${label}"; return 0; fi
  done
  return 1
}

_field_label()  { _canon_label "${1}" "${_FIELD_ORDER_DEFAULT}"; }
_arcade_label() { _canon_label "${1}" "${_ARCADE_KNOWN}"; }

_field_in_list() {
  local want="${1}" list="${2}" f=""
  for f in ${list}; do
    [ "${f,,}" = "${want,,}" ] && return 0
  done
  return 1
}

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
  local want="" label="" before=0

  META_PINNED_COUNT=0

  # Pinned first, in the order METADATA_PINNED gives them. The firmware then
  # only needs "the first N are pinned" and never has to know their names.
  for want in ${METADATA_PINNED}; do
    _field_label "${want}" || continue
    label="${_R}"
    _field_in_list "${want}" "${order}" || continue
    before="${#META_FIELDS[@]}"
    meta_addfield "${label}" "${META_AVAIL[${label}]:-}"
    [ "${#META_FIELDS[@]}" -gt "${before}" ] && META_PINNED_COUNT=$((META_PINNED_COUNT + 1))
  done

  # Then everything else, skipping whatever was already pinned.
  for want in ${order}; do
    _field_label "${want}" || continue
    label="${_R}"
    _field_in_list "${want}" "${METADATA_PINNED}" && continue
    meta_addfield "${label}" "${META_AVAIL[${label}]:-}"
  done
}

# Turn the MRA tags into the values the card shows.
#
# Commas are deliberately absent from everything built here. metasanitize
# replaces them with spaces on the wire - it has to, because the optional
# pinned count in CMDMETA is recognised by being digits followed by a comma -
# so a value that joins its parts with ", " arrives with a hole in it. "/"
# and " " survive the trip.
arcade_avail_from_mra() {
  local corename="${1}" count="" part="" out="" n=0

  ARCADE_AVAIL=()
  # The MRA first, the imported gamelist (SCR_*, from arcade_lookup_scraped)
  # for whatever it leaves out - the MRA is about this very set, where a
  # gamelist entry may have been matched to a parent or a clone.
  ARCADE_AVAIL[Year]="${MRA_YEAR:-${SCR_RELEASED:0:4}}"
  _nocomma "${SCR_PUBLISHER:-${SCR_DEVELOPER}}"
  ARCADE_AVAIL[Manufacturer]="${MRA_MANUFACTURER:-${_R}}"
  # catver is the finer-grained of the two - "Platform / Run Jump" against
  # "Platform" - so it wins where the MRA carries it.
  _nocomma "${SCR_GENRE}"
  ARCADE_AVAIL[Genre]="${MRA_CATVER:-${MRA_CATEGORY:-${_R}}}"
  ARCADE_AVAIL[Players]="${MRA_PLAYERS:-${SCR_PLAYERS}}"
  _nocomma "${SCR_DEVELOPER}"; ARCADE_AVAIL[Developer]="${_R}"
  _nocomma "${SCR_PUBLISHER}"; ARCADE_AVAIL[Publisher]="${_R}"
  _scr_rating "${SCR_RATING}"; ARCADE_AVAIL[Rating]="${_R}"
  ARCADE_AVAIL[Released]="${SCR_RELEASED}"
  _nocomma "${SCR_SERIES}"; ARCADE_AVAIL[Series]="${_R}"
  ARCADE_AVAIL[Controls]="${MRA_JOYSTICK}"
  ARCADE_AVAIL[Region]="${MRA_REGION}"
  ARCADE_AVAIL[Platform]="${MRA_PLATFORM}"
  ARCADE_AVAIL[Set]="${MRA_SETNAME:-${corename}}"
  ARCADE_AVAIL[Core]="${MRA_RBF}"
  ARCADE_AVAIL[MAME]="${MRA_MAMEVER}"
  ARCADE_AVAIL[Version]="${MRA_VERSION}"
  ARCADE_AVAIL[Author]="${MRA_AUTHOR}"

  # <rotation>vertical</rotation> reads as a value, not a sentence.
  [ -n "${MRA_ROTATION}" ] && ARCADE_AVAIL[Orientation]="${MRA_ROTATION^}"

  count="${MRA_BUTTONCOUNT}"
  case "${count}" in ""|*[!0-9]*) count=0 ;; esac

  # <buttons names="Shot,Jump,Start 1P,Coin,Pause" count="2"/> - the names
  # past "count" are the cabinet's own (start, coin, pause) and say nothing
  # about the game. Placeholders are written "-" and dropped.
  if [ -n "${MRA_BUTTONS}" ]; then
    # Split on the commas by turning them into newlines rather than by
    # setting IFS: a local IFS that has to be unset again to restore the
    # global one is a trap, and a here-string keeps the loop in this shell so
    # the result survives it.
    while IFS= read -r part; do
      part="${part#"${part%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [ -z "${part}" ] && continue
      [ "${part}" = "-" ] && continue
      n=$((n + 1))
      [ "${count}" -gt 0 ] && [ "${n}" -gt "${count}" ] && break
      out="${out}${out:+/}${part}"
    done <<< "${MRA_BUTTONS//,/$'\n'}"
    ARCADE_AVAIL[Buttons]="${out}"
  fi

  # A board with no joystick still has a control panel worth describing.
  if [ -z "${ARCADE_AVAIL[Controls]}" ] && [ "${count}" -gt 0 ]; then
    if [ "${count}" -eq 1 ]; then
      ARCADE_AVAIL[Controls]="1 button"
    else
      ARCADE_AVAIL[Controls]="${count} buttons"
    fi
  fi
}

# A gamelist says "Capcom, Inc." and "Shooter, Vertical", and metasanitize
# would turn each comma into a space beside the one already there. One space.
# Into _R.
_nocomma() {
  local v="${1//, / }"
  _R="${v//,/ }"
}

# What an imported gamelist said about the running arcade game. The gamelist
# is the one in games/mame, beside the zips, so it names sets - "dkong" - and
# the .mra's <setname> is the key; the core name, which for arcade is the set
# name too, covers an .mra that has none.
# Always resets SCR_*, so a set no gamelist lists cannot show the last game's.
arcade_lookup_scraped() {
  local corename="${1}"
  scr_reset
  [ -n "${MRA_SETNAME}" ] && lookup_scraped "${MRA_SETNAME}" "" Arcade && return 0
  [ -n "${corename}" ] && [ "${corename}" != "${MRA_SETNAME}" ] &&
    lookup_scraped "${corename}" "" Arcade && return 0
  return 1
}

# Emit the arcade fields held in ARCADE_AVAIL: the paired ones first, then the
# wide ones, each list honouring its ini setting for both membership and order.
#
# The firmware never learns a field's name. It is told how many leading fields
# to pair up (META_COMPACT_COUNT) and how many of those to repeat above the
# wide pages (META_PINNED_COUNT), and counts from there - so which field goes
# where is a script-side change, exactly as it is for the console layout.
#
# Both counts are counted as the fields are emitted, because a field whose MRA
# tag is missing is never emitted at all and must not reserve a place.
declare -A ARCADE_AVAIL=()
arcade_addfields_ordered() {
  local order="${ARCADE_FIELDS-${_ARCADE_ORDER_DEFAULT}}"
  local wide="${ARCADE_FIELDS_WIDE-${_ARCADE_WIDE_DEFAULT}}"
  local want="" name="" label="" before=0

  META_COMPACT_COUNT=0
  META_PINNED_COUNT=0

  for want in ${order}; do
    _arcade_label "${want}" || continue
    name="${_R}"
    _arcade_display_label "${name}"
    label="${_R}"
    before="${#META_FIELDS[@]}"
    meta_addfield "${label}" "${ARCADE_AVAIL[${name}]:-}"
    [ "${#META_FIELDS[@]}" -gt "${before}" ] || continue
    META_COMPACT_COUNT=$((META_COMPACT_COUNT + 1))
    # Pinned rows repeat above the wide pages, so they have to be the FIRST
    # fields emitted, not merely present: a gap would pin the wrong ones.
    if [ "${META_PINNED_COUNT}" -eq $((META_COMPACT_COUNT - 1)) ] &&
       _field_in_list "${name}" "${ARCADE_PINNED}"; then
      META_PINNED_COUNT=$((META_PINNED_COUNT + 1))
    fi
  done

  for want in ${wide}; do
    _arcade_label "${want}" || continue
    name="${_R}"
    _arcade_display_label "${name}"
    label="${_R}"
    meta_addfield "${label}" "${ARCADE_AVAIL[${name}]:-}"
  done
}

# ---------------------------------------------------------------------------
# ScummVM - a Linux program, not a core, that knows its games better than
# MiSTer does.
#
# Its Scripts launcher writes "ScummVM" to CORENAME and "MENU" back when it
# exits, and that is all MiSTer ever hears of it. What is playing has to be
# read off ScummVM itself:
#
#   scummvm.ini       ScummVM rewrites it whenever its launcher closes, which
#                     is how a game starts: lastselectedgame names the game,
#                     and the game's section its engine, id, path, platform
#                     and language. So an ini newer than the process means a
#                     game has been started.
#   /proc/<pid>/fd    Going back to ScummVM's launcher writes nothing at all.
#                     But SCUMM and SCI hold their data files open for as long
#                     as the game runs, and close them on the way out. AGI
#                     holds nothing - it opens, reads and closes - so a game
#                     never seen holding a file is taken to run until the ini
#                     changes again or ScummVM exits.
#   gui-icons-*.dat   Its icon packs: the year, company, series and engine
#                     (tty2oledplus_scummvm.py index -> games.idx), and a
#                     512x512 icon per game, converted once to 86x64 and kept.
#
# The process is found by its binary's name (scummvm, scummvmmaster...), its
# ini by --config or its HOME, so no one launcher script is assumed. A game
# named on the command line - a per-game launcher - is running from the start.
# ---------------------------------------------------------------------------
: "${SCUMMVM_CACHE:=/media/fat/tty2oledplus/cache/scummvm}"
SCUMMVM_HZ=100            # USER_HZ, what /proc/<pid>/stat counts start time in
SCUMMVM_GONE_SECS=3       # files closed this long = back in ScummVM's launcher:
                          # two looks, METADATA_POLL apart, not one

SVM_PID=""; SVM_START=0; SVM_INI=""; SVM_AUTO=""; SVM_ICONDIRS=()
SVM_INI_SEEN=""           # the ini's mtime when it was last parsed
SVM_LAST=""; SVM_ICONPATH=""
declare -A SVM_SEC=()     # lastselectedgame's section (or the autostart's)
SVM_KEY=""                # which start of which game the rest is about
SVM_GAMEDIR=""            # its path, resolved, as /proc shows open files
SVM_HELD="no"             # has it been seen holding a file there?
SVM_GONE_AT=""            # when it was first seen holding none
SVM_PLAYING="no"          # the last build's verdict, for META_SHOWCORE
SVM_DISPLAY=""            # ScummVM's name in names.txt, once a core change
SVM_NEED_ICON=""          # "<engine>|<gameid>" when the icon is not cached yet
SVM_BUILT=""              # the SVM_KEY the layout below was worked out for
SVM_C_TITLE=""; SVM_C_DESC=""; SVM_C_FIELDS=(); SVM_C_PINNED=0

scummvm_core() { [ "${1,,}" = "scummvm" ]; }

# ---------------------------------------------------------------------------
# proc_hits - the processes worth a closer look, into PROC_HITS (their
# cmdline files): one grep over every command line, for everything the daemon
# looks for - update_all, MiSTer's own updater, this one's, Super Attract
# Mode, Degauss, Zaparoo, ScummVM. It used to be a grep each, three to five a
# pass, each walking all of /proc. Case is ignored, which only widens the
# net: every caller still decides from the command line itself what it has.
# The brackets keep grep's own command line, which holds the patterns, out.
#
# Within one pass of the daemon's loop - PROC_PASS, which the loop bumps -
# the sweep is made once and shared. Outside one (the tests) every call looks.
# ---------------------------------------------------------------------------
PROC_PASS=""; PROC_SCANNED="-"; PROC_HITS=()
proc_hits() {
  [ -n "${PROC_PASS}" ] && [ "${PROC_SCANNED}" = "${PROC_PASS}" ] && return 0
  PROC_HITS=()
  mapfile -t PROC_HITS < <(grep -lsai \
      -e '[u]pdate_all' -e '[t]mp/downloader[.]sh' -e '[s]cripts/update[.]sh' \
      -e '[u]a_downloader' -e '[t]ty2oledplus_update' -e '[u]pdate_tty2oledplus' \
      -e '[m]ister_sam_on[.]sh' -e '[d]egauss/degauss' -e '[m]enu_zaparoo' -e '[s]cummvm' \
      "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null)
  PROC_SCANNED="${PROC_PASS}"
}

scummvm_reset() {
  SVM_PID=""; SVM_START=0; SVM_INI=""; SVM_AUTO=""; SVM_ICONDIRS=()
  SVM_INI_SEEN=""; SVM_LAST=""; SVM_ICONPATH=""; SVM_SEC=()
  SVM_KEY=""; SVM_GAMEDIR=""; SVM_HELD="no"; SVM_GONE_AT=""
  SVM_PLAYING="no"; SVM_NEED_ICON=""; SVM_BUILT=""
}

# Is this pid a ScummVM binary? By argv[0]'s name, so neither the launcher
# script (ScummVM_Master.sh) nor anything else naming the folder counts.
_svm_is() {
  local a0=""
  IFS= read -r -d '' a0 2>/dev/null <"${PROC_ROOT:-/proc}/${1}/cmdline" || [ -n "${a0}" ] || return 1
  a0="${a0##*/}"
  [[ "${a0,,}" == scummvm* ]]
}

# Find the running ScummVM and everything about it that does not change while
# it runs: start time, ini, icon folders, a game given on the command line.
# The pid is kept, and checked each time with a read rather than a search.
scummvm_find() {
  local proc="${PROC_ROOT:-/proc}" f="" pid="" args=() a="" prev="" i=0
  local home="" xdg="" e="" st="" rest="" btime="" line="" cfg="" iconsopt=""

  [ -n "${SVM_PID}" ] && _svm_is "${SVM_PID}" && return 0
  scummvm_reset
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    pid="${f%/cmdline}"; pid="${pid##*/}"
    _svm_is "${pid}" && { SVM_PID="${pid}"; break; }
  done
  [ -n "${SVM_PID}" ] || return 1

  # ScummVM takes a game to start as its last argument. An option's value may
  # be attached ("--config=f", "-cf") or the next argument ("-c f"), so an
  # argument after one of the options that take a value is that value.
  mapfile -d '' args 2>/dev/null <"${proc}/${SVM_PID}/cmdline"
  for ((i = 1; i < ${#args[@]}; i++)); do
    a="${args[i]}"
    case "${prev}" in
      -c|--config)  cfg="${a}"; prev=""; continue ;;
      --iconspath)  iconsopt="${a}"; prev=""; continue ;;
      -[bdegmopqrst]|--path|--savepath|--extrapath|--themepath|--language|--platform|--gfx-mode|--music-driver|--debuglevel|--debugflags|--engine|--game)
                    prev=""; continue ;;
    esac
    case "${a}" in
      --config=*)    cfg="${a#*=}" ;;
      --iconspath=*) iconsopt="${a#*=}" ;;
      -c?*)          cfg="${a#-c}" ;;
      -*)            ;;
      *)             [ "${i}" -eq $((${#args[@]} - 1)) ] && SVM_AUTO="${a}" ;;
    esac
    prev="${a}"
  done

  while IFS= read -r -d '' e; do
    case "${e}" in
      HOME=*)            home="${e#HOME=}" ;;
      XDG_CONFIG_HOME=*) xdg="${e#XDG_CONFIG_HOME=}" ;;
    esac
  done 2>/dev/null <"${proc}/${SVM_PID}/environ"

  if [ -z "${cfg}" ]; then
    cfg="${xdg:-${home}/.config}/scummvm/scummvm.ini"
    [ ! -e "${cfg}" ] && [ -e "${home}/.scummvmrc" ] && cfg="${home}/.scummvmrc"
  fi
  SVM_INI="${cfg}"
  # Where ScummVM keeps icons unless the ini says otherwise.
  SVM_ICONDIRS=(${iconsopt:+"${iconsopt}"} ${home:+"${home}/.cache/scummvm/icons"})

  # Its start, in epoch seconds: field 22 of stat is clock ticks since boot.
  # Everything after the ")" that closes the name, which may hold spaces.
  IFS= read -r st 2>/dev/null <"${proc}/${SVM_PID}/stat"
  rest="${st##*) }"
  read -r -a args <<<"${rest}"
  while IFS= read -r line; do
    case "${line}" in btime\ *) btime="${line#btime }" ;; esac
  done 2>/dev/null <"${proc}/stat"
  if [[ "${args[19]:-}" =~ ^[0-9]+$ ]] && [[ "${btime}" =~ ^[0-9]+$ ]]; then
    SVM_START=$(( btime + args[19] / SCUMMVM_HZ ))
  fi
  return 0
}

# The ini, re-read only when it has changed: lastselectedgame and iconspath
# from [scummvm], and the running game's own section.
scummvm_readini() {
  local mtime="${1}" target="" k="" v=""
  [ "${mtime}" = "${SVM_INI_SEEN}" ] && return 0
  SVM_INI_SEEN="${mtime}"; SVM_LAST=""; SVM_ICONPATH=""; SVM_SEC=()
  [ -r "${SVM_INI}" ] || return 1
  target="${SVM_AUTO}"
  while IFS='=' read -r k v; do
    case "${k}" in
      .last)      SVM_LAST="${v}" ;;
      .iconspath) SVM_ICONPATH="${v}" ;;
      *)          SVM_SEC[${k}]="${v}" ;;
    esac
  done < <(awk -v want="${target,,}" '
    { sub(/\r$/, "") }
    /^\[.*\]$/ { sec = tolower(substr($0, 2, length($0) - 2)); next }
    !index($0, "=") { next }
    {
      k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
      if (sec == "scummvm") {
        if (k == "lastselectedgame") { last = tolower(v); print ".last=" v }
        else if (k == "iconspath") print ".iconspath=" v
        next
      }
      if (k !~ /^(description|gameid|engineid|path|platform|language|extra)$/) next
      val[sec, k] = v; has[sec] = 1
    }
    END {
      t = (want != "") ? want : last
      if (!(t in has)) exit
      split("description gameid engineid path platform language extra", K, " ")
      for (i = 1; i <= 7; i++) if ((t, K[i]) in val) print K[i] "=" val[t, K[i]]
    }
  ' "${SVM_INI}" 2>/dev/null)
  return 0
}

# Is a game running, and which? Sets SVM_PLAYING, and SVM_SEC holds its
# section. Returns 1 in ScummVM's own launcher.
scummvm_state() {
  local mtime="" target="" key="" now="${EPOCHSECONDS:-$(date +%s)}" fds=""
  SVM_PLAYING="no"
  scummvm_find || return 1
  mtime="$(stat -c %Y "${SVM_INI}" 2>/dev/null)" || mtime=""
  scummvm_readini "${mtime}"

  if [ -n "${SVM_AUTO}" ]; then
    target="${SVM_AUTO}"
  elif [ -n "${mtime}" ] && [ "${mtime}" -gt $((SVM_START + 1)) ]; then
    # Newer than the process by more than a second: the launcher closed on a
    # game. A second of slack for a ScummVM that rewrites its ini as it starts.
    target="${SVM_LAST}"
  fi
  [ -n "${target}" ] && [ -n "${SVM_SEC[gameid]:-}" ] || return 1

  # A new start - even of the same game, which rewrites the ini - begins with
  # nothing known about its files.
  key="${target}|${mtime}"
  if [ "${key}" != "${SVM_KEY}" ]; then
    SVM_KEY="${key}"; SVM_HELD="no"; SVM_GONE_AT=""
    SVM_GAMEDIR="$(readlink -f "${SVM_SEC[path]:-/nonexistent}" 2>/dev/null)"
    SVM_GAMEDIR="${SVM_GAMEDIR%/}"
  fi

  if [ -n "${SVM_GAMEDIR}" ]; then
    fds="$(ls -l "${PROC_ROOT:-/proc}/${SVM_PID}/fd" 2>/dev/null)"
    if [[ "${fds}" == *" -> ${SVM_GAMEDIR}/"* ]]; then
      SVM_HELD="yes"; SVM_GONE_AT=""
    elif [ "${SVM_HELD}" = "yes" ]; then
      # Closed. Held a moment ago, so this engine holds its files while it
      # plays - but give a file swap a few seconds before calling it over.
      SVM_GONE_AT="${SVM_GONE_AT:-${now}}"
      [ $((now - SVM_GONE_AT)) -ge "${SCUMMVM_GONE_SECS}" ] && return 1
    fi
  fi
  SVM_PLAYING="yes"
  return 0
}

# ScummVM's platform and language codes, as a person would say them, into
# the variable named first - no subshell, as these run every pass.
_svm_platform() {
  local -n _out="${1}"
  case "${2,,}" in
    pc)          _out='DOS' ;;          windows)     _out='Windows' ;;
    amiga)       _out='Amiga' ;;        atari)       _out='Atari ST' ;;
    macintosh)   _out='Macintosh' ;;    macintosh2)  _out='Macintosh II' ;;
    apple2)      _out='Apple II' ;;     2gs)         _out='Apple IIgs' ;;
    c64)         _out='C64' ;;          fmtowns)     _out='FM Towns' ;;
    pc98)        _out='PC-98' ;;        pce)         _out='PC Engine' ;;
    segacd)      _out='Sega CD' ;;      3do)         _out='3DO' ;;
    nes)         _out='NES' ;;          linux)       _out='Linux' ;;
    playstation) _out='PlayStation' ;;  cdi)         _out='CD-i' ;;
    acorn)       _out='Acorn' ;;        coco|coco3)  _out='CoCo' ;;
    atari8)      _out='Atari 8-bit' ;;  zx)          _out='ZX Spectrum' ;;
    ti994)       _out='TI-99/4A' ;;     os2)         _out='OS/2' ;;
    *)           _out="${2}" ;;
  esac
}

_svm_language() {
  local -n _out="${1}"
  case "${2,,}" in
    en|gb|us) _out='English' ;;    de)    _out='German' ;;
    fr)       _out='French' ;;     es)    _out='Spanish' ;;
    it)       _out='Italian' ;;    pt|br) _out='Portuguese' ;;
    nl)       _out='Dutch' ;;      se|sv) _out='Swedish' ;;
    da)       _out='Danish' ;;     no|nb) _out='Norwegian' ;;
    fi)       _out='Finnish' ;;    pl)    _out='Polish' ;;
    cz|cs)    _out='Czech' ;;      hu)    _out='Hungarian' ;;
    ru)       _out='Russian' ;;    gr|el) _out='Greek' ;;
    he)       _out='Hebrew' ;;     ca)    _out='Catalan' ;;
    jp|ja)    _out='Japanese' ;;   kr|ko) _out='Korean' ;;
    cn|zh|zh-cn|tw|zh-tw) _out='Chinese' ;;
    *)        _out="${2}" ;;
  esac
}

# The console layout for the running ScummVM game, or its launcher.
# META_SHOWCORE says a game shown until now has ended: the caller puts the
# ScummVM picture back, as CMDMETAOFF alone leaves the layout on the panel.
#
# This runs every pass while ScummVM is up, beside a game using both cores, so
# the layout is worked out once a start (SVM_BUILT) and kept: a pass costs the
# ini's stat and a listing of the open files, and nothing else starts a
# process. The daemon clears SVM_BUILT when a new index lands.
scummvm_meta() {
  local was="${SVM_PLAYING}" engine="" gid="" title="" dir="" icon=""
  local i_name="" i_company="" i_year="" i_series="" i_engine="" hit=""
  local platform="" language="" rating=""
  META_KIND="console"
  SVM_NEED_ICON=""
  if ! scummvm_state; then
    META_TITLE="${DISPLAY_CORENAME}"
    META_SOURCE="core"
    META_ICON=""
    [ "${was}" = "yes" ] && META_SHOWCORE="yes"
    return 0
  fi

  engine="${SVM_SEC[engineid]:-}"; gid="${SVM_SEC[gameid]}"
  META_SOURCE="scummvm"
  META_GAME="yes"

  # The icon, once converted - named as the pack names it. Until then the
  # daemon converts it in the background, and sends it when it is there;
  # meanwhile, and for a game with none, ScummVM's own (pics/icon/ScummVM).
  printf -v icon '%s/icons/%s-%s.gsc' "${SCUMMVM_CACHE}" "${engine,,}" "${gid,,}"
  META_ICON="${DISPLAY_CORENAME:+ScummVM}"
  if [ -e "${icon}" ]; then META_ICON="${icon}"
  else SVM_NEED_ICON="${engine,,}|${gid,,}|${icon}"; fi

  if [ "${SVM_BUILT}" = "${SVM_KEY}" ]; then
    META_TITLE="${SVM_C_TITLE}"; META_DESC="${SVM_C_DESC}"
    META_FIELDS=("${SVM_C_FIELDS[@]}"); META_PINNED_COUNT="${SVM_C_PINNED}"
    return 0
  fi
  SVM_BUILT="${SVM_KEY}"

  [ -r "${SCUMMVM_CACHE}/games.idx" ] &&
    hit="$(awk -F'|' -v e="${engine,,}" -v g="${gid,,}" \
             '$1 == e && $2 == g { print; exit }' "${SCUMMVM_CACHE}/games.idx" 2>/dev/null)"
  [ -n "${hit}" ] && IFS='|' read -r _ _ i_name i_company i_year i_series i_engine <<<"${hit}"

  # An imported gamelist, keyed by the game's folder - what a scraper names
  # it - or by the target, as a .scummvm file named after it would be.
  # Batocera's folders are "Full Throttle.scummvm", and the importer drops that
  # extension as it does ".svm".
  dir="${SVM_SEC[path]:-}"; dir="${dir%/}"; dir="${dir##*/}"
  [[ "${dir,,}" == *.scummvm ]] && dir="${dir%.*}"
  lookup_scraped "${dir}" "" ScummVM || lookup_scraped "${gid}" "" ScummVM

  # ScummVM's own title, else its description less the variant in brackets -
  # "Full Throttle (Version A/English)" - else a gamelist's.
  title="${SVM_SEC[description]:-}"
  title="${title% (*}"
  META_TITLE="${i_name:-${title:-${SCR_TITLE:-${gid}}}}"
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="${SCR_DESC}"

  local _year="${i_year:-${SCR_RELEASED:0:4}}" _company="${i_company:-${SCR_PUBLISHER}}"
  if [ "${COMPACT_YEAR_COMPANY}" = "yes" ] && [ -n "${_year}" ] && [ -n "${_company}" ]; then
    _year="${_year}, ${_company}"; _company=""
  fi
  # ScummVM names a one-game engine after its game ("Lure of the
  # Temptress"): as a field that only repeats the title.
  i_engine="${i_engine:-${engine^^}}"
  [ "${i_engine,,}" = "${META_TITLE,,}" ] && i_engine=""
  _svm_platform platform "${SVM_SEC[platform]:-}"
  _svm_language language "${SVM_SEC[language]:-}"
  _scr_rating "${SCR_RATING}"; rating="${_R}"
  META_AVAIL=(
    [System]="${DISPLAY_CORENAME}"
    [Year]="${_year}"
    [Company]="${_company}"
    [Genre]="${SCR_GENRE}"
    [Developer]="${SCR_DEVELOPER}"
    [Engine]="${i_engine}"
    [Platform]="${platform}"
    [Language]="${language}"
    [Players]="${SCR_PLAYERS}"
    [Rating]="${rating}"
    [Released]="${SCR_RELEASED}"
    [Series]="${i_series:-${SCR_SERIES}}"
  )
  meta_addfields_ordered

  SVM_C_TITLE="${META_TITLE}"; SVM_C_DESC="${META_DESC}"
  SVM_C_FIELDS=("${META_FIELDS[@]}"); SVM_C_PINNED="${META_PINNED_COUNT}"
  return 0
}

# The folders to look for icon packs in, into SVM_DIRS: the ini's iconspath,
# then the command line's and ScummVM's default - those that exist.
scummvm_icondirs() {
  local d=""
  SVM_DIRS=()
  for d in ${SVM_ICONPATH:+"${SVM_ICONPATH}"} "${SVM_ICONDIRS[@]}"; do
    [ -d "${d}" ] && SVM_DIRS+=("${d}")
  done
  [ "${#SVM_DIRS[@]}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# The DVD core: a film, where it is in it, and what it is
# ---------------------------------------------------------------------------
#
# owenb321's MiSTer_DVD decodes and navigates in the FPGA, behind a Main of
# its own (MiSTer_DVDcss) that feeds it sectors - from the drive, /dev/sr0,
# or an ISO - and writes nothing about the film anywhere. Two things can be
# seen from here, both measured on the real MiSTer:
#
#   Where Main is reading. Its descriptor on the disc moves as it reads
#   (/proc/<pid>/fdinfo, "pos:"), and the disc's IFOs say which title,
#   chapter and second each sector is. tty2oledplus_dvd.py turns them into
#   one table, once per disc (cache/dvd/<key>.nav), which is searched here.
#   Main reads through a RAM ring of 16384 sectors (dvd_readahead.cpp,
#   RA_CAP) that it keeps full ahead of the core: the read is 32MB - half a
#   minute and more of film - ahead of the picture, measured 16854 sectors
#   with the ring full. So the place on screen is the daemon's own clock
#   (DVD_E_MS), counted while the film plays and set from the read where the
#   read says exactly: a seek, a chapter skip or a new title empties the ring
#   and starts it again where the core now is.
#
#   Whether it plays. The core reports pause, still, menu and whether a disc
#   is in through its telemetry (/tmp/dvd_telem.json, every 250ms), which its
#   Main writes only while /media/fat/dvd_hil exists. The daemon creates that
#   file while the DVD core is up (dvd_arm) and removes it after - only its
#   own, which says so inside.
#
# What the film is: Wikipedia, asked once per disc by its label (or an ISO by
# its name), into scraped/DVD.txt - lookup_scraped's format, keyed by the
# disc's label, date and size (tty2oledplus_dvd.py's disc_key). The user may
# edit it; a title they correct there is the title shown.
: "${DVD_CACHE:=/media/fat/tty2oledplus/cache/dvd}"
: "${DVD_TELEM:=/tmp/dvd_telem.json}"
: "${DVD_ARM:=/media/fat/dvd_hil}"
DVD_ARM_MARK="armed by tty2oled+ while the DVD core runs - removed when it stops"
DVD_LEAD_FULL=16850       # sectors the read runs ahead with Main's ring full
DVD_LEAD_MAX=17600        # ...and never more: the ring and the core's own
# A read further on than this in one look (plus DVD_JUMP_RATE a millisecond)
# is the core going somewhere, not the ring filling: measured fills are a
# sector a millisecond, about.
DVD_JUMP_SECTORS=2048
DVD_JUMP_RATE=3
DVD_BACK_SECTORS=300      # the ring keeps 256 behind for the core's re-reads

dvd_core() { [ "${1^^}" = "DVD" ]; }

declare -A DVD_STARTS=()
DVD_GEN=0                 # one more each time a disc goes: a scan of the last one is stale

# The disc went, or another came: what was known of it goes too.
dvd_forget() {
  DVD_FD=""; DVD_DEV=""
  DVD_KEY=""; DVD_LABEL=""; DVD_NAVFILE=""; DVD_FALLBACK=""; DVD_SCANNED=""
  DVD_S=(); DVD_E=(); DVD_TI=(); DVD_T0=(); DVD_T1=(); DVD_MENU=(); DVD_STARTS=()
  DVD_MAIN_TITLE=0; DVD_MAIN_TOTAL=0; DVD_TITLES=0
  DVD_R_PREV=""; DVD_AT_PREV=""; DVD_E_MS=0; DVD_TITLE=0
  DVD_STATE=0; DVD_CHAPTER=0; DVD_CHAPTERS=0; DVD_TOTAL=0
  DVD_BUILT=""
  DVD_GEN=$(( DVD_GEN + 1 ))
}

dvd_reset() {
  dvd_forget
  DVD_PID=""; DVD_HAD_DISC="no"
}
dvd_reset

# Is this pid a MiSTer Main, the DVD core's or any? It runs the core's .rbf,
# named as its first argument.
_dvd_is_main() {
  local a0="" a1=""
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null <"${PROC_ROOT:-/proc}/${1}/cmdline"
  [[ "${a0##*/}" == MiSTer* ]] && [[ "${a1,,}" == *.rbf ]]
}

# Find the disc Main is reading: DVD_PID, DVD_FD and DVD_DEV - the drive, or
# the image. The pid is kept and checked with a read; the descriptor is
# looked for with one listing, and checked after that with two tests.
dvd_find() {
  local proc="${PROC_ROOT:-/proc}" f="" pid="" line="" n="" target=""
  if [ -n "${DVD_FD}" ]; then
    [ -e "${proc}/${DVD_PID}/fd/${DVD_FD}" ] &&
      [ "${proc}/${DVD_PID}/fd/${DVD_FD}" -ef "${DVD_DEV}" ] && return 0
    # Closed: ejected, or another image mounted. The drive's name stays the
    # same from disc to disc, so its scan cannot outlive the descriptor.
    dvd_forget
  fi
  if [ -z "${DVD_PID}" ] || ! _dvd_is_main "${DVD_PID}"; then
    DVD_PID=""
    for f in "${proc}"/[0-9]*/comm; do
      IFS= read -r n 2>/dev/null <"${f}" || continue
      [[ "${n}" == MiSTer* ]] || continue
      pid="${f%/comm}"; pid="${pid##*/}"
      _dvd_is_main "${pid}" && { DVD_PID="${pid}"; break; }
    done
    [ -n "${DVD_PID}" ] || return 1
  fi
  # "lrwx------ 1 root root 64 Oct  3 02:41 9 -> /dev/sr0"
  while IFS= read -r line; do
    [[ "${line}" == *" -> "* ]] || continue
    target="${line##* -> }"
    n="${line% -> *}"; n="${n##* }"
    case "${target,,}" in
      /dev/sr[0-9]*|*.iso|*.img) DVD_FD="${n}"; DVD_DEV="${target}"; return 0 ;;
    esac
  done < <(ls -l "${proc}/${DVD_PID}/fd" 2>/dev/null)
  return 1
}

# Load a disc's table: each column one line, read whole.
dvd_navload() {
  local file="${1}" k="" rest=""
  DVD_S=(); DVD_E=(); DVD_TI=(); DVD_T0=(); DVD_T1=(); DVD_MENU=(); DVD_STARTS=()
  DVD_MAIN_TITLE=0; DVD_MAIN_TOTAL=0; DVD_TITLES=0
  [ -r "${file}" ] || return 1
  while IFS=' ' read -r k rest; do
    case "${k}" in
      start)    read -r -a DVD_S  <<<"${rest}" ;;
      end)      read -r -a DVD_E  <<<"${rest}" ;;
      title)    read -r -a DVD_TI <<<"${rest}" ;;
      t0)       read -r -a DVD_T0 <<<"${rest}" ;;
      t1)       read -r -a DVD_T1 <<<"${rest}" ;;
      menu)     read -r -a DVD_MENU <<<"${rest}" ;;
      titles)   DVD_TITLES="${rest}" ;;
      main)     read -r DVD_MAIN_TITLE DVD_MAIN_TOTAL _ <<<"${rest}" ;;
      starts[0-9]*) DVD_STARTS[${k#starts}]="${rest}" ;;
    esac
  done <"${file}"
  [ "${#DVD_S[@]}" -gt 0 ] && [ "${#DVD_S[@]}" -eq "${#DVD_T1[@]}" ]
}

# The segment holding a sector, into _R: its index, or -1. Binary search -
# a film is a thousand and more of them, and this runs every second.
dvd_seg() {
  local s="${1}" lo=0 hi=$(( ${#DVD_S[@]} - 1 )) mid=0
  _R=-1
  while [ "${lo}" -le "${hi}" ]; do
    mid=$(( (lo + hi) / 2 ))
    if [ "${s}" -lt "${DVD_S[mid]}" ]; then hi=$(( mid - 1 ))
    elif [ "${s}" -gt "${DVD_E[mid]}" ]; then lo=$(( mid + 1 ))
    else _R="${mid}"; return 0; fi
  done
  return 1
}

# Milliseconds into its title at a sector of segment $1, into _R: the
# segment's seconds, shared out over its sectors.
dvd_ms_at() {
  local i="${1}" s="${2}" span=0
  span=$(( DVD_E[i] - DVD_S[i] + 1 ))
  _R=$(( DVD_T0[i] * 1000 + (DVD_T1[i] - DVD_T0[i]) * 1000 * (s - DVD_S[i]) / span ))
}

# Is a sector in a menu's video (VIDEO_TS.VOB, a VTS_xx_0.VOB)?
dvd_in_menu() {
  local s="${1}" i=0
  for ((i = 0; i + 1 < ${#DVD_MENU[@]}; i += 2)); do
    [ "${s}" -ge "${DVD_MENU[i]}" ] && [ "${s}" -le "${DVD_MENU[i + 1]}" ] && return 0
  done
  return 1
}

# Title $1's length, chapter count and the chapter at $2 ms, into DVD_TOTAL,
# DVD_CHAPTERS and DVD_CHAPTER.
dvd_chapter() {
  local -a st=()
  local ms="${2}" i=0
  read -r -a st <<<"${DVD_STARTS[${1}]:-0}"
  DVD_TOTAL="${st[0]:-0}"
  DVD_CHAPTERS=$(( ${#st[@]} - 1 ))
  DVD_CHAPTER=0
  for ((i = 1; i < ${#st[@]}; i++)); do
    [ $(( st[i] * 1000 )) -le "${ms}" ] && DVD_CHAPTER="${i}"
  done
  [ "${DVD_CHAPTERS}" -gt 0 ] && [ "${DVD_CHAPTER}" -eq 0 ] && DVD_CHAPTER=1
  return 0
}

# A length as the Runtime field says it: 1h 43m, 58m.
_dvd_runtime() {
  local s="${1:-0}"
  _R=""
  [ "${s}" -gt 0 ] 2>/dev/null || return 0
  if [ "${s}" -ge 3600 ]; then printf -v _R '%dh %02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else printf -v _R '%dm' $(( (s + 30) / 60 )); fi
}

# The DVD core's layout. No disc, or one not read yet: the core's picture,
# and META_SHOWCORE when a disc shown until now has gone. Built once a disc
# and whenever scraped/DVD.txt changes (DVD_BUILT), since this runs every
# pass beside the film.
#
# DVD_FIELDS picks and orders the fields, from Year Studio Director Artist
# Genre Runtime Titles Label. Studio is the infobox's studio, else its record
# label or distributor; Artist a concert's band.
: "${DVD_FIELDS:=Year Studio Director Artist Genre Runtime}"
_DVD_KNOWN="Year Studio Director Artist Genre Runtime Titles Label"
dvd_meta() {
  local had="${DVD_HAD_DISC}" stamp="" f="" label="" titles=""
  META_KIND="console"
  if ! dvd_find || [ -z "${DVD_KEY}" ] || [ "${DVD_SCANNED}" != "${DVD_DEV}" ]; then
    META_TITLE="${DISPLAY_CORENAME}"
    META_SOURCE="core"
    META_ICON=""
    [ "${had}" = "yes" ] && META_SHOWCORE="yes"
    DVD_HAD_DISC="no"; DVD_BUILT=""
    return 0
  fi
  DVD_HAD_DISC="yes"
  META_SOURCE="dvd"
  META_GAME="yes"
  META_ICON="dvd"

  # scraped/DVD.txt is among the times meta_stat takes each pass: a
  # Wikipedia answer landing, or the user's own correction, is a new build.
  stamp="${DVD_KEY}|${META_MTIME[${SCRAPE_DIR}/DVD.txt]:-}"
  if [ "${DVD_BUILT}" = "${stamp}" ]; then
    META_TITLE="${DVD_C_TITLE}"; META_DESC="${DVD_C_DESC}"
    META_FIELDS=("${DVD_C_FIELDS[@]}")
    return 0
  fi
  DVD_BUILT="${stamp}"

  lookup_scraped "${DVD_KEY}" "" DVD
  META_TITLE="${SCR_TITLE:-${DVD_FALLBACK:-${DVD_LABEL:-${DISPLAY_CORENAME}}}}"
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="${SCR_DESC}"
  _dvd_runtime "${DVD_MAIN_TOTAL}"
  [ "${DVD_TITLES:-0}" -gt 1 ] && titles="${DVD_TITLES}"
  declare -A avail=(
    [Year]="${SCR_RELEASED:0:4}"
    [Studio]="${SCR_PUBLISHER}"
    [Director]="${SCR_DEVELOPER}"
    [Artist]="${SCR_SERIES}"
    [Genre]="${SCR_GENRE}"
    [Runtime]="${_R}"
    [Titles]="${titles}"
    [Label]="${DVD_LABEL}"
  )
  for f in ${DVD_FIELDS}; do
    _canon_label "${f}" "${_DVD_KNOWN}" || continue
    label="${_R}"
    meta_addfield "${label}" "${avail[${label}]:-}"
  done
  META_PINNED_COUNT=0
  DVD_C_TITLE="${META_TITLE}"; DVD_C_DESC="${META_DESC}"
  DVD_C_FIELDS=("${META_FIELDS[@]}")
  return 0
}

# ---------------------------------------------------------------------------
# meta_inputs - everything build_meta reads, as one string, into META_INPUTS:
# the core, the state files' contents, and the times of those and of the
# tables and folders it looks things up in (meta_stat). The same string, the
# same result - so a pass that finds it unchanged, which is nearly every pass
# while a game is played, need not build anything. A build is some forty
# processes on a console game; this is one.
#
# Not for ScummVM: its layout depends on ScummVM's own files and open
# descriptors, which it caches itself (SVM_BUILT).
# ---------------------------------------------------------------------------
META_INPUTS=""
meta_inputs() {  # meta_inputs <corename>
  local f="" v="" out="${1}"
  meta_stat
  META_STAT_FRESH="yes"
  for f in "${MISTER_RBFNAME}" "${MISTER_STARTPATH}" "${MISTER_FULLPATH}" \
           "${MISTER_CURRENTPATH}" "${MISTER_FILESELECT}" "${MISTER_GAMEID}"; do
    v=""
    [ -r "${f}" ] && IFS= read -r -d '' v 2>/dev/null <"${f}"
    out="${out}"$'\x1f'"${v}"
  done
  META_INPUTS="${out}"$'\x1f'"${META_STATSIG}"
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

  # Not a core: the menu core is loaded underneath, and RBFNAME/STARTPATH
  # still name it - so they are no names for this. Ahead of classify_core,
  # and names.txt read once a core change: this runs every pass beside a
  # ScummVM game, and each of those is a process.
  if scummvm_core "${corename}"; then
    if [ "${corechange}" = "corechange" ] || [ -z "${SVM_DISPLAY:-}" ]; then
      SVM_PLAYING="no"
      CORE_STARTPATH=""
      display_corename "${corename}"
      SVM_DISPLAY="${DISPLAY_CORENAME}"
    fi
    DISPLAY_CORENAME="${SVM_DISPLAY}"
    scummvm_meta
    return 0
  fi

  # The times of everything below, once: taken already this pass if
  # meta_inputs decided a build was due.
  [ "${META_STAT_FRESH}" = "yes" ] || meta_stat
  META_STAT_FRESH=""

  # The DVD core: a film, not a game - its own layout, built from the disc
  # (dvd_meta). Its name read from names.txt once a core change.
  if [ "${DVD_SCREEN:-yes}" = "yes" ] && dvd_core "${corename}"; then
    if [ "${corechange}" = "corechange" ] || [ -z "${DVD_DISPLAY:-}" ]; then
      CORE_STARTPATH=""
      _slurp _rbf "${MISTER_RBFNAME}"
      display_corename "${corename}" "${_rbf}"
      DVD_DISPLAY="${DISPLAY_CORENAME}"
    fi
    DISPLAY_CORENAME="${DVD_DISPLAY}"
    dvd_meta
    return 0
  fi

  classify_core "${corename}"

  _slurp _rbf "${MISTER_RBFNAME}"
  display_corename "${corename}" "${_rbf}"

  # A hybrid core is its game, wherever it was started from and whatever is
  # left in the state files: the table's line is the whole of it.
  if hybrid_core "${corename}"; then
    hybrid_meta "${corename}"
    return 0
  fi

  case "${META_KIND}" in

    arcade)
      if parse_mra "${CORE_STARTPATH}"; then
        META_TITLE="${MRA_NAME}"
        META_SOURCE="mra"
        META_GAME="yes"
        arcade_lookup_scraped "${corename}"
        arcade_avail_from_mra "${corename}"
        arcade_addfields_ordered
        [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="${SCR_DESC}"
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
        sel_id="${romref}|${META_MTIME[${MISTER_CURRENTPATH}]:-0}"

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

        # What the imported gamelist said. The index stays first for
        # everything the two share - it is keyed on the dump itself - and these
        # fill whatever it left empty, which on the disc systems is the year,
        # the publisher, the genre and the developer. The rest - players,
        # rating, release date, series, description - only the gamelist has.
        lookup_scraped "${romref}" "${GAME_CRC32}" "${corename}"
        if [ -z "${IDX_TITLE}" ] && [ -n "${SCR_TITLE}" ]; then
          META_TITLE="${SCR_TITLE}"
          META_SOURCE="scraped"
        fi
        [ -z "${IDX_YEAR}" ]      && IDX_YEAR="${SCR_RELEASED:0:4}"
        [ -z "${IDX_PUBLISHER}" ] && IDX_PUBLISHER="${SCR_PUBLISHER}"
        [ -z "${IDX_GENRE}" ]     && IDX_GENRE="${SCR_GENRE}"
        [ -z "${IDX_DEVELOPER}" ] && IDX_DEVELOPER="${SCR_DEVELOPER}"
        [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="${SCR_DESC}"

        # "1990, Acclaim" on one row rather than two. Either half on its own
        # still shows under its own label.
        local _year="${IDX_YEAR}" _company="${IDX_PUBLISHER}"
        if [ "${COMPACT_YEAR_COMPANY}" = "yes" ] &&
           [ -n "${_year}" ] && [ -n "${_company}" ]; then
          _year="${_year}, ${_company}"
          _company=""
        fi

        _scr_rating "${SCR_RATING}"
        local _rating="${_R}"
        META_AVAIL=(
          [System]="${DISPLAY_CORENAME}"
          [Region]="${ROM_REGION}"
          [Year]="${_year}"
          [Company]="${_company}"
          [Genre]="${IDX_GENRE}"
          [Developer]="${IDX_DEVELOPER}"
          [Format]="${ROM_EXT^^}"
          [Players]="${SCR_PLAYERS}"
          [Rating]="${_rating}"
          [Released]="${SCR_RELEASED}"
          [Series]="${SCR_SERIES}"
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
