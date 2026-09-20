#!/bin/bash
#
# Create a blank icon for every console core, correctly formatted and named.
#
#   ./tools/make-icon-stubs.sh              # into pics_pri/ICON/
#   ./tools/make-icon-stubs.sh --with-png   # ...and an 86x64 PNG to draw on
#   ./tools/make-icon-stubs.sh --out DIR
#
# The names come from coretypes.ini, which already lists every core we know of
# under the spelling MiSTer reports in /tmp/CORENAME - and that spelling is
# exactly what findicon() looks for, so the file names are right by
# construction rather than by being typed out twice.
#
# An existing file is never overwritten, so this is safe to re-run once you
# have drawn some real icons.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
OUT="${REPO}/pics_pri/ICON"
MAP="${REPO}/coretypes.ini"
WITH_PNG="no"

for arg in "$@"; do
  case "${arg}" in
    --with-png) WITH_PNG="yes" ;;
    --out=*)    OUT="${arg#--out=}" ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

[ -r "${MAP}" ] || { echo "No ${MAP}" >&2; exit 1; }
mkdir -p "${OUT}"

made=0
kept=0
while IFS= read -r line; do
  case "${line}" in ''|\#*|\;*) continue ;; esac
  case "${line}" in *=*) ;; *) continue ;; esac

  core="${line%%=*}"
  kind="${line#*=}"
  # Trim; core names legitimately contain spaces ("Pokemon Mini").
  core="$(printf '%s' "${core}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  kind="$(printf '%s' "${kind}" | tr -d '[:space:]')"

  [ "${kind}" = "console" ] || continue
  [ -n "${core}" ] || continue

  if [ -e "${OUT}/${core}.gsc" ]; then
    kept=$((kept + 1))
  else
    "${HERE}/png2gsc.py" --blank --out "${OUT}/${core}.gsc" >/dev/null
    made=$((made + 1))
  fi

  if [ "${WITH_PNG}" = "yes" ] && [ ! -e "${OUT}/${core}.png" ]; then
    python3 - "${OUT}/${core}.png" <<'EOF'
import sys
try:
    from PIL import Image
except ImportError:
    raise SystemExit(0)
Image.new("L", (86, 64), 0).save(sys.argv[1])
EOF
  fi
done < "${MAP}"

echo "${made} created, ${kept} left alone, in ${OUT}"
echo
echo "Draw at 86x64 in 16 greys, then:"
echo "    ./tools/png2gsc.py --out ${OUT#${REPO}/}/<Core>.gsc yourart.png"
echo "    ./tools/deploy-mister.sh --icons"
