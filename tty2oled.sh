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
# Two folders hold banners since 0.5.8b: pics/banner, the artwork pack's, which
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
# unrelated arcade set starting with "upd".
findbanner() {
  local core="${1}" mode="${2:-}" first="${userbannerfolder}" second="${bannerfolder}" d c
  BANNERFILE=""
  [ -n "${core}" ] || return 1
  if [ "${PRIORITIZE_USER_BANNERS:-yes}" != "yes" ]; then
    first="${bannerfolder}"; second="${userbannerfolder}"
  fi
  for d in "${first}" "${second}"; do
    [ -n "${d}" ] || continue
    if [ "${mode}" = "exact" ]; then
      [ -e "${d}/${core}.gsc" ] && { BANNERFILE="${d}/${core}.gsc"; return 0; }
      continue
    fi
    for ((c = "${#core}"; c >= 1; c--)); do
      [ -e "${d}/${core:0:$c}.gsc" ] && { BANNERFILE="${d}/${core:0:$c}.gsc"; return 0; }
    done
  done
  return 1
}

# Dice between a banner and its alternatives, and print the winner.
#
# The alternatives are <base>_alt1.gsc, _alt2.gsc ... in pics/alt - the pack's
# - and beside your own banner in pics/user. Named after the picture that was
# actually found rather than after the core, since that may have been a
# trimmed prefix. The primary is one of the faces of the die, which is what
# upstream's "RANDOM % (count + 1)" amounted to.
#
# Off by default here, unlike upstream: the pack's alternatives are a
# different take on a system rather than a variant of one picture, and a core
# that looked one way yesterday looking another way today reads as a fault.
randomalt() {
  local pic="${1}" base f
  if [ "${RANDOMIZE_ALT_BANNERS:-no}" != "yes" ]; then printf '%s' "${pic}"; return 0; fi
  base="$(basename "${pic}" .gsc)"
  local -a cands=("${pic}")
  for f in "${altbannerfolder}/${base}"_alt*.gsc "${userbannerfolder}/${base}"_alt*.gsc; do
    [ -e "${f}" ] && cands+=("${f}")
  done
  printf '%s' "${cands[$((RANDOM % ${#cands[@]}))]}"
}

