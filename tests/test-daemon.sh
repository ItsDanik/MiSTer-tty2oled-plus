#!/bin/bash
#
# Tests for the daemon's own loop and for the init script that starts it.
#
# The other suites check what the daemon says; this one checks that it is still
# there to say it. Three things it used to get wrong, each of them a hang or a
# spin rather than a wrong byte on the wire:
#
#   serialready       the display being unplugged under a running daemon
#   waitforcorename   /tmp/CORENAME not existing yet at boot
#   daemonpid/stop    a pid file shared with an upstream install
#
# No MiSTer, no ESP32 and no serial port: /dev/null is a character device, so
# it stands in for a display that is present, and a path that does not exist
# stands in for one that is not.
#
#   ./tests/test-daemon.sh

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/daemon"
rm -rf "${TMP}"; mkdir -p "${TMP}"

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

# Whole seconds are too coarse for a test that must finish, so elapsed time is
# measured in tenths. EPOCHREALTIME is punctuated by the locale - el_GR writes
# it "1790041391,629355" - and bash arithmetic reads that comma as the comma
# operator rather than failing, so the separator has to be pinned rather than
# trusted.
export LC_ALL=C
tenths() {
  local s="${EPOCHREALTIME:-}"
  if [ -n "${s}" ] && [ "${s}" != "${s#*.}" ]; then
    printf '%s' "$(( ${s%.*} * 10 + 10#${s#*.} / 100000 ))"
  else
    printf '%s' "$(( $(date +%s%N) / 100000000 ))"
  fi
}

# The daemon blocks on inotifywait wherever it can and falls back to a plain
# sleep where it cannot. MiSTer has inotify-tools; a workstation may not, and
# the assertions that need a real watch say so rather than passing vacuously.
HAVE_INOTIFY="no"
command -v inotifywait >/dev/null 2>&1 && HAVE_INOTIFY="yes"
skip() { printf '  \033[33mskip\033[0m %s (%s)\n' "${1}" "${2}"; }

# ---------------------------------------------------------------------------
# The daemon's functions, without its main block. Same trick the wire tests
# use: everything above "# ** Main **" is definitions, so sourcing that much
# gets the functions without starting a daemon.
# ---------------------------------------------------------------------------
corenamefile="${TMP}/CORENAME"
debug="false"
debugfile="${TMP}/debuglog"
TTYDEV="/dev/null"
WAITSECS="0"
CMDWAITSECS="0"
CONTRAST="100"
ROTATE="no"
USBMODE="yes"
oldcore="something"
META_WIRE_LAST="something"
TTYWAIT="0.3"
CORENAME_WAIT="1"
dbug() { :; }

eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" \
        | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"

# serialinit talks to the port and re-runs the startup handshake. Neither is
# what these tests are about, so it is replaced with a counter.
SERIALINIT_CALLS=0
serialinit() { SERIALINIT_CALLS=$((SERIALINIT_CALLS+1)); }

# ---------------------------------------------------------------------------
section "serialready: the display going away and coming back"
# ---------------------------------------------------------------------------

TTYGONE="no"; SERIALINIT_CALLS=0
TTYDEV="/dev/null"
serialready; ok "a present display is ready" "${?}" "0"
ok "and is not re-initialised" "${SERIALINIT_CALLS}" "0"

# Unplugged. The loop must be told to skip the pass, and - this is the whole
# point - the call has to block, or "serialready || continue" is a spin that
# eats a core for as long as the display is out.
TTYDEV="${TMP}/no-such-tty"
T0="$(tenths)"
serialready; RC="${?}"
T1="$(tenths)"
ok "an absent display is not ready" "${RC}" "1"
ok "and the call brakes the loop" "$(( T1 - T0 >= 2 ))" "1"

# Still absent: it must keep braking, not just the first time.
T0="$(tenths)"; serialready; T1="$(tenths)"
ok "every further pass brakes too" "$(( T1 - T0 >= 2 ))" "1"
ok "no re-init while it is away" "${SERIALINIT_CALLS}" "0"

