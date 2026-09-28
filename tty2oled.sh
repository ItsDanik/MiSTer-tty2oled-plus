#!/bin/bash

# By venice & ojaksch
#
# 2021-01-12 First release
# 2021-01-15 Adding debug to /tmp/tty2oled, device check else part
# 2021-01-16 Change send command "echo -ne ${newcore} >" to "echo ${newcore} >" without -ne to send "\n" (newline)
#            Arduino uses now "Serial.readStringUntil('\n');"
#            Feels more responsive as Serial Read on Arduino is not waitung for the timeout (1000ms)
#            Add "raw" to tty Parameter (see stty manpage)
# 2021-01-17 Add check for readable file "/tmp/CORENAME"
# 2021-01-19 Add "First Transmission" to clear send buffer (Preventing  weird issues after PowerOn)
# 2021-02-07 Changed Speed from 9600 to 57600
# 2021-02-14 Change Timed Loop to " inotifywait -e modify "/tmp/CORENAME" ".
#            Makes it much more responsive :-)
# 2021-03-29 USB Transfer realized by ojaksch, many thanks.
#            Modified Arduino Sketch and "tty2oled" for the USB Version of tty2oled.
#            All XBM must be stored on the MiSTer in the folder "/media/fat/tty2oledpics".
#            Instead of sending the Corename the Content of the XBM is send if an XBM exists. Done with the function "senddata".
#            "senddata" checks for an existing Picture-Folder and if the Folder exists the Picture-Data (if found) or the Corename are sent.
#            If the Folder does not exist, it's assumed the "SD Version" is used and only the corename is sent.
#            Serial Interface set to 115200 Baud now.
# 2021-04-12 Added an INI file
# 2021-05-05 Added sending Contrast Value
# 2021-05-14 Adding Command Line Parameter for Testing
#            Parameter 1: /dev/ttyUSBx Device
#            Parameter 2: SD or USB Mode
#            Parameter 3: Baudrate
#            Example: /usr/bin/tty2oled /dev/ttyUSB1
#            Example: /usr/bin/tty2oled /dev/ttyUSB1 SD
#            Example: /usr/bin/tty2oled /dev/ttyUSB1 USB 921600
# 2021-06-22 New Command Mode (Testing)
#            "CMCOR,[Corename]", "CMDCON,[Contrast]",  "CMDTEX,[Parameter]", "CMDGEO,[Parmeter]", "CMDRST", "CMDOTA"
# 2021-06-24 Adding folder "/media/fat/Scripts/.tty2oled/pics_pri"
#            Pictures found in this folder will be used before the "common" pictures.
#            The User himself is responsible for the content in this Folder.
# 2021-06-30 Added new INI Option/Command for Display Rotation ("CMDROT,[Parameter]")
# 2021-07-10 Fix Baudrate CLI Parameter handling
#            Change CLI Parameter order
#            Parameter 1: /dev/ttyUSBx Device
#            Parameter 2: Baudrate
#            Parameter 3: SD or USB Mode
#            Example: /usr/bin/tty2oled /dev/ttyUSB1
#            Example: /usr/bin/tty2oled /dev/ttyUSB1 115200
#            Example: /usr/bin/tty2oled /dev/ttyUSB1 921600 USB
# 2021-07-14 Clean up Script
# 2021-09-09 Moved from /etc/init.d to /media/fat/tty2oled
# 2021-09    Grayscale pictures implemented
# 2021-10-02 Complete rework of senddata
# 2021-10-05 USE_RANDOM_ALT to choose between _altX pictures
# 2022-01-23 Bugfix: Comment the reload of INI Files in function "senddata" because command line parameter don't work
# 2022-02-10 Added ScreenSaver functionality
# 2022-04-09 Make the Daemon more quiet
# 2022-04-24 Add "settime"
# 2022-06-17 Redo/Rework of PID and inotify
# 2022-07-22 New Screensaver Mode Handling
# 2022-09-20 Support for MiSTer SAM adding the tty2oled "SleepMode"
#            Create the file "/tmp/tty2oled_sleep" by using "touch /tmp/tty2oled_sleep" and the tty2oled Dameon goes to sleep.
#            Remove the file and the tty2oled Daemon goes back to work.
# 2023-12-06 Adding SLEEPMODEDELAY for better SAM Support
# 2023-12-07 Adding compatibility for tty2x
#
#

# 2026-09-23 Removed upstream's screensaver and SD mode (fork)
#            The screensaver reset its idle timer only from the picture paths,
#            so a metadata screen never reset it and never came back once it
#            fired; dimming and FLIP_MINUTES are the burn-in protection now.
#            SD mode gated every feature this fork has behind USBMODE and spoke
#            a protocol no sketch in this repository implements.
#
# 2026-09-20 Game metadata display (fork)
#            Sends per-game metadata ahead of the picture so the display can
#            show arcade info cards and the console split layout.
#            Requires "log_file_entry=1" in MiSTer.ini for anything beyond
#            core-level display; see tty2oled-meta.sh for why.
#
#

. /media/fat/tty2oledplus/tty2oled-system.ini
. /media/fat/tty2oledplus/tty2oled-user.ini
. /media/fat/tty2oledplus/tty2oled-meta.sh
cd /tmp


# Debug function
dbug() {
  if [ "${debug}" = "true" ]; then
    if [ ! -e ${debugfile} ]; then # log file not (!) exists (-e) create it
      echo "---------- tty2oled Debuglog ----------" >${debugfile}
    fi
    echo "${1}" >>${debugfile} # output debug text
    echo "${1}"
  fi
}

# The wait after a single-line command, as opposed to after a picture header.
# The firmware acknowledges a command after cDelay, which is 15ms; WAITSECS at
# 0.2 was three times the round trip of everything in the startup handshake put
# together. Falls back to WAITSECS when the ini predates the setting.
cmdwait() { sleep "${CMDWAITSECS:-${WAITSECS}}"; }

# How long the firmware takes over any brightness change. Sent before the first
# CMDCON, so that one fades at the user's speed too rather than the firmware's
# default.
sendfade() {
  dbug "Sending: CMDFADE,${CONTRAST_FADE_MS:-800}"
  echo "CMDFADE,${CONTRAST_FADE_MS:-800}" >${TTYDEV}
  cmdwait
}

# The Fade transition's timings. Sent before the first picture, which may be
# the first thing to use them.
sendtfade() {
  dbug "Sending: CMDTFADE,${TRANSITION_FADE_MS:-800},${TRANSITION_BLANK_MS:-1000}"
  echo "CMDTFADE,${TRANSITION_FADE_MS:-800},${TRANSITION_BLANK_MS:-1000}" >${TTYDEV}
  cmdwait
}

# Send Contrast-Data function
sendcontrast() {
  dbug "Sending: CMDCON,${CONTRAST}"
  echo "CMDCON,${CONTRAST}" >${TTYDEV} # Send Contrast Command and Value
  cmdwait
}

# Rotate Display function
sendrotation() {
  if [ "${ROTATE}" = "yes" ]; then
      dbug "Sending: CMDROT,1"
      echo "CMDROT,1" >${TTYDEV} # Send Rotation if set to "yes"
      cmdwait
      # The re-show used to be followed by "sleep 4" to let its animation run.
      # It no longer needs one: the start screen now ends the moment the next
      # command arrives, so the rotated boot screen stays up for exactly as
      # long as it takes the first core picture to be ready, and not a second
      # of it is spent waiting on a panel nobody is looking at any more.
      echo "CMDSORG" >${TTYDEV} # Show Start Screen rotated
      cmdwait
    #else
    #  dbug "Sending: CMDROT,0" > ${TTYDEV}
    #  echo "CMDROT,0" > ${TTYDEV}						# No Rotation
    #  sleep ${WAITSECS}
    #  echo "CMDSORG" > ${TTYDEV}						# Show Start Screen rotated
    #  sleep 4
  fi
}

# Locate a core's 256x64 banner, and set BANNERFILE to it. Returns 1 when
# there is none, which is the caller's cue to send the core name as text.
#
# Two folders hold banners since 0.5.8b: pics/banner, the release's, which
# every update replaces, and pics/user, yours, which no update ever touches.
# PRIORITIZE_USER_BANNERS decides which is searched first and the other is the
# fallback. One artwork format, one folder each: upstream searched five -
# GSC_US, XBM_US, GSC, XBM, XBM_TEXT - because .gsc was a later addition that
# never finished replacing the 1bpp .xbm it was introduced beside. This fork
# finished it (CHANGELOG 0.4.10b) and then flattened what was left.
#
# The core name is trimmed a character at a time until something matches, so a
# core whose name carries a suffix still finds the base picture. The trimming
# runs per folder rather than across both, which makes the priority absolute:
# a banner of yours for a shorter prefix beats the pack's longer match, rather
# than the most specific filename winning wherever it happens to live. That is
# what PRIORITIZE_USER_BANNERS says on the tin, and the alternative is a rule
# nobody could predict from the setting's name - your MegaDrive.gsc quietly
# ignored because the pack happens to ship a MegaDriveX.
#
# "exact" turns the trimming off, for the names that are looked up whole:
# update_all is one, and the prefix search would happily settle on some
# unrelated banner starting with "upd".
findbanner() {
  local core="${1}" mode="${2:-}" first="${userbannerfolder}" second="${bannerfolder}" d
  BANNERFILE=""
  [ -n "${core}" ] || return 1
  if [ "${PRIORITIZE_USER_BANNERS:-yes}" != "yes" ]; then
    first="${bannerfolder}"; second="${userbannerfolder}"
  fi
  for d in "${first}" "${second}"; do
    bannerin "${d}" "${core}" "${mode}" && return 0
  done
  return 1
}

# One folder of findbanner's: the whole name, then shorter and shorter
# prefixes of it unless "exact". Sets BANNERFILE.
bannerin() {
  local d="${1}" core="${2}" mode="${3:-}" c
  BANNERFILE=""
  [ -n "${d}" ] && [ -n "${core}" ] || return 1
  if [ "${mode}" = "exact" ]; then
    [ -e "${d}/${core}.gsc" ] && { BANNERFILE="${d}/${core}.gsc"; return 0; }
    return 1
  fi
  for ((c = "${#core}"; c >= 1; c--)); do
    [ -e "${d}/${core:0:$c}.gsc" ] && { BANNERFILE="${d}/${core:0:$c}.gsc"; return 0; }
  done
  return 1
}

