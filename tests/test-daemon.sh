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

# The port library, which the daemon sources from the install folder.
PORT_ID_FILE="${TMP}/display-port"; rm -f "${PORT_ID_FILE}"
# shellcheck source=../tools/tty2oled-port.sh
. "${ROOT}/tools/tty2oled-port.sh"
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

# The menu entry reaches the Scripts folder from here, not only from the
# installer: an update is applied by the *previous* installer, which knows
# nothing of a file added after it - so the daemon's own start is the first
# thing a new version controls. That is what carries the launcher onto a
# MiSTer whose last update predates it, as it carried the 0.4.8b renaming.
SCRIPTSPATH="${TMP}/Scripts"; TTY2OLED_PATH="${TMP}/install"
mkdir -p "${SCRIPTSPATH}" "${TTY2OLED_PATH}"
ok "the launcher is the one menu entry" "${MENU_SCRIPTS}" "tty2oledplus.sh"
place_menu_scripts
ok "nothing to place, nothing placed" \
   "$([ -e "${SCRIPTSPATH}/tty2oledplus.sh" ] && echo yes || echo no)" "no"

echo "#!/bin/bash" > "${TTY2OLED_PATH}/tty2oledplus.sh"
place_menu_scripts
ok "an install that has the launcher gets it into the Scripts menu" \
   "$([ -x "${SCRIPTSPATH}/tty2oledplus.sh" ] && echo yes || echo no)" "yes"
ok "and it can be run from there" "$(cat "${SCRIPTSPATH}/tty2oledplus.sh")" "#!/bin/bash"

echo "# newer" >> "${TTY2OLED_PATH}/tty2oledplus.sh"
place_menu_scripts
ok "a newer one replaces it" "$(grep -c '# newer' "${SCRIPTSPATH}/tty2oledplus.sh")" "1"
touch -d "2020-01-01" "${SCRIPTSPATH}/tty2oledplus.sh"
BEFORE="$(stat -c %Y "${SCRIPTSPATH}/tty2oledplus.sh")"
place_menu_scripts
ok "an identical one is left alone, so every boot is not a write" \
   "$(stat -c %Y "${SCRIPTSPATH}/tty2oledplus.sh")" "${BEFORE}"

# The three entries the launcher replaced, and the pre-0.4.8b names - which
# only the daemon can clear: the installer that put them there is the one
# that ran the update, and 0.6.2b's puts its own updater back after the
# daemon has already started.
for f in ${MENU_SCRIPTS_LEGACY}; do echo "# old" > "${SCRIPTSPATH}/${f}"; done
for f in tty2oledplus_update.sh tty2oledplus_settings.sh tty2oledplus_uninstall.sh; do
  echo "#!/bin/bash" > "${TTY2OLED_PATH}/${f}"
done
place_menu_scripts
LEFT=""
for f in ${MENU_SCRIPTS_LEGACY}; do [ -e "${SCRIPTSPATH}/${f}" ] && LEFT="${LEFT} ${f}"; done
ok "the old entries are swept once the launcher is in" "${LEFT}" ""
ok "all six of them" "$(echo ${MENU_SCRIPTS_LEGACY} | wc -w | tr -d ' ')" "6"
ok "and the launcher is still there" \
   "$([ -x "${SCRIPTSPATH}/tty2oledplus.sh" ] && echo yes || echo no)" "yes"
# Only the menu's copies: the launcher runs them from the install folder.
LEFT=0
for f in tty2oledplus_update.sh tty2oledplus_settings.sh tty2oledplus_uninstall.sh; do
  [ -e "${TTY2OLED_PATH}/${f}" ] && LEFT=$((LEFT+1))
done
ok "while the install folder keeps what the launcher opens" "${LEFT}" "3"
ok "and nothing is placed beside the launcher" "$(ls "${SCRIPTSPATH}")" "tty2oledplus.sh"

