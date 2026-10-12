#!/bin/bash
#
# MiSTer Hi-Fi: what the display learns about the music, and when.
#
# Everything here was seen on a real MiSTer, v1.12.0 playing Jethro Tull's
# "Songs from the Wood" from a USB drive: the player a process over the menu
# core (CORENAME says MENU), its state one line of JSON from the web remote
# on port 8182 - "Track 03", "Audio CD", "CDDA", the seconds in and long, the
# place in the queue - and the disc's size in /sys/block/sr0/size.
#
# No MiSTer and no disc: a fake /proc (PROC_ROOT) holds the player with the
# real one's command line; its state is a file written here (HIFI_STATE_FILE)
# and, once, a real socket answering as the player does; the disc's lookup is
# a stand-in that answers from here; the clock is the test's.
#
#   ./tests/test-hifi.sh

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/hifi"
rm -rf "${TMP}"; mkdir -p "${TMP}"
TMP="$(cd "${TMP}" && pwd -P)"
TOOL="${ROOT}/tools/tty2oledplus_cd.py"
export PATH="${HERE}/bin:${PATH}"

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

# ---------------------------------------------------------------------------
# A MiSTer in a fake /proc: the physical disc Main over the menu, the
# player's launcher script, and - when it runs - the player itself, with its
# config.json beside the binary.
# ---------------------------------------------------------------------------
PROC_ROOT="${TMP}/proc"
HIFI_HOME="${TMP}/fat/Scripts/.config/MiSTerHiFi"
mkdir -p "${PROC_ROOT}" "${HIFI_HOME}"
proc() {  # proc <pid> <argv...>
  local pid="${1}"; shift
  rm -rf "${PROC_ROOT:?}/${pid}"; mkdir -p "${PROC_ROOT}/${pid}"
  printf '%s\0' "$@" > "${PROC_ROOT}/${pid}/cmdline"
}
gone() { rm -rf "${PROC_ROOT:?}/${1}"; }
proc 9901 /media/fat/MiSTer_Physical-CD menu.rbf
proc 12205 /bin/bash /media/fat/Scripts/misterhifi.sh --physical-cd
player() { proc 12229 "${HIFI_HOME}/mister_hifi" --physical-cd; }
config() {  # config <enabled> <port>
  printf '{\n  "visualizer": "bars",\n  "web_remote_enabled": %s,\n  "web_remote_port": %s,\n  "lastfm": {\n    "enabled": false\n  }\n}\n' \
    "${1}" "${2}" > "${HIFI_HOME}/config.json"
}
config true 8182

# The player's answer, as it gives it: one line, no newline after it.
HIFI_STATE_FILE="${TMP}/state.json"
state() {  # state <state> <title> <position> <duration> <index> <of> [format [artist [album]]]
  printf '{"connected":true,"version":"1.12.0","state":"%s","title":"%s","artist":"%s","album":"%s","format":"%s","position":%s,"duration":%s,"queue_index":%s,"queue_length":%s,"shuffle":false,"loop":false,"loop_mode":"off","volume":100,"muted":false,"has_art":false,"art_key":""}' \
    "${1}" "${2}" "${8:-}" "${9-Audio CD}" "${7:-CDDA}" "${3}" "${4}" "${5}" "${6}" > "${HIFI_STATE_FILE}"
}
cd_state() { state "${1}" "$(printf 'Track %02d' "${2}")" "${3}" "${4}" $(( ${2} - 1 )) 9; }
HIFI_SYS="${TMP}/sys"
mkdir -p "${HIFI_SYS}/sr0" "${HIFI_SYS}/sda"
disc_in() { printf '%s\n' "${1}" > "${HIFI_SYS}/sr0/size"; }
disc_in 750900
printf '15523840\n' > "${HIFI_SYS}/sda/size"

