#!/bin/bash
#
# Remove tty2oled+ from a MiSTer, leaving nothing of it behind. Runs ON THE
# MISTER - it is installed as /media/fat/Scripts/tty2oledplus_uninstall.sh and
# appears in the Scripts menu as tty2oledplus_uninstall.
#
#   --keep-settings    save tty2oled-user.ini and coretypes.ini beside the
#                      install as *.saved instead of removing them
#   --keep-bootimage   leave a boot image stored on the display alone
#   --dry-run          list what would go, change nothing
#   --yes              do not ask (the Scripts menu has no keyboard when
#                      fb_terminal=0, so it never asks there anyway)
#
# What it removes, in order:
#   - the stored boot screen on the display, so it boots to its built-in logo
#   - the daemon, stopped before anything else so nothing rewrites what we
#     remove and nothing holds the serial port
#   - /media/fat/tty2oledplus - scripts, settings, artwork, title index
#   - the boot hook line in /media/fat/linux/user-startup.sh, and the
#     "# Startup tty2oled+" comment the installer wrote above it
#   - every Scripts entry this put there: tty2oledplus_update.sh,
#     tty2oledplus_settings.sh, tty2oledplus_install.sh, and the names all of
#     those had before 0.4.8b
#   - the pid file and the logs in /tmp
#   - the log_file_entry line in MiSTer.ini, if the install was what put it
#     there, restoring whatever was there before
#   - itself
#
# What it deliberately leaves:
#   - the firmware on the display. It is the display's own flash, not the
#     MiSTer's, and an ESP32 with no firmware shows nothing at all. Flash
#     upstream's from tty2tft.de if you want the stock display back.
#   - log_file_entry=1 in MiSTer.ini when it was already set before this was
#     installed, or when it has been changed since. It is MiSTer's own setting
#     and other things read that log.
#   - /media/fat/tty2oled, if upstream is installed there. Not ours to touch.

# Overridable for tests/test-installer.sh, which runs this against a fake
# /media/fat with a stand-in init script and no display.
FAT="${T2OP_FAT:-/media/fat}"
INSTALL="${FAT}/tty2oledplus"
INIT="${T2OP_INIT:-${INSTALL}/S60tty2oled}"