# An install with no launcher yet - a failed update - must not take the old
# menu entries away, or it leaves a MiSTer with no way to update or uninstall.
rm -f "${SCRIPTSPATH}"/* "${TTY2OLED_PATH}"/tty2oledplus*.sh
echo "# old" > "${SCRIPTSPATH}/tty2oledplus_update.sh"
place_menu_scripts
ok "no launcher leaves the old entries alone" \
   "$([ -e "${SCRIPTSPATH}/tty2oledplus_update.sh" ] && echo yes || echo no)" "yes"

# exFAT ignores case, and none of the names swept may be the launcher's.
ok "no old name is the launcher's in another case" \
   "$(for f in ${MENU_SCRIPTS_LEGACY}; do printf '%s\n' "${f}"; done | grep -ixc 'tty2oledplus.sh')" "0"

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
# The alternatives were dropped since: nothing reads them any more, so an
# install old enough to still have them loses them rather than moving them.
ok "its alternatives are dropped"        "$(ls "${TTY2OLED_PATH}/pics/banner" | grep -c _alt)" "0"
ok "and not moved anywhere"              "$([ -e "${TTY2OLED_PATH}/pics/alt" ] && echo there || echo gone)" "gone"
ok "the icons become pics/icon"          "$(cat "${TTY2OLED_PATH}/pics/icon/NES.gsc" 2>&1)" "icon"
ok "your own banners become pics/user"   "$(cat "${TTY2OLED_PATH}/pics/user/NES.gsc" 2>&1)" "mine"
ok "and nothing is left of the old names" \
   "$(ls -d "${TTY2OLED_PATH}/pics/GSC" "${TTY2OLED_PATH}/pics_pri" 2>/dev/null | wc -l | tr -d ' ')" "0"

# An install from between the two has a pics/alt of the release's, and the
# next start removes it - pics/user, beside it, is untouched.
mkdir -p "${TTY2OLED_PATH}/pics/alt"
echo alt > "${TTY2OLED_PATH}/pics/alt/NES_alt1.gsc"
migrate_pics
ok "a pics/alt left by an earlier release is removed" \
   "$([ -e "${TTY2OLED_PATH}/pics/alt" ] && echo there || echo gone)" "gone"
ok "and your own banners are not"        "$(cat "${TTY2OLED_PATH}/pics/user/NES.gsc" 2>&1)" "mine"

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

# /media/fat is exFAT, which ignores case: there pics/ICON is not a leftover
# of the old layout, it is pics/icon itself, and 0.5.8b to 0.6.0b deleted
# every icon on every start by removing it under that name. A symlink stands
# in for the second spelling, and an rm that follows it stands in for a
# filesystem on which both names reach the same folder.
rm -rf "${TTY2OLED_PATH}"
mkdir -p "${TTY2OLED_PATH}/pics/icon"
echo icon > "${TTY2OLED_PATH}/pics/icon/NES.gsc"
ln -s icon "${TTY2OLED_PATH}/pics/ICON"
# An executable first on PATH rather than a function named rm: a function
# would shadow every rm in this file as far as shellcheck can tell.
mkdir -p "${TMP}/caseblind"
cat > "${TMP}/caseblind/rm" <<EOF
#!/bin/bash
a=()
for x in "\$@"; do
  case "\${x}" in -*) a+=("\${x}") ;; *) a+=("\$(readlink -f -- "\${x}")") ;; esac
done
exec $(command -v rm) "\${a[@]}"
EOF
chmod +x "${TMP}/caseblind/rm"
( PATH="${TMP}/caseblind:${PATH}"; migrate_pics )
ok "on a case-blind card the icons survive a start" \
   "$(cat "${TTY2OLED_PATH}/pics/icon/NES.gsc" 2>&1)" "icon"
# Where the two names really are two folders, the old one still goes.
command rm -f "${TTY2OLED_PATH}/pics/ICON"
mkdir -p "${TTY2OLED_PATH}/pics/ICON"
migrate_pics
ok "a separate old pics/ICON is still swept" \
   "$([ -d "${TTY2OLED_PATH}/pics/ICON" ] && echo yes || echo no)" "no"
ok "leaving pics/icon alone" "$(cat "${TTY2OLED_PATH}/pics/icon/NES.gsc" 2>&1)" "icon"

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
mkdir -p "${bannerfolder}" "${userbannerfolder}"
SHOW_METADATA="yes"; TRANSITION="-2"; META_WIRE_LAST="CMDMETA,..."
# Moving to the update_all screen is as much a change of picture as a core
# change is, so it arrives the same way - CMDMSG carries the effect, which a
# bare line cannot. The artwork pack has no update_all.gsc, so this is the
# path most MiSTers actually take.
ok "no picture: metadata off, then the name as text, transitioned" \
   "$(sendupdateall | tr '\n' ' ')" "CMDMETAOFF CMDMSG,-2,update_all "
TRANSITION="30"
ok "with whatever effect the ini asks for" \
   "$(sendupdateall | grep -a CMDMSG | tr -d '\r\n')" "CMDMSG,30,update_all"
TRANSITION="-2"
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
# ...and with no effect on the end, deliberately. By this point the panel is
# already the update_all screen: nothing is being replaced, and fading from
# one message to another would say something changed when nothing did. The
# screens that *are* a replacement - update_all arriving, the updater taking
# over - carry one.
ok "and the downloader's bar is not transitioned into" \
   "$(grep -c ',Updating System ...,' "${WIRE}")" "0"
: >"${WIRE}"; updateall_pass
ok "and is not restarted every pass" "$(wc -c <"${WIRE}")" "0"
rm -rf "${PROC_ROOT}/601"
# Every write truncates this file, so what the whole pass sent is read off
# stdout instead - with the picture out of the way, so it is all text.
mv "${bannerfolder}/update_all.gsc" "${TMP}/update_all.gsc.away"
ok "the downloader done, the bar stops and the banner is drawn again" \
   "$(TTYDEV=/dev/stdout updateall_pass | tr '\n' ' ')" "CMDBUSY,0 CMDMETAOFF CMDMSG,-2,update_all "
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
UA_RUN="no"; UA_DONE_AT=""

# ---------------------------------------------------------------------------
section "update_all: its own words under the bar, and the finish"
# ---------------------------------------------------------------------------

# The firmware is asked before anything new goes on the wire: a command it
# does not know is drawn on the panel as text.
for v in "0.7.0b:0" "0.7.0:0" "0.7.3b:0" "0.10.0b:0" "1.0.0b:0" "0.6.10b:1" "0.6.9b:1" \
         "240519T:1" ":1" "0.7:1"; do
  FW_VERSION="${v%:*}"; fw_atleast 0.7.0
  ok "fw_atleast 0.7.0 with firmware '${v%:*}'" "${?}" "${v#*:}"
done

# ua_parselog, on what update_all 2.11 really writes: the downloader's
# progress dots with no newline, rules, a centred summary, DUPLICATED lines
# by the hundred.
LOG="${TMP}/update_all_print.log"
printf '%s\n' "Reading sections from /media/fat/downloader.ini" "" "Sequence:" \
  "- Main Distribution: MiSTer-devel" "- JTCORES for MiSTer" "" \
  "########################################################################" \
  "#======================================================================#" \
  "Running MiSTer Downloader" "" "START!" "" \
  "########################################################################" \
  "SECTION: jtcores" "_Arcade/cores/jtkiwi_20260927.rbf" >"${LOG}"
printf '........*.' >>"${LOG}"
ok "the last useful line, past the progress dots" \
   "$(ua_parselog <"${LOG}" | tr '\n' '|')" "||_Arcade/cores/jtkiwi_20260927.rbf|"
printf '\n%s\n' "DUPLICATED: _Arcade/Many Block.mra in [a, b] [using a instead]" >>"${LOG}"
ok "DUPLICATED warnings are not progress" "$(ua_parselog <"${LOG}" | sed -n 3p)" \
   "_Arcade/cores/jtkiwi_20260927.rbf"
printf '\r\n  - Arcade Organizer  \r\n' >>"${LOG}"
ok "carriage returns, padding and a list's dash go" "$(ua_parselog <"${LOG}" | sed -n 3p)" "Arcade Organizer"
printf '%s\n' "                  ╔════╗" >>"${LOG}"
ok "and a box drawn in UTF-8 is not a line" "$(ua_parselog <"${LOG}" | sed -n 3p)" "Arcade Organizer"
cp "${LOG}" "${TMP}/log.running"
printf '%s\n' "" "########################################################################" \
  "Update All 2.11 by theypsilon 00:49.38s 2026-09-28 16:09:49" "" \
  "Success! More details at: Scripts/.config/update_all/update_all.log" "" \
  "Shoutout to Thomas Williams! patreon.com/theypsilon" >>"${LOG}"
ok "the end: a verdict and the run time" "$(ua_parselog <"${LOG}" | sed -n 1,2p | tr '\n' '|')" "ok|00:49|"
cp "${LOG}" "${TMP}/log.success"
cp "${TMP}/log.running" "${TMP}/log.failed"
printf '%s\n' "Update All 2.11 by theypsilon 01:02:03.00s 2026-09-28" "" \
  "There were some errors in the Updaters." "Therefore, MiSTer hasn't been fully updated." \
  >>"${TMP}/log.failed"
ok "or it failed, and an hour-long run keeps its hours" \
   "$(ua_parselog <"${TMP}/log.failed" | sed -n 1,2p | tr '\n' '|')" "failed|01:02:03|"

# The follower works over only the lines that can matter (ua_feed); it has
# to come to what taking every line in full would.
seqparse() {
  local LC_ALL=C UA_VERDICT="" UA_RUNTIME="" UA_LINE="" UA_MAIN="" l
  while IFS= read -r l || [ -n "${l}" ]; do ua_takeline "${l}"; done
  printf '%s|%s|%s|%s' "${UA_VERDICT}" "${UA_RUNTIME}" "${UA_LINE}" "${UA_MAIN}"
}
batched() {
  local LC_ALL=C UA_VERDICT="" UA_RUNTIME="" UA_LINE="" UA_MAIN="" UA_CAND=() l
  while IFS= read -r l || [ -n "${l}" ]; do ua_feed "${l}"; done
  ua_takecand
  printf '%s|%s|%s|%s' "${UA_VERDICT}" "${UA_RUNTIME}" "${UA_LINE}" "${UA_MAIN}"
}
{ printf '%s\n' "Sequence:" "- Main Distribution: MiSTer-devel" "_Arcade/cores/Useful_20260929.rbf"
  for i in $(seq 200); do printf '%s\n' "########################################################################"; done
  for i in $(seq 300); do printf 'DUPLICATED: _Arcade/Many %s.mra in [a, b] [using a instead]\n' "${i}"; done
  printf '  ....*.. \n\n'; } >"${TMP}/burst.log"
ok "a useful line under 200 rules and 300 DUPLICATED lines is still the line" \
   "$(batched <"${TMP}/burst.log")" "||_Arcade/cores/Useful_20260929.rbf|yes"
for f in "${TMP}/log.running" "${TMP}/log.success" "${TMP}/log.failed" "${TMP}/burst.log"; do
  ok "held back or taken in full, the same: ${f##*/}" "$(batched <"${f}")" "$(seqparse <"${f}")"
done
printf 'a\r\n  - Arcade Organizer  \r\nb\n' >"${TMP}/cr.log"
ok "and with carriage returns" "$(batched <"${TMP}/cr.log")" "$(seqparse <"${TMP}/cr.log")"

LONG="_Arcade/cores/some/deep/folder/Arcade-NamcoS2_SG_20260927.rbf"
ok "a long path keeps its end" "$(ua_shorten "${LONG}")" ".../some/deep/folder/Arcade-NamcoS2_SG_20260927.rbf"
ok "at the status line's 51 columns" "$(ua_shorten "${LONG}" | wc -c | tr -d ' ')" "51"
ok "a long sentence keeps its start" \
   "$(ua_shorten "Check your connection and then run this script again, please, now")" \
   "Check your connection and then run this script a..."
ok "a short line is left alone" "$(ua_shorten "SECTION: jtcores")" "SECTION: jtcores"

# The pass. Every write reopens the port, and a regular file would be
# truncated each time, so the wire is a pipe into the file - and the pass
# runs in this shell, so its state is kept.
pass() { : >"${WIRE}"; TTYDEV=/dev/stdout updateall_pass > >(cat >>"${WIRE}"); UA_RC="${?}"; wait "${!}" 2>/dev/null; }
wire() { tr '\n' '|' <"${WIRE}"; }
UA_PRINTLOG="${LOG}"; UA_FINALLOG="${TMP}/update_all.log"
UPDATE_ALL_POLL="0"; TRANSITION="-2"; SHOW_METADATA="no"
UPDATE_ALL_DETAILS="yes"; UPDATE_DONE_SECS="1"
UPDATE_DONE_TEXT="Update Complete"; UPDATE_FAILED_TEXT="Update Failed"
mv "${bannerfolder}/update_all.gsc" "${TMP}/update_all.gsc.away"
uareset() {
  rm -rf "${PROC_ROOT}"/5[0-9][0-9] "${PROC_ROOT}"/6[0-9][0-9]
  UPDATEALL_SHOWN="no"; UPDATEALL_BUSY="no"; UA_RUN="no"; UA_DONE_AT=""; BUSYLINE_LAST=""
  FW_VERSION="0.7.0b"
}

# update_all started and its log written since: two passes in, the log fresh.
uastart() {
  uareset; FW_VERSION="${1:-0.7.0b}"
  rm -f "${LOG}"
  mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
  pass
  cp "${TMP}/log.running" "${LOG}"
  pass
}

# The previous run's log, verdict and all, is still there when update_all
# starts: its launcher runs before it recreates the file.
uareset
cp "${TMP}/log.success" "${LOG}"; touch -d '-1 hour' "${LOG}"
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
pass
ok "update_all starts: its banner" "$(wire)" "CMDMSG,-2,update_all|"
pass
ok "the last run's verdict is not this one's" "$(wire)" ""
ok "nor its Sequence" "${UA_MAIN}" "no"

# It recreates the file: intro, countdown - still only asking.
printf '%s\n' "Reading sections from /media/fat/downloader.ini" "" >"${LOG}.new"; mv "${LOG}.new" "${LOG}"
pass
ok "the countdown is not an update" "$(wire)" ""

