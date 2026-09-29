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
    PANEL_TTY="${T2OP_PANEL:-}"
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
  # Which port, and how to write to it - the installed tty2oled-port.sh,
  # where there is one yet.
  # shellcheck source=tty2oled-port.sh
  [ -r "${INSTALL}/tty2oled-port.sh" ] && . "${INSTALL}/tty2oled-port.sh"
  declare -F ttynode >/dev/null || ttynode() { TTYNODE="${1}"; TTYNODE_WHY="no tty2oled-port.sh"; TTYNODE_ERR=""; }
  declare -F port_resolve >/dev/null && port_resolve
  [ -c "${TTYDEV}" ] || return 0
  ttynode "${TTYDEV}"                     # Zaparoo probes a port written to
  stty -F "${TTYNODE}" ${BAUDRATE} ${TTYPARAM} 2>/dev/null || return 0
  PANEL_TTY="${TTYNODE}"
  exec 3<"${TTYNODE}" || return 0
  echo "CMDHWINF" > "${TTYNODE}"
  parse_hwinf <&3
  exec 3<&-
  [ -n "${HW_BOARD}" ] && declare -F port_remember >/dev/null && port_remember "${TTYDEV}"
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

# The daemon's "a newer release is out" flag, which an install answers.
# Parsed out of the ini as SLEEPFILE is; the literal for a first install.
update_flag_path() {
  local p=""
  [ -n "${T2OP_UPDATE_FLAG:-}" ] && { printf '%s' "${T2OP_UPDATE_FLAG}"; return; }
  p="$(sed -n 's/^UPDATE_FLAG="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null | tail -n1)"
  printf '%s' "${p:-/tmp/tty2oledplus_update}"
}

# This is the latest release now, so the menu stops saying there is a newer
# one: the flag goes, and so does the notice the display is holding - the
# restarted daemon puts the menu up before it has asked the display anything,
# and a notice still in the display's memory would come up with it.
update_answered() {
  rm -f "$(update_flag_path)"
  # Whether or not the progress screens are wanted (panel_send): this one is
  # not progress, and a stale notice would outlive them.
  [ -n "${PANEL_TTY}" ] && version_atleast "${HW_VERSION}" 0.7.1 \
    && printf 'CMDNOTE,\n' >>"${PANEL_TTY}" 2>/dev/null && sleep 0.05
  return 0
}

installed_version() {
  sed -n 's/^TTY2OLED_VERSION="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null
}

# --- The panel, while this runs ---------------------------------------------
# The daemon puts SELF_UPDATE_TEXT up when it sees this start, and this stops
# it within seconds for the serial port - so from there the display is this
# script's to talk to, and it says what is going on: each step on the status
# line under the label, a warning before the flash (the panel freezes, then
# restarts), and at the end the finish - "Update Complete", or "Update
# Failed" - for at least UPDATE_DONE_SECS before the daemon takes over again.
#
# Only to firmware 0.7.0b or later, which has the status line; to anything
# older a command it does not know is drawn as text. A display flashed from
# older firmware to newer is asked again once it has restarted, and gets the
# finish. The settings are the daemon's, parsed rather than sourced.
PANEL="no"            # the display can show it, and it is wanted
PANEL_TTY=""          # the port, once identify_display has found one
PANEL_DONE_AT=""      # when the finish went up, in milliseconds
PANEL_COLS=51         # the status line: 256 pixels of 5x7

ini_value() {  # ini_value <KEY> - the user's if set, else the system ini's
  local f v="" x
  for f in "${INSTALL}/tty2oled-system.ini" "${INSTALL}/tty2oled-user.ini"; do
    [ -r "${f}" ] || continue
    x="$(sed -n -e "s/^${1}=\"\([^\"]*\)\".*/\1/p" -e "s/^${1}=\([^\"#[:space:]][^#[:space:]]*\).*/\1/p" "${f}" | tail -n1)"
    [ -n "${x}" ] && v="${x}"
  done
  printf '%s' "${v}"
}

