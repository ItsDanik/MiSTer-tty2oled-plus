#!/bin/bash
#
# ScummVM: what the display learns about a ScummVM game, and when.
#
# ScummVM is a program, not a core - MiSTer only ever hears "ScummVM" in
# CORENAME - so everything here is read off ScummVM itself: its ini (rewritten
# as a game starts), the files it holds open (closed when a game goes back to
# ScummVM's launcher), and its icon packs (the games list and an icon a game).
# Each of those was checked on a real MiSTer running Full Throttle (SCUMM,
# holds its files), EcoQuest (SCI, holds them) and Space Quest II (AGI, holds
# none).
#
# No MiSTer and no ScummVM: a fake /proc (PROC_ROOT) holds a process with the
# real one's command line, environment, stat line and fd links, and the icon
# packs are zips made here with the real layout.
#
#   ./tests/test-scummvm.sh

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/scummvm"
rm -rf "${TMP}"; mkdir -p "${TMP}"
TMP="$(cd "${TMP}" && pwd -P)"   # /proc shows resolved paths; so must the fixtures
TOOL="${ROOT}/tools/tty2oledplus_scummvm.py"

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
# Icon packs, as ScummVM ships them: gui-icons-<date>.dat, a zip of
# icons/<engine>-<gameid>.png and icons/<engine>.png, with the games list in
# four XML files. A later pack corrects an earlier one.
# ---------------------------------------------------------------------------
ICONS="${TMP}/ScummVM/ICONS"
mkdir -p "${ICONS}"
python3 - "${ICONS}" <<'EOF'
import sys, os, struct, zlib, zipfile

