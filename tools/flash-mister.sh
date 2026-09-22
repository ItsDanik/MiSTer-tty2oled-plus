#!/bin/bash
#
# Flash tty2oled+ firmware from the MiSTer itself.
#
# Run this over SSH ON THE MISTER, not on your workstation. The display is
# already wired to /dev/ttyUSB0 there, so nothing needs unplugging.
#
#   ./flash-mister.sh                       # newest *.merged.bin in the tty2oled folder
#   ./flash-mister.sh /path/to/firmware.bin # an explicit file
#
# It works out which chip you have by asking the display, stops the daemon so
# the port is free, flashes, and starts the daemon again - including if the
# flash fails, so a failed attempt never leaves the display dead.

set -u

# Kept in its own variable because sourcing tty2oled-system.ini below sets
# TTY2OLED_PATH itself, which would quietly undo an override given here.
T2O_DIR="${TTY2OLED_PATH:-/media/fat/tty2oledplus}"
INIT="${T2O_DIR}/S60tty2oled"
ESPTOOL="${T2O_DIR}/esptool.py"
PYSERIAL_DIR="/lib/python3.9/site-packages"
URL="https://www.tty2tft.de//MiSTer_tty2oled-installer"
DBAUD="${DBAUD:-921600}"

die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }
say()  { printf '\n==> %s\n' "$1"; }

[ -r "${T2O_DIR}/tty2oled-system.ini" ] \
  || die "No tty2oled install at ${T2O_DIR}"
. "${T2O_DIR}/tty2oled-system.ini"
[ -r "${T2O_DIR}/tty2oled-user.ini" ] && . "${T2O_DIR}/tty2oled-user.ini"

# --- Find the firmware ------------------------------------------------------
BIN="${1:-}"
if [ -z "${BIN}" ]; then
  BIN="$(ls -t "${T2O_DIR}"/*.merged.bin 2>/dev/null | head -n1)"
  [ -n "${BIN}" ] || die "No *.merged.bin in ${T2O_DIR}. Copy one over first, or pass a path."
fi
[ -r "${BIN}" ] || die "Cannot read ${BIN}"

# A merged image is around 1MB. Anything tiny is a stray file or a failed
# build, and flashing it would brick the display until the next attempt.
SIZE="$(stat -c%s "${BIN}" 2>/dev/null || echo 0)"
[ "${SIZE}" -gt 200000 ] \
  || die "${BIN} is only ${SIZE} bytes - that is not a merged firmware image."

say "Firmware: ${BIN} (${SIZE} bytes)"

# --- Free the serial port ---------------------------------------------------
# Restart the daemon whatever happens, so a failed flash does not leave the
# display without its daemon.
#
# Asked of the init script rather than read off a pid file: which file, and
# what makes a pid in it ours, is known there alone. This used to test the
# path upstream shares, went on testing it after the init script moved to a
# file of its own, and so concluded the daemon was never running - and a
# successful flash left the display with no daemon at all.
DAEMON_WAS_RUNNING="no"
if "${INIT}" status >/dev/null 2>&1; then DAEMON_WAS_RUNNING="yes"; fi
restore_daemon() {
  if [ "${DAEMON_WAS_RUNNING}" = "yes" ]; then
    say "Restarting the tty2oled daemon"
    # The init script backgrounds the daemon without detaching it, so the
    # daemon would keep this script's stdout - and over SSH that is the
    # connection, which then never closes. Give it a file of its own.
    "${INIT}" start </dev/null >>/tmp/tty2oled-daemon.log 2>&1
    echo "    started; its output goes to /tmp/tty2oled-daemon.log"
  fi
}
trap restore_daemon EXIT

say "Stopping the tty2oled daemon"
"${INIT}" stop
sleep 1

[ -c "${TTYDEV}" ] || die "${TTYDEV} is not there. Is the display plugged in?"

# --- Ask the display what it is ---------------------------------------------
# The installer menu lists "DevKit" twice, so the board name a human remembers
# is not reliable. The firmware knows.
say "Identifying the display"
stty -F "${TTYDEV}" ${BAUDRATE} ${TTYPARAM}
HWINF=""
echo "CMDHWINF" > "${TTYDEV}"
read -t5 HWINF < "${TTYDEV}" || true
HWINF="$(printf '%s' "${HWINF}" | tr -d '\r\n')"
echo "    reported: ${HWINF:-<no answer>}"

