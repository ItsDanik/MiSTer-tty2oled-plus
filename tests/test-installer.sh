#!/bin/bash
#
# Tests for the release: tools/make-release.sh, which builds it, and
# tools/tty2oledplus_update.sh, which installs it on a MiSTer.
#
# A real release is built from this working copy - with a small title index,
# a small artwork pack and stand-in firmware images, so it takes a second
# rather than half a minute - and served from local disk over file://, laid
# out the way GitHub serves releases. The installer then runs against a fake
# /media/fat. The init script and flash-mister.sh are replaced by stand-ins
# that record what was asked of them; everything else is the real thing,
# including the boot hook and the archives.
#
#   ./tests/test-installer.sh

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/installer"
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
yesno() { if "$@"; then echo yes; else echo no; fi; }

VERSION="$(cat "${ROOT}/VERSION")"
. "${ROOT}/tools/manifest.sh"

# ===========================================================================
section "make-release.sh"
# ===========================================================================

SRC="${TMP}/src"
mkdir -p "${SRC}/index" "${SRC}/pics/banner" "${SRC}/pics/alt" "${SRC}/pics/icon" \
         "${SRC}/pics/user" "${SRC}/fw/fw-lolin32" "${SRC}/fw/fw-esp32s3" "${SRC}/fw/fw-tiny"
echo "00000000|Test Game|USA|1990|Test|Action|Test|" > "${SRC}/index/NES.idx"
echo "#define x 1" > "${SRC}/pics/banner/NES.gsc"
echo "#define x 1" > "${SRC}/pics/alt/NES_alt1.gsc"
echo "#define x 1" > "${SRC}/pics/icon/NES.gsc"
echo "#define x 1" > "${SRC}/pics/icon/SNES.gsc"
# The user's own. A release must never carry one: it would overwrite theirs.
echo "#define x 1" > "${SRC}/pics/user/NES.gsc"
# Stand-in firmware: the right name, and big enough to pass the size floor.
head -c 300000 /dev/zero > "${SRC}/fw/fw-lolin32/MiSTer_SSD1322_USB.ino.merged.bin"
head -c 300001 /dev/zero > "${SRC}/fw/fw-esp32s3/MiSTer_SSD1322_USB.ino.merged.bin"

release() {  # release <out dir> [more options]
  local out="$1"; shift
  "${ROOT}/tools/make-release.sh" --out "${out}" --index "${SRC}/index" \
    --pics "${SRC}/pics" --firmware "${SRC}/fw" "$@" > "${TMP}/release.out" 2>&1
}

release "${TMP}/dist" --notes "${TMP}/notes.md"; RC="${?}"
ok "a release builds" "${RC}" "0"
D="${TMP}/dist"
# Sorted in the C locale: a Greek one orders these differently, and a test
# that changes its mind with $LANG is no test.
ok "with version-free asset names, so latest/download finds them" \
   "$(cd "${D}" && LC_ALL=C ls | LC_ALL=C sort | tr '\n' ' ')" \
   "SHA256SUMS VERSION tty2oledplus-esp32s3.bin tty2oledplus-lolin32.bin tty2oledplus-pics.tar.gz tty2oledplus.tar.gz tty2oledplus_install.sh tty2oledplus_update.sh "
# GitHub compares asset names without case: tty2oledplus_install.sh beside
# tty2oledplus_installer.sh failed the upload of v0.4.1b with "already exists".
ok "no two asset names differ only in case" \
   "$(cd "${D}" && ls | tr '[:upper:]' '[:lower:]' | sort | uniq -d)" ""
ok "VERSION says which" "$(cat "${D}/VERSION")" "${VERSION}"
ok "every asset matches SHA256SUMS" "$(cd "${D}" && sha256sum -c --quiet SHA256SUMS 2>&1)" ""
ok "SHA256SUMS lists all seven" "$(grep -c '' "${D}/SHA256SUMS")" "7"

LISTING="$(tar tzf "${D}/tty2oledplus.tar.gz")"
MISSING=""
for f in ${MANIFEST_FILES} ${MANIFEST_DEFAULTS}; do
  printf '%s\n' "${LISTING}" | grep -qx "tty2oledplus/${f}" || MISSING="${MISSING} ${f}"
done
for f in ${MANIFEST_TOOLS}; do
  printf '%s\n' "${LISTING}" | grep -qx "tty2oledplus/$(basename "${f}")" || MISSING="${MISSING} ${f}"
