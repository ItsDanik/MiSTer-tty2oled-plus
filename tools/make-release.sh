#!/bin/bash
#
# Assemble the files a GitHub release carries, into dist/.
#
#   ./tools/make-release.sh                        # firmware from MiSTer_SSD1322_USB/build-out-*
#   ./tools/make-release.sh --firmware fw/         # or from any tree of *.merged.bin
#   ./tools/make-release.sh --tag v0.4.1b          # and insist the tag matches VERSION
#   ./tools/make-release.sh --notes notes.md       # also write the release notes
#
# --index DIR and --pics DIR take the title index and the artwork pack from
# somewhere other than titleindex/ and pics/; the tests use small ones.
# --config FILE is the settings utility's ARM binary, when it is not where
# tools/build-config.sh leaves it.
#
# CI runs this on a tag push; it runs the same way here, so a release can be
# looked at before anything is published.
#
# The asset names carry no version. GitHub serves the newest release's assets
# at /releases/latest/download/<name>, so with fixed names the installer finds
# the latest release without asking the API or parsing JSON on the MiSTer -
# and the version it is getting is the VERSION asset.
#
#   VERSION                     the version, one line
#   SHA256SUMS                  checksums of every other asset
#   tty2oledplus.tar.gz         scripts, tools, the settings utility, defaults,
#                               icons, title index
#   tty2oledplus-pics.tar.gz    the artwork pack, separate: it is 12MB and
#                               rarely changes, so updates skip it
#   tty2oledplus-<board>.bin    merged firmware, one per board built
#   tty2oledplus_update.sh      the installer itself, which the launcher runs as Update
#   tty2oledplus_install.sh     the starter a user drops into Scripts; it
#                               fetches and runs the installer above
#
# Both archives unpack to tty2oledplus/, the install folder's own name.

set -euo pipefail

cd "$(dirname "${0}")/.."

OUT="dist"
FWDIR=""
TAG=""
NOTES=""
INDEX="titleindex"
PICS="pics"
CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)      OUT="$2"; shift 2 ;;
    --firmware) FWDIR="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    --notes)    NOTES="$2"; shift 2 ;;
    --index)    INDEX="$2"; shift 2 ;;
    --pics)     PICS="$2"; shift 2 ;;
    --config)   CONFIG="$2"; shift 2 ;;
    -h|--help)  sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "make-release: $1" >&2; exit 1; }
say() { printf '==> %s\n' "$1"; }

VERSION="$(cat VERSION)"

# --- The things a release must not go out without -------------------------
./tools/bump-version.sh --check >/dev/null \
  || die "the version copies disagree - run ./tools/bump-version.sh --check"
if [ -n "${TAG}" ] && [ "${TAG}" != "v${VERSION}" ]; then
  die "tag ${TAG} is not v${VERSION}, which is what VERSION says"
fi
# Step 2 of the release ritual. A release whose notes are empty tells whoever
# installs it nothing about what they are installing.
CHANGES="$(awk -v v="${VERSION}" '
  $1 == "##" { if (on) exit; on = ($2 == v); next }
  on && (started || NF) { started = 1; print }' CHANGELOG.md)"
[ -n "$(printf '%s' "${CHANGES}" | tr -d '[:space:]')" ] \
  || die "CHANGELOG.md has no section for ${VERSION}"
