#!/bin/bash
#
# Push tty2oled+ from this working copy to the MiSTer over SSH.
#
# Runs on your workstation, from anywhere - it finds the repository from its
# own path. No git, no Claude Code and no Samba share needed on the MiSTer -
# just SSH.
#
#   ./tools/deploy-mister.sh                  # scripts only, restart the daemon
#   ./tools/deploy-mister.sh --firmware       # also copy the newest merged.bin
#   ./tools/deploy-mister.sh --firmware --flash   # ...and flash it
#   ./tools/deploy-mister.sh --index          # also copy titleindex/*.idx
#   ./tools/deploy-mister.sh --icons          # also copy pics_pri/ICON/*.gsc
#   ./tools/deploy-mister.sh --pics           # also copy the pics/ artwork pack
#   ./tools/deploy-mister.sh --all            # scripts, index, icons and artwork
#   ./tools/deploy-mister.sh --dry-run ...    # check and list, touch nothing
#
# Host defaults to root@MiSTer.local; override with MISTER=root@192.168.1.50.
#
# Set up key auth once and it stops asking for a password:
#   ssh-copy-id root@MiSTer.local
# Without it you are asked once per deploy, not once per step: every ssh and
# scp below shares one connection.

set -eu

# From anywhere, not just the repo root. Every path below is relative to it.
cd "$(dirname "${0}")/.."

MISTER="${MISTER:-root@MiSTer.local}"
REMOTE="${REMOTE:-/media/fat/tty2oledplus}"

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
WITH_PICS="no"
DRY_RUN="no"
for arg in "$@"; do
  case "${arg}" in
    --firmware) WITH_FIRMWARE="yes" ;;
    --flash)    WITH_FIRMWARE="yes"; DO_FLASH="yes" ;;
    --index)    WITH_INDEX="yes" ;;
    --icons)    WITH_ICONS="yes" ;;
    --pics)     WITH_PICS="yes" ;;
    --all)      WITH_INDEX="yes"; WITH_ICONS="yes"; WITH_PICS="yes" ;;
    --dry-run)  DRY_RUN="yes" ;;
    -h|--help)  sed -n '2,/^set -eu/p' "${0}" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$1"; }
die() { echo "deploy: $1" >&2; exit 1; }

[ -f tty2oled.sh ] && [ -f tty2oled-meta.sh ] \
  || die "$(pwd) does not look like the tty2oled+ repository."

# The file lists are shared with the release package; see tools/manifest.sh.
. tools/manifest.sh
FILES="${MANIFEST_FILES}"
TOOLS="${MANIFEST_TOOLS}"
# Fed to the MiSTer on stdin, see "Checking the boot hook". Copied as well, as
# one of TOOLS, so an install from either route carries it.
BOOTHOOK="tools/tty2oled-boothook.sh"

# ---------------------------------------------------------------------------
# Everything that can be checked here is checked before the MiSTer is touched.
# These checks used to sit beside the copies they guard, so "--index" with no
# index built got as far as copying new scripts, then exited - before the
# restart, leaving the old daemon running over new files on disk.
# ---------------------------------------------------------------------------
NEED="ssh scp"
[ "${WITH_PICS}" = "yes" ] && NEED="${NEED} tar"
for tool in ${NEED}; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is not installed on this machine."
done

for f in ${FILES} ${TOOLS} ${BOOTHOOK} ${MANIFEST_MENU} ${MANIFEST_DEFAULTS}; do
  [ -f "${f}" ] || die "${f} is missing from the working copy."
done

BIN=""
if [ "${WITH_FIRMWARE}" = "yes" ]; then
  BIN="$(ls -t MiSTer_SSD1322_USB/build-out-*/*.merged.bin 2>/dev/null | head -n1 || true)"
  [ -n "${BIN}" ] || die "no merged.bin found - build the firmware first:
  ./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32"
