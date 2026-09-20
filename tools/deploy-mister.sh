#!/bin/bash
#
# Push tty2oled+ from this working copy to the MiSTer over SSH.
#
# Run from the repo root on your workstation. No git, no Claude Code and no
# Samba share needed on the MiSTer - just SSH.
#
#   ./tools/deploy-mister.sh                  # scripts only, restart the daemon
#   ./tools/deploy-mister.sh --firmware       # also copy the newest merged.bin
#   ./tools/deploy-mister.sh --firmware --flash   # ...and flash it
#
# Host defaults to root@MiSTer.local; override with MISTER=root@192.168.1.50.
#
# Set up key auth once and it stops asking for a password:
#   ssh-copy-id root@MiSTer.local

set -eu

MISTER="${MISTER:-root@MiSTer.local}"
REMOTE="${REMOTE:-/media/fat/tty2oled}"

WITH_FIRMWARE="no"
DO_FLASH="no"
for arg in "$@"; do
  case "${arg}" in
    --firmware) WITH_FIRMWARE="yes" ;;
    --flash)    WITH_FIRMWARE="yes"; DO_FLASH="yes" ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$1"; }

[ -f tty2oled.sh ] && [ -f tty2oled-meta.sh ] \
  || { echo "Run this from the repository root." >&2; exit 1; }

# tty2oled-user.ini is deliberately absent from this list. It holds the user's
# own settings, it is sourced after tty2oled-system.ini so it overrides these
# files, and copying the repo's copy over it would wipe their configuration.
FILES="tty2oled.sh tty2oled-meta.sh tty2oled-system.ini"
TOOLS="tools/tty2oled-diag.sh tools/flash-mister.sh"

say "Copying scripts to ${MISTER}:${REMOTE}"
# shellcheck disable=SC2086
scp -q ${FILES} ${TOOLS} "${MISTER}:${REMOTE}/"

if [ "${WITH_FIRMWARE}" = "yes" ]; then
  BIN="$(ls -t MiSTer_SSD1322_USB/build-out-*/*.merged.bin 2>/dev/null | head -n1)"
  [ -n "${BIN}" ] || { echo "No merged.bin found - build the firmware first." >&2; exit 1; }
  say "Copying firmware: ${BIN}"
  scp -q "${BIN}" "${MISTER}:${REMOTE}/"
fi

say "Fixing permissions and restarting the daemon"
ssh "${MISTER}" "
  set -e
  chmod +x ${REMOTE}/tty2oled.sh ${REMOTE}/tty2oled-meta.sh \
           ${REMOTE}/tty2oled-diag.sh ${REMOTE}/flash-mister.sh
  # The init script refuses to parse CRLF, and files can pick it up in transit.
  dos2unix -k -q ${REMOTE}/*.ini 2>/dev/null || true
  ${REMOTE}/S60tty2oled restart
"

if [ "${DO_FLASH}" = "yes" ]; then
  say "Flashing"
  # -t so esptool's progress output is not buffered into one lump at the end.
  ssh -t "${MISTER}" "${REMOTE}/flash-mister.sh"
fi

say "Done. Watch it with:  ssh ${MISTER} 'tail -f /tmp/tty2oled'"