# Plugged back in. The board rebooted into its boot screen, so the port has to
# be set up again and nothing we last sent is on the panel any more.
TTYDEV="/dev/null"
serialready; RC="${?}"
ok "the pass it comes back on is skipped" "${RC}" "1"
ok "the port is re-initialised once" "${SERIALINIT_CALLS}" "1"
ok "the core is forgotten, forcing a redraw" "${oldcore}" ""
ok "the last metadata line is forgotten too" "${META_WIRE_LAST}" ""
ok "the deferred settings are re-sent" "${DEFERRED_DONE}" "no"

# And the pass after that is normal again.
serialready; ok "the next pass runs normally" "${?}" "0"
ok "with no second re-init" "${SERIALINIT_CALLS}" "1"

# ---------------------------------------------------------------------------
section "waitforcorename: MiSTer has not written it yet"
# ---------------------------------------------------------------------------

printf 'NES' > "${corenamefile}"
T0="$(tenths)"; waitforcorename; RC="${?}"; T1="$(tenths)"
ok "an existing CORENAME is ready at once" "${RC}" "0"
ok "and is not waited on" "$(( T1 - T0 < 3 ))" "1"

# Missing. This is the branch that used to be empty, so the loop came straight
# back round and spun - at boot, for as long as MiSTer's Main took to write it.
rm -f "${corenamefile}"
T0="$(tenths)"; waitforcorename; RC="${?}"; T1="$(tenths)"
ok "a missing CORENAME is not ready" "${RC}" "1"
ok "and the wait times out rather than spinning" "$(( T1 - T0 >= 8 ))" "1"

# The wait is a watch, not a sleep: the file appearing has to end it early, or
# the display sits blank for the rest of the timeout on every boot. Only the
# inotify path can do that - the fallback has nothing to wake on.
if [ "${HAVE_INOTIFY}" = "yes" ]; then
  CORENAME_WAIT="10"
  ( sleep 0.4; printf 'NES' > "${corenamefile}" ) &
  WRITER=$!
  T0="$(tenths)"; waitforcorename; T1="$(tenths)"
  wait "${WRITER}" 2>/dev/null
  ok "CORENAME appearing ends the wait early" "$(( T1 - T0 < 90 ))" "1"
  CORENAME_WAIT="1"
else
  skip "CORENAME appearing ends the wait early" "no inotifywait"
fi

# An unwatchable directory makes inotifywait fail and return at once, which is
# the spin again by another route.
rm -f "${corenamefile}"
corenamefile="${TMP}/no-such-dir/CORENAME"
T0="$(tenths)"; waitforcorename; RC="${?}"; T1="$(tenths)"
ok "an unwatchable directory is not ready" "${RC}" "1"
ok "and still brakes the loop" "$(( T1 - T0 >= 8 ))" "1"
corenamefile="${TMP}/CORENAME"

# ---------------------------------------------------------------------------
section "S60tty2oled: finding, starting and stopping the right daemon"
# ---------------------------------------------------------------------------

# A stand-in daemon that behaves like the real one where it matters: it spawns
# a child that blocks, and it blocks itself.
DAEMONSCRIPT="${TMP}/fake-daemon.sh"
cat > "${DAEMONSCRIPT}" <<'FAKE'
#!/bin/bash
sleep 300 &                 # stands in for the daemon's inotifywait
echo "${!}" > "${FAKE_CHILD_PIDFILE}"
wait
FAKE
chmod +x "${DAEMONSCRIPT}"

# Something that is emphatically not our daemon, standing in for an upstream
# install's process holding the shared pid file.
sleep 300 &
FOREIGN=$!

DAEMONNAME="fake-daemon.sh"
PIDFILE="${TMP}/tty2oledplus-daemon.pid"
export FAKE_CHILD_PIDFILE="${TMP}/child.pid"
TTYDEV="/dev/null"

DAEMONLOG="${TMP}/daemon.log"
# The init script's functions, without its dispatch. Kept in a file as well,
# so the hangup tests below can load them into a shell of their own.
S60LIB="${TMP}/s60-lib.sh"
sed '/^case "\$1" in/,$d' "${ROOT}/S60tty2oled" \
  | sed '/dos2unix/d; /^\. \/media\/fat/d; /^cd \/tmp/d; /^PIDFILE=/d; /^PIDFILE_LEGACY=/d' > "${S60LIB}"