# An arcade set's wheel logo in the pack: sets WHEELFRAME to its frame in
# ${wheelpack}, 8192 bytes at frame * 8192. Returns 1 when the pack does not
# have the set, or the frame is not in the .bin beside the index.
#
# The whole name, lower-cased as the index is - never trimmed. Two thirds of
# the MAME sets share their picture with another, and trimming a name finds a
# different game's wheel for hundreds of them (hook_408 -> hook); the index
# lists every set, so a set it lacks is a set the pack has no picture for.
# awk rather than grep, so an MRA's set name is never a regex.
findwheel() {
  local key="${1,,}" frame size
  WHEELFRAME=""
  [ -n "${key}" ] && [ -r "${wheelindex}" ] && [ -r "${wheelpack}" ] || return 1
  frame="$(awk -F'|' -v c="${key}" '$1 == c { print $2; exit }' "${wheelindex}" 2>/dev/null)"
  [[ "${frame}" =~ ^[0-9]+$ ]] || return 1
  # An index from one run beside a pack from another would cut a picture out
  # of the middle of two, or read past the end - which the firmware waits
  # forever to finish. Checked against the .bin actually there.
  size="$(stat -c %s "${wheelpack}" 2>/dev/null)"
  [ -n "${size}" ] && [ $(((frame + 1) * 8192)) -le "${size}" ] || return 1
  WHEELFRAME="${frame}"
}

# What kind of core this is - arcade, console, computer, unknown - into
# CORE_KIND, without touching META_KIND: the picture has to know whether to
# look in the wheel pack whether or not the metadata display is on.
core_kind() {
  local META_KIND="" CORE_STARTPATH=""
  classify_core "${1}"
  CORE_KIND="${META_KIND}"
}

# Where a core's picture comes from. Sets PICFILE, a .gsc, or PICFRAME, a
# frame of the wheel pack; returns 1 with neither, which is the caller's cue
# to send the core name as text.
#
# An arcade core is a game, and its picture is that game's wheel logo, looked
# up by the MRA's set name - which MiSTer writes to CORENAME. pics/banner is
# never searched for one: since the arcade marquees went, it holds console
# and computer banners only, and trimming a set name down into those could
# only ever find the wrong picture. pics/user is, first by default, so your
# own picture for a set beats the pack.
findpicture() {
  local core="${1}"
  PICFILE=""; PICFRAME=""
  core_kind "${core}"
  if [ "${CORE_KIND}" != "arcade" ]; then
    # Degauss is not a core, and its name is looked up whole, as update_all's
    # is: trimmed, any banner named for a prefix of it (deg.gsc) would stand
    # in for it instead of the name as text.
    local mode=""
    [ "${core}" = "${DEGAUSS_CORE}" ] && mode="exact"
    findbanner "${core}" "${mode}" && PICFILE="${BANNERFILE}"
    [ -n "${PICFILE}" ]; return
  fi
  if [ "${PRIORITIZE_USER_BANNERS:-yes}" = "yes" ]; then
    if bannerin "${userbannerfolder}" "${core}"; then PICFILE="${BANNERFILE}"
    elif findwheel "${core}"; then PICFRAME="${WHEELFRAME}"; fi
  else
    if findwheel "${core}"; then PICFRAME="${WHEELFRAME}"
    elif bannerin "${userbannerfolder}" "${core}"; then PICFILE="${BANNERFILE}"; fi
  fi
  [ -n "${PICFILE}${PICFRAME}" ]
}

# Send-Picture-Data function
senddata() {
  newcore="${1}"
  local picdraw="CMDCOR" hold="no"

  # Off, the picture, the hold, and only then the game's details.
  #
  # The firmware acts on each command as it lands - loop() runs between any
  # two of them - so a CMDMETA sent first had the transition to the split
  # layout under way before the CMDCBOOT saying "artwork first" had arrived.
  # A core launched with its game (a frontend, a .mgl, Recents) showed the old
  # screen start to fade, froze it for the picture's blocking 8KB read, then
  # jumped to black and faded the artwork in. Picture first, the panel simply
  # holds still while it transfers; everything after it lands during the
  # artwork's transition, which the firmware waits out before drawing again.
  if [ "${SHOW_METADATA}" = "yes" ]; then
    build_meta "${newcore}" corechange
    # Off first, always: the core has changed, so whatever layout the
    # firmware holds is the previous game's, and the picture below must go up
    # as a picture rather than be composed into it.
    sendmetaoff
    if coreboot_ms >/dev/null; then
      hold="yes"
    elif [ "${META_KIND}" = "console" ] && [ "${META_GAME:-no}" = "yes" ]; then
      # No hold, and the layout is due at once: store the picture without
      # drawing it (upstream's CMDAPD), so the only transition is the one to
      # the layout. Drawn, the artwork would fade in only to fade out again.
      picdraw="CMDAPD"
    fi
  fi

  # The menu's picture is the boot screen, which lives on the display - so
  # there is nothing to send but the request. At power-on the boot screen is
  # already on the panel and the firmware leaves it there; later, returning
  # to the menu transitions to it like any other core picture.
  if [ "${BOOTSCREEN_AS_MENU:-yes}" = "yes" ] && [ "${newcore}" = "MENU" ]; then
    dbug "Sending: CMDBOOTPIC,${newcore},${TRANSITION}"
    echo "CMDBOOTPIC,${newcore},${TRANSITION}" >${TTYDEV}
    cmdwait
  elif findpicture "${newcore}"; then
    # A frontend's picture is 54 rows with the band under it (frontend_core).
    local band=""
    [ -n "${PICFILE}" ] && frontend_core "${newcore}" && band=",band"
    dbug "Sending: ${picdraw},${1},${TRANSITION}${band} (${PICFILE:-wheel ${PICFRAME}})"
    echo "${picdraw},${1},${TRANSITION}${band}" >${TTYDEV}  # Send CORECHANGE" Command and Corename
    sleep ${WAITSECS}                              # sleep needed here ?!
    if [ -n "${PICFRAME}" ]; then                  # A wheel: its 8192 bytes, cut out of the pack
      dd if="${wheelpack}" bs=8192 skip="${PICFRAME}" count=1 2>/dev/null >${TTYDEV}
    elif [ -n "${band}" ]; then
      # The top 54 rows, whether the file is 256x54 or a 256x64 banner, and
      # the band's 1280 bytes black - as one stream, so the firmware reads
      # exactly 8192 bytes. A 256x54 file sent as it is would be 6912, and
      # the firmware would wait out its timeout for the rest.
      { tail -n +4 "${PICFILE}" | xxd -r -p | head -c 6912; head -c 1280 /dev/zero; } >${TTYDEV}
    else
      tail -n +4 "${PICFILE}" | xxd -r -p >${TTYDEV} # The Magic, send the Picture-Data up from Line 4 and process
    fi
  elif [ "${picdraw}" = "CMDCOR" ]; then           # No Picture available!
    echo "${1}" >${TTYDEV}                           # Send just the CORENAME
  fi                                                 # End if Picture check

  # After the picture, so none of it can start a transition ahead of it.
  if [ "${SHOW_METADATA}" = "yes" ]; then
    # The hold before the game, or the layout would be drawn unheld; and
    # after the picture, because the firmware starts its clock on the first
    # tick that finds the panel idle. Sent ahead of the picture, that was the
    # 50ms gap before CMDCOR, and the transfer and a Fade ate the whole hold -
    # the artwork faded in and straight back out.
    [ "${hold}" = "yes" ] && sendcoreboot
    # CMDMETAOFF went out above, so a game's line always differs from the
    # last one sent and a core with no game sends nothing more.
    sendbuiltmeta && sendicon "${META_ICON}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Metadata support (fork additions)
# ---------------------------------------------------------------------------

# Strip the characters that would break the CMDMETA wire format, plus anything
# non-printable that could desynchronise the serial stream.
metasanitize() {
  local s="${1}"
  s="${s//|/ }"       # field separator
  s="${s//,/ }"       # command separator
  s="${s//=/ }"       # label/value separator
  s="$(printf '%s' "${s}" | tr -d '\000-\037\177')"
  printf '%s' "${s}"
}

# Map META_KIND onto the numeric kind the firmware expects.
metakindnum() {
  case "${1}" in
    arcade)   printf '1' ;;
    console)  printf '2' ;;
    computer) printf '3' ;;
    *)        printf '0' ;;
  esac
}

# Locate the 86x64 console icon for a core. One folder, pics/icon, named by
# core name - not by the display name, which is why META_ICON is set from
# CORENAME rather than from display_corename.
#
# There is no user override folder for icons the way there is for banners:
# pics/user holds 256x64 banners named after the core, and an 86x64 icon of
# the same name in there would be indistinguishable from one until the
# firmware read 2752 bytes of an 8192-byte picture.
findicon() {
  local key="${1}"
  ICONFILE=""
  [ -n "${key}" ] || return 1
  [ -e "${iconfolder}/${key}.gsc" ] || return 1
  ICONFILE="${iconfolder}/${key}.gsc"
  return 0
}

# Send CMDMETA for the current game. Returns 1 if metadata mode is not active
# so the caller can fall back to plain picture display.
#
# For a game change within a running core. A core change builds the metadata
# itself, because the picture has to go out between building and sending it -
# see senddata.
sendmeta() {
  [ "${SHOW_METADATA}" = "yes" ] || return 1
  build_meta "${1}"
  sendbuiltmeta
}

# Leave metadata mode on the firmware, and remember that it has been left.
sendmetaoff() {
  dbug "Sending: CMDMETAOFF (kind=${META_KIND} game=${META_GAME:-no})"
  echo "CMDMETAOFF" >${TTYDEV}
  sleep ${WAITSECS}
  META_WIRE_LAST="OFF"
}

