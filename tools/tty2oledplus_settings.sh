#!/bin/bash
#
# tty2oled+ settings editor. Runs ON THE MISTER, from the install folder: the
# Scripts menu's one entry, tty2oledplus, opens it as Settings.
#
# A dialog front end for tty2oled-user.ini. The settings the display actually
# has - what it shows, which fields, how bright, how it changes picture - are
# picked from menus instead of typed into an ini over SSH, and the daemon is
# restarted so they take effect straight away.
#
#   --no-restart    save, but leave the daemon alone
#   --install DIR   somewhere other than /media/fat/tty2oledplus
#
# Why it edits only tty2oled-user.ini: that file is the user's and is never
# overwritten by an update, while tty2oled-system.ini ships with the release
# and is replaced every time. The system ini is read here only to know what a
# setting's default is - a setting left at its default is not written at all,
# so an install that has never been touched keeps an empty user ini and picks
# up whatever a later release changes its defaults to.
#
# Nothing is written until Save, and Save writes only the keys that differ
# from the default: every other line of the user ini - comments, settings this
# editor does not know about - is left exactly as it was.

REPO_NAME="tty2oled+"

# Overridable for tests/test-settings.sh, which runs this against a fake
# /media/fat with no display and no dialog.
FAT="${T2OP_FAT:-/media/fat}"
INSTALL="${T2OP_INSTALL:-${FAT}/tty2oledplus}"
INIT="${T2OP_INIT:-${INSTALL}/S60tty2oled}"

SYSTEM_INI="${INSTALL}/tty2oled-system.ini"
USER_INI="${INSTALL}/tty2oled-user.ini"

DIALOG_HEIGHT="${T2OP_DIALOG_HEIGHT:-22}"

say()  { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die()  { printf '\n*** %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The settings this editor offers
# ---------------------------------------------------------------------------
# One record per setting: KEY|TYPE|SPEC|LABEL|HELP
#
#   bool   yes/no
#   enum   SPEC is value=label pairs, separated by ';'
#   int    SPEC is "min max", inclusive
#   text   free text; commas and quotes are stripped on the way in
#   list   SPEC is the vocabulary, in the order the checklist offers it
#   prefix SPEC is the key whose value it must be a leading run of
#
# Everything a user chooses is here. What is deliberately not, and why:
#
#   BAUDRATE   the firmware is Serial.begin(115200) and nothing reads a
#              different rate, so the only thing this could do is break the
#              link between the MiSTer and the display
#   TTYPARAM   stty flags, not a choice
#   NAMES_TXT, TITLE_INDEX, TITLE_INDEX_DIR
#              where the installer put things, not settings - editing them
#              points the daemon at files that are not there
#
# The picture-variant and screensaver options that used to be excluded here
# are gone from the release entirely (0.4.10b, 0.4.9b).
CATEGORIES="display console arcade panel transition updates advanced"

cat_label() {
  case "$1" in
    display)    printf 'What the display shows' ;;
    console)    printf 'Console game details' ;;
    arcade)     printf 'Arcade info card' ;;
    panel)      printf 'Brightness and burn-in' ;;
    transition) printf 'Changing picture' ;;
    updates)    printf 'While updates run' ;;
    advanced)   printf 'Connection and troubleshooting' ;;
  esac
}

# The vocabularies. Console fields are what tty2oled-meta.sh can fill in from
# the filename and the title index; arcade fields are the tags an .mra carries.
CONSOLE_FIELDS_ALL="System Region Year Company Genre Developer Format"
ARCADE_FIELDS_ALL="Year Manufacturer Region Orientation Core Author Set MAME Genre Platform Version Players Controls Buttons"

# The transition effects, as tty2oled-system.ini lists them. Kept in step with
# that list by tests/test-settings.sh, which reads the ini's own numbering.
# The ports a MiSTer actually presents. The CP2102 and CH340 boards come up as
# ttyUSB, the S3's native USB as ttyACM; there is never a fifth.
TTYDEV_SPEC="/dev/ttyUSB0=/dev/ttyUSB0 (usual);/dev/ttyUSB1=/dev/ttyUSB1;/dev/ttyACM0=/dev/ttyACM0;/dev/ttyACM1=/dev/ttyACM1"