export MISTER_RBFNAME="${TMP}/RBFNAME" MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH" MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT" MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_CORENAME="${TMP}/CORENAME"
export MISTER_INI="${TMP}/MiSTer.ini" CORETYPE_MAP="${TMP}/coretypes"
export NAMES_TXT="${TMP}/names.txt" SCRAPE_DIR="${TMP}/scraped"
printf 'MENU' > "${MISTER_RBFNAME}"; printf 'MENU' > "${MISTER_CORENAME}"
printf 'menu.rbf' > "${MISTER_STARTPATH}"

# The wire: a FIFO with a reader, as test-wire.sh has it.
CAPTURE="${TMP}/tty-capture"; FIFO="${TMP}/tty-fifo"
mkfifo "${FIFO}"; : > "${CAPTURE}"
( while :; do cat "${FIFO}"; done >> "${CAPTURE}" ) 2>/dev/null &
READER_PID=$!
SERVER_PID=""
trap 'kill "${READER_PID}" ${SERVER_PID} 2>/dev/null' EXIT
TTYDEV="${FIFO}"
WAITSECS="0"; CMDWAITSECS="0"
SHOW_METADATA="yes"; METADATA_INTERVAL="12"; TRANSITION="-2"
core_bootscreen_time="0"
debug="false"; debugfile="${TMP}/debuglog"
iconfolder="${TMP}/pics/icon"; bannerfolder="${TMP}/pics/banner"; userbannerfolder="${TMP}/pics/user"
wheelpack="${TMP}/pics/arcade/wheels.bin"; wheelindex="${TMP}/pics/arcade/wheels.idx"
mkdir -p "${bannerfolder}" "${userbannerfolder}" "${iconfolder}"
cp "${ROOT}/pics/icon/dvd.gsc" "${iconfolder}/misterhifi.gsc"
corenamefile="${MISTER_CORENAME}"
dbug() { :; }
# shellcheck source=../tty2oled-meta.sh
. "${ROOT}/tty2oled-meta.sh"
eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"
HIFI_CACHE="${TMP}/cache/cd"
UC_OUT="${TMP}/check"
FW_VERSION="0.8.9b"
UPDATE_ALL_POLL=2

# The test's clock, and a nap that moves it on.
MS=1000000
now_ms() { NOW_MS="${MS}"; }
NAPPED=0
nap() { [ "${1}" = 0 ] && return 0; MS=$(( MS + ${1%%.*} * 1000 )); NAPPED=$(( NAPPED + 1 )); }
later() { MS=$(( MS + ${1} )); }

wire() { sleep 0.25; LC_ALL=C grep -a -o -E '(CMD[A-Z]+[^[:cntrl:]]*|^MiSTerHiFi|^MENU)' "${CAPTURE}" | tr '\n' ' '; : > "${CAPTURE}"; }
fields() { local IFS='|'; printf '%s' "${META_FIELDS[*]//$'\t'/=}"; }

# The tool as the daemon runs it: nice is a stand-in that runs it as it is,
# and the disc's lookup answers from here, logging what it was asked.
STUB="${TMP}/bin"; mkdir -p "${STUB}"
printf '#!/bin/sh\nshift 2; exec "$@"\n' > "${STUB}/nice"; chmod +x "${STUB}/nice"
ASKED="${TMP}/asked"; : > "${ASKED}"
ANSWER="${TMP}/answer"; echo known > "${ANSWER}"
DISC_ID="XUf79bcXBBwGktQa0wYAxKvS2Qs-"
cat > "${STUB}/cdtool" <<PYEOF
import os, subprocess, sys
a = sys.argv[1:]
if a and a[0] == "disc":
    with open("${ASKED}", "a") as f:
        f.write(" ".join(a) + "\\n")
    how = open("${ANSWER}").read().strip()
    cache, db = a[a.index("--cache") + 1], a[a.index("--db") + 1]
    if how == "down":
        print("no answer: network is unreachable"); sys.exit(1)
    if how == "unknown" or "--no-lookup" in a:
        print("${DISC_ID}|9||"); sys.exit(3)
    did = "${DISC_ID}" if how == "known" else "anotherDiscAltogether000000-"
    os.makedirs(cache, exist_ok=True); os.makedirs(os.path.dirname(db), exist_ok=True)
    path = os.path.join(cache, did + ".cd")
    with open(path, "w") as f:
        if how == "known":
            f.write("tty2oledplus-cd 1\\nSongs From the Wood|\\nJack-in-the-Green|\\nCup of Wonder|\\nHunting Girl|\\n"
                    "Ring Out, Solstice Bells|\\nVelvet Green|\\nThe Whistler|Somebody Else\\nPibroch (Cap in Hand)|\\nFire at Midnight|\\n")
        else:
            f.write("tty2oledplus-cd 1\\n" + "".join("Other %d|\\n" % i for i in range(1, 13)))
    with open(db, "a") as f:
        if how == "known":
            f.write(did + "||ok|Songs From the Wood|1977|||Folk rock||Chrysalis|Jethro Tull|The tenth album.\\n")
        else:
            f.write(did + "||ok|Another Record|1980|||||A Label|Someone|\\n")
    print("%s|%d|%s|%s" % (did, 9 if how == "known" else 12, path, "Songs From the Wood" if how == "known" else "Another Record"))
    sys.exit(0)
