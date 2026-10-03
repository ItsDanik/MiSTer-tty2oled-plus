#!/bin/bash
#
# The settings utility's preview. Runs ON THE MISTER, started by
# tty2oledplus_config with a pipe for stdin: while a setting is being changed
# on the TV, the display shows what it does.
#
#   tty2oledplus_preview.sh [--install DIR]            reads stdin until it closes
#   tty2oledplus_preview.sh [--install DIR] --check    is there a display to show it on?
#
# On stdin, a line each:
#
#   focus <key>           the setting that is highlighted ("-" for none)
#   set <key> <value>     a setting changed; the value is the rest of the line
#
# It has the display's port, so the daemon must not be running - which
# tty2oledplus_settings.sh sees to, and starts it again when this has gone.
# Nothing here is saved: values live in this process, and the daemon reads
# the ini when it starts.
#
# What is shown is the daemon's own doing. This sources the daemon up to its
# main block and replaces only what the daemon would read off the MiSTer - the
# game - with a sample: the picture, the hold, CMDMETA, the icon and every
# other command are sent by the functions the daemon sends them with, in the
# order it sends them, so a preview cannot look like something the daemon
# would not do.
#
# A setting has a scene, the screen it is seen on: a console game for the
# fields, an arcade card, a film, the menu for the clock and the ticker, two
# pictures taking turns for a transition, the update screens. Some need a
# demonstration as well, because their real timing is minutes: dimming is
# shown after two seconds, the side swap every eight.

INSTALL="${T2OP_INSTALL:-/media/fat/tty2oledplus}"
CHECK="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL="$2"; shift 2 ;;
    --check)   CHECK="yes"; shift ;;
    *)         echo "tty2oledplus_preview: unknown option '$1'" >&2; exit 2 ;;
  esac
done

[ -r "${INSTALL}/tty2oled-system.ini" ] && [ -r "${INSTALL}/tty2oled.sh" ] || exit 1
# shellcheck disable=SC1090,SC1091
. "${INSTALL}/tty2oled-system.ini"
# shellcheck disable=SC1090,SC1091
[ -r "${INSTALL}/tty2oled-user.ini" ] && . "${INSTALL}/tty2oled-user.ini"
# shellcheck disable=SC1090,SC1091
. "${INSTALL}/tty2oled-meta.sh"
# shellcheck disable=SC1090,SC1091
[ -r "${INSTALL}/tty2oled-port.sh" ] && . "${INSTALL}/tty2oled-port.sh"
# The daemon's functions without its main loop, and without the three lines
# that source what was sourced above from where the daemon expects it.
eval "$(sed -e '/^# \*\* Main \*\*/,$d' -e '/^\. \/media\/fat/d' -e '/^\[ -r \/media\/fat/d' \
            -e '/^cd \/tmp/d' "${INSTALL}/tty2oled.sh")"
cd /tmp || exit 1

# Tests stand a pipe in for the port and skip the waits.
if [ -n "${T2OP_PREVIEW_TTY:-}" ]; then TTYDEV="${T2OP_PREVIEW_TTY}"; WAITSECS=0; CMDWAITSECS=0; fi
TTYCONF="${TTYDEV}"
[ -n "${T2OP_PREVIEW_TTY:-}" ] || port_resolve
if [ -z "${T2OP_PREVIEW_TTY:-}" ]; then
  [ -c "${TTYDEV}" ] || exit 1
fi
[ "${CHECK}" = "yes" ] && exit 0

# ---------------------------------------------------------------------------
# The sample: what the daemon would have read off MiSTer's state files.
# ---------------------------------------------------------------------------
DEMO_KIND="menu"          # what core_kind and build_meta answer for
DEMO_CORE="MENU"
DEMO_DESC="no"            # yes: straight to the description page
DEMO_CONSOLE="SNES"
DEMO_ARCADE="galaga"
DEMO_OTHER="genesis"      # the transition's second picture

