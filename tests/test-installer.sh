#!/bin/bash
#
# Tests for the release: tools/make-release.sh, which builds it, and
# tools/update_tty2oledplus.sh, which installs it on a MiSTer.
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
mkdir -p "${SRC}/index" "${SRC}/pics/GSC" "${SRC}/fw/fw-lolin32" "${SRC}/fw/fw-esp32s3" "${SRC}/fw/fw-tiny"
echo "00000000|Test Game|USA|1990|Test|Action|Test|" > "${SRC}/index/NES.idx"
echo "#define x 1" > "${SRC}/pics/GSC/NES.gsc"
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
ok "with version-free asset names, so latest/download finds them" \
   "$(cd "${D}" && ls | tr '\n' ' ')" \
   "SHA256SUMS TTY2OLEDplus_Installer.sh VERSION tty2oledplus-esp32s3.bin tty2oledplus-lolin32.bin tty2oledplus-pics.tar.gz tty2oledplus.tar.gz update_tty2oledplus.sh "
# GitHub compares asset names without case: TTY2OLEDplus_Installer.sh beside
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
ok "and the drawn icons" "$(printf '%s\n' "${LISTING}" | grep -c 'pics_pri/ICON/.*\.gsc')" "$(ls "${ROOT}"/pics_pri/ICON/*.gsc | wc -l | tr -d ' ')"
ok "everything unpacks under tty2oledplus/" "$(printf '%s\n' "${LISTING}" | grep -vc '^tty2oledplus/')" "0"
ok "the artwork is in its own archive" "$(tar tzf "${D}/tty2oledplus-pics.tar.gz" | grep -c 'tty2oledplus/pics/GSC/NES.gsc')" "1"
ok "the notes carry this version's changelog" \
   "$(head -n1 "${TMP}/notes.md" | grep -c .)" "1"
ok "and how to install it" "$(grep -c '^curl .*releases/latest/download/update_tty2oledplus.sh | bash$' "${TMP}/notes.md")" "1"
ok "including from the Scripts menu" "$(grep -c 'run \*\*TTY2OLEDplus_Installer\*\* from the Scripts' "${TMP}/notes.md")" "1"

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
    bash "${ROOT}/tools/update_tty2oledplus.sh" "$@" > "${TMP}/out" 2>&1 </dev/null
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
ok "the artwork pack is installed" "$(yesno test -f "${INSTALL}/pics/GSC/NES.gsc")" "yes"
ok "the display was flashed, once, with its own board's image" "$(flashed)" "tty2oledplus-lolin32.bin chip=esp32 port=free"
ok "with a board id found behind stale ttyacks" "$(said 'reported: lolin32, firmware 0.3.0b')" "1"
ok "the boot hook is added" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"
ok "the daemon is running at the end" "$(running)" "running"
ok "the updater is in the Scripts menu" "$(cmp -s "${FAT}/Scripts/update_tty2oledplus.sh" "${ROOT}/tools/update_tty2oledplus.sh" && echo same)" "same"
ok "and is executable" "$(yesno test -x "${FAT}/Scripts/update_tty2oledplus.sh")" "yes"
ok "no half-written updater is left behind" "$(ls -A "${FAT}/Scripts" | grep -c '\.new$')" "0"
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

rm "${INSTALL}/pics/GSC/NES.gsc"
T2OP_HWINF="HWLOLIN32;${VERSION};" install --pics
ok "--pics fetches the artwork again" "$(yesno test -f "${INSTALL}/pics/GSC/NES.gsc")" "yes"

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

section "installer: when it must change nothing"

# Damaged download: nothing may be touched, and the daemon comes back.
BAD="${TMP}/releases-bad"
rm -rf "${BAD}"; cp -r "${REL}" "${BAD}"
printf 'x' >> "${BAD}/latest/download/tty2oledplus.tar.gz"
set_installed_version "0.0.1b"
echo '# marker' >> "${INSTALL}/tty2oled.sh"
: > "${CALLS}"
T2OP_FAT="${FAT}" T2OP_URL="file://${BAD}" T2OP_INIT="${TMP}/fake-init" T2OP_FLASH="${TMP}/fake-flash" \
  T2OP_HWINF="HWLOLIN32;${VERSION};" bash "${ROOT}/tools/update_tty2oledplus.sh" > "${TMP}/out" 2>&1 </dev/null
RC="${?}"
ok "a damaged download fails" "${RC}" "1"
ok "saying so" "$(said 'does not match its checksum')" "1"
ok "with the installed scripts untouched" "$(grep -c '# marker' "${INSTALL}/tty2oled.sh")" "1"
ok "and the daemon running again" "$(running)" "running"