TRANSITION_SPEC="-2=Fade (the default);-1=A random wipe each time;0=None;1=Left to right;2=Top to bottom;3=Right to left;4=Bottom to top;5=Alternate lines, opposite ways;6=Top half right, bottom half left;7=Four bands, alternating;8=Four quarters, crosswise;9=Particles;10=Diagonal, left to right;11=Slide in, left to right;12=Slide in, top to bottom;13=Slide in, right to left;14=Slide in, bottom to top;15=Top and bottom to the middle;16=Left and right to the middle;17=Middle out to top and bottom;18=Middle out to left and right;19=Warp, middle out to every edge;20=Clockwise sweep;21=Shaft;22=Waterfall;23=Chessboard of 8 squares;30=Fade, sliding left;31=Fade, sliding left fast;32=Fade, sliding right;33=Fade, sliding right fast;34=Fade, sliding up;35=Fade, sliding up fast;36=Fade, sliding down;37=Fade, sliding down fast;38=Fade, sliding a random way;39=Fade, sliding a random way fast"

settings_in() {  # settings_in <category>
  case "$1" in
    display) cat <<'EOS'
SHOW_METADATA|bool||Game details|Off shows only the core's artwork, as a display with no game information does.
USE_NAMES_TXT|bool||Core names from names.txt|Name cores the way your MiSTer menu names them rather than by their internal name.
COMPACT_YEAR_COMPANY|bool||Year and publisher on one row|"1989, Acclaim" on a single row instead of two.
core_bootscreen_time|int|0 10000|Core boot screen (ms)|How long a console core's own artwork is held before the game's details replace it, when the core and the game are loaded together. 0 goes straight to the details.
METADATA_INTERVAL|int|0 600|Arcade: seconds per screen|Artwork, then each page of the info card, then the artwork again - this long on each. 0 never swaps.
ROTATE|bool||Upside down|Turn the whole display 180 degrees, for a panel mounted the other way up.
RANDOMIZE_ALT_BANNERS|bool||Vary the artwork|Where a core has alternative pictures, pick between them at random each time it loads, instead of always showing the same one.
PRIORITIZE_USER_BANNERS|bool||Prefer your own artwork|Look in pics/user before the artwork pack, so a picture you put there replaces the shipped one. Off searches the pack first.
EOS
    ;;
    console) cat <<'EOS'
METADATA_FIELDS|list|CONSOLE_FIELDS_ALL|Fields to show|Which details appear under a console game's title, in this order. Four fit at once; any more take turns every 2.5 seconds.
METADATA_PINNED|list|SELECTED_CONSOLE|Fields that stay put|These stay on screen while the rest take turns underneath. They have to be fields you are showing.
EOS
    ;;
    arcade) cat <<'EOS'
ARCADE_FIELDS|list|ARCADE_FIELDS_ALL|Short fields|Fields whose values are short: they pair up two to a row, four rows to a page.
ARCADE_FIELDS_WIDE|list|ARCADE_FIELDS_ALL|Full-width fields|Fields whose values need a row to themselves - button names, control types.
ARCADE_PINNED|prefix|ARCADE_FIELDS|Row repeated on every page|The top row of the grid, repeated above the full-width pages. It can only be the first of the short fields, so pick how far along it runs.
EOS
    ;;
    panel) cat <<'EOS'
CONTRAST|int|0 255|Brightness|How bright the panel is, 0 to 255.
CONTRAST_FADE_MS|int|0 4000|Brightness fade (ms)|How long any change in brightness takes. 0 jumps.
DIM_AFTER|int|0 3600|Dim after (seconds)|Seconds with nothing new on screen before the panel dims itself. 0 never dims.
DIM_CONTRAST|int|0 255|Dimmed brightness|What it dims to, on the same scale as the brightness above.
DIM_FADE_MS|int|0 10000|Dimming fade (ms)|How long going dim takes. Slow is the point: nobody should notice it happen.
DIM_WAKE|int|-1 255|Waking brightness|What it comes back to. -1 means the brightness set above.
FLIP_MINUTES|int|0 1440|Swap sides every (minutes)|How often the console layout swaps sides, so no part of the panel stays lit. 0 never swaps.
EOS
    ;;
    transition) cat <<'EOS'
TRANSITION|enum|TRANSITION_SPEC|Effect|How one picture replaces the last, on a core change and between the pages of the arcade card.
TRANSITION_FADE_MS|int|0 4000|Fade time (ms)|With the Fade effect: how long each fade takes, out and in.
TRANSITION_BLANK_MS|int|0 4000|Black between (ms)|With the Fade effect: how long the panel stays black in between.
BOOTSCREEN_AS_MENU|bool||Boot screen is the menu picture|The boot screen stays up as the MiSTer menu's picture. Off shows the artwork pack's menu picture instead.
EOS
    ;;
    updates) cat <<'EOS'
UPDATE_ALL_SCREEN|bool||Say so while update_all runs|Show what is happening on the panel instead of leaving the last core's artwork up.
UPDATE_ALL_TEXT|text||What it says|The message shown while update_all is downloading.
SELF_UPDATE_SCREEN|bool||Say so while tty2oled+ updates|The same, for this display's own updater.
SELF_UPDATE_TEXT|text||What that says|The message shown while an Update runs.
UPDATE_ALL_POLL|int|1 60|How often to look (seconds)|How often to check whether update_all is running. Lower notices sooner and costs a little more.
EOS
    ;;
    advanced) cat <<'EOS'
