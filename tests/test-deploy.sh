#!/bin/bash
#
# Tests for deploy-mister.sh and the boot hook it installs.
#
# The deploy edits files on a machine that is not this one, so neither half can
# be run for real here. Instead:
#
#   boot hook     tools/tty2oled-boothook.sh is sourced as a library and run
#                 against fixture copies of /media/fat/linux/user-startup.sh.
#   the deploy    runs in full from a scratch copy of the repository, with
#                 ssh and scp replaced by fakes that record every call - so the
#                 order, the options and what reaches the MiSTer are all
#                 checked, and nothing leaves this machine.
#
#   ./tests/test-deploy.sh

set -u

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/deploy"
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

# ===========================================================================
# The boot hook
# ===========================================================================
BOOTHOOK_LIB=yes . "${ROOT}/tools/tty2oled-boothook.sh"

H="${TMP}/hook"; mkdir -p "${H}/upstream"
US="${H}/user-startup.sh"
TPL="${H}/_user-startup.sh"
INIT="/media/fat/tty2oledplus/S60tty2oled"
UPSTREAM="${H}/upstream/S60tty2oled"      # exists only when a test creates it
HOOKLINE="[ -e ${INIT} ] && ${INIT} \$1"

hook() { boothook "${US}" "${TPL}" "${INIT}" "${UPSTREAM}"; }
reset() { rm -f "${US}" "${TPL}" "${UPSTREAM}"; }

section "boot hook: creating user-startup.sh"

reset
printf '#!/bin/sh\n# MiSTer template\necho template\n' > "${TPL}"
OUT="$(hook)"
ok "made from the template when there is one" "$(sed -n '3p;$p' "${US}" | tr '\n' '|')" "# Startup tty2oled+|echo template|"
ok "hook straight under the shebang" "$(sed -n '4p' "${US}")" "${HOOKLINE}"
ok "shebang still first" "$(head -n1 "${US}")" "#!/bin/sh"
ok "the file is executable" "$(yesno test -x "${US}")" "yes"
ok "and it says so" "$(printf '%s' "${OUT}" | head -n1)" "created ${US}"

reset
hook >/dev/null
ok "made from nothing when there is no template" "$(head -n1 "${US}")" "#!/bin/sh"
ok "with the hook in it" "$(grep -cxF "${HOOKLINE}" "${US}")" "1"

# The '$1' is the point of the line: MiSTer calls user-startup.sh with
# start/stop, and the hook must pass it on rather than a value baked in now.
ok "the hook passes \$1 through literally" "$(grep -c '\$1$' "${US}")" "1"

section "boot hook: an existing file"

reset
printf '#!/bin/bash\nmount /mnt/nas\n/media/fat/Scripts/other.sh start\n' > "${US}"
BEFORE="$(tail -n +2 "${US}")"
hook >/dev/null
ok "hook goes above everything that was there" "$(sed -n '4p' "${US}")" "${HOOKLINE}"
ok "everything after the shebang is untouched" "$(tail -n +5 "${US}")" "${BEFORE}"

reset
printf 'mount /mnt/nas\n' > "${US}"
hook >/dev/null
ok "no shebang: the hook is the very top" "$(sed -n '2p' "${US}")" "${HOOKLINE}"
ok "and the old first line survives" "$(tail -n1 "${US}")" "mount /mnt/nas"

reset
printf '#!/bin/sh\necho hi\n' > "${US}"
hook >/dev/null; FIRST="$(cat "${US}")"
OUT="$(hook)"
ok "a second run changes nothing" "$(cat "${US}")" "${FIRST}"
ok "and says it is already there" "${OUT}" "boot hook already at the top of ${US}"
ok "no temporary file left behind" "$(ls "${H}" | grep -c '\.tty2oled\.')" "0"

section "boot hook: lines it must leave alone"

# Ours, but further down - the user may have put it there on purpose.
reset
{ printf '#!/bin/sh\n'; for i in 1 2 3 4 5 6; do echo "echo ${i}"; done; echo "${HOOKLINE}"; } > "${US}"
BEFORE="$(cat "${US}")"
OUT="$(hook)"
ok "our line lower down is not moved" "$(cat "${US}")" "${BEFORE}"
ok "it is reported instead" "$(printf '%s' "${OUT}" | head -n1)" "boot hook present in ${US}, but not at the top."

