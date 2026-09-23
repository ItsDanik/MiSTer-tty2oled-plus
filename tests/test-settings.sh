#!/bin/bash
#
# Tests for tty2oledplus_settings.sh, the Scripts-menu settings editor.
#
# dialog is not driven here - a menu nobody can see is not what goes wrong with
# an editor like this. What goes wrong is the file it writes: a setting written
# under a name the daemon does not read, a user ini rewritten with the user's
# own comments gone, a pinned field left naming a field that is no longer
# shown, or a value that is shell rather than a value. So this covers the ini
# reading and writing, the list arithmetic, and the fact that every key offered
# is a key the release actually has.
#
#   ./tests/test-settings.sh

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/settings"
rm -rf "${TMP}"; mkdir -p "${TMP}/install"

INSTALL="${TMP}/install"
SYS="${INSTALL}/tty2oled-system.ini"
USR="${INSTALL}/tty2oled-user.ini"

PASS=0; FAIL=0
ok() {
  local label="${1}" got="${2}" want="${3}"
  if [ "${got}" = "${want}" ]; then
    PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "${label}"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n' "${label}" "${want}" "${got}"
  fi
}
section() { printf '\n\033[1m%s\033[0m\n' "${1}"; }

# The editor as a library: every function, no menus.
T2OP_SETTINGS_LIB=yes T2OP_INSTALL="${INSTALL}" . "${ROOT}/tools/tty2oledplus_settings.sh"

fresh_inis() {
  cat > "${SYS}" <<'EOF'
CONTRAST="255"
DIM_AFTER="120"
TRANSITION="-2"
SHOW_METADATA="yes"
METADATA_FIELDS="System Year Genre Region Format"
METADATA_PINNED="System Year"
ARCADE_FIELDS="Year Manufacturer Region Orientation Core Author Set MAME"
ARCADE_PINNED="Year Manufacturer"
UPDATE_ALL_TEXT="Updating System ..."
EOF
  cat > "${USR}" <<'EOF'
# My own notes, which are mine.

#TTYDEV="/dev/ttyACM0"
TRANSITION="5"
EOF
}

# ---------------------------------------------------------------------------
section "reading a value out of an ini"
fresh_inis
ok "a quoted value"            "$(ini_get "${SYS}" CONTRAST)" "255"
ok "a value with spaces"       "$(ini_get "${SYS}" METADATA_FIELDS)" "System Year Genre Region Format"
ok "a negative number"         "$(ini_get "${SYS}" TRANSITION)" "-2"
ok "a key that is not there"   "$(ini_get "${SYS}" NOPE; echo "rc=${?}")" "rc=1"
# A commented-out line is not a setting; reading one as if it were would show
# the user a value the daemon never sees.
ok "a commented-out key is not a value" "$(ini_get "${USR}" TTYDEV; echo "rc=${?}")" "rc=1"

printf 'CONTRAST=200 # trailing comment\n' > "${TMP}/unquoted.ini"
ok "an unquoted value, comment and all" "$(ini_get "${TMP}/unquoted.ini" CONTRAST)" "200"

printf 'CONTRAST="10"\nCONTRAST="20"\n' > "${TMP}/twice.ini"
ok "the last assignment is the one that counts" "$(ini_get "${TMP}/twice.ini" CONTRAST)" "20"

# Parsed, never sourced: this runs as root from a menu.
printf 'CONTRAST="$(touch %s/pwned)"\n' "${TMP}" > "${TMP}/evil.ini"
ini_get "${TMP}/evil.ini" CONTRAST >/dev/null
ok "reading a value runs nothing" "$([ -e "${TMP}/pwned" ] && echo ran || echo no)" "no"

section "which value is the current one"
fresh_inis
ok "the user's, where they have set one"  "$(current_value TRANSITION)" "5"
ok "the release's, where they have not"   "$(current_value CONTRAST)" "255"
ok "the release's is the default either way" "$(default_value TRANSITION)" "-2"

# ---------------------------------------------------------------------------
section "writing a value into the user ini"
fresh_inis
ini_put "${USR}" CONTRAST 120
ok "the new setting is there"  "$(ini_get "${USR}" CONTRAST)" "120"
ok "and the user's comment is not touched" "$(grep -c 'My own notes' "${USR}")" "1"
ok "nor is the line they commented out"    "$(grep -c '^#TTYDEV=' "${USR}")" "1"