# Put what build_meta produced on the wire: CMDMETA and the description, or
# CMDMETAOFF when there is no game to describe. Nothing at all when it would
# repeat the last thing sent.
sendbuiltmeta() {
  local kindnum="" payload="" label="" value="" f="" wire=""

  # Computer cores stay on plain full-screen artwork by design, and so does a
  # console core sitting at its menu with no game loaded - there is nothing to
  # describe, and the core's artwork is the better screen.
  if [ "${META_KIND}" = "computer" ] || [ "${META_KIND}" = "unknown" ] ||
     [ "${META_GAME:-no}" != "yes" ]; then
    [ "${META_WIRE_LAST:-}" != "OFF" ] && sendmetaoff
    return 1
  fi

  kindnum="$(metakindnum "${META_KIND}")"
  payload="$(metasanitize "${META_TITLE}")"

  for f in "${META_FIELDS[@]}"; do
    label="${f%%$'\t'*}"
    value="${f#*$'\t'}"
    payload="${payload}|$(metasanitize "${label}")=$(metasanitize "${value}")"
  done

  # The two counts go between the interval and the title: how many fields are
  # pinned, and how many of them the arcade card pairs two to a row (0 for a
  # console, which has one field per row by construction). metasanitize strips
  # commas from the title and every value, so each extra comma is unambiguous
  # and a firmware that predates either count simply reads the title from
  # where that count starts.
  wire="CMDMETA,${kindnum},${METADATA_INTERVAL},${META_PINNED_COUNT:-0},${META_COMPACT_COUNT:-0},${payload}"
  # The description goes out as its own transfer after the line, and the
  # firmware drops it on every CMDMETA - so it is part of what "unchanged"
  # means, or a game whose description arrived late would never show it.
  local sent="${wire}${META_DESC:+|DESC|${META_DESC}}"

  # The daemon now also wakes on game-state changes, and MiSTer rewrites those
  # files while the user is merely browsing. Resending an identical line would
  # restart the card's scroll and animation for no reason, so send only what
  # actually changed. A core change always sends: senddata's CMDMETAOFF has
  # just reset the firmware, and set META_WIRE_LAST to say so.
  if [ "${sent}" = "${META_WIRE_LAST:-}" ]; then
    dbug "Metadata unchanged, not resending"
    return 1
  fi

  dbug "Sending: ${wire}"
  echo "${wire}" >${TTYDEV}
  sleep ${WAITSECS}
  senddesc
  META_WIRE_LAST="${sent}"
  return 0
}

# The description page's text, for a console or arcade game an imported
# gamelist described.
#
# CMDDESC,<bytes> and then exactly that many bytes, like an icon: at up to
# two kilobytes it is longer than the rest of the metadata put together, and a
# line that long could overflow the firmware's 256-byte serial buffer while
# it is busy animating. Printable ASCII only - the importer already folds
# accents away, and the firmware counts a byte as a character when it wraps.
DESC_MAX_BYTES=2048   # the firmware's DESC_MAX, and the importer's
senddesc() {
  local text=""
  case "${META_KIND}" in console|arcade) ;; *) return 1 ;; esac
  [ -n "${META_DESC:-}" ] || return 1
  text="$(printf '%s' "${META_DESC}" | LC_ALL=C tr -c ' -~' ' ' | LC_ALL=C tr -s ' ')"
  text="${text:0:${DESC_MAX_BYTES}}"
  [ -n "${text// /}" ] || return 1
  dbug "Sending: CMDDESC,${#text}"
  echo "CMDDESC,${#text}" >${TTYDEV}
  sleep ${WAITSECS}
  printf '%s' "${text}" >${TTYDEV}
  sleep ${WAITSECS}
  return 0
}

# Refresh metadata without redrawing the artwork. Used when the game changed
# but the core did not - loading a ROM does not touch /tmp/CORENAME, so there
# is nothing to redraw, only new text to send.
refreshmeta() {
  local corename="${1}"
  if sendmeta "${corename}"; then
    sendicon "${META_ICON}"
  fi
  return 0
}

# The state files MiSTer publishes, filtered to those that exist. Watching a
# missing file makes inotifywait exit immediately, which would spin the loop.
metawatchlist() {
  local f="" out=""
  for f in "${corenamefile}" "${MISTER_FULLPATH}" "${MISTER_FILESELECT}" \
           "${MISTER_GAMEID}" "${MISTER_STARTPATH}"; do
    [ -e "${f}" ] && out="${out} ${f}"
  done
  printf '%s' "${out# }"
}

# Send the 86x64 console icon, if one exists for this core.
sendicon() {
  local key="${1}"
  [ "${META_KIND}" = "console" ] || return 1
  findicon "${key}" || { dbug "No icon for ${key}"; return 1; }

  dbug "Sending: CMDICON (${ICONFILE})"
  echo "CMDICON" >${TTYDEV}
  sleep ${WAITSECS}
  tail -n +4 "${ICONFILE}" | xxd -r -p >${TTYDEV}
  sleep ${WAITSECS}
  return 0
}

# How long this core change holds the core's artwork, in ms; fails when it
# holds nothing - not a console core, or core_bootscreen_time 0 or not a number.
coreboot_ms() {
  local ms="${core_bootscreen_time:-3000}"
  [ "${META_KIND}" = "console" ] || return 1
  case "${ms}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${ms}" -gt 0 ] || return 1
  printf '%s' "${ms}"
}

# Ask the firmware to hold the core's own artwork before the game's layout
# replaces it - the core boot screen.
#
# Sent only from senddata, which runs on a core change, and only for a console
# core - the only kind with a layout that would otherwise cover the artwork.
#
# Deliberately not conditional on the game being known yet. MiSTer usually
# publishes the core first and the game a second or two later, so at this point
# the daemon has nothing to show but the core; the hold is what guarantees the
# artwork a minimum time on the panel whenever the game does turn up. It runs
# from the moment the artwork reaches the panel, so a game that arrives after
# it has already expired is drawn at once and nothing is delayed.
#
# It goes out after the picture, never before: the firmware stamps the start
# of the hold on the first tick that finds the panel idle, and ahead of the
# picture that is before the transfer has even begun.
#
# Deciding here rather than in the firmware is the point. Only the daemon can
# tell a core change from a game change; only the firmware knows when the
# transition finished and the artwork is actually on the panel. Send nothing
# and there is no hold, which is what core_bootscreen_time=0 does.
sendcoreboot() {
  local ms
  ms="$(coreboot_ms)" || return 1
  dbug "Sending: CMDCBOOT,${ms}"
  echo "CMDCBOOT,${ms}" >${TTYDEV}
  cmdwait
  return 0
}

# Tell the firmware how to dim and how often to swap sides. Both are firmware
# behaviour running off its own clock, so they are sent once at startup rather
# than driven from here.
senddim() {
  # DIM_PERCENT was a share of CONTRAST; DIM_CONTRAST is a level of its own.
  # The system ini no longer sets the old name, so if it is set at all it came
  # from the user's own ini - and would otherwise be ignored without a word.
  if [ -n "${DIM_PERCENT:-}" ]; then
    echo "tty2oled: DIM_PERCENT is gone - set DIM_CONTRAST (0..255) in tty2oled-user.ini instead. Using ${DIM_CONTRAST:-80}."
  fi
  dbug "Sending: CMDDIM,${DIM_AFTER:-120},${DIM_CONTRAST:-80},${DIM_WAKE:--1},${DIM_FADE_MS:-6000}"
  echo "CMDDIM,${DIM_AFTER:-120},${DIM_CONTRAST:-80},${DIM_WAKE:--1},${DIM_FADE_MS:-6000}" >${TTYDEV}
  cmdwait
}

# How fast the title marquee and the description move, in pixels a second.
sendscroll() {
  dbug "Sending: CMDSCROLL,${HSCROLL_SPEED:-25},${VSCROLL_SPEED:-6}"
  echo "CMDSCROLL,${HSCROLL_SPEED:-25},${VSCROLL_SPEED:-6}" >${TTYDEV}
  cmdwait
}

sendflip() {
  local secs=$(( ${FLIP_MINUTES:-5} * 60 ))
  dbug "Sending: CMDFLIP,${secs}"
  echo "CMDFLIP,${secs}" >${TTYDEV}
  cmdwait
}

# The scripts and the firmware carry the same version and are meant to be
# flashed together, so the first useful thing the log can say is whether they
# actually are. The firmware answers CMDHWINF with "HW<board>;<version>;" and
# acknowledges every other command with "ttyack;", so read ';'-delimited
# tokens - upstream's own idiom - until the board id turns up.
checkversion() {
  local tok="" fwver="" tries=0
  exec 3<"${TTYDEV}" || { dbug "Cannot open ${TTYDEV} for reading"; return 0; }
  echo "CMDHWINF" >${TTYDEV}
  while [ "${tries}" -lt 8 ]; do
    tries=$((tries + 1))
    read -t 2 -d ';' tok <&3 || break
    tok="${tok//[[:space:]]/}"
    case "${tok}" in
      HW*)
        read -t 2 -d ';' fwver <&3 || true
        fwver="${fwver//[[:space:]]/}"
        break
        ;;
    esac
  done
  exec 3<&-

  FW_VERSION="${fwver}"
  if [ -z "${fwver}" ]; then
    echo "tty2oled+ ${TTY2OLED_VERSION:-unknown} (the display did not answer CMDHWINF)"
    dbug "No CMDHWINF reply after ${tries} tokens"
    return 0
  fi

  if [ "${fwver}" = "${TTY2OLED_VERSION:-}" ]; then
    echo "tty2oled+ ${TTY2OLED_VERSION}, firmware ${fwver}"
  else
    echo "tty2oled+ ${TTY2OLED_VERSION:-unknown}, firmware ${fwver} - VERSIONS DIFFER"
    echo "tty2oled: the two ship together. Reflash with:  ./tools/deploy-mister.sh --firmware --flash"
  fi
  dbug "Script version ${TTY2OLED_VERSION:-unknown}, firmware version ${fwver}"
}