TTYDEV|enum|TTYDEV_SPEC|Serial port|Which port the display is on. Almost always the first. Change this only if the display is not responding and you know it is on another.
debug|bool||Write a debug log|Log everything the daemon does to /tmp/tty2oled. For working out why something is not showing; leave it off otherwise.
METADATA_WARN|bool||Warn about log_file_entry|Say so in the log at startup when MiSTer is not publishing which game is loaded, which is what game details need.
GAME_ROOTS|text|200|Where your games are|Searched in order, separated by spaces, to work out a game's file type. Add a mount point here if you keep games somewhere unusual.
METADATA_POLL|int|1 60|Game check (seconds)|How often to look again for game details MiSTer had not written yet.
SLEEPMODEDELAY|int|0 60|Settling delay (seconds)|After another program hands the display back, how long to wait before drawing - it may still be finishing up.
SLEEP_POLL|int|1 60|Sleep check (seconds)|While another program has the display, how often to look at whether it is finished.
SLEEP_STALE_GRACE|int|0 3600|Take the display back after (seconds)|If a program claimed the display and died without releasing it, how long past its own deadline to wait before taking it back.
EOS
    ;;
  esac
}

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

record_for() {  # record_for <key>
  local c r
  for c in ${CATEGORIES}; do
    while IFS= read -r r; do
      [ "$(field "${r}" 1)" = "$1" ] && { printf '%s' "${r}"; return 0; }
    done < <(settings_in "${c}")
  done
  return 1
}

# ---------------------------------------------------------------------------
# Reading and writing the ini
# ---------------------------------------------------------------------------
# Parsed rather than sourced. An ini is shell and the daemon does source it,
# but this runs as root from a menu: reading a value should not be able to run
# anything, and a half-written user ini should not be able to take the editor
# down with it.
ini_get() {  # ini_get <file> <key> - the last uncommented assignment, unquoted
  local file="$1" key="$2" line
  [ -r "${file}" ] || return 1
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -n1)" || return 1
  [ -n "${line}" ] || return 1
  line="${line#*=}"
  # Strip one layer of quotes, then a trailing comment on an unquoted value.
  case "${line}" in
    \"*\"*) line="${line#\"}"; line="${line%%\"*}" ;;
    \'*\'*) line="${line#\'}"; line="${line%%\'*}" ;;
    *)      line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}" ;;
  esac
  printf '%s' "${line}"
}

# The value the daemon would use: the user's if they have set one, otherwise
# the release's.
default_value() { ini_get "${SYSTEM_INI}" "$1"; }
current_value() {
  local v
  if v="$(ini_get "${USER_INI}" "$1")" && [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
  default_value "$1"
}

# Write one key into the user ini, or remove it when it matches the default.
#
# In place where the key is already there, appended under a header of its own
# where it is not, and every other line kept: the file is the user's, they may
# have commented it or put their own notes in it, and an editor that rewrote
# the whole file would quietly eat all of that.
ini_put() {  # ini_put <file> <key> <value>
  local file="$1" key="$2" value="$3" tmp
  tmp="${file}.t2op.$$"
  if [ -r "${file}" ] && grep -qE "^[[:space:]]*${key}=" "${file}"; then
    awk -v k="${key}" -v v="${value}" '
      $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=\"" v "\""; done = 1 } ; next }
      { print }
    ' "${file}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  else
    [ -r "${file}" ] && cat "${file}" > "${tmp}" || : > "${tmp}"
    if ! grep -q '^# Written by tty2oledplus_settings' "${tmp}" 2>/dev/null; then
      printf '\n# Written by tty2oledplus_settings. Remove a line to go back to\n' >> "${tmp}"
      printf '# whatever tty2oled-system.ini says.\n' >> "${tmp}"
    fi
    printf '%s="%s"\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
}

ini_drop() {  # ini_drop <file> <key>
  local file="$1" key="$2" tmp
  [ -r "${file}" ] || return 0
  grep -qE "^[[:space:]]*${key}=" "${file}" || return 0
  tmp="${file}.t2op.$$"
  grep -vE "^[[:space:]]*${key}=" "${file}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv "${tmp}" "${file}"
}

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------
# A value is only ever what a menu offered or what these accept, because it
# ends up in a file the daemon sources as shell.
sanitize_text() {  # sanitize_text <value> [max] - quotes, backslashes,
  # backticks, $ and control characters out; cut to max, 32 by default.
  local s max="${2:-32}"
  s="$(printf '%s' "$1" | tr -d '"'"'"'\\`$\000-\037')"
  # Bash's own truncation rather than cut, which ends what it prints with a
  # newline - and a newline in the middle of an ini line is a broken ini.
  printf '%s' "${s:0:${max}}"
}