. "${S60LIB}"
PIDFILE_LEGACY="${TMP}/tty2oled-daemon.pid"
UPSTREAM_DIR="${TMP}/upstream"            # none, unless a test makes one

# Upstream installed: start refuses, says so where boot would log it, and
# starts nothing. start() exits rather than returns, so it runs in a subshell.
mkdir -p "${UPSTREAM_DIR}"; touch "${UPSTREAM_DIR}/tty2oled.sh"
: > "${DAEMONLOG}"; rm -f "${PIDFILE}"
OUT="$( (start) 2>&1 )"; RC="${?}"
ok "start refuses while upstream is installed" "${RC}" "1"
ok "saying so" "$(printf '%s' "${OUT}" | grep -c 'not made to run side by side')" "1"
ok "in the daemon log too, for a start at boot" "$(grep -c 'not made to run side by side' "${DAEMONLOG}")" "1"
ok "and nothing is started" "$([ -e "${PIDFILE}" ] && echo started || echo none)" "none"
rm -rf "${UPSTREAM_DIR}"

# The uninstaller reaches the Scripts menu from here, not only from the
# installer: an update is applied by the *previous* installer, which knows
# nothing of a file added after it - so the daemon's own start is the first
# thing a new version controls.
SCRIPTSPATH="${TMP}/Scripts"; TTY2OLED_PATH="${TMP}/install"
mkdir -p "${SCRIPTSPATH}" "${TTY2OLED_PATH}"
place_uninstaller
ok "nothing to place, nothing placed" "$([ -e "${SCRIPTSPATH}/uninstall_tty2oledplus.sh" ] && echo yes || echo no)" "no"
echo "#!/bin/bash" > "${TTY2OLED_PATH}/uninstall_tty2oledplus.sh"
place_uninstaller
ok "an install that has one gets it into the Scripts menu" \
   "$(cat "${SCRIPTSPATH}/uninstall_tty2oledplus.sh")" "#!/bin/bash"
ok "and it can be run from there" "$([ -x "${SCRIPTSPATH}/uninstall_tty2oledplus.sh" ] && echo yes || echo no)" "yes"
echo "# newer" >> "${TTY2OLED_PATH}/uninstall_tty2oledplus.sh"
place_uninstaller
ok "a newer one replaces it" "$(grep -c '# newer' "${SCRIPTSPATH}/uninstall_tty2oledplus.sh")" "1"
touch -d "2020-01-01" "${SCRIPTSPATH}/uninstall_tty2oledplus.sh"
BEFORE="$(stat -c %Y "${SCRIPTSPATH}/uninstall_tty2oledplus.sh")"
place_uninstaller
ok "an identical one is left alone, so every boot is not a write" \
   "$(stat -c %Y "${SCRIPTSPATH}/uninstall_tty2oledplus.sh")" "${BEFORE}"
rm -rf "${SCRIPTSPATH}"
place_uninstaller; ok "no Scripts folder, no complaint" "${?}" "0"
unset SCRIPTSPATH TTY2OLED_PATH

rm -f "${PIDFILE}" "${PIDFILE_LEGACY}"
daemonpid; ok "nothing running, nothing found" "${?}" "1"
status >/dev/null; ok "status says not running" "${?}" "1"

# The heart of it. Upstream's pid file path was shared with this fork, so a
# live upstream daemon in it used to read as "already running" and its process
# was what "stop" went after. A pid is only ours if the process behind it is
# running our script.
printf '%s' "${FOREIGN}" > "${PIDFILE_LEGACY}"
daemonpid; ok "a live foreign pid is not our daemon" "${?}" "1"
status >/dev/null; ok "and status does not count it" "${?}" "1"
stop >/dev/null
ok "stop leaves a foreign process alone" "$([ -d "/proc/${FOREIGN}" ] && echo alive)" "alive"
ok "and leaves its pid file alone" "$([ -e "${PIDFILE_LEGACY}" ] && echo kept)" "kept"
rm -f "${PIDFILE_LEGACY}"

