#!/bin/bash
#
# The DVD core: what the display learns about a film, and when.
#
# Everything here was seen on a real MiSTer playing Queen's "On Fire" disc
# from a USB drive: Main (MiSTer_DVDcss) reading the disc on fd 9, its
# fdinfo's "pos:" moving as it reads, a RAM ring keeping that read a full
# 16384 sectors ahead of the picture, the core's telemetry in
# /tmp/dvd_telem.json while /media/fat/dvd_hil exists - pause, still, menu and
# whether a disc is in - and nothing else written anywhere.
#
# No MiSTer and no disc: a fake /proc (PROC_ROOT) holds a Main with the real
# one's command line and its descriptor on tests/dvdiso.py's image; the
# telemetry is a file written here; the clock is the test's. The ring is made
# small (DVD_LEAD_*), because the image is.
#
#   ./tests/test-dvd.sh

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/dvd"
rm -rf "${TMP}"; mkdir -p "${TMP}"
TMP="$(cd "${TMP}" && pwd -P)"
TOOL="${ROOT}/tools/tty2oledplus_dvd.py"
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

ISO="${TMP}/usb0/DVD/Some Film (2004).iso"
mkdir -p "${ISO%/*}"
python3 "${HERE}/dvdiso.py" "${ISO}"
OTHER="${TMP}/usb0/DVD/Other.iso"
python3 "${HERE}/dvdiso.py" "${OTHER}" "SECOND_DISC"

# ---------------------------------------------------------------------------
# A MiSTer in a fake /proc: Main with the DVD core, a stand-in that is called
# MiSTer but runs no core, and the uptime the telemetry's clock is compared
# against.
# ---------------------------------------------------------------------------
PROC_ROOT="${TMP}/proc"
mkdir -p "${PROC_ROOT}"
UPTIME=38600
printf '%s.42 70000.00\n' "${UPTIME}" > "${PROC_ROOT}/uptime"
main_process() {  # main_process <pid> <disc or "">
  rm -rf "${PROC_ROOT:?}/${1}"; mkdir -p "${PROC_ROOT}/${1}/fd" "${PROC_ROOT}/${1}/fdinfo"
  printf 'MiSTer_DVDcss\n' > "${PROC_ROOT}/${1}/comm"
  printf '/media/fat/MiSTer_DVDcss\0/media/fat/_Other/DVD_20260930.rbf\0' > "${PROC_ROOT}/${1}/cmdline"
  ln -s /dev/null "${PROC_ROOT}/${1}/fd/1"
  ln -s /dev/null "${PROC_ROOT}/${1}/fd/3"
  [ -n "${2}" ] && insert "${1}" "${2}"
}
insert() { ln -sfn "${2}" "${PROC_ROOT}/${1}/fd/9"; at 0 "${1}"; }      # the disc mounted
eject()  { rm -f "${PROC_ROOT}/${1}/fd/9" "${PROC_ROOT}/${1}/fdinfo/9"; }
at() {  # at <sector> [pid]: where Main has read to
  printf 'pos:\t%d\nflags:\t0100000\nmnt_id:\t21\n' $(( ${1} * 2048 )) > "${PROC_ROOT}/${2:-700}/fdinfo/9"
}
mkdir -p "${PROC_ROOT}/650"
printf 'MiSTer_SAM_on.s\n' > "${PROC_ROOT}/650/comm"
printf '/bin/bash\0/media/fat/Scripts/MiSTer_SAM_on.sh\0' > "${PROC_ROOT}/650/cmdline"
mkdir -p "${PROC_ROOT}/640/fd"
printf 'MiSTer\n' > "${PROC_ROOT}/640/comm"
printf '/media/fat/MiSTer\0--no-core\0' > "${PROC_ROOT}/640/cmdline"
main_process 700 "${ISO}"