core_kind() {
  case "${DEMO_KIND}" in arcade) CORE_KIND="arcade" ;; console|dvd) CORE_KIND="console" ;; *) CORE_KIND="unknown" ;; esac
}

build_meta() {
  meta_reset
  case "${DEMO_KIND}" in
    console) demo_console ;;
    arcade)  demo_arcade ;;
    dvd)     demo_dvd ;;
    *)       META_KIND="unknown"; META_TITLE="${1}"; META_ICON="${1}" ;;
  esac
  return 0
}

demo_console() {
  local CORE_STARTPATH="" year="1992" company="Nintendo"
  META_KIND="console"; META_GAME="yes"; META_SOURCE="sample"; META_ICON="${DEMO_CONSOLE}"
  META_TITLE="The Legend of Zelda - A Link to the Past"
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="A sample description, to show how the page reads. The hero wakes on a stormy night to a voice calling for help, follows it into the castle, and finds a kingdom that needs rescuing twice: once in the world he knows and once in its dark reflection. The text scrolls up at the speed you set, and the page turns when it has all gone by."
  display_corename "${DEMO_CONSOLE}"
  # One row for the two, as the daemon makes it.
  if [ "${COMPACT_YEAR_COMPANY:-yes}" = "yes" ]; then year="${year}, ${company}"; company=""; fi
  META_AVAIL=(
    [System]="${DISPLAY_CORENAME}" [Region]="USA" [Year]="${year}" [Company]="${company}"
    [Genre]="Action-adventure" [Developer]="Nintendo EAD" [Format]="SFC"
    [Platform]="Super Nintendo" [Engine]="Sample" [Language]="English"
    [Players]="1" [Rating]="9.4/10" [Released]="1992-04-13" [Series]="The Legend of Zelda"
  )
  if [ "${DEMO_DESC}" = "yes" ] && [ -n "${META_DESC}" ]; then
    local METADATA_FIELDS="System" METADATA_PINNED=""
    meta_addfields_ordered
  else
    meta_addfields_ordered
  fi
}

demo_arcade() {
  META_KIND="arcade"; META_GAME="yes"; META_SOURCE="sample"
  META_TITLE="Galaga"
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="A sample description, to show how the page reads. One fighter against a fleet that arrives in formation and peels off to dive. Let a boss capture the ship, shoot the boss, and the two fly side by side with twice the fire."
  ARCADE_AVAIL=(
    [Year]="1981" [Manufacturer]="Namco" [Region]="World" [Orientation]="Vertical"
    [Core]="galaga" [Author]="Sample" [Set]="galaga" [MAME]="0220"
    [Genre]="Shooter / Gallery" [Platform]="Namco Galaga" [Version]="Rev. B" [Players]="2"
    [Controls]="2-way" [Buttons]="Fire" [Developer]="Namco" [Publisher]="Midway"
    [Rating]="8.6/10" [Released]="1981-09-01" [Series]="Galaxian"
  )
  arcade_addfields_ordered
}

demo_dvd() {
  local f label
  if [ "${DVD_SCREEN:-yes}" != "yes" ]; then META_KIND="unknown"; META_TITLE="DVD"; return 0; fi
  META_KIND="console"; META_GAME="yes"; META_SOURCE="sample"; META_ICON="DVD"
  META_TITLE="Night of the Living Dead"
  [ "${SHOW_DESCRIPTION:-yes}" = "yes" ] && META_DESC="A sample description, to show how the page reads. Seven strangers shut themselves in a farmhouse and argue about the cellar while the night outside fills up."
  local -A avail=(
    [Year]="1968" [Studio]="Image Ten" [Director]="George A. Romero" [Artist]=""
    [Genre]="Horror" [Runtime]="1h 36m" [Titles]="3" [Label]="NOTLD_1968"
  )
  for f in ${DVD_FIELDS}; do
    _canon_label "${f}" "${_DVD_KNOWN}" || continue
    label="${_R}"
    meta_addfield "${label}" "${avail[${label}]:-}"
  done
  META_PINNED_COUNT=0
}