say()  { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

DRYRUN="no"
# An unmatched glob comes through as its own text, which -e then rejects.
gone() {  # gone <path>...
  local p
  for p in "$@"; do
    [ -e "${p}" ] || continue
    if [ "${DRYRUN}" = "yes" ]; then note "would remove ${p}"
    else rm -rf "${p}"; note "removed ${p}"; fi
  done
}

# The stored boot image lives in the display's own flash and survives a
# reflash, so removing the scripts alone would leave somebody's artwork on a
# display that no longer has anything to do with this fork.
clear_bootimage() {
  local dev baud param
  # The ini is the only thing that knows which port and what speed.
  dev="${TTYDEV:-}" baud="${BAUDRATE:-}" param="${TTYPARAM:-}"
  if [ -r "${INSTALL}/tty2oled-system.ini" ]; then
    # shellcheck disable=SC1090
    . "${INSTALL}/tty2oled-system.ini" >/dev/null 2>&1
    [ -r "${INSTALL}/tty2oled-user.ini" ] && . "${INSTALL}/tty2oled-user.ini" >/dev/null 2>&1
    dev="${TTYDEV}" baud="${BAUDRATE}" param="${TTYPARAM}"
  fi
  [ -n "${dev}" ] && [ -c "${dev}" ] || { note "no display on ${dev:-/dev/ttyUSB0} - nothing stored to clear"; return; }
  if [ "${DRYRUN}" = "yes" ]; then note "would clear the boot image stored on ${dev}"; return; fi
  # shellcheck disable=SC2086
  stty -F "${dev}" ${baud:-115200} ${param:-cs8 raw -parenb -cstopb -hupcl -echo} 2>/dev/null
  echo "CMDCLRBOOT" > "${dev}" 2>/dev/null \
    && note "cleared the boot image stored on the display" \
    || note "could not reach the display - a stored boot image may remain"
}

# MiSTer.ini, put back the way the install found it. The installer recorded
# what it did in .misterini.state inside the install folder, which is why this
# runs before the folder is removed:
#
#   present  it was already set: leave it alone
#   changed  the old line is in the record, and goes back verbatim
#   added    our line goes, and nothing else
#   created  there was no MiSTer.ini at all; the file goes if it is still only
#            what we wrote, and otherwise just our line does
#
# In every case the current value is checked first: a user who has since set
# log_file_entry themselves keeps what they set.
restore_misterini() {
  local ini="${FAT}/MiSTer.ini" state="${INSTALL}/.misterini.state" tmp action old
  [ -r "${state}" ] || { note "no record of changing MiSTer.ini"; return 0; }
  action="$(sed -n 's/^action=//p' "${state}")"
  old="$(sed -n 's/^line=//p' "${state}")"
  [ -e "${ini}" ] || return 0

  case "${action}" in
    present) note "MiSTer.ini was already set up; leaving it alone"; return 0 ;;
    changed|added|created) ;;
    *) note "unrecognised record of MiSTer.ini; leaving it alone"; return 0 ;;
  esac

  if ! grep -qs '^[[:space:]]*log_file_entry[[:space:]]*=[[:space:]]*1' "${ini}"; then
    note "log_file_entry is no longer ours to put back; leaving ${ini} alone"
    return 0
  fi

  if [ "${DRYRUN}" = "yes" ]; then note "would put ${ini} back as it was"; return 0; fi

  # Created by us and untouched since: the whole file goes.
  if [ "${action}" = "created" ] && [ "$(grep -vc '^[[:space:]]*$' "${ini}")" = "2" ] \
     && grep -qs '^\[MiSTer\]$' "${ini}"; then
    rm -f "${ini}" && note "removed ${ini}, which this install created"
    return 0
  fi

  tmp="${ini}.tty2oled.$$"
  if [ "${action}" = "changed" ] && [ -n "${old}" ]; then
    awk -v old="${old}" '
      !done && $0 ~ /^[[:space:]]*log_file_entry[[:space:]]*=/ { print old; done = 1; next }
      { print }
    ' "${ini}" > "${tmp}" && mv "${tmp}" "${ini}" \
      && note "put the old log_file_entry line back in ${ini}" \
      || { rm -f "${tmp}"; note "could not edit ${ini}"; }
    return 0
  fi

  awk '
    !done && $0 ~ /^[[:space:]]*log_file_entry[[:space:]]*=/ { done = 1; next }
    { print }
  ' "${ini}" > "${tmp}" && mv "${tmp}" "${ini}" \
    && note "removed the log_file_entry line this install added to ${ini}" \
    || { rm -f "${tmp}"; note "could not edit ${ini}"; }
}

# Written by tools/tty2oled-boothook.sh as a comment line followed by the
# hook. The comment goes only when it is that comment directly above that
# line: everything else in this file is somebody else's.
unhook() {
  local f="${FAT}/linux/user-startup.sh" tmp
  [ -f "${f}" ] || return 0
  grep -qF "${INSTALL}/S60tty2oled" "${f}" || { note "no boot hook in ${f}"; return 0; }
  if [ "${DRYRUN}" = "yes" ]; then note "would remove the boot hook from ${f}"; return 0; fi
  tmp="${f}.tty2oled.$$"
  awk -v hook="${INSTALL}/S60tty2oled" '
    # Hold back the comment: it is only dropped if the hook follows it.
    { if (held != "") { if (index($0, hook) == 0) print held; held = "" } }
    $0 == "# Startup tty2oled+" { held = $0; next }
    index($0, hook) > 0 { next }
    { print }
    END { if (held != "") print held }
  ' "${f}" > "${tmp}" || { rm -f "${tmp}"; note "could not rewrite ${f} - remove the tty2oledplus line by hand"; return 1; }
  chmod +x "${tmp}"
  mv "${tmp}" "${f}" && note "removed the boot hook from ${f}"
}