done
ok "the scripts archive has everything in the manifest" "${MISSING}" ""
ok "tools are flattened, as they are on the MiSTer" "$(printf '%s\n' "${LISTING}" | grep -c '/tools/')" "0"
ok "the title index goes in" "$(printf '%s\n' "${LISTING}" | grep -c 'titleindex/NES.idx')" "1"
# The icons ride in the scripts archive, not the 80MB pack: 27 small files
# that every update should carry, against artwork that is fetched only when it
# is missing.
ok "and the drawn icons" "$(printf '%s\n' "${LISTING}" | grep -c 'pics/icon/.*\.gsc')" "2"
ok "everything unpacks under tty2oledplus/" "$(printf '%s\n' "${LISTING}" | grep -vc '^tty2oledplus/')" "0"
PICSLIST="$(tar tzf "${D}/tty2oledplus-pics.tar.gz")"
ok "the artwork is in its own archive" "$(printf '%s\n' "${PICSLIST}" | grep -c 'tty2oledplus/pics/banner/NES.gsc')" "1"
ok "with the alternatives beside it" "$(printf '%s\n' "${PICSLIST}" | grep -c 'tty2oledplus/pics/alt/NES_alt1.gsc')" "1"
# pics/user is the user's own artwork and the one folder no release may write
# into - the same reason tty2oled-user.ini is not in the manifest. The empty
# folder goes in so a fresh install has somewhere to put a picture.
ok "and nothing of the user's in either" \
   "$(printf '%s\n%s\n' "${LISTING}" "${PICSLIST}" | grep -c 'pics/user/.')" "0"
ok "though the folder itself is made" "$(printf '%s\n' "${PICSLIST}" | grep -c 'tty2oledplus/pics/user/$')" "1"
ok "the notes carry this version's changelog" \
   "$(head -n1 "${TMP}/notes.md" | grep -c .)" "1"
ok "and how to install it" "$(grep -c '^curl .*releases/latest/download/tty2oledplus_update.sh | bash$' "${TMP}/notes.md")" "1"
ok "including from the Scripts menu" "$(grep -c 'run \*\*tty2oledplus_install\*\* from the Scripts' "${TMP}/notes.md")" "1"

release "${TMP}/dist2"
ok "the same inputs give the same bytes" "$(cat "${TMP}/dist2/SHA256SUMS")" "$(cat "${D}/SHA256SUMS")"

release "${TMP}/bad" --tag "v0.0.0"; RC="${?}"
ok "a tag that is not VERSION is refused" "${RC}" "1"
head -c 1000 /dev/zero > "${SRC}/fw/fw-tiny/MiSTer_SSD1322_USB.ino.merged.bin"
mv "${SRC}/fw/fw-tiny" "${SRC}/fw/fw-esp32de"
release "${TMP}/bad"; RC="${?}"
ok "a firmware image too small to be one is refused" "${RC}" "1"
rm -rf "${SRC}/fw/fw-esp32de"

# ===========================================================================
# The installer, against a fake MiSTer
# ===========================================================================

# Served the way GitHub does: /latest/download/<asset> and
# /download/v<version>/<asset>.
REL="${TMP}/releases"
mkdir -p "${REL}/latest" "${REL}/download"
cp -r "${D}" "${REL}/latest/download"
cp -r "${D}" "${REL}/download/v${VERSION}"

FAT="${TMP}/fat"
INSTALL="${FAT}/tty2oledplus"
CALLS="${TMP}/calls"
STATE="${TMP}/daemon-state"

# A stand-in init script that keeps "running" in a file and logs every call.
cat > "${TMP}/fake-init" <<'FAKE'
#!/bin/bash
echo "init $1" >> "${FAKE_CALLS}"
case "$1" in
  start)  echo running > "${FAKE_STATE}" ;;
  stop)   echo stopped > "${FAKE_STATE}" ;;
  status) [ "$(cat "${FAKE_STATE}" 2>/dev/null)" = running ] ;;
esac
FAKE
cat > "${TMP}/fake-flash" <<'FAKE'
#!/bin/bash
# What matters is that nothing holds the serial port while it flashes.
port="free"; [ "$(cat "${FAKE_STATE}" 2>/dev/null)" = running ] && port="held by the daemon"
echo "flash $(basename "$1") chip=${CHIP_OVERRIDE:-} port=${port}" >> "${FAKE_CALLS}"
FAKE
chmod +x "${TMP}/fake-init" "${TMP}/fake-flash"
export FAKE_CALLS="${CALLS}" FAKE_STATE="${STATE}"

