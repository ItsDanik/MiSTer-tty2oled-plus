#!/bin/bash
#
# tty2oled+ installer for the MiSTer's Scripts menu.
#
# Copy this file to the SD card's Scripts folder (/media/fat/Scripts) and run
# TTY2OLEDplus_Installer from the Scripts menu. It needs the MiSTer online.
#
# It is only a starter: it downloads the newest release's real installer,
# checks it against the release's SHA256SUMS and runs it, so a copy of this
# file downloaded long ago still installs the current release. When the
# install succeeds it deletes itself - the install puts update_tty2oledplus in
# the Scripts menu, which is the same installer, for every update after.
#
# Options are passed through to the installer (--board lolin32, --no-firmware,
# ...); see the top of tty2oledplus_installer.sh for the list.

REPO="ItsDanik/MiSTer-tty2oled-plus"

# Overridable for tests/test-installer.sh, which serves a release off local disk.
RELEASES="${T2OP_URL:-https://github.com/${REPO}/releases}"
CACERT="/etc/ssl/certs/cacert.pem"

say() { printf '\n==> %s\n' "$1"; }
die() { printf '\n*** %s\n' "$1" >&2; exit 1; }

# MiSTer's curl cannot verify GitHub's certificate without the bundle MiSTer
# ships, so it is named whenever it is there.
fetch() {  # fetch <asset> <dest>
  local ca=()
  [ -r "${CACERT}" ] && ca=(--cacert "${CACERT}")
  curl -fsSL --retry 3 --connect-timeout 15 "${ca[@]}" \
    -o "$2" "${RELEASES}/latest/download/$1"
}

# All in a function called on the last line: bash reads a script as it runs
# it, and this one deletes itself at the end.
main() {
  command -v curl >/dev/null 2>&1 || die "curl is missing - this does not look like a MiSTer."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is missing - this does not look like a MiSTer."

  local self rc want got
  # Not local: the EXIT trap runs after main has returned.
  TMPDIR_START="$(mktemp -d /tmp/tty2oledplus-start.XXXXXX)" || die "Could not create a folder in /tmp."
  trap 'rm -rf "${TMPDIR_START}"' EXIT
  local tmp="${TMPDIR_START}"

  say "Fetching the tty2oled+ installer"
  fetch SHA256SUMS "${tmp}/SHA256SUMS" && fetch tty2oledplus_installer.sh "${tmp}/installer.sh" \
    || die "Could not reach ${RELEASES}. Is the MiSTer online?"

  want="$(awk '$2 == "tty2oledplus_installer.sh" || $2 == "*tty2oledplus_installer.sh" { print $1 }' "${tmp}/SHA256SUMS")"
  got="$(sha256sum "${tmp}/installer.sh" | cut -d' ' -f1)"
  [ -n "${want}" ] && [ "${want}" = "${got}" ] \
    || die "The installer does not match the release's checksum - the download is damaged. Try again."

  bash "${tmp}/installer.sh" "$@"
  rc=$?

  # Replaced by update_tty2oledplus once that is in place. Only this file, by
  # name, and only after a successful run.
  self="$(readlink -f "$0" 2>/dev/null)"
  if [ "${rc}" -eq 0 ] && [ "$(basename "${self}")" = "TTY2OLEDplus_Installer.sh" ] \
     && [ -e "$(dirname "${self}")/update_tty2oledplus.sh" ]; then
    rm -f "${self}"
    say "TTY2OLEDplus_Installer has done its job and removed itself."
    printf '    Use update_tty2oledplus in the Scripts menu from now on.\n'
  fi
  return "${rc}"
}

main "$@"