case "${HWINF}" in
  HWLOLIN32*) CHIP="esp32"   ; OFFSET="0x0" ;;
  HWESP32DE*) CHIP="esp32"   ; OFFSET="0x0" ;;
  HWESP32S3*) CHIP="esp32s3" ; OFFSET="0x0" ;;
  HWESP8266*) die "This is an ESP8266. The tty2oled+ firmware is ESP32 only." ;;
  *)
    # No answer usually means the running firmware is already broken, which is
    # exactly when you most need to flash. Fall back rather than refuse.
    CHIP="${CHIP_OVERRIDE:-esp32}"
    say "No usable answer - assuming --chip ${CHIP}."
    echo "    If that is wrong, re-run with: CHIP_OVERRIDE=esp32s3 $0 $*"
    OFFSET="0x0"
    ;;
esac

# --- esptool ----------------------------------------------------------------
if [ ! -r "${ESPTOOL}" ]; then
  say "Fetching esptool into ${T2O_DIR} (survives reboots, unlike /tmp)"
  wget -q "${URL}/esptool.py" -O "${ESPTOOL}" || die "Could not download esptool"
  chmod +x "${ESPTOOL}"
fi

if ! python -c "import serial" 2>/dev/null; then
  say "Installing pyserial"
  wget -q "${URL}/pyserial-3.5-py3.9.egg" -O "${PYSERIAL_DIR}/pyserial-3.5-py3.9.egg" \
    || die "Could not download pyserial"
  echo "./pyserial-3.5-py3.9.egg" >> "${PYSERIAL_DIR}/easy-install.pth"
fi

# --- What to write ----------------------------------------------------------
# Not the whole image, when that can be avoided. A merged image covers the
# entire chip, and the settings store and the boot image's filesystem are
# erased bytes in it - so writing all of it at ${OFFSET} erased both, and every
# flash forgot the stored boot screen. fw-segments.py works out which parts
# carry data, and says to write the lot whenever the display's partitions are
# not laid out as the new firmware expects: reading the display's table first
# is what makes keeping the rest safe.
SEGDIR="$(mktemp -d /tmp/tty2oled-fw.XXXXXX)"
trap 'restore_daemon; rm -rf "${SEGDIR}"' EXIT
PARTS=("${OFFSET}" "${BIN}")
if [ -r "${T2O_DIR}/fw-segments.py" ]; then
  say "Reading the display's partition table"
  python "${ESPTOOL}" --chip "${CHIP}" --port "${TTYDEV}" --baud "${DBAUD}" \
    --before default_reset --after no_reset \
    read_flash 0x8000 0xC00 "${SEGDIR}/table.bin" >/dev/null 2>&1 \
    || rm -f "${SEGDIR}/table.bin"
  PLAN=()
  while read -r off file; do
    [ -n "${off}" ] && PLAN+=("${off}" "${file}")
  done < <(python "${T2O_DIR}/fw-segments.py" "${BIN}" "${SEGDIR}" "${SEGDIR}/table.bin")
  [ "${#PLAN[@]}" -ge 2 ] && PARTS=("${PLAN[@]}")
fi
if [ "${#PARTS[@]}" -gt 2 ]; then
  BYTES=0
  for ((i = 1; i < ${#PARTS[@]}; i += 2)); do BYTES=$((BYTES + $(stat -c%s "${PARTS[i]}"))); done
  echo "    writing $((${#PARTS[@]} / 2)) parts, ${BYTES} bytes - the stored boot"
  echo "    screen and settings are kept"
else
  echo "    writing the whole image - the stored boot screen and settings are erased"
fi

# --- Flash ------------------------------------------------------------------
say "Flashing ${CHIP} via ${TTYDEV}"
if ! python "${ESPTOOL}" --chip "${CHIP}" --port "${TTYDEV}" --baud "${DBAUD}" \
     --before default_reset --after hard_reset write_flash \
     --compress --flash_mode dio --flash_freq 80m --flash_size detect \
     "${PARTS[@]}"; then
  echo
  echo "Flash failed. Worth trying, in order:"
  echo "  1. A slower rate:  DBAUD=115200 $0 $*"
  echo "  2. Power-cycle the MiSTer and run it again."
  echo "  3. If it still cannot connect, this board's auto-reset is not wired"
  echo "     through and it has to be flashed from a PC over USB."
  exit 1
fi

say "Done. The display will restart on its own."