ls "${INDEX}"/*.idx >/dev/null 2>&1 \
  || die "no ${INDEX}/*.idx - run ./tools/build-title-index.sh first"
[ -d "${PICS}" ] || die "no ${PICS}/ - the artwork pack is part of every release"

. tools/manifest.sh

rm -rf "${OUT}"
mkdir -p "${OUT}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

# Reproducible archives: same inputs, same bytes. Names sorted, owners and
# times fixed, and gzip told not to stamp the time in its header.
EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
pack() {  # pack <archive> <dir under STAGE>
  tar -C "${STAGE}" --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@${EPOCH}" -cf - "$2" | gzip -9n > "$1"
}

# --- Scripts, tools, defaults, icons, index --------------------------------
say "Packing tty2oledplus.tar.gz"
P="${STAGE}/tty2oledplus"
mkdir -p "${P}/titleindex" "${P}/pics/icon" "${P}/pics/banner"
for f in ${MANIFEST_FILES} ${MANIFEST_DEFAULTS}; do cp -p "${f}" "${P}/"; done
for f in ${MANIFEST_TOOLS} ${MANIFEST_APPS} ${MANIFEST_MENU}; do cp -p "${f}" "${P}/$(basename "${f}")"; done
# The settings utility, cross-built for the MiSTer. Byte 18 of an ELF is its
# machine, 40 for ARM: the host's own build here would install and never run.
CONFIG="${CONFIG:-${MANIFEST_BIN}}"
[ -s "${CONFIG}" ] || die "no ${CONFIG} - build it with ./tools/build-config.sh, or pass --config"
[ "$(od -An -c -N4 "${CONFIG}" | tr -d ' ')" = '177ELF' ] \
  && [ "$(od -An -tu1 -j18 -N1 "${CONFIG}" | tr -d ' ')" = "40" ] \
  || die "${CONFIG} is not an ARM binary - build it with ./tools/build-config.sh"
cp -p "${CONFIG}" "${P}/$(basename "${MANIFEST_BIN}")"
chmod 755 "${P}/$(basename "${MANIFEST_BIN}")"
cp -p "${INDEX}"/*.idx "${P}/titleindex/"
cp -p "${PICS}/icon"/*.gsc "${P}/pics/icon/"
# The core banners ride here too (0.8.3b), as the icons do: every updater
# copies this archive's pics/ into the install, so a banner a release adds
# reaches a MiSTer on its next Update. They used to be in the pack alone,
# which is fetched only when it is missing - the DVD core's banner reached
# nobody who updated to 0.8.2b.
cp -p "${PICS}/banner"/*.gsc "${P}/pics/banner/"
pack "${OUT}/tty2oledplus.tar.gz" tty2oledplus

# The arcade wheel pack, and the core banners again - so installing the pack
# still replaces pics/banner whole, and a picture a release has dropped goes
# from the card. pics/icon ships in the scripts archive above only. pics/user
# ships in neither: it is the user's own and no release may write into it.
say "Packing tty2oledplus-pics.tar.gz"
[ -s "${PICS}/arcade/wheels.bin" ] && [ -s "${PICS}/arcade/wheels.idx" ] \
  || die "no ${PICS}/arcade/wheels.bin and wheels.idx - build them with tools/wheels2gsc.py and tools/gscpack.py"
rm -rf "${P}"
mkdir -p "${P}/pics/user" "${P}/pics/arcade"
cp -rp "${PICS}/banner" "${P}/pics/banner"
cp -p "${PICS}/arcade/wheels.bin" "${PICS}/arcade/wheels.idx" "${P}/pics/arcade/"
pack "${OUT}/tty2oledplus-pics.tar.gz" tty2oledplus

# --- Firmware --------------------------------------------------------------
# One merged image per board. The board is the suffix of the directory the
# image sits in: build-out-lolin32 locally, fw-lolin32 as CI downloads it.
say "Collecting firmware"
FOUND=0
while IFS= read -r bin; do
  board="$(basename "$(dirname "${bin}")")"
  board="${board##*-}"
  case "${board}" in lolin32|esp32de|esp32s3) ;; *) continue ;; esac
  # Same floor as flash-mister.sh: a merged image is around 1MB, and anything
  # tiny is a failed build that would leave a display unbootable.
  [ "$(wc -c < "${bin}")" -gt 200000 ] || die "${bin} is too small to be a firmware image"
  cp "${bin}" "${OUT}/tty2oledplus-${board}.bin"
  echo "    ${board}: ${bin}"
  FOUND=$((FOUND + 1))
done < <(find "${FWDIR:-MiSTer_SSD1322_USB}" -name 'MiSTer_SSD1322_USB.ino.merged.bin' | sort)
[ "${FOUND}" -gt 0 ] || die "no firmware found - build it first, or pass --firmware"

# --- The rest --------------------------------------------------------------
cp tools/tty2oledplus_update.sh tools/tty2oledplus_install.sh "${OUT}/"

printf '%s\n' "${VERSION}" > "${OUT}/VERSION"
( cd "${OUT}" && sha256sum -- * | grep -v ' SHA256SUMS$' > SHA256SUMS )

if [ -n "${NOTES}" ]; then
  {
    printf '%s\n\n' "${CHANGES}"
    cat <<EON
### Install or update

Download **tty2oledplus_install.sh** below, copy it to the \`Scripts\` folder
on the MiSTer's SD card, and run **tty2oledplus_install** from the Scripts
menu. Or on the MiSTer, over SSH:

\`\`\`sh
curl -fsSL --cacert /etc/ssl/certs/cacert.pem https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash
\`\`\`

After that the Scripts menu has one entry, **tty2oledplus**: Settings to
change what the display shows, Update for the next release, and Uninstall to
remove it all again.

### Support

If you enjoy this project, you can support my work on [Patreon](https://www.patreon.com/itsdanik).
EON
  } > "${NOTES}"
fi

say "Release ${VERSION} in ${OUT}/:"
( cd "${OUT}" && ls -l | tail -n +2 | awk '{printf "    %-28s %s\n", $9, $5}' )