# The telemetry: one line, as Main writes it, its clock the uptime's.
DVD_TELEM="${TMP}/dvd_telem.json"
telem() {  # telem [pause|still|menu|nomedia|stale]
  local p=0 s=0 m=0 media=1 t="${UPTIME}.996045"
  case "${1:-}" in pause) p=1 ;; still) s=1 ;; menu) m=1 ;; nomedia) media=0 ;; stale) t=$(( UPTIME - 60 )).5 ;; esac
  printf '{"t":%s,"refreshes":1,"pickups":2,"vbuf_fill":3,"flags":{"media":%d,"pause":%d,"video_live":1,"still":%d,"menu":%d,"blend":0,"tmap":0,"tmap_fb":0,"bob":0}}\n' \
    "${t}" "${media}" "${p}" "${s}" "${m}" > "${DVD_TELEM}"
}
telem

export MISTER_RBFNAME="${TMP}/RBFNAME" MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_FULLPATH="${TMP}/FULLPATH" MISTER_CURRENTPATH="${TMP}/CURRENTPATH"
export MISTER_FILESELECT="${TMP}/FILESELECT" MISTER_GAMEID="${TMP}/GAMEID"
export MISTER_CORENAME="${TMP}/CORENAME"
export MISTER_INI="${TMP}/MiSTer.ini" CORETYPE_MAP="${TMP}/coretypes"
export NAMES_TXT="${TMP}/names.txt" SCRAPE_DIR="${TMP}/scraped"
printf 'DVD' > "${MISTER_RBFNAME}"; printf 'DVD' > "${MISTER_CORENAME}"
printf '/media/fat/_Other/DVD_20260930.rbf' > "${MISTER_STARTPATH}"
DVD_CACHE="${TMP}/cache/dvd"
DVD_ARM="${TMP}/dvd_hil"

# The wire: a FIFO with a reader, as test-wire.sh has it.
CAPTURE="${TMP}/tty-capture"; FIFO="${TMP}/tty-fifo"
mkfifo "${FIFO}"; : > "${CAPTURE}"
( while :; do cat "${FIFO}"; done >> "${CAPTURE}" ) 2>/dev/null &
READER_PID=$!
trap 'kill "${READER_PID}" 2>/dev/null' EXIT
TTYDEV="${FIFO}"
WAITSECS="0"; CMDWAITSECS="0"
SHOW_METADATA="yes"; METADATA_INTERVAL="12"; TRANSITION="-2"
core_bootscreen_time="0"
debug="false"; debugfile="${TMP}/debuglog"
iconfolder="${ROOT}/pics/icon"; bannerfolder="${TMP}/pics/banner"; userbannerfolder="${TMP}/pics/user"
wheelpack="${TMP}/pics/arcade/wheels.bin"; wheelindex="${TMP}/pics/arcade/wheels.idx"
mkdir -p "${bannerfolder}" "${userbannerfolder}"
corenamefile="${MISTER_CORENAME}"
dbug() { :; }
# shellcheck source=../tty2oled-meta.sh
. "${ROOT}/tty2oled-meta.sh"
eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"
DVD_CACHE="${TMP}/cache/dvd"; DVD_ARM="${TMP}/dvd_hil"; DVD_TELEM="${TMP}/dvd_telem.json"
UC_OUT="${TMP}/check"
FW_VERSION="0.8.2b"
# The ring, as big as the image allows.
DVD_LEAD_FULL=2000; DVD_LEAD_MAX=2500; DVD_JUMP_SECTORS=500; DVD_JUMP_RATE=1

# The test's clock, and a nap that moves it on.
MS=1000000
now_ms() { NOW_MS="${MS}"; }
nap() { [ "${1}" = 0 ] || MS=$(( MS + 1000 )); }
later() { MS=$(( MS + ${1} )); }

# The wire's lines since the last look, pictures' and icons' bytes left out.
# Not anchored: a description's bytes end with no newline, so the command
# after them shares their line.
wire() { sleep 0.25; LC_ALL=C grep -a -o -E '(CMD[A-Z]+[^[:cntrl:]]*|^DVD)' "${CAPTURE}" | tr '\n' ' '; : > "${CAPTURE}"; }
fields() { local IFS='|'; printf '%s' "${META_FIELDS[*]//$'\t'/=}"; }