# Ours, commented out: switched off by hand. Re-adding it would switch it back
# on behind the user's back, and "already at the top" would be a lie.
reset
printf '#!/bin/sh\n# %s\n' "${HOOKLINE}" > "${US}"
BEFORE="$(cat "${US}")"
OUT="$(hook)"
ok "a commented-out hook is not re-enabled" "$(cat "${US}")" "${BEFORE}"
ok "and is reported as commented out" "$(printf '%s' "${OUT}" | head -n1)" "boot hook is commented out in ${US} - left alone, so the"

section "boot hook: an upstream install"

# The mistake upstream's own updater made: seeing "tty2oled" in the file and
# deciding the job was done. Upstream's line names another folder.
UPLINE="[ -e ${UPSTREAM} ] && ${UPSTREAM} \$1"
reset
printf '#!/bin/sh\n%s\n' "${UPLINE}" > "${US}"
OUT="$(hook)"
ok "an upstream hook does not count as ours" "$(grep -cxF "${HOOKLINE}" "${US}")" "1"
ok "and is kept" "$(grep -cxF "${UPLINE}" "${US}")" "1"
ok "no warning while upstream is not installed" "$(printf '%s' "${OUT}" | grep -c WARNING)" "0"

# Both installed and both hooked: two daemons on one serial port at boot.
reset
printf '#!/bin/sh\n%s\n' "${UPLINE}" > "${US}"
touch "${UPSTREAM}"
OUT="$(hook)"
ok "both active warns about the serial port" "$(printf '%s' "${OUT}" | grep -c WARNING)" "1"
ok "without touching upstream's line" "$(grep -cxF "${UPLINE}" "${US}")" "1"

reset
printf '#!/bin/sh\n# %s\n' "${UPLINE}" > "${US}"
touch "${UPSTREAM}"
OUT="$(hook)"
ok "a commented-out upstream hook is no conflict" "$(printf '%s' "${OUT}" | grep -c WARNING)" "0"

# ===========================================================================
# The deploy, against a fake MiSTer
# ===========================================================================

# A scratch copy of the repository, so the deploy's "newest merged.bin" can be
# a fake one without ever being the newest build in the real working copy.
REPO="${TMP}/repo"
mkdir -p "${REPO}/tools"
LIST="$("${ROOT}/tools/deploy-mister.sh" --dry-run 2>/dev/null | awk '$1 == "copy" {print $2}')"
for f in ${LIST} tools/deploy-mister.sh tools/manifest.sh coretypes.ini tty2oled-user.ini; do
  cp "${ROOT}/${f}" "${REPO}/${f}"
done

FAKEBIN="${TMP}/bin"; mkdir -p "${FAKEBIN}"
LOG="${TMP}/calls.log"
STDIN="${TMP}/stdin.captured"

# Each call becomes one line: the tool, its -o options, then its arguments,
# newlines folded so a multi-line remote command can still be grepped.
cat > "${FAKEBIN}/ssh" <<'FAKE'
#!/bin/bash
opts=""; host=""; cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) opts="${opts} $2"; shift 2 ;;
    -O) echo "SSH-CTL $2" >> "${FAKE_LOG}"; exit 0 ;;
    -t|-q) shift ;;
    *) if [ -z "${host}" ]; then host="$1"; else cmd="${cmd} $1"; fi; shift ;;
  esac
done
cmd="${cmd//$'\n'/ }"
echo "SSH [${opts# }] ${host}${cmd}" >> "${FAKE_LOG}"
case "${cmd}" in
  " true") [ "${FAKE_UNREACHABLE:-no}" = "yes" ] && exit 255 ;;
  *".ini ]"*) [ "${FAKE_HAS_DEFAULTS:-no}" = "yes" ] || exit 1 ;;
  *"/media/fat/tty2oled/"*) [ "${FAKE_UPSTREAM:-no}" = "yes" ] || exit 1 ;;
  *"bash -s"*) cat > "${FAKE_STDIN}" ;;
  *"tar -C"*) cat > /dev/null ;;
esac
exit 0
FAKE
cat > "${FAKEBIN}/scp" <<'FAKE'
#!/bin/bash
opts=""; args=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) opts="${opts} $2"; shift 2 ;;
    -q) shift ;;
    *) args="${args} $1"; shift ;;
  esac
