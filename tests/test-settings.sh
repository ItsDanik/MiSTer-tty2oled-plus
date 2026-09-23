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
yesno() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

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

# Being in the ini is not enough: something has to read it. SHOW_CONSOLE_SPLIT
# passed the check above for three releases while no script anywhere looked at
# it, so the editor offered a switch, the README documented it, and turning it
# off did nothing at all. A setting the user can change has to reach a consumer.
#
# The daemon and the metadata script between them are every consumer there is -
# the init script and the tools read paths, not preferences. A name that is
# only ever assigned is not a reader, so the assignment lines in the ini itself
# do not count, and neither does a line that merely sets a default of the same
# name somewhere else.
UNREAD=""
for c in ${CATEGORIES}; do
  while IFS= read -r r; do
    k="$(field "${r}" 1)"
    grep -qE "[$]\{?${k}\b" "${ROOT}/tty2oled.sh" "${ROOT}/tty2oled-meta.sh" \
      || UNREAD="${UNREAD} ${k}"
  done < <(settings_in "${c}")
done
ok "and every setting offered is read by the daemon or the metadata script" "${UNREAD}" ""

# The other direction, and the point of 0.5.0b: a setting a user is meant to
# choose has to be reachable from the menu. Anything in the ini's user half
# that the editor does not offer must be on this list, with a reason - so
# adding a setting and forgetting the menu fails here rather than shipping a
# release where the only way to change it is a text editor over SSH.
#
#   BAUDRATE, TTYPARAM        the firmware is Serial.begin(115200); a different
#                             rate or different stty flags can only break the
#                             link, so they are not choices
#   NAMES_TXT, TITLE_INDEX,   where the installer put things. Editing them
#   TITLE_INDEX_DIR           points the daemon at files that are not there
NOT_OFFERED="BAUDRATE NAMES_TXT TITLE_INDEX TITLE_INDEX_DIR TTYPARAM"
OFFERED="$(for c in ${CATEGORIES}; do settings_in "${c}"; done | cut -d'|' -f1 | sort -u)"
UNREACHABLE=""
while IFS= read -r k; do
  printf '%s\n' "${OFFERED}" | grep -qxF "${k}" && continue
  printf '%s' " ${NOT_OFFERED} " | grep -qF " ${k} " || UNREACHABLE="${UNREACHABLE} ${k}"
done < <(sed -n '/lines below are the user settings/,$p' "${ROOT}/tty2oled-system.ini" \
         | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=$//' | sort -u)
ok "every user setting is either offered or listed as deliberately not" "${UNREACHABLE}" ""

# And the exclusion list itself has to stay honest: a name on it that the ini
# no longer has is a stale excuse, and would hide a real gap behind it.
STALE=""
for k in ${NOT_OFFERED}; do
  grep -qE "^[[:space:]]*${k}=" "${ROOT}/tty2oled-system.ini" || STALE="${STALE} ${k}"
done
ok "and nothing is excused that the ini no longer has" "${STALE}" ""

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

# An enum's SPEC names a variable holding "value=label;value=label" - it is not
# the spec itself. Getting that wrong passes every check above (five fields, a
# known type) and then fails at runtime with "bad substitution" the moment the
# menu tries to render the value, which is exactly how TTYDEV was first written.
BADSPEC=""
for c in ${CATEGORIES}; do
  while IFS= read -r r; do
    [ "$(field "${r}" 2)" = "enum" ] || continue
    k="$(field "${r}" 1)"; sp="$(field "${r}" 3)"
    case "${sp}" in
      ''|*[!A-Za-z0-9_]*) BADSPEC="${BADSPEC} ${k}:not-a-variable-name" ; continue ;;
    esac
    v="$(eval printf '%s' "\"\${${sp}-}\"")"
    case "${v}" in
      '')    BADSPEC="${BADSPEC} ${k}:${sp}-is-unset" ;;
      *=*)   ;;
      *)     BADSPEC="${BADSPEC} ${k}:${sp}-has-no-pairs" ;;
    esac
  done < <(settings_in "${c}")
done
ok "every enum's spec names a variable of value=label pairs" "${BADSPEC}" ""