# Is the display's firmware at least <version>? Ours is always N.N.N with a
# letter or two after it; upstream's is a date with no dots, and an unanswered
# CMDHWINF is empty - both are "no", which is the safe answer: a command the
# firmware does not know is drawn on the panel as text.
FW_VERSION=""
fw_atleast() {  # fw_atleast 0.7.0
  local have="${FW_VERSION:-}" want="${1}" h=() w=() i
  [[ "${have}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)[A-Za-z]*$ ]] || return 1
  h=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  [[ "${want}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  w=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  for i in 0 1 2; do
    [ "$((10#${h[i]}))" -gt "$((10#${w[i]}))" ] && return 0
    [ "$((10#${h[i]}))" -lt "$((10#${w[i]}))" ] && return 1
  done
  return 0
}

# The rest of the startup handshake, run once the first core picture is on the
# panel rather than in front of it. None of it changes what that picture looks
# like: the version check is a log line, and the time, dimming and side-swap
# settings are all firmware behaviour on the firmware's own clock,
# minutes away from mattering. Together they cost a second of sleeps, and
# checkversion alone blocks for up to two more when the display is still
# booting and cannot answer CMDHWINF yet.
DEFERRED_DONE="no"
deferred_setup() {
  [ "${DEFERRED_DONE}" = "yes" ] && return 0
  DEFERRED_DONE="yes"

  # The alternative banners went with the arcade marquees, and the dice
  # between them with them. The system ini sets neither name any more, so one
  # that is set came from the user's own ini - and a user who asked for the
  # dice deserves to be told they are not being rolled.
  if [ -n "${RANDOMIZE_ALT_BANNERS:-}${USE_RANDOM_ALT:-}" ]; then
    echo "tty2oled: RANDOMIZE_ALT_BANNERS is gone - there are no alternative banners any more. It can be removed from tty2oled-user.ini."
  fi
  # The update that brings the wheel pack is applied by the previous
  # updater, which decides whether to fetch the artwork by asking whether
  # pics/banner exists - so it does not. Until the next Update, every arcade
  # core shows its name as text, and this is where that is explained.
  if ! [ -r "${wheelindex}" ] || ! [ -r "${wheelpack}" ]; then
    echo "tty2oled: the arcade wheel logos (${wheelindex%/*}) are missing - arcade cores show their name as text. Run Update from the tty2oledplus menu to fetch them."
  fi

  checkversion												# Scripts and firmware in step?
  sendtime													# Set time and date
  senddim													# Set idle dimming
  sendflip													# Set console side swapping
  sendscroll												# Set marquee and description speeds

  # Metadata needs MiSTer to publish its state files. That is off by default,
  # so say so once rather than silently showing core-level info forever.
  if [ "${SHOW_METADATA}" = "yes" ] && [ "${METADATA_WARN}" = "yes" ]; then
    check_mister_ini
    if [ "${MISTER_LOGFILEENTRY}" = "no" ]; then
      echo "tty2oled: game metadata is enabled but 'log_file_entry=1' is missing from ${MISTER_INI}."
      echo "tty2oled: without it MiSTer does not publish the loaded game, so only core names will show."
      dbug "log_file_entry not enabled - metadata limited to core level"
    fi
  fi
  return 0
}

sendtime() {
  timeoffset=$(date +%:::z)
  localtime=$(date '-d now '${timeoffset}' hour' +%s)
  echo "CMDSETTIME,${localtime}" >${TTYDEV}
  cmdwait
}

# Bring the serial port up: line settings, the buffer-clearing first
# transmission, and the two settings the first picture depends on. Factored out
# of the main block because a display that is unplugged and put back needs
# exactly this again - see serialready.
serialinit() {
  dbug "${TTYDEV} detected, setting Parameter: ${BAUDRATE} ${TTYPARAM}."
  stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}     # set tty parameter
  cmdwait
  echo "QWERTZ" >${TTYDEV}                      # First Transmission to clear serial send buffer
  dbug "Send QWERTZ as first transmission"
  cmdwait

  # Only what the first picture actually depends on runs before it. Contrast,
  # because the artwork would otherwise be drawn at the boot screen's level and
  # pop a moment later, and rotation, because it would arrive the wrong way up.
  # Everything else waits (see deferred_setup): none of it changes what that
  # picture looks like, and every second spent on it is a second of boot screen.
  sendfade													# How brightness changes move
  sendtfade													# ...and the Fade transition
  sendcontrast												# Set Contrast
  sendrotation												# Set Display Rotation
}

# Is the display still there, and if it has just come back, start it again.
#
# The device node goes away when the ESP is unplugged, when the USB bus re-
# enumerates it, and when a flash resets the board. Every "echo >${TTYDEV}"
# after that fails, silently, one per command: the loop carries on, the panel
# keeps whatever was last drawn on it, and nothing recovers until somebody
# restarts the daemon. The check used to run once, in front of the loop, so a
# display that was fine at boot was assumed to be fine forever.
#
# Returns 1 when the caller should skip this pass - either the port is absent,
# in which case this call is also the loop's only brake, or it has just been
# re-opened and what the panel shows is no longer what we think we sent.
TTYGONE="no"
serialready() {
  if ! [ -c "${TTYDEV}" ]; then
    [ "${TTYGONE}" = "no" ] && dbug "${TTYDEV} has gone away, waiting for the display"
    TTYGONE="yes"
    sleep "${TTYWAIT:-2}"
    return 1
  fi

  [ "${TTYGONE}" = "no" ] && return 0

  # Back. A re-enumerated board has rebooted into its boot screen with the
  # firmware's own defaults, and the line settings went with the old device
  # node, so this is the startup handshake over again rather than a resume.
  TTYGONE="no"
  dbug "${TTYDEV} is back, re-initialising the display"
  serialinit
  # Nothing on the panel came from us any more. Clearing all three is what
  # makes the next pass a full redraw: oldcore forces the core picture and its
  # icon, META_WIRE_LAST defeats the identical-line check in sendmeta, and
  # DEFERRED_DONE re-sends the time, dimming and side swap, all of
  # which lived in the RAM the reset cleared. The update_all screen and its
  # busy bar went with it too, so they are shown again if it is still running.
  oldcore=""
  META_WIRE_LAST=""
  DEFERRED_DONE="no"
  UPDATEALL_SHOWN="no"
  UPDATEALL_BUSY="no"
  NOTE_SENT="?"
  return 1
}

# Wait for MiSTer to publish /tmp/CORENAME.
#
# Every branch of the main loop ends in something that blocks - an inotifywait,
# or the sleep above - because a loop that does not block is a loop that eats a
# core. The branch for a missing CORENAME used to end in nothing at all, and
# the file really can be missing: S60tty2oled waits for the serial device but
# not for MiSTer's Main, so the daemon can reach the loop first. The spin then
# lasted until Main wrote the file, and with debug="true" it wrote the same
# line into /tmp for the whole of it.
#
# Watching the directory rather than the file is the point - inotifywait on a
# path that does not exist returns immediately, which is the spin again.
waitforcorename() {
  local dir="" rc=0
  [ -r "${corenamefile}" ] && return 0

  dbug "File ${corenamefile} not found, waiting for it"
  dir="$(dirname "${corenamefile}")"
  if [ "${debug}" = "false" ]; then
    inotifywait -qq -t "${CORENAME_WAIT:-5}" -e create,moved_to,modify "${dir}" 2>/dev/null
  else
    inotifywait -t "${CORENAME_WAIT:-5}" -e create,moved_to,modify "${dir}"
  fi
  rc=$?

  # 0 is an event and 2 is the timeout; both have already waited. Anything else
  # is inotifywait failing and returning at once - an unwatchable directory, or
  # no inotify-tools at all - and that is the spin a third time.
  [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ] || sleep "${CORENAME_WAIT:-5}"
  return 1
}

# ---------------------------------------------------------------------------
# Sleep mode: something else has claimed the display
# ---------------------------------------------------------------------------
#
# ${SLEEPFILE} is a mutex, not a courtesy. MiSTer SAM drives the panel itself:
# its own module, Scripts/.MiSTer_SAM/MiSTer_SAM_tty2oled, sources this ini to
# learn TTYDEV and then writes CMDCOR, CMDTXT, CMDCLST and raw picture bytes
# straight to the port - and reads the acks back off it. Two writers pushing
# 8KB payloads and both consuming one ack stream is the waitforack corruption
# upstream chased through three rounds of cDelay tuning. So while the file is
# there this daemon does not touch the port at all.
#
# SAM takes it in tty_start, before it launches its module, and releases it in
# tty_exit, after it kills it.

# Has the holder gone away without releasing it?
#
# SAM writes an epoch deadline into the file - the running game's start, plus
# its timer, plus ten seconds - and rewrites it on every game change. Nothing
# has ever read it, on either side. Without it, a SAM that is killed, crashes
# or loses power leaves the file behind and this daemon waits on a delete that
# never comes: the panel keeps whatever SAM last drew until somebody removes
# the file by hand or restarts the daemon.
#
# The deadline only covers the game that was running when it was written, so it
# falls due during any slow core load while SAM is perfectly healthy - a CD
# game, a big core. SLEEP_STALE_GRACE is the margin on top of it, and it wants
# to be generous: releasing early hands the port back to two writers, which is
# the thing the file exists to prevent. Waiting too long only costs a display
# that was already frozen a little more time.
#
# A file with no usable number in it - upstream's own "touch", or anything
# else that borrows the mechanism - has no deadline and is waited on for ever,
# exactly as before.
sleepmode_expired() {
  local deadline="" now="${EPOCHSECONDS:-$(date +%s)}"
  deadline="$(head -c 32 "${SLEEPFILE}" 2>/dev/null | tr -dc '0-9')"
  [ -n "${deadline}" ] || return 1
  [ "${now}" -gt "$(( deadline + ${SLEEP_STALE_GRACE:-60} ))" ]
}

# One pass of the main loop while the display belongs to somebody else.
# Returns 1 when it is ours again; the caller then runs a normal pass.
sleepmode_pass() {
  local rc=0
  [ -f "${SLEEPFILE}" ] || return 1

  if sleepmode_expired; then
    echo "tty2oled: ${SLEEPFILE} is past its deadline by more than ${SLEEP_STALE_GRACE:-60}s - taking the display back."
    dbug "Stale ${SLEEPFILE}, removing it and resuming"
    rm -f "${SLEEPFILE}"
    return 1
  fi

  [ "${SLEEPING:-no}" = "yes" ] || dbug "The tty2oled daemon is sleeping!"
  SLEEPING="yes"

  # The wait has to time out, or the deadline above is never re-read. Same
  # exit-code guard as waitforcorename: 0 is the delete and 2 the timeout, and
  # both have already waited. Anything else is inotifywait returning at once -
  # an unwatchable path, or no inotify-tools at all - and a branch of this loop
  # that does not block is a branch that eats a core. That it did not spin
  # before was an accident of the settling sleep below sitting under it.
  if [ "${debug}" = "false" ]; then
    inotifywait -qq -t "${SLEEP_POLL:-5}" -e delete "${SLEEPFILE}" 2>/dev/null
  else
    inotifywait -t "${SLEEP_POLL:-5}" -e delete "${SLEEPFILE}"
  fi
  rc=$?
  [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ] || sleep "${SLEEP_POLL:-5}"

  # Still held: go round again rather than settling and redrawing.
  [ -f "${SLEEPFILE}" ] && return 0

  # Released. SLEEPMODEDELAY is a settling delay, not a poll interval: at the
  # moment the file goes the holder is still finishing up, and /tmp/CORENAME
  # may hold a core that is on its way out rather than the one we are about to
  # be looking at.
  sleep "${SLEEPMODEDELAY:-2}"
  SLEEPING="no"

  # Nothing on the panel came from us. SAM has been drawing its own pictures
  # and text over everything for the whole session, and signs off with
  # CMDSWSAVER,1 and a CMDCLST - so the screensaver is on whatever SAM wanted
  # rather than whatever the ini says, and the firmware's metadata state is
  # whatever it was left as. Clearing all three is what makes the next pass a
  # full redraw, exactly as a re-enumerated display gets in serialready.
  dbug "${SLEEPFILE} is gone, redrawing everything"
  oldcore=""
  META_WIRE_LAST=""
  DEFERRED_DONE="no"
  NOTE_SENT="?"
  return 1
}

# ---------------------------------------------------------------------------
# Degauss: a frontend that is not a core
# ---------------------------------------------------------------------------
#
# MisterZine is launched as a core (MisterZine.mgl), so MiSTer writes its name
# to CORENAME and its banner is found like any other. Degauss is a Scripts
# entry: it draws over the menu core and CORENAME says MENU the whole time.
# All MiSTer writes is the selection of the script - CURRENTPATH "degauss",
# FULLPATH "Scripts" - which outlives it, so the process is the only sign.
# While the menu core is up and Degauss runs, the daemon takes "degauss" for
# the core: degauss.gsc by that exact name, else the name as text. When it
# exits the core is MENU again, and the menu's picture goes back up like any
# other core change. A game it launches changes CORENAME as usual.
DEGAUSS_CORE="degauss"

# Is the Degauss frontend running? Its binary, by argv[0]:
# Scripts/.config/degauss/degauss, or Scripts/.degauss/degauss where v0.1.0
# and v0.2.0 installed it. Only argv[0]: its own --config argument names
# degauss/degauss.toml, and so would an editor open on that file. The grep
# only narrows the field (busybox grep has no -z to anchor on an argument);
# the bracket keeps it from matching its own command line.
degauss_running() {
  local f="" a0=""
  for f in $(grep -lsa -e '[d]egauss/degauss' "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null); do
    a0=""
    IFS= read -r -d '' a0 2>/dev/null <"${f}"
    case "${a0}" in
      */.config/degauss/degauss|*/.degauss/degauss) return 0 ;;
    esac
  done
  return 1
}

# The core as far as the display is concerned, into CURCORE: CORENAME, except
# that the menu core with Degauss running is Degauss.
readcore() {
  CURCORE="$(<"${corenamefile}")"
  if [ "${CURCORE}" = "MENU" ] && degauss_running; then
    CURCORE="${DEGAUSS_CORE}"
  fi
}

# Could Degauss start or stop now? Neither touches a state file the daemon
# waits on, so while this holds - the menu is up, or Degauss is - the waits
# time out every UPDATE_ALL_POLL seconds to look again.
degauss_possible() {
  [ "${oldcore}" = "MENU" ] || [ "${oldcore}" = "${DEGAUSS_CORE}" ]
}

# ---------------------------------------------------------------------------
# The frontends, and a newer tty2oled+ in their band
# ---------------------------------------------------------------------------
#
# The menu, MisterZine and Degauss are where a game is chosen, and they are
# shown the way the boot screen is: a picture 54 rows tall, and the 10 rows
# under it kept for the display's own notices. Their picture goes out marked
# ",band" (senddata) - the menu's CMDBOOTPIC always is one - with its bottom
# ten rows black, so a 256x64 banner is shown cut down until it is redrawn.
# Names as CORENAME has them, or readcore for Degauss; case does not matter.
FRONTEND_CORES="menu misterzine ${DEGAUSS_CORE}"
frontend_core() {
  [ -n "${1}" ] || return 1
  case " ${FRONTEND_CORES} " in *" ${1,,} "*) return 0 ;; esac
  return 1
}

# The notice says an update is waiting: a newer tty2oled+ release, a system
# update (update_all would update something installed), or both. Each has its
# own switch, UPDATE_CHECK_TTY2OLED and UPDATE_CHECK_SYSTEM, and both are
# looked for when the daemon starts - at boot - and every
# UPDATE_CHECK_MINUTES after that. Once one is found it is not looked for
# again until it has been dealt with.
#
# tty2oled+: GitHub's latest release VERSION, and a newer one goes to
# UPDATE_FLAG. The flag stays until the updater, having installed a release,
# removes it, and the next check - the restarted daemon's first - decides
# again. A flag naming this version or an older one is left over from an
# update made some other way, and is dropped.
#
# System: tty2oledplus_syscheck.py compares update_all's databases with what
# its downloader installed (see its header). Kept in memory, not a file:
# nothing else answers it but update_all, which the daemon sees running, and
# once it has exited the flag goes and the check runs again at once - so
# the menu you come back to is clear unless something is still waiting. Never
# started while update_all runs; a result from a check that overlapped a run
# is thrown away.
#
# Both run in the background (bg_start): a check can take its whole timeout
# offline, and the loop cannot stop drawing for that. Each pass collects
# whatever has finished. A check that fails is tried again after
# UC_RETRY_SECS rather than a whole interval: the first one runs at boot,
# often before the network is up.
#
# CMDNOTE carries the text to the firmware (0.7.1b and later), which keeps it
# and shows it in the band of every frontend picture: faded in where one is up,
# arriving with the next one where one is not. Only a change is sent.
UPDATE_URL="${UPDATE_URL:-https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/VERSION}"
UPDATE_CACERT="${UPDATE_CACERT:-/etc/ssl/certs/cacert.pem}"   # MiSTer's curl finds none itself
SYSCHECK="${SYSCHECK:-${TTY2OLED_PATH:-/media/fat/tty2oledplus}/tty2oledplus_syscheck.py}"
UC_RETRY_SECS=300
UC_OUT="/tmp/.tty2oledplus-check.$$"
SC_CACHE="${SC_CACHE:-/tmp/.tty2oledplus-check.etags}"   # the databases' ETags, between checks
declare -A BG_PID=() BG_STARTED=()
BG_GIVEUP_uc=120    # stop a check still going after this; curl's own limit is 60
BG_GIVEUP_sc=300    # the system check's own is 20s a database, six at once
UC_NEXT=""          # when the next may start; empty is now
SC_NEXT=""
SC_FLAGGED=""       # a system update is waiting: what, from the checker
SC_UA="no"          # update_all has been seen running since the last check
SC_EPOCH=0          # bumped when update_all finishes; a check from before is stale
SC_JOB_EPOCH=0
NOTE_SENT="?"       # what the firmware was last told; "?" is nothing yet
NOTE_COLS=51        # the band's width in 5x7

# Run a check in the background: its first line of output and its exit code
# land in files, and bg_collect picks them up once it has finished.
bg_start() {  # bg_start <name> <now> <command...>
  local n="${1}" now="${2}" out="${UC_OUT}.${1}"
  shift 2
  rm -f "${out}" "${out}.rc"
  ( "$@" </dev/null >"${out}" 2>/dev/null; echo "$?" >"${out}.rc" ) &
  BG_PID[${n}]=$!
  BG_STARTED[${n}]="${now}"
}

bg_running() { [ -n "${BG_PID[${1}]:-}" ]; }

# A finished check into BG_RC and BG_LINE; 1 while it is still going. One that
# has run past its BG_GIVEUP_<name> is stopped, and has no exit code.
bg_collect() {  # bg_collect <name> <now>
  local n="${1}" now="${2}" out="${UC_OUT}.${1}" giveup
  BG_RC=""; BG_LINE=""
  bg_running "${n}" || return 1
  if ! [ -e "${out}.rc" ]; then
    giveup="BG_GIVEUP_${n}"
    [ $(( now - ${BG_STARTED[${n}]} )) -lt "${!giveup:-120}" ] && return 1
    kill "${BG_PID[${n}]}" 2>/dev/null
  fi
  wait "${BG_PID[${n}]}" 2>/dev/null
  [ -r "${out}.rc" ] && IFS= read -r BG_RC <"${out}.rc"
  [ -r "${out}" ] && IFS= read -r BG_LINE <"${out}"
  rm -f "${out}" "${out}.rc"
  BG_PID[${n}]=""
  return 0
}

# Is release $1 newer than version $2? N.N.N and letters, as VERSION has them;
# anything else is not newer. A release without the beta "b" is newer than
# the beta of the same number.
version_newer() {
  local a=() b=() i
  [[ "${1}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([A-Za-z]*)$ ]] || return 1
  a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  [[ "${2}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([A-Za-z]*)$ ]] || return 1
  b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  for i in 0 1 2; do
    [ "$((10#${a[i]}))" -gt "$((10#${b[i]}))" ] && return 0
    [ "$((10#${a[i]}))" -lt "$((10#${b[i]}))" ] && return 1
  done
  [ -z "${a[3]}" ] && [ -n "${b[3]}" ]
}

update_check_minutes() {
  local m="${UPDATE_CHECK_MINUTES:-30}"
  case "${m}" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$((10#${m}))"
}

# Is this check wanted? Its switch, and an interval to run it at.
update_check_on() {  # update_check_on <TTY2OLED|SYSTEM>
  local on="yes"
  case "${1}" in
    TTY2OLED) on="${UPDATE_CHECK_TTY2OLED:-yes}" ;;
    SYSTEM)   on="${UPDATE_CHECK_SYSTEM:-yes}" ;;
  esac
  [ "${on}" = "yes" ] && [ "$(update_check_minutes)" -gt 0 ]
}

# When the next check is due after one that ended: an interval, or
# UC_RETRY_SECS if that is sooner and it failed.
next_after() {  # next_after <now> <failed: yes|no>
  local secs=$(( $(update_check_minutes) * 60 ))
  [ "${2}" = "yes" ] && [ "${secs}" -gt "${UC_RETRY_SECS}" ] && secs="${UC_RETRY_SECS}"
  printf '%s' "$(( ${1} + secs ))"
}

due() { [ -z "${1}" ] || [ "${2}" -ge "${1}" ]; }   # due <next> <now>

# The flagged release, if it is still newer than this one; a stale flag goes.
update_flagged() {
  local v=""
  [ -r "${UPDATE_FLAG}" ] || return 1
  IFS= read -r v <"${UPDATE_FLAG}"
  v="${v//[[:space:]]/}"
  version_newer "${v}" "${TTY2OLED_VERSION:-}" && return 0
  dbug "${UPDATE_FLAG} names ${v:-nothing}, not newer than ${TTY2OLED_VERSION:-} - removing it"
  rm -f "${UPDATE_FLAG}"
  return 1
}

# The release's VERSION, on stdout. Run in the background.
uc_fetch() {
  local ca=()
  [ -r "${UPDATE_CACERT}" ] && ca=(--cacert "${UPDATE_CACERT}")
  curl -fsSL --connect-timeout 15 --max-time 60 "${ca[@]}" "${UPDATE_URL}"
}

# tty2oled+: collect a finished check, start one that is due.
uc_pass() {  # uc_pass <now>
  local now="${1}" v
  if bg_collect uc "${now}"; then
    v="${BG_LINE//[[:space:]]/}"
    if [ "${BG_RC}" != "0" ] || [ -z "${v}" ]; then
      dbug "The release check failed (curl ${BG_RC:-stopped}); again in ${UC_RETRY_SECS}s"
      UC_NEXT="$(next_after "${now}" yes)"
    else
      UC_NEXT="$(next_after "${now}" no)"
      if version_newer "${v}" "${TTY2OLED_VERSION:-}"; then
        printf '%s\n' "${v}" >"${UPDATE_FLAG}"
        echo "tty2oled: tty2oled+ ${v} is out (this is ${TTY2OLED_VERSION:-unknown}) - Update in the tty2oledplus Scripts entry installs it."
      else
        dbug "The latest release is ${v}; this is ${TTY2OLED_VERSION:-}"
      fi
    fi
  fi
  update_check_on TTY2OLED || return 0
  update_flagged && return 0
  bg_running uc && return 0
  due "${UC_NEXT}" "${now}" || return 0
  command -v curl >/dev/null 2>&1 || { UC_NEXT="$(next_after "${now}" yes)"; return 0; }
  dbug "Looking for a newer tty2oled+ at ${UPDATE_URL}"
  bg_start uc "${now}" uc_fetch
}

# Is update_all running, whatever UPDATE_ALL_SCREEN says?
updateall_process() {
  grep -qsa -e '[u]pdate_all' "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null
}

# System: the same, with update_all as what answers it.
sc_pass() {  # sc_pass <now>
  local now="${1}"
  if update_check_on SYSTEM || [ -n "${SC_FLAGGED}" ] || bg_running sc; then
    if updateall_process; then
      SC_UA="yes"
    elif [ "${SC_UA}" = "yes" ]; then
      # update_all has run: whatever was waiting may not be any more.
      SC_UA="no"; SC_FLAGGED=""; SC_NEXT=""
      SC_EPOCH=$(( SC_EPOCH + 1 ))
      dbug "update_all finished - looking for system updates again"
    fi
  fi
  if bg_collect sc "${now}"; then
    if [ "${SC_JOB_EPOCH}" != "${SC_EPOCH}" ] || [ "${SC_UA}" = "yes" ]; then
      dbug "The system check overlapped update_all - discarded"
      SC_NEXT=""
    else
      case "${BG_LINE}" in
        yes*)
          SC_FLAGGED="${BG_LINE#yes }"
          SC_NEXT="$(next_after "${now}" no)"
          echo "tty2oled: a system update is waiting (${SC_FLAGGED}) - update_all installs it." ;;
        no)
          dbug "No system update waiting"
          SC_NEXT="$(next_after "${now}" no)" ;;
        nostate)
          dbug "No update_all state to check against - it has not run yet"
          SC_NEXT="$(next_after "${now}" no)" ;;
        *)
          dbug "The system check failed (${BG_LINE:-exit ${BG_RC:-stopped}}); again in ${UC_RETRY_SECS}s"
          SC_NEXT="$(next_after "${now}" yes)" ;;
      esac
    fi
  fi
  update_check_on SYSTEM || return 0
  [ -z "${SC_FLAGGED}" ] || return 0
  [ "${SC_UA}" = "no" ] || return 0
  bg_running sc && return 0
  due "${SC_NEXT}" "${now}" || return 0
  if ! [ -r "${SYSCHECK}" ] || ! command -v python3 >/dev/null 2>&1; then
    SC_NEXT="$(next_after "${now}" no)"; return 0
  fi
  dbug "Looking for a system update (${SYSCHECK})"
  SC_JOB_EPOCH="${SC_EPOCH}"
  bg_start sc "${now}" nice -n 19 python3 "${SYSCHECK}" --cache "${SC_CACHE}"
}

# Tell the firmware what the band says, if that changed and it can show it.
sendnote() {
  local text="${1}"
  text="$(printf '%s' "${text}" | tr -d '\000-\037\177')"
  text="${text:0:${NOTE_COLS}}"
  [ "${text}" = "${NOTE_SENT}" ] && return 0
  fw_atleast 0.7.1 || return 0
  dbug "Sending: CMDNOTE,${text}"
  echo "CMDNOTE,${text}" >${TTYDEV}
  cmdwait
  NOTE_SENT="${text}"
}

# The notice for what is waiting: one, the other, both, or none.
update_note() {
  local t="no" y="no"
  update_check_on TTY2OLED && update_flagged && t="yes"
  update_check_on SYSTEM && [ -n "${SC_FLAGGED}" ] && y="yes"
  case "${t}${y}" in
    yesyes) printf '%s' "${UPDATE_NOTE_BOTH_TEXT:-TTY2OLED+ & System Update Available}" ;;
    yesno)  printf '%s' "${UPDATE_NOTE_TEXT:-TTY2OLED+ Update Available}" ;;
    noyes)  printf '%s' "${UPDATE_NOTE_SYSTEM_TEXT:-System Update Available}" ;;
  esac
}