is_int() { case "$1" in ''|*[!0-9-]*) return 1 ;; -*[!0-9]*) return 1 ;; esac; [ "$1" != "-" ]; }

clamp_int() {  # clamp_int <value> <min> <max> - fails on anything but a number
  is_int "$1" || return 1
  if [ "$1" -lt "$2" ]; then printf '%s' "$2"
  elif [ "$1" -gt "$3" ]; then printf '%s' "$3"
  else printf '%s' "$1"; fi
}

# A list keeps the order it already had: the order is the order the fields are
# drawn in, so re-picking the same set must not shuffle the display. Anything
# newly ticked goes on the end, in the vocabulary's own order.
list_merge() {  # list_merge <current> <picked> - both space separated
  local current="$1" picked="$2" out="" w
  for w in ${current}; do
    case " ${picked} " in *" ${w} "*) out="${out}${out:+ }${w}" ;; esac
  done
  for w in ${picked}; do
    case " ${out} " in *" ${w} "*) ;; *) out="${out}${out:+ }${w}" ;; esac
  done
  printf '%s' "${out}"
}

# Drop anything that is no longer in the list it has to be a subset of.
list_intersect() {  # list_intersect <list> <allowed>
  local out="" w
  for w in $1; do
    case " $2 " in *" ${w} "*) out="${out}${out:+ }${w}" ;; esac
  done
  printf '%s' "${out}"
}

# The first <n> words of a list. ARCADE_PINNED is the top row of the grid, so
# it can only be a leading run of ARCADE_FIELDS - a row cannot start halfway
# down the list. Offering the prefixes is how that constraint is kept without
# having to explain it.
list_prefix() {  # list_prefix <list> <n>
  local out="" w i=0
  for w in $1; do
    [ "${i}" -lt "$2" ] || break
    out="${out}${out:+ }${w}"
    i=$((i + 1))
  done
  printf '%s' "${out}"
}

# How the value reads in a menu, rather than how it is stored.
display_value() {  # display_value <record> <value>
  local type spec
  type="$(field "$1" 2)"; spec="$(field "$1" 3)"
  case "${type}" in
    bool)        [ "$2" = "yes" ] && printf 'on' || printf 'off' ;;
    enum)        enum_label "${spec}" "$2" ;;
    list|prefix) [ -n "$2" ] && printf '%s' "$2" || printf '(none)' ;;
    *)           printf '%s' "$2" ;;
  esac
}

enum_label() {  # enum_label <spec var name> <value>
  local spec pair
  spec="$(eval printf '%s' "\"\${$1}\"")"
  local IFS=';'
  for pair in ${spec}; do
    [ "${pair%%=*}" = "$2" ] && { printf '%s' "${pair#*=}"; return 0; }
  done
  printf '%s' "$2"
}

# ---------------------------------------------------------------------------
# dialog
# ---------------------------------------------------------------------------
# The Scripts menu runs this on /dev/tty2 under agetty when fb_terminal is on.
# The terminal is left as update_all leaves it - cursor back, screen reset -
# because a dialog that exits without doing so leaves the menu unreadable.
reset_tty() {
  local t
  t="$(tty 2>/dev/null)" || return 0
  [ "${t}" = "/dev/tty2" ] || return 0
  stty sane 2>/dev/null || true
  printf '\033[?25h'
}

setup_dialog() {
  command -v dialog >/dev/null 2>&1 \
    || die "dialog is not installed on this MiSTer, so there is nothing to draw the menus with.
    Edit ${USER_INI} by hand instead."
  # A dialogrc of our own, in the install folder rather than beside the script:
  # /media/fat/Scripts is the user's, and this is ours to regenerate.
  DIALOGRC="${INSTALL}/.dialogrc"
  if [ ! -f "${DIALOGRC}" ] && [ -w "${INSTALL}" ]; then
    dialog --create-rc "${DIALOGRC}" 2>/dev/null \
      && sed -i -e 's/use_colors = OFF/use_colors = ON/' \
                -e 's/screen_color = (CYAN,BLUE,ON)/screen_color = (CYAN,BLACK,ON)/' \
                "${DIALOGRC}" 2>/dev/null
  fi
  [ -f "${DIALOGRC}" ] && export DIALOGRC
  trap reset_tty EXIT INT TERM HUP
}