fi
if [ "${WITH_INDEX}" = "yes" ]; then
  ls titleindex/*.idx >/dev/null 2>&1 \
    || die "no titleindex/*.idx - run ./tools/build-title-index.sh first."
fi
if [ "${WITH_ICONS}" = "yes" ]; then
  ls pics_pri/ICON/*.gsc >/dev/null 2>&1 \
    || die "no pics_pri/ICON/*.gsc - draw one and convert it with ./tools/png2gsc.py."
fi
if [ "${WITH_PICS}" = "yes" ]; then
  [ -d pics ] || die "no pics/ directory here - nothing to copy."
fi

if [ "${DRY_RUN}" = "yes" ]; then
  say "Dry run - nothing will be copied to ${MISTER}:${REMOTE}"
  for f in ${FILES} ${TOOLS}; do echo "  copy     ${f}"; done
  for f in ${MANIFEST_MENU}; do echo "  copy     ${f} -> /media/fat/Scripts/"; done
  for f in ${MANIFEST_DEFAULTS}; do echo "  if absent ${f}"; done
  [ -n "${BIN}" ]                 && echo "  copy     ${BIN}"
  [ "${WITH_INDEX}" = "yes" ]     && echo "  copy     titleindex/ ($(ls titleindex/*.idx | wc -l | tr -d ' ') cores)"
  [ "${WITH_ICONS}" = "yes" ]     && echo "  copy     pics_pri/ICON/ ($(ls pics_pri/ICON/*.gsc | wc -l | tr -d ' ') icons)"
  [ "${WITH_PICS}" = "yes" ]      && echo "  copy     pics/ ($(find pics -type f | wc -l | tr -d ' ') files)"
  echo "  run      ${BOOTHOOK}"
  if [ "${DO_FLASH}" = "yes" ]; then echo "  flash    then restart the daemon"
  else echo "  restart  the daemon"; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# One SSH connection for the whole deploy. Every ssh and scp below would
# otherwise open its own - a TCP handshake and a key exchange each, and on a
# workstation without ssh-copy-id done yet, a password prompt each: seven or
# eight of them per deploy. The first call opens a master connection and the
# rest ride on it.
# ---------------------------------------------------------------------------
CTL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tty2oled-deploy.XXXXXX")"
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=${CTL_DIR}/%C"
          -o ControlPersist=60 -o ConnectTimeout=10)
cleanup() {
  command ssh "${SSH_OPTS[@]}" -O exit "${MISTER}" >/dev/null 2>&1 || true
  rm -rf "${CTL_DIR}"
}
trap cleanup EXIT
ssh() { command ssh "${SSH_OPTS[@]}" "$@"; }
scp() { command scp "${SSH_OPTS[@]}" "$@"; }

say "Connecting to ${MISTER}"
ssh "${MISTER}" true || die "cannot reach ${MISTER}.
  If the name does not resolve, give the address:  MISTER=root@192.168.1.50 $0
  If it asks for a password every time:            ssh-copy-id ${MISTER}"

# Upstream installed beside us would be started by its own boot hook on the
# same serial port, and the init script refuses to start ours while it is
# there - so a deploy would copy everything and then fail to start. Stop here
# instead, before anything is copied.
UPSTREAM_DIR="/media/fat/tty2oled"
if ssh "${MISTER}" "[ -e ${UPSTREAM_DIR}/tty2oled.sh ] || [ -e ${UPSTREAM_DIR}/S60tty2oled ]"; then
  die "upstream tty2oled is installed on ${MISTER} in ${UPSTREAM_DIR}.
  tty2oled+ replaces it; the two are not made to run side by side. Remove it:
    ssh ${MISTER} '${UPSTREAM_DIR}/S60tty2oled stop; rm -rf ${UPSTREAM_DIR} /media/fat/Scripts/update_tty2oled.sh'"
fi

say "Copying scripts to ${MISTER}:${REMOTE}"
# The folder is this fork's own, so on a first deploy there is nothing there
# to copy into yet.
ssh "${MISTER}" "mkdir -p ${REMOTE}"
# shellcheck disable=SC2086
scp -q ${FILES} ${TOOLS} "${MISTER}:${REMOTE}/"

# The menu scripts go to BOTH places, which is not a belt-and-braces choice
# but the only arrangement that survives a daemon restart.
#
# /media/fat/Scripts is where a user looks for them, and where the uninstaller
# has to live to outlive the folder it removes. But place_menu_scripts in
# S60tty2oled copies them from the install folder into Scripts on every start,
# cmp first - which is how a MiSTer updated by an installer older than these
# names still ends up with them in its menu. Copy only into Scripts, as this
# did, and the next daemon start finds the install folder's older copy
# different and puts *that* back: a deploy silently reverted its own menu
# scripts to whatever a release had last left behind. The release does copy
# them into the install folder (make-release.sh packs them there), so only the
# deploy was ever wrong, and only the copy in the menu.
# shellcheck disable=SC2086
scp -q ${MANIFEST_MENU} "${MISTER}:${REMOTE}/"
# shellcheck disable=SC2086
ssh "${MISTER}" "mkdir -p /media/fat/Scripts"
# shellcheck disable=SC2086
scp -q ${MANIFEST_MENU} "${MISTER}:/media/fat/Scripts/"

# The files the user edits - their settings and the core-type mapping - go
# over only when the MiSTer has none, so a deploy never undoes an edit. On a
# first deploy that includes tty2oled-user.ini, which the daemon sources and
# used to find missing.
for f in ${MANIFEST_DEFAULTS}; do
  if ssh "${MISTER}" "[ -e ${REMOTE}/${f} ]"; then
    say "Keeping the existing ${f}"
  else
    say "Installing the default ${f}"
    scp -q "${f}" "${MISTER}:${REMOTE}/"
  fi
done

if [ -n "${BIN}" ]; then
  say "Copying firmware: ${BIN}"
  scp -q "${BIN}" "${MISTER}:${REMOTE}/"
fi

if [ "${WITH_INDEX}" = "yes" ]; then
  say "Copying title index ($(du -sh titleindex | cut -f1), $(ls titleindex/*.idx | wc -l | tr -d ' ') cores)"
  ssh "${MISTER}" "mkdir -p ${REMOTE}/titleindex"
  scp -q titleindex/*.idx "${MISTER}:${REMOTE}/titleindex/"
fi

if [ "${WITH_ICONS}" = "yes" ]; then
  # Same path here as on the MiSTer. pics_pri overrides pics, the same way it
  # does for core artwork, so these survive an upstream picture-pack update.
  say "Copying $(ls pics_pri/ICON/*.gsc | wc -l | tr -d ' ') console icons"
  ssh "${MISTER}" "mkdir -p ${REMOTE}/pics_pri/ICON"
  scp -q pics_pri/ICON/*.gsc "${MISTER}:${REMOTE}/pics_pri/ICON/"
fi

if [ "${WITH_PICS}" = "yes" ]; then
  # The core artwork pack - what CMDCOR actually puts on screen. Big and it
  # never changes with the scripts, so it moves only when asked for, like the
  # index and the icons.
  #
  # tar over ssh rather than scp: 2322 small files through scp is 2322 round
  # trips, and /media/fat is mounted sync,dirsync so each one waits on the SD
  # card. One stream is the difference between minutes and seconds.
  #
  # --owner/--group/--numeric-owner on the sending side and --no-same-owner on
  # the receiving one, because /media/fat is exFAT: it has no ownership to
  # restore, so root unpacking a stream that names uid 1000 gets "Cannot change
  # ownership ... Operation not permitted" once per file. The files land
  # correctly regardless - exFAT takes its modes from the mount's fmask/dmask -
  # but tar then exits non-zero, and under `set -e` that would abort the deploy
  # after the copy rather than before it.
  #
  # -z because a .gsc is hex text: 87MB of artwork is about 12MB compressed,
  # and the MiSTer's CPU unpacks it faster than the network delivers the
  # difference. It also shortens the window in which a dropped connection can
  # leave a half-written file behind.
  say "Copying the artwork pack ($(find pics -type f | wc -l | tr -d ' ') files, $(du -sh pics | cut -f1))"
  tar --owner=0 --group=0 --numeric-owner -czf - pics \
    | ssh "${MISTER}" "tar -C ${REMOTE} --no-same-owner -xzf -"
fi

say "Fixing permissions"
ssh "${MISTER}" "
  set -e
  chmod +x ${REMOTE}/tty2oled.sh ${REMOTE}/tty2oled-meta.sh \
           ${REMOTE}/S60tty2oled ${REMOTE}/tty2oled-read.sh \
           ${REMOTE}/tty2oled-diag.sh ${REMOTE}/flash-mister.sh \
           ${REMOTE}/tty2oled-capture.sh ${REMOTE}/tty2oled-bootimg.sh
  # The init script refuses to parse CRLF, and files can pick it up in transit.
  dos2unix -k -q ${REMOTE}/*.ini 2>/dev/null || true
"

# The boot hook. Upstream's update script used to add this line, and it is not
# part of this fork - so the deploy is what makes sure the daemon comes back
# after a reboot. The script runs remotely off stdin, so the MiSTer gets it
# verbatim and only REMOTE crosses over; tests/test-deploy.sh runs the same
# file against fixtures.
say "Checking the boot hook"
ssh "${MISTER}" "REMOTE='${REMOTE}' bash -s" < "${BOOTHOOK}"

if [ "${DO_FLASH}" = "yes" ]; then
  # No restart of our own here. flash-mister.sh stops the daemon to free the
  # serial port and starts it again afterwards, and that start picks up the
  # scripts copied above - so restarting first would only be undone.
  say "Flashing"
  # -t so esptool's progress output is not buffered into one lump at the end.
  ssh -t "${MISTER}" "${REMOTE}/flash-mister.sh"
else
  say "Restarting the daemon"
  # "status" rather than reading a pid file here: which file, and what makes a
  # pid in it ours, is the init script's business. This used to check the path
  # by hand, and went on checking the old one after the init script moved.
  ssh "${MISTER}" "
    ${REMOTE}/S60tty2oled restart ${DAEMON_FDS}
    sleep 1
    ${REMOTE}/S60tty2oled status || { echo 'see ${DAEMON_LOG}' >&2; exit 1; }
  "
fi

say "Done. Watch it with:  ssh ${MISTER} 'tail -f /tmp/tty2oled'"