# The tool as the daemon runs it: nice is a stand-in that runs it as it is,
# and the lookup answers from here, logging what it was asked.
STUB="${TMP}/bin"; mkdir -p "${STUB}"
printf '#!/bin/sh\nshift 2; exec "$@"\n' > "${STUB}/nice"; chmod +x "${STUB}/nice"
ASKED="${TMP}/asked"
cat > "${STUB}/dvdtool" <<EOF
import os, subprocess, sys
a = sys.argv[1:]
if a and a[0] == "lookup":
    with open("${ASKED}", "a") as f:
        f.write(" ".join(a) + "\\n")
    key, db = a[a.index("--key") + 1], a[a.index("--db") + 1]
    os.makedirs(os.path.dirname(db), exist_ok=True)
    with open(db, "a") as f:
        f.write(key + "||ok|Some Film|2004-05-01|||Drama|Jane Doe|Big Studio||A film about a disc.\\n")
    print("ok Some Film")
    sys.exit(0)
sys.exit(subprocess.call([sys.executable, "${TOOL}"] + a))
EOF
chmod +x "${STUB}/dvdtool"
DVD_TOOL="${STUB}/dvdtool"
PATH="${STUB}:${PATH}"
jobs_done() {   # run the jobs until both are collected
  local i
  dvd_jobs
  for i in $(seq 1 100); do
    bg_running dvs || bg_running dvl || return 0
    sleep 0.1; dvd_jobs
  done
}

# ---------------------------------------------------------------------------
section "finding the disc: Main by its core, its descriptor on the disc"
# ---------------------------------------------------------------------------
oldcore="DVD"
dvd_reset
dvd_find
ok "Main, not the other MiSTer with no core" "${DVD_PID}" "700"
ok "the descriptor on the disc, not the others" "${DVD_FD}" "9"
ok "and what it is: the image" "${DVD_DEV}" "${ISO}"
LSLOG="${TMP}/ls-log"; printf '#!/bin/sh\necho ls >>"%s"\nexec %s "$@"\n' "${LSLOG}" "$(command -v ls)" > "${STUB}/ls"
chmod +x "${STUB}/ls"; : > "${LSLOG}"
dvd_find; dvd_find
ok "found once: after that two tests, no listing" "$(wc -l < "${LSLOG}")" "0"
rm -f "${STUB}/ls"
dvd_pos
ok "where it reads, in sectors" "${DVD_R}" "0"

# ---------------------------------------------------------------------------
section "the disc read and looked up, in the background"
# ---------------------------------------------------------------------------
DVD_LOOKUP="yes"
jobs_done
ok "scanned: its key" "${DVD_KEY}" "TEST_MOVIE_WS_D1-20041004230725-10120"
ok "its label" "${DVD_LABEL}" "TEST_MOVIE_WS_D1"
ok "its file's name to show until Wikipedia answers" "${DVD_FALLBACK}" "Some Film (2004)"
ok "for this disc" "${DVD_SCANNED}" "${ISO}"
ok "its table loaded" "${#DVD_S[@]}:${DVD_MAIN_TITLE}:${DVD_MAIN_TOTAL}" "27:1:100"
ok "the table cached, by the key" "$(ls "${DVD_CACHE}")" "TEST_MOVIE_WS_D1-20041004230725-10120.nav"
ok "Wikipedia asked, by the name" "$(cat "${ASKED}")" \
   "lookup --key TEST_MOVIE_WS_D1-20041004230725-10120 --query Some Film (2004) --db ${SCRAPE_DIR}/DVD.txt"
dvd_jobs; dvd_jobs
ok "once" "$(wc -l < "${ASKED}")" "1"

# ---------------------------------------------------------------------------
section "the layout: Wikipedia's details, the disc's runtime, the icon"
# ---------------------------------------------------------------------------
DVD_DISPLAY=""
build_meta DVD corechange
ok "a film, as a console game" "${META_KIND}:${META_GAME}:${META_SOURCE}" "console:yes:dvd"
ok "titled by Wikipedia" "${META_TITLE}" "Some Film"
ok "Year Studio Director Artist Genre Runtime, those there are" "$(fields)" \
   "Year=2004|Studio=Big Studio|Director=Jane Doe|Genre=Drama|Runtime=2m"