done
echo "SCP [${opts# }]${args}" >> "${FAKE_LOG}"
FAKE
chmod +x "${FAKEBIN}/ssh" "${FAKEBIN}/scp"

export FAKE_LOG="${LOG}" FAKE_STDIN="${STDIN}"
export MISTER="root@fake-mister" REMOTE="/media/fat/tty2oledplus"
export TMPDIR="${TMP}/tmpdir"; mkdir -p "${TMPDIR}"

# Run the deploy from somewhere that is not the repo root, which is how it
# gets run from another workstation's shell history.
deploy() {
  : > "${LOG}"; rm -f "${STDIN}"
  ( cd "${TMP}" && PATH="${FAKEBIN}:${PATH}" "${REPO}/tools/deploy-mister.sh" "$@" ) \
    > "${TMP}/out" 2>&1 </dev/null
}
calls() { grep -c '' "${LOG}"; }

section "deploy: checks that run before the MiSTer is touched"

deploy --dry-run; RC="${?}"
ok "a dry run succeeds from outside the repo" "${RC}" "0"
ok "and makes no connection at all" "$(calls)" "0"
MISSING=""
for f in ${LIST}; do [ -f "${ROOT}/${f}" ] || MISSING="${MISSING} ${f}"; done
ok "every file it would copy exists" "${MISSING}" ""
ok "it would copy something" "$(yesno test -n "${LIST}")" "yes"

deploy --bogus; RC="${?}"
ok "an unknown option is a usage error" "${RC}" "2"
ok "before any connection" "$(calls)" "0"

deploy --firmware; RC="${?}"
ok "--firmware with nothing built fails" "${RC}" "1"
ok "before any connection" "$(calls)" "0"

# This one used to copy the scripts first and then give up - before the
# restart, so the old daemon carried on over new files on disk.
deploy --index; RC="${?}"
ok "--index with no index built fails" "${RC}" "1"
ok "before any connection" "$(calls)" "0"

mv "${REPO}/tty2oled-read.sh" "${TMP}/held"
deploy; RC="${?}"
mv "${TMP}/held" "${REPO}/tty2oled-read.sh"
ok "a file missing from the working copy fails" "${RC}" "1"
ok "before any connection" "$(calls)" "0"
ok "and names it" "$(grep -c 'tty2oled-read.sh is missing' "${TMP}/out")" "1"

FAKE_UNREACHABLE=yes deploy; RC="${?}"
ok "an unreachable MiSTer fails" "${RC}" "1"
ok "after only the connection test" "$(grep -c '^SCP' "${LOG}")" "0"
ok "and says how to give the address" "$(grep -c 'MISTER=root@' "${TMP}/out")" "1"

# Upstream installed on the MiSTer: stop before copying anything. The init
# script would refuse to start ours anyway, after the copy.
FAKE_UPSTREAM=yes deploy; RC="${?}"
ok "upstream installed on the MiSTer fails" "${RC}" "1"
ok "before anything is copied" "$(grep -c '^SCP' "${LOG}")" "0"
ok "or the daemon touched" "$(grep -c 'S60tty2oled \(stop\|start\|restart\)' "${LOG}")" "0"
ok "and says why and how to remove it" "$(grep -c 'not made to run side by side' "${TMP}/out")|$(grep -c 'rm -rf /media/fat/tty2oled ' "${TMP}/out")" "1|1"

section "deploy: scripts only"

FAKE_HAS_DEFAULTS=no deploy; RC="${?}"
ok "the deploy succeeds" "${RC}" "0"
ok "the first call only tests the connection" "$(sed -n '1p' "${LOG}" | sed 's/.*\] //')" "root@fake-mister true"

# One connection for the lot: every call rides on the same control socket.
ok "every ssh and scp shares one connection" \
   "$(grep -E '^(SSH|SCP) ' "${LOG}" | grep -vc 'ControlPath=')" "0"
ok "and it is closed at the end" "$(tail -n1 "${LOG}")" "SSH-CTL exit"
ok "its socket directory is cleaned up" "$(ls "${TMPDIR}" | wc -l | tr -d ' ')" "0"