fresh_mister() {
  rm -rf "${FAT}"; mkdir -p "${FAT}/linux" "${FAT}/Scripts"
  printf '#!/bin/sh\necho mister\n' > "${FAT}/linux/user-startup.sh"
  : > "${FAT}/MiSTer.ini"
  rm -f "${STATE}"
}

# install [installer options]; T2OP_HWINF in the environment is what the
# display "says" - unset, there is no display to ask.
install() {
  : > "${CALLS}"
  T2OP_FAT="${FAT}" T2OP_URL="file://${REL}" T2OP_INIT="${TMP}/fake-init" \
  T2OP_FLASH="${TMP}/fake-flash" \
    bash "${ROOT}/tools/tty2oledplus_update.sh" "$@" > "${TMP}/out" 2>&1 </dev/null
}
said() { grep -c -- "$1" "${TMP}/out"; }
flashed() { grep '^flash' "${CALLS}" | sed 's/^flash //'; }
running() { if [ "$(cat "${STATE}" 2>/dev/null)" = running ]; then echo running; else echo stopped; fi; }
set_installed_version() { sed -i "s/^TTY2OLED_VERSION=\"[^\"]*\"/TTY2OLED_VERSION=\"$1\"/" "${INSTALL}/tty2oled-system.ini"; }

section "installer: a first install"

fresh_mister
T2OP_HWINF="ttyack;ttyack;HWLOLIN32;0.3.0b;"$'\r\n'"ttyack;" install; RC="${?}"
ok "it succeeds" "${RC}" "0"
MISSING=""
for f in ${MANIFEST_FILES} ${MANIFEST_DEFAULTS}; do [ -f "${INSTALL}/${f}" ] || MISSING="${MISSING} ${f}"; done
for f in ${MANIFEST_TOOLS}; do [ -x "${INSTALL}/$(basename "${f}")" ] || MISSING="${MISSING} ${f}"; done
ok "every file in the manifest is installed, tools executable" "${MISSING}" ""
ok "the installed version is the release's" "$(sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini")" "${VERSION}"
ok "the title index is installed" "$(yesno test -f "${INSTALL}/titleindex/NES.idx")" "yes"
ok "the artwork pack is installed" "$(yesno test -f "${INSTALL}/pics/banner/NES.gsc")" "yes"
ok "the display was flashed, once, with its own board's image" "$(flashed)" "tty2oledplus-lolin32.bin chip=esp32 port=free"
ok "with a board id found behind stale ttyacks" "$(said 'reported: lolin32, firmware 0.3.0b')" "1"
ok "the boot hook is added" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"
ok "the daemon is running at the end" "$(running)" "running"
ok "the updater is in the Scripts menu" "$(cmp -s "${FAT}/Scripts/tty2oledplus_update.sh" "${ROOT}/tools/tty2oledplus_update.sh" && echo same)" "same"
ok "and is executable" "$(yesno test -x "${FAT}/Scripts/tty2oledplus_update.sh")" "yes"
ok "no half-written updater is left behind" "$(ls -A "${FAT}/Scripts" | grep -c '\.new$')" "0"
# The Scripts menu is alphabetical, so the four entries read as a set:
# install, settings, uninstall, update.
ok "the settings editor is in the Scripts menu" \
   "$(cmp -s "${FAT}/Scripts/tty2oledplus_settings.sh" "${ROOT}/tools/tty2oledplus_settings.sh" && echo same)" "same"
ok "and is executable" "$(yesno test -x "${FAT}/Scripts/tty2oledplus_settings.sh")" "yes"
# ...and in the install folder as well, because S60tty2oled places all three
# from there on a MiSTer whose last update was run by an older installer.
ok "and in the install folder, for the daemon to place" \
   "$(yesno test -f "${INSTALL}/tty2oledplus_settings.sh")" "yes"
ok "log_file_entry being off is pointed out" "$(said 'log_file_entry=1')" "1"
ok "no staging directory is left in /tmp" "$(ls -d /tmp/tty2oledplus.* 2>/dev/null | wc -l | tr -d ' ')" "0"

section "installer: nothing to do"

echo "log_file_entry=1" > "${FAT}/MiSTer.ini"
T2OP_HWINF="HWLOLIN32;${VERSION};" install; RC="${?}"
ok "an up-to-date MiSTer succeeds" "${RC}" "0"
ok "and says there is nothing to do" "$(said 'nothing to do')" "1"
ok "without flashing" "$(flashed)" ""
ok "and the daemon it stopped to ask the display is running again" "$(running)" "running"
ok "the log_file_entry note is gone once it is set" "$(said 'log_file_entry=1')" "0"

section "installer: an update keeps what is yours"