SAMPLE_FEED=$'tty2oled+ news ticker: this is how headlines run under the menu\nA second headline follows the first after a gap\nThe third is the last of this sample'

# ---------------------------------------------------------------------------
# Things that happen later, without waiting for them: a name, a time, a
# command. The loop runs what is due between two lines of input.
# ---------------------------------------------------------------------------
declare -A PLAN_AT=() PLAN_DO=()
later() {  # later <name> <ms from now> <command...>
  local name="${1}" ms="${2}"; shift 2
  now_ms
  PLAN_AT["${name}"]=$(( NOW_MS + ms )); PLAN_DO["${name}"]="${*}"
}
unplan() { unset "PLAN_AT[${1}]" "PLAN_DO[${1}]"; }
plan_run() {
  local name todo
  now_ms
  for name in "${!PLAN_AT[@]}"; do
    [ "${NOW_MS}" -ge "${PLAN_AT[${name}]}" ] || continue
    todo="${PLAN_DO[${name}]}"
    unplan "${name}"
    ${todo}
  done
}

say() { dbug "Sending: ${1}"; echo "${1}" >"${TTYDEV}"; cmdwait; }

# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------
SCENE=""
FOCUS="-"

scene_of() {  # into SCENE_WANT: the screen this setting is seen on
  case "${1}" in
    BAND_CLOCK*|RSS_*|BOOTSCREEN_AS_MENU|UPDATE_NOTE_*|UPDATE_CHECK_*)
      SCENE_WANT="menu" ;;
    ARCADE_*)           SCENE_WANT="arcade" ;;
    DVD_*)              SCENE_WANT="dvd" ;;
    TRANSITION*)        SCENE_WANT="transition" ;;
    UPDATE_ALL_SCREEN|UPDATE_ALL_TEXT|UPDATE_ALL_DETAILS|UPDATE_DONE_TEXT|UPDATE_DONE_SECS|UPDATE_FAILED_TEXT|SELF_UPDATE_SCREEN|SELF_UPDATE_TEXT)
      SCENE_WANT="busy" ;;
    # Nothing of theirs to show: whatever is up stays up.
    -|TTYDEV|debug|METADATA_WARN|GAME_ROOTS|METADATA_POLL|SLEEPMODEDELAY|SLEEP_POLL|SLEEP_STALE_GRACE|UPDATE_ALL_POLL|PRIORITIZE_USER_BANNERS)
      SCENE_WANT="${SCENE:-menu}" ;;
    *)                  SCENE_WANT="console" ;;
  esac
}

# The header: Super Attract Mode's, while its settings are the ones in hand.
demo_head() {
  case "${FOCUS}" in
    SAM_*)
      if [ "${SAM_HEADER:-yes}" = "yes" ]; then sendhead "${SAM_HEADER_TEXT:-Super Attract Mode}"; else sendhead ""; fi
      TIMER_SENT="?"
      if [ "${SAM_TIMER:-yes}" = "yes" ]; then sendtimer 95; else sendtimer ""; fi ;;
    *) sendhead ""; sendtimer "" ;;
  esac
}

