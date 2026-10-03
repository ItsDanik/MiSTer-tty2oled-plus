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
[ -r /media/fat/tty2oledplus/tty2oled-port.sh ] && . /media/fat/tty2oledplus/tty2oled-port.sh
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
#
# The release's pictures are named in lower case (0.7.8b): two names that
# differ only in case are one file on the MiSTer's exFAT, and were two in git.
# So the lower-cased name is what is looked for. On exFAT that finds any
# spelling - an older install's NES.gsc, your own Nes.gsc in pics/user - and
# on a case-sensitive disk the name as given is tried first, so a picture of
# yours spelt like the core still counts.
bannerin() {
  local d="${1}" core="${2}" mode="${3:-}" c low
  BANNERFILE=""
  [ -n "${d}" ] && [ -n "${core}" ] || return 1
  low="${core,,}"
  if [ "${mode}" = "exact" ]; then
    [ -e "${d}/${core}.gsc" ] && { BANNERFILE="${d}/${core}.gsc"; return 0; }
    [ -e "${d}/${low}.gsc" ] && { BANNERFILE="${d}/${low}.gsc"; return 0; }
    return 1
  fi
  for ((c = "${#core}"; c >= 1; c--)); do
    [ -e "${d}/${core:0:$c}.gsc" ] && { BANNERFILE="${d}/${core:0:$c}.gsc"; return 0; }
    [ "${core}" != "${low}" ] && [ -e "${d}/${low:0:$c}.gsc" ] \
      && { BANNERFILE="${d}/${low:0:$c}.gsc"; return 0; }
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
    # Degauss and Zaparoo are not cores, and their names are looked up whole,
    # as update_all's is: trimmed, any banner named for a prefix of one
    # (deg.gsc, zap.gsc) would stand in for it instead of the name as text.
    local mode=""
    case "${core}" in "${DEGAUSS_CORE}"|"${ZAPAROO_CORE}") mode="exact" ;; esac
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
#
# metasan <variable> <text> does it into a variable, without starting a
# process: sendbuiltmeta runs it on the title and on every label and value,
# every pass, and a subshell and a tr cost 30ms a call on the DE10 - 0.4s a
# pass for a game with six fields, which a ScummVM game shares two cores with.
# globasciiranges (on since bash 5.0) keeps the range to those bytes in any
# locale; bash strings hold no NUL.
metasan() {
  local -n __ms_out="${1}"
  local __ms="${2}"
  __ms="${__ms//|/ }"       # field separator
  __ms="${__ms//,/ }"       # command separator
  __ms="${__ms//=/ }"       # label/value separator
  __ms_out="${__ms//[$'\001'-$'\037'$'\177']/}"
}

metasanitize() {
  local __out=""
  metasan __out "${1}"
  printf '%s' "${__out}"
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
  # A path is a file already: a ScummVM game's icon, converted into its cache.
  if [ "${key:0:1}" = "/" ]; then
    [ -e "${key}" ] || return 1
    ICONFILE="${key}"
    return 0
  fi
  # Lower case, as the release names them (see bannerin); as given first.
  if [ -e "${iconfolder}/${key}.gsc" ]; then ICONFILE="${iconfolder}/${key}.gsc"
  elif [ -e "${iconfolder}/${key,,}.gsc" ]; then ICONFILE="${iconfolder}/${key,,}.gsc"
  else return 1; fi
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
  ICON_SENT=""
  MEDIA_SENT=""                         # the transport band went with it
}

# Put what build_meta produced on the wire: CMDMETA and the description, or
# CMDMETAOFF when there is no game to describe. Nothing at all when it would
# repeat the last thing sent.
sendbuiltmeta() {
  local kindnum="" payload="" label="" value="" f="" wire="" l="" v=""

  # Computer cores stay on plain full-screen artwork by design, and so does a
  # console core sitting at its menu with no game loaded - there is nothing to
  # describe, and the core's artwork is the better screen.
  if [ "${META_KIND}" = "computer" ] || [ "${META_KIND}" = "unknown" ] ||
     [ "${META_GAME:-no}" != "yes" ]; then
    [ "${META_WIRE_LAST:-}" != "OFF" ] && sendmetaoff
    return 1
  fi

  case "${META_KIND}" in                  # metakindnum, without a subshell
    arcade) kindnum=1 ;; console) kindnum=2 ;; computer) kindnum=3 ;; *) kindnum=0 ;;
  esac
  metasan payload "${META_TITLE}"

  for f in "${META_FIELDS[@]}"; do
    label="${f%%$'\t'*}"
    value="${f#*$'\t'}"
    metasan l "${label}"; metasan v "${value}"
    payload="${payload}|${l}=${v}"
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
  ICON_SENT=""
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
#
# Two things a new line does not cover. A game ending under a core that keeps
# running - ScummVM back in its own launcher - puts the core's picture back up
# as a core change would: CMDMETAOFF alone leaves the layout on the panel. And
# an icon that turns up after its game's layout went out - ScummVM's, converted
# in the background - is sent on its own, as soon as it is there.
#
# Built only when something it is built from has changed (meta_inputs): the
# pass that finds nothing new - most of them - costs a stat, not a build.
META_INPUTS_LAST=""
refreshmeta() {
  local corename="${1}"
  [ "${SHOW_METADATA}" = "yes" ] || return 0
  if ! scummvm_core "${corename}" && ! { dvd_core "${corename}" && dvd_screen_on; }; then
    meta_inputs "${corename}"
    if [ "${META_INPUTS}" = "${META_INPUTS_LAST}" ]; then
      META_STAT_FRESH=""
      dbug "Nothing the metadata is built from has changed"
      return 0
    fi
    META_INPUTS_LAST="${META_INPUTS}"
  fi
  build_meta "${corename}"
  if [ "${META_SHOWCORE:-}" = "yes" ]; then
    dbug "The game has ended, back to the ${corename} picture"
    senddata "${corename}"
    return 0
  fi
  # A disc's place goes ahead of its layout, which is then drawn with it.
  [ "${META_SOURCE}" = "dvd" ] && dvd_tick
  if sendbuiltmeta; then
    sendicon "${META_ICON}"
  elif [ "${META_GAME:-no}" = "yes" ] && [ "${META_WIRE_LAST:-}" != "OFF" ] &&
       findicon "${META_ICON}" && [ "${ICONFILE}" != "${ICON_SENT:-}" ]; then
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
  # The device itself, when we write through our own node: only another
  # program writing to the display wakes it (port_pass).
  [ -n "${TTYPORT}" ] && [ "${TTYDEV}" != "${TTYPORT}" ] && [ -c "${TTYPORT}" ] && out="${out} ${TTYPORT}"
  # ScummVM starts a game by rewriting its ini. The folder, not the file: the
  # ini may be replaced rather than written in place. It is the only file in
  # there, and a folder with a space in its name is not watched.
  if scummvm_core "${oldcore:-}" && [ -n "${SVM_INI:-}" ]; then
    f="${SVM_INI%/*}"
    [ -d "${f}" ] && [[ "${f}" != *" "* ]] && out="${out} ${f}"
  fi
  printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# ScummVM: its games index and icons, built in the background
# ---------------------------------------------------------------------------
#
# Both come out of ScummVM's own icon packs (tty2oledplus_scummvm.py), and
# both are slow on the MiSTer - the standard library's PNG reader takes
# seconds over a 512x512 icon - so they run niced beside the loop, the way the
# update checks do. The index is brought up to date once each time ScummVM
# starts (a no-op when the packs have not changed); an icon is converted the
# first time its game is played, and kept. A game whose icon cannot be made is
# not tried again until ScummVM is next started.
SCUMMVM_TOOL="${SCUMMVM_TOOL:-${TTY2OLED_PATH:-/media/fat/tty2oledplus}/tty2oledplus_scummvm.py}"
BG_GIVEUP_svi=300
BG_GIVEUP_svc=300
SVM_INDEXED=""                  # the ScummVM pid the index was checked for
declare -A SVM_ICON_TRIED=()    # "<pid>|<engine>|<gameid>" already attempted

scummvm_jobs() {
  local now="${EPOCHSECONDS:-$(date +%s)}" engine="" gid="" out=""
  if bg_collect svi "${now}"; then
    dbug "ScummVM index: ${BG_LINE:-exit ${BG_RC:-killed}}"
    SVM_BUILT=""                # look the game up again, in the new index
  fi
  bg_collect svc "${now}" && dbug "ScummVM icon: ${BG_LINE:-exit ${BG_RC:-killed}}"

  scummvm_core "${oldcore}" && [ -n "${SVM_PID}" ] || return 0
  [ -r "${SCUMMVM_TOOL}" ] && scummvm_icondirs || return 0
  if [ "${SVM_INDEXED}" != "${SVM_PID}" ] && ! bg_running svi; then
    SVM_INDEXED="${SVM_PID}"
    dbug "ScummVM: checking the games index against ${SVM_DIRS[*]}"
    bg_start svi "${now}" nice -n 19 python3 "${SCUMMVM_TOOL}" index \
      --out "${SCUMMVM_CACHE}/games.idx" "${SVM_DIRS[@]}"
  fi
  if [ -n "${SVM_NEED_ICON}" ] && [ -z "${SVM_ICON_TRIED[${SVM_PID}|${SVM_NEED_ICON%|*}]:-}" ] &&
     ! bg_running svc; then
    SVM_ICON_TRIED[${SVM_PID}|${SVM_NEED_ICON%|*}]=1
    IFS='|' read -r engine gid out <<<"${SVM_NEED_ICON}"
    dbug "ScummVM: converting the icon for ${engine}-${gid}"
    bg_start svc "${now}" nice -n 19 python3 "${SCUMMVM_TOOL}" icon \
      --out "${out}" --engine "${engine}" --game "${gid}" "${SVM_DIRS[@]}"
  fi
}

# ---------------------------------------------------------------------------
# The DVD core: its telemetry armed, its disc read, its place followed
# ---------------------------------------------------------------------------
#
# See tty2oled-meta.sh's DVD section for what can be seen and why. Here is
# the doing: the telemetry switched on while the core is up, the disc's table
# and Wikipedia's answer fetched in the background, and - between the passes,
# every DVD_TICK_SECS - one look at the read and the telemetry, which sends
# CMDMEDIA when the firmware's own count would be wrong: a pause, a chapter,
# a seek. A look starts no process: two file reads, a search of the table.
DVD_TOOL="${DVD_TOOL:-${TTY2OLED_PATH:-/media/fat/tty2oledplus}/tty2oledplus_dvd.py}"
BG_GIVEUP_dvs=120               # the scan: a few dozen sectors, or one when cached
BG_GIVEUP_dvl=60                # the lookup: two requests, 15s each at most
DVD_TICK_SECS="1"
DVD_SCAN_GEN=""; DVD_SCAN_DEV=""
declare -A DVD_ASKED=()         # disc keys Wikipedia was asked about, this run
MEDIA_SENT=""                   # what the firmware holds: "state|length|chapter|of"
MEDIA_SENT_POS=0                # ...its seconds in when sent
MEDIA_SENT_AT=0                 # ...and when, in ms

dvd_screen_on() { [ "${SHOW_METADATA}" = "yes" ] && [ "${DVD_SCREEN:-yes}" = "yes" ]; }

# The core's Main reports pause, still and the menu only while this file
# exists (it looks every 2s). Ours says so inside, so that only ours is ever
# removed: the same file is the DVD core's developer's test switch.
dvd_arm() {
  [ -e "${DVD_ARM}" ] && return 0
  printf '%s\n' "${DVD_ARM_MARK}" 2>/dev/null >"${DVD_ARM}" && dbug "DVD: telemetry armed (${DVD_ARM})"
}

dvd_disarm() {
  local l=""
  [ -f "${DVD_ARM}" ] || return 0
  IFS= read -r l 2>/dev/null <"${DVD_ARM}"
  [ "${l}" = "${DVD_ARM_MARK}" ] || return 0
  rm -f "${DVD_ARM}" && dbug "DVD: telemetry disarmed"
}

# The disc's table and its Wikipedia entry, each in the background: the scan
# once per disc (a few dozen sectors, read while the film plays; one sector
# for a disc seen before), the lookup once per disc a run, and never for one
# scraped/DVD.txt already describes - the user's correction included.
dvd_jobs() {
  local now="${EPOCHSECONDS:-$(date +%s)}" key="" label="" nav="" title=""
  if bg_collect dvs "${now}"; then
    dbug "DVD: scanned ${DVD_SCAN_DEV}: ${BG_LINE:-exit ${BG_RC:-killed}}"
    if [ "${DVD_SCAN_GEN}" = "${DVD_GEN}" ]; then
      IFS='|' read -r key label nav title <<<"${BG_LINE}"
      DVD_KEY="${key}"; DVD_LABEL="${label}"; DVD_NAVFILE="${nav}"; DVD_FALLBACK="${title}"
      DVD_SCANNED="${DVD_SCAN_DEV}"
      DVD_R_PREV=""
      [ -n "${nav}" ] && ! dvd_navload "${nav}" && dbug "DVD: ${nav} did not load"
    fi
  fi
  bg_collect dvl "${now}" && dbug "DVD: Wikipedia: ${BG_LINE:-exit ${BG_RC:-killed}}"

  dvd_core "${oldcore}" && dvd_screen_on || return 0
  dvd_find || return 0
  if [ "${DVD_SCANNED}" != "${DVD_DEV}" ] && ! bg_running dvs; then
    DVD_SCAN_GEN="${DVD_GEN}"; DVD_SCAN_DEV="${DVD_DEV}"
    dbug "DVD: reading ${DVD_DEV}"
    bg_start dvs "${now}" nice -n 10 python3 "${DVD_TOOL}" scan --dev "${DVD_DEV}" --cache "${DVD_CACHE}"
  fi
  if [ -n "${DVD_KEY}" ] && [ "${DVD_LOOKUP:-yes}" = "yes" ] &&
     [ -z "${DVD_ASKED[${DVD_KEY}]:-}" ] && ! bg_running dvl; then
    DVD_ASKED[${DVD_KEY}]=1
    lookup_scraped "${DVD_KEY}" "" DVD && return 0
    dbug "DVD: asking Wikipedia about ${DVD_FALLBACK:-${DVD_LABEL}}"
    bg_start dvl "${now}" nice -n 10 python3 "${DVD_TOOL}" lookup --key "${DVD_KEY}" \
      --query "${DVD_FALLBACK:-${DVD_LABEL}}" --db "${SCRAPE_DIR}/DVD.txt"
  fi
}

# The core's telemetry, if it is fresh: DVD_TF yes, and its flags. Its "t" is
# the MiSTer's seconds since boot, as /proc/uptime has them; a file older than
# three seconds is a Main that stopped writing it - not armed yet, or gone.
dvd_telem() {
  local line="" t="" up=""
  DVD_TF="no"; DVD_PAUSE=0; DVD_STILL=0; DVD_MENUF=0; DVD_MEDIA=1
  IFS= read -r line 2>/dev/null <"${DVD_TELEM}" || [ -n "${line}" ] || return 1
  t="${line#*\"t\":}"; t="${t%%[.,]*}"
  IFS=' .' read -r up _ 2>/dev/null <"${PROC_ROOT:-/proc}/uptime"
  case "${t}${up}" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( up - t )) -le 3 ] && [ $(( t - up )) -le 3 ] || return 1
  DVD_TF="yes"
  case "${line}" in *'"pause":1'*) DVD_PAUSE=1 ;; esac
  case "${line}" in *'"still":1'*) DVD_STILL=1 ;; esac
  case "${line}" in *'"menu":1'*)  DVD_MENUF=1 ;; esac
  case "${line}" in *'"media":0'*) DVD_MEDIA=0 ;; esac
  return 0
}

