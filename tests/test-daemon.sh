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

# The menu entries reach the Scripts folder from here, not only from the
# installer: an update is applied by the *previous* installer, which knows
# nothing of a file added after it - so the daemon's own start is the first
# thing a new version controls. That is what carries the 0.4.8b renaming onto
# a MiSTer whose last update predates it.
SCRIPTSPATH="${TMP}/Scripts"; TTY2OLED_PATH="${TMP}/install"
mkdir -p "${SCRIPTSPATH}" "${TTY2OLED_PATH}"
place_menu_scripts
ok "nothing to place, nothing placed" \
   "$([ -e "${SCRIPTSPATH}/tty2oledplus_uninstall.sh" ] && echo yes || echo no)" "no"

for f in ${MENU_SCRIPTS}; do echo "#!/bin/bash" > "${TTY2OLED_PATH}/${f}"; done
place_menu_scripts
PLACED=0
for f in ${MENU_SCRIPTS}; do [ -x "${SCRIPTSPATH}/${f}" ] && PLACED=$((PLACED+1)); done
ok "an install that has them gets all three into the Scripts menu" "${PLACED}" "3"
ok "and they can be run from there" \
   "$(cat "${SCRIPTSPATH}/tty2oledplus_settings.sh")" "#!/bin/bash"

echo "# newer" >> "${TTY2OLED_PATH}/tty2oledplus_uninstall.sh"
place_menu_scripts
ok "a newer one replaces it" "$(grep -c '# newer' "${SCRIPTSPATH}/tty2oledplus_uninstall.sh")" "1"
touch -d "2020-01-01" "${SCRIPTSPATH}/tty2oledplus_settings.sh"
BEFORE="$(stat -c %Y "${SCRIPTSPATH}/tty2oledplus_settings.sh")"
place_menu_scripts
ok "an identical one is left alone, so every boot is not a write" \
   "$(stat -c %Y "${SCRIPTSPATH}/tty2oledplus_settings.sh")" "${BEFORE}"

# The pre-0.4.8b names, which only the daemon can clear: the installer that
# put them there is the one that ran the update.
for f in ${MENU_SCRIPTS_LEGACY}; do echo "# old" > "${SCRIPTSPATH}/${f}"; done
place_menu_scripts
LEFT=0
for f in ${MENU_SCRIPTS_LEGACY}; do [ -e "${SCRIPTSPATH}/${f}" ] && LEFT=$((LEFT+1)); done
ok "the old names are swept once the new ones are in" "${LEFT}" "0"
ok "and the new ones are still there" \
   "$([ -x "${SCRIPTSPATH}/tty2oledplus_update.sh" ] && echo yes || echo no)" "yes"