def png(w, h, grey):
    raw = b"".join(b"\x00" + bytes([grey]) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

def pack(name, members):
    with zipfile.ZipFile(os.path.join(sys.argv[1], name), "w") as z:
        for k, v in members.items():
            z.writestr(k, v)

pack("gui-icons-20211112.dat", {
    "icons/": b"",
    "icons/scumm-ft.png": png(64, 64, 255),
    "icons/agi.png": png(32, 32, 136),
    "games.xml": '<?xml version="1.0" ?>\n<games>\n'
        '\t<game id="ft" name="Full Throttle (old name)" engine_id="scumm" company_id="lucasarts" year="1995" series_id=""/>\n'
        '\t<game id="sq2" name="Space Quest II: Chapter II - Vohaul&apos;s Revenge" engine_id="agi" company_id="sierra" year="1987" series_id="sq"/>\n'
        '\t<game id="ft" name="Not SCUMM" engine_id="other" company_id="" year="" series_id=""/>\n'
        '</games>\n',
    "companies.xml": '<companies><company id="lucasarts" name="LucasArts" alt_name=""/>'
                     '<company id="sierra" name="Sierra On-Line" alt_name=""/></companies>',
    "engines.xml": '<engines><engine id="scumm" name="SCUMM" alt_name=""/><engine id="agi" name="AGI" alt_name=""/></engines>',
    "series.xml": '<series><serie id="sq" name="Space Quest"/></series>',
})
pack("gui-icons-20241222.dat", {
    "games.xml": '<games><game id="ft" name="Full Throttle" engine_id="scumm" company_id="lucasarts" year="1995" series_id=""/>'
                 '<game id="ecoquest" name="EcoQuest: The Search for Cetus" engine_id="sci" company_id="sierra" year="1991" series_id=""/></games>',
    "companies.xml": '<companies><company id="sierra" name="Sierra" alt_name=""/></companies>',
    "engines.xml": '<engines><engine id="sci" name="SCI" alt_name=""/></engines>',
    "series.xml": "<series/>",
})
EOF

CACHE="${TMP}/cache"

# ---------------------------------------------------------------------------
section "tty2oledplus_scummvm.py index: the games list out of the packs"
# ---------------------------------------------------------------------------
OUT="$(python3 "${TOOL}" index --out "${CACHE}/games.idx" "${ICONS}")"
ok "it says what it did" "${OUT}" "4 games from 2 packs"
ok "a game is engine|gameid|name|company|year|series|engine" \
   "$(grep '^agi|sq2|' "${CACHE}/games.idx")" "agi|sq2|Space Quest II: Chapter II - Vohaul's Revenge|Sierra|1987|Space Quest|AGI"
ok "a later pack's name wins" "$(grep '^scumm|ft|' "${CACHE}/games.idx" | cut -d'|' -f3)" "Full Throttle"
ok "and a later pack's company" "$(grep '^sci|ecoquest|' "${CACHE}/games.idx" | cut -d'|' -f4)" "Sierra"
ok "an id is its engine's: the same id elsewhere is another game" \
   "$(grep -c '|ft|' "${CACHE}/games.idx")" "2"
ok "the first line records the packs" "$(head -c 8 "${CACHE}/games.idx")" "# packs "

OUT="$(python3 "${TOOL}" index --out "${CACHE}/games.idx" "${ICONS}")"
ok "the same packs again: nothing to do" "${OUT}" "up to date"
touch -d '2026-01-01' "${ICONS}/gui-icons-20241222.dat"
OUT="$(python3 "${TOOL}" index --out "${CACHE}/games.idx" "${ICONS}")"
ok "a changed pack: built again" "${OUT}" "4 games from 2 packs"

# ---------------------------------------------------------------------------
section "tty2oledplus_scummvm.py icon: 86x64, the game's else the engine's"
# ---------------------------------------------------------------------------
python3 "${TOOL}" icon --backend pure --out "${CACHE}/icons/scumm-ft.gsc" \
  --engine scumm --game ft "${ICONS}" >/dev/null
ok "the game's own icon converts" "${?}" "0"
ok "to an 86x64 .gsc" "$(tail -n +4 "${CACHE}/icons/scumm-ft.gsc" | xxd -r -p | wc -c)" "2752"
ok "fitted and centred: the square is 64 wide, black either side" \
   "$(tail -n +4 "${CACHE}/icons/scumm-ft.gsc" | tr -d '\n' | cut -c 1-86 | sed 's/0\{11\}\(f\{64\}\)0\{11\}/ok/')" "ok"

python3 "${TOOL}" icon --backend pure --out "${CACHE}/icons/agi-sq2.gsc" \
  --engine agi --game sq2 "${ICONS}" >/dev/null
ok "no icon of its own: the engine's" "${?}" "0"
ok "which is the engine's grey" \
   "$(tail -n +4 "${CACHE}/icons/agi-sq2.gsc" | tr -d '\n' | cut -c 44)" "8"

python3 "${TOOL}" icon --out "${CACHE}/icons/sci-ecoquest.gsc" \
  --engine sci --game ecoquest "${ICONS}" >/dev/null
ok "neither: exit 3" "${?}" "3"
ok "and no file" "$([ -e "${CACHE}/icons/sci-ecoquest.gsc" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
# A running ScummVM, in a fake /proc: the real one's command line and
# environment, and a stat line whose name has a space and a bracket in it.
# btime 1000000000, started 5000.00s after boot: 1000005000.
# ---------------------------------------------------------------------------
PROC_ROOT="${TMP}/proc"
mkdir -p "${PROC_ROOT}"
printf 'cpu  1 2 3\nbtime 1000000000\nprocesses 5\n' > "${PROC_ROOT}/stat"
START=1000005000
SVMHOME="${TMP}/ScummVM"
INI="${SVMHOME}/.config/scummvm/scummvm.ini"
mkdir -p "${INI%/*}"
GAMES="${TMP}/usb0/games/ScummVM"
FT="${GAMES}/Full Throttle (CD DOS)"
SQ2="${GAMES}/Space Quest 2 - Vohaul's Revenge (Floppy DOS)"
mkdir -p "${FT}/VIDEO" "${SQ2}"
: > "${FT}/FT.LA1"; : > "${FT}/VIDEO/CREDITS.SAN"; : > "${SQ2}/VOL.0"

cat > "${INI}" <<EOF
[scummvm]
versioninfo=2026.1.1git
lastselectedgame=ft
iconspath=${ICONS}

[ecoquest]
description=EcoQuest: The Search for Cetus (Floppy/DOS/English)
path=${GAMES}/EcoQuest
engineid=sci
gameid=ecoquest

[ft]
description=Full Throttle (Version A/English)
extra=Version A
path=${FT}
engineid=scumm
gameid=ft
language=en
platform=pc

[sq2]
description=Space Quest II: Chapter II - Vohaul's Revenge (2.0F 1989-01-05 3.5"/DOS/English)
path=${SQ2}/
engineid=agi
gameid=sq2
platform=pc
language=de
EOF
at() { touch -d "@${1}" "${INI}"; }                      # the ini written at <epoch>
last() { sed -i "s/^lastselectedgame=.*/lastselectedgame=${1}/" "${INI}"; }

# fake_process <pid> <arg>... : a ScummVM with that command line.
fake_process() {
  local pid="${1}"; shift
  rm -rf "${PROC_ROOT:?}/${pid}"; mkdir -p "${PROC_ROOT}/${pid}/fd"
  printf '%s\0' "$@" > "${PROC_ROOT}/${pid}/cmdline"
  printf 'SHELL=/bin/sh\0HOME=%s\0PWD=%s\0' "${SVMHOME}" "${SVMHOME}" > "${PROC_ROOT}/${pid}/environ"
  printf '%s (scummvm (x) y) S 1 1 1 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 3 0 500000 118412 8474\n' \
    "${pid}" > "${PROC_ROOT}/${pid}/stat"
  ln -s /dev/fb0 "${PROC_ROOT}/${pid}/fd/1"
  ln -s "${SVMHOME}/.cache/scummvm/logs/scummvm.log" "${PROC_ROOT}/${pid}/fd/6"
}
holds() { ln -sf "${2}" "${PROC_ROOT}/${1}/fd/${3:-20}"; }       # holds <pid> <file> [fd]
closes() { rm -f "${PROC_ROOT}/${1}/fd/20" "${PROC_ROOT}/${1}/fd/21"; }

# The launcher script's process, which names ScummVM but is not it.
mkdir -p "${PROC_ROOT}/900"
printf '/bin/bash\0/media/fat/Scripts/ScummVM_Master.sh\0' > "${PROC_ROOT}/900/cmdline"

export MISTER_RBFNAME="${TMP}/RBFNAME" MISTER_STARTPATH="${TMP}/STARTPATH"
export MISTER_INI="${TMP}/MiSTer.ini" CORETYPE_MAP="${TMP}/coretypes"
export NAMES_TXT="${TMP}/names.txt" SCRAPE_DIR="${TMP}/scraped"
printf 'MENU' > "${TMP}/RBFNAME"; printf 'menu.rbf' > "${TMP}/STARTPATH"
# shellcheck source=../tty2oled-meta.sh
. "${ROOT}/tty2oled-meta.sh"
SCUMMVM_CACHE="${CACHE}"
SCUMMVM_GONE_SECS=0

fields() { local IFS='|'; printf '%s' "${META_FIELDS[*]//$'\t'/=}"; }
rm -rf "${CACHE}/icons"          # converted above; here, not yet

# ---------------------------------------------------------------------------
section "finding ScummVM: the binary by name, its ini by HOME"
# ---------------------------------------------------------------------------
fake_process 4242 /media/fat/ScummVM/scummvmmaster --opl-driver=db --output-rate=48000
scummvm_reset
scummvm_find
ok "the binary, not the script that started it" "${SVM_PID}" "4242"
ok "the ini under its HOME" "${SVM_INI}" "${INI}"
ok "its start, from stat's 22nd field despite the name" "${SVM_START}" "${START}"
ok "no game on the command line" "${SVM_AUTO}" ""

# ---------------------------------------------------------------------------
section "ScummVM's launcher, then a game: the ini names it"
# ---------------------------------------------------------------------------
at $((START - 600))
build_meta ScummVM corechange
ok "an ini older than the process: the launcher" "${META_GAME}:${META_KIND}" "no:console"
ok "which is shown as the core" "${META_TITLE}" "ScummVM"
ok "RBFNAME's MENU is no name for it" "${DISPLAY_CORENAME}" "ScummVM"

at $((START + 1))
build_meta ScummVM
ok "written in its first second: still the launcher" "${META_GAME}" "no"

at $((START + 60))
build_meta ScummVM
ok "written since: the game it names is running" "${META_GAME}" "yes"
ok "titled from the games list" "${META_TITLE}" "Full Throttle"
ok "with the list's year and company, engine, platform and language" "$(fields)" \
   "System=ScummVM|Year=1995, LucasArts|Platform=DOS|Engine=SCUMM|Language=English"
ok "the icon is not converted yet: asked for" \
   "${SVM_NEED_ICON}" "scumm|ft|${CACHE}/icons/scumm-ft.gsc"
ok "meanwhile ScummVM's own icon, from pics/icon" "${META_ICON}" "ScummVM"

python3 "${TOOL}" icon --backend pure --out "${CACHE}/icons/scumm-ft.gsc" \
  --engine scumm --game ft "${ICONS}" >/dev/null
build_meta ScummVM
ok "once it is there, it is the icon" "${META_ICON}" "${CACHE}/icons/scumm-ft.gsc"
ok "and nothing is asked for" "${SVM_NEED_ICON}" ""

# ---------------------------------------------------------------------------
section "back to ScummVM's launcher: the game's files close"
# ---------------------------------------------------------------------------
holds 4242 "${FT}/FT.LA1"; holds 4242 "${FT}/VIDEO/CREDITS.SAN" 21
build_meta ScummVM
ok "holding its files: playing" "${META_GAME}:${SVM_HELD}" "yes:yes"

closes 4242
SCUMMVM_GONE_SECS=100
build_meta ScummVM
ok "closed a moment ago: a file swap, still playing" "${META_GAME}" "yes"
SCUMMVM_GONE_SECS=0
build_meta ScummVM
ok "closed for longer: back in the launcher" "${META_GAME}" "no"
ok "and the core's picture is asked for back" "${META_SHOWCORE}" "yes"
build_meta ScummVM
ok "asked for once, not every pass" "${META_SHOWCORE}" ""

at $((START + 120))
build_meta ScummVM
ok "the same game again rewrites the ini: playing again" "${META_GAME}:${SVM_HELD}" "yes:no"

# ---------------------------------------------------------------------------
section "an engine that holds nothing (AGI): playing until the ini changes"
# ---------------------------------------------------------------------------
last sq2; at $((START + 200))
build_meta ScummVM
ok "the ini's new game" "${META_TITLE}" "Space Quest II: Chapter II - Vohaul's Revenge"
ok "with its series, and language" "$(fields)" \
   "System=ScummVM|Year=1987, Sierra|Platform=DOS|Engine=AGI|Language=German|Series=Space Quest"
build_meta ScummVM; build_meta ScummVM
ok "never seen holding a file, it is taken to be running" "${META_GAME}" "yes"
ok "a path with a trailing slash is still its folder" "${SVM_GAMEDIR}" "${SQ2}"

# ---------------------------------------------------------------------------
section "a game the games list does not know: ScummVM's own description"
# ---------------------------------------------------------------------------
mv "${CACHE}/games.idx" "${CACHE}/games.idx.away"
last ecoquest; at $((START + 300))
build_meta ScummVM
ok "the description without its variant" "${META_TITLE}" "EcoQuest: The Search for Cetus"
ok "the engine as its id" "$(fields)" "System=ScummVM|Engine=SCI"
mv "${CACHE}/games.idx.away" "${CACHE}/games.idx"
build_meta ScummVM
ok "worked out once a start: a new index is not read" "${META_TITLE}" "EcoQuest: The Search for Cetus"
SVM_BUILT=""
build_meta ScummVM
ok "until the daemon says one landed" "$(fields)" "System=ScummVM|Year=1991, Sierra|Engine=SCI"

# ---------------------------------------------------------------------------
section "a one-game engine is named after its game: no Engine field"
# ---------------------------------------------------------------------------
printf 'lure|lure|Lure of the Temptress|Revolution|1992||Lure of the Temptress\n' >> "${CACHE}/games.idx"
printf '[lure]\ndescription=Lure of the Temptress (VGA/DOS/English)\npath=%s\nengineid=lure\ngameid=lure\nplatform=pc\n' \
  "${GAMES}/Lure" >> "${INI}"
last lure; at $((START + 350))
build_meta ScummVM
ok "the engine would only repeat the title" "$(fields)" \
   "System=ScummVM|Year=1992, Revolution|Platform=DOS"

# ---------------------------------------------------------------------------
section "an imported gamelist: by the game's folder, or by its target"
# ---------------------------------------------------------------------------
mkdir -p "${SCRAPE_DIR}"
printf '%s\n' \
  "Full Throttle (CD DOS)||ok|Full Throttle|1995-04-30|1|18|Adventure|LucasArts|LucasArts||Ben leads the Polecats." \
  "sq2||ok|Space Quest II|1987|1|14|Adventure|Sierra|Sierra|Space Quest|Roger again." \
  > "${SCRAPE_DIR}/ScummVM.txt"
last ft; at $((START + 400))
build_meta ScummVM
ok "the folder's name finds it" "${META_DESC}" "Ben leads the Polecats."
ok "and adds genre, developer, players, rating, release date" "$(fields)" \
   "System=ScummVM|Year=1995, LucasArts|Genre=Adventure|Developer=LucasArts|Platform=DOS|Engine=SCUMM|Language=English|Players=1|Rating=9/10|Released=1995-04-30"
last sq2; at $((START + 500))
build_meta ScummVM
ok "the target finds one keyed by it" "${META_DESC}" "Roger again."
SHOW_DESCRIPTION="no"; SVM_BUILT=""
build_meta ScummVM
ok "SHOW_DESCRIPTION=no leaves it out" "${META_DESC}" ""
SHOW_DESCRIPTION="yes"

# ---------------------------------------------------------------------------
section "a game on the command line runs from the start"
# ---------------------------------------------------------------------------
at $((START - 600))
fake_process 5151 /media/fat/ScummVM/scummvm --config="${INI}" -p /somewhere --fullscreen ft
rm -rf "${PROC_ROOT:?}/4242"
build_meta ScummVM corechange
ok "a new process is found" "${SVM_PID}" "5151"
ok "its game is the last argument" "${SVM_AUTO}" "ft"
ok "and runs though the ini is old" "${META_GAME}:${META_TITLE}" "yes:Full Throttle"

fake_process 5152 /media/fat/ScummVM/scummvm -c "${INI}" -p ft
rm -rf "${PROC_ROOT:?}/5151"
scummvm_reset; scummvm_find
ok "an option's value is not a game" "${SVM_AUTO}" ""
ok "-c <file> is the ini" "${SVM_INI}" "${INI}"

# ---------------------------------------------------------------------------
section "ScummVM gone: nothing to find"
# ---------------------------------------------------------------------------
rm -rf "${PROC_ROOT:?}/5152"
build_meta ScummVM
ok "no process, no game" "${META_GAME}:${SVM_PID}" "no:"

# ---------------------------------------------------------------------------
# The daemon's side: what goes on the wire as all that happens.
# ---------------------------------------------------------------------------
# A FIFO, as test-wire.sh does: the daemon writes with ">", which would
# truncate a plain file at every command.
CAPTURE="${TMP}/tty"; FIFO="${TMP}/tty-fifo"
: > "${CAPTURE}"; mkfifo "${FIFO}"
( while :; do cat "${FIFO}"; done >> "${CAPTURE}" ) 2>/dev/null &
READER_PID=$!
trap 'kill "${READER_PID}" 2>/dev/null' EXIT
TTYDEV="${FIFO}"
WAITSECS="0"; CMDWAITSECS="0"
SHOW_METADATA="yes"; METADATA_INTERVAL="12"; TRANSITION="-2"
core_bootscreen_time="0"
debug="false"; debugfile="${TMP}/debuglog"
iconfolder="${TMP}/pics/icon"; bannerfolder="${TMP}/pics/banner"; userbannerfolder="${TMP}/pics/user"
wheelpack="${TMP}/pics/arcade/wheels.bin"; wheelindex="${TMP}/pics/arcade/wheels.idx"
mkdir -p "${bannerfolder}" "${iconfolder}" "${userbannerfolder}"
python3 "${ROOT}/tools/png2gsc.py" --banner --blank --out "${bannerfolder}/ScummVM.gsc" >/dev/null
corenamefile="${TMP}/CORENAME"; printf 'ScummVM' > "${corenamefile}"
dbug() { :; }
eval "$(sed '/^# \*\* Main \*\*/,$d' "${ROOT}/tty2oled.sh" | sed '/^\. \/media\/fat/d; /^cd \/tmp/d')"
SCUMMVM_CACHE="${CACHE}"; SCUMMVM_GONE_SECS=0
# The lines sent since the last look, pictures' bytes left out.
wire() { sleep 0.25; LC_ALL=C grep -a -o -E '^(CMD[A-Z]+[^[:cntrl:]]*|ScummVM)' "${CAPTURE}" | tr '\n' ' '; : > "${CAPTURE}"; }

section "the wire: launcher, game, late icon, launcher"
rm -rf "${SCRAPE_DIR}"            # the layout alone; test-wire.sh covers descriptions
rm -f "${CACHE}/icons/scumm-ft.gsc"
fake_process 6000 /media/fat/ScummVM/scummvmmaster --opl-driver=db
last ft; at $((START - 600))
oldcore="MENU"; META_WIRE_LAST=""
senddata ScummVM; oldcore="ScummVM"
ok "ScummVM's launcher: its picture, no layout" "$(wire)" "CMDMETAOFF CMDCOR,ScummVM,-2 "

ok "the ini's folder is watched" "$(metawatchlist | tr ' ' '\n' | grep -cxF "${INI%/*}")" "1"

# ScummVM's own icon, from pics/icon, stands in until the game's is converted.
python3 "${ROOT}/tools/png2gsc.py" --blank --out "${iconfolder}/ScummVM.gsc" >/dev/null
at $((START + 60))
refreshmeta ScummVM
ok "a game: its layout, and ScummVM's icon for now" "$(wire)" \
   "CMDMETA,2,12,1,0,Full Throttle|System=ScummVM|Year=1995  LucasArts|Platform=DOS|Engine=SCUMM|Language=English CMDICON "
ok "which is pics/icon's" "${ICON_SENT}" "${iconfolder}/ScummVM.gsc"
refreshmeta ScummVM
ok "nothing new: nothing sent" "$(wire)" ""

# The jobs, with nice stubbed out so the helper runs as it is.
STUB="${TMP}/bin"; mkdir -p "${STUB}"
printf '#!/bin/sh\nshift 2; exec "$@"\n' > "${STUB}/nice"; chmod +x "${STUB}/nice"
SCUMMVM_TOOL="${TOOL}"
PATH="${STUB}:${PATH}" scummvm_jobs
ok "the icon is being converted" "$(bg_running svc && echo yes)" "yes"
ok "and the index checked" "$(bg_running svi && echo yes)" "yes"
for _ in $(seq 1 100); do [ -e "${CACHE}/icons/scumm-ft.gsc" ] && [ -e "${UC_OUT}.svi.rc" ] && break; sleep 0.1; done
scummvm_jobs
ok "both collected" "$(bg_running svc || bg_running svi || echo done)" "done"
refreshmeta ScummVM
ok "the game's icon, on its own, once it is there" "$(wire)" "CMDICON "
ok "which is the converted one" "${ICON_SENT}" "${CACHE}/icons/scumm-ft.gsc"
refreshmeta ScummVM
ok "and not again" "$(wire)" ""

closes 6000; holds 6000 "${FT}/FT.LA1"
refreshmeta ScummVM
ok "playing, holding its files: nothing" "$(wire)" ""
closes 6000
refreshmeta ScummVM
ok "back in the launcher: ScummVM's picture again" "$(wire)" "CMDMETAOFF CMDCOR,ScummVM,-2 "

at $((START + 90))
refreshmeta ScummVM
ok "the next game: its layout and its icon at once" "$(wire)" \
   "CMDMETA,2,12,1,0,Full Throttle|System=ScummVM|Year=1995  LucasArts|Platform=DOS|Engine=SCUMM|Language=English CMDICON "

# ---------------------------------------------------------------------------
section ".scummvm entries for frontends (tools/scummvm-entries.sh)"
# ---------------------------------------------------------------------------

# The shapes the real MiSTer's ini had: a folder a game, an apostrophe, a
# folder holding four games, two versions of one, a game in a subfolder and
# ScummVM having added it twice, a game outside games/ScummVM.
ENT="${TMP}/entries"
G="${ENT}/usb0/games/ScummVM"
mkdir -p "${G}/Full Throttle (CD DOS)" "${G}/Bear Stormin' (DOS)" "${G}/Puzzle Pack (CD Windows)" \
         "${G}/Space Quest 4 (CD DOS)" "${G}/Toonstruck (CD Windows)/MISC" "${ENT}/elsewhere/Lure"
cat > "${ENT}/scummvm.ini" <<EOF
[scummvm]
lastselectedgame=ft

[brstorm]
description=Bear Stormin' (DOS/English)
path=${G}/Bear Stormin' (DOS)
engineid=gob
gameid=brstorm

[dimp-win]
description=Simon the Sorcerer's Puzzle Pack: Demon in my Pocket (CD/Windows/English)
path=${G}/Puzzle Pack (CD Windows)
gameid=dimp

[ft]
description=Full Throttle (Version A/English)
path=${G}/Full Throttle (CD DOS)/
engineid=scumm
gameid=ft

[gone]
description=Removed Since
path=${G}/Not There
gameid=gone

[jumble-win]
description=Simon the Sorcerer's Puzzle Pack: Jumble (CD/Windows/English)
path=${G}/Puzzle Pack (CD Windows)
gameid=jumble

[lure]
description=Lure of the Temptress (VGA/DOS/English)
path=${ENT}/elsewhere/Lure
gameid=lure

[sq4-cd]
description=Space Quest IV: Roger Wilco and the Time Rippers (CD/DOS/English)
path=${G}/Space Quest 4 (CD DOS)
gameid=sq4

[sq4-cd-win]
description=Space Quest IV: Roger Wilco and the Time Rippers (CD/Windows/English)
path=${G}/Space Quest 4 (CD DOS)
gameid=sq4

[toon]
description=Toonstruck (DOS/English)
path=${G}/Toonstruck (CD Windows)
gameid=toon

[toon-1]
description=Toonstruck (DOS/English)
path=${G}/Toonstruck (CD Windows)/MISC
gameid=toon
EOF
ENTRIES="${ROOT}/tools/scummvm-entries.sh"
# As the MiSTer's bash 5.0 would run it: 5.2 forgives a quote in an
# associative array's arithmetic subscript, 5.0 does not.
entries() { INI="${ENT}/scummvm.ini" BASH_COMPAT=50 bash "${ENTRIES}" "$@" 2>&1; }
listed() { (cd "${ENT}" && find . -name '*.scummvm' | sort | tr '\n' ' '); }

OUT="$(entries -n)"
ok "-n writes nothing" "$(listed)" ""
ok "-n says what it would write" "$(tail -n 1 <<<"${OUT}")" "8 to be written, 0 already there, 2 skipped"

OUT="$(entries)"
ok "no shell errors (an apostrophe is not an arithmetic subscript)" \
   "$(grep -c -e 'bad array subscript' -e 'syntax error' <<<"${OUT}")" "0"
ok "one entry a game, named after its folder, or its description where a folder holds two" \
   "$(listed)" "./elsewhere/Lure/Lure.scummvm ./usb0/games/ScummVM/Bear Stormin' (DOS)/Bear Stormin' (DOS).scummvm ./usb0/games/ScummVM/Full Throttle (CD DOS)/Full Throttle (CD DOS).scummvm ./usb0/games/ScummVM/Puzzle Pack (CD Windows)/Simon the Sorcerer's Puzzle Pack - Demon in my Pocket (CD Windows English).scummvm ./usb0/games/ScummVM/Puzzle Pack (CD Windows)/Simon the Sorcerer's Puzzle Pack - Jumble (CD Windows English).scummvm ./usb0/games/ScummVM/Space Quest 4 (CD DOS)/Space Quest IV - Roger Wilco and the Time Rippers (CD DOS English).scummvm ./usb0/games/ScummVM/Space Quest 4 (CD DOS)/Space Quest IV - Roger Wilco and the Time Rippers (CD Windows English).scummvm ./usb0/games/ScummVM/Toonstruck (CD Windows)/Toonstruck (CD Windows).scummvm "
ok "an entry holds the game id, no newline" \
   "$(od -An -c "${G}/Full Throttle (CD DOS)/Full Throttle (CD DOS).scummvm" | tr -s ' ')" " f t"
ok "the id, not the target" \
   "$(cat "${G}/Puzzle Pack (CD Windows)/Simon the Sorcerer's Puzzle Pack - Jumble (CD Windows English).scummvm")" "jumble"
ok "a game ScummVM added twice is skipped" "$(grep -c '^skip toon-1: the same game as toon$' <<<"${OUT}")" "1"
ok "a game whose folder is gone is skipped" "$(grep -c '^skip gone:' <<<"${OUT}")" "1"

printf 'queen' > "${G}/Full Throttle (CD DOS)/Full Throttle (CD DOS).scummvm"
OUT="$(entries)"
ok "a second run writes nothing new" "$(tail -n 1 <<<"${OUT}")" "0 written, 7 already there, 3 skipped"
ok "an entry holding something else is kept and reported" \
   "$(cat "${G}/Full Throttle (CD DOS)/Full Throttle (CD DOS).scummvm")|$(grep -c "^skip ft: .* holds 'queen'$" <<<"${OUT}")" "queen|1"

# ---------------------------------------------------------------------------
rm -rf "${TMP}"
printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