# dialog writes what was chosen to stderr and says how it ended in its exit
# code; every caller here needs both, so they go through one place.
DIALOG_OUT=""
DIALOG_RC=0
# Every picker that chooses one thing is a --menu, not a --radiolist.
#
# A radiolist hands back the tag that is already switched on unless the user
# presses Space on the one they want; arrowing down and pressing Enter returns
# the old value and looks for all the world like the editor ignoring the
# change. A menu returns whatever is highlighted, which is what "move with the
# d-pad and press A" means on a MiSTer - and the Scripts menu's framebuffer
# terminal is driven by a pad as often as by a keyboard.
#
# --default-item opens the list on the value in force, so the current setting
# is still visible without a radio dot to mark it.
#
# The one exception is the field lists, which choose several things and so
# cannot be a menu. They get this note instead.
pick_note() {
  printf '\n\nSpace ticks and unticks. Enter when done.'
}

run_dialog() {
  local tmp
  tmp="$(mktemp /tmp/tty2oledplus-dialog.XXXXXX)"
  dialog "$@" 2> "${tmp}"
  DIALOG_RC=$?
  DIALOG_OUT="$(cat "${tmp}")"
  rm -f "${tmp}"
  return "${DIALOG_RC}"
}

# ---------------------------------------------------------------------------
# Editing one setting
# ---------------------------------------------------------------------------
# PENDING holds what has been changed but not saved. Nothing reaches the ini
# until Save, so Escape at any point really does leave the display alone.
declare -A PENDING=()

value_of() {  # value_of <key> - pending if it has been touched, else current
  local key="$1"
  if [ -n "${PENDING[${key}]+set}" ]; then printf '%s' "${PENDING[${key}]}"
  else current_value "${key}"; fi
}

set_value() {  # set_value <key> <value>
  PENDING["$1"]="$2"
  # METADATA_PINNED can only name fields that are being shown, so dropping a
  # field has to drop it from the pinned list too - otherwise the daemon quietly
  # ignores it and the setting reads as something it is not.
  if [ "$1" = "METADATA_FIELDS" ]; then
    PENDING[METADATA_PINNED]="$(list_intersect "$(value_of METADATA_PINNED)" "$2")"
  fi
  if [ "$1" = "ARCADE_FIELDS" ]; then
    PENDING[ARCADE_PINNED]="$(list_prefix "$2" "$(printf '%s' "$(value_of ARCADE_PINNED)" | wc -w)")"
  fi
}

edit_bool() {  # edit_bool <record>
  local key label help cur
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  cur="$(value_of "${key}")"
  # A menu, not a radiolist. See pick_note() below: a radiolist hands back
  # whatever was already switched on unless Space is pressed, so arrowing to
  # "Off" and pressing Enter saved "On".
  run_dialog --clear --title "${label}" --default-item "${cur}" \
    --menu "${help}" 12 70 2 \
    yes "On" \
    no  "Off" || return 1
  [ -n "${DIALOG_OUT}" ] && set_value "${key}" "${DIALOG_OUT}"
}

edit_enum() {  # edit_enum <record>
  local key label help spec cur pair items=()
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  spec="$(eval printf '%s' "\"\${$(field "$1" 3)}\"")"
  cur="$(value_of "${key}")"
  local IFS=';'
  for pair in ${spec}; do
    items+=("${pair%%=*}" "${pair#*=}")
  done
  unset IFS
  run_dialog --clear --title "${label}" --default-item "${cur}" \
    --menu "${help}" "${DIALOG_HEIGHT}" 70 12 "${items[@]}" || return 1
  [ -n "${DIALOG_OUT}" ] && set_value "${key}" "${DIALOG_OUT}"
}

edit_int() {  # edit_int <record>
  local key label help spec min max cur new
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  spec="$(field "$1" 3)"; min="${spec%% *}"; max="${spec##* }"
  cur="$(value_of "${key}")"
  while true; do
    run_dialog --clear --title "${label}" \
      --inputbox "${help}

${min} to ${max}. The default is $(default_value "${key}")." 12 70 "${cur}" || return 1
    new="$(printf '%s' "${DIALOG_OUT}" | tr -d '[:space:]')"
    if is_int "${new}"; then
      set_value "${key}" "$(clamp_int "${new}" "${min}" "${max}")"
      return 0
    fi
    dialog --clear --title "${label}" \
      --msgbox "\"${new}\" is not a number. ${min} to ${max}, please." 8 60
  done
}

edit_text() {  # edit_text <record> - SPEC is the length limit, 32 if empty
  local key label help spec max cur
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  spec="$(field "$1" 3)"; max="${spec:-32}"
  cur="$(value_of "${key}")"
  run_dialog --clear --title "${label}" \
    --inputbox "${help}

Up to ${max} characters; quotes are removed." 12 70 "${cur}" || return 1
  set_value "${key}" "$(sanitize_text "${DIALOG_OUT}" "${max}")"
}