# A pid that no longer exists at all - the file a killed daemon left behind.
printf '999999' > "${PIDFILE}"
daemonpid; ok "a dead pid is not our daemon" "${?}" "1"
# Junk, which is what a truncated write leaves.
printf 'not-a-pid' > "${PIDFILE}"
daemonpid; ok "a malformed pid file is not our daemon" "${?}" "1"
rm -f "${PIDFILE}"

start >/dev/null
sleep 0.5
ok "start writes its own pid file" "$([ -e "${PIDFILE}" ] && echo yes)" "yes"
ok "and not upstream's" "$([ -e "${PIDFILE_LEGACY}" ] && echo yes || echo no)" "no"
daemonpid; ok "the daemon is found" "${?}" "0"
ok "found in our pid file" "${PIDFILE_FOUND}" "${PIDFILE}"
DPID="${DAEMON_PID}"
CPID="$(cat "${FAKE_CHILD_PIDFILE}" 2>/dev/null)"
ok "it really is running" "$([ -d "/proc/${DPID}" ] && echo yes)" "yes"
ok "and so is its child" "$([ -d "/proc/${CPID}" ] && echo yes)" "yes"
ok "children finds the child" "$(children "${DPID}" | grep -cx "${CPID}")" "1"

# stat is "pid (comm) state ppid pgrp session tty_nr ...".
statf() { sed -n "s/.*) \(.*\)/\1/p" "/proc/$1/stat" | cut -d' ' -f"$2"; }
ok "the daemon leads a session of its own" "$(statf "${DPID}" 4)" "${DPID}"
ok "with no controlling terminal to be hung up" "$(statf "${DPID}" 5)" "0"
ok "and none of its starter's stdin" "$(readlink "/proc/${DPID}/fd/0")" "/dev/null"
ok "its output goes to the daemon log" "$(readlink "/proc/${DPID}/fd/1")" "${DAEMONLOG}"

( start ) >/dev/null 2>&1
ok "a second start is refused" "$(cat "${PIDFILE}")" "${DPID}"
ok "status names the running daemon" "$(status)" "fake-daemon.sh running, pid ${DPID}"

stop >/dev/null
sleep 0.5
ok "stop kills the daemon" "$([ -d "/proc/${DPID}" ] && echo alive || echo gone)" "gone"
ok "stop kills the blocked child too" "$([ -d "/proc/${CPID}" ] && echo alive || echo gone)" "gone"
ok "and removes the pid file" "$([ -e "${PIDFILE}" ] && echo kept || echo gone)" "gone"

# ---------------------------------------------------------------------------
# The hangup that killed it. deploy-mister.sh --flash runs flash-mister.sh
# over "ssh -t", flash-mister.sh starts the daemon on its way out, and when
# the connection closed the kernel sent SIGHUP to the terminal's foreground
# process group - which a bare "&" had left the daemon in. Here a shell in a
# session of its own plays the ssh session: it starts the daemon, then does
# what the hangup does, "kill -HUP 0" to its whole process group.
# ---------------------------------------------------------------------------
hangup_start() {
  setsid bash -c '
    . "$1"; PIDFILE="$2"; PIDFILE_LEGACY="$3"
    start >/dev/null 2>&1
    kill -HUP 0' _ "${S60LIB}" "${PIDFILE}" "${PIDFILE_LEGACY}" 2>/dev/null
  sleep 0.5
}
export DAEMONSCRIPT DAEMONNAME TTYDEV DAEMONLOG FAKE_CHILD_PIDFILE
rm -f "${PIDFILE}" "${PIDFILE_LEGACY}"
hangup_start
HPID="$(cat "${PIDFILE}" 2>/dev/null)"
ok "the daemon survives its starter's hangup" "$([ -n "${HPID}" ] && [ -d "/proc/${HPID}" ] && echo alive || echo killed)" "alive"
ok "and so does its child" "$(C="$(cat "${FAKE_CHILD_PIDFILE}" 2>/dev/null)"; [ -n "${C}" ] && [ -d "/proc/${C}" ] && echo alive || echo killed)" "alive"
stop >/dev/null; sleep 0.3