sys.exit(subprocess.call([sys.executable, "${TOOL}"] + a))
PYEOF
HIFI_TOOL="${STUB}/cdtool"
PATH="${STUB}:${PATH}"
jobs_done() {   # run the job until it is collected
  local i
  hifi_jobs
  for i in $(seq 1 100); do
    bg_running hfd || return 0
    sleep 0.1; hifi_jobs
  done
}

# ---------------------------------------------------------------------------
section "finding the player: its binary, over the menu"
# ---------------------------------------------------------------------------
oldcore="MENU"
menu_frontend
ok "the launcher script and the disc Main are not it" "${MENU_FRONTEND}" ""
player
menu_frontend
ok "the binary is: a core of its own" "${MENU_FRONTEND}" "MiSTerHiFi"
readcore
ok "CORENAME says MENU, the display's core is the player" "${CURCORE}" "MiSTerHiFi"
proc 1254 /media/fat/MiSTer /media/fat/zaparoo/menu_zaparoo.rbf
menu_frontend
ok "over Zaparoo's menu, which it draws over" "${MENU_FRONTEND}" "MiSTerHiFi"
gone 12229
proc 13000 "${HIFI_HOME}/mister_hifi" --send next
menu_frontend
ok "the same binary passing a command on is not the player" "${MENU_FRONTEND}" "zaparoo"
gone 13000; gone 1254
player
HIFI_SCREEN="no"; menu_frontend
ok "HIFI_SCREEN=no: the menu as before" "${MENU_FRONTEND}" ""
HIFI_SCREEN="yes"
SHOW_METADATA="no"; menu_frontend
ok "nor with the layouts off" "${MENU_FRONTEND}" ""
SHOW_METADATA="yes"
hifi_find
ok "its pid and binary kept" "${HIFI_PID}:${HIFI_BIN##*/}" "12229:mister_hifi"
GREPLOG="${TMP}/grep-log"; printf '#!/bin/sh\necho grep >>"%s"\nexec %s "$@"\n' "${GREPLOG}" "$(command -v grep)" > "${STUB}/grep"
chmod +x "${STUB}/grep"; : > "${GREPLOG}"
hifi_find; menu_frontend; menu_frontend
ok "found once: after that a read, no sweep of /proc" "${MENU_FRONTEND}:$(wc -l < "${GREPLOG}")" "MiSTerHiFi:0"
rm -f "${STUB}/grep"

# ---------------------------------------------------------------------------
section "its remote: where it listens, and whether"
# ---------------------------------------------------------------------------
HIFI_CONF_SEEN=""; hifi_port
ok "the port from its config.json" "${HIFI_PORT}" "8182"
config true 9000; HIFI_CONF_SEEN=""; hifi_port
ok "another port" "${HIFI_PORT}" "9000"
hifi_port
config true 9001; hifi_port
ok "read once, not every look" "${HIFI_PORT}" "9000"
config false 8182; HIFI_CONF_SEEN=""; hifi_port
ok "switched off: none" "${HIFI_PORT}" ""
rm -f "${HIFI_HOME}/config.json"; HIFI_CONF_SEEN=""; hifi_port
ok "no config: its default" "${HIFI_PORT}" "8182"
config true 8182

