# tty2oled+'s screens on the framebuffer, for the scripts. Sourced, not run.
#
# The launcher and the tools behind it - Settings, Update, Scrape metadata,
# Boot screen, Uninstall - show the same screens in the same look, drawn by
# tty2oledplus_config (tools/settings-ui/config.c). This is how they ask for
# one: a menu, a question, a checklist, a command's output as it runs.
#
#   ui_begin          take the screen; fails where there is none to take, and
#                     the caller goes on with dialog or plain text as before
#   ui_fb             is the screen taken?
#   ui_menu, ui_ask, ui_check, ui_run     one screen each, below
#   ui_end            give the console back, if this script took it
#
# The screen is taken once and kept: the console stays in graphics mode from
# the first screen to the last, so its text never shows between two. Whoever
# took it gives it back - T2OP_FB tells a script started by another that it
# was taken already, and that giving it back is not its business.
#
# The utility runs from a copy in /tmp. Update writes a new one over the
# installed file and Uninstall removes it, both while it is the thing on
# screen - and a running program cannot be written over.

# Overridable for tests.
UI_BIN_SRC="${T2OP_CONFIG_BIN:-${INSTALL:-/media/fat/tty2oledplus}/tty2oledplus_config}"
UI_BIN_COPY="${T2OP_CONFIG_COPY:-/tmp/.tty2oledplus_config}"
UI_FBDEV="${T2OP_FBDEV:-/dev/fb0}"
UI_OWNER="no"
UI_OUT=""

ui_fb() { [ "${T2OP_FB:-}" = "1" ] && [ -x "${T2OP_FB_BIN:-}" ]; }

ui_begin() {
  ui_fb && return 0
  [ "${T2OP_UI:-auto}" = "dialog" ] && return 1
  [ -s "${UI_BIN_SRC}" ] || return 1
  if [ "${T2OP_UI:-auto}" != "fb" ]; then
    # The Scripts menu runs us on a virtual console with the framebuffer
    # behind it; an SSH session has a terminal and no screen.
    [ -c "${UI_FBDEV}" ] || return 1
    case "$(tty 2>/dev/null)" in /dev/tty[0-9]*) ;; *) return 1 ;; esac
  fi
  cmp -s "${UI_BIN_SRC}" "${UI_BIN_COPY}" 2>/dev/null \
    || { cp "${UI_BIN_SRC}" "${UI_BIN_COPY}" 2>/dev/null && chmod 755 "${UI_BIN_COPY}"; } || return 1
  # Can it draw here at all? Better found out now than on the first screen.
  # shellcheck disable=SC2086
  "${UI_BIN_COPY}" probe --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} 2>/dev/null || return 1
  export T2OP_FB=1 T2OP_FB_BIN="${UI_BIN_COPY}"
  UI_OWNER="yes"
  return 0
}

ui_end() {
  [ "${UI_OWNER}" = "yes" ] || return 0
  UI_OWNER="no"
  # shellcheck disable=SC2086
  ui_fb && "${T2OP_FB_BIN}" release --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} 2>/dev/null
  unset T2OP_FB T2OP_FB_BIN
  return 0
}

# Give the console back whoever took it: for a script about to fall back to
# dialog or plain text, which would otherwise write where nobody can see.
ui_drop() { UI_OWNER="yes"; ui_end; }

# One screen: its name, then the utility's own arguments. --keep and the
# device go in ahead of them - what follows a "--" is the screen's items, or
# the command a run screen runs.
ui_screen() {  # ui_screen <screen> <args...>
  local screen="$1"; shift
  # shellcheck disable=SC2086
  "${T2OP_FB_BIN}" "${screen}" --keep --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} "$@"
}
# The same, with what was chosen read back into UI_OUT.
ui_pick() {  # ui_pick <screen> <args...>
  local screen="$1" tmp rc; shift
  tmp="$(mktemp /tmp/tty2oledplus-ui.XXXXXX)" || return 12
  # shellcheck disable=SC2086
  "${T2OP_FB_BIN}" "${screen}" --out "${tmp}" --keep --fb "${UI_FBDEV}" ${T2OP_CONFIG_ARGS:-} "$@"
  rc=$?
  UI_OUT="$(cat "${tmp}" 2>/dev/null)"; rm -f "${tmp}"
  return "${rc}"
}

# ui_menu <title> <subtitle> <default tag> <tag> <label> <help> ...
# The tag chosen in UI_OUT; fails on Cancel.
ui_menu() {
  local title="$1" sub="$2" def="$3"; shift 3
  ui_pick menu --title "${title}" --subtitle "${sub}" --default "${def}" -- "$@"
}

# ui_ask <title> <text> <buttons, "|" between> [default index]
# The index of the button pressed in UI_OUT; fails on Cancel.
ui_ask() {
  ui_pick ask --title "$1" --text "$2" --buttons "$3" --default "${4:-0}"
}
# ui_msg <title> <text>: something to read, and OK.
ui_msg() { ui_ask "$1" "$2" "OK"; return 0; }
# ui_yesno <title> <text> <no label> <yes label>: 0 for yes. No is the button
# highlighted, and Cancel is no.
ui_yesno() { ui_ask "$1" "$2" "$3|$4" 0 && [ "${UI_OUT}" = "1" ]; }

# ui_check <title> <text> <label of the way on> <tag> <label> <on|off> ...
# The ticked tags, space separated, in UI_OUT; fails on Cancel.
ui_check() {
  local title="$1" text="$2" ok="$3"; shift 3
  ui_pick check --title "${title}" --text "${text}" --ok-label "${ok}" -- "$@"
}

# ui_run <title> <command...>: its output on screen as it comes, and OK when
# it has finished. The command's own exit code.
ui_run() {
  local title="$1"; shift
  ui_screen run --title "${title}" -- "$@"
}
