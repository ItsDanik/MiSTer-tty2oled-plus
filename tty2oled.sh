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

# 2026-09-20 Game metadata display (fork)
#            Sends per-game metadata ahead of the picture so the display can
#            show arcade info cards and the console split layout.
#            Requires "log_file_entry=1" in MiSTer.ini for anything beyond
#            core-level display; see tty2oled-meta.sh for why.
#
#

. /media/fat/tty2oled/tty2oled-system.ini
. /media/fat/tty2oled/tty2oled-user.ini
. /media/fat/tty2oled/tty2oled-meta.sh
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

# Send Contrast-Data function
sendcontrast() {
  if [ "${USBMODE}" = "yes" ]; then # Check the tty2xxx mode
    dbug "Sending: CMDCON,${CONTRAST}"
    echo "CMDCON,${CONTRAST}" >${TTYDEV} # Send Contrast Command and Value
    sleep ${WAITSECS}
  else
    echo "att" >${TTYDEV}       # Send an "att" to the MiSTer annoucing another Command
    sleep ${WAITSECS}           # sleep needed here ?!
    echo "CONTRAST" >${TTYDEV}  # Send "CONTRAST" annoucing the OLED Contrast Data as next
    sleep ${WAITSECS}           # sleep needed here ?!
    echo ${CONTRAST} >${TTYDEV} # Send Contrast Value
  fi
}