# The main run begins.
printf '%s\n' "Sequence:" "- Main Distribution: MiSTer-devel" >>"${LOG}"
pass
ok "Sequence: the label, and its line" "$(wire)" "CMDBUSY,1,Updating System ...|CMDBUSYLINE,Main Distribution: MiSTer-devel|"
pass
ok "the same line is not sent again" "$(wire)" ""
mkproc 601 /tmp/ua_downloader_bin
printf '%s\n' "Running MiSTer Downloader" "SECTION: jtcores" >>"${LOG}"
pass
ok "the downloader's lines follow" "$(wire)" "CMDBUSYLINE,SECTION: jtcores|"
printf '%s\n' "${LONG}" "....*." >>"${LOG}"
pass
ok "shortened to fit" "$(wire)" "CMDBUSYLINE,.../some/deep/folder/Arcade-NamcoS2_SG_20260927.rbf|"
ok "polled every second while it follows the log" "$(UPDATE_ALL_POLL=2 ua_poll)" "1"
ok "unless UPDATE_ALL_POLL is already quicker" "$(UPDATE_ALL_POLL=0 ua_poll)" "0"
rm -rf "${PROC_ROOT}/601"
printf '%s\n' "Running Arcade Organizer" >>"${LOG}"
pass
ok "the downloader done, the update is not: the label stays" "$(wire)" "CMDBUSYLINE,Running Arcade Organizer|"

# The verdict: the label becomes the finish, the bar runs off. Appended, as
# update_all writes it.
tail -n 7 "${TMP}/log.success" >>"${LOG}"
pass
ok "success: Update Complete, and the run time under it" "$(wire)" \
   "CMDBUSY,0,Update Complete,-2|CMDBUSYLINE,Finished in 00:49|"
pass
ok "sent once" "$(wire)" ""
# update_all exits at once: the rest of the second is waited out.
rm -rf "${PROC_ROOT}/500"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "gone before UPDATE_DONE_SECS: the rest of it is waited" "$(( T1 - T0 >= 8 ))" "1"
ok "then back to the core" "${UA_RC}|${oldcore}|$(wire)" "1||"

# update_all stays up past it - its log viewer - and exits later: no wait.
uastart
cp "${TMP}/log.success" "${LOG}"; pass
T0="$(tenths)"; while [ "$(( $(tenths) - T0 ))" -lt 11 ]; do :; done
rm -rf "${PROC_ROOT}/500"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "outlasting UPDATE_DONE_SECS: back to the core at once" "$(( T1 - T0 < 5 ))" "1"

# Printed and gone between two looks: the finish still goes up, and stays.
uastart
cp "${TMP}/log.success" "${LOG}"; rm -rf "${PROC_ROOT}/500"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "a verdict found after it exited is shown" "$(wire)" \
   "CMDBUSY,0,Update Complete,-2|CMDBUSYLINE,Finished in 00:49|"
ok "for the whole of UPDATE_DONE_SECS" "$(( T1 - T0 >= 8 ))" "1"

# Failed.
uastart
cp "${TMP}/log.failed" "${LOG}"; pass
ok "errors: Update Failed, and where to look" "$(wire)" \
   "CMDBUSY,0,Update Failed,-2|CMDBUSYLINE,Some updaters failed - see the log|"
UA_DONE_AT=""; rm -rf "${PROC_ROOT}/500"; pass

# An update_all that writes no print log: the verdict is in its own log,
# written as it exits.
uareset
rm -f "${LOG}"
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
pass
mkproc 601 /tmp/ua_downloader_bin
pass
ok "no print log: the label, no line" "$(wire)" "CMDBUSY,1,Updating System ...|"
rm -rf "${PROC_ROOT}/601" "${PROC_ROOT}/500"
cp "${TMP}/log.success" "${UA_FINALLOG}"
pass
ok "and the finish from update_all.log" "$(wire | cut -d'|' -f1)" "CMDBUSY,0,Update Complete,-2"
# ...but not a log left by an earlier run.
uareset
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
touch -d '-1 hour' "${UA_FINALLOG}"
pass; mkproc 601 /tmp/ua_downloader_bin; pass
rm -rf "${PROC_ROOT}/601" "${PROC_ROOT}/500"
pass
ok "an old update_all.log says nothing about this run" "$(wire)" "CMDBUSY,0|"

# Settings.
UPDATE_ALL_DETAILS="no"; uastart
ok "UPDATE_ALL_DETAILS=no: the label without a line" "$(wire)" "CMDBUSY,1,Updating System ...|"
cp "${TMP}/log.success" "${LOG}"; pass
ok "the finish still has its own" "$(wire)" "CMDBUSY,0,Update Complete,-2|CMDBUSYLINE,Finished in 00:49|"
UA_DONE_AT=""; rm -rf "${PROC_ROOT}/500"; pass
UPDATE_ALL_DETAILS="yes"

UPDATE_DONE_SECS="0"; uastart
cp "${TMP}/log.success" "${LOG}"; pass
ok "UPDATE_DONE_SECS=0: no finish screen" "$(wire | grep -c 'Update Complete')" "0"
rm -rf "${PROC_ROOT}/500"; pass
ok "straight back to the core" "$(wire)" "CMDBUSY,0|"
UPDATE_DONE_SECS="1"

# Firmware before 0.7.0b: exactly the old screens.
uastart 0.6.9b
ok "old firmware: Sequence alone is not the bar" "$(wire)" ""
mkproc 601 /tmp/ua_downloader_bin; pass
ok "the downloader is, with no line" "$(wire)" "CMDBUSY,1,Updating System ...|"
rm -rf "${PROC_ROOT}/601"; pass
ok "and after it, the banner again" "$(wire)" "CMDBUSY,0|CMDMSG,-2,update_all|"
cp "${TMP}/log.success" "${LOG}"; pass
ok "no finish screen" "$(wire)" ""
rm -rf "${PROC_ROOT}/500"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "and no wait" "$(( T1 - T0 < 5 ))" "1"

# ---------------------------------------------------------------------------
# 0.7.3b: the line followed ten times a second, and nothing started to do it
# ---------------------------------------------------------------------------
# A writer appending a line every 100ms, as the downloader does - faster, in
# truth. Started before anything else so its own processes are its own.
writer() {  # writer <lines> [then]
  ( for i in $(seq "${1}"); do printf '%s\n' "_Console/Core${i}_20260929.rbf" >>"${LOG}"; sleep 0.1; done
    [ -n "${2:-}" ] && tail -n 7 "${TMP}/log.success" >>"${LOG}" ) &
  WRITER=$!
}
busylines() { grep -ac '^CMDBUSYLINE,' "${WIRE}"; }

UPDATE_ALL_POLL="1"
uastart 0.7.0b
writer 12; : >"${WIRE}"; pass; wait "${WRITER}"
ok "firmware before 0.7.3b: one line a pass, as before" "$(busylines)" "1"

uastart 0.7.3b
writer 12; : >"${WIRE}"; pass; wait "${WRITER}"
ok "0.7.3b: the line follows the log within the pass" "$(( $(busylines) >= 6 ))" "1"
ok "the latest line, not a queue of them" "$(( $(busylines) <= 11 ))" "1"

# Nothing is started while it follows: every command the daemon could reach
# for is a logging stand-in on PATH for the length of it. The capture is a
# FIFO with its reader already running, so the plumbing starts nothing either.
FORKLOG="${TMP}/forks"; FORKBIN="${TMP}/forkbin"; rm -rf "${FORKBIN}"; mkdir -p "${FORKBIN}"
for c in stat tail awk tr grep sleep cat date head sed wc cut printf; do
  real="$(command -v "${c}")" || continue
  printf '#!/bin/sh\necho %s >>"%s"\nexec %s "$@"\n' "${c}" "${FORKLOG}" "${real}" >"${FORKBIN}/${c}"
  chmod +x "${FORKBIN}/${c}"
done
FIFO="${TMP}/wire-fifo"; rm -f "${FIFO}"; mkfifo "${FIFO}"
( while :; do cat "${FIFO}"; done >>"${WIRE}" ) 2>/dev/null &
READER=$!
uastart 0.7.3b
nap 0.01                                   # its pipe, set up once, outside the watch
writer 8
: >"${WIRE}"; : >"${FORKLOG}"
KEEP="${PATH}"; PATH="${FORKBIN}:${PATH}"; KEEPTTY="${TTYDEV}"; TTYDEV="${FIFO}"
T0="$(tenths)"; ua_follow 1000; T1="$(tenths)"
PATH="${KEEP}"; TTYDEV="${KEEPTTY}"
wait "${WRITER}"; sleep 0.3; kill "${READER}" 2>/dev/null; rm -f "${FIFO}"
ok "following the log for a second starts no process" "$(tr '\n' ' ' <"${FORKLOG}")" ""
ok "and sends the lines as they come" "$(( $(busylines) >= 5 ))" "1"
ok "for the second it was given" "$(( T1 - T0 >= 9 && T1 - T0 <= 13 ))" "1"

# The verdict ends it early, for the pass to put the finish up at once.
uastart 0.7.3b
writer 2 then
T0="$(tenths)"; ua_follow 3000 >/dev/null; T1="$(tenths)"; wait "${WRITER}"
ok "a verdict ends the follow at once" "$(( T1 - T0 < 15 ))|${UA_VERDICT}" "1|ok"

# A line still being written waits for its newline.
uastart 0.7.3b
ua_readlog fast; BEFORE="${UA_LINE}"
printf 'Installing abc' >>"${LOG}"; ua_readlog fast
ok "half a line is not shown" "${UA_LINE}" "${BEFORE}"
printf 'def\n' >>"${LOG}"; ua_readlog fast
ok "the whole of it is, once it ends" "${UA_LINE}" "Installing abcdef"
printf 'Last words' >>"${LOG}"; ua_readlog final
ok "and a last line with no newline, when nothing more is coming" "${UA_LINE}" "Last words"