edit_list() {  # edit_list <record>
  local key label help spec vocab cur w items=()
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  spec="$(field "$1" 3)"
  case "${spec}" in
    SELECTED_CONSOLE) vocab="$(value_of METADATA_FIELDS)" ;;
    *)                vocab="$(eval printf '%s' "\"\${${spec}}\"")" ;;
  esac
  cur="$(value_of "${key}")"
  # Already-chosen fields first, in their own order, so the checklist reads in
  # the order the display draws them.
  local ordered="" rest=""
  for w in ${cur}; do
    case " ${vocab} " in *" ${w} "*) ordered="${ordered}${ordered:+ }${w}" ;; esac
  done
  for w in ${vocab}; do
    case " ${ordered} " in *" ${w} "*) ;; *) rest="${rest}${rest:+ }${w}" ;; esac
  done
  for w in ${ordered}; do items+=("${w}" "" on); done
  for w in ${rest};    do items+=("${w}" "" off); done
  [ "${#items[@]}" -gt 0 ] || {
    dialog --clear --title "${label}" \
      --msgbox "There is nothing to choose from yet - pick the fields to show first." 8 60
    return 1
  }
  # The one picker that cannot be a menu: several fields can be on at once.
  # So it is the one that really does need Space, and says so.
  run_dialog --clear --title "${label}" \
    --checklist "${help}$(pick_note)" "${DIALOG_HEIGHT}" 70 10 "${items[@]}" || return 1
  set_value "${key}" "$(list_merge "${cur}" "${DIALOG_OUT}")"
}

edit_prefix() {  # edit_prefix <record>
  local key label help base list n items=() cur
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  base="$(field "$1" 3)"
  list="$(value_of "${base}")"
  cur="$(value_of "${key}")"
  local count n_cur
  count="$(printf '%s' "${list}" | wc -w)"
  n_cur="$(printf '%s' "${cur}" | wc -w)"
  items+=("0" "(none)")
  # Three at most: the card has four rows and the firmware caps pinning one
  # below the row count, since pinning every row would leave nothing to page.
  local most=3
  [ "${count}" -lt "${most}" ] && most="${count}"
  n=1
  while [ "${n}" -le "${most}" ]; do
    items+=("${n}" "$(list_prefix "${list}" "${n}")")
    n=$((n + 1))
  done
  run_dialog --clear --title "${label}" --default-item "${n_cur}" \
    --menu "${help}" "${DIALOG_HEIGHT}" 70 6 "${items[@]}" || return 1
  [ -n "${DIALOG_OUT}" ] && set_value "${key}" "$(list_prefix "${list}" "${DIALOG_OUT}")"
}

edit_setting() {  # edit_setting <record>
  case "$(field "$1" 2)" in
    bool)   edit_bool "$1" ;;
    enum)   edit_enum "$1" ;;
    int)    edit_int "$1" ;;
    text)   edit_text "$1" ;;
    list)   edit_list "$1" ;;
    prefix) edit_prefix "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
changed_count() { printf '%s' "${#PENDING[@]}"; }

category_menu() {  # category_menu <category>
  local cat="$1" r key items=()
  while true; do
    items=()
    while IFS= read -r r; do
      key="$(field "${r}" 1)"
      items+=("${key}" "$(field "${r}" 4): $(display_value "${r}" "$(value_of "${key}")")" \
              "$(field "${r}" 5)")
    done < <(settings_in "${cat}")
    run_dialog --clear --item-help --ok-label "Change" --cancel-label "Back" \
      --title "$(cat_label "${cat}")" \
      --menu "Pick a setting to change." "${DIALOG_HEIGHT}" 74 12 "${items[@]}"
    [ "${DIALOG_RC}" -eq 0 ] || return 0
    r="$(record_for "${DIALOG_OUT}")" && edit_setting "${r}"
  done
}

# ---------------------------------------------------------------------------
# The boot screen
# ---------------------------------------------------------------------------
# The picture the display shows at power-up, before the MiSTer has booted and
# whether or not the SD card is even in. It lives in the ESP32's own flash, so
# putting one there is a transfer over the serial port rather than a file
# copy - which is why it is an action here and not a setting.
#
# The whole interface is a file: drop a PNG at pics/boot.png and pick this.
# The .gsc it is converted to is a build artifact and is removed afterwards;
# the PNG stays, so it survives updates (no release writes into pics/) and can
# be sent again after a reflash.
BOOTPNG="${INSTALL}/pics/boot.png"

