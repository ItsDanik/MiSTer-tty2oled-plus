#!/bin/bash
#
# tty2oled metadata diagnostic.
#
# Load a game first, then run this. MiSTer's state files persist, so what it
# reads is exactly what the daemon saw.
#
#   chmod +x /media/fat/tty2oledplus/tty2oled-diag.sh
#   /media/fat/tty2oledplus/tty2oled-diag.sh

TTY2OLED_PATH="${TTY2OLED_PATH:-/media/fat/tty2oledplus}"

# This reads MiSTer's /tmp state files, so it is only meaningful on the MiSTer.
# Run from the repo on a workstation it used to print a screenful of MISSING
# and a build_meta that was never sourced, which looks like a broken MiSTer
# rather than a script in the wrong place.
if [ ! -r "${TTY2OLED_PATH}/tty2oled-system.ini" ]; then
  echo "No tty2oled install at ${TTY2OLED_PATH}." >&2
  echo >&2
  echo "This has to run ON THE MISTER - it reads the state files in its /tmp." >&2
  echo "From your workstation:" >&2
  echo "    ssh root@MiSTer.local ${TTY2OLED_PATH}/tty2oled-diag.sh" >&2
  echo >&2
  echo "(./tools/deploy-mister.sh puts it there.)" >&2
  exit 1
fi

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
echo "FRESHNESS  (leftover state is ignored: the selection must post-date the core)"
hr
# build_meta calls the selection stale only when BOTH files predate CORENAME,
# so report both rather than FULLPATH alone.
if [ ! -e /tmp/FULLPATH ] && [ ! -e /tmp/CURRENTPATH ]; then
  echo "Neither FULLPATH nor CURRENTPATH exists - MiSTer recorded no selection."
else
  for f in CURRENTPATH FULLPATH; do
    if [ ! -e "/tmp/${f}" ]; then
      printf '%-12s missing\n' "${f}"
    elif [ "/tmp/${f}" -nt /tmp/CORENAME ]; then
      printf '%-12s NEWER than CORENAME - fresh\n' "${f}"
    else
      printf '%-12s older than CORENAME - stale\n' "${f}"
    fi
  done
  if [ ! /tmp/CURRENTPATH -nt /tmp/CORENAME ] && [ ! /tmp/FULLPATH -nt /tmp/CORENAME ]; then
    echo
    echo "Both are stale, so the selection is ignored. That is correct for a core"
    echo "just launched from the menu. If you DID just load a game, CORENAME is"
    echo "being rewritten after the load and the freshness test is wrong here."
  fi
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
echo "SETTINGS IN FORCE"
hr
echo "system ini : ${TTY2OLED_PATH}/tty2oled-system.ini   (shipped, overwritten on deploy)"
if [ -r "${TTY2OLED_PATH}/tty2oled-user.ini" ]; then
  echo "user ini   : ${TTY2OLED_PATH}/tty2oled-user.ini   ($(grep -cvE '^[[:space:]]*(#|$)' "${TTY2OLED_PATH}/tty2oled-user.ini") setting(s), read second, wins)"
else
  echo "user ini   : none - create it to override anything below"
fi
echo
# Both inis are already sourced, so these are the values actually in use.
for v in SHOW_METADATA METADATA_INTERVAL METADATA_FIELDS METADATA_PINNED \
         ARCADE_FIELDS ARCADE_FIELDS_WIDE ARCADE_PINNED \
         COMPACT_YEAR_COMPANY METADATA_POLL USE_NAMES_TXT CONTRAST \
         DIM_AFTER DIM_CONTRAST DIM_WAKE CONTRAST_FADE_MS FLIP_MINUTES SCREENSAVER; do
  eval "val=\${${v}:-<unset>}"
  # Mark anything the user ini overrides, so it is obvious which file to edit.
  src="system"
  if [ -r "${TTY2OLED_PATH}/tty2oled-user.ini" ] &&
     grep -qE "^[[:space:]]*${v}=" "${TTY2OLED_PATH}/tty2oled-user.ini"; then
    src="USER"
  fi
  printf '  %-22s %-34s [%s]\n' "${v}" "${val}" "${src}"