# Send-Picture-Data function
senddata() {
  newcore="${1}"
  unset picfnam

  # Metadata first: the firmware needs to know which layout to compose
  # before the picture arrives, and the console icon has to be in place
  # before CMDCOR triggers the first paint of the split layout.
  # sendmeta answers 0 when it put game details on the wire and 1 when it sent
  # CMDMETAOFF instead - which is the usual case here, because MiSTer publishes
  # the core a second or two before the game. The hold has to be armed either
  # way: it is about the core's artwork, which is going up regardless, and the
  # game will arrive against it whenever MiSTer gets round to saying so.
  sendmeta "${newcore}" force; local metaon="${?}"
  # Before the icon, not after: the icon composes the layout as it lands, and
  # would put it on the panel a moment before the artwork replaced it.
  sendcoreboot
  [ "${metaon}" -eq 0 ] && sendicon "${META_ICON}"

  # The menu's picture is the boot screen, which lives on the display - so
  # there is nothing to send but the request. At power-on the boot screen is
  # already on the panel and the firmware leaves it there; later, returning
  # to the menu transitions to it like any other core picture.
  if [ "${BOOTSCREEN_AS_MENU:-yes}" = "yes" ] && [ "${newcore}" = "MENU" ]; then
    dbug "Sending: CMDBOOTPIC,${newcore},${TRANSITION}"
    echo "CMDBOOTPIC,${newcore},${TRANSITION}" >${TTYDEV}
    cmdwait
    return 0
  fi

  if findbanner "${newcore}"; then
    picfnam="$(randomalt "${BANNERFILE}")"
    dbug "Sending: CMDCOR,${1},${TRANSITION}"
    echo "CMDCOR,${1},${TRANSITION}" >${TTYDEV}    # Send CORECHANGE" Command and Corename
    sleep ${WAITSECS}                              # sleep needed here ?!
    tail -n +4 "${picfnam}" | xxd -r -p >${TTYDEV} # The Magic, send the Picture-Data up from Line 4 and process
  else                                               # No Picture available!
    echo "${1}" >${TTYDEV}                           # Send just the CORENAME
  fi                                                 # End if Picture check
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
sendmeta() {
  local corename="${1}" force="${2:-}" kindnum="" payload="" label="" value="" f="" wire=""

  [ "${SHOW_METADATA}" = "yes" ] || return 1

  # "force" is set on a core change, which is the only time the leftover-state
  # guard in build_meta applies.
  build_meta "${corename}" "${force:+corechange}"

  # Computer cores stay on plain full-screen artwork by design, and so does a
  # console core sitting at its menu with no game loaded - there is nothing to
  # describe, and the core's artwork is the better screen.
  if [ "${META_KIND}" = "computer" ] || [ "${META_KIND}" = "unknown" ] ||
     [ "${META_GAME:-no}" != "yes" ]; then
    if [ "${force}" = "force" ] || [ "${META_WIRE_LAST:-}" != "OFF" ]; then
      dbug "Sending: CMDMETAOFF (kind=${META_KIND} game=${META_GAME:-no})"
      echo "CMDMETAOFF" >${TTYDEV}
      sleep ${WAITSECS}
      META_WIRE_LAST="OFF"
    fi
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

  # The daemon now also wakes on game-state changes, and MiSTer rewrites those
  # files while the user is merely browsing. Resending an identical line would
  # restart the card's scroll and animation for no reason, so send only what
  # actually changed. "force" is used on a core change, where the firmware has
  # just been reset and must be told again regardless.
  if [ "${force}" != "force" ] && [ "${wire}" = "${META_WIRE_LAST:-}" ]; then
    dbug "Metadata unchanged, not resending"
    return 1
  fi

  dbug "Sending: ${wire}"
  echo "${wire}" >${TTYDEV}
  sleep ${WAITSECS}
  META_WIRE_LAST="${wire}"
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
# Deciding here rather than in the firmware is the point. Only the daemon can
# tell a core change from a game change; only the firmware knows when the
# transition finished and the artwork is actually on the panel. Send nothing
# and there is no hold, which is what core_bootscreen_time=0 does.
sendcoreboot() {
  local ms="${core_bootscreen_time:-3000}"
  [ "${META_KIND}" = "console" ] || return 1
  case "${ms}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${ms}" -gt 0 ] || return 1
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

  # USE_RANDOM_ALT became RANDOMIZE_ALT_BANNERS in 0.5.8b, and the default
  # turned over with the rename. The system ini no longer sets the old name,
  # so if it is set at all it came from the user's own ini - and a user who
  # asked for the dice deserves to be told they are not being rolled.
  if [ -n "${USE_RANDOM_ALT:-}" ]; then
    echo "tty2oled: USE_RANDOM_ALT is gone - set RANDOMIZE_ALT_BANNERS (yes/no) in tty2oled-user.ini instead. Using ${RANDOMIZE_ALT_BANNERS:-no}."
  fi

  checkversion												# Scripts and firmware in step?
  sendtime													# Set time and date
  senddim													# Set idle dimming
  sendflip													# Set console side swapping

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
  return 1
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
  grep -qsa -e '[u]pdate_all' "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null
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
sendbusy() {
  local arg="${1}"
  # A label takes the panel: the firmware blacks the picture and writes the
  # message above the bar. Without one the picture stays and only the bar runs.
  # The comma is the separator, so it cannot survive in the text.
  if [ -n "${2:-}" ]; then arg="${1},$(printf '%s' "${2}" | tr -d ',')"; fi
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
  dbug "Sending: ${name} (as text)"
  echo "${name}" >${TTYDEV}
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
  grep -qsa -e '[t]ty2oledplus_update' -e '[u]pdate_tty2oledplus' \
       "${PROC_ROOT:-/proc}"/[0-9]*/cmdline 2>/dev/null
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
    sendbusy 1 "${SELF_UPDATE_TEXT:-Updating TTY2OLED+...}"
    SELFUPDATE_SHOWN="yes"
    # Whatever was on screen is gone, and the board is about to be reset by
    # the flash: everything goes out again when the daemon comes back.
    oldcore=""
  fi
  sleep "${UPDATE_ALL_POLL:-2}"
  return 0
}

# One pass of the main loop while update_all runs: show its screen once, then
# wait. Returns 1 when it is not running; the first such pass after it was
# clears oldcore and the metadata line, so the core and game go out again in
# full rather than being judged unchanged.
updateall_pass() {
  if updateall_running; then
    if [ "${UPDATEALL_SHOWN:-no}" != "yes" ]; then
      dbug "update_all is running"
      sendupdateall
      UPDATEALL_SHOWN="yes"
      UPDATEALL_BUSY="no"
    fi
    # The bar follows the downloader, which update_all may run several times
    # over - its own update, then the main run.
    if downloader_running; then
      # The download is the part that takes minutes, so it gets the panel:
      # UPDATING above the bar, the banner gone. The firmware ignores a repeat
      # of the same label, so re-sending it costs a command and nothing else.
      [ "${UPDATEALL_BUSY:-no}" = "yes" ] || { sendbusy 1 "${UPDATE_ALL_TEXT:-Updating System ...}"; UPDATEALL_BUSY="yes"; }
    elif [ "${UPDATEALL_BUSY:-no}" = "yes" ]; then
      # Back to the banner: the label blacked it out, so it has to go again.
      sendbusy 0; UPDATEALL_BUSY="no"; sendupdateall
    fi
    sleep "${UPDATE_ALL_POLL:-2}"
    return 0
  fi
  if [ "${UPDATEALL_SHOWN:-no}" = "yes" ]; then
    dbug "update_all finished, back to the core"
    [ "${UPDATEALL_BUSY:-no}" = "yes" ] && sendbusy 0
    UPDATEALL_SHOWN="no"
    UPDATEALL_BUSY="no"
    oldcore=""
    META_WIRE_LAST=""
  fi
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
        # update_all takes the screen over whatever core is loaded, and our
        # own updater over that - it is about to stop this daemon.
        selfupdate_pass && { deferred_setup; continue; }
        updateall_pass && { deferred_setup; continue; }
        newcore=$(<${corenamefile})				  # get CORENAME
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
          if [ "${debug}" = "false" ]; then
            inotifywait -qq -t "${METADATA_POLL:-5}" -e modify,create,moved_to ${metawatch}
          else
            inotifywait -t "${METADATA_POLL:-5}" -e modify,create,moved_to ${metawatch}
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
            { [ "${UPDATE_ALL_SCREEN:-yes}" = "yes" ] || [ "${SELF_UPDATE_SCREEN:-yes}" = "yes" ]; } \
              && upwait="-t ${UPDATE_ALL_POLL:-2}"
            while true; do
              if [ "${debug}" = "false" ]; then
                inotifywait -qq ${upwait} -e modify "${corenamefile}"  # wait here for next change of corename, -qq for quietness
              else
                inotifywait ${upwait} -e modify "${corenamefile}"      # but not -qq when debugging
              fi
              [ "$?" -eq 2 ] || break
              updateall_running && break
              selfupdate_running && break
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