ini_put "${USR}" TRANSITION 0
ok "an existing setting is replaced"       "$(ini_get "${USR}" TRANSITION)" "0"
ok "in place, not appended"                "$(grep -c '^TRANSITION=' "${USR}")" "1"

ini_put "${USR}" DIM_AFTER 60
ok "and the header is written once, not per setting" \
   "$(grep -c 'Written by tty2oledplus_settings' "${USR}")" "1"

ini_drop "${USR}" CONTRAST
ok "dropping a setting removes its line"   "$(ini_get "${USR}" CONTRAST; echo "rc=${?}")" "rc=1"
ok "and leaves the others"                 "$(ini_get "${USR}" DIM_AFTER)" "60"
ok "and the user's own lines"              "$(grep -c 'My own notes' "${USR}")" "1"

# A user ini that does not exist yet is the normal case on a fresh install.
rm -f "${USR}"
ini_put "${USR}" CONTRAST 7
ok "a missing user ini is created" "$(ini_get "${USR}" CONTRAST)" "7"

# ---------------------------------------------------------------------------
section "saving writes only what differs from the release's defaults"
fresh_inis
PENDING=([CONTRAST]=200 [DIM_AFTER]=120 [TRANSITION]=-2)
apply_pending
ok "a changed setting is written"               "$(ini_get "${USR}" CONTRAST)" "200"
# The point of the design: a setting left at its default is not written, so a
# later release that changes that default is still followed.
ok "one set back to the default is not"         "$(ini_get "${USR}" DIM_AFTER; echo "rc=${?}")" "rc=1"
ok "and an override equal to the default goes"  "$(ini_get "${USR}" TRANSITION; echo "rc=${?}")" "rc=1"
ok "nothing is left pending afterwards"         "$(changed_count)" "0"

section "putting everything back"
fresh_inis
PENDING=([CONTRAST]=10 [METADATA_FIELDS]="Year Genre")
apply_pending
reset_to_defaults
ok "every managed setting is gone"   "$(grep -cE '^(CONTRAST|METADATA_FIELDS|TRANSITION)=' "${USR}")" "0"
ok "the user's own lines stay"       "$(grep -c 'My own notes' "${USR}")" "1"
ok "and so does what they commented" "$(grep -c '^#TTYDEV=' "${USR}")" "1"

# ---------------------------------------------------------------------------
section "field lists keep the order they are drawn in"
# The order of METADATA_FIELDS is the order the rows appear in, so re-picking
# the same fields must not shuffle them - a checklist hands them back in its
# own order, not the display's.
ok "an unchanged pick is unchanged" \
   "$(list_merge "System Year Genre" "Genre System Year")" "System Year Genre"
ok "a newly ticked field goes on the end" \
   "$(list_merge "System Year" "System Year Format")" "System Year Format"
ok "an unticked one is dropped" \
   "$(list_merge "System Year Genre" "System Genre")" "System Genre"
ok "picking nothing leaves nothing" "$(list_merge "System Year" "")" ""

section "pinned fields cannot name a field that is not shown"
fresh_inis
PENDING=()
# METADATA_PINNED has to be a subset of METADATA_FIELDS; the daemon ignores a
# name that is not, which would leave the editor showing a setting that does
# nothing.
set_value METADATA_FIELDS "System Genre"
ok "dropping a shown field drops it from the pinned list" \
   "$(value_of METADATA_PINNED)" "System"
ok "and the fields themselves are what was picked" \
   "$(value_of METADATA_FIELDS)" "System Genre"

section "the arcade pinned row is a leading run of the short fields"
fresh_inis
PENDING=()
ok "two of them"   "$(list_prefix "Year Manufacturer Region Core" 2)" "Year Manufacturer"
ok "none of them"  "$(list_prefix "Year Manufacturer" 0)" ""
ok "more than there are" "$(list_prefix "Year" 5)" "Year"
# Re-ordering the short fields moves the pinned row with them: it is the top
# row of the grid, so it cannot start halfway down the list.
set_value ARCADE_FIELDS "Region Year Core"
ok "re-ordering the fields re-pins the new leaders" \
   "$(value_of ARCADE_PINNED)" "Region Year"

# ---------------------------------------------------------------------------
section "a value is a value, not shell"
ok "an integer is accepted"        "$(clamp_int 42 0 255)" "42"
ok "one below the floor is raised" "$(clamp_int -5 0 255)" "0"
ok "one above the ceiling is cut"  "$(clamp_int 900 0 255)" "255"
ok "a negative floor works"        "$(clamp_int -1 -1 255)" "-1"
ok "letters are refused"           "$(clamp_int "12x" 0 255; echo "rc=${?}")" "rc=1"
ok "so is nothing at all"          "$(clamp_int "" 0 255; echo "rc=${?}")" "rc=1"