SENT="$(grep '^SCP' "${LOG}" | head -n1)"
UNSENT=""
# The three menu entries go to both places, so they are checked separately
# below rather than against the install-folder list.
for f in ${LIST}; do
  case "${f}" in */tty2oledplus_update.sh|*/tty2oledplus_settings.sh|*/tty2oledplus_uninstall.sh) continue ;; esac
  case "${SENT}" in *" ${f}"*) ;; *) UNSENT="${UNSENT} ${f}" ;; esac
done
ok "every script and tool is sent" "${UNSENT}" ""
# Both places, and this pair of assertions used to say the opposite - that the
# menu scripts go to Scripts and NOT into the install folder. That was wrong,
# and the test pinned it: place_menu_scripts in S60tty2oled copies them from
# the install folder into Scripts on every daemon start, cmp first, so a deploy
# that put them only in Scripts had its own fresh copy overwritten by the older
# one still sitting in the install folder the moment it restarted the daemon.
# It went unnoticed because the release is packed the right way - make-release
# puts them in the install folder - so only a deploy ever reverted them, and
# only the copy in the menu, which nothing else reads.
for f in tty2oledplus_update.sh tty2oledplus_settings.sh tty2oledplus_uninstall.sh; do
  ok "${f} goes to the Scripts menu" \
     "$(grep -c "^SCP .*tools/${f} .*:/media/fat/Scripts/\$" "${LOG}")" "1"
  ok "and into the install folder, for place_menu_scripts to place from" \
     "$(grep '^SCP' "${LOG}" | grep -c "tools/${f} .*:/media/fat/tty2oledplus/")" "1"
done
ok "the default coretypes.ini goes to a fresh MiSTer" "$(grep -c '^SCP.* coretypes.ini ' "${LOG}")" "1"
# The daemon sources it, and a first deploy used to leave it missing.
ok "and so does a default tty2oled-user.ini" "$(grep -c '^SCP.* tty2oled-user.ini ' "${LOG}")" "1"
ok "the boot hook runs from the repo's own script" "$(cmp -s "${STDIN}" "${REPO}/tools/tty2oled-boothook.sh" && echo same)" "same"
ok "the daemon is restarted" "$(grep -c 'S60tty2oled restart' "${LOG}")" "1"
ok "and its health comes from the init script" "$(grep -c 'S60tty2oled status' "${LOG}")" "1"
# The regression this guards: the deploy checked the pid file by hand, and
# kept checking the old path after the init script moved to its own.
ok "no pid file is read directly" "$(grep -c '\.pid' "${LOG}")" "0"
ok "nothing is flashed" "$(grep -c 'flash-mister.sh"*$' "${LOG}")" "0"

FAKE_HAS_DEFAULTS=yes deploy
ok "an edited coretypes.ini is kept" "$(grep -c '^SCP.* coretypes.ini ' "${LOG}")" "0"
ok "and the user's own settings are never overwritten" "$(grep -c '^SCP.*tty2oled-user.ini' "${LOG}")" "0"

section "deploy: firmware and artwork"

mkdir -p "${REPO}/MiSTer_SSD1322_USB/build-out-lolin32"
: > "${REPO}/MiSTer_SSD1322_USB/build-out-lolin32/MiSTer_SSD1322_USB.ino.merged.bin"
deploy --flash; RC="${?}"
ok "--flash succeeds" "${RC}" "0"
ok "the firmware is sent" "$(grep -c '^SCP.*merged.bin ' "${LOG}")" "1"
ok "and flashed" "$(grep -c 'flash-mister.sh$' "${LOG}")" "1"
ok "after the scripts it runs with are in place" \
   "$(awk '/^SCP.*tty2oled.sh /{s=NR} /flash-mister.sh$/{f=NR} END{print (s && f > s) ? "yes" : "no"}' "${LOG}")" "yes"
ok "with no restart of its own to undo it" "$(grep -c 'S60tty2oled restart' "${LOG}")" "0"

mkdir -p "${REPO}/pics/GSC"; echo 00 > "${REPO}/pics/GSC/NES.gsc"
deploy --pics; RC="${?}"
ok "--pics succeeds" "${RC}" "0"
ok "the pack goes as one tar stream" "$(grep -c 'tar -C /media/fat/tty2oledplus --no-same-owner -xzf -' "${LOG}")" "1"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