# Where Main is reading, in sectors, into DVD_R.
dvd_pos() {
  local k="" v=""
  DVD_R=""
  while read -r k v; do
    [ "${k}" = "pos:" ] && { DVD_R=$(( v / 2048 )); return 0; }
  done 2>/dev/null <"${PROC_ROOT:-/proc}/${DVD_PID}/fdinfo/${DVD_FD}"
  return 1
}

# CMDMEDIA, when what the firmware shows is not what it should: the state,
# the title's length or the chapter changed, or its count has drifted two
# seconds from the daemon's. Firmware 0.8.2b or later; older draws it as text.
MEDIA_FW_FOR="-"; MEDIA_FW="no"
sendmedia() {  # sendmedia <state> <seconds in> <length> <chapter> <chapters>
  local want="${1}|${3}|${4}|${5}" shown=0
  # Asked once a firmware version, not every look: fw_atleast is two regexes.
  if [ "${MEDIA_FW_FOR}" != "${FW_VERSION:-}" ]; then
    MEDIA_FW_FOR="${FW_VERSION:-}"
    if fw_atleast 0.8.2; then MEDIA_FW="yes"; else MEDIA_FW="no"; fi
  fi
  [ "${MEDIA_FW}" = "yes" ] || return 0
  if [ "${want}" = "${MEDIA_SENT}" ]; then
    shown="${MEDIA_SENT_POS}"
    [ "${1}" = "1" ] && shown=$(( shown + (NOW_MS - MEDIA_SENT_AT) / 1000 ))
    [ "${3}" -gt 0 ] && [ "${shown}" -gt "${3}" ] && shown="${3}"
    [ $(( shown - ${2} )) -lt 2 ] && [ $(( ${2} - shown )) -lt 2 ] && return 0
  else
    dbug "Sending: CMDMEDIA,${1},${2},${3},${4},${5}"
  fi
  echo "CMDMEDIA,${1},${2},${3},${4},${5}" >"${TTYDEV}"
  nap "${CMDWAITSECS:-0.05}"
  MEDIA_SENT="${want}"; MEDIA_SENT_POS="${2}"; MEDIA_SENT_AT="${NOW_MS}"
}

# One look: where the film is, and CMDMEDIA if that is news. 2 when the disc
# has gone, which a pass handles; 0 otherwise.
dvd_tick() {
  local r=0 idx=0 title=0 hi=0 lo=0 dt=0 state=1
  now_ms
  dvd_find || return 2
  [ -n "${DVD_KEY}" ] && [ "${DVD_SCANNED}" = "${DVD_DEV}" ] || return 0
  [ "${#DVD_S[@]}" -gt 0 ] || return 0           # no table: no place to tell
  dvd_telem
  dvd_pos || return 2
  r="${DVD_R}"
  dt=$(( NOW_MS - ${DVD_AT_PREV:-${NOW_MS}} ))
  DVD_AT_PREV="${NOW_MS}"
  # The core says no disc, the descriptor still open: mid-mount. Nothing
  # plays, and nothing is said.
  [ "${DVD_TF}" = "yes" ] && [ "${DVD_MEDIA}" = "0" ] && return 0

  # In a menu: nothing to count. The film after it starts where the read is.
  if [ "${DVD_MENUF}" = "1" ] || { ! dvd_seg "${r}" && dvd_in_menu "${r}"; }; then
    DVD_R_PREV="${r}"; DVD_TITLE=0; DVD_STATE=4
    sendmedia 4 0 0 0 0
    return 0
  fi
  if ! dvd_seg "${r}"; then                       # between titles, say: as it was
    DVD_R_PREV="${r}"
    return 0
  fi
  idx="${_R}"; title="${DVD_TI[idx]}"
  dvd_ms_at "${idx}" "${r}"; hi="${_R}"

  if [ -z "${DVD_R_PREV}" ]; then
    # First seen in the middle of a film - the daemon started, the disc was
    # read just now: the ring is taken to be full.
    DVD_E_MS=0
    if dvd_seg $(( r - DVD_LEAD_FULL )) && [ "${DVD_TI[_R]}" = "${title}" ]; then
      dvd_ms_at "${_R}" $(( r - DVD_LEAD_FULL )); DVD_E_MS="${_R}"
    fi
  elif [ "${title}" != "${DVD_TITLE}" ] || [ "${r}" -lt $(( DVD_R_PREV - DVD_BACK_SECTORS )) ] ||
       [ "${r}" -gt $(( DVD_R_PREV + DVD_JUMP_SECTORS + DVD_JUMP_RATE * dt )) ]; then
    # Gone somewhere - a seek, a chapter, another title, out of the menu:
    # the ring starts again from where the core now is.
    DVD_E_MS="${hi}"
  elif [ "${DVD_TF}" != "yes" ] || [ "${DVD_PAUSE}${DVD_STILL}" = "00" ]; then
    DVD_E_MS=$(( DVD_E_MS + dt ))
  fi
  # Never ahead of the read, never further behind it than the ring holds.
  [ "${DVD_E_MS}" -gt "${hi}" ] && DVD_E_MS="${hi}"
  if dvd_seg $(( r - DVD_LEAD_MAX )) && [ "${DVD_TI[_R]}" = "${title}" ]; then
    dvd_ms_at "${_R}" $(( r - DVD_LEAD_MAX )); lo="${_R}"
    [ "${DVD_E_MS}" -lt "${lo}" ] && DVD_E_MS="${lo}"
  fi
  DVD_R_PREV="${r}"; DVD_TITLE="${title}"

  if [ "${DVD_TF}" = "yes" ] && [ "${DVD_PAUSE}" = "1" ]; then state=2
  elif [ "${DVD_TF}" = "yes" ] && [ "${DVD_STILL}" = "1" ]; then state=5; fi
  DVD_STATE="${state}"
  dvd_chapter "${title}" "${DVD_E_MS}"
  sendmedia "${state}" $(( DVD_E_MS / 1000 )) "${DVD_TOTAL}" "${DVD_CHAPTER}" "${DVD_CHAPTERS}"
  return 0
}

