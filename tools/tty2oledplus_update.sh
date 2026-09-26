#!/bin/bash
#
# Install or update tty2oled+ from its GitHub releases. Runs ON THE MISTER.
#
# First install, over SSH:
#   curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
#     https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash
#
# After that it lives in the install folder, and the Scripts menu's one entry,
# tty2oledplus, runs it as Update. Options, when run by hand:
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
#   - sets log_file_entry=1 in MiSTer.ini, inside its [MiSTer] section, and
#     records what was there so the uninstaller can put it back
#   - adds the boot hook to /media/fat/linux/user-startup.sh
#   - puts the launcher in /media/fat/Scripts as tty2oledplus.sh - the one
#     entry of ours there - with this, the settings editor and the uninstaller
#     in the install folder for it to run, and removes the separate entries
#     those had before 0.6.3b once the launcher is there
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

# Has something else claimed the display?
#
# /tmp/tty2oled_sleep is a mutex on the serial port, not a preference: the
# daemon honours it by not writing at all, and MiSTer SAM takes it for the
# whole of an attract session because its own module drives the panel directly.
# Our daemon stepping aside is not enough - this script asks the display its
# version and may then flash it, and a flash while something else is mid-write
# is the one failure here that needs a USB cable and a workstation to undo.
#
# Deliberately not silent and not a wait: whoever holds it is a program the
# user started, so the user is the one who can stop it.
#
# Parsed out of the installed ini rather than sourced - this runs as root from
# a menu, and reading a path should not be able to run anything - and rather
# than hardcoded, because a user who moved SLEEPFILE would otherwise have this
# watching a file nothing writes. The literal is the fallback for a first
# install, where there is no ini yet.
sleepfile_path() {
  local p=""
  p="$(sed -n 's/^SLEEPFILE="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null | tail -n1)"
  printf '%s' "${p:-/tmp/tty2oled_sleep}"
}

display_claimed() {
  [ -f "$(sleepfile_path)" ]
}

installed_version() {
  sed -n 's/^TTY2OLED_VERSION="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null
}

# --- MiSTer.ini ------------------------------------------------------------
# log_file_entry=1 is what makes MiSTer publish which game is loaded. Without
# it the display can only ever show the core, which is the whole point of this
# fork - so the install sets it, and records what it found so the uninstaller
# can put it back exactly as it was.
#
# It has to go *inside* the [MiSTer] section. MiSTer.ini carries per-core
# sections after it ([NES], [Genesis], ...), so a line appended to the end of
# the file would belong to whichever of those came last and do nothing.
MISTERINI="${FAT}/MiSTer.ini"
INI_STATE="${INSTALL}/.misterini.state"