# The band under the menu: the clock, the feed, the notice.
demo_band() {
  local text=""
  sendclock
  rss_load 2>/dev/null || { [ "${RSS_TEXT}" = "${SAMPLE_FEED}" ] || { RSS_TEXT="${SAMPLE_FEED}"; RSS_REV=$(( RSS_REV + 1 )); }; RSS_FOR="${RSS_URL:-}"; }
  case "${FOCUS}" in
    # The ticker at once, rather than after the clock's whole turn.
    RSS_FEED|RSS_URL|RSS_SCROLL_SECS|RSS_SPEED|RSS_MINUTES|RSS_ITEMS) RSS_CLOCK_SECS=3 sendrss ;;
    *) sendrss ;;
  esac
  case "${FOCUS}" in
    UPDATE_NOTE_TEXT)        text="${UPDATE_NOTE_TEXT}" ;;
    UPDATE_NOTE_SYSTEM_TEXT) text="${UPDATE_NOTE_SYSTEM_TEXT}" ;;
    UPDATE_NOTE_BOTH_TEXT)   text="${UPDATE_NOTE_BOTH_TEXT}" ;;
    UPDATE_CHECK_TTY2OLED)   [ "${UPDATE_CHECK_TTY2OLED:-yes}" = "yes" ] && text="${UPDATE_NOTE_TEXT}" ;;
    UPDATE_CHECK_SYSTEM)     [ "${UPDATE_CHECK_SYSTEM:-yes}" = "yes" ] && text="${UPDATE_NOTE_SYSTEM_TEXT}" ;;
  esac
  sendnote "${text}"
}

demo_busy() {
  BUSYLINE_LAST=""
  case "${FOCUS}" in
    SELF_UPDATE_*)
      if [ "${SELF_UPDATE_SCREEN:-yes}" = "yes" ]; then
        sendbusy 1 "${SELF_UPDATE_TEXT}" "${TRANSITION}"
        sendbusyline "Installing the scripts"
      else pictureof "${DEMO_CONSOLE}"; fi ;;
    UPDATE_DONE_*)
      sendbusy 0 "${UPDATE_DONE_TEXT}"; sendbusyline "Finished in 1m 12s" ;;
    UPDATE_FAILED_TEXT)
      sendbusy 0 "${UPDATE_FAILED_TEXT}"; sendbusyline "Finished in 1m 12s" ;;
    *)
      if [ "${UPDATE_ALL_SCREEN:-yes}" = "yes" ]; then
        sendbusy 1 "${UPDATE_ALL_TEXT}" "${TRANSITION}"
        if [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ]; then sendbusyline "_Console/SNES_20260901.rbf"; else say "CMDBUSYLINE,"; fi
      else pictureof "${DEMO_CONSOLE}"; fi ;;
  esac
}

# A core's picture and nothing else, as the daemon sends one with game
# details off.
pictureof() { DEMO_KIND="other"; SHOW_METADATA="no" senddata "${1}"; }

# Two pictures taking turns, so the effect in hand is seen over and over.
TRANS_SIDE=0
trans_step() {
  local gap=3500
  case "${TRANSITION}" in
    -2|3[0-9]) gap=$(( 2 * ${TRANSITION_FADE_MS:-800} + ${TRANSITION_BLANK_MS:-1000} + 2500 )) ;;
  esac
  if [ "${TRANS_SIDE}" -eq 0 ]; then pictureof "${DEMO_CONSOLE}"; else pictureof "${DEMO_OTHER}"; fi
  TRANS_SIDE=$(( 1 - TRANS_SIDE ))
  later trans "${gap}" trans_step
}

# With the description in hand, the page it is on comes up in two seconds
# rather than after every field has had its turn.
with_desc() {
  if [ "${DEMO_DESC}" = "yes" ]; then METADATA_INTERVAL=2 "${@}"; else "${@}"; fi
}

show_scene() {  # show_scene <scene>
  SCENE="${1}"
  unplan trans
  DEMO_DESC="no"
  case "${FOCUS}" in VSCROLL_SPEED|SHOW_DESCRIPTION) DEMO_DESC="yes" ;; esac
  # With game details off the daemon never leaves metadata mode, never having
  # entered it; here the last scene may have.
  [ "${SHOW_METADATA}" = "yes" ] || [ "${META_WIRE_LAST:-}" = "OFF" ] || sendmetaoff
  case "${SCENE}" in
    menu)
      DEMO_KIND="menu"; DEMO_CORE="MENU"
      senddata "MENU"; demo_band ;;
    console)
      DEMO_KIND="console"; DEMO_CORE="${DEMO_CONSOLE}"
      demo_head; with_desc senddata "${DEMO_CORE}" ;;
    arcade)
      DEMO_KIND="arcade"; DEMO_CORE="${DEMO_ARCADE}"
      demo_head; senddata "${DEMO_CORE}"
      # The card now, not after the artwork's turn.
      [ "${SHOW_METADATA}" = "yes" ] && say "CMDSHMETA" ;;
    dvd)
      DEMO_KIND="dvd"; DEMO_CORE="DVD"
      demo_head; senddata "${DEMO_CORE}"
      [ "${SHOW_METADATA}" = "yes" ] && [ "${DVD_SCREEN:-yes}" = "yes" ] && fw_atleast 0.8.2 && say "CMDMEDIA,1,1325,5760,4,12" ;;
    transition)
      sendmetaoff; TRANS_SIDE=0; trans_step ;;
    busy)
      sendmetaoff; demo_busy ;;
  esac
}