# Between the passes while the DVD core is up: a look every DVD_TICK_SECS
# for up to $1 seconds - less when the core changes, the disc goes, or a
# background job has finished, all of which a pass handles.
dvd_follow() {  # dvd_follow <seconds>
  local end=0 core=""
  now_ms; end=$(( NOW_MS + ${1} * 1000 ))
  nap 0                                          # its pipe, opened once
  while :; do
    core=""; IFS= read -r core 2>/dev/null <"${corenamefile}"
    [ "${core}" = "${oldcore}" ] || return 0
    dvd_tick || return 0
    { bg_running dvs && [ -e "${UC_OUT}.dvs.rc" ]; } && return 0
    { bg_running dvl && [ -e "${UC_OUT}.dvl.rc" ]; } && return 0
    now_ms
    [ "${NOW_MS}" -lt "${end}" ] || return 0
    nap "${DVD_TICK_SECS}"
  done
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
  ICON_SENT="${ICONFILE}"
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
#
# Every command before this one was acknowledged too, and nothing reads those:
# the USB-serial chip holds them while the port is closed, and the first open
# gets the lot - ten or so at startup. So what is already queued is read and
# dropped before asking, and the answer is looked for until a deadline rather
# than for a number of tokens, which a long enough queue used to use up.
CHECKVERSION_SECS=3
checkversion() {  # checkversion [quiet] - quiet: say nothing if there is no answer
  local tok="" fwver="" tries=0 end
  exec 3<"${TTYDEV}" || { dbug "Cannot open ${TTYDEV} for reading"; return 0; }
  while read -t 0.1 -d ';' tok <&3; do tries=$((tries + 1)); done
  [ "${tries}" -gt 0 ] && dbug "Dropped ${tries} queued acknowledgements"
  tries=0
  echo "CMDHWINF" >${TTYDEV}
  end=$(( ${EPOCHSECONDS:-$(date +%s)} + CHECKVERSION_SECS ))
  while [ "${EPOCHSECONDS:-$(date +%s)}" -lt "${end}" ]; do
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
  # It answered: this is the display's port, wherever it is next time.
  [ -n "${fwver}" ] && port_remember "${TTYPORT:-${TTYDEV}}"
  if [ -z "${fwver}" ]; then
    [ "${1:-}" = "quiet" ] || echo "tty2oled+ ${TTY2OLED_VERSION:-unknown} (the display did not answer CMDHWINF)"
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

# The display did not answer CMDHWINF - still booting after a flash or a
# replug, when the daemon asked straight away. Without an answer FW_VERSION is
# empty and everything newer than 0.7.0b is withheld for the life of the
# daemon: the update notice, update_all's status line. So it is asked again,
# FW_ASK_SECS apart, up to FW_ASK_MAX times. Each unanswered try blocks for
# the two seconds checkversion waits; an answered one returns at once.
FW_ASKS=0
FW_ASK_AT=0
FW_ASK_MAX=5
FW_ASK_SECS=10
fw_pass() {
  [ -z "${FW_VERSION}" ] && [ "${DEFERRED_DONE}" = "yes" ] || return 0
  [ "${FW_ASKS}" -lt "${FW_ASK_MAX}" ] || return 0
  local now="${EPOCHSECONDS:-$(date +%s)}"
  [ "${now}" -ge "${FW_ASK_AT}" ] || return 0
  FW_ASKS=$(( FW_ASKS + 1 ))
  dbug "Asking the display its version again (${FW_ASKS} of ${FW_ASK_MAX})"
  checkversion quiet
  if [ -z "${FW_VERSION}" ]; then
    FW_ASK_AT=$(( now + FW_ASK_SECS ))
    [ "${FW_ASKS}" -ge "${FW_ASK_MAX}" ] \
      && echo "tty2oled: the display never said which firmware it runs - the update notice and update_all's status line stay off until the daemon restarts."
  fi
  return 0
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

  FW_ASKS=1; FW_ASK_AT=$(( ${EPOCHSECONDS:-$(date +%s)} + FW_ASK_SECS ))
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

# The time, as the MiSTer's clock and time zone have it: seconds since 1970
# with the zone's offset added, which the firmware counts on from and shows
# as it stands (the band's clock). The offset is %z's hours and minutes: it
# used to go through "date -d 'now +05:30 hour'", which GNU date refuses, so
# India, Nepal, Newfoundland and South Australia were sent nothing at all.
# printf's own strftime, so no process either. Again every TIME_RESEND_SECS
# (time_pass), for drift and for daylight saving.
TIME_RESEND_SECS=3600
TIME_NEXT=0
local_epoch() {  # into LOCAL_EPOCH
  local now="${EPOCHSECONDS:-}" z="" off=0
  [ -n "${now}" ] || printf -v now '%(%s)T' -1
  printf -v z '%(%z)T' -1                    # +0530, -0330, +0000
  if [[ "${z}" =~ ^([+-])([0-9][0-9])([0-9][0-9])$ ]]; then
    off=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 ))
    [ "${BASH_REMATCH[1]}" = "-" ] && off=$(( -off ))
  fi
  LOCAL_EPOCH=$(( now + off ))
}

sendtime() {
  local_epoch
  dbug "Sending: CMDSETTIME,${LOCAL_EPOCH}"
  echo "CMDSETTIME,${LOCAL_EPOCH}" >${TTYDEV}
  cmdwait
  TIME_NEXT=$(( ${EPOCHSECONDS:-0} + TIME_RESEND_SECS ))
}

# The time again, once an hour. Only to firmware that does not take it for
# someone at the MiSTer (0.7.8b): older firmware wakes a dimmed panel for it.
time_pass() {
  [ "${DEFERRED_DONE}" = "yes" ] || return 0
  [ "${EPOCHSECONDS:-0}" -ge "${TIME_NEXT}" ] || return 0
  fw_atleast 0.7.8 || { TIME_NEXT=$(( ${EPOCHSECONDS:-0} + TIME_RESEND_SECS )); return 0; }
  sendtime
}

# The band's clock: its two formats, "<left>|<right>", or nothing for none.
# Sent when it changes, like the notice; "?" is nothing told yet.
CLOCK_SENT="?"
sendclock() {
  local want=""
  if [ "${BAND_CLOCK:-yes}" = "yes" ]; then
    want="${BAND_CLOCK_LEFT-%d/%m/%y}|${BAND_CLOCK_RIGHT-%H:%M}"
    want="${want//[$'\001'-$'\037'$'\177']/}"
    [ "${want}" = "|" ] && want=""
  fi
  [ "${want}" = "${CLOCK_SENT}" ] && return 0
  fw_atleast 0.7.8 || return 0
  dbug "Sending: CMDCLOCK,${want}"
  echo "CMDCLOCK,${want}" >${TTYDEV}
  cmdwait
  CLOCK_SENT="${want}"
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

# The display's port: which one, and how to write to it (tty2oled-port.sh).
# Without it - an install part way through an update - as before it existed.
declare -F ttynode >/dev/null || ttynode() { TTYNODE="${1}"; TTYNODE_WHY="no tty2oled-port.sh"; TTYNODE_ERR=""; }
declare -F port_resolve >/dev/null || port_resolve() { :; }
declare -F port_remember >/dev/null || port_remember() { :; }
declare -F port_find >/dev/null || port_find() { return 1; }

# The display's port, and what the daemon writes through: TTYCONF is TTYDEV
# as the ini has it, TTYPORT the device the display is on (port_resolve),
# TTYDEV our node for it.
TTYCONF=""
TTYPORT=""
ttyalias() {
  [ -n "${TTYPORT}" ] || TTYPORT="${TTYDEV}"
  ttynode "${TTYPORT}"
  TTYDEV="${TTYNODE}"
  [ -n "${TTYNODE_WHY}" ] && dbug "Writing through ${TTYDEV} itself: ${TTYNODE_WHY}"
  [ -z "${TTYNODE_WHY}" ] && [ -n "${TTYNODE_ERR}" ] && dbug "Made ${TTYDEV} after a retry: ${TTYNODE_ERR}"
  port_mark
}

# Someone else writing to the display: Zaparoo's reader probe - once when it
# starts, whatever we do - an updater older than ttynode, anything. Their
# bytes land in whatever we are sending: a picture comes out shifted by them,
# its tail wrapped round, and nothing of ours would ever know. Since we write
# through our own node, the device file's time moves only when another
# program writes through it; when it has, and the writer has had
# PORT_SETTLE_SECS to finish, everything goes out again. The look is a test
# builtin against PORT_REF, a file holding the time last seen: no process.
PORT_REF="${PORT_REF:-/tmp/tty2oledplus.port}"
PORT_DIRTY_AT=""
PORT_RETRY_AT=0
port_mark() {  # the device file's time, as the one to compare with
  [ -n "${TTYPORT}" ] && [ "${TTYDEV}" != "${TTYPORT}" ] || return 0
  touch -r "${TTYPORT}" "${PORT_REF}" 2>/dev/null
  PORT_DIRTY_AT=""
}
port_pass() {
  local now="${EPOCHSECONDS:-$(date +%s)}"
  [ -n "${TTYPORT}" ] || return 0
  if [ "${TTYDEV}" = "${TTYPORT}" ]; then
    # Writing through the device (ttynode found no node): our node again,
    # every PORT_RETRY_SECS, rather than never. Straight after boot the node
    # would not do for about a minute, and every write meanwhile invited a
    # probe.
    [ "${now}" -ge "${PORT_RETRY_AT}" ] || return 0
    PORT_RETRY_AT=$(( now + ${PORT_RETRY_SECS:-10} ))
    ttyalias
    [ "${TTYDEV}" != "${TTYPORT}" ] && dbug "Writing through ${TTYDEV} from now on"
    return 0
  fi
  if [ "${TTYPORT}" -nt "${PORT_REF}" ]; then
    touch -r "${TTYPORT}" "${PORT_REF}" 2>/dev/null
    PORT_DIRTY_AT="${now}"
    dbug "Something else wrote to ${TTYPORT} - redrawing once it is done"
  fi
  [ -n "${PORT_DIRTY_AT}" ] && [ $(( now - PORT_DIRTY_AT )) -ge "${PORT_SETTLE_SECS:-2}" ] || return 0
  PORT_DIRTY_AT=""
  dbug "Redrawing everything after the other writer"
  oldcore=""
  META_WIRE_LAST=""
  NOTE_SENT="?"
  HEAD_SENT="?"
  CLOCK_SENT="?"
  TIMER_SENT="?"; SAM_TIMER_REF=""
  UPDATEALL_SHOWN="no"
  UPDATEALL_BUSY="no"
}

# Unplugged and back under another number? A replug can renumber it: with a
# reader plugged in, the display can go from ttyUSB0 to ttyUSB1. Only where
# the ini names a numbered port, and only for the display remembered.
port_moved() {
  case "${TTYCONF:-}" in /dev/ttyUSB[0-9]*|/dev/ttyACM[0-9]*) ;; *) return 1 ;; esac
  port_find && [ "${PORT_FOUND}" != "${TTYPORT}" ] && [ -c "${PORT_FOUND}" ] || return 1
  dbug "The display is on ${PORT_FOUND} now, not ${TTYPORT}"
  TTYPORT="${PORT_FOUND}"
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
  # The device itself: our node for it stays when it goes.
  if ! [ -c "${TTYPORT:-${TTYDEV}}" ]; then
    if port_moved; then
      TTYGONE="yes"                          # back, on another port: start it again
    else
      [ "${TTYGONE}" = "no" ] && dbug "${TTYPORT:-${TTYDEV}} has gone away, waiting for the display"
      TTYGONE="yes"
      sleep "${TTYWAIT:-2}"
      return 1
    fi
  fi

  [ "${TTYGONE}" = "no" ] && return 0

  # Back. A re-enumerated board has rebooted into its boot screen with the
  # firmware's own defaults, and the line settings went with the old device
  # node, so this is the startup handshake over again rather than a resume.
  TTYGONE="no"
  dbug "${TTYPORT:-${TTYDEV}} is back, re-initialising the display"
  ttyalias
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
  HEAD_SENT="?"
  CLOCK_SENT="?"
  TIMER_SENT="?"; SAM_TIMER_REF=""
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

# The main loop's two waits. inotifywait's 0 is an event and 2 its timeout,
# and both have waited; anything else returned at once - a watched file gone
# in between, the watch limit reached, no inotify-tools - and a loop whose
# wait does not wait is a spin: the metadata path rebuilding the game's
# details, the upstream path resending its picture, as fast as they can.
#
# metawait <seconds> <file...>: the metadata path's, on the state files.
metawait() {
  local t="${1}" rc=0
  shift
  if [ "${debug}" = "false" ]; then
    inotifywait -qq -t "${t}" -e modify,create,moved_to "$@" 2>/dev/null
  else
    inotifywait -t "${t}" -e modify,create,moved_to "$@"
  fi
  rc=$?
  [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ] || sleep "${t}"
  return 0
}

# corewait ["-t <seconds>"]: the upstream path's, on CORENAME alone, with or
# without a timeout. Returns inotifywait's code - 2 is "timed out, look again"
# - after a failure has waited too.
corewait() {
  local rc=0
  # shellcheck disable=SC2086  # "-t N" or nothing
  if [ "${debug}" = "false" ]; then
    inotifywait -qq ${1:-} -e modify "${corenamefile}" 2>/dev/null
  else
    inotifywait ${1:-} -e modify "${corenamefile}"
  fi
  rc=$?
  [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ] || sleep "${UPDATE_ALL_POLL:-2}"
  PROC_PASS=$(( ${PROC_PASS:-0} + 1 ))       # what follows is a new look
  return "${rc}"
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
  port_mark                                  # SAM wrote through the device
  oldcore=""
  META_WIRE_LAST=""
  DEFERRED_DONE="no"
  NOTE_SENT="?"
  HEAD_SENT="?"
  CLOCK_SENT="?"
  TIMER_SENT="?"; SAM_TIMER_REF=""
  return 1
}

# ---------------------------------------------------------------------------
# Degauss and Zaparoo: frontends over the menu core
# ---------------------------------------------------------------------------
#
# MisterZine is launched as a core (MisterZine.mgl), so MiSTer writes its name
# to CORENAME and its banner is found like any other. Degauss is a Scripts
# entry: it draws over the menu core and CORENAME says MENU the whole time.
# All MiSTer writes is the selection of the script - CURRENTPATH "degauss",
# FULLPATH "Scripts" - which outlives it, so the process is the only sign.
#
# Zaparoo's frontend replaces MiSTer's main (main=zaparoo/MiSTer_Zaparoo in
# MiSTer.ini) and runs over its own menu core, zaparoo/menu_zaparoo.rbf, and
# CORENAME says MENU there too. The same binary can load the stock menu.rbf,
# and STARTPATH, which does name the rbf, is never cleared - so again the
# process: MiSTer's main re-execs itself with the rbf it loaded as argv[1],
# keeping its pid, so its command line is always the loaded core's.
#
# While the menu core is up and one of them runs, the daemon takes its name
# for the core: degauss.gsc or zaparoo.gsc by that exact name, else the name
# as text. When it goes the core is MENU again, and the menu's picture goes
# back up like any other core change. A game either launches changes CORENAME
# as usual.
DEGAUSS_CORE="degauss"
ZAPAROO_CORE="zaparoo"
# ScummVM over the menu core. Its Scripts launcher writes ScummVM to CORENAME;
# Zaparoo starts the binary itself, with the game to run as its last argument
# ("scummvmmaster ... lure"), and CORENAME stays MENU. ScummVM has the screen,
# so it wins over whichever frontend started it, and is then the ScummVM core
# in every respect - the game from the command line and all (tty2oled-meta.sh).
SCUMMVM_CORE="ScummVM"

# Which of them is up, into MENU_FRONTEND: SCUMMVM_CORE, DEGAUSS_CORE,
# ZAPAROO_CORE or empty. One grep over /proc finds both; it only narrows the field (busybox
# grep has no -z to anchor on an argument), and the brackets keep it from
# matching its own command line.
#
# Degauss by its binary, argv[0]: Scripts/.config/degauss/degauss, or
# Scripts/.degauss/degauss where v0.1.0 and v0.2.0 installed it. Only argv[0]:
# its own --config argument names degauss/degauss.toml, and so would an
# editor open on that file. It wins over Zaparoo, which it would draw over.
# Zaparoo by the main's argv[1], the rbf: menu_zaparoo.rbf in any folder.
menu_frontend() {
  local f="" a0="" a1="" b=""
  MENU_FRONTEND=""
  # ScummVM already found: its binary still there is a read, not a search -
  # every pass while a game runs, and the game shares the DE10's two cores.
  if [ -n "${SVM_PID:-}" ]; then
    a0=""; IFS= read -r -d '' a0 2>/dev/null <"${PROC_ROOT:-/proc}/${SVM_PID}/cmdline"
    b="${a0##*/}"
    [[ "${b,,}" == scummvm* ]] && { MENU_FRONTEND="${SCUMMVM_CORE}"; return 0; }
  fi
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    a0=""; a1=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null <"${f}"
    # ScummVM's binary by argv[0]'s name, as tty2oled-meta.sh finds it: not
    # its launcher script, nor anything naming its folder.
    b="${a0##*/}"
    [[ "${b,,}" == scummvm* ]] && { MENU_FRONTEND="${SCUMMVM_CORE}"; return 0; }
    case "${a0}" in
      */.config/degauss/degauss|*/.degauss/degauss) MENU_FRONTEND="${DEGAUSS_CORE}"; continue ;;
    esac
    case "${a1##*/}" in
      menu_zaparoo*.rbf) [ -z "${MENU_FRONTEND}" ] && MENU_FRONTEND="${ZAPAROO_CORE}" ;;
    esac
  done
  [ -n "${MENU_FRONTEND}" ]
}