# ---------------------------------------------------------------------------
section "its state: one line of JSON, read without a process"
# ---------------------------------------------------------------------------
cd_state playing 3 80.62 274.226666666
hifi_look
ok "the real answer: state, title, format" "${HF_STATE}|${HF_TITLE}|${HF_FORMAT}|${HF_ALBUM}|${HF_ARTIST}" \
   "playing|Track 03|CDDA|Audio CD|"
ok "seconds in, whole; seconds long, rounded" "${HF_POS}:${HF_DUR}" "80:274"
ok "the disc's own track number, of the queue's" "${HF_TRACK}/${HF_QN}" "3/9"
ok "playing something" "${HF_IDLE}" "no"
ok "which disc: the drive's size and the track count" "${HIFI_DISC_SIG}|${HIFI_DEV}" "sr0:750900 9|/dev/sr0"
state playing 'Track 07' 1 200 2 9
hifi_look
ok "shuffled: the title's number, not the queue's place" "${HF_TRACK}" "7"
state playing 'Say \"Hi\" \\ AC\/DC & Co\nTwo' 12.96 100.5 0 3 FLAC 'A \"B\"' 'C'
hifi_look
ok "a string unescaped: quotes, a backslash, a slash, an ampersand, a newline" "${HF_TITLE}" 'Say "Hi" \ AC/DC & Co Two'
ok "the next string after one with quotes in it" "${HF_ARTIST}|${HF_ALBUM}|${HF_FORMAT}" 'A "B"|C|FLAC'
ok "a file: its place in the queue" "${HF_TRACK}/${HF_QN}:${HF_POS}:${HF_DUR}" "1/3:12:101"
ok "not a disc: no disc asked after" "${HIFI_DISC_SIG}" ""
state playing 'a \"position\":999,\"title\":\"x' 5 10 0 1 MP3
hifi_look
ok "a key's name inside a title is the title" "${HF_POS}|${HF_TITLE}" '5|a "position":999,"title":"x'
printf '{"connected":true,"state":"stopped"}' > "${HIFI_STATE_FILE}"
hifi_look
ok "fields left out (another version): nothing playing, nothing broken" \
   "${HF_STATE}|${HF_TITLE}|${HF_POS}|${HF_DUR}|${HF_TRACK}|${HF_IDLE}" "stopped||0|0|0|yes"
printf 'not json at all' > "${HIFI_STATE_FILE}"
hifi_look; rc=$?
ok "an answer that is no state: still read, nothing playing" "${rc}:${HF_IDLE}" "0:yes"
: > "${HIFI_STATE_FILE}"
hifi_look; rc=$?
ok "no answer: the look fails" "${rc}" "1"

# The socket itself: a server that answers as the player does.
PORTFILE="${TMP}/port"
cd_state playing 3 80.62 274.226666666
python3 - "${PORTFILE}" "${HIFI_STATE_FILE}" <<'PYEOF' &
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1]))
import os; os.replace(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    c, _ = s.accept()
    req = b""
    while b"\r\n\r\n" not in req:      # bash writes the request a line at a time
        more = c.recv(4096)
        if not more:
            break
        req += more
    body = open(sys.argv[2], "rb").read()
    code = b"200 OK" if req.startswith(b"GET /api/state ") else b"404 Not Found"
    c.sendall(b"HTTP/1.1 " + code + b"\r\nCache-Control: no-store\r\nContent-Type: application/json\r\n"
              b"Content-Length: %d\r\n\r\n" % len(body) + body)
    c.close()
PYEOF
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "${PORTFILE}" ] && break; sleep 0.1; done
SAVED_STATE_FILE="${HIFI_STATE_FILE}"; HIFI_STATE_FILE=""
HIFI_PORT="$(cat "${PORTFILE}")"; HIFI_CONF_SEEN="yes"
hifi_get; rc=$?
ok "asked over /dev/tcp: the body, past the headers, with no newline to end it" \
   "${rc}:${HIFI_JSON:0:44}:${HIFI_JSON: -15}" '0:{"connected":true,"version":"1.12.0","state":e,"art_key":""}'
