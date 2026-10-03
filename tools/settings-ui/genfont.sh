#!/usr/bin/env bash
#
# Regenerate tools/settings-ui/fonts.h from the u8g2 fonts the firmware uses.
#
#   ./tools/settings-ui/genfont.sh [name font ...]     # default: the shipped set
#
# Needs a host C++ compiler and the Arduino libraries the firmware builds
# against (~/Arduino/libraries, or ARDUINO_LIBS=), as make-screenshots.sh does.

set -euo pipefail

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
LIBS="${ARDUINO_LIBS:-${HOME}/Arduino/libraries}"
GFX="${LIBS}/Adafruit_GFX_Library"
U8G2="${LIBS}/U8g2_for_Adafruit_GFX/src"
STUBS="${ROOT}/tools/screenshots/stubs"
OUT="${GENFONT_OUT:-${HERE}/fonts.h}"

[ "${#}" -gt 0 ] || set -- title tenfatguys_tr head luBS08_tf body 6x12_mf small 5x7_mf

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# u8g2_fonts.c as C, not C++, as make-screenshots.sh explains.
gcc -O1 -w -I "${STUBS}" -I "${U8G2}" -c "${U8G2}/u8g2_fonts.c" -o "${WORK}/u8g2_fonts.o"
g++ -std=c++11 -O1 -w -DARDUINO=100 -I "${STUBS}" -I "${GFX}" -I "${U8G2}" \
    -o "${WORK}/genfont" "${HERE}/genfont.cpp" \
    "${GFX}/Adafruit_GFX.cpp" "${U8G2}/U8g2_for_Adafruit_GFX.cpp" "${WORK}/u8g2_fonts.o"
"${WORK}/genfont" "$@" > "${OUT}.new"
mv "${OUT}.new" "${OUT}"
echo "wrote ${OUT}"