# The core as far as the display is concerned, into CURCORE: CORENAME, except
# that the menu core with ScummVM, Degauss or Zaparoo up is that.
readcore() {
  CURCORE="$(<"${corenamefile}")"
  if [ "${CURCORE}" = "MENU" ] && menu_frontend; then
    CURCORE="${MENU_FRONTEND}"
  fi
}

# Could Degauss start or stop now? Neither touches a state file the daemon
# waits on, so while this holds - the menu core is up, as the menu, Degauss or
# Zaparoo - the waits time out every UPDATE_ALL_POLL seconds to look again.
# Zaparoo itself comes and goes with a core load, which writes CORENAME.
menu_frontend_possible() {
  case "${oldcore}" in
    MENU|"${DEGAUSS_CORE}"|"${ZAPAROO_CORE}") return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The frontends, and a newer tty2oled+ in their band
# ---------------------------------------------------------------------------
#
# The menu, MisterZine, Degauss and Zaparoo are where a game is chosen, and they are
# shown the way the boot screen is: a picture 54 rows tall, and the 10 rows
# under it kept for the display's own notices. Their picture goes out marked
# ",band" (senddata) - the menu's CMDBOOTPIC always is one - with its bottom
# ten rows black, so a 256x64 banner is shown cut down until it is redrawn.
# Names as CORENAME has them, or readcore's for Degauss and Zaparoo; case
# does not matter.
FRONTEND_CORES="menu misterzine ${DEGAUSS_CORE} ${ZAPAROO_CORE}"
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
# whatever has finished. A check that fails is tried again soon rather than
# a whole interval later - UC_RETRY_FIRST, doubling each failure in a row up
# to UC_RETRY_SECS: the first one runs at boot, usually before the network is
# up (curl 6, no name resolved), and waiting the full five minutes for the
# second left the notice off for most of that.
#
# CMDNOTE carries the text to the firmware (0.7.1b and later), which keeps it
# and shows it in the band of every frontend picture: faded in where one is up,
# arriving with the next one where one is not. Only a change is sent.
UPDATE_URL="${UPDATE_URL:-https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/VERSION}"
UPDATE_CACERT="${UPDATE_CACERT:-/etc/ssl/certs/cacert.pem}"   # MiSTer's curl finds none itself
SYSCHECK="${SYSCHECK:-${TTY2OLED_PATH:-/media/fat/tty2oledplus}/tty2oledplus_syscheck.py}"
UC_RETRY_SECS=300
UC_RETRY_FIRST=30
UC_FAILS=0          # failures in a row, each check
SC_FAILS=0
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
HEAD_SENT="?"       # the header's caption, the same way; "" is "Now playing"
SAM_PID=""          # Super Attract Mode's loop, when last seen
SAM_ON="no"         # ...and whether it was
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

update_check_minutes() {  # into UC_MINUTES, and on stdout
  local m="${UPDATE_CHECK_MINUTES:-30}"
  case "${m}" in ''|*[!0-9]*) m=0 ;; esac
  UC_MINUTES="$((10#${m}))"
  printf '%s' "${UC_MINUTES}"
}

# Is this check wanted? Its switch, and an interval to run it at.
update_check_on() {  # update_check_on <TTY2OLED|SYSTEM>
  local on="yes"
  case "${1}" in
    TTY2OLED) on="${UPDATE_CHECK_TTY2OLED:-yes}" ;;
    SYSTEM)   on="${UPDATE_CHECK_SYSTEM:-yes}" ;;
  esac
  [ "${on}" = "yes" ] || return 1
  update_check_minutes >/dev/null             # every pass: no subshell
  [ "${UC_MINUTES}" -gt 0 ]
}

# When the next check is due after one that ended: an interval, or - the
# nth failure in a row - UC_RETRY_FIRST doubled n-1 times, at most
# UC_RETRY_SECS, if that is sooner.
next_after() {  # next_after <now> <failed: yes|no> [failures in a row]
  local secs=$(( $(update_check_minutes) * 60 )) retry="${UC_RETRY_FIRST}" n="${3:-1}"
  if [ "${2}" = "yes" ]; then
    while [ "${n}" -gt 1 ] && [ "${retry}" -lt "${UC_RETRY_SECS}" ]; do
      retry=$(( retry * 2 )); n=$(( n - 1 ))
    done
    [ "${retry}" -gt "${UC_RETRY_SECS}" ] && retry="${UC_RETRY_SECS}"
    [ "${secs}" -gt "${retry}" ] && secs="${retry}"
  fi
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
      UC_FAILS=$(( UC_FAILS + 1 ))
      UC_NEXT="$(next_after "${now}" yes "${UC_FAILS}")"
      dbug "The release check failed (curl ${BG_RC:-stopped}); again in $(( UC_NEXT - now ))s"
    else
      UC_FAILS=0
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
  command -v curl >/dev/null 2>&1 || { UC_NEXT="$(next_after "${now}" yes "${UC_FAILS}")"; return 0; }
  dbug "Looking for a newer tty2oled+ at ${UPDATE_URL}"
  bg_start uc "${now}" uc_fetch
}