hifi_look
ok "and parsed" "${HF_TITLE}:${HF_POS}:${HF_TRACK}" "Track 03:80:3"
FDS_BEFORE="$(ls /proc/$$/fd | wc -l)"
for _ in 1 2 3 4 5; do hifi_get; done
ok "its descriptor closed after each look" "$(ls /proc/$$/fd | wc -l)" "${FDS_BEFORE}"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
hifi_get; rc=$?
ok "nobody listening: the look fails, the daemon goes on" "${rc}" "1"
HIFI_PORT=""
hifi_get; rc=$?
ok "the remote switched off: not asked" "${rc}" "1"
HIFI_STATE_FILE="${SAVED_STATE_FILE}"; HIFI_CONF_SEEN=""

# ---------------------------------------------------------------------------
section "the layout: a CD nobody has named yet"
# ---------------------------------------------------------------------------
oldcore="MiSTerHiFi"
cd_state playing 3 80.62 274.226666666
build_meta MiSTerHiFi corechange
ok "music, as a console game" "${META_KIND}:${META_GAME}:${META_SOURCE}" "console:yes:hifi"
ok "titled as the player has it" "${META_TITLE}" "Track 03"
ok "what it is, and no more" "$(fields)" "Format=Audio CD"
ok "the player's icon" "${META_ICON}" "misterhifi"
ok "nothing pinned: the track is above them" "${META_PINNED_COUNT}" "0"

# ---------------------------------------------------------------------------
section "the disc read and looked up, in the background"
# ---------------------------------------------------------------------------
HIFI_LOOKUP="yes"
jobs_done
ok "asked once, of the drive holding the disc" "$(cat "${ASKED}")" \
   "disc --dev /dev/sr0 --cache ${HIFI_CACHE} --db ${SCRAPE_DIR}/CD.txt"
ok "its ID, and its nine titles" "${HIFI_DISC}:$(( ${#HIFI_TRACKS[@]} - 1 ))" "${DISC_ID}:9"
hifi_jobs; hifi_jobs
ok "once a disc" "$(wc -l < "${ASKED}")" "1"
build_meta MiSTerHiFi
ok "the track's own title" "${META_TITLE}" "Cup of Wonder"
ok "Artist Album Year Format" "$(fields)" "Artist=Jethro Tull|Album=Songs From the Wood|Year=1977|Format=Audio CD"
ok "the album's description" "${META_DESC}" "The tenth album."
HIFI_FIELDS="Label Genre nonsense Artist"; HIFI_BUILT=""
build_meta MiSTerHiFi
ok "HIFI_FIELDS picks and orders; unknown names are not rows" "$(fields)" "Label=Chrysalis|Genre=Folk rock|Artist=Jethro Tull"
HIFI_FIELDS="Artist Album Year Format"
cd_state playing 7 0 211.733333
build_meta MiSTerHiFi
ok "a track by someone else on the disc: theirs" "${META_TITLE}:$(fields)" \
   "The Whistler:Artist=Somebody Else|Album=Songs From the Wood|Year=1977|Format=Audio CD"
sed -i 's/|ok|Songs From the Wood|/|ok|Songs from the Wood (remaster)|/' "${SCRAPE_DIR}/CD.txt"
touch -d '+5 seconds' "${SCRAPE_DIR}/CD.txt"
build_meta MiSTerHiFi
ok "corrected by hand in scraped/CD.txt: shown" "$(fields)" \
   "Artist=Somebody Else|Album=Songs from the Wood (remaster)|Year=1977|Format=Audio CD"
SHOW_DESCRIPTION="no"; HIFI_BUILT=""
build_meta MiSTerHiFi
ok "SHOW_DESCRIPTION=no: none" "${META_DESC}" ""
SHOW_DESCRIPTION="yes"