# Once a pass, whatever else the pass does: never blocks.
updatenote_pass() {
  local now="${EPOCHSECONDS:-$(date +%s)}"
  uc_pass "${now}"
  sc_pass "${now}"
  sendnote "$(update_note)"
}

# ---------------------------------------------------------------------------
# update_all screen
# ---------------------------------------------------------------------------

# Is update_all running? It leaves no state file behind and does not touch
# CORENAME - it can be started from the Scripts menu or from inside a frontend
# core such as MiSTerZine - so the only reliable sign is the process itself.
# One grep over every command line: update_all.sh, and the update_all.pyz it
# hands over to, both carry the name. The bracket keeps grep's own command
# line, which holds the pattern, from matching it.
updateall_running() {
  [ "${UPDATE_ALL_SCREEN:-yes}" = "yes" ] || return 1
  updateall_process
}

# Is update_all's downloader running - the update itself, as opposed to the
# settings screen in front of it? update_all copies the downloader to /tmp and
# runs it from there, under one of three names depending on which build it
# found: ua_downloader_bin, ua_downloader_latest.zip or ua_downloader_dd.pyz
# (Update_All_MiSTer, downloader_service.py). The settings screen also runs it
# for a moment with --list-dbs to see what is installed, which is a query and
# not an update, so that one does not count.
downloader_running() {
  local f=""
  for f in $(grep -lsa -e '[u]a_downloader' "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null); do
    grep -qsa -e '--list-dbs' "${f}" || return 0
  done
  return 1
}

# The busy bar in the band under the update_all picture: the boot screen's
# sweep, run by the firmware until told to stop.
sendbusy() {  # sendbusy <0|1> [label] [effect]
  local arg="${1}"
  # A label takes the panel: the firmware blacks the picture and writes the
  # message above the bar. Without one the picture stays and only the bar runs.
  # The comma is the separator, so it cannot survive in the text.
  if [ -n "${2:-}" ]; then arg="${1},$(printf '%s' "${2}" | tr -d ',')"; fi
  # An effect makes the message arrive like a picture instead of appearing.
  # Only for a screen that *replaces* what you were looking at - the updater
  # taking over from a core's artwork. The downloader's bar passes none: by
  # then the panel is already the update_all screen, and fading from one
  # message to another says something changed when nothing did.
  if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then arg="${arg},${3}"; fi
  dbug "Sending: CMDBUSY,${arg}"
  echo "CMDBUSY,${arg}" >${TTYDEV}
  cmdwait
}

# Show the update_all picture in place of whatever core is loaded, cropped to
# the top 54 rows like a boot image so the band below is free for the busy
# bar. Exact names only - the core lookup's prefix trimming would happily settle on some
# unrelated arcade set starting with "upd". With no picture it falls back to
# the name as text, which is what the firmware does with any line it does not
# recognise - the same thing a missing core banner gets.
sendupdateall() {
  local name="update_all" pic=""
  # Out of the split layout / card first, or the card alternation would
  # keep drawing the previous game over the picture.
  if [ "${SHOW_METADATA}" = "yes" ]; then
    dbug "Sending: CMDMETAOFF (update_all)"
    echo "CMDMETAOFF" >${TTYDEV}
    sleep ${WAITSECS}
    META_WIRE_LAST="OFF"
  fi
  findbanner "${name}" exact && pic="${BANNERFILE}"
  if [ -n "${pic}" ]; then
    dbug "Sending: CMDCOR,${name},${TRANSITION} (${pic})"
    echo "CMDCOR,${name},${TRANSITION}" >${TTYDEV}
    sleep ${WAITSECS}
    # The first 6912 bytes are the top 54 rows; the band's 1280 are sent
    # black. As one stream, so the firmware reads exactly 8192 bytes.
    { tail -n +4 "${pic}" | xxd -r -p | head -c 6912; head -c 1280 /dev/zero; } >${TTYDEV}
    return 0
  fi
  # As text, and transitioned: this is the update_all screen whenever the
  # artwork pack has no update_all.gsc, which is the usual case, and moving to
  # it is as much a change of picture as a core change is. A bare line is what
  # the firmware draws for any command it does not know, and carries no
  # effect, so it is asked for by name instead.
  dbug "Sending: CMDMSG,${TRANSITION},${name} (as text)"
  echo "CMDMSG,${TRANSITION},${name}" >${TTYDEV}
  cmdwait
}

# Is this fork's own updater running? tty2oledplus_update.sh stops the daemon
# within a few seconds of starting - it wants the serial port for the display's
# version and the flash - so this is the one chance to say what is happening.
# The message stays on the panel afterwards precisely because the daemon is
# gone: nothing else writes to it until the flash resets the board.
#
# The uninstaller is deliberately not matched: it stops the daemon too, but it
# is removing this, and a display left saying "Updating" would be a lie.
selfupdate_running() {
  [ "${SELF_UPDATE_SCREEN:-yes}" = "yes" ] || return 1
  # Both spellings: the scripts were renamed in 0.4.8b, and an install that
  # has not been updated since still has update_tty2oledplus.sh in Scripts.
  # Where it runs from does not matter - the install folder, from the
  # launcher, since 0.6.3b - which is why this matches the name, not a path.
  #
  # Not one that was already running when this daemon started: that is the
  # updater that started it, in its last second - its finish screen is up,
  # and "Updating" going back over it would say the opposite.
  local p
  for p in $(selfupdate_pids); do
    case " ${SELFUPDATE_OURS:-} " in *" ${p} "*) continue ;; esac
    return 0
  done
  return 1
}