# Is a system update running, whatever UPDATE_ALL_SCREEN says? update_all,
# or MiSTer's own updater - Scripts/update.sh, which Zaparoo's Update runs -
# into SYSUPD ("update_all" or "downloader"), with the pid of the latter's
# Downloader, if it has started, in SYSUPD_PID.
#
# update.sh copies the Downloader to /tmp/downloader.sh and runs it; update_all
# uses /tmp/update_all.sh and /tmp/ua_downloader_*, so the names never cross.
# The launcher counts from its start: its time sync and certificate check are
# part of the update, and it outlives the Downloader restarting itself. The
# Downloader runs an update_all step of its own, so anything naming update_all
# under it is its. --list-dbs is a query, not an update.
sysupdate_process() {
  local f a0="" a1="" args=()
  SYSUPD=""; SYSUPD_PID=""
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    args=(); mapfile -d '' -t args 2>/dev/null <"${f}"
    a0="${args[0]:-}"; a1="${args[1]:-}"
    if [ "${a0}" = "/tmp/downloader.sh" ] || [ "${a1%/Scripts/update.sh}" != "${a1}" ]; then
      case " ${args[*]} " in *" --list-dbs "*) continue ;; esac
      SYSUPD="downloader"
      if [ "${a0}" = "/tmp/downloader.sh" ]; then f="${f%/cmdline}"; SYSUPD_PID="${f##*/}"; fi
    elif [ -z "${SYSUPD}" ]; then
      case "${args[*]}" in *update_all*) SYSUPD="update_all" ;; esac
    fi
  done
  [ -n "${SYSUPD}" ]
}
updateall_process() { sysupdate_process; }

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
      dbug "A system update finished - looking for system updates again"
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
          SC_FAILS=0; SC_NEXT="$(next_after "${now}" no)"
          echo "tty2oled: a system update is waiting (${SC_FLAGGED}) - update_all installs it." ;;
        no)
          dbug "No system update waiting"
          SC_FAILS=0; SC_NEXT="$(next_after "${now}" no)" ;;
        nostate)
          dbug "No update_all state to check against - it has not run yet"
          SC_FAILS=0; SC_NEXT="$(next_after "${now}" no)" ;;
        *)
          SC_FAILS=$(( SC_FAILS + 1 ))
          SC_NEXT="$(next_after "${now}" yes "${SC_FAILS}")"
          dbug "The system check failed (${BG_LINE:-exit ${BG_RC:-stopped}}); again in $(( SC_NEXT - now ))s" ;;
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
  text="${text//[$'\001'-$'\037'$'\177']/}"   # every pass: no tr for it
  text="${text:0:${NOTE_COLS}}"
  [ "${text}" = "${NOTE_SENT}" ] && return 0
  fw_atleast 0.7.1 || return 0
  dbug "Sending: CMDNOTE,${text}"
  echo "CMDNOTE,${text}" >${TTYDEV}
  cmdwait
  NOTE_SENT="${text}"
}

# Is MiSTer SAM's Super Attract Mode playing games by itself? Its loop is
# "MiSTer_SAM_on.sh loop_core", in a tmux session, from when it starts to
# when a button takes the game over (play_or_exit kills every
# MiSTer_SAM_on.sh). Its MCP, which starts it after the idle time, runs
# always and is not it. The MiSTer.ini SAM Video bind-mounts is no sign: only
# SAM Video makes it, and it was seen outliving SAM.
#
# The pid is kept and re-read, so a pass with SAM running starts no process;
# its subshells share the command line, so any of them will do.
sam_loop() { case " ${*} " in *"MiSTer_SAM_on.sh loop_core "*) return 0 ;; esac; return 1; }
SAM_SCRIPT="${SAM_SCRIPT:-/media/fat/Scripts/MiSTer_SAM_on.sh}"
sam_running() {
  local f args=()
  [ -e "${SAM_SCRIPT}" ] || return 1          # not installed: no /proc to search
  if [ -n "${SAM_PID}" ]; then
    mapfile -d '' -t args 2>/dev/null <"${PROC_ROOT:-/proc}/${SAM_PID}/cmdline"
    sam_loop "${args[@]}" && return 0
    SAM_PID=""
  fi
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    args=(); mapfile -d '' -t args 2>/dev/null <"${f}"
    if sam_loop "${args[@]}"; then f="${f%/cmdline}"; SAM_PID="${f##*/}"; return 0; fi
  done
  return 1
}

# The layouts' header: SAM_HEADER_TEXT while Super Attract Mode runs, else
# "Now playing" (empty on the wire). Sent before the pass's pictures, so a
# game SAM loads is drawn with it; on its own when SAM stops under a game.
sam_pass() {
  local want=""
  SAM_ON="no"
  if [ "${SAM_HEADER:-yes}" = "yes" ] && fw_atleast 0.7.7 && sam_running; then
    SAM_ON="yes"
    want="${SAM_HEADER_TEXT:-Super Attract Mode}"
  fi
  sendhead "${want}"
  samtimer_pass
}

# The time to SAM's next game, after its caption (CMDHTIMER, 0.7.8b).
#
# SAM writes the game it launches to /tmp/SAM_Game.txt, tells MiSTer to load
# it, waits a second, and then counts its gametimer down (run_countdown_timer
# in MiSTer_SAM_on.sh) - so the next game is due about the file's time, plus
# one, plus gametimer. That goes out the moment a game is new; the firmware
# counts it down itself. gametimer is MiSTer_SAM.ini's (120 by default), 21
# in M82 mode, whatever the ini says. SAM Video does not change it: its games
# are timed the same way, and a video in between is played over menu.rbf -
# the menu's picture, no header to show a count in - and writes no
# SAM_Game.txt, so the game after it starts a count of its own.
#
# "About", because SAM's second is a "sleep 1" and the rest of its loop,
# which on the DE10 is 180 counts in ~190 real seconds: a count from the
# clock ran out ten seconds early and sat at 0:00. So SAM's own count is read
# as well - "Next game in N...", the last line of its tmux session's pane -
# a look shortly after the game starts, every SAM_LOOK_SECS, and every pass
# in the last SAM_LOOK_NEAR seconds, and the firmware is corrected when it is
# two seconds or more out. A look is a tmux client, ~50ms; a pass without one
# is a test of the file's time against a copy of it (SAM_STAMP), no process.
SAM_INI="${SAM_INI:-/media/fat/Scripts/MiSTer_SAM.ini}"
SAM_GAMEFILE="${SAM_GAMEFILE:-/tmp/SAM_Game.txt}"
SAM_STAMP="${SAM_STAMP:-/tmp/.tty2oledplus-samgame}"
SAM_SESSION="SAM"
SAM_LOOK_SECS=30
SAM_LOOK_NEAR=15
TIMER_SENT="?"       # the seconds last sent, "" none, "?" nothing told yet
TIMER_AT=0           # ...and when
SAM_TIMER_REF=""     # "yes" once the current game's timer is worked out
SAM_LOOKED=0         # when SAM's own count was last read

# gametimer, as SAM will use it, into SAM_GAMETIMER; fails on a value that is
# not a number.
sam_gametimer() {
  local line="" k="" v="" timer="120" m82="no"
  SAM_GAMETIMER=""
  if [ -r "${SAM_INI}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "${line}" == *=* ]] || continue
      k="${line%%=*}"; v="${line#*=}"
      v="${v%%#*}"; v="${v//[\"\' ]/}"
      case "${k}" in
        gametimer) timer="${v}" ;;
        m82)       m82="${v,,}" ;;
      esac
    done <"${SAM_INI}"
  fi
  [ "${m82}" = "yes" ] && timer=21
  case "${timer}" in ''|*[!0-9]*) return 1 ;; esac
  SAM_GAMETIMER="$(( 10#${timer} ))"
}

# SAM's own count, into SAM_COUNT: the last line of its pane, when that is
# "Next game in N..." - not during a video, a load, or with no tmux at all.
sam_counter() {
  local out="" line=""
  SAM_COUNT=""
  out="$(tmux capture-pane -p -t "${SAM_SESSION}" 2>/dev/null)" || return 1
  line="${out##*$'\n'}"
  [[ "${line}" =~ ^[[:space:]]*Next\ game\ in\ ([0-9]+) ]] || return 1
  SAM_COUNT="$(( 10#${BASH_REMATCH[1]} ))"
}

sendtimer() {  # sendtimer <seconds, or empty for none>
  [ "${1}" = "${TIMER_SENT}" ] && return 0
  fw_atleast 0.7.8 || return 0
  dbug "Sending: CMDHTIMER,${1}"
  echo "CMDHTIMER,${1}" >${TTYDEV}
  cmdwait
  TIMER_SENT="${1}"
  TIMER_AT="${EPOCHSECONDS:-$(date +%s)}"
}

samtimer_pass() {
  local mt="" left="" now="${EPOCHSECONDS:-$(date +%s)}" shown=0
  if [ "${SAM_ON}" != "yes" ] || [ "${SAM_TIMER:-yes}" != "yes" ]; then
    SAM_TIMER_REF=""
    sendtimer ""
    return 0
  fi
  [ -r "${SAM_GAMEFILE}" ] || return 0

  # A new game - the file's time moved: its count from the clock, at once.
  if [ -z "${SAM_TIMER_REF}" ] || [ "${SAM_GAMEFILE}" -nt "${SAM_STAMP}" ]; then
    touch -r "${SAM_GAMEFILE}" "${SAM_STAMP}" 2>/dev/null
    SAM_TIMER_REF="yes"; SAM_LOOKED=0
    mt="$(stat -c %Y "${SAM_GAMEFILE}" 2>/dev/null)"
    if [[ "${mt}" =~ ^[0-9]+$ ]] && sam_gametimer; then
      left=$(( mt + 1 + SAM_GAMETIMER - now ))
      [ "${left}" -gt $(( SAM_GAMETIMER + 1 )) ] && left=$(( SAM_GAMETIMER + 1 ))
      # A file from before this SAM session's first game: nothing to count.
      [ "${left}" -gt 0 ] || left=""
    fi
    # Sent even when it is the same number as the last game's: the display is
    # still counting that one, at 0:00 by now. It went unsent when two games
    # both came out at 180.
    TIMER_SENT="?"
    sendtimer "${left}"
    return 0
  fi

  # A count running: put right from SAM's own, now and then.
  case "${TIMER_SENT}" in ''|'?') return 0 ;; esac
  shown=$(( TIMER_SENT - (now - TIMER_AT) ))
  [ "${shown}" -lt 0 ] && shown=0
  [ $(( now - SAM_LOOKED )) -ge "${SAM_LOOK_SECS}" ] || [ "${shown}" -le "${SAM_LOOK_NEAR}" ] || return 0
  SAM_LOOKED="${now}"
  sam_counter || return 0
  [ $(( SAM_COUNT - shown )) -ge 2 ] || [ $(( shown - SAM_COUNT )) -ge 2 ] || return 0
  dbug "SAM says ${SAM_COUNT}s to its next game, the display ${shown}s"
  TIMER_SENT="?"
  sendtimer "${SAM_COUNT}"
}

