#!/bin/bash
#
# tty2oled+ settings editor. Runs ON THE MISTER, from the Scripts menu as
# tty2oledplus_settings.
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
# Only the fork's own settings are here. The inherited picture-variant and
# screensaver options, the serial device and the game roots are deliberately
# left to the ini: they are either set once at install time or not something
# a menu makes safer.
CATEGORIES="display console arcade panel transition updates"

cat_label() {
  case "$1" in
    display)    printf 'What the display shows' ;;
    console)    printf 'Console game details' ;;
    arcade)     printf 'Arcade info card' ;;
    panel)      printf 'Brightness and burn-in' ;;
    transition) printf 'Changing picture' ;;
    updates)    printf 'While updates run' ;;
  esac
}

# The vocabularies. Console fields are what tty2oled-meta.sh can fill in from
# the filename and the title index; arcade fields are the tags an .mra carries.
CONSOLE_FIELDS_ALL="System Region Year Company Genre Developer Format"
ARCADE_FIELDS_ALL="Year Manufacturer Region Orientation Core Author Set MAME Genre Platform Version Players Controls Buttons"

# The transition effects, as tty2oled-system.ini lists them. Kept in step with
# that list by tests/test-settings.sh, which reads the ini's own numbering.
TRANSITION_SPEC="-2=Fade (the default);-1=A random wipe each time;0=None;1=Left to right;2=Top to bottom;3=Right to left;4=Bottom to top;5=Alternate lines, opposite ways;6=Top half right, bottom half left;7=Four bands, alternating;8=Four quarters, crosswise;9=Particles;10=Diagonal, left to right;11=Slide in, left to right;12=Slide in, top to bottom;13=Slide in, right to left;14=Slide in, bottom to top;15=Top and bottom to the middle;16=Left and right to the middle;17=Middle out to top and bottom;18=Middle out to left and right;19=Warp, middle out to every edge;20=Clockwise sweep;21=Shaft;22=Waterfall;23=Chessboard of 8 squares"

settings_in() {  # settings_in <category>
  case "$1" in
    display) cat <<'EOS'
SHOW_METADATA|bool||Game details|Off shows only the core's artwork, as a display with no game information does.
SHOW_CONSOLE_SPLIT|bool||Console split layout|The console layout: text on one side, the system's icon on the other.
USE_NAMES_TXT|bool||Core names from names.txt|Name cores the way your MiSTer menu names them rather than by their internal name.
COMPACT_YEAR_COMPANY|bool||Year and publisher on one row|"1989, Acclaim" on a single row instead of two.
METADATA_INTERVAL|int|0 600|Arcade: seconds per screen|Artwork, then each page of the info card, then the artwork again - this long on each. 0 never swaps.
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
SELF_UPDATE_TEXT|text||What that says|The message shown while tty2oledplus_update runs.
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
sanitize_text() {  # quotes, backslashes, backticks, $ and control characters
  local s
  s="$(printf '%s' "$1" | tr -d '"'"'"'\\`$\000-\037')"
  # Bash's own truncation rather than cut, which ends what it prints with a
  # newline - and a newline in the middle of an ini line is a broken ini.
  printf '%s' "${s:0:32}"
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
  local on_state off_state
  [ "${cur}" = "yes" ] && { on_state=on; off_state=off; } || { on_state=off; off_state=on; }
  run_dialog --clear --title "${label}" \
    --radiolist "${help}" 12 70 2 \
    yes "On"  "${on_state}" \
    no  "Off" "${off_state}" || return 1
  [ -n "${DIALOG_OUT}" ] && set_value "${key}" "${DIALOG_OUT}"
}

edit_enum() {  # edit_enum <record>
  local key label help spec cur pair items=()
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  spec="$(eval printf '%s' "\"\${$(field "$1" 3)}\"")"
  cur="$(value_of "${key}")"
  local IFS=';'
  for pair in ${spec}; do
    items+=("${pair%%=*}" "${pair#*=}" "$([ "${pair%%=*}" = "${cur}" ] && echo on || echo off)")
  done
  unset IFS
  run_dialog --clear --title "${label}" \
    --radiolist "${help}" "${DIALOG_HEIGHT}" 70 12 "${items[@]}" || return 1
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

edit_text() {  # edit_text <record>
  local key label help cur
  key="$(field "$1" 1)"; label="$(field "$1" 4)"; help="$(field "$1" 5)"
  cur="$(value_of "${key}")"
  run_dialog --clear --title "${label}" \
    --inputbox "${help}

Up to 32 characters; quotes are removed." 12 70 "${cur}" || return 1
  set_value "${key}" "$(sanitize_text "${DIALOG_OUT}")"
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
  run_dialog --clear --title "${label}" \
    --checklist "${help}" "${DIALOG_HEIGHT}" 70 10 "${items[@]}" || return 1
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
  items+=("0" "(none)" "$([ "${n_cur}" -eq 0 ] && echo on || echo off)")
  # Three at most: the card has four rows and the firmware caps pinning one
  # below the row count, since pinning every row would leave nothing to page.
  local most=3
  [ "${count}" -lt "${most}" ] && most="${count}"
  n=1
  while [ "${n}" -le "${most}" ]; do
    items+=("${n}" "$(list_prefix "${list}" "${n}")" \
            "$([ "${n_cur}" -eq "${n}" ] && echo on || echo off)")
    n=$((n + 1))
  done
  run_dialog --clear --title "${label}" \
    --radiolist "${help}" "${DIALOG_HEIGHT}" 70 6 "${items[@]}" || return 1
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

main_menu() {
  local items=() c
  while true; do
    items=()
    for c in ${CATEGORIES}; do items+=("${c}" "$(cat_label "${c}")" ""); done
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
        if [ "${DIALOG_OUT}" = "defaults" ]; then
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
    Run tty2oledplus_update from the Scripts menu to put the install back."
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
    note "  ${FAT}/Scripts/tty2oledplus_settings.sh"
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
