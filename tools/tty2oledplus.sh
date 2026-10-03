#!/bin/bash
#
# tty2oled+ in the Scripts menu. Runs ON THE MISTER, as tty2oledplus.
#
# The one entry tty2oled+ puts in /media/fat/Scripts. It opens a menu - arrows
# and one button, so a pad drives it as well as a keyboard - with the
# things a user does with an install:
#
#   Settings         what the display shows    tty2oledplus_settings.sh
#   Update           the newest release        tty2oledplus_update.sh
#   Scrape metadata  descriptions and more     tty2oledplus_scrape.sh
#   Uninstall        remove it all             tty2oledplus_uninstall.sh
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
#   /media/fat/Scripts/tty2oledplus.sh scrape
#
# With fb_terminal=0 the Scripts menu runs this with the OSD showing its
# output and no terminal at all, so there is no menu to draw. It runs the
# update then - the only one of them that needs no questions answered,
# and what the Scripts entry for it did before there was a launcher.

# Overridable for tests/test-installer.sh, which runs this against a fake
# /media/fat.
FAT="${T2OP_FAT:-/media/fat}"
INSTALL="${T2OP_INSTALL:-${FAT}/tty2oledplus}"

say()  { printf '\n==> %s\n' "$1"; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

tool_path() { printf '%s/tty2oledplus_%s.sh' "${INSTALL}" "$1"; }

# The framebuffer screens (tty2oledplus_ui.sh, in the install folder). Where
# there are none - over SSH, or an install from before them - the menu below
# is dialog's and the tools talk in plain text, as they always did.
# shellcheck disable=SC1090,SC1091
[ -r "${T2OP_UI_LIB:-${INSTALL}/tty2oledplus_ui.sh}" ] && . "${T2OP_UI_LIB:-${INSTALL}/tty2oledplus_ui.sh}"
declare -F ui_begin >/dev/null || { ui_begin() { return 1; }; ui_fb() { return 1; }; ui_end() { :; }; }

# Update and uninstall are exec'd, not called: the update replaces this very
# file, and the uninstall removes it, and bash reads a script as it runs it.
# Nothing of this one is needed afterwards - the Scripts menu's own "Press any
# key" is what follows either.
run_tool() {  # run_tool <settings|update|uninstall|scrape> [options]
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
    settings|scrape) bash "${tool}" "$@" ;;
    *)               exec bash "${tool}" "$@" ;;
  esac
}

# The same menu on the framebuffer, and each tool on it too.
#
# Update and Uninstall are still exec'd, for the reason above - but as the
# command of a run screen, which shows what they print and waits for OK. That
# screen is not told to keep the console: it is the last one, and hands the
# console back itself when it is left. It is a copy in /tmp of the utility
# (ui_begin), so the update can replace the installed one under it and the
# uninstall remove it.
fb_menu() {
  local last="settings" tool answer
  trap 'ui_end' EXIT
  while true; do
    ui_menu "tty2oled+" "$(installed_version)" "${last}" \
      settings   "Settings"        "What the display shows, which details and how bright - with the display showing each change as you make it." \
      update     "Update"          "Install the newest release: the scripts, and the display's firmware when it has changed." \
      scrape     "Scrape metadata" "Game descriptions, players, ratings and more, from the gamelist.xml a scraper left in your games folders." \
      bootscreen "Boot screen"     "The picture the display shows at power-up, kept in the display itself. Put a PNG at pics/boot.png and store it from here." \
      uninstall  "Uninstall"       "Remove tty2oled+ from this MiSTer. It asks first, and offers to keep what is yours." \
      || return 0
    last="${UI_OUT}"
    case "${UI_OUT}" in
      settings|scrape) run_tool "${UI_OUT}" ;;
      bootscreen)      run_tool settings --bootscreen ;;
      update)
        tool="$(tool_path update)"
        [ -f "${tool}" ] || { ui_msg "Update" "${tool} is missing, so this install is incomplete. Put it back with the one-line install from the README, over SSH."; continue; }
        # shellcheck disable=SC2086
        exec "${T2OP_FB_BIN}" run --title "Update" --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} -- bash "${tool}" ;;
      uninstall)
        tool="$(tool_path uninstall)"
        [ -f "${tool}" ] || { ui_msg "Uninstall" "${tool} is missing, so this install is incomplete. Update first to put it back."; continue; }
        # It asks on the framebuffer and says what was answered; Cancel is
        # back to this menu with nothing touched.
        answer="$(bash "${tool}" --ask)" || continue
        case "${answer}" in keep) answer="--keep-settings" ;; delete) answer="" ;; *) continue ;; esac
        # shellcheck disable=SC2086
        exec "${T2OP_FB_BIN}" run --title "Uninstall" --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} -- bash "${tool}" --yes ${answer} ;;
    esac
  done
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
    --menu "What would you like to do?" 13 64 4 \
    settings  "Settings - what the display shows" \
    update    "Update - install the newest release" \
    scrape    "Scrape metadata - game descriptions and more" \
    uninstall "Uninstall - remove tty2oled+" 2> "${tmp}"
  rc=$?
  PICKED="$(cat "${tmp}")"
  rm -f "${tmp}"
  return "${rc}"
}

main() {
  case "${1:-}" in
    settings|update|uninstall|scrape) run_tool "$@"; return $? ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    '') ;;
    *) die "Unknown choice '$1' - settings, update, uninstall or scrape." ;;
  esac

  [ -d "${INSTALL}" ] || die "tty2oled+ is not installed in ${INSTALL}."

  # T2OP_UI=fb is the tests', which feed the keys on a pipe.
  if { [ -t 0 ] || [ "${T2OP_UI:-}" = "fb" ]; } && ui_begin; then
    fb_menu
    return 0
  fi

  if [ ! -t 0 ] || [ ! -t 1 ] || ! command -v dialog >/dev/null 2>&1; then
    say "No terminal to draw a menu in, so this runs the update."
    printf '    Set fb_terminal=1 in MiSTer.ini for Settings, Uninstall and Scrape metadata.\n'
    run_tool update
  fi

  while true; do
    pick || { clear; return 0; }
    case "${PICKED}" in
      settings|scrape)   run_tool "${PICKED}" ;;  # and back to this menu
      update|uninstall)  clear; run_tool "${PICKED}" ;;
      *)                 clear; return 0 ;;
    esac
  done
}

main "$@"