echo 'TTYDEV="/dev/ttyUSB1"   # mine' > "${INSTALL}/tty2oled-user.ini"
echo 'MYCORE=console' > "${INSTALL}/coretypes.ini"
echo '# stale' >> "${INSTALL}/tty2oled.sh"
set_installed_version "0.0.1b"
T2OP_HWINF="HWLOLIN32;${VERSION};" install; RC="${?}"
ok "an update succeeds" "${RC}" "0"
ok "the scripts are replaced" "$(grep -c '# stale' "${INSTALL}/tty2oled.sh")" "0"
ok "your settings are not" "$(cat "${INSTALL}/tty2oled-user.ini")" 'TTYDEV="/dev/ttyUSB1"   # mine'
ok "nor your core types" "$(cat "${INSTALL}/coretypes.ini")" "MYCORE=console"
ok "a display already on this version is not reflashed" "$(flashed)" ""
ok "an artwork pack already there is not fetched again" "$(said 'Installing the artwork pack')" "0"
ok "the boot hook is not added twice" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"

rm "${INSTALL}/pics/banner/NES.gsc"
T2OP_HWINF="HWLOLIN32;${VERSION};" install --pics
ok "--pics fetches the artwork again" "$(yesno test -f "${INSTALL}/pics/banner/NES.gsc")" "yes"

T2OP_HWINF="HWLOLIN32;${VERSION};" install --force
ok "--force reflashes a current display" "$(flashed)" "tty2oledplus-lolin32.bin chip=esp32 port=free"

section "installer: firmware decisions"

set_installed_version "0.0.1b"
install --no-firmware
ok "--no-firmware updates the scripts" "$(said 'Installing scripts')" "1"
ok "and flashes nothing" "$(flashed)" ""

# No answer: guessing would flash the wrong pinout.
set_installed_version "0.0.1b"
install
ok "a display that does not answer is not flashed" "$(flashed)" ""
ok "the run still installs the scripts" "$(said 'Installing scripts')" "1"
ok "and says how to name the board" "$(said -- '--board lolin32')" "1"

install --board esp32s3
ok "--board names it when the display cannot" "$(flashed)" "tty2oledplus-esp32s3.bin chip=esp32s3 port=free"

T2OP_HWINF="HWESP8266;1.0;" install --force
ok "an ESP8266 is never flashed" "$(flashed)" ""

T2OP_HWINF="HWESP32S3;0.1;" install
ok "an S3 gets the S3 image and chip" "$(flashed)" "tty2oledplus-esp32s3.bin chip=esp32s3 port=free"

install --board banana; RC="${?}"
ok "an unknown --board is refused" "${RC}" "1"

section "installer: the pre-0.4.8b Scripts entries"

# The scripts were renamed in 0.4.8b. An update applied by this installer has
# to leave the menu with the new names and none of the old ones - a menu
# listing both update_tty2oledplus and tty2oledplus_update is a menu where
# nobody knows which one to run.
for f in update_tty2oledplus.sh uninstall_tty2oledplus.sh TTY2OLEDplus_Installer.sh; do
  printf '# the old one\n' > "${FAT}/Scripts/${f}"
done
install --force
LEFT=""
for f in update_tty2oledplus.sh uninstall_tty2oledplus.sh TTY2OLEDplus_Installer.sh; do
  [ -e "${FAT}/Scripts/${f}" ] && LEFT="${LEFT} ${f}"
done
ok "the old names are gone from the Scripts menu" "${LEFT}" ""
NEW=""
for f in tty2oledplus_update.sh tty2oledplus_settings.sh tty2oledplus_uninstall.sh; do
  [ -x "${FAT}/Scripts/${f}" ] || NEW="${NEW} ${f}"
done
ok "and the new ones are all there" "${NEW}" ""

section "installer: when it must change nothing"

# Damaged download: nothing may be touched, and the daemon comes back.
BAD="${TMP}/releases-bad"
rm -rf "${BAD}"; cp -r "${REL}" "${BAD}"
printf 'x' >> "${BAD}/latest/download/tty2oledplus.tar.gz"
set_installed_version "0.0.1b"
echo '# marker' >> "${INSTALL}/tty2oled.sh"
: > "${CALLS}"
T2OP_FAT="${FAT}" T2OP_URL="file://${BAD}" T2OP_INIT="${TMP}/fake-init" T2OP_FLASH="${TMP}/fake-flash" \
  T2OP_HWINF="HWLOLIN32;${VERSION};" bash "${ROOT}/tools/tty2oledplus_update.sh" > "${TMP}/out" 2>&1 </dev/null
