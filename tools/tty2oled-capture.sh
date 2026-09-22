#!/bin/bash
#
# Record what MiSTer publishes as you load games, so a whole set of systems can
# be diagnosed in one pass instead of one diag run each.
#
# Run it ON THE MISTER, leave it running, then load a game in each core you
# want covered. Ctrl-C when done and send the file it names.
#
#   ssh root@MiSTer.local /media/fat/tty2oledplus/tty2oled-capture.sh
#
# It only reads state; it does not talk to the display and does not disturb the
# running daemon.

TTY2OLED_PATH="${TTY2OLED_PATH:-/media/fat/tty2oledplus}"
OUT="${OUT:-/tmp/tty2oled-capture.txt}"

if [ ! -r "${TTY2OLED_PATH}/tty2oled-system.ini" ]; then
  echo "No tty2oled install at ${TTY2OLED_PATH}." >&2
  echo "This has to run ON THE MISTER. ./tools/deploy-mister.sh puts it there." >&2
  exit 1
fi

# shellcheck disable=SC1090,SC1091
. "${TTY2OLED_PATH}/tty2oled-system.ini"
[ -r "${TTY2OLED_PATH}/tty2oled-user.ini" ] && . "${TTY2OLED_PATH}/tty2oled-user.ini"
# shellcheck disable=SC1090,SC1091
. "${TTY2OLED_PATH}/tty2oled-meta.sh"

FILES="/tmp/CORENAME /tmp/RBFNAME /tmp/STARTPATH /tmp/FULLPATH
       /tmp/CURRENTPATH /tmp/FILESELECT /tmp/GAMEID"

snapshot() {
  local why="${1}" f="" core=""
  {
    echo "============================================================"
    echo "$(date '+%H:%M:%S.%3N')  ${why}"
    echo "------------------------------------------------------------"
    for f in ${FILES}; do
      if [ -e "${f}" ]; then
        printf '%-12s %s  [%s]\n' "${f##*/}" \
          "$(stat -c '%y' "${f}" 2>/dev/null | cut -c12-23)" \
          "$(head -c 200 "${f}" 2>/dev/null | tr '\n' '|')"
      else
        printf '%-12s --missing--\n' "${f##*/}"
      fi
    done

    core="$(cat /tmp/CORENAME 2>/dev/null)"
    build_meta "${core}"
    echo "------------------------------------------------------------"
    printf 'KIND=%s  GAME=%s  SOURCE=%s\n' "${META_KIND}" "${META_GAME}" "${META_SOURCE}"
    printf 'TITLE=[%s]  ICON=[%s]\n' "${META_TITLE}" "${META_ICON}"
    printf 'CORE_STARTPATH=[%s]\n' "${CORE_STARTPATH}"
    printf 'INDEX=[%s]\n' "$(_index_file "${core}" 2>/dev/null || echo none)"
    if [ "${#META_FIELDS[@]}" -eq 0 ]; then
      echo "FIELDS: none"
    else
      for f in "${META_FIELDS[@]}"; do
        printf 'FIELD: %s\n' "${f//$'\t'/ = }"
      done
    fi
    # The two reasons a console core shows no game, spelled out.
    if [ "${META_KIND}" != "console" ] && [ "${META_KIND}" != "arcade" ]; then
      echo ">> NOT a console/arcade core: classify_core said '${META_KIND}'."
      echo ">> Metadata is off for this core, so the artwork stays full-screen."
    elif [ "${META_GAME}" != "yes" ]; then
      echo ">> console core but NO GAME detected - see the selection above."
    fi
  } >> "${OUT}"
}

: > "${OUT}"
{
  echo "tty2oled capture - $(date)"
  echo "Load a game in each core you want covered, then Ctrl-C."
  echo
} >> "${OUT}"

echo "Recording to ${OUT}"
echo "Load a game in each problem core now. Ctrl-C when done."
echo

snapshot "start"
echo "  captured: start"

n=0
watch=""
for f in ${FILES}; do [ -e "${f}" ] && watch="${watch} ${f}"; done
[ -n "${watch}" ] || { echo "None of MiSTer's state files exist - is log_file_entry=1 set?" >&2; exit 1; }

trap 'echo; echo "Done. Send this file:"; echo "  ${OUT}"; echo "  ssh root@MiSTer.local cat ${OUT}"; exit 0' INT TERM

while true; do
  # -t so a file that did not exist when the watch was built still gets picked
  # up, the same reason the daemon polls.
  inotifywait -qq -t 5 -e modify,create,moved_to ${watch} 2>/dev/null
  # Let MiSTer finish writing the rest of the set before reading it.
  sleep 0.4
  n=$((n + 1))
  snapshot "change #${n}"
  printf '  captured: change #%d  (core=%s game=%s)\n' \
    "${n}" "$(cat /tmp/CORENAME 2>/dev/null)" "${META_GAME}"
  watch=""
  for f in ${FILES}; do [ -e "${f}" ] && watch="${watch} ${f}"; done
done
