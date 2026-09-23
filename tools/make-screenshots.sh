#!/usr/bin/env bash
#
# Take screenshots of the display, without a display.
#
#   ./tools/make-screenshots.sh [outdir]      # default: docs/img
#
# The pictures in the README are the firmware's own output, not drawings.
# tools/screenshots/render.cpp compiles the sketch's display headers against
# the real Adafruit GFX and U8g2 libraries, hands them a 256x64 4bpp
# framebuffer - the same bytes the panel is sent - composes each screen with
# the code the ESP32 runs, and writes the buffer out. This wraps that: build,
# render, and scale the frames up into PNGs.
#
# So re-running it after a layout change updates the documentation, and a
# screenshot cannot drift from the layout: the rows, the fonts, the paging and
# the icons are the shipped code.
#
# Needs a host C++ compiler, ImageMagick, and the Arduino libraries the
# firmware builds against - ./tools/build-tty2oled.sh installs those into
# ~/Arduino/libraries; ARDUINO_LIBS= points elsewhere.

set -euo pipefail

HERE="$(cd "$(dirname "${0}")/.." && pwd)"
OUTDIR="${1:-${HERE}/docs/img}"
LIBS="${ARDUINO_LIBS:-${HOME}/Arduino/libraries}"
SCALE="${SCALE:-3}"          # nearest-neighbour, so a panel pixel stays square

say()  { printf '\033[1;32m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }

command -v g++ >/dev/null 2>&1 || die "No g++ - a host C++ compiler is needed."

MAGICK=""
for c in magick convert; do command -v "${c}" >/dev/null 2>&1 && { MAGICK="${c}"; break; }; done
[ -n "${MAGICK}" ] || die "No ImageMagick - install it for the PGM to PNG step."

GFX="${LIBS}/Adafruit_GFX_Library"
U8G2="${LIBS}/U8g2_for_Adafruit_GFX/src"
for d in "${GFX}" "${U8G2}"; do
  [ -d "${d}" ] || die "Missing ${d}
The renderer builds against the real libraries. Install them with
  ./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32
or point ARDUINO_LIBS at a sketchbook that has them."
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# u8g2_fonts.c is compiled as C, not C++: at namespace scope a const array has
# internal linkage in C++, so every font would be a local symbol and nothing
# could link against it.
say "Building the renderer"
gcc -O1 -w -I "${HERE}/tools/screenshots/stubs" -I "${U8G2}" \
    -c "${U8G2}/u8g2_fonts.c" -o "${WORK}/u8g2_fonts.o"

g++ -std=c++11 -O1 -w -DARDUINO=100 \
    -I "${HERE}/tools/screenshots/stubs" -I "${GFX}" -I "${U8G2}" \
    -o "${WORK}/render" \
    "${HERE}/tools/screenshots/render.cpp" \
    "${GFX}/Adafruit_GFX.cpp" "${U8G2}/U8g2_for_Adafruit_GFX.cpp" \
    "${WORK}/u8g2_fonts.o"

say "Rendering"
"${WORK}/render" "${WORK}" "${HERE}"

say "Writing PNGs into ${OUTDIR}"
mkdir -p "${OUTDIR}"
for pgm in "${WORK}"/*.pgm; do
  name="$(basename "${pgm}" .pgm)"
  # -interpolate Integer + -filter point: no smoothing. A blurred screenshot
  # of a 256x64 panel says nothing about what the panel draws.
  "${MAGICK}" "${pgm}" -filter point -resize "$((SCALE * 100))%" \
              -define png:color-type=0 "${OUTDIR}/${name}.png"
  printf '    %s.png\n' "${name}"
done

say "Done"
