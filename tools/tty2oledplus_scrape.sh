#!/bin/bash
#
# tty2oled+ Scrape metadata. Runs ON THE MISTER, from the install folder: the
# launcher's "Scrape metadata" opens it.
#
# Imports the gamelist.xml a scraper - Skraper, ES-DE, Batocera, Skyscraper -
# left in each system's own games folder, games/NES/gamelist.xml, and keeps
# players, rating, release date, series and a description for every game in
# it, for the display. No account, no network.
#
# This is the dialog front end: which systems. tty2oledplus_scrape.py does the
# work, and can be run on its own over SSH:
#
#   /media/fat/tty2oledplus/tty2oledplus_scrape.py --systems NES,SNES
#
# Only systems with a console icon are offered: the description page is part
# of the console layout, which is what the icons are for.

# Overridable for tests.
FAT="${T2OP_FAT:-/media/fat}"
INSTALL="${T2OP_INSTALL:-${FAT}/tty2oledplus}"
SCRAPER="${INSTALL}/tty2oledplus_scrape.py"
SUMMARY="/tmp/tty2oledplus-scrape.summary"

die() { printf '\n*** %s\n' "$1" >&2; exit 1; }

[ -d "${INSTALL}" ] || die "tty2oled+ is not installed in ${INSTALL}."
[ -r "${INSTALL}/tty2oledplus_settings.sh" ] || die "${INSTALL}/tty2oledplus_settings.sh is missing.
    Run tty2oledplus from the Scripts menu and choose Update to put it back."

# The settings editor's dialog wrapper, as a library - one copy of it, so this
# looks and behaves like the rest of the menus.
T2OP_SETTINGS_LIB=yes T2OP_INSTALL="${INSTALL}" . "${INSTALL}/tty2oledplus_settings.sh"

SELECTION="${INSTALL}/scraped/.systems"
PY=""

# The systems the importer offers - key, tab, label - and the ones ticked last
# time, or all of them the first time round.
declare -a KEYS=() LABELS=()
load_systems() {
  local k l
  KEYS=(); LABELS=()
  while IFS=$'\t' read -r k l; do
    [ -n "${k}" ] || continue
    KEYS+=("${k}"); LABELS+=("${l}")
  done < <("${PY}" "${SCRAPER}" --install "${INSTALL}" --list-systems 2>/dev/null)
}

# CHECKED is a space-separated set of keys.
CHECKED=""
is_checked() { case " ${CHECKED} " in *" $1 "*) return 0 ;; esac; return 1; }

pick_systems() {  # sets CHECKED to what was ticked; fails on Back
  local i items state
  if [ -r "${SELECTION}" ]; then CHECKED="$(cat "${SELECTION}")"
  else CHECKED="${KEYS[*]}"; fi
  while true; do
    items=()
    for i in "${!KEYS[@]}"; do
      state=off; is_checked "${KEYS[$i]}" && state=on
      items+=("${KEYS[$i]}" "${LABELS[$i]}" "${state}")
    done
    # Select all and Select none are buttons rather than entries in the list:
    # an entry would be ticked and unticked like a system and mean something
    # else entirely. A pad moves to a button with left and right.
    run_dialog --clear --title "Scrape metadata" \
      --ok-label "Import" --extra-button --extra-label "Select all" \
      --help-button --help-label "Select none" --cancel-label "Back" \
      --checklist "Which systems to import? Each needs a gamelist.xml in its own
games folder - games/NES/gamelist.xml - as Skraper, ES-DE and
Batocera write it. What it says replaces what was there.$(pick_note)" \
      "${DIALOG_HEIGHT}" 72 14 "${items[@]}"
    case "${DIALOG_RC}" in
      0)
        CHECKED="$(printf '%s' "${DIALOG_OUT}" | tr -d '"')"
        [ -n "${CHECKED// /}" ] && return 0
        dialog --clear --title "Scrape metadata" --msgbox "Tick at least one system - or Back." 7 50 ;;
      3) CHECKED="${KEYS[*]}" ;;       # Select all
      2) CHECKED="" ;;                 # Select none
      *) return 1 ;;
    esac
  done
}

main() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf '\n==> Scrape metadata\n'
    printf '    This needs a terminal to draw its menus in. Over SSH, run the\n'
    printf '    importer itself:  %s --systems NES,SNES\n' "${SCRAPER}"
    exit 2
  fi
  PY="$(command -v python3 || command -v python)" || die "There is no python on this MiSTer."
  [ -r "${SCRAPER}" ] || die "${SCRAPER} is missing.
    Run tty2oledplus from the Scripts menu and choose Update to put it back."

  setup_dialog

  load_systems
  if [ "${#KEYS[@]}" -eq 0 ]; then
    dialog --clear --title "Scrape metadata" \
      --msgbox "There are no console icons in ${INSTALL}/pics/icon, so there is no
system with a description page to import for. Update tty2oled+ to put them back." 9 72
    clear; return 0
  fi

  pick_systems || { clear; return 0; }
  mkdir -p "$(dirname "${SELECTION}")" && printf '%s\n' "${CHECKED}" > "${SELECTION}"

  clear
  rm -f "${SUMMARY}"
  "${PY}" "${SCRAPER}" --install "${INSTALL}" \
    --systems "$(printf '%s' "${CHECKED}" | tr -s ' ' ',')" --summary "${SUMMARY}"

  local text="Nothing to report."
  [ -s "${SUMMARY}" ] && text="$(cat "${SUMMARY}")"
  dialog --clear --title "Scrape metadata: done" --no-collapse --msgbox "${text}

The display uses what was imported from the next game you load." "${DIALOG_HEIGHT}" 76
  rm -f "${SUMMARY}"
  clear
  reset_tty
  return 0
}

main "$@"
