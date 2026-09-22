#!/usr/bin/env bash
#
# Build the tty2oled metadata fork with arduino-cli. No Arduino IDE needed.
#
#   ./build-tty2oled.sh <sketch dir> <board>
#
# <board> must match the hardware. Ask the display itself if unsure - over SSH
# on the MiSTer:
#     . /media/fat/tty2oledplus/tty2oled-system.ini
#     stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
#     echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"
#   HWLOLIN32  -> lolin32
#   HWESP32DE  -> esp32de
#   HWESP32S3  -> esp32s3
#
# Example:
#   ./build-tty2oled.sh ~/Downloads/.../MiSTer_SSD1322_USB lolin32

set -euo pipefail

SKETCH_DIR="${1:?Usage: $0 <sketch dir> <lolin32|esp32de|esp32s3>}"
BOARD="${2:?Usage: $0 <sketch dir> <lolin32|esp32de|esp32s3>}"

SKETCH_DIR="$(cd "${SKETCH_DIR}" && pwd)"
OUTDIR="${SKETCH_DIR}/build-out-${BOARD}"

# The FQBN decides which ARDUINO_* define the sketch sees, and therefore which
# pinout it compiles. Getting this wrong produces a clean build that does not
# drive the display.
case "${BOARD}" in
  lolin32) FQBN_BASE="esp32:esp32:lolin32"; CHIP="esp32"   ;;  # ARDUINO_LOLIN32
  esp32de) FQBN_BASE="esp32:esp32:esp32"  ; CHIP="esp32"   ;;  # ARDUINO_ESP32_DEV
  esp32s3) FQBN_BASE="esp32:esp32:esp32s3"; CHIP="esp32s3" ;;  # ARDUINO_ESP32S3_DEV
  *) echo "Unknown board '${BOARD}'. Use lolin32, esp32de or esp32s3." >&2; exit 1 ;;
esac

# PartitionScheme=default carries the ~1.5MB filesystem partition the boot
# screen lives in. CDCOnBoot only exists on the S3 and must stay disabled so
# Serial remains on the UART bridge the MiSTer talks to.
OPTS="PartitionScheme=default"
[ "${BOARD}" = "esp32s3" ] && OPTS="CDCOnBoot=default,${OPTS}"
FQBN="${FQBN_BASE}:${OPTS}"

ESP32_INDEX="https://espressif.github.io/arduino-esp32/package_esp32_index.json"
SKETCHBOOK="${HOME}/Arduino"
LIBDIR="${SKETCHBOOK}/libraries"

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
warn() { printf '\n\033[1;33m==> %s\033[0m\n' "$1"; }

[ -f "${SKETCH_DIR}/MiSTer_SSD1322_USB.ino" ] || {
  echo "No MiSTer_SSD1322_USB.ino in ${SKETCH_DIR}" >&2; exit 1; }

# --- arduino-cli ------------------------------------------------------------
if ! command -v arduino-cli >/dev/null 2>&1; then
  say "Installing arduino-cli into ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
    | BINDIR="${HOME}/.local/bin" sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi

# --- Config (never overwrite an existing one) -------------------------------
if ! arduino-cli config dump >/dev/null 2>&1; then
  arduino-cli config init
fi
arduino-cli config set directories.user "${SKETCHBOOK}"
arduino-cli config dump | grep -qF "${ESP32_INDEX}" || \
  arduino-cli config add board_manager.additional_urls "${ESP32_INDEX}"

# --- Core and libraries -----------------------------------------------------
# ESP32_CORE_VERSION pins the core, which is what makes a CI build the same
# firmware as a local one - the core is most of the binary, and 3.x already
# broke upstream's sketch once (the LEDC API). Unset, whatever core is
# installed is used, and the newest is installed when there is none.
if [ -n "${ESP32_CORE_VERSION:-}" ]; then
  if ! arduino-cli core list | grep -qE "^esp32:esp32 +${ESP32_CORE_VERSION//./\\.} "; then
    say "Installing ESP32 core ${ESP32_CORE_VERSION} (roughly 1GB)"
    arduino-cli core update-index
    arduino-cli core install "esp32:esp32@${ESP32_CORE_VERSION}"
  fi
elif ! arduino-cli core list | grep -q '^esp32:esp32'; then
  say "Installing the ESP32 core (roughly 1GB, first run only)"
  arduino-cli core update-index
  arduino-cli core install esp32:esp32
fi

say "Checking libraries"
arduino-cli lib install \
  "Adafruit GFX Library" "U8g2_for_Adafruit_GFX" "Bounce2" "ESP32Time" "FastLED"

mkdir -p "${LIBDIR}"
for repo in \
  "SSD1322_for_Adafruit_GFX https://github.com/venice1200/SSD1322_for_Adafruit_GFX.git" \
  "MIC184_Temperature_Sensor https://github.com/venice1200/MIC184_Temperature_Sensor.git"
do
  name="${repo%% *}"; url="${repo#* }"
  if [ -d "${LIBDIR}/${name}/.git" ]; then
    git -C "${LIBDIR}/${name}" pull --ff-only >/dev/null 2>&1 || \
      warn "Could not update ${name}, using the copy already there"
  else
    say "Cloning ${name}"
    git clone --depth 1 "${url}" "${LIBDIR}/${name}"
  fi
done

# --- Validate the FQBN separately from compiling ----------------------------
# Checking the board first means a compile error is reported as a compile
# error, instead of being blamed on the FQBN and retried pointlessly.
if ! arduino-cli board details --fqbn "${FQBN}" >/dev/null 2>&1; then
  warn "Your core does not accept '${OPTS}'. Falling back to core defaults."
  echo "    Valid options: arduino-cli board details --fqbn ${FQBN_BASE}"
  FQBN="${FQBN_BASE}"
fi

# --- Compile ----------------------------------------------------------------
rm -rf "${OUTDIR}"
say "Compiling ${BOARD} as ${FQBN}"
arduino-cli compile --fqbn "${FQBN}" --output-dir "${OUTDIR}" "${SKETCH_DIR}"

MERGED="${OUTDIR}/MiSTer_SSD1322_USB.ino.merged.bin"
say "Build finished"
ls -la "${OUTDIR}"

if [ -f "${MERGED}" ]; then
  cat <<EOM

Copy this to the MiSTer (\\\\MISTER\\fat\\tty2oledplus\\):
  ${MERGED}

Then flash it from the MiSTer over SSH, with the daemon stopped:
  python /tmp/esptool.py --chip ${CHIP} --port /dev/ttyUSB0 --baud 921600 \\
    --before default_reset --after hard_reset write_flash \\
    --compress --flash_mode dio --flash_freq 80m --flash_size detect \\
    0x0 /media/fat/tty2oledplus/MiSTer_SSD1322_USB.ino.merged.bin
EOM
else
  warn "No merged.bin produced - core too old. Flash the parts separately:"
  if [ "${CHIP}" = "esp32s3" ]; then
    echo "  0x0     ...ino.bootloader.bin"
  else
    echo "  0x1000  ...ino.bootloader.bin   (0x1000 on classic ESP32)"
  fi
  echo "  0x8000  ...ino.partitions.bin"
  echo "  0xe000  ~/.arduino15/packages/esp32/hardware/esp32/*/tools/partitions/boot_app0.bin"
  echo "  0x10000 ...ino.bin"
fi