# And every value the enum offers has to survive being written and read back,
# which is what rules out a label containing the ';' that separates the pairs.
DUPE=""
for c in ${CATEGORIES}; do
  while IFS= read -r r; do
    [ "$(field "${r}" 2)" = "enum" ] || continue
    sp="$(field "${r}" 3)"
    v="$(eval printf '%s' "\"\${${sp}-}\"")"
    n="$(printf '%s' "${v}" | tr ';' '\n' | cut -d= -f1 | sort | uniq -d | tr '\n' ' ')"
    [ -z "${n}" ] || DUPE="${DUPE} $(field "${r}" 1):${n}"
  done < <(settings_in "${c}")
done
ok "and offers no value twice" "${DUPE}" ""

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
section "a picker returns what is highlighted, not what was already set"
# ---------------------------------------------------------------------------
# The bug this is here for: every single-choice picker was a --radiolist, and
# a radiolist hands back the tag that is already switched *on* unless the user
# presses Space on the one they want. Arrowing down to a new effect and
# pressing Enter therefore stored the old one, and the editor looked as though
# it were ignoring the change. On a MiSTer the Scripts menu is driven by a pad
# as often as a keyboard, so "arrow and press A" is the whole vocabulary.
#
# dialog itself is not driven, but its two widgets are modelled exactly: a
# fake on PATH that answers a --menu with the item the user moved to and a
# --radiolist with whatever carries the "on" status, which is what each one
# really does when Enter is pressed without Space.
FAKEBIN="${TMP}/bin"; mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/dialog" <<'FAKE'
#!/bin/bash
# T2OP_FAKE_PICK is the index of the entry the user arrowed to.
widget=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --menu|--radiolist|--checklist)
      widget="${1#--}"; shift 5 ;;          # widget, text, height, width, list-height
    --default-item) shift 2 ;;
    --clear) shift ;;
    --title) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "${widget}" in
  menu)
    # Returns the highlighted entry. Items are tag/label pairs.
    echo -n "${args[$(( T2OP_FAKE_PICK * 2 ))]}" >&2 ;;
  radiolist)
    # Returns the entry whose status is "on" - Enter without Space never moves
    # the dot. Items are tag/label/status triples.
    i=0
    while [ "${i}" -lt "${#args[@]}" ]; do
      [ "${args[$((i+2))]}" = "on" ] && { echo -n "${args[${i}]}" >&2; break; }
      i=$((i + 3))
    done ;;
esac
exit 0
FAKE
chmod +x "${FAKEBIN}/dialog"
PATH="${FAKEBIN}:${PATH}"

fresh_inis
PENDING=()
# TRANSITION is -2 in the fixture. Entry 2 of the spec is "0=None".
T2OP_FAKE_PICK=2 edit_enum "$(settings_in transition | grep '^TRANSITION|')"
ok "an effect the user moved to is the one stored" "${PENDING[TRANSITION]:-unset}" "0"
# ...and the one the fade-slides made worth checking: they are far down a list
# of 36, which is exactly where nobody would think to press Space.
T2OP_FAKE_PICK=26 edit_enum "$(settings_in transition | grep '^TRANSITION|')"
ok "including one well down the list" "${PENDING[TRANSITION]:-unset}" "30"
ok "and it is the fade-slide it names" \
   "$(enum_label TRANSITION_SPEC "${PENDING[TRANSITION]}")" "Fade, sliding left"

# Same widget, same trap: off could not be chosen.
PENDING=()
T2OP_FAKE_PICK=1 edit_bool "$(settings_in display | grep '^SHOW_METADATA|')"
ok "a switch can be turned off"  "${PENDING[SHOW_METADATA]:-unset}" "no"
T2OP_FAKE_PICK=0 edit_bool "$(settings_in display | grep '^SHOW_METADATA|')"
ok "and back on"                 "${PENDING[SHOW_METADATA]:-unset}" "yes"

# The pinned prefix is a single choice too.
PENDING=()
T2OP_FAKE_PICK=0 edit_prefix "$(settings_in arcade | grep '^ARCADE_PINNED|')"
ok "the pinned row can be emptied" "${PENDING[ARCADE_PINNED]-unset}" ""
T2OP_FAKE_PICK=3 edit_prefix "$(settings_in arcade | grep '^ARCADE_PINNED|')"
ok "and set to a longer run"       "${PENDING[ARCADE_PINNED]:-unset}" "Year Manufacturer Region"

# The field lists choose several things at once, so they cannot be a menu and
# Space really is how they work. They are the only ones that say so.
ok "the multi-select picker explains itself" \
   "$(grep -c -- '--checklist "${help}$(pick_note)"' "${ROOT}/tools/tty2oledplus_settings.sh")" "1"