# Whatever is typed into a text box ends up in a file the daemon sources.
ok "quotes are stripped"      "$(sanitize_text 'say "hi"')" "say hi"
ok "so is a command substitution" \
   "$(sanitize_text 'a$(reboot)b')" "a(reboot)b"
ok "and backticks"            "$(sanitize_text 'a`reboot`b')" "arebootb"
ok "and it is cut to 32 characters" \
   "$(sanitize_text "$(printf 'x%.0s' $(seq 1 60))" | wc -c)" "32"

# ---------------------------------------------------------------------------
section "every setting offered is one the release actually has"
# A typo in a key here would show the user a menu that changes nothing: the
# daemon would go on reading the name it knows, and the editor would go on
# reporting the one it wrote.
MISSING=""
for c in ${CATEGORIES}; do
  while IFS= read -r r; do
    k="$(field "${r}" 1)"
    grep -qE "^[[:space:]]*${k}=" "${ROOT}/tty2oled-system.ini" || MISSING="${MISSING} ${k}"
  done < <(settings_in "${c}")
done
ok "no setting is offered under a name the ini does not use" "${MISSING}" ""

# Each record has to have all five fields, or the menu shows a blank label or
# edits nothing at all.
MALFORMED=""
for c in ${CATEGORIES}; do
  while IFS= read -r r; do
    [ "$(printf '%s' "${r}" | awk -F'|' '{print NF}')" = "5" ] || MALFORMED="${MALFORMED} ${r}"
    case "$(field "${r}" 2)" in
      bool|enum|int|text|list|prefix) ;;
      *) MALFORMED="${MALFORMED} $(field "${r}" 1):type" ;;
    esac
    [ -n "$(field "${r}" 4)" ] || MALFORMED="${MALFORMED} $(field "${r}" 1):label"
    [ -n "$(field "${r}" 5)" ] || MALFORMED="${MALFORMED} $(field "${r}" 1):help"
  done < <(settings_in "${c}")
done
ok "every record is complete and of a type that can be edited" "${MALFORMED}" ""

section "the transition list matches the one the ini documents"
# The ini lists every effect by number, and the firmware's own suite checks
# that list against the sketch. This ties the editor's menu to the same
# numbers, so an effect added to the firmware cannot go missing from here.
# The ini's list runs two effects to a line, so both columns are read: a
# number followed by the start of its name.
INI_EFFECTS="$(awk '/^# How one picture replaces the last/,/^TRANSITION=/' "${ROOT}/tty2oled-system.ini" \
  | grep -oE '(-?[0-9]+)[[:space:]]+[A-Za-z]' \
  | grep -oE '^-?[0-9]+' | sort -n | uniq | tr '\n' ' ')"
MENU_EFFECTS="$(printf '%s' "${TRANSITION_SPEC}" | tr ';' '\n' | cut -d= -f1 | sort -n | uniq | tr '\n' ' ')"
ok "the same effects, by number" "${MENU_EFFECTS}" "${INI_EFFECTS}"

# ---------------------------------------------------------------------------
section "running it where it cannot work"
OUT="$(T2OP_INSTALL="${TMP}/nowhere" bash "${ROOT}/tools/tty2oledplus_settings.sh" 2>&1)"; RC="${?}"
ok "no install, so it says so rather than drawing a menu" \
   "$(printf '%s' "${OUT}" | grep -c 'is not installed')" "1"
ok "and fails"                      "$([ "${RC}" -ne 0 ] && echo yes || echo no)" "yes"

fresh_inis
# The Scripts menu with fb_terminal=0 has no terminal to draw in. dialog would
# fail with something unreadable; this says what to do instead.
OUT="$(T2OP_INSTALL="${INSTALL}" bash "${ROOT}/tools/tty2oledplus_settings.sh" </dev/null 2>&1)"; RC="${?}"
ok "no terminal, so it explains itself" \
   "$(printf '%s' "${OUT}" | grep -c 'needs a terminal')" "1"
ok "and exits 2, as MiSTer's own editor does" "${RC}" "2"
ok "having changed nothing"          "$(ini_get "${USR}" TRANSITION)" "5"

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