ok "the DVD icon" "${META_ICON}" "dvd"
ok "the description" "${META_DESC}" "A film about a disc."
ok "nothing pinned: the chapter is above them" "${META_PINNED_COUNT}" "0"
DVD_FIELDS="Titles Label nonsense Runtime"; DVD_BUILT=""
build_meta DVD
ok "DVD_FIELDS picks and orders; unknown names are not rows" "$(fields)" \
   "Titles=2|Label=TEST_MOVIE_WS_D1|Runtime=2m"
DVD_FIELDS="Year Studio Director Artist Genre Runtime"
sed -i 's/|ok|Some Film|/|ok|Some Film (Director'"'"'s Cut)|/' "${SCRAPE_DIR}/DVD.txt"
touch -d '+5 seconds' "${SCRAPE_DIR}/DVD.txt"
build_meta DVD
ok "corrected by hand in scraped/DVD.txt: shown" "${META_TITLE}" "Some Film (Director's Cut)"
mv "${SCRAPE_DIR}/DVD.txt" "${TMP}/DVD.txt.away"
build_meta DVD
ok "nothing from Wikipedia: the image's name" "${META_TITLE}:$(fields)" "Some Film (2004):Runtime=2m"
mv "${TMP}/DVD.txt.away" "${SCRAPE_DIR}/DVD.txt"

# ---------------------------------------------------------------------------
section "the place in the film: the read, the ring, the telemetry"
# ---------------------------------------------------------------------------
# The film's sectors start at 120; chapters at 0, 30 and 70s. In the film's
# own sectors (less 120): 100 a second to 30s at 3000, 50 a second to 50s at
# 4000, 150 a second to 70s at 7000, then 66.7 a second to 100s at 9000.
# The ring here is 2000 sectors, never more than 2500.
dvd_tick_at() { at "${1}"; dvd_tick; }
: > "${CAPTURE}"
DVD_R_PREV=""; MEDIA_SENT=""
dvd_tick_at 6120
ok "first seen mid-film: the ring taken to be full - 2000 back is 4120, 50s" \
   "$(wire)" "CMDMEDIA,1,50,100,2,3 "
later 1000; dvd_tick_at 6270
ok "a second on, the read a second on: in step, nothing sent" "$(wire)" ""
ok "the clock counted it" "$(( DVD_E_MS / 1000 ))" "51"

telem pause; later 5000; dvd_tick_at 6270
ok "paused: said at once, the count stopped" "$(wire)" "CMDMEDIA,2,51,100,2,3 "
later 5000; dvd_tick_at 6270
ok "paused for longer: nothing" "$(wire)" ""
telem; later 1000; dvd_tick_at 6420
ok "playing again" "$(wire)" "CMDMEDIA,1,52,100,2,3 "
for i in 1 2 3 4 5; do later 1000; dvd_tick_at $(( 6420 + 150 * i )); done
ok "five seconds in step: nothing" "$(wire)" ""
for i in $(seq 1 13); do later 1000; dvd_tick_at $(( 7170 + 100 * i )); done
ok "into chapter 3 at 70s: said, and only that" "$(wire)" "CMDMEDIA,1,70,100,3,3 "

later 1000; dvd_tick_at 1120
ok "a seek back: the read starts again where the film is - 10s" "$(wire)" "CMDMEDIA,1,10,100,1,3 "
later 1000; dvd_tick_at 1300
ok "and counts on from there" "$(wire)$(( DVD_E_MS / 1000 ))" "11"
for i in 1 2 3 4 5 6 7 8; do later 1000; dvd_tick_at 1300; done
ok "never ahead of the read: the read stalled, the clock waits at it - 11.8s" \
   "$(( DVD_E_MS / 100 ))" "118"
ok "and the firmware, counting on, is told so every 2s" "$(wire)" \
   "CMDMEDIA,1,11,100,1,3 CMDMEDIA,1,11,100,1,3 CMDMEDIA,1,11,100,1,3 CMDMEDIA,1,11,100,1,3 "