done
echo
echo "To change one, put it in the USER ini and restart - never edit the system"
echo "one, a deploy overwrites it:"
echo "    echo 'DIM_AFTER=\"60\"' >> ${TTY2OLED_PATH}/tty2oled-user.ini"
echo "    ${TTY2OLED_PATH}/S60tty2oled restart"

hr
echo "TITLE INDEX"
hr
idx="${TITLE_INDEX_DIR:-${TTY2OLED_PATH}/titleindex}/${core}.idx"
if [ -r "${idx}" ]; then
  printf '%-14s %s (%s games)\n' "index" "${idx}" "$(wc -l < "${idx}")"
else
  printf '%-14s none for core %s - build it with tools/build-title-index.sh\n' "index" "[${core}]"
fi
read_gameid
printf '%-14s [%s]\n' "GAMEID CRC32" "${GAME_CRC32}"
if [ -n "${GAME_CRC32}" ] && [ -r "${idx}" ]; then
  if lookup_crc "${GAME_CRC32}" "${core}"; then
    echo "  HIT: ${IDX_TITLE} | ${IDX_REGION} | ${IDX_YEAR} | ${IDX_PUBLISHER} | ${IDX_GENRE} | ${IDX_DEVELOPER}"
  else
    echo "  CRC MISS: this CRC32 is not in the index."
    echo "  MiSTer and No-Intro are hashing different bytes - usually a header"
    echo "  counted by one and not the other. The name fallback covers it:"
    clean_romname "$(cat /tmp/CURRENTPATH 2>/dev/null)"
    if lookup_name "${ROM_TITLE}" "${ROM_REGION}" "${core}"; then
      echo "  NAME HIT: ${IDX_TITLE} | ${IDX_REGION} | ${IDX_YEAR} | ${IDX_PUBLISHER} | ${IDX_GENRE} | ${IDX_DEVELOPER}"
    else
      echo "  NAME MISS too: [${ROM_TITLE}] is not in ${idx##*/} either."
      echo "  The filename title and its fields still display."
    fi
  fi
fi

# GAMEID outlives its game, so say whether this one belongs to the loaded game.
if [ -e /tmp/GAMEID ] && [ -e /tmp/CURRENTPATH ]; then
  if [ /tmp/CURRENTPATH -nt /tmp/GAMEID ]; then
    echo "  NOTE: GAMEID is OLDER than the selection - it is the previous"
    echo "  game's CRC and is ignored until MiSTer writes the real one."
  fi
fi

hr
echo "CLASSIFICATION DETAIL"
hr
echo "CORE_STARTPATH: [${CORE_STARTPATH}]"
fs="$(cat /tmp/FILESELECT 2>/dev/null)"
echo "FILESELECT    : [${fs}]  (the daemon only trusts a selection when this is 'selected')"
cp_="$(cat /tmp/CURRENTPATH 2>/dev/null)"
fp_="$(cat /tmp/FULLPATH 2>/dev/null)"
ref="${cp_:-${fp_}}"
echo "romref        : [${ref}]"
if [ "${META_GAME}" != "yes" ] && [ "${META_KIND}" = "console" ]; then
  echo "  -> no game. Reason:"
  [ -z "${ref}" ] && echo "     nothing selected"
  [ -n "${fs}" ] && [ "${fs}" != "selected" ] \
    && echo "     FILESELECT is '${fs}', not 'selected' (browsing, not loading)"
  case "${ref,,}" in
    *.rbf|*.mra) echo "     the selection is the core file itself, not a game" ;;
  esac
  [ -n "${ref}" ] && [ -n "${CORE_STARTPATH}" ] \
    && [ "${ref##*/}" = "${CORE_STARTPATH##*/}" ] \
    && echo "     the selection matches STARTPATH - it is the core, not a game"
fi
hr
