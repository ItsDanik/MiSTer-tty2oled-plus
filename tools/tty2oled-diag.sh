#!/bin/bash
#
# tty2oled metadata diagnostic.
#
# Load a game first, then run this. MiSTer's state files persist, so what it
# reads is exactly what the daemon saw.
#
#   chmod +x /media/fat/tty2oled/tty2oled-diag.sh
#   /media/fat/tty2oled/tty2oled-diag.sh

TTY2OLED_PATH="${TTY2OLED_PATH:-/media/fat/tty2oled}"
. "${TTY2OLED_PATH}/tty2oled-system.ini"
[ -r "${TTY2OLED_PATH}/tty2oled-user.ini" ] && . "${TTY2OLED_PATH}/tty2oled-user.ini"
. "${TTY2OLED_PATH}/tty2oled-meta.sh"

hr() { printf '%s\n' "-------------------------------------------------------------"; }

hr
echo "STATE FILES  (mtime / first line)"
hr
for f in CORENAME RBFNAME STARTPATH FULLPATH CURRENTPATH FILESELECT GAMEID; do
  p="/tmp/${f}"
  if [ -e "${p}" ]; then
    printf '%-12s %s\n' "${f}" "$(stat -c '%y' "${p}" 2>/dev/null)"
    printf '%-12s   value: [%s]\n' "" "$(head -c 300 "${p}" 2>/dev/null | tr '\n' '|')"
  else
    printf '%-12s *** MISSING ***\n' "${f}"
  fi
done

hr
echo "FRESHNESS  (the game is only trusted if FULLPATH is newer than CORENAME)"
hr
if [ ! -e /tmp/FULLPATH ]; then
  echo "FULLPATH does not exist - MiSTer never recorded a loaded game."
elif [ /tmp/FULLPATH -nt /tmp/CORENAME ]; then
  echo "OK: FULLPATH is NEWER than CORENAME - the game is trusted."
else
  echo "PROBLEM: FULLPATH is OLDER than CORENAME."
  echo "The daemon treats this as leftover state and ignores the game."
  echo "If you did just load a game, CORENAME is being rewritten on load and"
  echo "the freshness test is the wrong heuristic for your setup."
fi

hr
echo "MiSTer.ini"
hr
grep -nE '^[[:space:]]*log_file_entry' /media/fat/MiSTer.ini 2>/dev/null \
  || echo "log_file_entry not found - MiSTer will not publish game state at all."

hr
echo "WHAT build_meta MAKES OF IT"
hr
core="$(cat /tmp/CORENAME 2>/dev/null)"
echo "corename: [${core}]"
build_meta "${core}"
echo "KIND   : ${META_KIND}"
echo "GAME   : ${META_GAME:-<not in this version>}"
echo "TITLE  : ${META_TITLE}"
echo "SOURCE : ${META_SOURCE}"
echo "ICON   : ${META_ICON}"
if [ "${#META_FIELDS[@]}" -eq 0 ]; then
  echo "FIELDS : none"
else
  for f in "${META_FIELDS[@]}"; do
    printf 'FIELD  : %s\n' "${f//$'\t'/ = }"
  done
fi

hr
echo "CLASSIFICATION DETAIL"
hr
echo "CORE_STARTPATH: [${CORE_STARTPATH}]"
fs="$(cat /tmp/FILESELECT 2>/dev/null)"
echo "FILESELECT    : [${fs}]  (the daemon only trusts FULLPATH when this is 'selected')"
if [ -n "${fs}" ] && [ "${fs}" != "selected" ]; then
  echo "  -> this is why the game was ignored, if it was."
fi
hr