RC="${?}"
ok "a damaged download fails" "${RC}" "1"
ok "saying so" "$(said 'does not match its checksum')" "1"
ok "with the installed scripts untouched" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"
ok "and the daemon running again" "$(running)" "running"

T2OP_FAT="${FAT}" T2OP_URL="file://${TMP}/nowhere" T2OP_INIT="${TMP}/fake-init" T2OP_FLASH="${TMP}/fake-flash" \
  bash "${ROOT}/tools/tty2oledplus_update.sh" > "${TMP}/out" 2>&1 </dev/null
ok "an unreachable release fails" "${?}" "1"
ok "with the installed scripts untouched" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"

# Upstream's daemon on the same port: refuse before stopping anything.
mkdir -p "${FAT}/tty2oled"
printf '#!/bin/bash\nsleep 30\n' > "${FAT}/tty2oled/tty2oled.sh"
chmod +x "${FAT}/tty2oled/tty2oled.sh"
"${FAT}/tty2oled/tty2oled.sh" &
UPSTREAM=$!
sleep 0.3
T2OP_HWINF="HWLOLIN32;0.1;" install; RC="${?}"
kill "${UPSTREAM}" 2>/dev/null; wait "${UPSTREAM}" 2>/dev/null
ok "a running upstream daemon is refused" "${RC}" "1"
ok "and named" "$(said 'Upstream tty2oled is installed')" "1"
ok "before our daemon is touched" "$(grep -c 'init stop' "${CALLS}")" "0"
ok "or anything installed" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"

# Installed but not running is refused too: its boot hook would start it
# beside ours at the next reboot. The init script alone is enough to count.
rm -f "${FAT}/tty2oled/tty2oled.sh"
touch "${FAT}/tty2oled/S60tty2oled"
: > "${CALLS}"
T2OP_HWINF="HWLOLIN32;0.1;" install; RC="${?}"
ok "an installed upstream is refused, running or not" "${RC}" "1"
ok "saying they do not run side by side" "$(said 'not made to run side by side')" "1"
ok "and how to remove it" "$(said "rm -rf ${FAT}/tty2oled ")" "1"
ok "before our daemon is touched" "$(grep -c 'init stop' "${CALLS}")" "0"
ok "or anything installed" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"
ok "and upstream's files are left where they are" "$([ -e "${FAT}/tty2oled/S60tty2oled" ] && echo kept)" "kept"
rm -rf "${FAT}/tty2oled"

# Something else holding the display. /tmp/tty2oled_sleep is a mutex on the
# serial port - MiSTer SAM takes it for a whole attract session and drives the
# panel itself - and our daemon standing aside is not enough here: this script
# asks the display its version and may then reflash it. A flash landing while
# another program is mid-write is the one failure in this script that needs a
# USB cable and a workstation to undo.
#
# The path comes out of the installed ini rather than a literal, so the fake
# install names one inside the sandbox: the suite must not depend on - or
# create - a file in the real /tmp.
SLEEPY="${TMP}/claimed_sleep"
sed -i "s|^SLEEPFILE=.*|SLEEPFILE=\"${SLEEPY}\"|" "${INSTALL}/tty2oled-system.ini"
: > "${SLEEPY}"
T2OP_HWINF="HWLOLIN32;0.1;" install; RC="${?}"
rm -f "${SLEEPY}"
sed -i 's|^SLEEPFILE=.*|SLEEPFILE="/tmp/tty2oled_sleep"|' "${INSTALL}/tty2oled-system.ini"
ok "a claimed display is refused" "${RC}" "1"
ok "saying what has it" "$(said 'Something else has the display')" "1"
ok "reading the path from the ini, not a literal" "$(said "${SLEEPY}")" "2"
ok "before our daemon is touched" "$(grep -c 'init stop' "${CALLS}")" "0"
ok "and before the display is flashed" "$(grep -c 'flash' "${CALLS}")" "0"
ok "or anything installed" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"

section "installer: a pinned version"

set_installed_version "0.0.1b"
rm -rf "${REL}/latest"
T2OP_HWINF="HWLOLIN32;${VERSION};" install --version "v${VERSION}"; RC="${?}"
ok "--version installs from that release's own path" "${RC}" "0"
ok "and says which" "$(said "version ${VERSION}")" "1"
mkdir -p "${REL}/latest"; cp -r "${D}" "${REL}/latest/download"

section "starter: tty2oledplus_install.sh from the Scripts menu"

