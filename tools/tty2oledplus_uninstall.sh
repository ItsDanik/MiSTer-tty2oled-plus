#!/bin/bash
#
# Remove tty2oled+ from a MiSTer, leaving nothing of it behind. Runs ON THE
# MISTER - it is installed in the install folder it removes, and the Scripts
# menu's one entry, tty2oledplus, runs it as Uninstall. So that removing its
# own folder cannot pull the script out from under bash, it runs from a copy
# in /tmp, which removes itself when it is done.
#
#   --keep-settings    save what is yours - tty2oled-user.ini, coretypes.ini,
#                      pics/boot.png and pics/user - into
#                      /media/fat/tty2oledplus-saved instead of removing it
#   --keep-bootimage   leave a boot image stored on the display alone
#   --dry-run          list what would go, change nothing
#   --yes              do not ask. Without it this asks twice - whether to go
#                      on, and what to do with your own files - through dialog
#                      where there is a screen for it, and refuses to run at
#                      all where it cannot ask
#
# What it removes, in order:
#   - the stored boot screen on the display, so it boots to its built-in logo
#   - the daemon, stopped before anything else so nothing rewrites what we
#     remove and nothing holds the serial port
#   - /media/fat/tty2oledplus - scripts, settings, artwork, title index
#   - the boot hook line in /media/fat/linux/user-startup.sh, and the
#     "# Startup tty2oled+" comment the installer wrote above it
#   - every Scripts entry this put there: the launcher tty2oledplus.sh,
#     tty2oledplus_install.sh, the three entries the launcher replaced in
#     0.6.3b, and the names those had before 0.4.8b
#   - the pid file and the logs in /tmp
#   - the log_file_entry line in MiSTer.ini, if the install was what put it
#     there, restoring whatever was there before
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
# Where "keep mine" puts them: one folder beside the install, not a scatter of
# *.saved files, because what is kept is no longer only two inis - pics/user
# is a folder and boot.png is a picture.
SAVEDIR="${FAT}/tty2oledplus-saved"
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

# --- Asking first ----------------------------------------------------------
# This removes things that cannot be put back, so it asks twice: once whether
# to go on at all, and once what to do with the files that are the user's own
# rather than ours.
#
# Through dialog when there is one, because of what the Scripts menu is: with
# fb_terminal=1 this runs under agetty on tty2, and the input is as often a
# pad as a keyboard - arrows and one button. dialog's yesno and menu are
# exactly that shape, highlight and press A. A typed "y" is not: it needs a
# keyboard, and a pad cannot answer it at all.
#
# Sets CONFIRM_KEEP to yes or no. Returns 1 for cancel, and cancel is the
# default everywhere - the No button, Escape, and a dialog that fails to run.
CONFIRM_KEEP="no"
have_dialog() { [ "${T2OP_NO_DIALOG:-no}" != "yes" ] && command -v dialog >/dev/null 2>&1 && [ -t 0 ]; }

confirm_removal() {
  CONFIRM_KEEP="no"
  if have_dialog; then
    # --defaultno so the highlighted button is the one that changes nothing.
    dialog --clear --title "Uninstall tty2oled+" --defaultno \
      --yesno "This removes tty2oled+ from ${FAT}:

  - the install folder, artwork and title index
  - the display's stored boot image
  - the startup entry and the Scripts menu entries

The display's firmware is left alone.

Are you sure?" 16 66 || { clear; return 1; }

    local out tmp
    tmp="$(mktemp /tmp/tty2oledplus-uninstall.XXXXXX)"
    dialog --clear --title "Your own files" --default-item keep \
      --menu "Keep the files that are yours rather than ours?

Your settings (tty2oled-user.ini, coretypes.ini), your own
banners in pics/user, and your boot.png." 16 66 3 \
      keep   "Keep them - saved to $(basename "${SAVEDIR}")" \
      delete "Remove everything, mine included" \
      cancel "Cancel - change nothing" 2> "${tmp}"
    local rc=$?
    out="$(cat "${tmp}")"; rm -f "${tmp}"
    clear
    [ "${rc}" -eq 0 ] || return 1
    case "${out}" in
      keep)   CONFIRM_KEEP="yes"; return 0 ;;
      delete) CONFIRM_KEEP="no";  return 0 ;;
      *)      return 1 ;;
    esac
  fi

  # No dialog, or nothing to draw in. With fb_terminal=0 the Scripts menu runs
  # this with the OSD showing its output and no terminal at all, so there is
  # no way to ask - and something this destructive must not proceed on
  # silence. --yes is the way to say it outright.
  if [ ! -t 0 ]; then
    printf '    Nothing can be asked here - there is no terminal to ask in.\n'
    printf '    Run it again with --yes, or set fb_terminal=1 in MiSTer.ini\n'
    printf '    so the Scripts menu gives it a screen to draw on.\n'
    return 1
  fi
  printf '    This removes the install, your settings and the boot hook. Type y to go on: '
  local answer; read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) return 1 ;; esac
  printf '    Keep your settings and your own artwork? [y/N]: '
  read -r answer
  case "${answer}" in y|Y|yes|YES) CONFIRM_KEEP="yes" ;; esac
  return 0
}