# Send Screensaver function
sendscreensaver() {
  if [ "${SCREENSAVER}" = "yes" ]; then # Check screensaver mode

    SCREENSAVER_MODE="0"
    [ "${SCREENSAVER_SCREEN_TTY2OLED}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+1
    [ "${SCREENSAVER_SCREEN_MISTER}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+2
    [ "${SCREENSAVER_SCREEN_CORE}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+4
    [ "${SCREENSAVER_SCREEN_TIME}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+8
    [ "${SCREENSAVER_SCREEN_DATE}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+16
    [ "${SCREENSAVER_SCREEN_STARS}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+32
    [ "${SCREENSAVER_SCREEN_TOAST}" = "yes" ] && let SCREENSAVER_MODE=${SCREENSAVER_MODE}+64
    # echo "ScreenSaverMode: ${SCREENSAVER_MODE}"
    dbug "Sending: CMDSAVER,${SCREENSAVER_MODE},${SCREENSAVER_IVAL},${SCREENSAVER_START}"
    echo "CMDSAVER,${SCREENSAVER_MODE},${SCREENSAVER_IVAL},${SCREENSAVER_START}" >${TTYDEV} # Send Screensaver Command and Values

  else
    dbug "Sending: CMDSAVER,0,0,0"
    echo "CMDSAVER,0,0,0" >${TTYDEV} # Send Screensaver Command and Values
  fi
  sleep ${WAITSECS}
}

# Rotate Display function
sendrotation() {
  if [ "${USBMODE}" = "yes" ]; then # Check the tty2xxx mode
    if [ "${ROTATE}" = "yes" ]; then
      dbug "Sending: CMDROT,1"
      echo "CMDROT,1" >${TTYDEV} # Send Rotation if set to "yes"
      sleep ${WAITSECS}
      echo "CMDSORG" >${TTYDEV} # Show Start Screen rotated
      sleep 4
    #else
    #  dbug "Sending: CMDROT,0" > ${TTYDEV}
    #  echo "CMDROT,0" > ${TTYDEV}						# No Rotation
    #  sleep ${WAITSECS}
    #  echo "CMDSORG" > ${TTYDEV}						# Show Start Screen rotated
    #  sleep 4
    fi
  fi
}

# USB Send-Picture-Data function
senddata() {
  newcore="${1}"
  unset picfnam
  if [ "${USBMODE}" = "yes" ]; then                       # Check the tty2xxx mode

    # Metadata first: the firmware needs to know which layout to compose
    # before the picture arrives, and the console icon has to be in place
    # before CMDCOR triggers the first paint of the split layout.
    if sendmeta "${newcore}" force; then
      sendicon "${META_ICON}"
    fi

    if [ -e "${picturefolder_pri}/${newcore}.gsc" ]; then # Check for _pri pictures
      picfnam="${picturefolder_pri}/${newcore}.gsc"
    elif [ -e "${picturefolder_pri}/${newcore}.xbm" ]; then
      picfnam="${picturefolder_pri}/${newcore}.xbm"
    else
      picfolders="gsc_us xbm_us gsc xbm xbm_text" # If no _pri picture found, try all the others
      [ "${USE_US_PICTURE}" = "no" ] && picfolders="${picfolders//gsc_us xbm_us/}"
      [ "${USE_GSC_PICTURE}" = "no" ] && picfolders="${picfolders//gsc_us/}" && picfolders="${picfolders//gsc/}"
      [ "${USE_TEXT_PICTURE}" = "no" ] && picfolders="${picfolders//xbm_text/}"
      for picfolder in ${picfolders}; do
        for ((c = "${#newcore}"; c >= 1; c--)); do                                   # Manipulate string...
          picfnam="${picturefolder}/${picfolder^^}/${newcore:0:$c}.${picfolder:0:3}" # ...until it matches something
          [ -e "${picfnam}" ] && break
        done
        [ -e "${picfnam}" ] && break
      done
    fi
    if [ -e "${picfnam}" ]; then               # Exist?
      if [ "${USE_RANDOM_ALT}" = "yes" ]; then # Use _altX pictures?
        SAVEIFS="${IFS}"
        IFS=$'\n'
        ALTPICNUM=$(find $(dirname "${picfnam}") -name $(basename "${picfnam%.*}_alt")* | wc -l)
        IFS="${SAVEIFS}"
        if [ "${ALTPICNUM}" -gt "0" ]; then             # If more than 0 _altX pictures
          ALTPICRND=$((${RANDOM} % $((ALTPICNUM + 1)))) # then dice between 0 and count of found _altX pictures
           [ "${ALTPICRND}" -gt 0 ] && picfnam="${picfnam%.*}_alt"${ALTPICRND}".${picfolder:0:3}"
        fi # If 0 then original picture, otherwise _altX
      fi
      dbug "Sending: CMDCOR,${1},${TRANSITION}"
      echo "CMDCOR,${1},${TRANSITION}" >${TTYDEV}    # Send CORECHANGE" Command and Corename
      sleep ${WAITSECS}                              # sleep needed here ?!
      tail -n +4 "${picfnam}" | xxd -r -p >${TTYDEV} # The Magic, send the Picture-Data up from Line 4 and proces
    else                                             # No Picture available!
      echo "${1}" >${TTYDEV}                         # Send just the CORENAME
    fi                                               # End if Picture check
  else                                               # SD/Standard Mode ? Just send the Corename
    echo "${1}" >${TTYDEV}                           # Instruct the device to load the appropriate picture from SD card
  fi
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

# Locate the 86x64 console icon for a core, honouring the _pri override folder
# so hand-made icons can replace generated ones one at a time.
findicon() {
  local key="${1}"
  ICONFILE=""
  [ -n "${key}" ] || return 1
  if [ -e "${iconfolder_pri}/${key}.gsc" ]; then
    ICONFILE="${iconfolder_pri}/${key}.gsc"
  elif [ -e "${iconfolder}/${key}.gsc" ]; then
    ICONFILE="${iconfolder}/${key}.gsc"
  else
    return 1
  fi
  return 0
}

# Send CMDMETA for the current game. Returns 1 if metadata mode is not active
# so the caller can fall back to plain picture display.
sendmeta() {
  local corename="${1}" force="${2:-}" kindnum="" payload="" label="" value="" f="" wire=""

  [ "${SHOW_METADATA}" = "yes" ] || return 1
  [ "${USBMODE}" = "yes" ]       || return 1

  build_meta "${corename}"

  # Computer cores stay on plain full-screen artwork by design.
  if [ "${META_KIND}" = "computer" ] || [ "${META_KIND}" = "unknown" ]; then
    if [ "${force}" = "force" ] || [ "${META_WIRE_LAST:-}" != "OFF" ]; then
      dbug "Sending: CMDMETAOFF (kind=${META_KIND})"
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

  wire="CMDMETA,${kindnum},${METADATA_INTERVAL},${payload}"

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

sendtime() {
  timeoffset=$(date +%:::z)
  localtime=$(date '-d now '${timeoffset}' hour' +%s)
  echo "CMDSETTIME,${localtime}" >${TTYDEV}
  sleep ${WAITSECS}
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
  if [ -n "${3}" ]; then                                  # Parameter 3 SD or USB Mode
    if [ "${3}" = "SD" ]; then                            # Parameter 3 = "SD" ?
      USBMODE="no"                                        # Un-Set USBMODE
    elif [ "${3}" = "USB" ]; then                         # Parameter 3 = "USB" ?
      USBMODE="yes"                                       # Set USBMODE
    else                                                  # Parameter not "USB" or "SD"!
      echo "Parameter 3 invalid"                          # Parameter 3 wrong
    fi                                                    # end if USB Mode
  fi                                                      # end if Parameter 3
  echo "Using Interface: ${TTYDEV} with ${BAUDRATE} Baud" # Device Output
  echo "USBMODE: ${USBMODE}"                              # Mode Output
fi                                                        # end if command line Parameter

# Let's go
if [ -c "${TTYDEV}" ]; then # check for tty device
  dbug "${TTYDEV} detected, setting Parameter: ${BAUDRATE} ${TTYPARAM}."
  stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM} # set tty parameter
  sleep ${WAITSECS}
  echo "QWERTZ" >${TTYDEV} # First Transmission to clear serial send buffer
  dbug "Send QWERTZ as first transmission"
  sleep ${WAITSECS}
  sendcontrast												# Set Contrast
  sendrotation												# Set Display Rotation
  sendtime													# Set time and date
  sendscreensaver											# Set Screensaver

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
  while true; do											# main loop
    if [ -r ${corenamefile} ]; then							# proceed if file exists and is readable (-r)
      if [ -f ${SLEEPFILE} ]; then							# Sleepmode = Yes
        dbug "The tty2oled daemon is sleeping!"
        if [ "${debug}" = "false" ]; then
          inotifywait -qq -e delete "${SLEEPFILE}"		  # Sleepmode is waiting it here
        elif [ "${debug}" = "true" ]; then
          inotifywait -e delete "${SLEEPFILE}"			  # Sleepmode is waiting it here
        fi
        sleep ${SLEEPMODEDELAY}
      fi
      if [ ! -f ${SLEEPFILE} ]; then				  # Sleepmode = No
        newcore=$(<${corenamefile})				  # get CORENAME
        if [ "${SHOW_METADATA}" = "yes" ] && [ "${USBMODE}" = "yes" ]; then
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
            if [ "${debug}" = "false" ]; then
              inotifywait -qq -e modify "${corenamefile}"            # wait here for next change of corename, -qq for quietness
            elif [ "${debug}" = "true" ]; then
              inotifywait -e modify "${corenamefile}"                # but not -qq when debugging
            fi
	  #else
          #  dbug "Core not changed!"
          #fi #newcore != oldcore
        fi
      fi
    else # CORENAME file not found
      dbug "File ${corenamefile} not found!"
    fi # end if /tmp/CORENAME check
  done # end while
else   # no tty detected
  echo "No ${TTYDEV} Device detected, abort."
  dbug "No ${TTYDEV} Device detected, abort."
fi # end if tty check
# ** End Main **