# The game's details again, the picture left alone: a game change, to the
# daemon.
refresh_meta() {
  case "${SCENE}" in console|arcade|dvd) ;; *) return 0 ;; esac
  with_desc sendmeta "${DEMO_CORE}" || return 0
  sendicon "${META_ICON}"
  [ "${SCENE}" = "arcade" ] && say "CMDSHMETA"
  return 0
}

# ---------------------------------------------------------------------------
# Demonstrations: what a setting does, sooner than it really would.
# ---------------------------------------------------------------------------
DEMO_DIM="no"; DEMO_FLIP="no"
dim_wake() {  # something for the firmware to wake at, and round again
  sendscroll
  later demo $(( 2000 + ${DIM_FADE_MS:-6000} + 2500 )) dim_wake
}
demo_focus() {
  unplan demo
  case "${FOCUS}" in
    DIM_CONTRAST|DIM_FADE_MS|DIM_WAKE)
      # Dim after two seconds, wake, and again.
      DEMO_DIM="yes"
      say "CMDDIM,2,${DIM_CONTRAST:-80},${DIM_WAKE:--1},${DIM_FADE_MS:-6000}"
      later demo $(( 2000 + ${DIM_FADE_MS:-6000} + 2500 )) dim_wake ;;
    *)
      [ "${DEMO_DIM}" = "yes" ] && { DEMO_DIM="no"; senddim; } ;;
  esac
  case "${FOCUS}" in
    FLIP_MINUTES)
      DEMO_FLIP="yes"
      if [ "${FLIP_MINUTES:-5}" -gt 0 ] 2>/dev/null; then say "CMDFLIP,8"; else say "CMDFLIP,0"; fi ;;
    *)
      [ "${DEMO_FLIP}" = "yes" ] && { DEMO_FLIP="no"; sendflip; } ;;
  esac
  if [ "${FOCUS}" = "CONTRAST_FADE_MS" ]; then
    # Down and back up, at the speed in hand.
    local low=20
    [ "${CONTRAST:-200}" -lt 80 ] 2>/dev/null && low=255
    say "CMDCON,${low}"
    later demo $(( ${CONTRAST_FADE_MS:-800} + 700 )) sendcontrast
  fi
}

# ---------------------------------------------------------------------------
# A setting changed.
# ---------------------------------------------------------------------------
NEED_SCENE="no"; NEED_META="no"; NEED_DEMO="no"
CHANGED=()