version_atleast() {  # version_atleast <have> <want>; upstream's dated versions are not
  local h=() w=() i
  [[ "${1}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)[A-Za-z]*$ ]] || return 1
  h=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  [[ "${2}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  w=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  for i in 0 1 2; do
    [ "$((10#${h[i]}))" -gt "$((10#${w[i]}))" ] && return 0
    [ "$((10#${h[i]}))" -lt "$((10#${w[i]}))" ] && return 1
  done
  return 0
}

ms_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "${t}" ]; then t="${t//[.,]/}"; echo "$(( 10#${t} / 1000 ))"
  else echo "$(( $(date +%s) * 1000 ))"; fi
}

# Wanted, and can the display just identified show it?
panel_can() {
  [ "$(ini_value SELF_UPDATE_SCREEN)" != "no" ] && [ -n "${PANEL_TTY}" ] \
    && [ -n "${HW_BOARD}" ] && [ "${HW_BOARD}" != "esp8266" ] \
    && version_atleast "${HW_VERSION}" 0.7.0
}

panel_send() {
  [ "${PANEL}" = "yes" ] || return 0
  printf '%s\n' "${1}" >>"${PANEL_TTY}" 2>/dev/null
  sleep 0.05
}

# The effect the ini asks for, for a screen that replaces what was there.
panel_effect() {
  local e; e="$(ini_value TRANSITION)"
  [[ "${e}" =~ ^-?[0-9]+$ ]] && printf ',%s' "${e}"
}

panel_open() {
  panel_can || return 0
  PANEL="yes"
  local label; label="$(ini_value SELF_UPDATE_TEXT)"
  label="${label:-Updating TTY2OLED+...}"
  # Out of the metadata view, then the label - the same the daemon sends, so
  # when the daemon put it up already the firmware takes it as a repeat.
  panel_send "CMDMETAOFF"
  panel_send "CMDBUSY,1,${label//,/}$(panel_effect)"
}

panel_step() {  # panel_step <what is happening>
  local s="${1}"
  [ "${#s}" -le "${PANEL_COLS}" ] || s="${s:0:$((PANEL_COLS - 3))}..."
  panel_send "CMDBUSYLINE,${s}"
}

# The finish: the label replaced, the bar left to run off, a line under it.
panel_finish() {  # panel_finish <done|failed|uptodate> <line>
  [ "${PANEL}" = "yes" ] && [ -z "${PANEL_DONE_AT}" ] || return 0
  local secs head
  secs="$(ini_value UPDATE_DONE_SECS)"
  [ "${secs:-3}" -gt 0 ] 2>/dev/null || return 0
  case "${1}" in
    failed)   head="$(ini_value UPDATE_FAILED_TEXT)"; head="${head:-Update Failed}" ;;
    uptodate) head="Up to Date" ;;
    *)        head="$(ini_value UPDATE_DONE_TEXT)"; head="${head:-Update Complete}" ;;
  esac
  panel_send "CMDBUSY,0,${head//,/}$(panel_effect)"
  panel_step "${2}"
  PANEL_DONE_AT="$(ms_now)"
}

# Whatever is left of the finish's minimum time, before the daemon draws.
panel_hold() {
  [ -n "${PANEL_DONE_AT}" ] || return 0
  local secs left
  secs="$(ini_value UPDATE_DONE_SECS)"
  [ "${secs:-3}" -ge 0 ] 2>/dev/null || secs=3
  left=$(( ${secs:-3} * 1000 - ( $(ms_now) - PANEL_DONE_AT ) ))
  PANEL_DONE_AT=""
  [ "${left}" -gt 0 ] && sleep "$(printf '%d.%03d' $((left / 1000)) $((left % 1000)))"
  return 0
}

