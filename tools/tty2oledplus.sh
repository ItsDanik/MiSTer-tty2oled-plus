#!/bin/bash
#
# tty2oled+ in the Scripts menu. Runs ON THE MISTER, as tty2oledplus.
#
# The one entry tty2oled+ puts in /media/fat/Scripts. It opens a menu - arrows
# and one button, so a pad drives it as well as a keyboard - with the three
# things a user does with an install:
#
#   Settings    what the display shows    tty2oledplus_settings.sh
#   Update      the newest release        tty2oledplus_update.sh
#   Uninstall   remove it all             tty2oledplus_uninstall.sh
#
# Those live in the install folder, /media/fat/tty2oledplus, beside
# everything else of ours, so the Scripts menu - which is the user's, and
# shared with everything else they run - carries one line of ours instead of
# three.
#
# Over SSH, name one to go straight there; any options after it are passed on:
#
#   /media/fat/Scripts/tty2oledplus.sh update --no-firmware
#   /media/fat/Scripts/tty2oledplus.sh uninstall --keep-settings
#
# With fb_terminal=0 the Scripts menu runs this with the OSD showing its
# output and no terminal at all, so there is no menu to draw. It runs the
# update then - the only one of the three that needs no questions answered,
# and what the Scripts entry for it did before there was a launcher.

# Overridable for tests/test-installer.sh, which runs this against a fake
# /media/fat.
FAT="${T2OP_FAT:-/media/fat}"
INSTALL="${T2OP_INSTALL:-${FAT}/tty2oledplus}"

say()  { printf '\n==> %s\n' "$1"; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

tool_path() { printf '%s/tty2oledplus_%s.sh' "${INSTALL}" "$1"; }

# Update and uninstall are exec'd, not called: the update replaces this very
# file, and the uninstall removes it, and bash reads a script as it runs it.
# Nothing of this one is needed afterwards - the Scripts menu's own "Press any
# key" is what follows either.
run_tool() {  # run_tool <settings|update|uninstall> [options]
  local name="$1" tool
  shift
  tool="$(tool_path "${name}")"
  if [ ! -f "${tool}" ]; then
    die "${tool} is missing, so this install is incomplete.
    Put it back with the one-line install from the README, over SSH:
      curl -fsSL --cacert /etc/ssl/certs/cacert.pem \\
        https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash"
  fi
  case "${name}" in
    settings) bash "${tool}" "$@" ;;
    *)        exec bash "${tool}" "$@" ;;
  esac
}

installed_version() {
  sed -n 's/^TTY2OLED_VERSION="\([^"]*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini" 2>/dev/null
}

# The same widget, and the same capture, as the settings editor: a --menu
# returns what is highlighted, which is what "arrow and press A" means.
pick() {
  local tmp rc version
  version="$(installed_version)"
  tmp="$(mktemp /tmp/tty2oledplus-dialog.XXXXXX)"
  dialog --clear --title "tty2oled+${version:+ ${version}}" \
    --ok-label "Open" --cancel-label "Exit" \
    --menu "What would you like to do?" 12 60 3 \
    settings  "Settings - what the display shows" \
    update    "Update - install the newest release" \
    uninstall "Uninstall - remove tty2oled+" 2> "${tmp}"
  rc=$?
  PICKED="$(cat "${tmp}")"
  rm -f "${tmp}"
  return "${rc}"
}

main() {
  case "${1:-}" in
    settings|update|uninstall) run_tool "$@"; return $? ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    '') ;;
    *) die "Unknown choice '$1' - settings, update or uninstall." ;;
  esac

  [ -d "${INSTALL}" ] || die "tty2oled+ is not installed in ${INSTALL}."

  if [ ! -t 0 ] || [ ! -t 1 ] || ! command -v dialog >/dev/null 2>&1; then
    say "No terminal to draw a menu in, so this runs the update."
    printf '    Set fb_terminal=1 in MiSTer.ini for Settings and Uninstall.\n'
    run_tool update
  fi

  while true; do
    pick || { clear; return 0; }
    case "${PICKED}" in
      settings)          run_tool settings ;;      # and back to this menu
      update|uninstall)  clear; run_tool "${PICKED}" ;;
      *)                 clear; return 0 ;;
    esac
  done
}

main "$@"