# In main() and called on the last line, because this script deletes itself:
# bash reads a script as it runs it.
main() {
  local keep_settings="no" keep_bootimage="no" assume_yes="no" self
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-settings)  keep_settings="yes"; shift ;;
      --keep-bootimage) keep_bootimage="yes"; shift ;;
      --dry-run)        DRYRUN="yes"; shift ;;
      --yes|-y)         assume_yes="yes"; shift ;;
      -h|--help)        sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)                die "unknown option: $1" ;;
    esac
  done

  [ -e "${INSTALL}" ] || [ -e "${FAT}/Scripts/tty2oledplus_update.sh" ] \
    || [ -e "${FAT}/Scripts/update_tty2oledplus.sh" ] \
    || die "tty2oled+ is not installed in ${INSTALL} - nothing to remove."

  say "Removing tty2oled+ from ${FAT}"
  [ "${DRYRUN}" = "yes" ] && note "dry run - nothing will be changed"
  if [ "${assume_yes}" = "no" ] && [ "${DRYRUN}" = "no" ] && [ -t 0 ]; then
    printf '    This removes the install, your settings and the boot hook. Type y to go on: '
    local answer; read -r answer
    case "${answer}" in y|Y|yes|YES) ;; *) die "Nothing was changed." ;; esac
  fi

  if [ "${keep_bootimage}" = "no" ]; then
    say "Clearing the display's stored boot image"
    clear_bootimage
  fi

  # Before anything is removed: the daemon rewrites its log and holds the port.
  say "Stopping the daemon"
  if [ -x "${INIT}" ]; then
    if [ "${DRYRUN}" = "yes" ]; then note "would run ${INIT} stop"
    else "${INIT}" stop >/dev/null 2>&1; note "stopped"; fi
  else
    note "no init script - nothing to stop"
  fi

  if [ "${keep_settings}" = "yes" ]; then
    say "Keeping your settings"
    local f
    for f in tty2oled-user.ini coretypes.ini; do
      [ -e "${INSTALL}/${f}" ] || continue
      if [ "${DRYRUN}" = "yes" ]; then note "would save ${FAT}/tty2oledplus-${f}.saved"
      else cp "${INSTALL}/${f}" "${FAT}/tty2oledplus-${f}.saved" && note "saved ${FAT}/tty2oledplus-${f}.saved"; fi
    done
  fi

  # Before the folder goes: the record of what was done to MiSTer.ini is in it.
  say "Putting MiSTer.ini back"
  restore_misterini

  say "Removing the install"
  gone "${INSTALL}"

  say "Removing the boot hook"
  unhook

  say "Removing the Scripts entries and what was left in /tmp"
  gone "${FAT}/Scripts/tty2oledplus_update.sh" "${FAT}/Scripts/tty2oledplus_install.sh" \
       "${FAT}/Scripts/tty2oledplus_settings.sh" \
       "${FAT}/Scripts/update_tty2oledplus.sh" \
       "${FAT}/Scripts/uninstall_tty2oledplus.sh" \
       "${FAT}/Scripts/TTY2OLEDplus_Installer.sh"
  # The pid file by the ini's own name where the ini could be read, and by a
  # glob otherwise - no script but S60tty2oled and the ini should know that
  # path, and tests/test-daemon.sh enforces it. The glob is deliberately
  # tty2oledplus*: upstream's pid file in /run is named for upstream, may
  # well be its own, and is not ours to delete. /run is a tmpfs in any case.
  gone ${PIDFILE:+"${PIDFILE}"} /run/tty2oledplus*.pid \
       "${DAEMONLOG:-/tmp/tty2oled-daemon.log}" "${debugfile:-/tmp/tty2oled}" \
       /tmp/tty2oled_sleep

  say "Done."
  note "The firmware stays on the display - it is the display's own flash, and"
  note "an ESP32 with none shows nothing. Flash upstream's if you want it back."
  [ -e "${FAT}/tty2oled" ] && note "Upstream's ${FAT}/tty2oled is left alone - it is not ours."

  # Only the installed copy, in the Scripts menu: a copy run from anywhere
  # else is someone's own file, and deleting it would be a surprise.
  self="$(readlink -f "$0" 2>/dev/null)"
  if [ "${DRYRUN}" = "no" ] && [ "${self}" = "$(readlink -f "${FAT}/Scripts" 2>/dev/null)/tty2oledplus_uninstall.sh" ]; then
    rm -f "${self}" && note "removed ${self}"
  fi
  return 0
}

main "$@"