ensure_log_file_entry() {
  local tmp="${MISTERINI}.tty2oledplus.$$"

  # Recorded once, on the run that changed it. A later update finds the
  # setting already at 1 - because we set it - and must not overwrite the
  # record with "it was already like that".
  if [ -e "${INI_STATE}" ]; then
    note "MiSTer.ini was set up by an earlier install; leaving it alone."
    return 0
  fi

  if [ ! -e "${MISTERINI}" ]; then
    printf '[MiSTer]\nlog_file_entry=1\n' > "${MISTERINI}" || {
      note "Could not create ${MISTERINI} - set log_file_entry=1 by hand."; return 0; }
    printf 'action=created\n' > "${INI_STATE}"
    note "created ${MISTERINI} with log_file_entry=1"
    note "Reboot for it to take effect."
    return 0
  fi

  if grep -qs '^[[:space:]]*log_file_entry[[:space:]]*=[[:space:]]*1' "${MISTERINI}"; then
    printf 'action=present\n' > "${INI_STATE}"
    note "log_file_entry=1 is already set."
    return 0
  fi

  # Set to something else - 0, usually - rather than missing: the value
  # changes and the line, comment and all, is kept for the uninstaller.
  if grep -qs '^[[:space:]]*log_file_entry[[:space:]]*=' "${MISTERINI}"; then
    local old
    old="$(grep -m1 '^[[:space:]]*log_file_entry[[:space:]]*=' "${MISTERINI}")"
    sed 's/^\([[:space:]]*\)log_file_entry[[:space:]]*=[[:space:]]*[^[:space:];#]*/\1log_file_entry=1/' \
      "${MISTERINI}" > "${tmp}" && mv "${tmp}" "${MISTERINI}" || {
        rm -f "${tmp}"; note "Could not edit ${MISTERINI} - set log_file_entry=1 by hand."; return 0; }
    { printf 'action=changed\n'; printf 'line=%s\n' "${old}"; } > "${INI_STATE}"
    note "set log_file_entry=1 (was: ${old# })"
    note "Reboot for it to take effect."
    return 0
  fi

  # Missing: add it as the first line of the [MiSTer] section.
  awk '
    BEGIN { added = 0 }
    { print }
    !added && tolower($0) ~ /^[[:space:]]*\[mister\][[:space:]]*$/ {
      print "log_file_entry=1"; added = 1
    }
    END { if (!added) { print "[MiSTer]"; print "log_file_entry=1" } }
  ' "${MISTERINI}" > "${tmp}" && mv "${tmp}" "${MISTERINI}" || {
      rm -f "${tmp}"; note "Could not edit ${MISTERINI} - add log_file_entry=1 by hand."; return 0; }
  printf 'action=added\n' > "${INI_STATE}"
  note "added log_file_entry=1 to ${MISTERINI}"
  note "Reboot for it to take effect."
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
# script; and tty2oledplus_update.sh replaces itself while it runs.
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
  # Either layout counts as "the artwork is there". pics/ itself does not:
  # 0.5.8b split it into banner/alt/icon/user, and an install that predates
  # that has a pics/ with the old pics/GSC inside it - which S60tty2oled
  # renames into the new folders on its next start, locally, without fetching
  # 80MB again. Asking about pics/ alone would skip a fresh install whose
  # pics/ holds nothing but the icons out of the scripts archive.
  [ -d "${INSTALL}/pics/banner" ] || [ -d "${INSTALL}/pics/GSC" ] || pics="yes"

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

  if display_claimed; then
    die "Something else has the display: $(sleepfile_path) exists.
    MiSTer SAM does this for as long as an attract session runs - it drives the
    panel itself - and this update asks the display its version and may reflash
    it, which must not happen while another program is writing to the port.
    Stop it first (for SAM, exit it from the Scripts menu), then run this again.
    If nothing is using the display, the file was left behind and removing it is
    safe:
      rm $(sleepfile_path)"
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
  [ "${scripts}" = "yes" ] && assets+=(tty2oledplus.tar.gz)
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
        # Run from the launcher, this is the file bash is reading: copied
        # over in place, bash would go on reading the new script from the old
        # one's byte offset. So it goes in by rename, below.
        tty2oledplus_update.sh) continue ;;
      esac
      cp -r "${f}" "${INSTALL}/"
    done
    cp "${src}/tty2oledplus_update.sh" "${INSTALL}/.tty2oledplus_update.sh.new" \
      && mv "${INSTALL}/.tty2oledplus_update.sh.new" "${INSTALL}/tty2oledplus_update.sh" \
      || die "Could not install the updater into ${INSTALL}."
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
    # By rename, never in place: the launcher exec's the updater, so it is not
    # being read any more - but a copy of this run from the Scripts folder by
    # an older name may be.
    cp "${STAGE}/tty2oledplus/tty2oledplus.sh" "${FAT}/Scripts/.tty2oledplus.sh.new"
    chmod +x "${FAT}/Scripts/.tty2oledplus.sh.new"
    mv "${FAT}/Scripts/.tty2oledplus.sh.new" "${FAT}/Scripts/tty2oledplus.sh"

    # The entries the launcher replaced, and the names those had before
    # 0.4.8b. Swept only now, with the launcher beside them, so an interrupted
    # run never leaves a menu with none. Deleting a script bash is running is
    # safe: it keeps reading the file it opened. An update applied by an
    # installer older than the launcher puts its own tty2oledplus_update.sh
    # back instead; S60tty2oled sweeps that on its next start.
    local legacy
    for legacy in tty2oledplus_update.sh tty2oledplus_settings.sh \
                  tty2oledplus_uninstall.sh update_tty2oledplus.sh \
                  uninstall_tty2oledplus.sh TTY2OLEDplus_Installer.sh; do
      [ -e "${FAT}/Scripts/${legacy}" ] && rm -f "${FAT}/Scripts/${legacy}"
    done

    note "the Scripts menu now has one entry, tty2oledplus: Settings to change"
    note "what the display shows, Update for the next release, and Uninstall."
  fi

  say "Checking MiSTer.ini"
  ensure_log_file_entry

  say "tty2oled+ ${version} is installed."
}

# Sourced by the tests for parse_hwinf; run otherwise.
[ "${T2OP_LIB:-no}" = "yes" ] || main "$@"