sendhead() {
  local text="${1//[![:print:]]/}"             # every pass: no process for it
  text="${text:0:24}"
  [ "${text}" = "${HEAD_SENT}" ] && return 0
  fw_atleast 0.7.7 || return 0
  dbug "Sending: CMDHEAD,${text}"
  echo "CMDHEAD,${text}" >${TTYDEV}
  cmdwait
  HEAD_SENT="${text}"
}

# The notice for what is waiting: one, the other, both, or none.
update_note() { update_note_into; printf '%s' "${NOTE_WANT}"; }
update_note_into() {  # into NOTE_WANT: every pass, so no subshell
  local t="no" y="no"
  NOTE_WANT=""
  update_check_on TTY2OLED && update_flagged && t="yes"
  update_check_on SYSTEM && [ -n "${SC_FLAGGED}" ] && y="yes"
  case "${t}${y}" in
    yesyes) NOTE_WANT="${UPDATE_NOTE_BOTH_TEXT:-TTY2OLED+ & System Update Available}" ;;
    yesno)  NOTE_WANT="${UPDATE_NOTE_TEXT:-TTY2OLED+ Update Available}" ;;
    noyes)  NOTE_WANT="${UPDATE_NOTE_SYSTEM_TEXT:-System Update Available}" ;;
  esac
}

# Once a pass, whatever else the pass does: never blocks. The band's clock
# and the time it counts from go with it - the notice's neighbours.
updatenote_pass() {
  local now="${EPOCHSECONDS:-$(date +%s)}"
  uc_pass "${now}"
  sc_pass "${now}"
  update_note_into
  sendnote "${NOTE_WANT}"
  sendclock
  time_pass
}

# ---------------------------------------------------------------------------
# update_all screen
# ---------------------------------------------------------------------------

# Is update_all running - or MiSTer's own updater, which gets the same screens
# (sysupdate_process says which)? Neither leaves a state file behind or
# touches CORENAME - both can be started from the Scripts menu or from inside
# a frontend, MiSTerZine or Zaparoo - so the only reliable sign is the
# process itself. One grep over every command line: update_all.sh, and the
# update_all.pyz it hands over to, both carry the name. The brackets keep
# grep's own command line, which holds the patterns, from matching it.
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
  local f="" args=()
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    args=(); mapfile -d '' -t args 2>/dev/null <"${f}"
    case " ${args[*]} " in *ua_downloader*) ;; *) continue ;; esac
    case " ${args[*]} " in *--list-dbs*) continue ;; esac
    return 0
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
  if [ -n "${2:-}" ]; then arg="${1},${2//,/}"; fi
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

# Out of the split layout / card first, or the card alternation would keep
# drawing the previous game over the update screen.
sendmetaoff_ua() {
  [ "${SHOW_METADATA}" = "yes" ] || return 0
  dbug "Sending: CMDMETAOFF (update_all)"
  echo "CMDMETAOFF" >${TTYDEV}
  sleep ${WAITSECS}
  META_WIRE_LAST="OFF"
}

# Show the update_all picture in place of whatever core is loaded, cropped to
# the top 54 rows like a boot image so the band below is free for the busy
# bar. Exact names only - the core lookup's prefix trimming would happily settle on some
# unrelated arcade set starting with "upd". With no picture it falls back to
# the name as text, which is what the firmware does with any line it does not
# recognise - the same thing a missing core banner gets.
sendupdateall() {
  local name="update_all" pic=""
  sendmetaoff_ua
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
  selfupdate_pids >/dev/null
  for p in ${SELFUPD_PIDS}; do
    case " ${SELFUPDATE_OURS:-} " in *" ${p} "*) continue ;; esac
    return 0
  done
  return 1
}

selfupdate_pids() {  # into SELFUPD_PIDS, and on stdout
  local f p args=()
  SELFUPD_PIDS=""
  proc_hits
  for f in "${PROC_HITS[@]}"; do
    args=(); mapfile -d '' -t args 2>/dev/null <"${f}"
    # A shell running the script, by its file name - not any command line
    # with the name in it: the update flag is /tmp/tty2oledplus_update, and
    # a "cat" of it put "Updating TTY2OLED+..." on the panel.
    case "${args[0]##*/}" in bash|sh) ;; *) continue ;; esac
    case "${args[1]:-}" in */tty2oledplus_update.sh|tty2oledplus_update.sh|*/update_tty2oledplus.sh|update_tty2oledplus.sh) ;; *) continue ;; esac
    p="${f%/cmdline}"; SELFUPD_PIDS="${SELFUPD_PIDS}${p##*/} "
  done
  printf '%s' "${SELFUPD_PIDS}"
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
#
# Followed, not re-read. Once trusted the file is held open (UA_FD) and each
# look reads only the lines added since, with bash's own read: no process is
# started, which is what lets the line keep up with the MiSTer's screen - a
# tail, tr and awk per look cost the DE10 ~50ms, and the stat and two /proc
# scans beside them as much again. A file replaced under it (not the one open
# any more, -ef) or cut short (smaller than at the last once-a-second look)
# is opened again from the start.
UA_PRINTLOG="${UA_PRINTLOG:-/tmp/update_all_print.log}"
# Written when update_all exits; where the verdict is looked for if the print
# log had none - an update_all too old to write one.
UA_FINALLOG="${UA_FINALLOG:-/media/fat/Scripts/.config/update_all/update_all.log}"
UA_LINE_COLS=51     # the 5x7 status line's width, 256 pixels / 5
# How often the status line is looked at while it follows the log, on
# firmware that takes it without the 15ms acknowledgement delay every other
# command costs (0.7.3b): ten a second. Each is a line of 60 bytes or so -
# about 5% of the port at 115200 - and the panel redraws a frame the busy bar
# redraws hundreds of times a second anyway. Only a change is sent, and only
# the latest: a burst of files between two looks shows the last of them.
UA_LINE_MS=100
UA_FD=""            # the print log, open once trusted
# The file this run's line comes from: update_all's print log, or MiSTer's
# own Downloader's log (dl_findlog). Set when a run is first seen.
UA_LOG="${UA_PRINTLOG}"
# Where the Downloader leaves its log once it has finished: the verdict.
DL_FINALLOG="${DL_FINALLOG:-/media/fat/Scripts/.config/downloader/downloader.log}"

# Milliseconds, for the finish screen's minimum time.
ms_now() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "${t}" ]; then t="${t//[.,]/}"; echo "$(( 10#${t} / 1000 ))"
  else echo "$(( $(date +%s) * 1000 ))"; fi
}

# The same into NOW_MS, without the subshell a $(ms_now) costs.
now_ms() {
  local t="${EPOCHREALTIME:-}"
  if [ -n "${t}" ]; then t="${t//[.,]/}"; NOW_MS=$(( 10#${t} / 1000 ))
  else NOW_MS=$(( $(date +%s) * 1000 )); fi
}

# Sleep without starting a process: a read that times out on a pipe nothing
# ever writes to. The external sleep where that cannot be set up.
NAP_FD=""
nap() {  # nap <seconds, fractions allowed>
  if [ -z "${NAP_FD}" ]; then
    { exec {NAP_FD}<> <(:); } 2>/dev/null || NAP_FD="none"   # braced: see ua_openlog
  fi
  if [ "${NAP_FD}" = "none" ]; then sleep "${1}"; return 0; fi
  read -r -t "${1}" -u "${NAP_FD}" _ 2>/dev/null
  return 0
}

ua_logref() { stat -c '%i %Y' "${UA_PRINTLOG}" 2>/dev/null; }

# One line of update_all's output into the run's state: UA_VERDICT (ok,
# failed), UA_RUNTIME, UA_LINE - the last useful line - and the UA_MAIN latch,
# which "Sequence:" sets: the main run has begun, and from there to the end is
# all update, downloader or not - unless the countdown's "Press <UP>, To enter
# the SETTINGS" follows, which update_all prints under a first listing of the
# sequence (2.11) and which undoes it. Rules, blank lines and the downloader's
# progress dots are not useful; nor are its DUPLICATED warnings, which come in
# hundreds and say nothing about progress. A carriage return starts a line
# over; anything but printable ASCII - a box drawn in UTF-8 - goes.
#
# Expects the C locale, which its callers set once (ua_readlog, ua_parselog):
# switching it here, per line, was a third of what a line cost on the DE10.
ua_takeline() {
  local l="${1}" seg rt='[0-9][0-9:]*\.[0-9]+s'
  while :; do
    seg="${l%%$'\r'*}"
    # MiSTer's own Downloader: its summary is no status - "none." under
    # "Errors:" was the last line shown before the finish. update_all's print
    # log relays the same summary mid-run, with more to come after it.
    case "${seg}" in *" Run time: "*) [ "${UA_KIND:-}" = "downloader" ] && UA_DLSUM="yes" ;; esac
    case "${seg}" in
      *Success!*|*"There were some errors in the Updaters"*|*"Update All "*|*Sequence:*|*"To enter the SETTINGS"*)
        ua_clean "${seg}"; seg="${UA_TRIMMED}"
        case "${seg}" in
          Success!*) UA_VERDICT="ok" ;;
          "There were some errors in the Updaters"*) UA_VERDICT="failed" ;;
          "Update All "*) [[ "${seg}" =~ ${rt} ]] && UA_RUNTIME="${BASH_REMATCH[0]%.*}" ;;
          Sequence:*) UA_MAIN="yes" ;;
          # The countdown in front of the settings screen: update_all lists
          # the sequence first, then asks - the run has not begun. It lists
          # it again, on a cleared screen, once it does.
          *"To enter the SETTINGS"*) UA_MAIN="no" ;;
        esac ;;
      *) ua_clean "${seg}" ;;
    esac
    [ -n "${UA_CLEAN}" ] && [ "${UA_DLSUM:-}" != "yes" ] && UA_LINE="${UA_CLEAN}"
    [ "${l}" != "${l#*$'\r'}" ] || break
    l="${l#*$'\r'}"
  done
}