selfupdate_pids() {
  local f p
  for f in $(grep -lsa -e '[t]ty2oledplus_update' -e '[u]pdate_tty2oledplus' \
               "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null); do
    p="${f%/cmdline}"; printf '%s ' "${p##*/}"
  done
}

# The updater's own screen: no banner to show - it may be replaced mid-run -
# so the message is all there is, with the bar under it.
selfupdate_pass() {
  if ! selfupdate_running; then
    # Finished - which for an update that reflashed the display means the
    # board reset under us, and for one that did not means the bar is still
    # sweeping over whatever is drawn next. Stop it and redraw everything:
    # CMDBOOTPIC, which is all the MENU core sends, used to leave it running
    # for ever over the menu picture.
    if [ "${SELFUPDATE_SHOWN:-no}" = "yes" ]; then
      dbug "tty2oledplus_update finished, back to the core"
      sendbusy 0
      SELFUPDATE_SHOWN="no"
      oldcore=""
      META_WIRE_LAST=""
    fi
    return 1
  fi
  if [ "${SELFUPDATE_SHOWN:-no}" != "yes" ]; then
    dbug "tty2oledplus_update is running"
    if [ "${SHOW_METADATA}" = "yes" ]; then
      dbug "Sending: CMDMETAOFF (self update)"
      echo "CMDMETAOFF" >${TTYDEV}
      sleep ${WAITSECS}
      META_WIRE_LAST="OFF"
    fi
    sendbusy 1 "${SELF_UPDATE_TEXT:-Updating TTY2OLED+...}" "${TRANSITION}"
    SELFUPDATE_SHOWN="yes"
    # Whatever was on screen is gone, and the board is about to be reset by
    # the flash: everything goes out again when the daemon comes back.
    oldcore=""
  fi
  sleep "${UPDATE_ALL_POLL:-2}"
  return 0
}

# ---------------------------------------------------------------------------
# update_all's own words, under the bar
# ---------------------------------------------------------------------------
#
# update_all (2.x) copies everything it prints to the screen into
# /tmp/update_all_print.log as it prints it, flushed line by line - the
# downloader's output too, which it relays from the child process as it
# arrives. So the file's last useful line is what the MiSTer's own screen is
# saying right now, and it goes under the label as the status line
# (CMDBUSYLINE, firmware 0.7.0b and later). The end of the run is in it as
# well: "Success! ..." or "There were some errors in the Updaters.", after
# the "Update All <version> ... <run time>s" summary.
#
# update_all deletes and recreates the file when it starts, but not at once -
# its launcher runs first - so until then the file is the previous run's, and
# that one ends in a verdict. It is trusted only once it differs, by inode or
# mtime, from what was there when update_all was first seen.
UA_PRINTLOG="${UA_PRINTLOG:-/tmp/update_all_print.log}"
# Written when update_all exits; where the verdict is looked for if the print
# log had none - an update_all too old to write one.
UA_FINALLOG="${UA_FINALLOG:-/media/fat/Scripts/.config/update_all/update_all.log}"
UA_LINE_COLS=51     # the 5x7 status line's width, 256 pixels / 5

# Milliseconds, for the finish screen's minimum time.
ms_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "${t}" ]; then t="${t//[.,]/}"; echo "$(( 10#${t} / 1000 ))"
  else echo "$(( $(date +%s) * 1000 ))"; fi
}