# Replaced: another file at the path. Cut short: the same file, rewritten.
uastart 0.7.3b
printf '%s\n' "Sequence:" "Fresh line" >"${LOG}.new"; mv "${LOG}.new" "${LOG}"
ua_readlog fast
ok "a file replaced under it is opened again, from the start" "${UA_LINE}" "Fresh line"
printf 'Short\n' >"${LOG}"
ua_readlog fast
ok "one cut short is not noticed on a quick look" "${UA_LINE}" "Fresh line"
ua_readlog slow
ok "but is on the once-a-second one" "${UA_LINE}" "Short"
UPDATE_ALL_POLL="0"

# ---------------------------------------------------------------------------
# MiSTer's own updater - Scripts/update.sh, which Zaparoo's Update runs
# ---------------------------------------------------------------------------
# update.sh copies the Downloader to /tmp/downloader.sh and runs it, as seen
# on a MiSTer under Zaparoo. It gets update_all's screens, all of it the bar.
uareset
sysupdate_process; ok "nothing running: no system update" "${?}:${SYSUPD}" "1:"
mkproc 540 /bin/bash /media/fat/Scripts/update.sh
sysupdate_process; ok "Scripts/update.sh is MiSTer's updater" "${?}:${SYSUPD}:${SYSUPD_PID}" "0:downloader:"
updateall_process; ok "which counts as a system update running" "${?}" "0"
mkproc 541 /tmp/downloader.sh
sysupdate_process; ok "and its Downloader, with its pid" "${SYSUPD}:${SYSUPD_PID}" "downloader:541"
mkproc 542 /usr/bin/python3 /tmp/x/update_all.pyz
sysupdate_process; ok "anything naming update_all under it is its" "${SYSUPD}" "downloader"
uareset
mkproc 540 /bin/bash /media/fat/Scripts/tty2oledplus_update.sh
mkproc 541 vi /media/fat/Scripts/update.sh.bak
mkproc 542 /bin/sh -c "cat /media/fat/Scripts/update.sh"
mkproc 543 /tmp/downloader.sh --list-dbs
sysupdate_process; ok "not our updater, a query, nor anything else naming it" "${?}:${SYSUPD}" "1:"
uareset
mkproc 500 /bin/bash /media/fat/Scripts/update_all.sh
mkproc 601 /tmp/ua_downloader_bin
sysupdate_process; ok "update_all is still update_all" "${SYSUPD}" "update_all"

DL_FINALLOG="${TMP}/downloader.log"; DLLOG="${TMP}/tmpk3v9_x2q"
dlsummary() {  # dlsummary <what the Errors: heading has under it>
  printf '%s\n' "DEBUG| Moving downloader.log" "$(printf '=%.0s' $(seq 80))" \
    "Downloader 2.4 (615) by theypsilon. Run time: 05:26.71s at 2026-09-29 14:45:41" \
    "Log: /media/fat/Scripts/.config/downloader/downloader.log" "" \
    "Installed:" "aliensec.zip, grdians.zip" "" "Errors:" "${1}" "" \
    "Reboot MiSTer to apply some changes." "" >"${DL_FINALLOG}"
}
# The launcher, then its Downloader, holding its log open as Python's tempfile.
dlstart() {
  uareset; FW_VERSION="${1:-0.7.0b}"
  rm -f "${DL_FINALLOG}" "${DLLOG}"
  mkproc 540 /bin/bash /media/fat/Scripts/update.sh
  pass
}
dlrun() {
  printf '%s\n' "DEBUG| Config: {}" "START!" "SECTION: jtcores" "****" >"${DLLOG}"
  mkproc 541 /tmp/downloader.sh
  mkdir -p "${PROC_ROOT}/541/fd"
  ln -sf /dev/null "${PROC_ROOT}/541/fd/0"; ln -sf "${DLLOG}" "${PROC_ROOT}/541/fd/3"
  pass
}

dlstart
ok "it starts: no update_all picture, the label at once, transitioned" "$(wire)" "CMDBUSY,1,Updating System ...,-2|"
pass
ok "no line before its Downloader has a log" "$(wire)" ""
dlrun
ok "its log found and followed" "$(wire)" "CMDBUSYLINE,SECTION: jtcores|"
printf '%s\n' "No changes: games/mame/1on1gov.zip" "DEBUG| Moving x" \
  "Traceback (most recent call last):" '  File "/app/downloader/file_system.py", line 552, in x' >>"${DLLOG}"
pass
ok "its debug lines and tracebacks are no status" "$(wire)" "CMDBUSYLINE,No changes: games/mame/1on1gov.zip|"
# Its log comes in 8KB bursts, minutes apart: between them the line is the
# file it has open under /media - not its own files, nor the log.

ln -sf "/media/fat/Scripts/.config/downloader/downloader.json" "${PROC_ROOT}/541/fd/4"
ln -sf "/media/usb0/games/mame/intcup94.zip" "${PROC_ROOT}/541/fd/5"
pass
ok "nothing new in its log: the file it has open" "$(wire)" "CMDBUSYLINE,games/mame/intcup94.zip|"
rm -f "${PROC_ROOT}/541/fd/5"
pass
ok "nothing open a moment: the file stays, not a blank" "$(wire)" ""
ln -sf "/media/usb0/games/mame/intcup94.zip" "${PROC_ROOT}/541/fd/5"
pass
ok "the same file is not sent again" "$(wire)" ""
printf '%s\n' "No changes: games/mame/spidman.zip" >>"${DLLOG}"
pass
ok "a burst of its log: its last line" "$(wire)" "CMDBUSYLINE,No changes: games/mame/spidman.zip|"
rm -f "${PROC_ROOT}/541/fd/5"
pass
ok "nothing open and nothing new: the line stays" "$(wire)" ""
# The summary is no status: "none." under "Errors:" was the last line shown.
printf '%s\n' "$(printf '=%.0s' $(seq 80))" \
  "Downloader 2.4 (615) by theypsilon. Run time: 05:26.71s at 2026-09-29 14:45:41" \
  "Installed:" "aliensec.zip" "" "Errors:" "none." >>"${DLLOG}"
ln -sf "/media/usb0/games/mame/intcup94.zip" "${PROC_ROOT}/541/fd/5"
pass
ok "its summary changes nothing on the line" "$(wire)" ""
dlsummary "none."; rm -rf "${PROC_ROOT}/540" "${PROC_ROOT}/541"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "done: Update Complete, and its run time" "$(wire)" \
   "CMDBUSY,0,Update Complete,-2|CMDBUSYLINE,Finished in 05:26|"
ok "for the whole of UPDATE_DONE_SECS" "$(( T1 - T0 >= 8 ))" "1"
ok "then back to the core" "${UA_RC}|${oldcore}" "1|"

dlstart; dlrun
dlsummary "games/mame/aliensec.zip"; rm -rf "${PROC_ROOT}/540" "${PROC_ROOT}/541"
pass
ok "errors: Update Failed" "$(wire)" \
   "CMDBUSY,0,Update Failed,-2|CMDBUSYLINE,Some files failed - see the log|"

# Cancelled in Zaparoo: SIGTERM, no summary; the log left is the last run's.
dlstart; dlrun
dlsummary "none."; touch -d '-1 hour' "${DL_FINALLOG}"
rm -rf "${PROC_ROOT}/540" "${PROC_ROOT}/541"
T0="$(tenths)"; pass; T1="$(tenths)"
ok "stopped part way: straight back, no finish" "$(wire)|$(( T1 - T0 < 5 ))" "CMDBUSY,0||1"

dlstart 0.6.9b
pass
ok "old firmware: the label all the same, never the update_all picture" "$(wire)" ""
rm -rf "${PROC_ROOT}/540"; pass
ok "and no finish" "$(wire)" "CMDBUSY,0|"

UPDATE_ALL_SCREEN="no"; uareset
mkproc 540 /bin/bash /media/fat/Scripts/update.sh
pass
ok "UPDATE_ALL_SCREEN=no leaves it alone too" "${UA_RC}|$(wire)" "1|"
UPDATE_ALL_SCREEN="yes"
rm -f "${DL_FINALLOG}" "${DLLOG}"

uareset
mv "${TMP}/update_all.gsc.away" "${bannerfolder}/update_all.gsc"
UA_RUN="no"; UA_DONE_AT=""; TTYDEV="${WIRE}"
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
# The updater starts the daemon a second before it exits, with its finish on
# the panel; the daemon must not put "Updating" back over it.
SELFUPDATE_OURS="$(selfupdate_pids)"
ok "the daemon notes an updater already running when it starts" "${SELFUPDATE_OURS}" "700 "
selfupdate_running; ok "and does not take it for an update starting" "${?}" "1"
mkproc 702 /bin/bash /media/fat/tty2oledplus/tty2oledplus_update.sh
selfupdate_running; ok "a later one it does" "${?}" "0"
rm -rf "${PROC_ROOT}/702"; SELFUPDATE_OURS=""

oldcore="NES"; META_WIRE_LAST="CMDMETA,..."
# The updater's screen replaces a core's artwork, so it arrives like a
# picture rather than appearing.
ok "the message and the bar go out, with no banner, transitioned" \
   "$(TTYDEV=/dev/stdout selfupdate_pass | tr '\n' ' ')" \
   "CMDMETAOFF CMDBUSY,1,Updating TTY2OLED+...,-2 "
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
   "$(TTYDEV=/dev/stdout selfupdate_pass | tail -n1)" "CMDBUSY,1,Updating TTY2OLED+...,-2"
