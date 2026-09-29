#!/bin/bash
#
# Write a .scummvm entry into each ScummVM game's folder, for frontends that
# list ScummVM games by them (ES-DE, RetroPie, RetroArch's ScummVM core).
#
# Runs on the MiSTer and reads ScummVM's own ini, so only games added in
# ScummVM's launcher get one. From the workstation:
#
#   ssh root@192.168.1.206 'bash -s -- -n' < tools/scummvm-entries.sh   # list
#   ssh root@192.168.1.206 'bash -s' < tools/scummvm-entries.sh         # write
#
# An entry is "<game folder>.scummvm" beside the game's files, holding the
# game id, no newline: "Full Throttle (CD DOS)/Full Throttle (CD DOS).scummvm"
# holds "ft". The id, not the ini's target ("fw-cd-us"): a frontend's ScummVM
# has no such target and detects the game from the id in the entry's folder.
# The folder's name, because a scraper keys its gamelist on the entry's name
# and tty2oled+ looks a ScummVM game up by its folder.
#
# - Where two games would get one name (a folder holding a puzzle pack, a DOS
#   and a Windows version), each is named after ScummVM's description instead,
#   less what exFAT refuses: "Simon the Sorcerer's Puzzle Pack - Jumble (CD
#   Windows English).scummvm". Two versions with one id both hold it; which
#   one a frontend starts is its detector's choice.
# - The game folder is the one under games/ScummVM (a game whose data is in a
#   subfolder gets its entry there, named after the game); elsewhere, the
#   game's own folder.
# - A game ScummVM added twice (same id and description) gets one entry.
# - Never overwrites: an entry holding something else is reported and kept.
#
# Options:
#   -n   list what would be written, write nothing
#
# INI=<scummvm.ini> overrides where ScummVM's ini is read from.

INI="${INI:-/media/fat/ScummVM/.config/scummvm/scummvm.ini}"
dry=""
case "${1:-}" in
  -n) dry=yes ;;
  "") ;;
  *)  echo "usage: ${0##*/} [-n]" >&2; exit 2 ;;
esac
[ -r "${INI}" ] || { echo "No ScummVM ini at ${INI}" >&2; exit 1; }

# exFAT refuses : ? * " < > | \ - and a / would be a folder.
clean() {
  local s="${1}"
  s="${s//: / - }"; s="${s//:/ -}"; s="${s//\// }"
  s="${s//[?*\"<>|\\]/}"
  printf '%s' "${s}"
}

mapfile -t rows < <(awk -F= '
  function out() { if (t != "" && t != "scummvm") print t "|" g "|" p "|" d }
  /^\[/ { out(); t = substr($0, 2, length($0) - 2); g = p = d = ""; next }
  /^gameid=/      { g = substr($0, 8) }
  /^path=/        { p = substr($0, 6) }
  /^description=/ { d = substr($0, 13) }
  END { out() }' "${INI}")

declare -A name count seen dup
for r in "${rows[@]}"; do
  IFS='|' read -r t g p d <<<"${r}"
  [ -n "${p}" ] || continue
  k="${g}|${d}"
  if [ -n "${seen[$k]}" ]; then dup[$t]="${seen[$k]}"; continue; fi
  seen[$k]="${t}"
  p="${p%/}"
  shopt -s nocasematch
  if [[ "${p}" == */games/ScummVM/* ]]; then
    n="${p#*/games/[Ss][Cc][Uu][Mm][Mm][Vv][Mm]/}"; n="${n%%/*}"
  else
    n="${p##*/}"
  fi
  shopt -u nocasematch
  # Not ((count[$n]++)): a name with an apostrophe is not an arithmetic
  # subscript ("Bear Stormin' (DOS)").
  name[$t]="${n}"; count[$n]=$(( ${count[$n]:-0} + 1 ))
done

made=0 same=0 skipped=0
for r in "${rows[@]}"; do
  IFS='|' read -r t g p d <<<"${r}"
  if [ -n "${dup[$t]}" ]; then
    echo "skip ${t}: the same game as ${dup[$t]}"; skipped=$((skipped + 1)); continue
  fi
  if [ -z "${g}" ] || [ -z "${p}" ] || [ ! -d "${p}" ]; then
    echo "skip ${t}: no game id, or no folder at '${p}'"; skipped=$((skipped + 1)); continue
  fi
  n="${name[$t]}"
  [ "${count[$n]}" -gt 1 ] && n="$(clean "${d:-${t}}")"
  f="${p%/}/${n}.scummvm"
  if [ -e "${f}" ]; then
    if [ "$(cat "${f}")" = "${g}" ]; then same=$((same + 1)); continue; fi
    echo "skip ${t}: ${f} holds '$(head -c 64 "${f}")'"; skipped=$((skipped + 1)); continue
  fi
  echo "${g}  ->  ${f}"
  if [ -z "${dry}" ]; then
    printf '%s' "${g}" >"${f}" || { echo "Could not write ${f}" >&2; exit 1; }
  fi
  made=$((made + 1))
done
echo "${made} ${dry:+to be }written, ${same} already there, ${skipped} skipped"