ua_logref() { stat -c '%i %Y' "${UA_PRINTLOG}" 2>/dev/null; }

# The last useful line, and the verdict and run time if the run is over:
# three lines out - verdict (ok, failed or empty), run time, line. Rules,
# blank lines and the downloader's progress dots are not useful; nor are its
# DUPLICATED warnings, which come in hundreds and say nothing about progress.
ua_parselog() {
  tr '\r' '\n' | LC_ALL=C tr -cd '\n\040-\176' | awk '
    {
      sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
      if ($0 ~ /^Success!/) v = "ok"
      else if ($0 ~ /^There were some errors in the Updaters/) v = "failed"
      if ($0 ~ /^Update All / && match($0, /[0-9][0-9:]*\.[0-9]+s/)) {
        rt = substr($0, RSTART, RLENGTH); sub(/\.[0-9]+s$/, "", rt)
      }
      if ($0 == "" || $0 ~ /^[-#=*._ ]+$/ || $0 ~ /^DUPLICATED:/) next
      sub(/^- /, "")
      last = $0
    }
    END { print v; print rt; print last }'
}

# Into UA_VERDICT, UA_RUNTIME, UA_LINE; latches UA_MAIN once update_all has
# printed its "Sequence:" - the main run has begun, and from there to the end
# is all update, downloader or not.
ua_readlog() {
  UA_VERDICT=""; UA_RUNTIME=""; UA_LINE=""
  [ -r "${UA_PRINTLOG}" ] || return 0
  if [ "${UA_LOG_FRESH:-no}" != "yes" ]; then
    [ "$(ua_logref)" = "${UA_LOG_REF:-}" ] && return 0
    UA_LOG_FRESH="yes"
  fi
  [ "${UA_MAIN:-no}" = "yes" ] || ! grep -qs '^Sequence:' "${UA_PRINTLOG}" || UA_MAIN="yes"
  { IFS= read -r UA_VERDICT; IFS= read -r UA_RUNTIME; IFS= read -r UA_LINE; } \
    < <(tail -c 8192 "${UA_PRINTLOG}" | ua_parselog)
}

# update_all has exited without a verdict in the print log: its full log, if
# this run wrote it.
ua_readfinal() {
  [ -r "${UA_FINALLOG}" ] || return 0
  [ "$(stat -c %Y "${UA_FINALLOG}" 2>/dev/null || echo 0)" -ge "${UA_SEEN_AT:-0}" ] || return 0
  IFS= read -r UA_VERDICT < <(tail -c 8192 "${UA_FINALLOG}" | ua_parselog)
}

# Shortened to the status line's width: a path loses its beginning, since the
# file name is the part that says something; anything else its end.
ua_shorten() {
  local s="${1}" max="${UA_LINE_COLS}"
  if [ "${#s}" -le "${max}" ]; then printf '%s' "${s}"; return; fi
  case "${s}" in
    */*) printf '...%s' "${s: -$((max - 3))}" ;;
    *)   printf '%s...' "${s:0:$((max - 3))}" ;;
  esac
}

# The status line under the busy label. Only what changed goes out, and only
# to firmware that knows the command - to any other it would be drawn as text.
sendbusyline() {
  local line; line="$(ua_shorten "${1}")"
  [ "${line}" = "${BUSYLINE_LAST:-}" ] && return 0
  fw_atleast 0.7.0 || return 0
  BUSYLINE_LAST="${line}"
  dbug "Sending: CMDBUSYLINE,${line}"
  echo "CMDBUSYLINE,${line}" >${TTYDEV}
  cmdwait
}

# The finish screen: "Update Complete" (or failed) in place of the label, the
# bar left to run off, and the run time under it. It stays for at least
# UPDATE_DONE_SECS, counted from here - see ua_holddone.
ua_done() {
  UA_DONE_HEAD="${UPDATE_DONE_TEXT:-Update Complete}"
  UA_DONE_LINE="${UA_RUNTIME:+Finished in ${UA_RUNTIME}}"
  if [ "${UA_VERDICT}" = "failed" ]; then
    UA_DONE_HEAD="${UPDATE_FAILED_TEXT:-Update Failed}"
    UA_DONE_LINE="Some updaters failed - see the log"
  fi
  dbug "update_all is done: ${UA_VERDICT}"
  ua_showdone
  UA_DONE_AT="$(ms_now)"
}

ua_showdone() {
  # The effect is for a panel that is showing the banner; over the busy
  # screen the firmware swaps the label in place and ignores it.
  sendbusy 0 "${UA_DONE_HEAD}" "${TRANSITION}"
  UPDATEALL_BUSY="no"
  BUSYLINE_LAST=""
  sendbusyline "${UA_DONE_LINE}"
}

# Can this display show the finish screen, and is it wanted?
ua_finishes() {
  fw_atleast 0.7.0 && [ "${UPDATE_DONE_SECS:-3}" -gt 0 ] 2>/dev/null
}

# update_all has gone: whatever is left of the finish screen's minimum time.
# If it outlasted that - the log viewer it offers at the end - nothing.
ua_holddone() {
  [ -n "${UA_DONE_AT:-}" ] || return 0
  local left=$(( ${UPDATE_DONE_SECS:-3} * 1000 - ( $(ms_now) - UA_DONE_AT ) ))
  UA_DONE_AT=""
  [ "${left}" -gt 0 ] || return 0
  dbug "Holding the finish screen ${left}ms more"
  sleep "$(printf '%d.%03d' $((left / 1000)) $((left % 1000)))"
}

# How long to wait between looks: a second while the status line is following
# the log, so it keeps up; UPDATE_ALL_POLL otherwise.
ua_poll() {
  local p="${UPDATE_ALL_POLL:-2}"
  if [ "${UPDATEALL_BUSY:-no}" = "yes" ] && [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ] \
     && [ "${p}" -gt 1 ] 2>/dev/null; then
    p=1
  fi
  echo "${p}"
}

# One pass of the main loop while update_all runs. Returns 1 when it is not
# running; the first such pass after it was clears oldcore and the metadata
# line, so the core and game go out again in full rather than being judged
# unchanged.
#
# The banner while update_all is only asking (its countdown and settings
# screen); the label and bar while it updates - the downloader, and on a
# display that can show the finish, everything from "Sequence:" to the end;
# then "Update Complete" for at least UPDATE_DONE_SECS, however soon or late
# update_all itself exits after printing it.
updateall_pass() {
  if updateall_running; then
    if [ "${UA_RUN:-no}" != "yes" ]; then
      UA_RUN="yes"; UA_MAIN="no"; UA_DONE_AT=""; UA_LOG_FRESH="no"
      UA_LOG_REF="$(ua_logref)"; UA_SEEN_AT="$(date +%s)"
    fi
    if [ "${UPDATEALL_SHOWN:-no}" != "yes" ]; then
      dbug "update_all is running"
      sendupdateall
      UPDATEALL_SHOWN="yes"
      UPDATEALL_BUSY="no"
      # A display that reset during the finish screen gets it back.
      [ -n "${UA_DONE_AT}" ] && ua_showdone
    fi
    if [ -z "${UA_DONE_AT}" ]; then
      ua_readlog
      # Older firmware keeps the older screens: the bar with the downloader.
      fw_atleast 0.7.0 || UA_MAIN="no"
      if [ -n "${UA_VERDICT}" ] && ua_finishes; then
        ua_done
      # The bar follows the downloader, which update_all may run more than
      # once - its own update, then the main run.
      elif downloader_running || [ "${UA_MAIN}" = "yes" ]; then
        # The download is the part that takes minutes, so it gets the panel:
        # UPDATING above the bar, the banner gone. The firmware ignores a
        # repeat of the same label, so re-sending it costs a command and
        # nothing else.
        if [ "${UPDATEALL_BUSY:-no}" != "yes" ]; then
          sendbusy 1 "${UPDATE_ALL_TEXT:-Updating System ...}"
          UPDATEALL_BUSY="yes"
          BUSYLINE_LAST=""
        fi
        [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ] && sendbusyline "${UA_LINE}"
      elif [ "${UPDATEALL_BUSY:-no}" = "yes" ]; then
        # Back to the banner: the label blacked it out, so it has to go again.
        sendbusy 0; UPDATEALL_BUSY="no"; sendupdateall
      fi
    fi
    sleep "$(ua_poll)"
    return 0
  fi
  if [ "${UPDATEALL_SHOWN:-no}" = "yes" ]; then
    # It may have printed its verdict and exited between two looks.
    if [ -z "${UA_DONE_AT:-}" ] && ua_finishes \
       && { [ "${UPDATEALL_BUSY:-no}" = "yes" ] || [ "${UA_MAIN:-no}" = "yes" ]; }; then
      ua_readlog
      [ -n "${UA_VERDICT}" ] || ua_readfinal
      [ -n "${UA_VERDICT}" ] && ua_done
    fi
    ua_holddone
    dbug "update_all finished, back to the core"
    [ "${UPDATEALL_BUSY:-no}" = "yes" ] && sendbusy 0
    UPDATEALL_SHOWN="no"
    UPDATEALL_BUSY="no"
    oldcore=""
    META_WIRE_LAST=""
  fi
  UA_RUN="no"; UA_DONE_AT=""
  return 1
}

# ** Main **
# Check for Command Line Parameter
if [ "${#}" -ge 1 ]; then # Command Line Parameter given, override Parameter
  #echo -e "\nUsing Command Line Parameter"
  dbug "\nUsing Command Line Parameter"
  ! [ "${1}" = "tty2x" ] && TTYDEV=${1}                   # Set TTYDEV with Parameter 1
  if [ -n "${2}" ]; then                                  # Parameter 2 Baudrate
    BAUDRATE=${2}                                         # Set Baudrate
  fi                                                      # end if Parameter 3
  echo "Using Interface: ${TTYDEV} with ${BAUDRATE} Baud" # Device Output
fi                                                        # end if command line Parameter

# Let's go
if [ -c "${TTYDEV}" ]; then # check for tty device
  SELFUPDATE_OURS="$(selfupdate_pids)"            # the updater that started us, if any
  serialinit													# Line settings, contrast, rotation
  while true; do											# main loop
    # The display can be unplugged, re-enumerated or reset under a running
    # daemon. Skipping the pass is how the loop waits for it to come back, and
    # how the pass after it becomes a full redraw.
    serialready || continue
    if [ -r ${corenamefile} ]; then							# proceed if file exists and is readable (-r)
      # Sleep mode: the display belongs to something else - see sleepmode_pass.
      # Nothing below this may write to the port while it is held.
      if ! sleepmode_pass; then
        # A newer release, and the notice for it: never blocks.
        updatenote_pass
        # update_all takes the screen over whatever core is loaded, and our
        # own updater over that - it is about to stop this daemon.
        selfupdate_pass && { deferred_setup; continue; }
        updateall_pass && { deferred_setup; continue; }
        readcore; newcore="${CURCORE}"			  # get CORENAME, or Degauss over MENU
        if [ "${SHOW_METADATA}" = "yes" ]; then
          # Metadata mode. Loading a ROM does not modify /tmp/CORENAME, so
          # watching that file alone never notices a game change - which is
          # why the display used to sit on the core screen forever. Watch the
          # game-state files too, and tell the two cases apart: a new core
          # needs the full redraw, a new game needs only fresh text.
          if [ "${newcore}" != "${oldcore}" ]; then
            dbug "Read CORENAME: -${newcore}-"
            dbug "Send -${newcore}- to ${TTYDEV}."
            senddata "${newcore}"
            oldcore=$newcore
          else
            dbug "Core unchanged, refreshing metadata only"
            refreshmeta "${newcore}"
          fi
          [ "${1}" = "tty2x" ] && exit 9
          deferred_setup						  # the half of startup the picture did not need
          metawatch="$(metawatchlist)"
          # The timeout is what picks up a state file that did not exist when
          # the watch list was built - GAMEID only appears once a game with a
          # known CRC is loaded. A wake with nothing changed costs one cheap
          # rebuild and no serial traffic, because sendmeta de-duplicates.
          # Shorter while Degauss could come or go, which changes none of them.
          mpoll="${METADATA_POLL:-5}"
          degauss_possible && mpoll="${UPDATE_ALL_POLL:-2}"
          if [ "${debug}" = "false" ]; then
            inotifywait -qq -t "${mpoll}" -e modify,create,moved_to ${metawatch}
          else
            inotifywait -t "${mpoll}" -e modify,create,moved_to ${metawatch}
          fi
        else
          # Upstream path, unchanged.
          #if [ "$newcore" != "$oldcore" ]; then
            dbug "Read CORENAME: -${newcore}-"
            dbug "Send -${newcore}- to ${TTYDEV}."
            senddata "${newcore}" 				   # The "Magic"
            oldcore=$newcore
            [ "${1}" = "tty2x" ] && exit 9
            deferred_setup					   # the half of startup the picture did not need
            # With the update_all screen on, the wait times out now and then
            # to look for it; a timeout only redraws if update_all started.
            # Anything but a timeout (an event, or inotifywait failing) ends
            # the wait as it always did.
            upwait=""
            { [ "${UPDATE_ALL_SCREEN:-yes}" = "yes" ] || [ "${SELF_UPDATE_SCREEN:-yes}" = "yes" ] || degauss_possible \
              || update_check_on TTY2OLED || update_check_on SYSTEM; } \
              && upwait="-t ${UPDATE_ALL_POLL:-2}"
            while true; do
              if [ "${debug}" = "false" ]; then
                inotifywait -qq ${upwait} -e modify "${corenamefile}"  # wait here for next change of corename, -qq for quietness
              else
                inotifywait ${upwait} -e modify "${corenamefile}"      # but not -qq when debugging
              fi
              [ "$?" -eq 2 ] || break
              updatenote_pass
              updateall_running && break
              selfupdate_running && break
              if degauss_possible; then
                readcore; [ "${CURCORE}" = "${oldcore}" ] || break
              fi
            done
	  #else
          #  dbug "Core not changed!"
          #fi #newcore != oldcore
        fi
      fi
    else # CORENAME file not found
      # Blocks until MiSTer writes it. Returning here without waiting is a
      # spin, which is what this used to do.
      waitforcorename
    fi # end if /tmp/CORENAME check
  done # end while
else   # no tty detected
  echo "No ${TTYDEV} Device detected, abort."
  dbug "No ${TTYDEV} Device detected, abort."
fi # end if tty check
# ** End Main **