# Holding the starter's stdout kept "ssh host S60tty2oled start" from ever
# returning: ssh waits for EOF on the pipe, and the daemon had its end of it.
timeout 5 bash -c '. "$1"; PIDFILE="$2"; start | cat >/dev/null' _ "${S60LIB}" "${PIDFILE}" >/dev/null 2>&1
ok "start returns even when its output is a pipe" "${?}" "0"
stop >/dev/null; sleep 0.3

# A daemon started by the previous version of this script wrote the old path.
# Deploying this one must still be able to stop it, or a restart would leave
# two daemons on the same serial port.
rm -f "${PIDFILE}" "${PIDFILE_LEGACY}"
"${DAEMONSCRIPT}" & LEGACY_PID=$!
printf '%s' "${LEGACY_PID}" > "${PIDFILE_LEGACY}"
sleep 0.3
daemonpid; ok "a daemon found under the old path" "${DAEMON_PID}" "${LEGACY_PID}"
ok "and the old file is the one to clear" "${PIDFILE_FOUND}" "${PIDFILE_LEGACY}"
stop >/dev/null
sleep 0.5
ok "stop kills it" "$([ -d "/proc/${LEGACY_PID}" ] && echo alive || echo gone)" "gone"
ok "and clears the old file" "$([ -e "${PIDFILE_LEGACY}" ] && echo kept || echo gone)" "gone"

kill "${FOREIGN}" 2>/dev/null
wait "${FOREIGN}" 2>/dev/null

# ---------------------------------------------------------------------------
section "one script knows where the pid file is"
# ---------------------------------------------------------------------------

# Moving the pid file to its own path broke two scripts that read it by hand:
# the deploy reported a healthy daemon as dead, and flash-mister.sh and
# tty2oled-bootimg.sh both decided there was no daemon to restart once they had
# stopped it for the serial port. All three ask "S60tty2oled status" now; this
# test found the third, and keeps a fourth from appearing.
READERS="$(cd "${ROOT}" && grep -l 'daemon\.pid' \
             tty2oled*.sh tty2oled-system.ini tools/*.sh tools/*.py 2>/dev/null)"
ok "no script but S60tty2oled and the ini names the pid file" \
   "$(printf '%s\n' ${READERS} | grep -vx 'tty2oled-system.ini' | tr '\n' ' ')" ""
for t in flash-mister.sh tty2oled-bootimg.sh; do
  ok "${t} asks the init script instead" "$(grep -c 'INIT}" status' "${ROOT}/tools/${t}")" "1"
done

# ---------------------------------------------------------------------------
section "update_all: its own screen while it runs, the core again after"
# ---------------------------------------------------------------------------

# A fake /proc: one directory per pid holding a NUL-separated cmdline, as the
# kernel writes it.
PROC_ROOT="${TMP}/proc"; mkdir -p "${PROC_ROOT}"
mkproc() { local pid="${1}"; shift; mkdir -p "${PROC_ROOT}/${pid}"; printf '%s\0' "$@" >"${PROC_ROOT}/${pid}/cmdline"; }
mkproc 1 /sbin/init
mkproc 400 /bin/bash /media/fat/tty2oledplus/tty2oled.sh
mkproc 401 grep -qsa -e '[u]pdate_all' /proc/1/cmdline

UPDATE_ALL_SCREEN="yes"
updateall_running; ok "no update_all: not running, and grep's own pattern does not count" "${?}" "1"

mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
updateall_running; ok "update_all.sh seen" "${?}" "0"
rm -rf "${PROC_ROOT}/500"
mkproc 501 python3 /tmp/update_all.pyz
updateall_running; ok "the update_all.pyz it hands over to, seen" "${?}" "0"
UPDATE_ALL_SCREEN="no"
updateall_running; ok "UPDATE_ALL_SCREEN=no ignores it" "${?}" "1"
UPDATE_ALL_SCREEN="yes"