# png2gsc.py needs Pillow or ImageMagick on a workstation and has neither
# here, so it carries a PNG reader built on the standard library. That is the
# backend this asks for by name rather than leaving to "auto", so a MiSTer
# that happens to have one of the others still converts the same bytes.
bootimg_convert() {  # bootimg_convert <out.gsc>; prints what went wrong
  local py
  py="$(command -v python3 || command -v python)" || { printf 'no python on this MiSTer'; return 1; }
  "${py}" "${INSTALL}/png2gsc.py" --boot --backend pure --out "$1" "${BOOTPNG}" 2>&1 \
    || return 1
  return 0
}

bootimg_menu() {
  local gsc="${INSTALL}/pics/boot.gsc" out rc
  while true; do
    local stored="unknown"
    out="$("${INSTALL}/tty2oled-bootimg.sh" status 2>/dev/null)"
    case "${out}" in
      *"custom"*) stored="an image of your own" ;;
      *"legacy"*) stored="an older image, shown cropped" ;;
      *"none"*|*"built-in"*) stored="the built-in tty2oled+ logo" ;;
    esac
    local have="no - put a 256x54 PNG at pics/boot.png"
    [ -e "${BOOTPNG}" ] && have="yes - pics/boot.png"

    run_dialog --clear --item-help --ok-label "Do it" --cancel-label "Back" \
      --title "Boot screen" \
      --menu "The picture the display shows at power-up. It is kept in the
display's own flash, so it appears with the MiSTer still booting.

Showing now: ${stored}
Your picture: ${have}" "${DIALOG_HEIGHT}" 74 4 \
      install "Use my pics/boot.png" \
        "Converts it and stores it on the display. 256x54, up to 16 shades of grey; anything else is scaled to fit and centred on black." \
      clear   "Back to the built-in logo" \
        "Forgets the stored image. Your pics/boot.png is left where it is." \
      || return 0

    case "${DIALOG_OUT}" in
      install)
        if [ ! -e "${BOOTPNG}" ]; then
          dialog --clear --title "Boot screen" --msgbox "There is no ${BOOTPNG} to use.

Put a PNG there - 256x54, drawn in up to 16 shades of grey - and
pick this again. Anything else is scaled to fit and centred." 12 68
          continue
        fi
        clear
        printf '\n==> Converting %s\n' "${BOOTPNG}"
        out="$(bootimg_convert "${gsc}")"; rc=$?
        if [ "${rc}" -ne 0 ]; then
          rm -f "${gsc}"
          dialog --clear --title "Boot screen" --msgbox "Could not convert it:

${out}" 12 68
          continue
        fi
        printf '==> Storing it on the display\n'
        # The transfer stops the daemon for the port and starts it again.
        out="$("${INSTALL}/tty2oled-bootimg.sh" set "${gsc}" 2>&1)"; rc=$?
        # The .gsc is only ever a step on the way, so it goes whether the
        # transfer worked or not; the PNG is what the user keeps.
        rm -f "${gsc}"
        if [ "${rc}" -eq 0 ]; then
          dialog --clear --title "Boot screen" --msgbox "Stored. Power the display off and on to see it.

pics/boot.png is still there, so you can send it again
after a reflash." 11 68
        else
          dialog --clear --title "Boot screen" --msgbox "Could not store it:

${out}" 14 68
        fi ;;
      clear)
        dialog --clear --defaultno --title "Boot screen" \
          --yesno "Forget the image stored on the display and go back to
the built-in tty2oled+ logo?

Your pics/boot.png is left where it is." 11 62 || continue
        clear
        out="$("${INSTALL}/tty2oled-bootimg.sh" clear 2>&1)"; rc=$?
        if [ "${rc}" -eq 0 ]; then
          dialog --clear --title "Boot screen" --msgbox "Back to the built-in logo." 7 50
        else
          dialog --clear --title "Boot screen" --msgbox "Could not clear it:

${out}" 14 68
        fi ;;
    esac
  done
}

main_menu() {
  local items=() c
  while true; do
    items=()
    for c in ${CATEGORIES}; do items+=("${c}" "$(cat_label "${c}")" ""); done
    items+=("bootscreen" "Boot screen" \
            "The picture the display shows at power-up. Put a PNG at pics/boot.png and store it on the display from here.")
    items+=("defaults" "Put everything back to the defaults" \
            "Removes every setting this editor manages from your ini, so the release's own values apply again.")
    local extra=()
    [ "$(changed_count)" -gt 0 ] && extra=(--extra-button --extra-label "Save")
    run_dialog --clear --item-help --ok-label "Open" --cancel-label "Exit" \
      "${extra[@]}" \
      --title "${REPO_NAME} settings" \
      --menu "$(changed_count) change(s) not saved yet.
Settings are written to tty2oled-user.ini and take effect when the display restarts." \
      "${DIALOG_HEIGHT}" 74 12 "${items[@]}"
    case "${DIALOG_RC}" in
      0)
        if [ "${DIALOG_OUT}" = "bootscreen" ]; then
          bootimg_menu
        elif [ "${DIALOG_OUT}" = "defaults" ]; then
          dialog --clear --defaultno --title "Back to the defaults" \
            --yesno "Remove every setting this editor manages from your ini?