# Run from a copy in /tmp, never from where it was installed. It lives in the
# folder it removes, and bash reads a script as it runs it - so it steps out
# of the way first, from wherever it was started, and the copy cleans itself
# up on the way out. Not local: the EXIT trap runs after main has returned.
relocate() {
  if [ -n "${T2OP_UNINSTALL_COPY:-}" ]; then
    trap 'rm -f "${T2OP_UNINSTALL_COPY}"' EXIT
    return 0
  fi
  local copy
  copy="$(mktemp /tmp/tty2oledplus_uninstall.XXXXXX)" || die "Could not create a file in /tmp."
  cat "$0" > "${copy}" || { rm -f "${copy}"; die "Could not copy $0 to /tmp."; }
  T2OP_UNINSTALL_COPY="${copy}" exec bash "${copy}" "$@"
}

# In main() and called on the last line, because bash reads a script as it
# runs it.
main() {
  local keep_settings="no" keep_bootimage="no" assume_yes="no"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-settings)  keep_settings="yes"; shift ;;
      --keep-bootimage) keep_bootimage="yes"; shift ;;
      --dry-run)        DRYRUN="yes"; shift ;;
      --yes|-y)         assume_yes="yes"; shift ;;
      -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)                die "unknown option: $1" ;;
    esac
  done

  [ -e "${INSTALL}" ] || [ -e "${FAT}/Scripts/tty2oledplus.sh" ] \
    || [ -e "${FAT}/Scripts/tty2oledplus_update.sh" ] \
    || [ -e "${FAT}/Scripts/update_tty2oledplus.sh" ] \
    || die "tty2oled+ is not installed in ${INSTALL} - nothing to remove."

  say "Removing tty2oled+ from ${FAT}"
  [ "${DRYRUN}" = "yes" ] && note "dry run - nothing will be changed"
  if [ "${assume_yes}" = "no" ] && [ "${DRYRUN}" = "no" ]; then
    confirm_removal || die "Nothing was changed."
    [ "${CONFIRM_KEEP}" = "yes" ] && keep_settings="yes"
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
    # Everything here is the user's own work, not ours: two inis they edited,
    # the banners they drew, and the boot screen they chose. pics/banner,
    # pics/alt and pics/icon are the release's and are not kept - a new
    # install brings them back.
    say "Keeping what is yours"
    local f kept=0
    for f in tty2oled-user.ini coretypes.ini pics/boot.png pics/user; do
      [ -e "${INSTALL}/${f}" ] || continue
      if [ "${DRYRUN}" = "yes" ]; then note "would save ${SAVEDIR}/$(basename "${f}")"
      else
        mkdir -p "${SAVEDIR}" 2>/dev/null
        cp -r "${INSTALL}/${f}" "${SAVEDIR}/" && { note "saved ${SAVEDIR}/$(basename "${f}")"; kept=$((kept + 1)); }
      fi
    done
    if [ "${DRYRUN}" = "no" ]; then
      if [ "${kept}" -gt 0 ]; then
        note "put them back by copying them into ${INSTALL} after installing again."
      else
        note "nothing of yours to keep - no edited settings and no artwork of your own."
      fi
    fi
  fi

  # Before the folder goes: the record of what was done to MiSTer.ini is in it.
  say "Putting MiSTer.ini back"
  restore_misterini

  say "Removing the install"
  gone "${INSTALL}"

  say "Removing the boot hook"
  unhook

  say "Removing the Scripts entries and what was left in /tmp"
  gone "${FAT}/Scripts/tty2oledplus.sh" "${FAT}/Scripts/tty2oledplus_install.sh" \
       "${FAT}/Scripts/tty2oledplus_update.sh" "${FAT}/Scripts/tty2oledplus_settings.sh" \
       "${FAT}/Scripts/tty2oledplus_uninstall.sh" \
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
  return 0
}

relocate "$@"
main "$@"