# What reaches the wire, with a picture and without one. The daemon writes
# with ">", which truncates a regular file each time, so the wire is a pipe.
TTYDEV="/dev/stdout"
picturefolder="${TMP}/pics"; picturefolder_pri="${TMP}/pics_pri"
mkdir -p "${picturefolder}/GSC" "${picturefolder_pri}"
SHOW_METADATA="yes"; TRANSITION="-2"; META_WIRE_LAST="CMDMETA,..."
ok "no picture: metadata off, then the name as text" "$(sendupdateall | tr '\n' ' ')" "CMDMETAOFF update_all "
sendupdateall >/dev/null
ok "and the metadata line is forgotten" "${META_WIRE_LAST}" "OFF"

# A whole 256x64 picture: rows 0-53 pure 0x11, the band 0xff. What goes out
# is the same 8192 bytes with the band black.
{ printf 'h1\nh2\nh3\n'; for i in $(seq 6912); do printf '11'; done; for i in $(seq 1280); do printf 'ff'; done; echo; } \
  >"${picturefolder}/GSC/update_all.gsc"
PIC="$(sendupdateall | tail -n +3 | xxd -p | tr -d '\n')"
ok "picture in pics/GSC: sent as CMDCOR" "$(sendupdateall | head -2 | tr '\n' ' ')" "CMDMETAOFF CMDCOR,update_all,-2 "
ok "exactly one framebuffer of it" "$(( ${#PIC} / 2 ))" "8192"
ok "the top 54 rows as drawn" "$(printf '%s' "${PIC:0:13824}" | tr -d 1)" ""
ok "the band's 10 rows black, for the busy bar" "$(printf '%s' "${PIC:13824}" | tr -d 0)" ""

# The pass: shown once while running, then a full redraw once it stops.
WIRE="${TMP}/wire"; TTYDEV="${WIRE}"; : >"${WIRE}"
UPDATE_ALL_POLL="0"; UPDATEALL_SHOWN="no"; oldcore="MiSTerZine"
updateall_pass; ok "running: the pass is taken" "${?}" "0"
: >"${WIRE}"; updateall_pass
ok "and the screen is sent once, not every pass" "$(wc -c <"${WIRE}")" "0"
ok "the core is left alone meanwhile" "${oldcore}" "MiSTerZine"
# The downloader: the bar goes on with it and off after it, once each way.
mkproc 600 /tmp/ua_downloader_latest.zip --list-dbs all
downloader_running; ok "the settings screen's --list-dbs query is not an update" "${?}" "1"
: >"${WIRE}"; updateall_pass
ok "so no bar for it" "$(wc -c <"${WIRE}")" "0"
mkproc 601 /tmp/ua_downloader_bin
downloader_running; ok "the downloader proper is" "${?}" "0"
updateall_pass
ok "the bar starts, and takes the panel with UPDATING" "$(cat "${WIRE}")" "CMDBUSY,1,UPDATING"
: >"${WIRE}"; updateall_pass
ok "and is not restarted every pass" "$(wc -c <"${WIRE}")" "0"
rm -rf "${PROC_ROOT}/601"
# Every write truncates this file, so what the whole pass sent is read off
# stdout instead - with the picture out of the way, so it is all text.
mv "${picturefolder}/GSC/update_all.gsc" "${TMP}/update_all.gsc.away"
ok "the downloader done, the bar stops and the banner is drawn again" \
   "$(TTYDEV=/dev/stdout updateall_pass | tr '\n' ' ')" "CMDBUSY,0 CMDMETAOFF update_all "
mv "${TMP}/update_all.gsc.away" "${picturefolder}/GSC/update_all.gsc"
UPDATEALL_BUSY="no"    # that pass ran down a pipe, so its state stayed there
: >"${WIRE}"; updateall_pass
ok "once" "$(wc -c <"${WIRE}")" "0"
mkproc 602 python3 /tmp/ua_downloader_dd.pyz
updateall_pass
ok "a second run starts it again" "$(cat "${WIRE}")" "CMDBUSY,1,UPDATING"
UPDATE_ALL_TEXT="DOWNLOADING"; UPDATEALL_BUSY="no"
: >"${WIRE}"; updateall_pass
ok "UPDATE_ALL_TEXT says what it reads" "$(cat "${WIRE}")" "CMDBUSY,1,DOWNLOADING"
UPDATE_ALL_TEXT="Updating, now"; UPDATEALL_BUSY="no"
: >"${WIRE}"; updateall_pass
ok "and a comma in it cannot reach the wire, where it is the separator" \
   "$(cat "${WIRE}")" "CMDBUSY,1,Updating now"