Anything else in the file is left alone." 10 60 && reset_to_defaults
        else
          category_menu "${DIALOG_OUT}"
        fi ;;
      3) save_changes && return 0 ;;
      *)
        if [ "$(changed_count)" -gt 0 ]; then
          dialog --clear --title "Unsaved changes" \
            --yesno "Save your $(changed_count) change(s) before leaving?" 8 60 \
            && { save_changes; return 0; }
        fi
        return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Saving
# ---------------------------------------------------------------------------
# A setting equal to the release's default is removed rather than written, so
# the user ini stays a list of the things this MiSTer actually does
# differently - and a later release that changes a default is followed.
apply_pending() {
  local key value
  for key in "${!PENDING[@]}"; do
    value="${PENDING[${key}]}"
    if [ "${value}" = "$(default_value "${key}")" ]; then ini_drop "${USER_INI}" "${key}"
    else ini_put "${USER_INI}" "${key}" "${value}" || return 1; fi
  done
  PENDING=()
  sync 2>/dev/null || true
}

reset_to_defaults() {
  local c r
  for c in ${CATEGORIES}; do
    while IFS= read -r r; do ini_drop "${USER_INI}" "$(field "${r}" 1)"; done < <(settings_in "${c}")
  done
  PENDING=()
  sync 2>/dev/null || true
}

restart_daemon() {
  [ -x "${INIT}" ] || return 1
  "${INIT}" restart >/dev/null 2>&1
}

save_changes() {
  local n
  n="$(changed_count)"
  if ! apply_pending; then
    dialog --clear --title "Could not save" \
      --msgbox "Writing ${USER_INI} failed. Nothing was changed." 8 60
    return 1
  fi
  if [ "${RESTART}" = "no" ]; then
    dialog --clear --title "Saved" \
      --msgbox "${n} setting(s) written to tty2oled-user.ini.

The display picks them up next time it starts." 10 60
    return 0
  fi
  dialog --clear --title "Saved" --infobox "Restarting the display..." 5 40
  if restart_daemon; then
    dialog --clear --title "Saved" \
      --msgbox "${n} setting(s) written, and the display restarted with them." 8 60
  else
    dialog --clear --title "Saved" \
      --msgbox "${n} setting(s) written to tty2oled-user.ini.

The display could not be restarted from here - it will pick them up at the
next boot." 11 60
  fi
}

# ---------------------------------------------------------------------------
main() {
  RESTART="yes"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-restart) RESTART="no"; shift ;;
      --install)    INSTALL="$2"; SYSTEM_INI="${INSTALL}/tty2oled-system.ini"
                    USER_INI="${INSTALL}/tty2oled-user.ini"
                    INIT="${INSTALL}/S60tty2oled"; shift 2 ;;
      -h|--help)    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)            die "Unknown option '$1'." ;;
    esac
  done

  [ -d "${INSTALL}" ] || die "${REPO_NAME} is not installed in ${INSTALL}.
    Run tty2oledplus_install from the Scripts menu first."
  [ -r "${SYSTEM_INI}" ] || die "${SYSTEM_INI} is missing, so there are no defaults to read.
    Run tty2oledplus from the Scripts menu and choose Update to put it back."
  # The daemon reads it and this writes it, so a missing one is only missing
  # until the first save; creating it here keeps the two in one place.
  [ -e "${USER_INI}" ] || : > "${USER_INI}"
  [ -w "${USER_INI}" ] || die "${USER_INI} is not writable. Is the SD card read-only?"

  # Not run from a terminal - the Scripts menu with fb_terminal=0 pipes our
  # output to the OSD - and dialog has nothing to draw on.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    say "${REPO_NAME} settings"
    note "This needs a terminal to draw its menus in."
    note "Press F9 on the MiSTer for the console and run it there, or use SSH:"
    note "  ${FAT}/Scripts/tty2oledplus.sh settings"
    note "Or set fb_terminal=1 in MiSTer.ini and run it from the Scripts menu."
    exit 2
  fi

  setup_dialog
  main_menu
  clear
  reset_tty
  exit 0
}

# Sourced by tests/test-settings.sh for the ini and list handling; run otherwise.
[ "${T2OP_SETTINGS_LIB:-no}" = "yes" ] || main "$@"