# Half an install - only one of the three - must not take the old menu entry
# away, or a failed update leaves a MiSTer with no way to update or uninstall.
rm -f "${SCRIPTSPATH}"/* "${TTY2OLED_PATH}"/tty2oledplus_*.sh
echo "# old" > "${SCRIPTSPATH}/update_tty2oledplus.sh"
echo "#!/bin/bash" > "${TTY2OLED_PATH}/tty2oledplus_uninstall.sh"
place_menu_scripts
ok "an incomplete set leaves the old entry alone" \
   "$([ -e "${SCRIPTSPATH}/update_tty2oledplus.sh" ] && echo yes || echo no)" "yes"

rm -rf "${SCRIPTSPATH}"
place_menu_scripts; ok "no Scripts folder, no complaint" "${?}" "0"
unset SCRIPTSPATH TTY2OLED_PATH

# ---------------------------------------------------------------------------
section "S60tty2oled: the 0.5.8b artwork folders, moved on the next start"
# ---------------------------------------------------------------------------
# Here for the same reason place_menu_scripts is: the update that introduces
# pics/banner is applied by the previous updater, which knows nothing about
# moving anything - and which decides whether to fetch the 80MB pack by asking
# whether the artwork is already there, so it does not bring the new one
# either. Renames, not a download: the files are byte for byte the same.
TTY2OLED_PATH="${TMP}/migr"
mkdir -p "${TTY2OLED_PATH}/pics/GSC" "${TTY2OLED_PATH}/pics_pri/ICON"
echo menu  > "${TTY2OLED_PATH}/pics/GSC/MENU.gsc"
echo nes   > "${TTY2OLED_PATH}/pics/GSC/NES.gsc"
echo alt   > "${TTY2OLED_PATH}/pics/GSC/NES_alt1.gsc"
echo icon  > "${TTY2OLED_PATH}/pics_pri/ICON/NES.gsc"
echo mine  > "${TTY2OLED_PATH}/pics_pri/NES.gsc"
migrate_pics
ok "the pack becomes pics/banner"        "$(cat "${TTY2OLED_PATH}/pics/banner/NES.gsc" 2>&1)" "nes"
ok "its alternatives move to pics/alt"   "$(cat "${TTY2OLED_PATH}/pics/alt/NES_alt1.gsc" 2>&1)" "alt"
ok "and are out of the banner folder"    "$(ls "${TTY2OLED_PATH}/pics/banner" | grep -c _alt)" "0"
ok "the icons become pics/icon"          "$(cat "${TTY2OLED_PATH}/pics/icon/NES.gsc" 2>&1)" "icon"
ok "your own banners become pics/user"   "$(cat "${TTY2OLED_PATH}/pics/user/NES.gsc" 2>&1)" "mine"
ok "and nothing is left of the old names" \
   "$(ls -d "${TTY2OLED_PATH}/pics/GSC" "${TTY2OLED_PATH}/pics_pri" 2>/dev/null | wc -l | tr -d ' ')" "0"

# It runs on every start, so it has to be safe to run twice - and must never
# overwrite a user banner with a stale copy of itself.
migrate_pics
ok "a second run changes nothing"        "$(cat "${TTY2OLED_PATH}/pics/user/NES.gsc" 2>&1)" "mine"
ok "and the banner folder is intact"     "$(cat "${TTY2OLED_PATH}/pics/banner/NES.gsc" 2>&1)" "nes"

# The other order: the new pack was unpacked beside the old folders. Then
# there is nothing to move and the old ones are simply dropped - but only
# because their replacements are there, so a half-finished update never leaves
# a MiSTer with no artwork at all.
mkdir -p "${TTY2OLED_PATH}/pics/GSC"
echo stale > "${TTY2OLED_PATH}/pics/GSC/NES.gsc"
migrate_pics
ok "a new pack beside the old one drops the old" \
   "$([ -d "${TTY2OLED_PATH}/pics/GSC" ] && echo yes || echo no)" "no"
ok "keeping the new"                     "$(cat "${TTY2OLED_PATH}/pics/banner/NES.gsc" 2>&1)" "nes"

# Yours is never overwritten by the migration - it is the one folder here
# whose contents nobody but the user put there.
mkdir -p "${TTY2OLED_PATH}/pics_pri"
echo theirs > "${TTY2OLED_PATH}/pics_pri/NES.gsc"
migrate_pics
ok "a user banner already moved is not replaced" \
   "$(cat "${TTY2OLED_PATH}/pics/user/NES.gsc")" "mine"

# A fresh install has neither, and the folder the user drops artwork into has
# to exist for them to find it.
rm -rf "${TTY2OLED_PATH}"
mkdir -p "${TTY2OLED_PATH}/pics/banner"
migrate_pics
ok "a fresh install still gets a pics/user to use" \
   "$([ -d "${TTY2OLED_PATH}/pics/user" ] && echo yes || echo no)" "yes"
rm -rf "${TTY2OLED_PATH}"
migrate_pics; ok "and no pics at all is not an error" "${?}" "0"
unset TTY2OLED_PATH

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
picturefolder="${TMP}/pics"
bannerfolder="${picturefolder}/banner"; userbannerfolder="${picturefolder}/user"
altbannerfolder="${picturefolder}/alt"
mkdir -p "${bannerfolder}" "${userbannerfolder}" "${altbannerfolder}"
SHOW_METADATA="yes"; TRANSITION="-2"; META_WIRE_LAST="CMDMETA,..."
ok "no picture: metadata off, then the name as text" "$(sendupdateall | tr '\n' ' ')" "CMDMETAOFF update_all "
sendupdateall >/dev/null
ok "and the metadata line is forgotten" "${META_WIRE_LAST}" "OFF"

# A whole 256x64 picture: rows 0-53 pure 0x11, the band 0xff. What goes out
# is the same 8192 bytes with the band black.
{ printf 'h1\nh2\nh3\n'; for i in $(seq 6912); do printf '11'; done; for i in $(seq 1280); do printf 'ff'; done; echo; } \
  >"${bannerfolder}/update_all.gsc"
PIC="$(sendupdateall | tail -n +3 | xxd -p | tr -d '\n')"
ok "picture in pics/banner: sent as CMDCOR" "$(sendupdateall | head -2 | tr '\n' ' ')" "CMDMETAOFF CMDCOR,update_all,-2 "
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
ok "the bar starts, and takes the panel with the message" "$(cat "${WIRE}")" "CMDBUSY,1,Updating System ..."
: >"${WIRE}"; updateall_pass
ok "and is not restarted every pass" "$(wc -c <"${WIRE}")" "0"
rm -rf "${PROC_ROOT}/601"
# Every write truncates this file, so what the whole pass sent is read off
# stdout instead - with the picture out of the way, so it is all text.
mv "${bannerfolder}/update_all.gsc" "${TMP}/update_all.gsc.away"
ok "the downloader done, the bar stops and the banner is drawn again" \
   "$(TTYDEV=/dev/stdout updateall_pass | tr '\n' ' ')" "CMDBUSY,0 CMDMETAOFF update_all "
mv "${TMP}/update_all.gsc.away" "${bannerfolder}/update_all.gsc"
UPDATEALL_BUSY="no"    # that pass ran down a pipe, so its state stayed there
: >"${WIRE}"; updateall_pass
ok "once" "$(wc -c <"${WIRE}")" "0"
mkproc 602 python3 /tmp/ua_downloader_dd.pyz
updateall_pass
ok "a second run starts it again" "$(cat "${WIRE}")" "CMDBUSY,1,Updating System ..."
UPDATE_ALL_TEXT="DOWNLOADING"; UPDATEALL_BUSY="no"
: >"${WIRE}"; updateall_pass
ok "UPDATE_ALL_TEXT says what it reads" "$(cat "${WIRE}")" "CMDBUSY,1,DOWNLOADING"
UPDATE_ALL_TEXT="Updating, now"; UPDATEALL_BUSY="no"
: >"${WIRE}"; updateall_pass
ok "and a comma in it cannot reach the wire, where it is the separator" \
   "$(cat "${WIRE}")" "CMDBUSY,1,Updating now"
UPDATE_ALL_TEXT="Updating System ..."

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
mkproc 700 /bin/bash /media/fat/Scripts/tty2oledplus_update.sh
selfupdate_running; ok "tty2oledplus_update seen" "${?}" "0"
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
mkproc 701 /bin/bash /media/fat/Scripts/tty2oledplus_uninstall.sh
selfupdate_running; ok "the uninstaller is not an update" "${?}" "1"
rm -rf "${PROC_ROOT}/701"

# Finished. The bar has to be stopped by name: the MENU core sends CMDBOOTPIC
# and no picture, so nothing else would ever take the panel back, and it swept
# over the menu picture for ever.
SELFUPDATE_SHOWN="yes"; oldcore="MENU"; META_WIRE_LAST="OFF"
ok "finished: the bar is stopped" "$(TTYDEV=/dev/stdout selfupdate_pass | tr '\n' ' ')" "CMDBUSY,0 "
selfupdate_pass >/dev/null
ok "and the core is redrawn in full" "${oldcore}|${META_WIRE_LAST}" "|"
: >"${WIRE}"; TTYDEV="${WIRE}"; selfupdate_pass
ok "only once" "$(wc -c <"${WIRE}")" "0"
selfupdate_pass; ok "gone: the pass is not taken" "${?}" "1"

# It wins over update_all: it is about to stop the daemon.
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
mkproc 700 /bin/bash /media/fat/Scripts/tty2oledplus_update.sh
SELFUPDATE_SHOWN="no"
ok "with both running, ours is what shows" \
   "$(TTYDEV=/dev/stdout selfupdate_pass | tail -n1)" "CMDBUSY,1,Updating TTY2OLED+..."
rm -rf "${PROC_ROOT}/500" "${PROC_ROOT}/700"
SELFUPDATE_SHOWN="no"

ok "the daemon's wait times out for it even with the update_all screen off" \
   "$(grep -c 'SELF_UPDATE_SCREEN:-yes}" = "yes" \]; }' "${ROOT}/tty2oled.sh")" "1"

TTYDEV="/dev/null"; unset PROC_ROOT

# ---------------------------------------------------------------------------
section "sleep mode: the display belongs to something else"
# ---------------------------------------------------------------------------
#
# /tmp/tty2oled_sleep is a mutex. MiSTer SAM drives the panel itself for the
# whole of an attract session - its module writes CMDCOR, CMDTXT and raw
# picture bytes to the same port and reads the acks back - so while the file is
# there this daemon must not touch the port at all.
#
# SAM writes an epoch deadline into it and rewrites it on every game change.
# Before this was read, a SAM that was killed left the file behind and the
# daemon waited on a delete that never came: the panel stayed frozen until
# somebody removed the file by hand.

SLEEPFILE="${TMP}/tty2oled_sleep"
SLEEP_POLL="1"
SLEEP_STALE_GRACE="2"
SLEEPMODEDELAY="0.3"

# Recomputed at every use, never captured once: each assertion below blocks for
# a poll interval, so a timestamp taken at the top of the section is already
# seconds stale by the time the later ones read it - and every one of these
# turns on how far "now" is from the deadline.
now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

rm -f "${SLEEPFILE}"
sleepmode_pass; ok "no sleep file: the pass is ours" "${?}" "1"

# A plain "touch" - upstream's own documented way in, and anything else that
# borrows the mechanism. No deadline, so it is waited on for ever.
: >"${SLEEPFILE}"
T0="$(tenths)"; sleepmode_pass; RC="${?}"; T1="$(tenths)"
ok "an empty sleep file holds the display" "${RC}" "0"
ok "and the pass brakes the loop" "$(( T1 - T0 >= 8 ))" "1"

# The same, for a holder that is alive and up to date.
printf '%s\n' "$(( $(now) + 300 ))" >"${SLEEPFILE}"
sleepmode_pass; ok "a deadline in the future holds it too" "${?}" "0"
ok "and the file is left alone" "$(test -f "${SLEEPFILE}" && echo yes)" "yes"

# Past the deadline but inside the grace. The deadline only covers the game
# that was running when it was written, so it falls due during any slow core
# load while SAM is perfectly healthy - releasing here would hand the port back
# to two writers, which is the thing the file exists to prevent.
printf '%s\n' "$(( $(now) - 1 ))" >"${SLEEPFILE}"
sleepmode_pass; ok "just past the deadline still holds it" "${?}" "0"
ok "and still does not touch the file" "$(test -f "${SLEEPFILE}" && echo yes)" "yes"

# Past the grace as well: the holder is gone and is not coming back.
oldcore="something"; META_WIRE_LAST="something"; DEFERRED_DONE="yes"
printf '%s\n' "$(( $(now) - SLEEP_STALE_GRACE - 1 ))" >"${SLEEPFILE}"
sleepmode_pass; ok "past the grace, the display is ours again" "${?}" "1"
ok "and the stale file is removed" "$(test -f "${SLEEPFILE}" && echo yes)" ""

# Released normally, while we are waiting on it. SAM has been drawing over
# everything all session and signs off with CMDSWSAVER,1 and a CMDCLST, so the
# screensaver is on whatever SAM wanted rather than whatever the ini says and
# nothing on the panel came from us. The next pass has to be a full redraw.
if [ "${HAVE_INOTIFY}" = "yes" ]; then
  oldcore="something"; META_WIRE_LAST="something"; DEFERRED_DONE="yes"
  printf '%s\n' "$(( $(now) + 300 ))" >"${SLEEPFILE}"
  ( sleep 0.3; rm -f "${SLEEPFILE}" ) &
  sleepmode_pass; ok "the delete hands the display back" "${?}" "1"
  ok "the core is forgotten, forcing a redraw" "${oldcore}" ""
  ok "the last metadata line is forgotten too" "${META_WIRE_LAST}" ""
  ok "and the deferred settings are re-sent" "${DEFERRED_DONE}" "no"
  wait
else
  skip "waking on the delete" "no inotify-tools"
fi

# No inotify-tools: inotifywait fails and returns at once. Every branch of the
# main loop has to block, or the daemon eats a core - and this branch only ever
# avoided that by accident, because the settling sleep happened to sit under
# it. Shadowing the command is how the workstation plays a machine without it.
rm -f "${SLEEPFILE}"; printf '%s\n' "$(( $(now) + 300 ))" >"${SLEEPFILE}"
inotifywait() { return 127; }
T0="$(tenths)"; sleepmode_pass; RC="${?}"; T1="$(tenths)"
unset -f inotifywait
ok "with no inotifywait it still holds the display" "${RC}" "0"
ok "and still brakes the loop rather than spinning" "$(( T1 - T0 >= 8 ))" "1"
rm -f "${SLEEPFILE}"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