# ---------------------------------------------------------------------------
section "the place in the track"
# ---------------------------------------------------------------------------
: > "${CAPTURE}"; MEDIA_SENT=""
cd_state playing 7 12.5 211.733333
build_meta MiSTerHiFi
hifi_tick; rc=$?
ok "playing: its seconds, its length, which of how many - and the row's name" "${rc}:$(wire)" \
   "0:CMDMEDIA,1,12,212,7,9,Track "
later 1000; cd_state playing 7 13.5 211.733333; hifi_tick
ok "a second on: in step, nothing sent" "$(wire)" ""
later 1000; cd_state paused 7 14.1 211.733333; hifi_tick
ok "paused: said at once" "$(wire)" "CMDMEDIA,2,14,212,7,9,Track "
later 9000; hifi_tick
ok "paused for longer: nothing" "$(wire)" ""
later 1000; cd_state playing 7 14.9 211.733333; hifi_tick
ok "playing again" "$(wire)" "CMDMEDIA,1,14,212,7,9,Track "
later 1000; cd_state playing 7 120.2 211.733333; hifi_tick
ok "a seek: the firmware's count is out, so sent" "$(wire)" "CMDMEDIA,1,120,212,7,9,Track "
later 1000; cd_state stopped 7 0 211.733333; hifi_tick
ok "stopped" "$(wire)" "CMDMEDIA,3,0,212,7,9,Track "
later 1000; cd_state loading 7 0 211.733333; hifi_tick
ok "a state with no name here: as stopped, nothing new" "$(wire)" ""
later 1000; cd_state playing 8 0.4 517.293333; hifi_tick; rc=$?
ok "the next track: a pass is due, and sends it - nothing from the look" "${rc}:$(wire)" "1:"
FW_VERSION="0.8.1b"; MEDIA_SENT=""
build_meta MiSTerHiFi; hifi_tick
ok "firmware before 0.8.2b: never sent, it would be drawn as text" "$(wire)" ""
FW_VERSION="0.8.9b"

# ---------------------------------------------------------------------------
section "a look starts no process"
# ---------------------------------------------------------------------------
FORKLOG="${TMP}/forks"; FORKBIN="${TMP}/forkbin"; mkdir -p "${FORKBIN}"
for c in ls stat cat grep sed awk date sleep head tail tr cut wc python3 readlink curl; do
  real="$(command -v "${c}")" || continue
  printf '#!/bin/sh\necho %s >>"%s"\nexec %s "$@"\n' "${c}" "${FORKLOG}" "${real}" >"${FORKBIN}/${c}"
  chmod +x "${FORKBIN}/${c}"
done
build_meta MiSTerHiFi; hifi_tick; wire >/dev/null
: > "${FORKLOG}"
KEEP="${PATH}"; PATH="${FORKBIN}:${PATH}"
for i in 1 2 3 4 5; do later 1000; cd_state playing 8 "${i}.4" 517.293333; hifi_tick; done
PATH="${KEEP}"
ok "five looks: nothing started" "$(tr '\n' ' ' < "${FORKLOG}")" ""
: > "${FORKLOG}"
later 1000; cd_state paused 8 6.0 517.293333
PATH="${FORKBIN}:${PATH}"; hifi_tick; PATH="${KEEP}"
ok "nor by the look that says a pause" "$(tr '\n' ' ' < "${FORKLOG}")|$(wire)" "|CMDMEDIA,2,6,517,8,9,Track "
: > "${FORKLOG}"
PATH="${FORKBIN}:${PATH}"; build_meta MiSTerHiFi; PATH="${KEEP}"
ok "a pass with the same track builds from what it kept: only the pass's one stat" \
   "$(tr '\n' ' ' < "${FORKLOG}")" "stat "