# Run the way Main runs it: by its full path out of Scripts.
starter() {
  : > "${CALLS}"
  cp "${ROOT}/tools/tty2oledplus_install.sh" "${FAT}/Scripts/"
  T2OP_FAT="${FAT}" T2OP_URL="file://${1}" T2OP_INIT="${TMP}/fake-init" \
  T2OP_FLASH="${TMP}/fake-flash" T2OP_HWINF="HWLOLIN32;0.3.9b;" \
    bash "${FAT}/Scripts/tty2oledplus_install.sh" > "${TMP}/out" 2>&1 </dev/null
}

fresh_mister
starter "${REL}"; RC="${?}"
ok "a first install from the starter succeeds" "${RC}" "0"
ok "installing the release" "$(sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini")" "${VERSION}"
ok "flashing the display" "$(flashed)" "tty2oledplus-lolin32.bin chip=esp32 port=free"
ok "wiring the boot hook" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"
ok "leaving the updater in its place" "$(yesno test -x "${FAT}/Scripts/tty2oledplus_update.sh")" "yes"
ok "and removing itself" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_install.sh")" "no"
ok "saying so" "$(said 'removed itself')" "1"
ok "no staging directory is left in /tmp" "$(ls -d /tmp/tty2oledplus-start.* 2>/dev/null | wc -l | tr -d ' ')" "0"

rm -rf "${BAD}"; cp -r "${REL}" "${BAD}"
printf '# tampered\n' >> "${BAD}/latest/download/tty2oledplus_update.sh"
fresh_mister
starter "${BAD}"; RC="${?}"
ok "a damaged installer is refused" "${RC}" "1"
ok "saying so" "$(said 'does not match')" "1"
ok "before it runs" "$(yesno test -e "${INSTALL}")" "no"
ok "and the starter stays, to try again" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_install.sh")" "yes"

fresh_mister
mkdir -p "${FAT}/tty2oled"; touch "${FAT}/tty2oled/S60tty2oled"
starter "${REL}"; RC="${?}"
ok "an installer that refuses fails the starter" "${RC}" "1"
ok "which stays in Scripts" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_install.sh")" "yes"
rm -rf "${FAT}/tty2oled"

starter "${TMP}/nowhere"; RC="${?}"
ok "an unreachable release fails the starter" "${RC}" "1"
ok "saying where it looked" "$(said 'Is the MiSTer online')" "1"

uninstall() {
  : > "${CALLS}"
  T2OP_FAT="${FAT}" T2OP_INIT="${TMP}/fake-init" \
    bash "${FAT}/Scripts/tty2oledplus_uninstall.sh" --yes "$@" > "${TMP}/out" 2>&1 </dev/null
}

section "installer: MiSTer.ini's log_file_entry"

misterini() {  # misterini <contents, or "none">
  rm -rf "${FAT}"; mkdir -p "${FAT}/linux" "${FAT}/Scripts"
  printf '#!/bin/sh\necho mister\n' > "${FAT}/linux/user-startup.sh"
  rm -f "${STATE}"
  if [ "$1" = "none" ]; then rm -f "${FAT}/MiSTer.ini"; else printf '%s' "$1" > "${FAT}/MiSTer.ini"; fi
}
state() { sed -n "s/^${1:-action}=//p" "${INSTALL}/.misterini.state" 2>/dev/null; }

# Missing: the line goes inside [MiSTer], not at the end of the file, where a
# per-core section would own it and it would do nothing.
misterini '[MiSTer]
video_mode=8

[NES]
video_mode=9
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
ok "a missing setting is added" "$(grep -c '^log_file_entry=1$' "${FAT}/MiSTer.ini")" "1"
ok "on the first line of the [MiSTer] section" "$(sed -n '2p' "${FAT}/MiSTer.ini")" "log_file_entry=1"
ok "the rest of the file is untouched" "$(grep -c '^video_mode=9$' "${FAT}/MiSTer.ini")" "1"
ok "and it is recorded as ours" "$(state)" "added"
ok "with a word about rebooting" "$(said 'Reboot for it')" "1"

# A second run must not re-record: the setting is 1 now because we set it.
T2OP_HWINF="HWLOLIN32;${VERSION};" install --force
ok "a later update leaves the record alone" "$(state)" "added"
ok "and does not add it twice" "$(grep -c '^log_file_entry=1$' "${FAT}/MiSTer.ini")" "1"

# Already set: nothing to do, and nothing to undo later.
misterini '[MiSTer]
log_file_entry=1
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
ok "one already set is left alone" "$(cat "${FAT}/MiSTer.ini")" "$(printf '[MiSTer]\nlog_file_entry=1')"
ok "and recorded as none of our doing" "$(state)" "present"