for r in 2700 4100 5500 6900; do later 1000; dvd_tick_at "${r}"; done
ok "never further behind than the ring holds: 2500 behind 6900 is 51.9s" \
   "$(( DVD_E_MS / 100 ))" "518"
wire >/dev/null

later 1000; dvd_tick_at 8500
ok "a jump forward, further than a ring fills in a second: there" "$(wire)" "CMDMEDIA,1,90,100,3,3 "
later 1000; dvd_tick_at 9620
ok "into title 2's own sectors: title 2, its length and chapters" "$(wire)" "CMDMEDIA,1,10,60,1,2 "

telem menu; later 1000; dvd_tick_at 34
ok "the disc's menu: no time, no chapter" "$(wire)" "CMDMEDIA,4,0,0,0,0 "
telem; later 1000; dvd_tick_at 3120
ok "a chapter chosen from it: from where the read is" "$(wire)" "CMDMEDIA,1,30,100,2,3 "
later 1000; dvd_tick_at 114
ok "the menu's sectors say so with no telemetry flag too" "$(wire)" "CMDMEDIA,4,0,0,0,0 "
later 1000; dvd_tick_at 3170; wire >/dev/null

telem still; later 1000; dvd_tick_at 3170
ok "a still: its own state, not counting" "$(wire)" "CMDMEDIA,5,31,100,2,3 "
telem stale; later 3000; dvd_tick_at 3320
ok "telemetry gone stale: taken to be playing" "$(wire)" "CMDMEDIA,1,34,100,2,3 "
telem nomedia; later 1000; dvd_tick_at 3320
ok "no disc said by the core, the descriptor still open: nothing" "$(wire)" ""
telem

FW_VERSION="0.8.1b"; MEDIA_SENT=""
later 1000; dvd_tick_at 3470
ok "firmware before 0.8.2b: never sent, it would be drawn as text" "$(wire)" ""
FW_VERSION="0.8.2b"
later 1000; dvd_tick_at 3620
ok "and again once it is" "$(wire)" "CMDMEDIA,1,36,100,2,3 "

# Drift: the firmware counts from what it was sent, the daemon from the read.
MEDIA_SENT_AT=$(( MS - 3000 ))
later 1000; dvd_tick_at 3770
ok "the firmware's count 3s ahead of the daemon's: sent again" "$(wire)" "CMDMEDIA,1,37,100,2,3 "

# ---------------------------------------------------------------------------
section "a look starts no process"
# ---------------------------------------------------------------------------
FORKLOG="${TMP}/forks"; FORKBIN="${TMP}/forkbin"; mkdir -p "${FORKBIN}"
for c in ls stat cat grep sed awk date sleep head tail tr cut wc python3 readlink; do
  real="$(command -v "${c}")" || continue
  printf '#!/bin/sh\necho %s >>"%s"\nexec %s "$@"\n' "${c}" "${FORKLOG}" "${real}" >"${FORKBIN}/${c}"
  chmod +x "${FORKBIN}/${c}"
done
: > "${FORKLOG}"
KEEP="${PATH}"; PATH="${FORKBIN}:${PATH}"
for i in 1 2 3 4 5; do later 1000; at $(( 3770 + 150 * i )); dvd_tick; done
telem pause; later 1000; dvd_tick
PATH="${KEEP}"
ok "six looks, a pause said among them: nothing started" "$(tr '\n' ' ' < "${FORKLOG}")" ""
ok "the pause went out" "$(wire)" "CMDMEDIA,2,42,100,2,3 "
telem

# ---------------------------------------------------------------------------
section "following between passes"
# ---------------------------------------------------------------------------
at 4500
T0="${MS}"; dvd_follow 3
ok "a look a second for the seconds it was given" "$(( (MS - T0) / 1000 ))" "3"
printf 'NES' > "${MISTER_CORENAME}"
T0="${MS}"; dvd_follow 5
ok "another core: back to the loop at once" "$(( MS - T0 ))" "0"
printf 'DVD' > "${MISTER_CORENAME}"
eject 700
T0="${MS}"; dvd_follow 5
ok "the disc gone: back to the loop at once" "$(( MS - T0 ))" "0"
wire >/dev/null