# ---------------------------------------------------------------------------
section "following between passes"
# ---------------------------------------------------------------------------
cd_state playing 8 7 517.293333
build_meta MiSTerHiFi; hifi_tick; wire >/dev/null
T0="${MS}"; hifi_follow 3
ok "a look a second for the seconds it was given" "$(( (MS - T0) / 1000 ))" "3"
cd_state playing 9 0 147.24
T0="${MS}"; hifi_follow 5
ok "the track changed: back to the loop at once" "$(( MS - T0 ))" "0"
build_meta MiSTerHiFi
printf 'NES' > "${MISTER_CORENAME}"
T0="${MS}"; hifi_follow 5
ok "another core: back to the loop at once" "$(( MS - T0 ))" "0"
printf 'MENU' > "${MISTER_CORENAME}"
: > "${HIFI_STATE_FILE}"
T0="${MS}"; NAPPED=0; hifi_follow 5
ok "the player there but not answering: waited on, not asked in a spin" "$(( (MS - T0) / 1000 )):${NAPPED}" "2:1"
gone 12229
T0="${MS}"; hifi_follow 5
ok "the player gone: back to the loop at once" "$(( MS - T0 ))" "0"
menu_frontend
ok "and the menu is the menu again" "${MENU_FRONTEND}" ""
wire >/dev/null

# ---------------------------------------------------------------------------
section "on the wire: started, a disc played, changed, the player closed"
# ---------------------------------------------------------------------------
hifi_reset; MEDIA_SENT=""; META_WIRE_LAST=""; : > "${ASKED}"; rm -rf "${HIFI_CACHE}" "${SCRAPE_DIR}"
player
printf '{"connected":true,"version":"1.12.0","state":"stopped","title":"","artist":"","album":"","format":"","position":0,"duration":0,"queue_index":0,"queue_length":0}' > "${HIFI_STATE_FILE}"
readcore
senddata "${CURCORE}"; oldcore="${CURCORE}"
ok "the player with nothing chosen: its name, no layout" "$(wire)" "CMDMETAOFF MiSTerHiFi "
refreshmeta MiSTerHiFi
ok "nothing to show yet" "$(wire)" ""

cd_state playing 1 2.2 295.866666666
refreshmeta MiSTerHiFi
ok "a disc started: the place first, then the layout as the player names it, its icon" "$(wire)" \
   "CMDMEDIA,1,2,296,1,9,Track CMDMETA,2,12,0,0,Track 01|Format=Audio CD CMDICON "
jobs_done
later 1000; cd_state playing 1 3.2 295.866666666
refreshmeta MiSTerHiFi
ok "named: the layout again with the track's title, the album's details and description" "$(wire)" \
   "CMDMETA,2,12,0,0,Songs From the Wood|Artist=Jethro Tull|Album=Songs From the Wood|Year=1977|Format=Audio CD CMDDESC,16 CMDICON "
refreshmeta MiSTerHiFi
ok "nothing new: nothing sent" "$(wire)" ""
later 3000; cd_state playing 5 0.3 226.466666
refreshmeta MiSTerHiFi
ok "another track: its place, then its title (commas made spaces)" "$(wire)" \
   "CMDMEDIA,1,0,226,5,9,Track CMDMETA,2,12,0,0,Ring Out  Solstice Bells|Artist=Jethro Tull|Album=Songs From the Wood|Year=1977|Format=Audio CD CMDDESC,16 CMDICON "

# Another disc: twelve tracks, another size.
echo other > "${ANSWER}"; disc_in 612000
later 1000; state playing 'Track 01' 0.5 180 0 12
refreshmeta MiSTerHiFi
ok "another disc: the first one's names are not shown for it" "$(wire)" \
   "CMDMEDIA,1,0,180,1,12,Track CMDMETA,2,12,0,0,Track 01|Format=Audio CD CMDICON "
jobs_done
refreshmeta MiSTerHiFi
ok "then its own" "$(wire)" "CMDMETA,2,12,0,0,Other 1|Artist=Someone|Album=Another Record|Year=1980|Format=Audio CD CMDICON "
ok "each disc asked about once" "$(wc -l < "${ASKED}")" "2"