# Set to something else: the value changes, the line is kept for later.
misterini '[MiSTer]
log_file_entry=0     ; off by default
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
ok "a setting of 0 is turned on" "$(grep -c '^log_file_entry=1' "${FAT}/MiSTer.ini")" "1"
ok "keeping the comment after it" "$(grep -c 'off by default' "${FAT}/MiSTer.ini")" "1"
ok "and the old line is recorded" "$(state line)" "log_file_entry=0     ; off by default"

# No MiSTer.ini at all.
misterini none
T2OP_HWINF="HWLOLIN32;${VERSION};" install
ok "a missing MiSTer.ini is created" "$(cat "${FAT}/MiSTer.ini")" "$(printf '[MiSTer]\nlog_file_entry=1')"
ok "and recorded as created" "$(state)" "created"

section "uninstaller: MiSTer.ini goes back as it was found"

# Added by us: the line goes, the file stays, everything else stays.
misterini '[MiSTer]
video_mode=8
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
uninstall
ok "our line is removed" "$(grep -c 'log_file_entry' "${FAT}/MiSTer.ini")" "0"
ok "the file stays" "$(cat "${FAT}/MiSTer.ini")" "$(printf '[MiSTer]\nvideo_mode=8')"

# Changed by us: the old line comes back verbatim.
misterini '[MiSTer]
log_file_entry=0     ; off by default
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
uninstall
ok "the old line comes back" "$(cat "${FAT}/MiSTer.ini")" \
   "$(printf '[MiSTer]\nlog_file_entry=0     ; off by default')"

# Already set before us: untouched, both ways.
misterini '[MiSTer]
log_file_entry=1
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
uninstall
ok "a setting that was not ours is left" "$(grep -c '^log_file_entry=1$' "${FAT}/MiSTer.ini")" "1"
ok "and said so" "$(said 'leaving it alone')" "1"

# Created by us and untouched since: the file goes with the install.
misterini none
T2OP_HWINF="HWLOLIN32;${VERSION};" install
uninstall
ok "a MiSTer.ini we created is removed" "$(yesno test -e "${FAT}/MiSTer.ini")" "no"

# Created by us but written to since: only our line goes.
misterini none
T2OP_HWINF="HWLOLIN32;${VERSION};" install
printf 'video_mode=8\n' >> "${FAT}/MiSTer.ini"
uninstall
ok "one we created but they edited is kept" "$(yesno test -e "${FAT}/MiSTer.ini")" "yes"
ok "less our line" "$(cat "${FAT}/MiSTer.ini")" "$(printf '[MiSTer]\nvideo_mode=8')"

# Changed by the user since: their setting wins over our record.
misterini '[MiSTer]
video_mode=8
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
sed -i 's/^log_file_entry=1$/log_file_entry=0/' "${FAT}/MiSTer.ini"
uninstall
ok "a setting they have since changed is left alone" \
   "$(grep -c '^log_file_entry=0$' "${FAT}/MiSTer.ini")" "1"

# A dry run says what it would do and does none of it.
misterini '[MiSTer]
video_mode=8
'
T2OP_HWINF="HWLOLIN32;${VERSION};" install
uninstall --dry-run
ok "a dry run leaves MiSTer.ini alone" "$(grep -c '^log_file_entry=1$' "${FAT}/MiSTer.ini")" "1"
ok "saying what it would do" "$(said 'would put')" "1"

section "uninstaller: leaving nothing behind"

# A real install first, so the uninstaller has the real thing to remove.
fresh_mister
echo "# somebody else's line" >> "${FAT}/linux/user-startup.sh"
T2OP_HWINF="HWLOLIN32;0.3.9b;" install
ok "the installer leaves the uninstaller in the Scripts menu" \
   "$(yesno test -x "${FAT}/Scripts/tty2oledplus_uninstall.sh")" "yes"
# And in the install folder as well, which is what S60tty2oled places it from
# on every start - the only way it reaches the menu of a MiSTer whose update
# was applied by an installer too old to know about it.
ok "and in the install folder, for S60tty2oled to place from" \
   "$(yesno test -e "${INSTALL}/tty2oledplus_uninstall.sh")" "yes"
ok "the two are the same file" \
   "$(cmp -s "${INSTALL}/tty2oledplus_uninstall.sh" "${FAT}/Scripts/tty2oledplus_uninstall.sh" && echo same)" "same"
BEFORE="$(cat "${FAT}/linux/user-startup.sh")"