UPDATE_ALL_TEXT="UPDATING"

rm -rf "${PROC_ROOT}/501" "${PROC_ROOT}/602"

: >"${WIRE}"
UPDATEALL_BUSY="yes"
updateall_pass; ok "finished: the pass is not taken" "${?}" "1"
ok "and a bar still running is stopped" "$(cat "${WIRE}")" "CMDBUSY,0"
ok "and the core is redrawn in full" "${oldcore}|${META_WIRE_LAST}" "|"
oldcore="MiSTerZine"
updateall_pass
ok "only once" "${oldcore}" "MiSTerZine"
# A display that reset under us lost the picture and the bar with its RAM.
UPDATEALL_SHOWN="yes"; UPDATEALL_BUSY="yes"; TTYGONE="yes"; TTYDEV="/dev/null"
serialready
ok "a display that came back gets the update_all screen and bar again" \
   "${UPDATEALL_SHOWN}|${UPDATEALL_BUSY}" "no|no"
# ---------------------------------------------------------------------------
# Our own updater: the message has to go up before it stops this daemon
# ---------------------------------------------------------------------------
TTYDEV="${WIRE}"

SELF_UPDATE_SCREEN="yes"; SELFUPDATE_SHOWN="no"; SHOW_METADATA="yes"
selfupdate_running; ok "no updater running" "${?}" "1"
mkproc 700 /bin/bash /media/fat/Scripts/update_tty2oledplus.sh
selfupdate_running; ok "update_tty2oledplus seen" "${?}" "0"
SELF_UPDATE_SCREEN="no"
selfupdate_running; ok "SELF_UPDATE_SCREEN=no ignores it" "${?}" "1"
SELF_UPDATE_SCREEN="yes"

oldcore="NES"; META_WIRE_LAST="CMDMETA,..."
ok "the message and the bar go out, with no banner" \
   "$(TTYDEV=/dev/stdout selfupdate_pass | tr '\n' ' ')" \
   "CMDMETAOFF CMDBUSY,1,Updating TTY2OLED+... "
selfupdate_pass >/dev/null
ok "the core is forgotten, so it is redrawn when the daemon returns" "${oldcore}" ""
: >"${WIRE}"; TTYDEV="${WIRE}"; selfupdate_pass
ok "and it is sent once, not every pass" "$(wc -c <"${WIRE}")" "0"

# The uninstaller stops the daemon too, and a display left saying "Updating"
# about software that is being removed would be a lie.
rm -rf "${PROC_ROOT}/700"
mkproc 701 /bin/bash /media/fat/Scripts/uninstall_tty2oledplus.sh
selfupdate_running; ok "the uninstaller is not an update" "${?}" "1"
rm -rf "${PROC_ROOT}/701"
selfupdate_pass; ok "gone: the pass is not taken" "${?}" "1"

# It wins over update_all: it is about to stop the daemon.
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
mkproc 700 /bin/bash /media/fat/Scripts/update_tty2oledplus.sh
SELFUPDATE_SHOWN="no"
ok "with both running, ours is what shows" \
   "$(TTYDEV=/dev/stdout selfupdate_pass | tail -n1)" "CMDBUSY,1,Updating TTY2OLED+..."
rm -rf "${PROC_ROOT}/500" "${PROC_ROOT}/700"
SELFUPDATE_SHOWN="no"

ok "the daemon's wait times out for it even with the update_all screen off" \
   "$(grep -c 'SELF_UPDATE_SCREEN:-yes}" = "yes" \]; }' "${ROOT}/tty2oled.sh")" "1"

TTYDEV="/dev/null"; unset PROC_ROOT

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