# One segment of a line: printable ASCII only, trimmed, into UA_TRIMMED; and
# into UA_CLEAN as the status line would show it, or empty when it is not a
# useful line.
ua_clean() {
  local seg="${1}" head rest
  # A terminal's escape sequences - bold, the screen cleared in front of the
  # second "Sequence:" - are not text; the ESC alone would leave "[1m" behind.
  while [[ "${seg}" == *$'\e['* ]]; do
    head="${seg%%$'\e['*}"; rest="${seg#*$'\e['}"
    rest="${rest#"${rest%%[!0-9;?]*}"}"
    seg="${head}${rest:1}"
  done
  seg="${seg//[^ -~]/}"
  seg="${seg#"${seg%%[! ]*}"}"; seg="${seg%"${seg##*[! ]}"}"
  UA_TRIMMED="${seg}"; UA_CLEAN=""
  [ -n "${seg}" ] || return 0
  # A rule, or dots: nothing but these. A glob - a regex is compiled afresh
  # every time.
  [[ "${seg}" == *[!-#=*._\ ]* ]] || return 0
  [ "${seg#DUPLICATED:}" = "${seg}" ] || return 0
  # The Downloader's own log (MiSTer's updater) has its debug lines and
  # Python's tracebacks in it; update_all's print log has neither.
  case "${seg}" in "DEBUG|"*|"Traceback ("*|"File \""*) return 0 ;; esac
  UA_CLEAN="${seg#- }"
}

# The last useful line of the ones held back, newest first. A burst of the
# downloader's output is hundreds of lines between two looks, and only the
# last useful one is ever shown - so only that one, and whatever useless
# lines follow it, are worked over.
UA_CAND=()
ua_takecand() {
  local i
  [ "${UA_DLSUM:-}" = "yes" ] && { UA_CAND=(); return 0; }
  for (( i = ${#UA_CAND[@]} - 1; i >= 0; i-- )); do
    case "${UA_CAND[i]}" in ""|DUPLICATED:*|"DEBUG|"*) continue ;; esac
    ua_clean "${UA_CAND[i]}"
    [ -n "${UA_CLEAN}" ] && { UA_LINE="${UA_CLEAN}"; break; }
  done
  UA_CAND=()
}

# One line into the run's state, the cheap way: a line that can say anything
# but "this is what is happening now" - the verdict, the run time, Sequence:,
# a carriage return - is taken in full and in order; any other is held back
# for ua_takecand. The two give what ua_takeline gives over every line.
ua_feed() {
  case "${1}" in
    *Success!*|*"There were some errors in the Updaters"*|*"Update All "*|*Sequence:*|*"To enter the SETTINGS"*|*" Run time: "*|*$'\r'*)
      ua_takecand; ua_takeline "${1}" ;;
    ""|DUPLICATED:*|"DEBUG|"*) ;;
    *) UA_CAND+=("${1}")
       # Resolved rather than cut, or a useful line followed by a run of rules
       # would be lost with them.
       [ "${#UA_CAND[@]}" -ge 64 ] && ua_takecand ;;
  esac
}

# The same over a whole file on stdin, three lines out - verdict, run time,
# line - for update_all's own log, read once when it has gone.
ua_parselog() {
  local LC_ALL=C UA_VERDICT="" UA_RUNTIME="" UA_LINE="" UA_MAIN="" UA_DLSUM="" UA_CAND=() l
  while IFS= read -r l || [ -n "${l}" ]; do ua_feed "${l}"; done
  ua_takecand
  printf '%s\n%s\n%s\n' "${UA_VERDICT}" "${UA_RUNTIME}" "${UA_LINE}"
}

ua_closelog() {
  [ -n "${UA_FD}" ] && exec {UA_FD}<&-
  UA_FD=""; UA_SIZE=0; UA_PARTIAL=""
}

# Open the print log, from the start, with the run's state as it would be
# having read none of it.
ua_openlog() {
  ua_closelog
  UA_VERDICT=""; UA_RUNTIME=""; UA_LINE=""; UA_DLSUM=""; UA_CAND=()
  # Braced: on exec with no command a redirection is the shell's for good,
  # and "2>/dev/null" there silenced the daemon's errors from then on.
  { exec {UA_FD}<"${UA_LOG}"; } 2>/dev/null || { UA_FD=""; return 0; }
  UA_SIZE="$(stat -c %s "${UA_LOG}" 2>/dev/null || echo 0)"
}

# What update_all has added since the last look, into the run's state.
# "slow" also checks the file is still the one open and no shorter than what
# has been read, which costs a stat; "final" takes a last line with no newline
# too, since nothing more is coming.
ua_readlog() {  # ua_readlog [slow|fast|final]
  local how="${1:-slow}" l size
  # C, for byte-wise patterns; set here unless the caller has (ua_follow sets
  # it once for all its looks - each switch costs the DE10 half a millisecond).
  [ "${LC_ALL:-}" = "C" ] || local LC_ALL=C
  if [ -z "${UA_FD}" ]; then
    [ "${how}" = "fast" ] && return 0
    [ -n "${UA_LOG}" ] && [ -r "${UA_LOG}" ] || return 0
    if [ "${UA_LOG_FRESH:-no}" != "yes" ]; then
      [ "$(ua_logref)" = "${UA_LOG_REF:-}" ] && return 0
      UA_LOG_FRESH="yes"
    fi
    ua_openlog
    [ -n "${UA_FD}" ] || return 0
  elif ! [ "${UA_LOG}" -ef "/dev/fd/${UA_FD}" ]; then
    [ -r "${UA_LOG}" ] || return 0
    ua_openlog; [ -n "${UA_FD}" ] || return 0
  elif [ "${how}" != "fast" ]; then
    # Cut short and written again: smaller than it was a look ago.
    size="$(stat -c %s "${UA_LOG}" 2>/dev/null)"
    if [ -n "${size}" ] && [ "${size}" -lt "${UA_SIZE:-0}" ]; then
      ua_openlog; [ -n "${UA_FD}" ] || return 0
    fi
    UA_SIZE="${size:-0}"
  fi
  # Everything new at once: mapfile takes a line in a fifteenth of the time a
  # read loop does, which is the difference that matters when the downloader
  # has printed five hundred lines since the last look. Newlines kept, so a
  # last line still being written can be told from a whole one.
  UA_NEW=()
  mapfile -u "${UA_FD}" UA_NEW
  [ "${#UA_NEW[@]}" -gt 0 ] && ua_absorb
  if [ "${how}" = "final" ] && [ -n "${UA_PARTIAL}" ]; then
    ua_feed "${UA_PARTIAL}"; UA_PARTIAL=""; ua_takecand
  fi
  return 0
}

# The lines just read, in UA_NEW, into the run's state.
ua_absorb() {
  local n="${#UA_NEW[@]}" l
  if [ -n "${UA_PARTIAL}" ]; then UA_NEW[0]="${UA_PARTIAL}${UA_NEW[0]}"; UA_PARTIAL=""; fi
  if [ "${UA_NEW[n-1]}" = "${UA_NEW[n-1]%$'\n'}" ]; then
    UA_PARTIAL="${UA_NEW[n-1]}"; unset 'UA_NEW[n-1]'
  fi
  UA_NEW=("${UA_NEW[@]%$'\n'}")
  # Only a line that says more than "this is happening" - the verdict, the
  # run time, Sequence:, a carriage return - needs taking one by one, and a
  # run has a handful. Looked for once, over the whole batch.
  local IFS=$'\n' all
  all="${UA_NEW[*]}"
  case "${all}" in
    *Success!*|*"There were some errors in the Updaters"*|*"Update All "*|*Sequence:*|*"To enter the SETTINGS"*|*" Run time: "*|*$'\r'*)
      for l in "${UA_NEW[@]}"; do ua_feed "${l}"; done ;;
    *) UA_CAND+=("${UA_NEW[@]}") ;;
  esac
  ua_takecand
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
  local out; ua_shorten_into out "${1}"; printf '%s' "${out}"
}
# Into a variable of the caller's - no subshell. Its own names are odd so they
# cannot hide the caller's variable from printf -v.
ua_shorten_into() {  # ua_shorten_into <variable> <text>
  local _us_s="${2}" _us_max="${UA_LINE_COLS}"
  if [ "${#_us_s}" -gt "${_us_max}" ]; then
    case "${_us_s}" in
      */*) _us_s="...${_us_s: -$((_us_max - 3))}" ;;
      *)   _us_s="${_us_s:0:$((_us_max - 3))}..." ;;
    esac
  fi
  printf -v "${1}" '%s' "${_us_s}"
}

# The status line under the busy label. Only what changed goes out, and only
# to firmware that knows the command - to any other it would be drawn as text.
# Firmware that takes it without the acknowledgement delay (0.7.3b) needs no
# wait after it either: the next look is UA_LINE_MS away.
sendbusyline() {  # sendbusyline <text> [fast: the caller knows it is 0.7.3b or later]
  local line
  ua_shorten_into line "${1}"
  [ "${line}" = "${BUSYLINE_LAST:-}" ] && return 0
  if [ "${2:-}" != "fast" ]; then fw_atleast 0.7.0 || return 0; fi
  BUSYLINE_LAST="${line}"
  dbug "Sending: CMDBUSYLINE,${line}"
  echo "CMDBUSYLINE,${line}" >${TTYDEV}
  [ "${2:-}" = "fast" ] || fw_atleast 0.7.3 || cmdwait
}

# Follow the log for <ms>, sending its line each time it changes, and never
# starting a process to do it. Returns early with a verdict, for the pass to
# put the finish up at once.
#
# A look that finds nothing new is five statements: on the DE10 each costs
# 50-100us, so what is not needed every tenth of a second is not done then.
ua_follow() {  # ua_follow <ms>
  local end secs t LC_ALL=C
  printf -v secs '%d.%03d' $(( UA_LINE_MS / 1000 )) $(( UA_LINE_MS % 1000 ))
  now_ms; end=$(( NOW_MS + ${1} ))
  nap 0                                          # its pipe, opened once
  while :; do
    if [ "${UA_LOG}" -ef "/dev/fd/${UA_FD}" ]; then
      mapfile -u "${UA_FD}" UA_NEW
      if [ "${#UA_NEW[@]}" -gt 0 ]; then
        ua_absorb
        [ -n "${UA_VERDICT}" ] && return 0
        [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ] && sendbusyline "${UA_LINE}" fast
      fi
    else
      ua_readlog fast                            # replaced: opened again
      [ -z "${UA_FD}" ] && return 0
    fi
    t="${EPOCHREALTIME//[.,]/}"
    [ $(( 10#${t} / 1000 )) -lt "${end}" ] || return 0
    if [ "${NAP_FD}" = "none" ]; then sleep "${secs}"
    else read -r -t "${secs}" -u "${NAP_FD}" _; fi
  done
}

# Is the status line following the log closely right now?
ua_following() {
  [ "${UPDATEALL_BUSY:-no}" = "yes" ] && [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ] \
    && [ -n "${UA_FD}" ] && [ -z "${UA_DONE_AT:-}" ] && fw_atleast 0.7.3
}

# MiSTer's own Downloader keeps its log open in /tmp under a name Python's
# tempfile picks (tmp and eight characters), and moves it to DL_FINALLOG when
# it is done. Found through its descriptors, once it has started; new with
# every run, so trusted at once.
dl_findlog() {
  local l
  [ -n "${SYSUPD_PID}" ] || return 1
  l="$(ls -l "${PROC_ROOT:-/proc}/${SYSUPD_PID}/fd" 2>/dev/null \
       | awk '$(NF-1) == "->" && $NF ~ /\/tmp[a-z0-9_]+$/ { print $NF; exit }')"
  [ -n "${l}" ] && [ -r "${l}" ] || return 1
  UA_LOG="${l}"; UA_LOG_FRESH="yes"
}

# What the Downloader has open right now under /media - the file it is
# checking or writing - into DL_OPEN, as a path from the drive's root
# (games/mame/intcup94.zip). Its log reaches the file in 8KB bursts, minutes
# apart, where update_all's print log is written line by line; this is what
# keeps the status line live between them. Its own files under
# Scripts/.config are not progress.
dl_openfile() {
  local f
  DL_OPEN=""
  [ -n "${SYSUPD_PID}" ] || return 1
  f="$(ls -l "${PROC_ROOT:-/proc}/${SYSUPD_PID}/fd" 2>/dev/null \
       | awk '$(NF-1) == "->" && $NF ~ /^\/media\// && $NF !~ /\/Scripts\/\.config\// { f = $NF } END { print f }')"
  [ -n "${f}" ] || return 1
  DL_OPEN="${f#/media/*/}"
}