uninstall --dry-run; RC="${?}"
ok "a dry run succeeds" "${RC}" "0"
ok "and changes nothing" "$(yesno test -d "${INSTALL}")" "yes"
ok "nor the boot hook" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"
ok "nor itself" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_uninstall.sh")" "yes"
ok "but says what would go" "$(grep -c "would remove ${INSTALL}\$" "${TMP}/out")" "1"

echo running > "${STATE}"
uninstall; RC="${?}"
ok "the uninstall succeeds" "${RC}" "0"
ok "the install folder is gone" "$(yesno test -e "${INSTALL}")" "no"
ok "the daemon was stopped first" "$(grep -c 'init stop' "${CALLS}")" "1"
ok "and not started again" "$(running)" "stopped"
ok "the updater is gone from Scripts" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_update.sh")" "no"
ok "and the uninstaller removed itself" "$(yesno test -e "${FAT}/Scripts/tty2oledplus_uninstall.sh")" "no"
ok "the boot hook is gone" "$(grep -c tty2oledplus "${FAT}/linux/user-startup.sh")" "0"
ok "with the comment the installer wrote above it" "$(grep -c 'Startup tty2oled' "${FAT}/linux/user-startup.sh")" "0"
ok "and everybody else's lines untouched" "$(grep -c "somebody else's line" "${FAT}/linux/user-startup.sh")" "1"
ok "user-startup.sh keeps its shebang" "$(head -n1 "${FAT}/linux/user-startup.sh")" "#!/bin/sh"
ok "and is still executable" "$(yesno test -x "${FAT}/linux/user-startup.sh")" "yes"
ok "it says the firmware stays on the display" "$(said 'firmware stays')" "1"

# Nothing left to remove: say so rather than half-run. Run from the repo,
# since the installed copy has removed itself - and check that a copy run from
# outside the Scripts menu does not delete itself.
: > "${CALLS}"
T2OP_FAT="${FAT}" T2OP_INIT="${TMP}/fake-init" \
  bash "${ROOT}/tools/tty2oledplus_uninstall.sh" --yes > "${TMP}/out" 2>&1 </dev/null
RC="${?}"
ok "the repo's own copy is never deleted" "$(yesno test -e "${ROOT}/tools/tty2oledplus_uninstall.sh")" "yes"
ok "a second run refuses" "${RC}" "1"
ok "saying it is not installed" "$(said 'not installed')" "1"

section "uninstaller: what it keeps when asked"

fresh_mister
T2OP_HWINF="HWLOLIN32;0.3.9b;" install
echo 'TTYDEV="/dev/ttyUSB1"   # mine' > "${INSTALL}/tty2oled-user.ini"
uninstall --keep-settings
ok "--keep-settings saves your ini" "$(cat "${FAT}/tty2oledplus-tty2oled-user.ini.saved")" 'TTYDEV="/dev/ttyUSB1"   # mine'
ok "and your core types" "$(yesno test -e "${FAT}/tty2oledplus-coretypes.ini.saved")" "yes"
ok "while the install still goes" "$(yesno test -e "${INSTALL}")" "no"

# Upstream's install is not ours to remove, whatever else we clean up.
fresh_mister
T2OP_HWINF="HWLOLIN32;0.3.9b;" install
mkdir -p "${FAT}/tty2oled"; touch "${FAT}/tty2oled/S60tty2oled"
uninstall
ok "upstream's install is left alone" "$(yesno test -e "${FAT}/tty2oled/S60tty2oled")" "yes"
ok "and its pid file, which may name its daemon" \
   "$(grep -c 'removed /run/tty2oled-daemon.pid' "${TMP}/out")" "0"
ok "and said so" "$(said 'is left alone')" "1"
rm -rf "${FAT}/tty2oled"

section "installer: reading the display's answer"

T2OP_LIB=yes . "${ROOT}/tools/tty2oledplus_update.sh"
hw() { parse_hwinf <<<"$1"; echo "${HW_BOARD}/${HW_VERSION}"; }
ok "a plain answer"                    "$(hw 'HWLOLIN32;0.4.1b;')"                       "lolin32/0.4.1b"
ok "behind stale acknowledgements"     "$(hw $'ttyack;ttyack;HWESP32DE;0.4.1b;\r\nttyack;')" "esp32de/0.4.1b"
ok "an S3"                             "$(hw 'HWESP32S3;0.5.0;')"                        "esp32s3/0.5.0"
ok "a build with no board is no board" "$(hw 'HWNONEXXX;0.4.1b;')"                       "/"
ok "silence is no board"               "$(hw '')"                                        "/"
ok "junk is no board"                  "$(hw 'garbage without separators')"              "/"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