# After a flash: the display restarts, and is asked again - it may be running
# firmware that can show the finish when the old one could not. A few tries:
# it takes a second or two to boot, and the first line to reach it can be
# garbled, which is what QWERTZ is for (the daemon does the same).
panel_reopen() {
  PANEL="no"
  [ "$(ini_value SELF_UPDATE_SCREEN)" != "no" ] && [ -n "${PANEL_TTY}" ] || return 0
  local tries=0
  [ -n "${T2OP_HWINF_AFTER+set}" ] && T2OP_HWINF="${T2OP_HWINF_AFTER}"
  while [ "${tries}" -lt 6 ]; do
    tries=$((tries + 1))
    [ -n "${T2OP_HWINF+set}" ] || { sleep 1; printf 'QWERTZ\n' >>"${PANEL_TTY}" 2>/dev/null; sleep 0.1; }
    identify_display
    [ -n "${HW_BOARD}" ] && break
  done
  panel_can && PANEL="yes"
  return 0
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
  local rc="$?"
  [ -n "${STAGE:-}" ] && rm -rf "${STAGE}"
  [ "${rc}" -ne 0 ] && panel_finish failed "See the MiSTer's screen for why"
  panel_hold
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
  # The artwork is there when the arcade wheel pack is. pics/ itself says
  # nothing - a fresh install's pics/ holds the icons out of the scripts
  # archive - and neither does pics/banner any more: every install from
  # before the wheels has one, full of the arcade marquees they replaced,
  # and asking about it is why the updater that introduced them could not
  # fetch them. This one can, so an install that reached the wheel release
  # through an older updater gets them on its next Update.
  [ -r "${INSTALL}/pics/arcade/wheels.idx" ] && [ -r "${INSTALL}/pics/arcade/wheels.bin" ] \
    && [ -d "${INSTALL}/pics/banner" ] || pics="yes"

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

  # Asked even with --no-firmware: the answer also says whether the panel can
  # show what this run is doing.
  local flash="no"
  say "Asking the display what it is"
  identify_display
  note "reported: ${HW_BOARD:-no answer}${HW_VERSION:+, firmware ${HW_VERSION}}"
  panel_open
  if [ "${firmware}" = "yes" ]; then
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
    [ -z "${want}" ] && update_answered
    panel_finish uptodate "tty2oled+ ${version} is installed"
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
    case "${a}" in
      tty2oledplus.tar.gz)      panel_step "Downloading tty2oled+ ${version}" ;;
      tty2oledplus-pics.tar.gz) panel_step "Downloading the artwork" ;;
      *.bin)                    panel_step "Downloading the ${board} firmware" ;;
    esac
    fetch "${a}" "${STAGE}/${a}" || die "Could not download ${a}. Nothing was changed."
    verify "${a}"
  done

  # --- Scripts ------------------------------------------------------------
  if [ "${scripts}" = "yes" ]; then
    say "Installing scripts into ${INSTALL}"
    panel_step "Installing the scripts"
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
    panel_step "Installing the artwork"
    # Unpacked beside the install first, then swapped in folder by folder:
    # the release's folders are replaced whole, so a picture a release has
    # dropped - the arcade marquees, pics/alt - goes from the card too,
    # instead of lingering unread in 128KB clusters. pics/user is not in
    # the archive's list of folders to replace, and is never touched.
    local new="${STAGE}/pics-new" d
    mkdir -p "${new}"
    tar -C "${new}" --no-same-owner -xzf "${STAGE}/tty2oledplus-pics.tar.gz" \
      || die "Could not unpack the artwork pack. Nothing was changed."
    mkdir -p "${INSTALL}/pics/user"
    for d in banner arcade; do
      [ -d "${new}/tty2oledplus/pics/${d}" ] || continue
      rm -rf "${INSTALL}/pics/${d}"
      mv "${new}/tty2oledplus/pics/${d}" "${INSTALL}/pics/${d}" \
        || die "Could not install pics/${d}."
    done
    rm -rf "${INSTALL}/pics/alt"
  fi

  # --- Firmware -----------------------------------------------------------
  local flashed="yes"
  if [ "${flash}" = "yes" ]; then
    say "Flashing the ${board} firmware"
    # Last words before the panel freezes: the flash stops the firmware
    # mid-frame, and the new one restarts it on its boot screen.
    panel_step "Flashing firmware - the display will restart"
    cp "${STAGE}/tty2oledplus-${board}.bin" "${INSTALL}/tty2oledplus-${board}.bin"
    # flash-mister.sh identifies the chip itself; the override only matters
    # when it cannot get an answer, and then this run already knows.
    local chip="esp32"
    [ "${board}" = "esp32s3" ] && chip="esp32s3"
    CHIP_OVERRIDE="${chip}" TTY2OLED_PATH="${INSTALL}" \
      "${FLASH}" "${INSTALL}/tty2oledplus-${board}.bin" \
      || { flashed="no"; note "The flash did not complete - the scripts are installed; run this again to retry it."; }
    panel_reopen
  fi

  # Nothing left that can fail: the rest is quick, and runs under the finish.
  if [ "${flashed}" = "yes" ]; then
    # The latest, not a --version picked by hand: that may be an older one.
    [ -z "${want}" ] && update_answered
    panel_finish done "tty2oled+ ${version} installed"
  else
    panel_finish failed "The firmware flash did not complete"
  fi

  # --- Boot hook, daemon, updater -----------------------------------------
  say "Checking the boot hook"
  (
    BOOTHOOK_LIB=yes . "${INSTALL}/tty2oled-boothook.sh"
    boothook "${FAT}/linux/user-startup.sh" "${FAT}/linux/_user-startup.sh" "${INSTALL}/S60tty2oled"
  )

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

  # Last, so the finish is the panel's until it has been up long enough.
  panel_hold
  say "Starting the daemon"
  start_daemon
  sleep 1
  "${INIT}" status || note "It did not start - see ${DAEMON_LOG}"

  say "tty2oled+ ${version} is installed."
}

# Sourced by the tests for parse_hwinf; run otherwise.
[ "${T2OP_LIB:-no}" = "yes" ] || main "$@"