# Counted as invocations, not mentions: the comments explaining why say the
# word too, and a test that greps for a word in a comment tests nothing.
ok "and no single-choice picker is a radiolist any more" \
   "$(grep -cE '^ *--radiolist ' "${ROOT}/tools/tty2oledplus_settings.sh")" "0"
# Each picker in its own right, rather than counting words over the whole
# file: without --default-item the list opens at the top and the setting in
# force is not visible anywhere, there being no radio dot to mark it now.
for f in edit_bool edit_enum edit_prefix; do
  BODY="$(awk -v f="${f}" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' \
          "${ROOT}/tools/tty2oledplus_settings.sh")"
  ok "${f} is a menu" \
     "$(printf '%s\n' "${BODY}" | grep -cE '^ *--menu ')" "1"
  ok "${f} opens on the value in force" \
     "$(printf '%s\n' "${BODY}" | grep -c -- '--default-item')" "1"
done

PATH="${PATH#"${FAKEBIN}:"}"
PENDING=()
fresh_inis

# ---------------------------------------------------------------------------
section "the boot screen: a PNG in, a picture on the display"
# ---------------------------------------------------------------------------
# The whole interface is a file: drop pics/boot.png and pick the entry. What
# has to be true is that it converts without anything installed - a MiSTer has
# neither Pillow nor ImageMagick - that the display is handed exactly the
# bytes the firmware reads, and that the .gsc, being a step on the way rather
# than something the user asked for, does not survive the run.
mkdir -p "${INSTALL}/pics"
cp "${ROOT}/tools/png2gsc.py" "${INSTALL}/png2gsc.py"
cp "${ROOT}/tools/tty2oled-bootimg.sh" "${INSTALL}/tty2oled-bootimg.sh.real"

# A real 256x54 PNG, written with nothing but the standard library so the
# fixture does not need what the backend is there to avoid needing.
python3 - "${INSTALL}/pics/boot.png" <<'PY'
import struct, sys, zlib
w, h = 256, 54
raw = b"".join(b"\x00" + bytes(((x * 4 + y) % 256) for x in range(w)) for y in range(h))
def chunk(k, d):
    return struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PY
ok "the fixture PNG is written" "$(yesno test -s "${INSTALL}/pics/boot.png")" "yes"

BOOTPNG="${INSTALL}/pics/boot.png"
GSC="${TMP}/boot.gsc"
OUT="$(bootimg_convert "${GSC}" 2>&1)"; RC="${?}"
ok "it converts with nothing installed" "${RC}" "0"
ok "to exactly what the firmware reads" \
   "$(tail -n +4 "${GSC}" | xxd -r -p | wc -c | tr -d ' ')" "6912"
ok "with the three header lines the daemon's tail -n +4 assumes" \
   "$(sed -n '3p' "${GSC}" | grep -c 'icon_bits')" "1"

# The one that has to work on a machine with no image library at all: the
# backend is named rather than left to "auto", so a MiSTer that happens to
# have Pillow converts the same bytes as one that does not.
ok "and it asks for the standard-library backend by name" \
   "$(grep -c -- '--backend pure' "${ROOT}/tools/tty2oledplus_settings.sh")" "1"
rm -f "${GSC}"

# The whole action, with dialog and the transfer both modelled. The fake
# dialog reads its answers in order from a file, so a menu that loops until
# Back can be driven to the end.
BBIN="${TMP}/bbin"; mkdir -p "${BBIN}"
cat > "${BBIN}/dialog" <<'FAKE'
#!/bin/bash
# --msgbox and --yesno just succeed; a --menu takes the next scripted answer.
for a in "$@"; do
  case "${a}" in
    --msgbox) exit 0 ;;
    --yesno)  exit "${T2OP_FAKE_YESNO:-0}" ;;
  esac
done
ans="$(head -n1 "${T2OP_ANSWERS}")"
sed -i '1d' "${T2OP_ANSWERS}"
[ -n "${ans}" ] || exit 1          # nothing left to say: Back
echo -n "${ans}" >&2
exit 0
FAKE
chmod +x "${BBIN}/dialog"
cat > "${INSTALL}/tty2oled-bootimg.sh" <<'FAKE'
#!/bin/bash
echo "bootimg $1 $(basename "${2:-}")" >> "${T2OP_BOOTLOG}"
case "$1" in
  status) echo "BOOTIMG,none" ;;
  set)    [ -s "$2" ] || { echo "empty image" >&2; exit 1; }
          echo "${2}" > "${T2OP_BOOTLOG}.sent" ;;