apply() {  # apply <key>
  case "${1}" in
    CONTRAST)                 sendcontrast ;;
    CONTRAST_FADE_MS)         sendfade ;;
    ROTATE)
      if [ "${ROTATE}" = "yes" ]; then say "CMDROT,1"; else say "CMDROT,0"; fi
      NEED_SCENE="yes" ;;
    HSCROLL_SPEED|VSCROLL_SPEED) sendscroll ;;
    DIM_AFTER)                senddim ;;
    DIM_*|FLIP_MINUTES)       ;;                      # demo_focus shows them
    TRANSITION_FADE_MS|TRANSITION_BLANK_MS)
      sendtfade; [ "${SCENE}" = "transition" ] && NEED_SCENE="yes" ;;
    TRANSITION)               NEED_SCENE="yes" ;;
    BAND_CLOCK*|RSS_*|UPDATE_NOTE_*|UPDATE_CHECK_*)
      [ "${SCENE}" = "menu" ] && demo_band ;;
    SAM_*)                    demo_head ;;
    UPDATE_ALL_*|SELF_UPDATE_*|UPDATE_DONE_*|UPDATE_FAILED_TEXT)
      [ "${SCENE}" = "busy" ] && NEED_SCENE="yes" ;;
    METADATA_FIELDS|METADATA_PINNED|COMPACT_YEAR_COMPANY|METADATA_INTERVAL|ARCADE_FIELDS|ARCADE_FIELDS_WIDE|ARCADE_PINNED|DVD_FIELDS|USE_NAMES_TXT)
      NEED_META="yes" ;;
    SHOW_METADATA|SHOW_DESCRIPTION|core_bootscreen_time|DVD_SCREEN|BOOTSCREEN_AS_MENU)
      NEED_SCENE="yes" ;;
  esac
  [ "${1}" = "${FOCUS}" ] && NEED_DEMO="yes"
}

take() {  # one line of input
  local cmd key value
  read -r cmd key value <<< "${1}"
  case "${cmd}" in
    focus)
      [ "${key}" = "${FOCUS}" ] || { FOCUS="${key}"; NEED_DEMO="yes"; } ;;
    set)
      [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
      # A setting, not just any variable; and never the port this writes to.
      case "${key}" in TTYDEV|BAUDRATE|TTYPARAM) return 0 ;; esac
      [ -n "${!key+set}" ] || return 0
      [ "${!key}" = "${value}" ] && return 0
      printf -v "${key}" '%s' "${value}"
      case " ${CHANGED[*]} " in *" ${key} "*) ;; *) CHANGED+=("${key}") ;; esac ;;
  esac
}

act() {
  local key
  NEED_SCENE="no"; NEED_META="no"
  for key in "${CHANGED[@]}"; do apply "${key}"; done
  CHANGED=()
  scene_of "${FOCUS}"
  # The description's settings want its page; leaving them, the fields again.
  local desc="no"
  case "${FOCUS}" in VSCROLL_SPEED|SHOW_DESCRIPTION) desc="yes" ;; esac
  [ "${desc}" != "${DEMO_DESC}" ] && [ "${SCENE_WANT}" = "console" ] && NEED_SCENE="yes"
  if [ "${SCENE_WANT}" != "${SCENE}" ] || [ "${NEED_SCENE}" = "yes" ]; then
    show_scene "${SCENE_WANT}"
  else
    [ "${NEED_META}" = "yes" ] && refresh_meta
    if [ "${NEED_DEMO}" = "yes" ]; then
      case "${SCENE}" in
        menu) demo_band ;;
        busy) demo_busy ;;
        console|arcade|dvd) demo_head ;;
      esac
    fi
  fi
  [ "${NEED_DEMO}" = "yes" ] && demo_focus
  NEED_DEMO="no"
}

# ---------------------------------------------------------------------------
if [ -n "${T2OP_PREVIEW_TTY:-}" ]; then
  FW_VERSION="${T2OP_PREVIEW_FW:-${TTY2OLED_VERSION:-}}"
  sendfade; sendtfade; sendcontrast
else
  ttyalias
  serialinit
  checkversion >/dev/null 2>&1
fi
sendtime; senddim; sendflip; sendscroll

TICK="${T2OP_PREVIEW_TICK:-0.2}"
while true; do
  if IFS= read -r -t "${TICK}" line; then
    take "${line}"
    # Whatever else is already waiting: a slider held down sends a run of
    # values, and only where it ended up is worth showing.
    while IFS= read -r -t 0.02 line; do take "${line}"; done
    act
  else
    [ "${?}" -gt 128 ] || break
  fi
  plan_run
done
exit 0
