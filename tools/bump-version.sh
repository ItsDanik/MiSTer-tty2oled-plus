#!/bin/bash
#
# One version for the whole project - scripts and firmware together.
#
#   ./tools/bump-version.sh              # 0.4.0b -> 0.4.1b
#   ./tools/bump-version.sh --set 0.5.0b # ...or say it outright
#   ./tools/bump-version.sh --release    # 0.4.1b -> 0.4.1, drop the beta mark
#   ./tools/bump-version.sh --check      # every copy matches VERSION?
#
# VERSION at the repo root is the source of truth. Two files need the number
# as a literal and cannot read it from there:
#
#   tty2oled-system.ini                        TTY2OLED_VERSION="..."
#   MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino  #define BuildVersion "..."
#
# so this writes both, and --check proves they still agree. The daemon reports
# both its own version and the firmware's at startup and complains when they
# differ, which is the whole point of moving them together: a display showing
# stale metadata is then one line in /tmp/tty2oled away from being explained.
#
# Bump on every push, even when only one side changed. A build where the two
# numbers differ is a build nobody can reason about.

set -eu

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
VFILE="${REPO}/VERSION"
INI="${REPO}/tty2oled-system.ini"
INO="${REPO}/MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino"

# major.minor.patch, with an optional one-letter pre-release mark: 0.4.0b.
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$'

die() { echo "bump-version: $*" >&2; exit 1; }

[ -r "${VFILE}" ] || die "no VERSION file at ${VFILE}"
CURRENT="$(tr -d ' \t\n\r' < "${VFILE}")"
[[ "${CURRENT}" =~ ${VERSION_RE} ]] || die "VERSION holds '${CURRENT}', which is not major.minor.patch[mark]"

MODE="bump"
WANT=""
while [ "${#}" -gt 0 ]; do
  case "${1}" in
    --check)   MODE="check" ;;
    --release) MODE="release" ;;
    --set)     MODE="set"; shift; WANT="${1:-}" ;;
    --set=*)   MODE="set"; WANT="${1#--set=}" ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown option: ${1}" ;;
  esac
  shift
done

# The version as it is written in each file, or the empty string if the line
# this expects is not there any more.
ini_version() { sed -n 's/^TTY2OLED_VERSION="\(.*\)".*/\1/p' "${INI}" | head -n1; }
ino_version() { sed -n 's/^#define BuildVersion "\([^"]*\)".*/\1/p' "${INO}" | head -n1; }

if [ "${MODE}" = "check" ]; then
  rc=0
  for pair in "tty2oled-system.ini:$(ini_version)" \
              "MiSTer_SSD1322_USB.ino:$(ino_version)"; do
    file="${pair%%:*}"; got="${pair#*:}"
    if [ -z "${got}" ]; then
      echo "MISSING  ${file} has no version line" >&2; rc=1
    elif [ "${got}" != "${CURRENT}" ]; then
      echo "MISMATCH ${file} says ${got}, VERSION says ${CURRENT}" >&2; rc=1
    else
      printf 'ok       %-26s %s\n' "${file}" "${got}"
    fi
  done
  [ "${rc}" = "0" ] && printf 'ok       %-26s %s\n' "VERSION" "${CURRENT}"
  exit "${rc}"
fi

case "${MODE}" in
  bump)
    base="${CURRENT%%[a-z]}"
    mark="${CURRENT#"${base}"}"
    patch="${base##*.}"
    WANT="${base%.*}.$((patch + 1))${mark}"
    ;;
  release)
    WANT="${CURRENT%%[a-z]}"
    [ "${WANT}" = "${CURRENT}" ] && die "${CURRENT} is already a release"
    ;;
  set)
    [ -n "${WANT}" ] || die "--set needs a version"
    ;;
esac

[[ "${WANT}" =~ ${VERSION_RE} ]] || die "'${WANT}' is not major.minor.patch[mark]"

printf '%s\n' "${WANT}" > "${VFILE}"
# The ini line and the sketch's #define, rewritten in place. Anchored at the
# start of the line so a mention in a comment cannot be hit by accident.
sed -i "s|^TTY2OLED_VERSION=\".*\"|TTY2OLED_VERSION=\"${WANT}\"|" "${INI}"
sed -i "s|^#define BuildVersion \"[^\"]*\"|#define BuildVersion \"${WANT}\"|" "${INO}"

echo "${CURRENT} -> ${WANT}"
REPO="${REPO}" "$0" --check
echo
echo "Then:"
echo "    add a CHANGELOG.md entry for ${WANT}"
echo "    ./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32"
echo "    ./tools/deploy-mister.sh --firmware --flash"
echo "    git tag -a v${WANT} -m \"tty2oled+ ${WANT}\""