# A disc nobody answers for is asked about again later; an unknown one is not.
echo down > "${ANSWER}"; disc_in 700000; : > "${ASKED}"
later 1000; state playing 'Track 02' 0.5 180 1 12
refreshmeta MiSTerHiFi; wire >/dev/null
jobs_done; hifi_jobs
ok "no answer: not asked again at once" "$(wc -l < "${ASKED}")" "1"
HIFI_RETRY_AT=1; echo unknown > "${ANSWER}"
jobs_done
ok "but again after a while" "$(wc -l < "${ASKED}")" "2"
ok "a disc MusicBrainz does not know: its ID, no titles" "${HIFI_DISC}:${#HIFI_TRACKS[@]}" "${DISC_ID}:0"
hifi_jobs; hifi_jobs
ok "and that is an answer: not asked again" "$(wc -l < "${ASKED}"):${HIFI_RETRY_AT}" "2:"
HIFI_LOOKUP="no"; disc_in 650000; : > "${ASKED}"
refreshmeta MiSTerHiFi; jobs_done
ok "HIFI_LOOKUP=no: the disc read, nobody asked" "$(sed 's/.* //' "${ASKED}" | tr '\n' ' ')" "--no-lookup "
HIFI_LOOKUP="yes"; wire >/dev/null

# A file, with tags the panel's fonts cannot show as they are.
later 1000
state playing 'Déjà vu' 30 200 4 20 FLAC 'Björk' 'Été'
sed -i 's/D\\u00e9j\\u00e0/D\xc3\xa9j\xc3\xa0/; s/Bj\\u00f6rk/Bj\xc3\xb6rk/' "${HIFI_STATE_FILE}"
: > "${ASKED}"
refreshmeta MiSTerHiFi
ok "a file: its own tags, folded to what the panel has; its place in the queue" "$(wire)" \
   "CMDMEDIA,1,30,200,5,20,Track CMDMETA,2,12,0,0,Deja vu|Artist=Bjork|Album=Ete|Format=FLAC CMDICON "
hifi_jobs
ok "not a disc: nothing looked up" "$(wc -l < "${ASKED}")" "0"
later 1000
state playing 'http stream' 12 0 0 1 MP3 'Some Radio' ''
refreshmeta MiSTerHiFi
ok "a stream: no length, so the band says the state" "$(wire)" \
   "CMDMEDIA,1,12,0,1,1,Track CMDMETA,2,12,0,0,http stream|Artist=Some Radio|Format=MP3 CMDICON "

printf '{"connected":true,"state":"stopped","title":"","queue_length":0}' > "${HIFI_STATE_FILE}"
hifi_tick; rc=$?
ok "back in its browser: a pass is due" "${rc}" "1"
refreshmeta MiSTerHiFi
ok "which puts the player's picture back" "$(wire)" "CMDMETAOFF MiSTerHiFi "
refreshmeta MiSTerHiFi
ok "once" "$(wire)" ""
ok "CMDMETAOFF forgot what the band showed" "${MEDIA_SENT}" ""

gone 12229
readcore
ok "the player closed: the menu" "${CURCORE}" "MENU"

HIFI_SCREEN="no"; player
build_meta MiSTerHiFi corechange
ok "HIFI_SCREEN=no: nothing of it built" "${META_SOURCE}:${META_GAME}" "core:no"
HIFI_SCREEN="yes"

# ---------------------------------------------------------------------------
section "what is shipped"
# ---------------------------------------------------------------------------
ok "the installer carries the disc tool" \
   "$(. "${ROOT}/tools/manifest.sh"; case " ${MANIFEST_FILES//$'\n'/ } ${MANIFEST_TOOLS:-} " in *"tty2oledplus_cd.py"*) echo yes ;; *) echo no ;; esac)" "yes"
ok "the daemon and the tool agree on the track file's mark" \
   "$(grep -c '^CD_MAGIC = "tty2oledplus-cd 1"$' "${TOOL}"):$(grep -c '= "tty2oledplus-cd 1" \]' "${ROOT}/tty2oled-meta.sh")" "1:1"
for k in HIFI_SCREEN HIFI_LOOKUP HIFI_FIELDS HIFI_CACHE; do
  ok "the ini has ${k}" "$(grep -c "^${k}=" "${ROOT}/tty2oled-system.ini")" "1"
done

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
