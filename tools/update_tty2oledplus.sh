#!/bin/bash
#
# Install or update tty2oled+ from its GitHub releases. Runs ON THE MISTER.
#
# First install, over SSH:
#   curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
#     https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/update_tty2oledplus.sh | bash
#
# After that it is in the Scripts menu as update_tty2oledplus, and runs the same
# way from there. Options, when run by hand:
#
#   --version 0.4.1b   that release instead of the newest
#   --board lolin32    when the display cannot say what it is (lolin32,
#                      esp32de or esp32s3 - the name the firmware build uses)
#   --no-firmware      scripts only; leave the display's firmware alone
#   --pics             fetch the artwork pack again even though it is there
#   --force            reinstall and reflash even when already up to date
#
# What it does, in order, and what it never does:
#   - downloads the release and checks every file against SHA256SUMS before
#     touching anything - a failed or tampered download changes nothing
#   - stops the daemon, and starts it again however the run ends
#   - replaces the scripts; installs tty2oled-user.ini and coretypes.ini only
#     when there are none, so your settings survive every update
#   - flashes the firmware for the board the display reports, and only when
#     the display is running a different version
#   - adds the boot hook to /media/fat/linux/user-startup.sh
#   - puts itself in /media/fat/Scripts as update_tty2oledplus.sh
#   - refuses to run at all while upstream tty2oled is installed in
#     /media/fat/tty2oled - tty2oled+ replaces it, the two are not made to run
#     side by side - and never touches that install itself

REPO="ItsDanik/MiSTer-tty2oled-plus"

# Everything overridable is for tests/test-installer.sh, which runs this
# against a fake /media/fat and a release on local disk.
FAT="${T2OP_FAT:-/media/fat}"
RELEASES="${T2OP_URL:-https://github.com/${REPO}/releases}"
INSTALL="${FAT}/tty2oledplus"
INIT="${T2OP_INIT:-${INSTALL}/S60tty2oled}"
FLASH="${T2OP_FLASH:-${INSTALL}/flash-mister.sh}"
CACERT="/etc/ssl/certs/cacert.pem"
DAEMON_LOG="/tmp/tty2oled-daemon.log"

say()  { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

# --- Downloads -------------------------------------------------------------
# MiSTer's curl does not find a CA bundle on its own - every https request
# fails certificate verification - so it is pointed at the one MiSTer ships.
fetch() {  # fetch <asset> <dest>
  local url="${BASE}/$1" ca=()
  [ -r "${CACERT}" ] && ca=(--cacert "${CACERT}")
  curl -fsSL --retry 3 --connect-timeout 15 "${ca[@]}" -o "$2" "${url}"
}

# Every file is checked before any of them is used.
verify() {  # verify <file in STAGE>
  local want got
  want="$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "${STAGE}/SHA256SUMS")"
  [ -n "${want}" ] || die "$1 is not listed in SHA256SUMS - refusing to use it."
  got="$(sha256sum "${STAGE}/$1" | cut -d' ' -f1)"
  [ "${got}" = "${want}" ] || die "$1 does not match its checksum - the download is damaged. Nothing was changed."
}

# --- The display -----------------------------------------------------------
# Read ';'-separated tokens and take the first that names a board. The
# firmware answers CMDHWINF with "HWLOLIN32;<version>;", but it also sends
# "ttyack;" after every command, and any the daemon never read are still
# queued on the port in front of the answer - so the first line is not
# necessarily the answer. Same approach as checkversion in the daemon.
#
# Sets HW_BOARD (lolin32, esp32de, esp32s3, esp8266 or empty) and HW_VERSION.
parse_hwinf() {
  local tok="" tries=0
  HW_BOARD=""; HW_VERSION=""
  while [ "${tries}" -lt 12 ]; do
    tries=$((tries + 1))
    IFS= read -r -t 2 -d ';' tok || break
    tok="${tok//[[:space:]]/}"
    case "${tok}" in
      HW*)
        IFS= read -r -t 2 -d ';' HW_VERSION || true
        HW_VERSION="${HW_VERSION//[[:space:]]/}"
        break ;;
    esac
  done
  case "${tok}" in
    HWLOLIN32) HW_BOARD="lolin32" ;;
    HWESP32DE) HW_BOARD="esp32de" ;;
    HWESP32S3) HW_BOARD="esp32s3" ;;
    HWESP8266) HW_BOARD="esp8266" ;;
    *) HW_VERSION="" ;;
  esac
}