# ---------------------------------------------------------------------------
section "on the wire: the disc found, changed, taken out"
# ---------------------------------------------------------------------------
dvd_reset; MEDIA_SENT=""; META_WIRE_LAST=""; ASKED_BEFORE="$(wc -l < "${ASKED}")"
DVD_ASKED=(); DVD_DISPLAY=""
senddata DVD; oldcore="DVD"
ok "the core with no disc: its name, no layout" "$(wire)" "CMDMETAOFF DVD "
refreshmeta DVD
ok "nothing to show yet" "$(wire)" ""

insert 700 "${ISO}"
jobs_done
at 3170; telem
refreshmeta DVD
ok "read: the place first (2000 back from 3170), the layout, its description, its icon" "$(wire)" \
   "CMDMEDIA,1,10,100,1,3 CMDMETA,2,12,0,0,Some Film (Director's Cut)|Year=2004|Studio=Big Studio|Director=Jane Doe|Genre=Drama|Runtime=2m CMDDESC,20 CMDICON "
ok "known to scraped/DVD.txt: Wikipedia not asked again" "$(wc -l < "${ASKED}")" "${ASKED_BEFORE}"
refreshmeta DVD
ok "nothing new: nothing sent" "$(wire)" ""

eject 700; insert 700 "${OTHER}"
refreshmeta DVD
ok "another disc: the core's picture back while it is read" "$(wire)" "CMDMETAOFF DVD "
jobs_done
at 120
refreshmeta DVD
ok "then its own layout, under its label" "$(wire)" \
   "CMDMEDIA,1,0,100,1,3 CMDMETA,2,12,0,0,Some Film|Year=2004|Studio=Big Studio|Director=Jane Doe|Genre=Drama|Runtime=2m CMDDESC,20 CMDICON "
ok "which Wikipedia was asked about, by the image's name" "$(tail -n 1 "${ASKED}" | sed 's/.*--query \(.*\) --db.*/\1/')" "Other"

eject 700
refreshmeta DVD
ok "taken out: the core's picture again" "$(wire)" "CMDMETAOFF DVD "
refreshmeta DVD
ok "once" "$(wire)" ""
MEDIA_SENT="1|100|1|3"
sendmetaoff >/dev/null; wire >/dev/null
ok "CMDMETAOFF forgets what the band showed" "${MEDIA_SENT}" ""

DVD_SCREEN="no"
build_meta DVD corechange
ok "DVD_SCREEN=no: the DVD core as any other" "${META_SOURCE}:${META_GAME}" "core:no"
DVD_SCREEN="yes"

# ---------------------------------------------------------------------------
section "the telemetry switch: ours made, ours removed, no one else's"
# ---------------------------------------------------------------------------
rm -f "${DVD_ARM}"
dvd_arm
ok "armed: the file, saying whose it is" "$(cat "${DVD_ARM}")" "${DVD_ARM_MARK}"
dvd_disarm
ok "disarmed: gone" "$([ -e "${DVD_ARM}" ] && echo there || echo gone)" "gone"
: > "${DVD_ARM}"
dvd_arm
ok "someone else's (the core's own test switch): left as it is" "$(wc -c < "${DVD_ARM}")" "0"
dvd_disarm
ok "and not removed" "$([ -e "${DVD_ARM}" ] && echo there || echo gone)" "there"
ok "S60tty2oled's stop knows ours by the same words" \
   "$(printf '%s\n' "${DVD_ARM_MARK}" | grep -c '^armed by tty2oled+ ')" "1"
ok "and names the same file" "$(grep -c '/media/fat/dvd_hil' "${ROOT}/S60tty2oled")" "1"
ok "which is the meta library's" "$(grep -c ': "${DVD_ARM:=/media/fat/dvd_hil}"' "${ROOT}/tty2oled-meta.sh")" "1"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
