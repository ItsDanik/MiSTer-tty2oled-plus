#!/bin/bash
#
# Install, clear or query the tty2oled+ boot screen.
#
# Run this ON THE MISTER. The image is written to the ESP's own flash, so it
# appears at power-up with the MiSTer off, the SD card out, or the daemon
# never starting.
#
#   ./tty2oled-bootimg.sh status          what is stored now
#   ./tty2oled-bootimg.sh set boot.gsc    store a 256x64 .gsc
#   ./tty2oled-bootimg.sh clear           revert to the built-in logo
#
# Make the .gsc on your workstation:
#   ./tools/png2gsc.py --boot splash.png
# then copy it over and run this.
#
# The daemon holds the serial port, so it is stopped for the transfer and
# started again afterwards, whatever happens.

set -u

T2O_DIR="${TTY2OLED_PATH:-/media/fat/tty2oled}"
INIT="${T2O_DIR}/S60tty2oled"
BOOT_BYTES=8192

die() { printf '\n*** %s\n' "$1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

[ -r "${T2O_DIR}/tty2oled-system.ini" ] || die "No tty2oled install at ${T2O_DIR}"
# shellcheck disable=SC1090,SC1091
. "${T2O_DIR}/tty2oled-system.ini"
[ -r "${T2O_DIR}/tty2oled-user.ini" ] && . "${T2O_DIR}/tty2oled-user.ini"

ACTION="${1:-status}"
IMAGE="${2:-}"

# --- Free the serial port ---------------------------------------------------
DAEMON_WAS_RUNNING="no"
[ -e /run/tty2oled-daemon.pid ] && DAEMON_WAS_RUNNING="yes"
restore_daemon() {
  if [ "${DAEMON_WAS_RUNNING}" = "yes" ]; then
    say "Restarting the tty2oled daemon"
    # Detached, or it keeps this script's stdout and an ssh session never ends.
    "${INIT}" start </dev/null >>/tmp/tty2oled-daemon.log 2>&1
  fi
}
trap restore_daemon EXIT

"${INIT}" stop >/dev/null 2>&1
sleep 1

[ -c "${TTYDEV}" ] || die "${TTYDEV} is not there. Is the display plugged in?"
stty -F "${TTYDEV}" ${BAUDRATE} ${TTYPARAM}

ask() {
  local reply=""
  echo "$1" > "${TTYDEV}"
  read -t 5 reply < "${TTYDEV}" || true
  printf '%s' "${reply}" | tr -d '\r\n'
}

case "${ACTION}" in
  status)
    say "Asking the display"
    r="$(ask CMDBOOTINF)"
    echo "    ${r:-<no answer - is this tty2oled+ firmware?>}"
    ;;

  set)
    [ -n "${IMAGE}" ] || die "Usage: $0 set <image.gsc>"
    [ -r "${IMAGE}" ] || die "Cannot read ${IMAGE}"

    # A .gsc is a 3-line header then hex; the firmware wants the raw bytes.
    # Check the size BEFORE sending: the firmware reads exactly 8192 bytes and
    # a short file would leave it waiting on a transfer that never finishes.
    got="$(tail -n +4 "${IMAGE}" | xxd -r -p | wc -c)"
    [ "${got}" -eq "${BOOT_BYTES}" ] \
      || die "${IMAGE} is ${got} bytes, need ${BOOT_BYTES} (a 256x64 .gsc).
       Make one with:  ./tools/png2gsc.py --boot yourimage.png"

    say "Sending ${IMAGE} (${got} bytes)"
    echo "CMDWRBOOT" > "${TTYDEV}"
    sleep "${WAITSECS}"
    tail -n +4 "${IMAGE}" | xxd -r -p > "${TTYDEV}"
    sleep 1
    echo "    $(ask CMDBOOTINF)"
    echo "    Power-cycle the display to see it."
    ;;

  clear)
    say "Clearing the stored boot image"
    echo "CMDCLRBOOT" > "${TTYDEV}"
    sleep 1
    echo "    $(ask CMDBOOTINF)"
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