identify_display() {
  HW_BOARD=""; HW_VERSION=""
  # A test states the answer rather than providing a port.
  if [ -n "${T2OP_HWINF+set}" ]; then
    parse_hwinf <<<"${T2OP_HWINF}"
    return 0
  fi
  local TTYDEV="/dev/ttyUSB0" BAUDRATE="115200" TTYPARAM="cs8 raw -parenb -cstopb -hupcl -echo"
  # The user's own ini can move the port or change the speed.
  eval "$(
    for f in "${INSTALL}/tty2oled-system.ini" "${INSTALL}/tty2oled-user.ini"; do
      [ -r "${f}" ] && . "${f}" >/dev/null 2>&1
    done
    printf 'TTYDEV=%q BAUDRATE=%q TTYPARAM=%q\n' "${TTYDEV}" "${BAUDRATE}" "${TTYPARAM}"
  )"
  [ -c "${TTYDEV}" ] || return 0
  stty -F "${TTYDEV}" ${BAUDRATE} ${TTYPARAM} 2>/dev/null || return 0
  exec 3<"${TTYDEV}" || return 0
  echo "CMDHWINF" > "${TTYDEV}"
  parse_hwinf <&3
  exec 3<&-
}

# Upstream's daemon holds the same serial port, and both at once garble the
# display and make flashing fail halfway.
upstream_running() {
  local d
  for d in /proc/[0-9]*; do
    tr '\0' ' ' < "${d}/cmdline" 2>/dev/null | grep -qF "${FAT}/tty2oled/tty2oled.sh" && return 0
  done
  return 1
}

# Upstream installed at all, running or not. Its boot hook would start it
# beside ours on the next reboot, on the same serial port.
upstream_installed() {
  [ -e "${FAT}/tty2oled/tty2oled.sh" ] || [ -e "${FAT}/tty2oled/S60tty2oled" ]
}

installed_version() {
  sed -n 's/^TTY2OLED_VERSION="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null
}

# --- The daemon ------------------------------------------------------------
# Started again on the way out whatever happened, the way flash-mister.sh
# does it - a failed update must never leave the display without its daemon.
DAEMON_WAS_RUNNING="no"
DAEMON_STARTED="no"
start_daemon() {
  [ -x "${INIT}" ] || return 0
  # The init script backgrounds the daemon without detaching it; over SSH it
  # would hold the connection open, so it gets a log file of its own.
  "${INIT}" start </dev/null >>"${DAEMON_LOG}" 2>&1
  DAEMON_STARTED="yes"
}
on_exit() {
  [ -n "${STAGE:-}" ] && rm -rf "${STAGE}"
  if [ "${DAEMON_WAS_RUNNING}" = "yes" ] && [ "${DAEMON_STARTED}" = "no" ]; then
    printf '\n==> Restarting the daemon as it was\n'
    start_daemon
  fi
}

