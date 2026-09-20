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
#   ./tools/deploy-mister.sh --index          # also copy titleindex/*.idx
#   ./tools/deploy-mister.sh --icons          # also copy pics/ICON/*.gsc
#
# Host defaults to root@MiSTer.local; override with MISTER=root@192.168.1.50.
#
# Set up key auth once and it stops asking for a password:
#   ssh-copy-id root@MiSTer.local

set -eu

MISTER="${MISTER:-root@MiSTer.local}"
REMOTE="${REMOTE:-/media/fat/tty2oled}"

# S60tty2oled backgrounds the daemon without detaching it, so the daemon keeps
# whatever stdout it was started with. Over SSH that is the connection itself,
# and ssh then waits on that pipe for as long as the daemon lives - which is
# what used to hang the deploy before it ever reached the flash step. Give the
# daemon its own file to talk to and the remote command can finish.
DAEMON_LOG="/tmp/tty2oled-daemon.log"
DAEMON_FDS="</dev/null >>${DAEMON_LOG} 2>&1"

WITH_FIRMWARE="no"
DO_FLASH="no"
WITH_INDEX="no"
WITH_ICONS="no"
for arg in "$@"; do
  case "${arg}" in
    --firmware) WITH_FIRMWARE="yes" ;;
    --flash)    WITH_FIRMWARE="yes"; DO_FLASH="yes" ;;
    --index)    WITH_INDEX="yes" ;;
    --icons)    WITH_ICONS="yes" ;;
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
TOOLS="tools/tty2oled-diag.sh tools/flash-mister.sh tools/tty2oled-capture.sh
       tools/tty2oled-bootimg.sh"

say "Copying scripts to ${MISTER}:${REMOTE}"
# shellcheck disable=SC2086
scp -q ${FILES} ${TOOLS} "${MISTER}:${REMOTE}/"

# coretypes.ini is a mapping the user edits, so ship the default only when
# there is nothing there yet - same reasoning as tty2oled-user.ini, which is
# absent from FILES entirely.
if ssh "${MISTER}" "[ -e ${REMOTE}/coretypes.ini ]"; then
  say "Keeping the existing coretypes.ini"
else
  say "Installing the default coretypes.ini"
  scp -q coretypes.ini "${MISTER}:${REMOTE}/"
fi

if [ "${WITH_FIRMWARE}" = "yes" ]; then
  BIN="$(ls -t MiSTer_SSD1322_USB/build-out-*/*.merged.bin 2>/dev/null | head -n1)"
  [ -n "${BIN}" ] || { echo "No merged.bin found - build the firmware first." >&2; exit 1; }
  say "Copying firmware: ${BIN}"
  scp -q "${BIN}" "${MISTER}:${REMOTE}/"
fi

if [ "${WITH_INDEX}" = "yes" ]; then
  [ -d titleindex ] && [ -n "$(ls -A titleindex 2>/dev/null)" ] \
    || { echo "No titleindex/ - run ./tools/build-title-index.sh first." >&2; exit 1; }
  say "Copying title index ($(du -sh titleindex | cut -f1), $(ls titleindex | wc -l) cores)"
  ssh "${MISTER}" "mkdir -p ${REMOTE}/titleindex"
  scp -q titleindex/*.idx "${MISTER}:${REMOTE}/titleindex/"
fi

if [ "${WITH_ICONS}" = "yes" ]; then
  # Same path here as on the MiSTer. pics_pri overrides pics, the same way it
  # does for core artwork, so these survive an upstream picture-pack update.
  if ls pics_pri/ICON/*.gsc >/dev/null 2>&1; then
    say "Copying $(ls pics_pri/ICON/*.gsc | wc -l) console icons"
    ssh "${MISTER}" "mkdir -p ${REMOTE}/pics_pri/ICON"
    scp -q pics_pri/ICON/*.gsc "${MISTER}:${REMOTE}/pics_pri/ICON/"
  else
    echo "No pics_pri/ICON/*.gsc - run ./tools/make-icon-stubs.sh first." >&2
    exit 1
  fi
fi

say "Fixing permissions"
ssh "${MISTER}" "
  set -e
  chmod +x ${REMOTE}/tty2oled.sh ${REMOTE}/tty2oled-meta.sh \
           ${REMOTE}/tty2oled-diag.sh ${REMOTE}/flash-mister.sh \
           ${REMOTE}/tty2oled-capture.sh ${REMOTE}/tty2oled-bootimg.sh
  # The init script refuses to parse CRLF, and files can pick it up in transit.
  dos2unix -k -q ${REMOTE}/*.ini 2>/dev/null || true
"

if [ "${DO_FLASH}" = "yes" ]; then
  # No restart of our own here. flash-mister.sh stops the daemon to free the
  # serial port and starts it again afterwards, and that start picks up the
  # scripts copied above - so restarting first would only be undone.
  say "Flashing"
  # -t so esptool's progress output is not buffered into one lump at the end.
  ssh -t "${MISTER}" "${REMOTE}/flash-mister.sh"
else
  say "Restarting the daemon"
  ssh "${MISTER}" "
    ${REMOTE}/S60tty2oled restart ${DAEMON_FDS}
    sleep 1
    if [ -e /run/tty2oled-daemon.pid ] && [ -d /proc/\$(cat /run/tty2oled-daemon.pid) ]; then
      echo \"daemon running, pid \$(cat /run/tty2oled-daemon.pid)\"
    else
      echo 'daemon did not start - see ${DAEMON_LOG}' >&2
      exit 1
    fi
  "
fi

say "Done. Watch it with:  ssh ${MISTER} 'tail -f /tmp/tty2oled'"