T2OP_FAT="${FAT}" T2OP_URL="file://${TMP}/nowhere" T2OP_INIT="${TMP}/fake-init" T2OP_FLASH="${TMP}/fake-flash" \
  bash "${ROOT}/tools/update_tty2oledplus.sh" > "${TMP}/out" 2>&1 </dev/null
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

section "installer: a pinned version"

set_installed_version "0.0.1b"
rm -rf "${REL}/latest"
T2OP_HWINF="HWLOLIN32;${VERSION};" install --version "v${VERSION}"; RC="${?}"
ok "--version installs from that release's own path" "${RC}" "0"
ok "and says which" "$(said "version ${VERSION}")" "1"
mkdir -p "${REL}/latest"; cp -r "${D}" "${REL}/latest/download"

section "starter: TTY2OLEDplus_Installer.sh from the Scripts menu"

# Run the way Main runs it: by its full path out of Scripts.
starter() {
  : > "${CALLS}"
  cp "${ROOT}/tools/TTY2OLEDplus_Installer.sh" "${FAT}/Scripts/"
  T2OP_FAT="${FAT}" T2OP_URL="file://${1}" T2OP_INIT="${TMP}/fake-init" \
  T2OP_FLASH="${TMP}/fake-flash" T2OP_HWINF="HWLOLIN32;0.3.9b;" \
    bash "${FAT}/Scripts/TTY2OLEDplus_Installer.sh" > "${TMP}/out" 2>&1 </dev/null
}

fresh_mister
starter "${REL}"; RC="${?}"
ok "a first install from the starter succeeds" "${RC}" "0"
ok "installing the release" "$(sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${INSTALL}/tty2oled-system.ini")" "${VERSION}"
ok "flashing the display" "$(flashed)" "tty2oledplus-lolin32.bin chip=esp32 port=free"
ok "wiring the boot hook" "$(grep -c "${INSTALL}/S60tty2oled" "${FAT}/linux/user-startup.sh")" "1"
ok "leaving the updater in its place" "$(yesno test -x "${FAT}/Scripts/update_tty2oledplus.sh")" "yes"
ok "and removing itself" "$(yesno test -e "${FAT}/Scripts/TTY2OLEDplus_Installer.sh")" "no"
ok "saying so" "$(said 'removed itself')" "1"
ok "no staging directory is left in /tmp" "$(ls -d /tmp/tty2oledplus-start.* 2>/dev/null | wc -l | tr -d ' ')" "0"

rm -rf "${BAD}"; cp -r "${REL}" "${BAD}"
printf '# tampered\n' >> "${BAD}/latest/download/update_tty2oledplus.sh"
fresh_mister
starter "${BAD}"; RC="${?}"
ok "a damaged installer is refused" "${RC}" "1"
ok "saying so" "$(said 'does not match')" "1"
ok "before it runs" "$(yesno test -e "${INSTALL}")" "no"
ok "and the starter stays, to try again" "$(yesno test -e "${FAT}/Scripts/TTY2OLEDplus_Installer.sh")" "yes"

fresh_mister
mkdir -p "${FAT}/tty2oled"; touch "${FAT}/tty2oled/S60tty2oled"
starter "${REL}"; RC="${?}"
ok "an installer that refuses fails the starter" "${RC}" "1"
ok "which stays in Scripts" "$(yesno test -e "${FAT}/Scripts/TTY2OLEDplus_Installer.sh")" "yes"
rm -rf "${FAT}/tty2oled"

starter "${TMP}/nowhere"; RC="${?}"
ok "an unreachable release fails the starter" "${RC}" "1"
ok "saying where it looked" "$(said 'Is the MiSTer online')" "1"

section "installer: reading the display's answer"

T2OP_LIB=yes . "${ROOT}/tools/update_tty2oledplus.sh"
hw() { parse_hwinf <<<"$1"; echo "${HW_BOARD}/${HW_VERSION}"; }
ok "a plain answer"                    "$(hw 'HWLOLIN32;0.4.1b;')"                       "lolin32/0.4.1b"
ok "behind stale acknowledgements"     "$(hw $'ttyack;ttyack;HWESP32DE;0.4.1b;\r\nttyack;')" "esp32de/0.4.1b"
ok "an S3"                             "$(hw 'HWESP32S3;0.5.0;')"                        "esp32s3/0.5.0"
ok "a build with no board is no board" "$(hw 'HWNONEXXX;0.4.1b;')"                       "/"
ok "silence is no board"               "$(hw '')"                                        "/"
ok "junk is no board"                  "$(hw 'garbage without separators')"              "/"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