rm -rf "${PROC_ROOT}/500" "${PROC_ROOT}/700"
SELFUPDATE_SHOWN="no"

ok "the daemon's wait times out for it even with the update_all screen off" \
   "$(grep -c 'SELF_UPDATE_SCREEN:-yes}" = "yes" \] || menu_frontend_possible' "${ROOT}/tty2oled.sh")" "1"

# ---------------------------------------------------------------------------
section "the firmware's version, asked again when the display was not ready"
# ---------------------------------------------------------------------------
section "Degauss and Zaparoo: frontends over the menu core, found by their process"
# ---------------------------------------------------------------------------
# Degauss is a Scripts entry, not a core: CORENAME says MENU all the while it
# runs. Its binary is the only sign.
degauss_running() { menu_frontend && [ "${MENU_FRONTEND}" = "degauss" ]; }
menu_frontend; ok "nothing running: no frontend" "${?}:${MENU_FRONTEND}" "1:"
mkproc 800 /bin/bash /media/fat/Scripts/degauss.sh
degauss_running; ok "its launcher script alone is not it" "${?}" "1"
mkproc 801 vi /media/fat/Scripts/.config/degauss/degauss.toml
degauss_running; ok "nor an editor open on its config, which names degauss/degauss" "${?}" "1"
mkproc 802 /media/fat/Scripts/.config/degauss/degauss \
  --config /media/fat/Scripts/.config/degauss/degauss.toml \
  --systems /media/fat/Scripts/.config/degauss/systems.toml
degauss_running; ok "its binary, as degauss.sh starts it" "${?}" "0"
rm -rf "${PROC_ROOT}/802"
mkproc 803 /media/fat/Scripts/.degauss/degauss --config /media/fat/Scripts/.degauss/degauss.toml
degauss_running; ok "and where v0.1.0 and v0.2.0 installed it" "${?}" "0"
rm -rf "${PROC_ROOT}/803"

# Zaparoo's frontend is MiSTer's main, swapped in by MiSTer.ini, over its own
# menu core; the main's argv[1] is the rbf it loaded (as seen on a MiSTer).
mkproc 900 /media/fat/zaparoo/zaparoo.d32b564816485bce.sh -service exec
mkproc 901 /media/fat/zaparoo/frontend --crt
menu_frontend; ok "its service and frontend alone are not it" "${?}:${MENU_FRONTEND}" "1:"
mkproc 902 /media/fat/zaparoo/MiSTer_Zaparoo menu.rbf
menu_frontend; ok "nor its main on the stock menu" "${?}:${MENU_FRONTEND}" "1:"
mkproc 902 /media/fat/zaparoo/MiSTer_Zaparoo zaparoo/menu_zaparoo.rbf
menu_frontend; ok "its main on menu_zaparoo.rbf is" "${?}:${MENU_FRONTEND}" "0:zaparoo"
mkproc 902 /media/fat/MiSTer /media/fat/zaparoo/menu_zaparoo.rbf
menu_frontend; ok "whatever the main is called, and by a full path" "${?}:${MENU_FRONTEND}" "0:zaparoo"
mkproc 903 vi /media/fat/zaparoo/menu_zaparoo.rbf.txt
mkproc 902 /media/fat/zaparoo/MiSTer_Zaparoo _Console/SNES_20250605.rbf
menu_frontend; ok "a core it loaded is not, nor anything else naming the rbf" "${?}:${MENU_FRONTEND}" "1:"
mkproc 902 /media/fat/zaparoo/MiSTer_Zaparoo zaparoo/menu_zaparoo.rbf
mkproc 802 /media/fat/Scripts/.config/degauss/degauss --config x
menu_frontend; ok "Degauss over Zaparoo is Degauss" "${?}:${MENU_FRONTEND}" "0:degauss"
rm -rf "${PROC_ROOT}/802"

# The display's idea of the core: a frontend replaces MENU and nothing else.
printf 'MENU' > "${corenamefile}"
readcore; ok "the menu, Zaparoo up: zaparoo" "${CURCORE}" "zaparoo"

# ScummVM started by Zaparoo itself, not its Scripts launcher: the binary with
# the game as its last argument (as seen on a MiSTer), and CORENAME left MENU.
mkproc 910 /bin/bash /media/fat/Scripts/ScummVM_Master.sh
readcore; ok "ScummVM's launcher script alone is not ScummVM" "${CURCORE}" "zaparoo"
mkproc 911 /media/fat/ScummVM/scummvmmaster --opl-driver=db --output-rate=48000 lure
readcore; ok "its binary over Zaparoo's menu core is ScummVM" "${CURCORE}" "ScummVM"
mkproc 802 /media/fat/Scripts/.config/degauss/degauss --config x
readcore; ok "over Degauss too - it has the screen" "${CURCORE}" "ScummVM"
rm -rf "${PROC_ROOT}/802"
SVM_PID="911"; rm -rf "${PROC_ROOT}/910"
readcore; ok "found once, followed by its pid" "${CURCORE}" "ScummVM"
rm -rf "${PROC_ROOT}/911"
readcore; ok "gone: the frontend it came from" "${CURCORE}" "zaparoo"
SVM_PID=""
printf 'ScummVM' > "${corenamefile}"
readcore; ok "started from Scripts, CORENAME says so as before" "${CURCORE}" "ScummVM"
printf 'MENU' > "${corenamefile}"
rm -rf "${PROC_ROOT}/900" "${PROC_ROOT}/901" "${PROC_ROOT}/902" "${PROC_ROOT}/903"
readcore; ok "the menu, nothing running: MENU" "${CURCORE}" "MENU"
mkproc 802 /media/fat/Scripts/.config/degauss/degauss --config x
readcore; ok "the menu with Degauss running: degauss" "${CURCORE}" "degauss"
printf 'SNES' > "${corenamefile}"
readcore; ok "a game it launched is that game's core" "${CURCORE}" "SNES"
printf 'MENU' > "${corenamefile}"

# Starting or leaving Degauss changes no state file, so the waits must time
# out to see it - while the menu core is up in any guise, and not in a core.
oldcore="MENU"; menu_frontend_possible; ok "on the menu, the wait polls for it" "${?}" "0"
oldcore="degauss"; menu_frontend_possible; ok "and while it runs, for it leaving" "${?}" "0"
oldcore="zaparoo"; menu_frontend_possible; ok "and on Zaparoo, which it could run over" "${?}" "0"
oldcore="SNES"; menu_frontend_possible; ok "in a core it does not" "${?}" "1"
rm -rf "${PROC_ROOT}/800" "${PROC_ROOT}/801" "${PROC_ROOT}/802"
unset -f degauss_running
printf 'NES' > "${corenamefile}"