# Its summary, from the log it leaves: "Run time: 05:26.71s", and "Errors:"
# with "none." under it, or what failed. A run stopped part way - Zaparoo's
# Cancel - has none, and gets no finish screen. Only a log written since the
# run was seen.
dl_readfinal() {
  local l errs="" v="" rt=""
  [ -r "${DL_FINALLOG}" ] || return 0
  [ "$(stat -c %Y "${DL_FINALLOG}" 2>/dev/null || echo 0)" -ge "${UA_SEEN_AT:-0}" ] || return 0
  while IFS= read -r l || [ -n "${l}" ]; do
    l="${l%$'\r'}"
    case "${l}" in
      *" Run time: "*)
        rt="${l#* Run time: }"; rt="${rt%%[ s]*}"; rt="${rt%.*}"; v=""; errs="" ;;
      Errors:) errs="yes" ;;
      *)
        if [ "${errs}" = "yes" ] && [ -n "${l//[[:space:]]/}" ]; then
          if [ "${l}" = "none." ]; then v="ok"; else v="failed"; fi
          errs=""
        fi ;;
    esac
  done < <(tail -c 16384 "${DL_FINALLOG}" | grep -av '^DEBUG|')
  UA_VERDICT="${v}"
  [ -n "${v}" ] && UA_RUNTIME="${rt}"
  return 0
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
    [ "${UA_KIND:-}" = "downloader" ] && UA_DONE_LINE="Some files failed - see the log"
  fi
  dbug "${UA_KIND:-update_all} is done: ${UA_VERDICT}"
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
      ua_closelog; UA_VERDICT=""; UA_RUNTIME=""; UA_LINE=""
      UA_KIND="${SYSUPD}"; UA_LOG="${UA_PRINTLOG}"; UA_DLSUM=""; DL_LOGLAST=""
      # MiSTer's own updater asks nothing first: all of it is the update. Its
      # line comes from its own log, once the Downloader is running.
      [ "${UA_KIND}" = "downloader" ] && { UA_MAIN="yes"; UA_LOG=""; }
    fi
    [ "${UA_KIND}" = "downloader" ] && [ -z "${UA_LOG}" ] && dl_findlog
    if [ "${UPDATEALL_SHOWN:-no}" != "yes" ]; then
      dbug "${UA_KIND} is running"
      if [ "${UA_KIND}" = "downloader" ]; then
        # No update_all picture: the label takes the panel straight from the
        # frontend's, with the effect - it replaces what was there.
        sendmetaoff_ua
        sendbusy 1 "${UPDATE_ALL_TEXT:-Updating System ...}" "${TRANSITION}"
        UPDATEALL_BUSY="yes"; BUSYLINE_LAST=""
      else
        sendupdateall
        UPDATEALL_BUSY="no"
      fi
      UPDATEALL_SHOWN="yes"
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
      # once - its own update, then the main run. MiSTer's own updater is
      # nothing but its Downloader.
      elif [ "${UA_KIND}" = "downloader" ] || downloader_running || [ "${UA_MAIN}" = "yes" ]; then
        # The download is the part that takes minutes, so it gets the panel:
        # UPDATING above the bar, the banner gone. The firmware ignores a
        # repeat of the same label, so re-sending it costs a command and
        # nothing else.
        if [ "${UPDATEALL_BUSY:-no}" != "yes" ]; then
          sendbusy 1 "${UPDATE_ALL_TEXT:-Updating System ...}"
          UPDATEALL_BUSY="yes"
          BUSYLINE_LAST=""
        fi
        if [ "${UPDATE_ALL_DETAILS:-yes}" = "yes" ]; then
          # MiSTer's own Downloader: a new line of its log, else the file it
          # has open, else nothing - what is up stays up. Its log says nothing
          # for the first minutes, and the line went blank (or back to an old
          # log line) whenever a look found nothing open.
          if [ "${UA_KIND}" != "downloader" ] || [ "${UA_DLSUM:-}" = "yes" ]; then
            sendbusyline "${UA_LINE}"
          elif [ "${UA_LINE}" != "${DL_LOGLAST:-}" ]; then
            sendbusyline "${UA_LINE}"
          elif dl_openfile; then
            sendbusyline "${DL_OPEN}"
          fi
          DL_LOGLAST="${UA_LINE}"
        fi
      elif [ "${UPDATEALL_BUSY:-no}" = "yes" ]; then
        # Back to the banner: the label blacked it out, so it has to go again.
        sendbusy 0; UPDATEALL_BUSY="no"; sendupdateall
      fi
    fi
    # The rest of the look: the line followed closely, or a plain wait. The
    # process checks - update_all, the downloader - stay at this pace.
    if ua_following; then ua_follow "$(( $(ua_poll) * 1000 ))"
    else sleep "$(ua_poll)"; fi
    return 0
  fi
  if [ "${UPDATEALL_SHOWN:-no}" = "yes" ]; then
    # It may have printed its verdict and exited between two looks.
    if [ -z "${UA_DONE_AT:-}" ] && ua_finishes \
       && { [ "${UPDATEALL_BUSY:-no}" = "yes" ] || [ "${UA_MAIN:-no}" = "yes" ]; }; then
      if [ "${UA_KIND:-}" = "downloader" ]; then
        dl_readfinal
      else
        ua_readlog final
        [ -n "${UA_VERDICT}" ] || ua_readfinal
      fi
      [ -n "${UA_VERDICT}" ] && ua_done
    fi
    ua_holddone
    dbug "${UA_KIND:-update_all} finished, back to the core"
    [ "${UPDATEALL_BUSY:-no}" = "yes" ] && sendbusy 0
    UPDATEALL_SHOWN="no"
    UPDATEALL_BUSY="no"
    oldcore=""
    META_WIRE_LAST=""
  fi
  [ "${UA_RUN:-no}" = "yes" ] && ua_closelog
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
TTYCONF="${TTYDEV}"
port_resolve                                      # where the display is now
[ "${TTYDEV}" != "${TTYCONF}" ] && dbug "The display is on ${TTYDEV}, not ${TTYCONF}"
if [ -c "${TTYDEV}" ]; then # check for tty device
  ttyalias                                        # write through a node of our own
  SELFUPDATE_OURS="$(selfupdate_pids)"            # the updater that started us, if any
  serialinit													# Line settings, contrast, rotation
  while true; do											# main loop
    # The display can be unplugged, re-enumerated or reset under a running
    # daemon. Skipping the pass is how the loop waits for it to come back, and
    # how the pass after it becomes a full redraw.
    serialready || continue
    PROC_PASS=$(( ${PROC_PASS:-0} + 1 ))          # one /proc sweep a pass (proc_hits)
    if [ -r ${corenamefile} ]; then							# proceed if file exists and is readable (-r)
      # Sleep mode: the display belongs to something else - see sleepmode_pass.
      # Nothing below this may write to the port while it is held.
      if ! sleepmode_pass; then
        # The firmware's version, if the display was not ready to say.
        fw_pass
        # A newer release, and the notice for it: never blocks.
        updatenote_pass
        # Another program's bytes on the panel: redraw once it is done.
        port_pass
        # update_all takes the screen over whatever core is loaded, and our
        # own updater over that - it is about to stop this daemon.
        selfupdate_pass && { deferred_setup; continue; }
        updateall_pass && { deferred_setup; continue; }
        readcore; newcore="${CURCORE}"			  # get CORENAME, or Degauss/Zaparoo over MENU
        if [ "${SHOW_METADATA}" = "yes" ]; then
          sam_pass                                # the header, before the pictures
          # The DVD core's telemetry is on only while it is up.
          if dvd_core "${newcore}" && dvd_screen_on; then dvd_arm; else dvd_disarm; fi
          # Metadata mode. Loading a ROM does not modify /tmp/CORENAME, so
          # watching that file alone never notices a game change - which is
          # why the display used to sit on the core screen forever. Watch the
          # game-state files too, and tell the two cases apart: a new core
          # needs the full redraw, a new game needs only fresh text.
          if [ "${newcore}" != "${oldcore}" ]; then
            dbug "Read CORENAME: -${newcore}-"
            dbug "Send -${newcore}- to ${TTYDEV}."
            dvd_core "${oldcore}" && dvd_reset    # its disc is not the next core's
            senddata "${newcore}"
            oldcore=$newcore
          else
            dbug "Core unchanged, refreshing metadata only"
            refreshmeta "${newcore}"
          fi
          scummvm_jobs
          dvd_jobs
          [ "${1}" = "tty2x" ] && exit 9
          deferred_setup						  # the half of startup the picture did not need
          metawatch="$(metawatchlist)"
          # The timeout is what picks up a state file that did not exist when
          # the watch list was built - GAMEID only appears once a game with a
          # known CRC is loaded. A wake with nothing changed costs one cheap
          # rebuild and no serial traffic, because sendmeta de-duplicates.
          # Shorter while Degauss could come or go, which changes none of them.
          mpoll="${METADATA_POLL:-5}"
          menu_frontend_possible && mpoll="${UPDATE_ALL_POLL:-2}"
          # And while SAM runs, which ends with no state file written when a
          # button takes the game over: the header goes back within seconds.
          [ "${SAM_ON}" = "yes" ] && mpoll="${UPDATE_ALL_POLL:-2}"
          # Not shorter for ScummVM, though nothing is written when a game goes
          # back to its launcher: a pass costs ~190ms of CPU on the DE10, and
          # ScummVM runs on the same two cores. The ini's folder is watched, so
          # a game starting is seen at once; the way back takes 5 to 10s.
          # The DVD core: the film's place looked at every second until the
          # next pass, instead of a wait. No state file says anything there.
          if dvd_core "${oldcore}" && dvd_screen_on; then
            dvd_follow "${mpoll}"
          else
            # shellcheck disable=SC2086  # a list; metawatchlist leaves out names with spaces
            metawait "${mpoll}" ${metawatch}
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
            { [ "${UPDATE_ALL_SCREEN:-yes}" = "yes" ] || [ "${SELF_UPDATE_SCREEN:-yes}" = "yes" ] || menu_frontend_possible \
              || update_check_on TTY2OLED || update_check_on SYSTEM; } \
              && upwait="-t ${UPDATE_ALL_POLL:-2}"
            while true; do
              corewait "${upwait}"                  # wait here for the next change of corename
              [ "$?" -eq 2 ] || break
              fw_pass
              updatenote_pass
              updateall_running && break
              selfupdate_running && break
              if menu_frontend_possible; then
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