esac
exit 0
FAKE
chmod +x "${INSTALL}/tty2oled-bootimg.sh"

export T2OP_BOOTLOG="${TMP}/bootlog" T2OP_ANSWERS="${TMP}/answers"
: > "${T2OP_BOOTLOG}"
printf 'install\n' > "${T2OP_ANSWERS}"
PATH="${BBIN}:${PATH}" bootimg_menu >/dev/null 2>&1

ok "the display is asked to store it" \
   "$(grep -c '^bootimg set boot.gsc' "${T2OP_BOOTLOG}")" "1"
ok "and what it was handed was a real picture" \
   "$(yesno test -s "${T2OP_BOOTLOG}.sent")" "yes"
# The .gsc is a build artifact. Leaving it in pics/ would put an 8KB file of
# hex next to the user's artwork that nothing reads and no update removes.
ok "the converted .gsc does not survive the run" \
   "$(yesno test -e "${INSTALL}/pics/boot.gsc")" "no"
ok "and the PNG does, so it can be sent again after a reflash" \
   "$(yesno test -e "${BOOTPNG}")" "yes"

# No picture to use: it says so rather than converting nothing.
mv "${BOOTPNG}" "${TMP}/boot.png.away"
: > "${T2OP_BOOTLOG}"
printf 'install\n' > "${T2OP_ANSWERS}"
PATH="${BBIN}:${PATH}" bootimg_menu >/dev/null 2>&1
ok "with no boot.png nothing is sent" "$(grep -c '^bootimg set' "${T2OP_BOOTLOG}")" "0"
mv "${TMP}/boot.png.away" "${BOOTPNG}"

# Clearing goes back to the built-in logo and leaves the user's PNG alone.
: > "${T2OP_BOOTLOG}"
printf 'clear\n' > "${T2OP_ANSWERS}"
PATH="${BBIN}:${PATH}" bootimg_menu >/dev/null 2>&1
ok "clearing asks the display to forget it" "$(grep -c '^bootimg clear' "${T2OP_BOOTLOG}")" "1"
ok "and keeps your PNG"                     "$(yesno test -e "${BOOTPNG}")" "yes"

# It is reached from the main menu, and png2gsc.py has to be installed for any
# of this to run at all.
ok "the main menu offers it" \
   "$(grep -c '"bootscreen" "Boot screen"' "${ROOT}/tools/tty2oledplus_settings.sh")" "1"
ok "and the converter is part of an install" \
   "$(. "${ROOT}/tools/manifest.sh"; printf '%s' "${MANIFEST_TOOLS}" | grep -c 'png2gsc.py')" "1"

unset T2OP_BOOTLOG T2OP_ANSWERS
fresh_inis

# ---------------------------------------------------------------------------
section "the effect list is the ini's, not a copy that drifts from it"
# ---------------------------------------------------------------------------
# The editor is how most people will ever pick a transition, so an effect the
# ini documents and the editor cannot offer is as good as not existing - the
# same "a setting in the ini is not a setting that works" the key checks
# above are there for, one level down.
INI_EFFECTS="$(sed -n '/^# How one picture replaces the last/,/^TRANSITION=/p' "${ROOT}/tty2oled-system.ini" \
               | grep -oE '(^#|[[:space:]]) +-?[0-9]+  [A-Za-z]' | grep -oE -- '-?[0-9]+' | sort -n | tr '\n' ' ')"
SPEC_EFFECTS="$(printf '%s' "${TRANSITION_SPEC}" | tr ';' '\n' | cut -d= -f1 | sort -n | tr '\n' ' ')"
ok "the editor offers exactly what the ini lists" "${SPEC_EFFECTS}" "${INI_EFFECTS}"
ok "the fade-slides among them" \
   "$(printf '%s' "${SPEC_EFFECTS}" | grep -oE '\b3[0-9]\b' | tr '\n' ' ')" \
   "30 31 32 33 34 35 36 37 38 39 "
# Every one needs a label a person can choose between - a bare number in the
# menu tells nobody which way the picture goes.
ok "and every one has a name" \
   "$(printf '%s' "${TRANSITION_SPEC}" | tr ';' '\n' | grep -cE '^-?[0-9]+=.+')" \
   "$(printf '%s' "${TRANSITION_SPEC}" | tr ';' '\n' | grep -c .)"

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