# ---------------------------------------------------------------------------
section "the port under a name of our own, so Zaparoo probes it once"
# ---------------------------------------------------------------------------
# Writing through /dev/ttyUSB0 stamps its time, and Zaparoo re-probes a port
# whose time has changed. A node of our own for the device is written
# instead; the device itself is what says whether the display is there.
FAKEMK="${TMP}/fakemknod"; mkdir -p "${FAKEMK}"
printf '#!/bin/sh\necho "$@" >"%s/args"\nexit "${FAKE_MKNOD_RC:-0}"\n' "${FAKEMK}" >"${FAKEMK}/mknod"
chmod +x "${FAKEMK}/mknod"
KEEP="${PATH}"; PATH="${FAKEMK}:${PATH}"
TTYPORT=""; TTYDEV="/dev/null"; TTYALIAS="${TMP}/tty2oledplus.tty"; rm -f "${TTYALIAS}"
ttyalias
ok "made for the device's own numbers" "$(cat "${FAKEMK}/args")" "${TTYALIAS} c 1 3"
ok "and the port remembered" "${TTYPORT}" "/dev/null"
ok "a node that is not there after all is not written to" "${TTYDEV}" "/dev/null"
: >"${TTYALIAS}"
ttyalias
ok "nor is a file in its place" "${TTYDEV}" "/dev/null"
rm -f "${TTYALIAS}"; FAKE_MKNOD_RC=1 ttyalias
ok "no node made: the device, as always" "${TTYDEV}" "/dev/null"
PATH="${KEEP}"
TTYGONE="no"; TTYPORT="${TMP}/no-such-port"; TTYDEV="/dev/null"
serialready; ok "gone is the device gone, whatever our node says" "${?}:${TTYGONE}" "1:yes"
TTYPORT=""; TTYGONE="no"
# Whether ours opens, asked the way stty opens a port. At boot a plain open
# failed in the second Zaparoo's first probe had the port, and the daemon
# wrote through /dev/ttyUSB0 from then on. Stand-ins for rm, mknod and stty,
# with /dev/null as the device and /dev/zero as our "node" - never as root,
# where a stand-in not taking would mean a real rm.
if [ "$(id -u)" != "0" ]; then
  FAKEN="${TMP}/fakenode"; mkdir -p "${FAKEN}"
  printf '#!/bin/sh\nexit 0\n' >"${FAKEN}/rm"
  printf '#!/bin/sh\nexit 0\n' >"${FAKEN}/mknod"
  printf '#!/bin/sh\necho "$2" >>"%s/opens"\ncase " ${FAKE_STTY_OK:-} " in *" $2 "*) exit 0 ;; esac\nexit 1\n' "${FAKEN}" >"${FAKEN}/stty"
  chmod +x "${FAKEN}"/*
  KEEP="${PATH}"; PATH="${FAKEN}:${PATH}"; KEEPALIAS="${TTYALIAS:-}"; TTYALIAS="/dev/zero"
  FAKE_STTY_OK="/dev/zero" ttynode /dev/null
  ok "ours opens: ours" "${TTYNODE}" "/dev/zero"
  : >"${FAKEN}/opens"; FAKE_STTY_OK="/dev/null" ttynode /dev/null
  ok "ours will not, the device does (a nodev mount): the device" "${TTYNODE}" "/dev/null"
  ok "and it says why" "${TTYNODE_WHY}" "/dev/zero would not open, /dev/null did"
  ok "after a few tries at ours" "$(grep -c zero "${FAKEN}/opens")" "5"
  FAKE_STTY_OK="" ttynode /dev/null
  ok "neither opens - the port busy this instant: ours all the same" "${TTYNODE}" "/dev/zero"
  # Straight after boot mknod fails for a few seconds, then works: tried
  # again rather than given up on, and what it said is kept.
  printf '#!/bin/sh\nn=$(cat "%s/mk" 2>/dev/null || echo 0); echo $((n + 1)) >"%s/mk"\n[ "$n" -ge 2 ] && exit 0\necho "mknod: busy for now" >&2; exit 1\n' \
    "${FAKEN}" "${FAKEN}" >"${FAKEN}/mknod"
  rm -f "${FAKEN}/mk"; TTYALIAS="/dev/zero"
  FAKE_STTY_OK="/dev/zero" ttynode /dev/random
  ok "mknod failing twice at boot: tried again, ours" "${TTYNODE}|$(cat "${FAKEN}/mk")" "/dev/zero|3"
  ok "and what it said is kept" "${TTYNODE_ERR}" "mknod: busy for now"
  PATH="${KEEP}"; TTYALIAS="${KEEPALIAS}"
fi

# Another program writing to the display: the device file's time moves, and
# everything goes out again once it has had a moment to finish.
TTYPORT="${TMP}/port"; TTYDEV="${TMP}/node"; PORT_REF="${TMP}/port.ref"
: >"${TTYPORT}"; : >"${TTYDEV}"; touch -d '-1 minute' "${TTYPORT}"
port_mark
oldcore="SNES"; META_WIRE_LAST="x"
port_pass; ok "nothing else wrote: nothing" "${oldcore}|${PORT_DIRTY_AT}" "SNES|"
touch "${TTYPORT}"
port_pass; ok "someone else did: noted, not redrawn while they may be at it" "${oldcore}" "SNES"
ok "from now" "${PORT_DIRTY_AT}" "${EPOCHSECONDS}"
PORT_DIRTY_AT=$(( EPOCHSECONDS - 3 ))
port_pass; ok "PORT_SETTLE_SECS later: everything again" "${oldcore}|${META_WIRE_LAST}|${NOTE_SENT}" "||?"
oldcore="SNES"
port_pass; ok "once" "${oldcore}" "SNES"
# Writing through the device itself - no node could be made - the device's
# time is ours, and our node is tried for again, once a minute.
eval "keep_ttyalias() $(declare -f ttyalias | tail -n +2)"
ALIASES=0; ttyalias() { ALIASES=$(( ALIASES + 1 )); }
TTYDEV="${TTYPORT}"; PORT_RETRY_AT=0
port_pass; port_pass
ok "through the device: our node tried again, not every pass" "${ALIASES}" "1"
ok "every PORT_RETRY_SECS" "$(( PORT_RETRY_AT - EPOCHSECONDS ))" "10"
ok "and our own writes are not someone else's" "${oldcore}" "SNES"
eval "ttyalias() $(declare -f keep_ttyalias | tail -n +2)"; unset -f keep_ttyalias
TTYPORT=""; TTYDEV="/dev/null"; PORT_DIRTY_AT=""; PORT_RETRY_AT=0
ok "sleep mode's own redraw takes the time SAM's writes left" \
   "$(sed -n '/^sleepmode_pass()/,/^}/p' "${ROOT}/tty2oled.sh" | grep -c 'port_mark')" "1"

# One ttynode, in tty2oled-port.sh, which everything that writes to the
# display sources - three copies of it were kept in step by this suite.
ok "ttynode is defined in tty2oled-port.sh alone" \
   "$(grep -l '^ttynode() {' "${ROOT}"/tty2oled.sh "${ROOT}"/S60tty2oled "${ROOT}"/tools/*.sh | sed "s|${ROOT}/||" | tr '\n' ' ')" \
   "tools/tty2oled-port.sh "
for f in tty2oled.sh S60tty2oled tools/flash-mister.sh tools/tty2oledplus_update.sh tools/tty2oled-bootimg.sh; do
  ok "${f##*/} sources it" "$(grep -c '\. .*tty2oled-port\.sh' "${ROOT}/${f}")" "1"
