#!/bin/bash
#
# Build the tty2oled+ title index from libretro-database.
#
# Run on your workstation - it downloads a few MB per system and needs curl.
# The result is one index file per MiSTer core name, which deploy-mister.sh
# --index copies to the MiSTer.
#
#   ./tools/build-title-index.sh                 # every mapped system
#   ./tools/build-title-index.sh NES GAMEBOY     # just these
#   ./tools/build-title-index.sh --list          # show the core -> dat map
#
# Each line of an index file is:
#
#   CRC32|Title|Region|Year|Publisher|Genre|Developer
#
# tty2oled-meta.sh looks a game up by the CRC32 that MiSTer writes to
# /tmp/GAMEID, so a hit replaces the filename-derived title with the canonical
# one and fills in the fields the filename cannot supply.
#
# Source: https://github.com/libretro/libretro-database (metadat/), which is
# CRC-keyed, offline, and needs no API key or account.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
OUT="${OUT:-${REPO}/titleindex}"
CACHE="${CACHE:-${REPO}/.index-cache}"
BASE="https://raw.githubusercontent.com/libretro/libretro-database/master/metadat"

# The four categories worth carrying onto a 256x64 display. Each is a separate
# file per system upstream; a game may appear in some and not others.
#
# Format is <directory>:<dat field>:<tag>. For these three coincide, but the
# disc systems live in metadat/redump and the field there is "serial", so the
# directory and the field name are not interchangeable.
CATEGORIES="releaseyear:releaseyear:year publisher:publisher:publisher
            genre:genre:genre developer:developer:developer"

FORCE="no"
LIST="no"

# ---------------------------------------------------------------------------
# MiSTer core name -> libretro dat basename(s).
#
# One core often covers several libretro systems - the MiSTer GAMEBOY core
# plays Game Boy and Game Boy Color, SMS plays Master System, Game Gear and
# SG-1000 - so the value is a list and every dat in it is merged into one
# index file.
#
# Core names are what MiSTer writes to /tmp/CORENAME. If yours is missing or
# spelled differently, add a line here; tools/tty2oled-diag.sh prints the name
# your MiSTer actually uses.
# ---------------------------------------------------------------------------
sysmap() {
  case "${1^^}" in
    NES)            echo "Nintendo - Nintendo Entertainment System|Nintendo - Family Computer Disk System" ;;
    SNES)           echo "Nintendo - Super Nintendo Entertainment System|Nintendo - Satellaview|Nintendo - Sufami Turbo" ;;
    GAMEBOY)        echo "Nintendo - Game Boy|Nintendo - Game Boy Color" ;;
    GBA)            echo "Nintendo - Game Boy Advance" ;;
    N64)            echo "Nintendo - Nintendo 64" ;;
    VIRTUALBOY|VB)  echo "Nintendo - Virtual Boy" ;;
    GENESIS|MEGADRIVE) echo "Sega - Mega Drive - Genesis" ;;
    S32X|SEGA32X)   echo "Sega - 32X" ;;
    SMS)            echo "Sega - Master System - Mark III|Sega - Game Gear|Sega - SG-1000" ;;
    GAMEGEAR|GG)    echo "Sega - Game Gear" ;;
    SG1000)         echo "Sega - SG-1000" ;;
    TGFX16|PCE)     echo "NEC - PC Engine - TurboGrafx 16|NEC - PC Engine SuperGrafx" ;;
    NEOGEO)         return 1 ;;   # MAME set, see mamemap
    ATARI2600|A2600) echo "Atari - 2600" ;;
    ATARI5200|A5200) echo "Atari - 5200" ;;
    ATARI7800|A7800) echo "Atari - 7800" ;;
    LYNX)           echo "Atari - Lynx" ;;
    JAGUAR)         echo "Atari - Jaguar" ;;
    COLECO|COLECOVISION) echo "Coleco - ColecoVision" ;;
    INTELLIVISION)  echo "Mattel - Intellivision" ;;
    VECTREX)        echo "GCE - Vectrex" ;;
    ODYSSEY2)       echo "Magnavox - Odyssey 2|Magnavox - Odyssey2" ;;
    CHANNELF)       echo "Fairchild - Channel F" ;;
    ARCADIA)        echo "Emerson - Arcadia 2001" ;;
    WONDERSWAN|WS)  echo "Bandai - WonderSwan|Bandai - WonderSwan Color" ;;
    NGP|NEOGEOPOCKET) echo "SNK - Neo Geo Pocket|SNK - Neo Geo Pocket Color" ;;
    SUPERVISION)    echo "Watara - Supervision" ;;
    MSX)            echo "Microsoft - MSX|Microsoft - MSX 2|Microsoft - MSX2" ;;
    STUDIO2)        echo "RCA - Studio II" ;;
    SUPERVISION8|SCV) echo "Epoch - Super Cassette Vision" ;;
    ADVENTUREVISION) echo "Entex - Adventure Vision" ;;
    *) return 1 ;;
  esac
}