# --- Main ------------------------------------------------------------------
# All in a function, called on the last line. "curl | bash" executes as the
# bytes arrive, so a connection dropped halfway would otherwise run half a
# script; and update_tty2oledplus.sh replaces itself while it runs.
main() {
  local want="" board="" firmware="yes" pics="no" force="no"
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)     want="${2#v}"; shift 2 ;;
      --board)       board="$2"; shift 2 ;;
      --no-firmware) firmware="no"; shift ;;
      --pics)        pics="yes"; shift ;;
      --force)       force="yes"; shift ;;
      -h|--help)     sed -n '2,/^REPO=/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
  case "${board}" in ''|lolin32|esp32de|esp32s3) ;; *) die "--board must be lolin32, esp32de or esp32s3" ;; esac

  for t in curl tar gzip sha256sum; do
    command -v "${t}" >/dev/null 2>&1 || die "${t} is missing - this does not look like a MiSTer."
  done

  if [ -n "${want}" ]; then BASE="${RELEASES}/download/v${want}"
  else BASE="${RELEASES}/latest/download"; fi

  STAGE="$(mktemp -d /tmp/tty2oledplus.XXXXXX)"
  trap on_exit EXIT

  say "Checking ${want:+version ${want} of }tty2oled+"
  fetch VERSION "${STAGE}/VERSION" && fetch SHA256SUMS "${STAGE}/SHA256SUMS" \
    || die "Could not reach the release at ${BASE}. Is the MiSTer online?"
  local version current
  version="$(head -n1 "${STAGE}/VERSION" | tr -d '[:space:]')"
  current="$(installed_version)"
  note "release:   ${version}"
  note "installed: ${current:-nothing}"

  local scripts="yes"
  [ "${current}" = "${version}" ] && [ "${force}" = "no" ] && scripts="no"
  [ -d "${INSTALL}/pics" ] || pics="yes"

  if upstream_installed; then
    die "Upstream tty2oled is installed in ${FAT}/tty2oled. tty2oled+ replaces it
    and the two are not made to run side by side. Remove it first:
      ${FAT}/tty2oled/S60tty2oled stop
      rm -rf ${FAT}/tty2oled ${FAT}/Scripts/update_tty2oled.sh
    Its line in ${FAT}/linux/user-startup.sh does nothing once the folder is
    gone. Then run this again."
  fi

  if upstream_running; then
    die "Upstream tty2oled is running and has the serial port. Stop it first:
      ${FAT}/tty2oled/S60tty2oled stop
    and comment out its line in ${FAT}/linux/user-startup.sh so it does not
    come back at boot. Then run this again."
  fi

  # Stopped before the display is asked anything: the daemon owns the port.
  if [ -x "${INIT}" ] && "${INIT}" status >/dev/null 2>&1; then
    say "Stopping the daemon"
    "${INIT}" stop >/dev/null 2>&1
    DAEMON_WAS_RUNNING="yes"
    sleep 1
  fi

  local flash="no"
  if [ "${firmware}" = "yes" ]; then
    say "Asking the display what it is"
    identify_display
    note "reported: ${HW_BOARD:-no answer}${HW_VERSION:+, firmware ${HW_VERSION}}"
    if [ "${HW_BOARD}" = "esp8266" ]; then
      note "An ESP8266 cannot run tty2oled+ firmware - leaving it alone."
    elif [ -z "${HW_BOARD}" ] && [ -z "${board}" ]; then
      # Guessing would flash the wrong pinout. The display would still take a
      # correct flash afterwards, but it would sit dark until then.
      note "Leaving the firmware alone. If it is not working, say which board"
      note "it is and run this again:   --board lolin32   (or esp32de, esp32s3)"
    else
      board="${board:-${HW_BOARD}}"
      if [ "${HW_VERSION}" = "${version}" ] && [ "${force}" = "no" ]; then
        note "Firmware ${version} is already on the display."
      else
        flash="yes"
      fi
    fi
  fi

  if [ "${scripts}" = "no" ] && [ "${flash}" = "no" ] && [ "${pics}" = "no" ]; then
    say "tty2oled+ ${version} is already installed - nothing to do."
    return 0
  fi

  # --- Download and verify everything before changing anything -----------
  say "Downloading"
  local assets=()
  [ "${scripts}" = "yes" ] && assets+=(tty2oledplus.tar.gz update_tty2oledplus.sh)
  [ "${pics}" = "yes" ] && assets+=(tty2oledplus-pics.tar.gz)
  [ "${flash}" = "yes" ] && assets+=("tty2oledplus-${board}.bin")
  local a
  for a in "${assets[@]}"; do
    note "${a}"
    fetch "${a}" "${STAGE}/${a}" || die "Could not download ${a}. Nothing was changed."
    verify "${a}"
  done

  # --- Scripts ------------------------------------------------------------
  if [ "${scripts}" = "yes" ]; then
    say "Installing scripts into ${INSTALL}"
    tar -C "${STAGE}" --no-same-owner -xzf "${STAGE}/tty2oledplus.tar.gz" \
      || die "Could not unpack the scripts. Nothing was changed."
    mkdir -p "${INSTALL}"
    local src="${STAGE}/tty2oledplus" f
    for f in "${src}"/*; do
      case "$(basename "${f}")" in
        # Yours. Installed when missing, never replaced.
        tty2oled-user.ini|coretypes.ini)
          if [ -e "${INSTALL}/$(basename "${f}")" ]; then
            note "kept your $(basename "${f}")"
            continue
          fi ;;
      esac
      cp -r "${f}" "${INSTALL}/"
    done
    chmod +x "${INSTALL}"/*.sh "${INSTALL}/S60tty2oled"
    # CRLF breaks the init script, and files pick it up on their way through
    # Windows shares.
    command -v dos2unix >/dev/null 2>&1 && dos2unix -k -q "${INSTALL}"/*.ini 2>/dev/null
  fi

  if [ "${pics}" = "yes" ]; then
    say "Installing the artwork pack"
    tar -C "${FAT}" --no-same-owner -xzf "${STAGE}/tty2oledplus-pics.tar.gz" \
      || die "Could not unpack the artwork pack."
  fi

  # --- Firmware -----------------------------------------------------------
  if [ "${flash}" = "yes" ]; then
    say "Flashing the ${board} firmware"
    cp "${STAGE}/tty2oledplus-${board}.bin" "${INSTALL}/tty2oledplus-${board}.bin"
    # flash-mister.sh identifies the chip itself; the override only matters
    # when it cannot get an answer, and then this run already knows.
    local chip="esp32"
    [ "${board}" = "esp32s3" ] && chip="esp32s3"
    CHIP_OVERRIDE="${chip}" TTY2OLED_PATH="${INSTALL}" \
      "${FLASH}" "${INSTALL}/tty2oledplus-${board}.bin" \
      || note "The flash did not complete - the scripts are installed; run this again to retry it."
  fi

  # --- Boot hook, daemon, updater -----------------------------------------
  say "Checking the boot hook"
  (
    BOOTHOOK_LIB=yes . "${INSTALL}/tty2oled-boothook.sh"
    boothook "${FAT}/linux/user-startup.sh" "${FAT}/linux/_user-startup.sh" "${INSTALL}/S60tty2oled"
  )

  say "Starting the daemon"
  start_daemon
  sleep 1
  "${INIT}" status || note "It did not start - see ${DAEMON_LOG}"

  if [ "${scripts}" = "yes" ] && [ -d "${FAT}/Scripts" ]; then
    # By rename, never in place: if this *is* update_tty2oledplus.sh, bash is
    # still reading it, and overwriting the open file would feed it the new
    # script from the old one's byte offset.
    cp "${STAGE}/update_tty2oledplus.sh" "${FAT}/Scripts/.update_tty2oledplus.sh.new"
    chmod +x "${FAT}/Scripts/.update_tty2oledplus.sh.new"
    mv "${FAT}/Scripts/.update_tty2oledplus.sh.new" "${FAT}/Scripts/update_tty2oledplus.sh"
    note "update_tty2oledplus is in the Scripts menu for next time."
  fi

  # The one setting everyone misses. Without it MiSTer never says which game
  # is loaded, and all the display can show is the core.
  if ! grep -qs '^[[:space:]]*log_file_entry[[:space:]]*=[[:space:]]*1' "${FAT}/MiSTer.ini"; then
    say "One more thing"
    note "Add  log_file_entry=1  to ${FAT}/MiSTer.ini and reboot. Without it"
    note "MiSTer does not publish which game is loaded, so only core names show."
  fi

  say "tty2oled+ ${version} is installed."
}

# Sourced by the tests for parse_hwinf; run otherwise.
[ "${T2OP_LIB:-no}" = "yes" ] || main "$@"