done
ok "it is shipped" "$(. "${ROOT}/tools/manifest.sh"; case " ${MANIFEST_TOOLS//$'\n'/ } " in *" tools/tty2oled-port.sh "*) echo yes ;; esac)" "yes"

# ---------------------------------------------------------------------------
section "which port: the display remembered by its USB identity"
# ---------------------------------------------------------------------------
# /sys as on the MiSTer: the display a CP2102 on 1-1.2.4, and a reader's
# CH340 - no serial - plugged in beside it. Linux numbers them as they turn
# up, so the display is not always ttyUSB0.
SYS_ROOT="${TMP}/sys"
mksys() {  # mksys <tty> <usb path> <vid> <pid> [serial]
  local dev="${SYS_ROOT}/devices/platform/soc/ffb40000.usb/usb1/1-1/${2}"
  rm -rf "${dev}" "${SYS_ROOT}/class/tty/${1}"
  mkdir -p "${dev}/${2}:1.0/${1}" "${SYS_ROOT}/class/tty/${1}"
  printf '%s\n' "${3}" >"${dev}/idVendor"; printf '%s\n' "${4}" >"${dev}/idProduct"
  [ -n "${5:-}" ] && printf '%s\n' "${5}" >"${dev}/serial"
  printf '00\n' >"${dev}/${2}:1.0/bInterfaceNumber"
  ln -s "${dev}/${2}:1.0/${1}" "${SYS_ROOT}/class/tty/${1}/device"
}
rm -rf "${SYS_ROOT}"; rm -f "${PORT_ID_FILE}"
mksys ttyUSB0 1-1.2.4 10c4 ea60 0001
mksys ttyUSB1 1-1.2.3 1a86 7523
port_id /dev/ttyUSB0; ok "a port's identity, from /sys" "${PORT_ID}" "10c4:ea60:0001:1-1.2.4:00"
port_id ttyUSB1; ok "a CH340 has no serial" "${PORT_ID}" "1a86:7523::1-1.2.3:00"
port_id /dev/ttyS0; ok "a port not on USB has none" "${?}:${PORT_ID}" "1:"

TTYDEV="/dev/ttyUSB0"; port_resolve
ok "nothing remembered: TTYDEV as the ini has it" "${TTYDEV}" "/dev/ttyUSB0"
port_remember /dev/ttyUSB0
ok "the display answered on ttyUSB0: remembered" "$(cat "${PORT_ID_FILE}")" "10c4:ea60:0001:1-1.2.4:00"
T0="$(stat -c %Y "${PORT_ID_FILE}")"; touch -d '-1 hour' "${PORT_ID_FILE}"
port_remember /dev/ttyUSB0
ok "and not written again when nothing changed" "$(( $(stat -c %Y "${PORT_ID_FILE}") < T0 ))" "1"

# Next boot the reader turns up first.
mksys ttyUSB0 1-1.2.3 1a86 7523
mksys ttyUSB1 1-1.2.4 10c4 ea60 0001
TTYDEV="/dev/ttyUSB0"; port_resolve
ok "renumbered: the display found on ttyUSB1" "${TTYDEV}" "/dev/ttyUSB1"
TTYDEV="/dev/serial/by-id/usb-Silicon_Labs_CP2102-if00-port0"; port_resolve
ok "a by-id link set by hand is taken as it is" "${TTYDEV}" "/dev/serial/by-id/usb-Silicon_Labs_CP2102-if00-port0"

# Moved to another socket: the serial says which.
mksys ttyUSB1 1-1.2.1 10c4 ea60 0001
TTYDEV="/dev/ttyUSB0"; port_resolve
ok "moved to another socket: found by its serial" "${TTYDEV}" "/dev/ttyUSB1"
# Two CP2102s with the serial they all have: the socket decides.
mksys ttyUSB0 1-1.2.3 10c4 ea60 0001
mksys ttyUSB1 1-1.2.4 10c4 ea60 0001
TTYDEV="/dev/ttyUSB0"; port_resolve
ok "two of one make: the one in the remembered socket" "${TTYDEV}" "/dev/ttyUSB1"
mksys ttyUSB1 1-1.2.1 10c4 ea60 0001
TTYDEV="/dev/ttyUSB0"; port_resolve
ok "neither in it: no guess, TTYDEV as it was" "${TTYDEV}" "/dev/ttyUSB0"
# Another make of board: nothing matches, and the ini's port is used; when
# it answers, it is what is remembered.
rm -rf "${SYS_ROOT}"; mksys ttyUSB0 1-1.2.4 1a86 55d4 5A7C
TTYDEV="/dev/ttyUSB0"; port_resolve
ok "a display on another make of adapter: the ini's port" "${TTYDEV}" "/dev/ttyUSB0"
port_remember /dev/ttyUSB0
ok "remembered once it answers" "$(cat "${PORT_ID_FILE}")" "1a86:55d4:5A7C:1-1.2.4:00"
# The ESP32-S3's own USB: ttyACM, the interface one level up.
rm -rf "${SYS_ROOT}"; mkdir -p "${SYS_ROOT}/devices/usb1/1-1/1-1:1.0" "${SYS_ROOT}/class/tty/ttyACM0"
printf '303a\n' >"${SYS_ROOT}/devices/usb1/1-1/idVendor"; printf '1001\n' >"${SYS_ROOT}/devices/usb1/1-1/idProduct"
printf '00\n' >"${SYS_ROOT}/devices/usb1/1-1/1-1:1.0/bInterfaceNumber"
ln -s "${SYS_ROOT}/devices/usb1/1-1/1-1:1.0" "${SYS_ROOT}/class/tty/ttyACM0/device"
port_id ttyACM0; ok "an S3's ttyACM" "${PORT_ID}" "303a:1001::1-1:00"

# The daemon: gone from its port, and back on another after a replug.
rm -rf "${SYS_ROOT}"; mksys ttyUSB0 1-1.2.4 10c4 ea60 0001; port_remember /dev/ttyUSB0
TTYCONF="/dev/ttyUSB0"; TTYPORT="${TMP}/gone"; TTYGONE="no"
port_moved; ok "nowhere else: not moved" "${?}" "1"
ok "only a numbered port in the ini is looked for" "$(TTYCONF=/dev/serial/by-id/x; port_moved; echo $?)" "1"
TTYCONF=""; TTYPORT=""; rm -rf "${SYS_ROOT}"; rm -f "${PORT_ID_FILE}"; unset SYS_ROOT

TTYDEV="/dev/null"; unset PROC_ROOT

# ---------------------------------------------------------------------------
section "updates waiting: tty2oled+ and the system, looked for in the background"
# ---------------------------------------------------------------------------
# GitHub is a fake curl on PATH: it answers FAKE_LATEST (or fails with
# FAKE_CURL_RC) after FAKE_CURL_SLEEP seconds. The system check is a fake
# tty2oledplus_syscheck.py saying FAKE_SC. Both log each run.
FAKEBIN="${TMP}/fakebin"; mkdir -p "${FAKEBIN}"
cat >"${FAKEBIN}/curl" <<'FAKE'
#!/bin/bash
echo "curl $*" >>"${FAKE_CURL_LOG}"
sleep "${FAKE_CURL_SLEEP:-0}"
[ "${FAKE_CURL_RC:-0}" = "0" ] || exit "${FAKE_CURL_RC}"
printf '%s\n' "${FAKE_LATEST}"
FAKE
chmod +x "${FAKEBIN}/curl"
SYSCHECK="${TMP}/fake-syscheck.py"
cat >"${SYSCHECK}" <<'FAKE'
import os, sys, time
with open(os.environ["FAKE_SC_LOG"], "a") as f:
    f.write("syscheck " + " ".join(sys.argv[1:]) + "\n")
time.sleep(float(os.environ.get("FAKE_SC_SLEEP", "0")))
print(os.environ.get("FAKE_SC", "no"))
FAKE
export FAKE_CURL_LOG="${TMP}/curl.log" FAKE_LATEST="" FAKE_CURL_RC=0 FAKE_CURL_SLEEP=0
export FAKE_SC_LOG="${TMP}/sc.log" FAKE_SC="no" FAKE_SC_SLEEP=0
KEEP_PATH="${PATH}"; PATH="${FAKEBIN}:${PATH}"
PROC_ROOT="${TMP}/proc-uc"; rm -rf "${PROC_ROOT}"; mkdir -p "${PROC_ROOT}"
UPDATE_FLAG="${TMP}/update-flag"; rm -f "${UPDATE_FLAG}"
UC_OUT="${TMP}/check"; SC_CACHE="${TMP}/etags"
TTY2OLED_VERSION="0.7.1b"; FW_VERSION="0.7.1b"
UPDATE_CHECK_MINUTES="30"; UPDATE_CHECK_TTY2OLED="yes"; UPDATE_CHECK_SYSTEM="yes"
unset UPDATE_NOTE_TEXT UPDATE_NOTE_SYSTEM_TEXT UPDATE_NOTE_BOTH_TEXT
NOTEWIRE="${TMP}/notewire"; TTYDEV="${NOTEWIRE}"
curls() { wc -l <"${FAKE_CURL_LOG}" 2>/dev/null | tr -d ' ' || echo 0; }
scs()   { wc -l <"${FAKE_SC_LOG}" 2>/dev/null | tr -d ' ' || echo 0; }
wire()  { tr '\n' '|' <"${NOTEWIRE}" 2>/dev/null; }
settle() {  # the background checks that are running, finished
  local i n
  for i in $(seq 50); do
    n=0
    for j in uc sc; do bg_running "${j}" && ! [ -e "${UC_OUT}.${j}.rc" ] && n=1; done
    [ "${n}" -eq 0 ] && return
    sleep 0.1
  done
}
fresh() { : >"${FAKE_CURL_LOG}"; : >"${FAKE_SC_LOG}"; : >"${NOTEWIRE}"; }
yesno_e() { [ -e "${1}" ] && echo yes || echo no; }
reset_checks() {
  settle
  local j
  for j in uc sc; do
    [ -n "${BG_PID[${j}]:-}" ] && { kill "${BG_PID[${j}]}" 2>/dev/null; wait "${BG_PID[${j}]}" 2>/dev/null; }
    BG_PID[${j}]=""
  done
  rm -f "${UC_OUT}".*
  UC_NEXT=""; SC_NEXT=""; SC_FLAGGED=""; SC_UA="no"; NOTE_SENT="?"
  rm -f "${UPDATE_FLAG}"; FAKE_LATEST="0.7.1b"; FAKE_SC="no"; fresh
}
nowish() { date +%s; }

for pair in "0.7.2b 0.7.1b yes" "0.7.10b 0.7.9b yes" "0.8.0b 0.7.99b yes" "1.0.0 0.9.9b yes" \
            "0.7.1 0.7.1b yes" "0.7.1b 0.7.1b no" "0.7.1b 0.7.1 no" "0.7.0b 0.7.1b no" \
            "garbage 0.7.1b no" " 0.7.1b no" "0.7.2b unknown no"; do
  set -- ${pair}
  [ $# -eq 2 ] && set -- "" "$1" "$2"
  version_newer "$1" "$2" && r=yes || r=no
  ok "release '$1' newer than '$2': $3" "${r}" "$3"
done

reset_checks; FAKE_LATEST="0.7.2b"
updatenote_pass
ok "the first pass - boot - asks GitHub" "$(curls)" "1"
ok "at the release's VERSION" "$(grep -c 'releases/latest/download/VERSION' "${FAKE_CURL_LOG}")" "1"
settle
ok "and runs the system check, niced, with its ETag cache" "$(cat "${FAKE_SC_LOG}")" "syscheck --cache ${SC_CACHE}"
ok "and tells the display nothing is waiting yet" "$(wire)" "CMDNOTE,|"

reset_checks; FAKE_CURL_SLEEP=3; FAKE_SC_SLEEP=3
T0="$(tenths)"; updatenote_pass; T1="$(tenths)"
ok "without waiting for either: a slow network never holds up the display" "$(( T1 - T0 < 10 ))" "1"
kill "${BG_PID[uc]}" "${BG_PID[sc]}" 2>/dev/null; FAKE_CURL_SLEEP=0; FAKE_SC_SLEEP=0
reset_checks

section "updates waiting: a newer tty2oled+"
reset_checks; FAKE_LATEST="0.7.2b"
updatenote_pass; settle; : >"${NOTEWIRE}"; updatenote_pass
ok "a newer release is flagged when the check comes back" "$(cat "${UPDATE_FLAG}" 2>/dev/null)" "0.7.2b"
ok "and the display told, in the same pass" "$(wire)" "CMDNOTE,TTY2OLED+ Update Available|"
UC_NEXT=0; SC_NEXT=$(( $(nowish) + 999 )); fresh
for i in 1 2 3; do updatenote_pass; done
ok "flagged, it stops asking, however long it has been" "$(curls)" "0"
ok "and says nothing more" "$(wire)" ""

# The updater installed it: the flag goes, and the next check - due at once
# here, as it is when the daemon it restarts first runs - finds nothing newer.
rm -f "${UPDATE_FLAG}"; FAKE_LATEST="0.7.1b"; UC_NEXT=0; fresh
updatenote_pass; settle; updatenote_pass
ok "once installed, it asks again" "$(curls)" "1"
ok "finds nothing newer, flags nothing" "$(yesno_e "${UPDATE_FLAG}")" "no"
ok "and the notice goes" "$(wire)" "CMDNOTE,|"
ok "the next check is an interval away" "$(( UC_NEXT - $(nowish) > 29 * 60 ))" "1"

printf '0.7.1b\n' >"${UPDATE_FLAG}"; UC_NEXT=$(( $(nowish) + 999 )); fresh
updatenote_pass
ok "a flag that is not newer than this is dropped" "$(yesno_e "${UPDATE_FLAG}")" "no"
ok "and shown nowhere" "$(wire)" ""

reset_checks; FAKE_CURL_RC=6; SC_NEXT=$(( $(nowish) + 999 ))
updatenote_pass; settle; updatenote_pass
ok "offline: nothing flagged" "$(yesno_e "${UPDATE_FLAG}")" "no"
left=$(( UC_NEXT - $(nowish) ))
ok "and tried again in five minutes" "$(( left >= UC_RETRY_SECS - 1 && left <= UC_RETRY_SECS ))" "1"
FAKE_CURL_RC=0

reset_checks; FAKE_CURL_SLEEP=30; SC_NEXT=$(( $(nowish) + 999 ))
updatenote_pass; STUCK="${BG_PID[uc]}"
BG_STARTED[uc]=$(( $(nowish) - BG_GIVEUP_uc - 1 ))
updatenote_pass
ok "a check stuck past its limit is stopped" "$(kill -0 "${STUCK}" 2>/dev/null && echo alive || echo gone)" "gone"
left=$(( UC_NEXT - $(nowish) ))
ok "and retried like a failure" "$(( left >= UC_RETRY_SECS - 1 && left <= UC_RETRY_SECS ))" "1"
FAKE_CURL_SLEEP=0

section "updates waiting: the system"
reset_checks; FAKE_SC="yes distribution_mister: _Console/NES_20260928.rbf"
UC_NEXT=$(( $(nowish) + 999 ))
updatenote_pass; settle; : >"${NOTEWIRE}"; updatenote_pass
ok "something update_all would update is flagged" "${SC_FLAGGED}" "distribution_mister: _Console/NES_20260928.rbf"
ok "and the display told" "$(wire)" "CMDNOTE,System Update Available|"
SC_NEXT=0; fresh
for i in 1 2 3; do updatenote_pass; done
ok "flagged, it stops looking, however long it has been" "$(scs)" "0"

printf '0.7.2b\n' >"${UPDATE_FLAG}"; fresh
updatenote_pass
ok "with a tty2oled+ release as well, both" "$(wire)" "CMDNOTE,TTY2OLED+ & System Update Available|"
rm -f "${UPDATE_FLAG}"; fresh; updatenote_pass
ok "and back to the system's alone" "$(wire)" "CMDNOTE,System Update Available|"

# update_all runs: nothing is looked for while it does; once it has gone the
# flag goes, and the check runs again at once to see what is left.
mkproc 900 /bin/bash /media/fat/Scripts/update_all.sh
FAKE_SC="no"; fresh
updatenote_pass
ok "update_all running: the flag stays" "${SC_FLAGGED:+set}" "set"
ok "and nothing is started" "$(scs)" "0"
rm -rf "${PROC_ROOT}/900"
updatenote_pass
ok "update_all gone: the flag goes" "${SC_FLAGGED}" ""
ok "the notice with it, before any check has said so" "$(wire)" "CMDNOTE,|"
settle
ok "and it looks again at once" "$(scs)" "1"
updatenote_pass
ok "which finds nothing left" "${SC_FLAGGED}" ""

# One that was running when update_all started says what was true before it.
reset_checks; UC_NEXT=$(( $(nowish) + 999 )); FAKE_SC="yes stale: from before"; FAKE_SC_SLEEP=1
updatenote_pass
mkproc 901 python3 /tmp/update_all.pyz
updatenote_pass; settle; sleep 1.2; updatenote_pass
ok "a check that overlapped update_all is thrown away" "${SC_FLAGGED}" ""
rm -rf "${PROC_ROOT}/901"; FAKE_SC_SLEEP=0; FAKE_SC="no"
updatenote_pass; settle; updatenote_pass
ok "and a new one runs once it has gone" "${SC_FLAGGED}" ""

UPDATE_ALL_SCREEN="no"
reset_checks; UC_NEXT=$(( $(nowish) + 999 )); SC_FLAGGED="x: y"
mkproc 902 /bin/bash /media/fat/Scripts/update_all.sh; updatenote_pass
rm -rf "${PROC_ROOT}/902"; updatenote_pass
ok "update_all is seen whatever UPDATE_ALL_SCREEN says" "${SC_FLAGGED}" ""
unset UPDATE_ALL_SCREEN

reset_checks; UC_NEXT=$(( $(nowish) + 999 )); FAKE_SC="nostate"
updatenote_pass; settle; updatenote_pass
ok "update_all never ran: nothing flagged" "${SC_FLAGGED}" ""
ok "looked at again an interval later" "$(( SC_NEXT - $(nowish) > 29 * 60 ))" "1"
reset_checks; UC_NEXT=$(( $(nowish) + 999 )); FAKE_SC="error none of 65 databases could be reached"
updatenote_pass; settle; updatenote_pass
left=$(( SC_NEXT - $(nowish) ))
ok "offline: tried again in five minutes" "$(( left >= UC_RETRY_SECS - 1 && left <= UC_RETRY_SECS ))" "1"

section "updates waiting: the switches and the words"
reset_checks; FAKE_LATEST="0.7.2b"; FAKE_SC="yes a: b"
UPDATE_CHECK_TTY2OLED="no"; UPDATE_CHECK_SYSTEM="no"
updatenote_pass; settle
ok "both off: GitHub is not asked" "$(curls)" "0"
ok "nor the system checked" "$(scs)" "0"
printf '0.7.2b\n' >"${UPDATE_FLAG}"; SC_FLAGGED="a: b"; : >"${NOTEWIRE}"; NOTE_SENT="?"
updatenote_pass
ok "and neither is said, flagged or not" "$(wire)" "CMDNOTE,|"
UPDATE_CHECK_TTY2OLED="yes"; : >"${NOTEWIRE}"; updatenote_pass
ok "one on: its own words" "$(wire)" "CMDNOTE,TTY2OLED+ Update Available|"
UPDATE_CHECK_TTY2OLED="no"; UPDATE_CHECK_SYSTEM="yes"; : >"${NOTEWIRE}"; updatenote_pass
ok "the other on: its own" "$(wire)" "CMDNOTE,System Update Available|"
UPDATE_CHECK_TTY2OLED="yes"
UPDATE_CHECK_MINUTES="0"; : >"${NOTEWIRE}"; fresh; SC_NEXT=""; UC_NEXT=""
updatenote_pass
ok "UPDATE_CHECK_MINUTES=0: nothing asked" "$(curls)$(scs)" "00"
ok "and nothing said" "$(wire)" "CMDNOTE,|"
UPDATE_CHECK_MINUTES="30"
UPDATE_NOTE_TEXT="New display software"; UPDATE_NOTE_SYSTEM_TEXT="New cores"
UPDATE_NOTE_BOTH_TEXT="Both, now"
: >"${NOTEWIRE}"; updatenote_pass
ok "UPDATE_NOTE_BOTH_TEXT says both" "$(wire)" "CMDNOTE,Both, now|"
rm -f "${UPDATE_FLAG}"; : >"${NOTEWIRE}"; updatenote_pass
ok "UPDATE_NOTE_SYSTEM_TEXT the system's" "$(wire)" "CMDNOTE,New cores|"
printf '0.7.2b\n' >"${UPDATE_FLAG}"; SC_FLAGGED=""; : >"${NOTEWIRE}"; updatenote_pass
ok "UPDATE_NOTE_TEXT tty2oled+'s" "$(wire)" "CMDNOTE,New display software|"
unset UPDATE_NOTE_TEXT UPDATE_NOTE_SYSTEM_TEXT UPDATE_NOTE_BOTH_TEXT

ok "the shipped ini: both on, every 30 minutes" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${UPDATE_CHECK_TTY2OLED} ${UPDATE_CHECK_SYSTEM} ${UPDATE_CHECK_MINUTES}")" "yes yes 30"
ok "and the three messages" \
   "$(. "${ROOT}/tty2oled-system.ini" 2>/dev/null; echo "${UPDATE_NOTE_TEXT}|${UPDATE_NOTE_SYSTEM_TEXT}|${UPDATE_NOTE_BOTH_TEXT}")" \
   "TTY2OLED+ Update Available|System Update Available|TTY2OLED+ & System Update Available"

# The loop runs it on every pass that owns the port, and the upstream path's
# wait polls for it.
ok "the main loop runs it first thing after sleep mode" \
   "$(grep -A4 'if ! sleepmode_pass; then' "${ROOT}/tty2oled.sh" | grep -c '^ *updatenote_pass$')" "1"
ok "and the upstream path's wait on every timeout" \
   "$(grep -A2 '\[ "\$?" -eq 2 \] || break' "${ROOT}/tty2oled.sh" | grep -c '^ *updatenote_pass$')" "1"
ok "which times out for it" "$(grep -c '|| update_check_on TTY2OLED || update_check_on SYSTEM; }' "${ROOT}/tty2oled.sh")" "1"
ok "a display that comes back is told again" "$(sed -n '/^serialready()/,/^}/p' "${ROOT}/tty2oled.sh" | grep -c 'NOTE_SENT="?"')" "1"
ok "and so is one handed back by sleep mode" "$(sed -n '/^sleepmode_pass()/,/^}/p' "${ROOT}/tty2oled.sh" | grep -c 'NOTE_SENT="?"')" "1"

reset_checks
PATH="${KEEP_PATH}"; TTYDEV="/dev/null"; NOTE_SENT="?"; FW_VERSION=""; unset PROC_ROOT

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