# Disc systems. libretro has no releaseyear/publisher/genre/developer for
# these - they exist only under metadat/redump, which carries name, region and
# serial. So these indexes give a canonical title, a region and a serial to
# match MiSTer's /tmp/GAMEID against, and leave the metadata columns empty.
# Core names are what MiSTer reports: PSX, Saturn, MegaCD, 3DO, TGFX16.
discmap() {
  case "${1^^}" in
    PSX|PLAYSTATION)      echo "Sony - PlayStation" ;;
    SATURN)               echo "Sega - Saturn" ;;
    MEGACD|SEGACD)        echo "Sega - Mega-CD - Sega CD" ;;
    3DO)                  echo "The 3DO Company - 3DO" ;;
    TGFX16CD|PCECD)       echo "NEC - PC Engine CD - TurboGrafx-CD" ;;
    # The MiSTer TurboGrafx core plays cartridges and CDs and reports TGFX16
    # for both, so its index carries the CD set as well as the cartridge one.
    TGFX16|PCE)           echo "NEC - PC Engine CD - TurboGrafx-CD" ;;
    *) return 1 ;;
  esac
}

DISC_CORES="PSX SATURN MEGACD 3DO TGFX16CD"

# Arcade-lineage consoles. The Neo Geo AES/MVS is arcade hardware, so none of
# the four metadata categories carry it - its year and publisher live in the
# MAME set instead, keyed on the set name with the title in <description>.
# The MiSTer NeoGeo core names games by title, so the name lookup resolves
# them. The XML is ~20MB and is cached like everything else.
MAME_XML="MAME 2003-Plus XML.xml"
mamemap() {
  case "${1^^}" in
    NEOGEO) echo "neogeo" ;;
    *) return 1 ;;
  esac
}

ALL_CORES="NES SNES GAMEBOY GBA N64 VIRTUALBOY GENESIS S32X SMS TGFX16
           ATARI2600 ATARI5200 ATARI7800 LYNX JAGUAR COLECO INTELLIVISION
           VECTREX ODYSSEY2 CHANNELF ARCADIA WONDERSWAN NGP SUPERVISION MSX
           STUDIO2 SCV ADVENTUREVISION NEOGEO ${DISC_CORES}"

say()  { printf '\n==> %s\n' "$1"; }
warn() { printf '    !! %s\n' "$1" >&2; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

CORES=""
for arg in "$@"; do
  case "${arg}" in
    --force)   FORCE="yes" ;;
    --list)    LIST="yes" ;;
    --out=*)   OUT="${arg#--out=}" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*)        die "Unknown option: ${arg}" ;;
    *)         CORES="${CORES} ${arg}" ;;
  esac
done

if [ "${LIST}" = "yes" ]; then
  for c in ${ALL_CORES}; do
    printf '%-16s %s\n' "${c}" "$(sysmap "${c}" | tr '|' '\n' | sed '2,$s/^/                 /')"
  done
  exit 0
fi

[ -n "${CORES}" ] || CORES="${ALL_CORES}"

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v awk  >/dev/null 2>&1 || die "awk is required."

mkdir -p "${OUT}" "${CACHE}"

