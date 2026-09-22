#!/bin/bash
#
# Put the tty2oled+ boot hook at the top of MiSTer's user-startup.sh.
#
# Runs ON THE MISTER, but is never copied there: deploy-mister.sh feeds it over
# ssh on stdin, with REMOTE naming the install folder whose ini to read.
#
#   ssh root@MiSTer.local "REMOTE=/media/fat/tty2oledplus bash -s" \
#       < tools/tty2oled-boothook.sh
#
# It used to be a heredoc inside deploy-mister.sh, which meant the only place it
# ever ran was a real MiSTer's real user-startup.sh. It edits a file the user
# owns, on a machine that is not this one, so it is a separate file now purely
# so tests/test-deploy.sh can run it against fixtures first.

# Upstream's hook, which names upstream's init script. Recognised so that two
# daemons are not left set to start on the same serial port.
UPSTREAM_INIT="/media/fat/tty2oled/S60tty2oled"

# boothook <user-startup.sh> <its template> <our init script> [upstream init]
#
# Matched on the full path, not on the string "tty2oled": a MiSTer that has
# ever had upstream installed already has a line naming the OLD folder, and
# matching loosely would see it, call the job done and never add ours.
#
# Added at the TOP of the file rather than appended. user-startup.sh already
# runs late in the boot, and anything above this line - mounts, network shares,
# other people's scripts - is time the display spends on its boot screen. The
# hook backgrounds the daemon (S60tty2oled start), so putting it first delays
# nothing that follows it.
#
# An existing line of ours is never moved or re-enabled, only reported. It is
# the user's file, and a line further down or commented out may be exactly
# where they want it.
boothook() {
  local userstartup="${1}" template="${2}" initscript="${3}"
  local upstream="${4:-${UPSTREAM_INIT}}" tmp=""

  if [ ! -e "${userstartup}" ]; then
    if [ -e "${template}" ]; then
      cp "${template}" "${userstartup}"
    else
      printf '#!/bin/sh\n' > "${userstartup}"
    fi
    chmod +x "${userstartup}"
    echo "created ${userstartup}"
  fi

  if grep -qF "${initscript}" "${userstartup}"; then
    if ! grep -F "${initscript}" "${userstartup}" | grep -qv '^[[:space:]]*#'; then
      echo "boot hook is commented out in ${userstartup} - left alone, so the"
      echo "  display will not start at boot until that line is uncommented."
    elif head -n 5 "${userstartup}" | grep -qF "${initscript}"; then
      echo "boot hook already at the top of ${userstartup}"
    else
      echo "boot hook present in ${userstartup}, but not at the top."
      echo "  Move the '${initscript}' line up to just under the shebang and the"
      echo "  display starts as early as this file runs. Left alone - it is your file."
    fi
  else
    tmp="${userstartup}.tty2oled.$$"
    {
      if head -n 1 "${userstartup}" | grep -q '^#!'; then
        head -n 1 "${userstartup}"
        echo ""
        echo "# Startup tty2oled+"
        echo "[ -e ${initscript} ] && ${initscript} \$1"
        tail -n +2 "${userstartup}"
      else
        echo "# Startup tty2oled+"
        echo "[ -e ${initscript} ] && ${initscript} \$1"
        echo ""
        cat "${userstartup}"
      fi
    } > "${tmp}"
    chmod +x "${tmp}"
    mv "${tmp}" "${userstartup}"
    echo "added the boot hook at the top of ${userstartup}"
  fi

  # Both hooks active means both daemons start at boot and fight over one
  # serial port. Only a warning: the upstream line is guarded by "[ -e ... ]",
  # so it is harmless once that install has been moved or removed, and whether
  # to keep upstream at all is the user's call.
  if [ -e "${upstream}" ] && grep -F "${upstream}" "${userstartup}" | grep -qv '^[[:space:]]*#'; then
    echo "WARNING: ${userstartup} also starts upstream tty2oled (${upstream})."
    echo "  Both daemons would drive the same serial port. Comment that line out,"
    echo "  or move the upstream install away, before rebooting."
  fi
  return 0
}

# The tests source this with BOOTHOOK_LIB=yes to get the function without
# running it against a real /media/fat.
if [ "${BOOTHOOK_LIB:-no}" != "yes" ]; then
  set -e
  . "${REMOTE:?REMOTE must name the install folder}/tty2oled-system.ini"
  boothook "${USERSTARTUP}" "${USERSTARTUPTPL}" "${INITSCRIPT}"
fi