# Fetch one dat into the cache. A system genuinely absent from a category is
# normal - not every console has genre data - so a 404 is not fatal.
fetch() {
  local category="${1}" system="${2}" dest="${3}" url=""
  if [ -s "${dest}" ] && [ "${FORCE}" != "yes" ]; then
    return 0
  fi
  # Percent-encode the spaces; the rest of the names are URL-safe.
  local ext=".dat"
  [ "${category}" = "mame" ] && ext=".xml"
  url="${BASE}/${category}/${system// /%20}${ext}"
  if curl -sfL --max-time 60 -o "${dest}.part" "${url}"; then
    mv "${dest}.part" "${dest}"
    return 0
  fi
  rm -f "${dest}.part"
  return 1
}

TOTAL_GAMES=0
BUILT=0

# Collect the tagged records for one system list into $tagged.
harvest() {
  local list="${1}" cats="${2}" system="" pair="" category="" field="" tag=""
  local dest="" got=0 total=0
  IFS='|' read -r -a syslist <<<"${list}"
  for system in "${syslist[@]}"; do
    [ -n "${system}" ] || continue
    got=0
    total=0
    for pair in ${cats}; do
      total=$((total + 1))
      category="${pair%%:*}"
      field="${pair#*:}"; field="${field%%:*}"
      tag="${pair##*:}"
      dest="${CACHE}/${category}__${system}.dat"
      fetch "${category}" "${system}" "${dest}" || continue
      if awk -v field="${field}" -f "${HERE}/dat2index.awk" "${dest}" 2>/dev/null \
           | sed "s/^/${tag}	/" >> "${tagged}"; then
        got=$((got + 1))
      fi
    done
    if [ "${got}" -eq 0 ]; then
      warn "${system}: nothing downloaded (not in libretro-database?)"
    else
      printf '    %-52s %d/%d categories\n' "${system}" "${got}" "${total}"
    fi
  done
}

for core in ${CORES}; do
  carts=""; discs=""; mame=""
  carts="$(sysmap  "${core}")"  || carts=""
  discs="$(discmap "${core}")"  || discs=""
  mame="$(mamemap  "${core}")"  || mame=""

  if [ -z "${carts}" ] && [ -z "${discs}" ] && [ -z "${mame}" ]; then
    warn "${core}: no libretro system mapped - add it to sysmap() in $0"
    continue
  fi

  say "${core}"
  tagged="${CACHE}/${core}.tagged"
  : > "${tagged}"

  [ -n "${carts}" ] && harvest "${carts}" "${CATEGORIES}"
  [ -n "${discs}" ] && harvest "${discs}" "redump:serial:serial"

  if [ -n "${mame}" ]; then
    dest="${CACHE}/mame__${MAME_XML}"
    if fetch "mame" "${MAME_XML%.xml}" "${dest}"; then
      if awk -v family="${mame}" -f "${HERE}/mamexml2index.awk" "${dest}" \
           >> "${tagged}" 2>/dev/null; then
        printf '    %-52s MAME family "%s"\n' "${MAME_XML}" "${mame}"
      else
        warn "no games with romof=\"${mame}\" in ${MAME_XML}"
      fi
    else
      warn "could not fetch ${MAME_XML}"
    fi
  fi

  if [ ! -s "${tagged}" ]; then
    warn "${core}: no data, skipping"
    continue
  fi

  awk -f "${HERE}/index-emit.awk" "${tagged}" | sort -u > "${OUT}/${core}.idx"
  n="$(wc -l < "${OUT}/${core}.idx")"
  TOTAL_GAMES=$((TOTAL_GAMES + n))
  BUILT=$((BUILT + 1))
  printf '    -> %s  (%s games, %s)\n' "${OUT}/${core}.idx" "${n}" \
         "$(du -h "${OUT}/${core}.idx" | cut -f1)"
done

say "Done: ${BUILT} index files, ${TOTAL_GAMES} games, $(du -sh "${OUT}" | cut -f1) in ${OUT}"
echo
echo "Copy them to the MiSTer with:"
echo "    ./tools/deploy-mister.sh --index"
echo
echo "The cache in ${CACHE} makes a re-run cheap; --force re-downloads."
