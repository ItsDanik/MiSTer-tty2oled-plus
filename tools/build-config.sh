#!/usr/bin/env bash
#
# Build tty2oledplus_config, the settings utility that draws on the MiSTer's
# framebuffer (tools/settings-ui/config.c).
#
#   ./tools/build-config.sh           # for the MiSTer: ARMv7, static
#   ./tools/build-config.sh --host    # for this machine, to run against a file
#
# The MiSTer has no compiler, so its binary is cross-built here and in CI and
# shipped in the scripts archive - make-release.sh refuses to pack without it.
# Static, so the MiSTer's libc version is nobody's business. The output is
# tools/settings-ui/build/tty2oledplus_config (gitignored, like the firmware);
# --host goes to build/host/ and is what tests/test-config.sh runs.
#
# Needs arm-linux-gnueabihf-gcc (Debian/Ubuntu: gcc-arm-linux-gnueabihf), or
# CROSS_CC= naming another; with neither, and Docker here, it builds in a
# Debian container.

set -euo pipefail

cd "$(dirname "${0}")/.."

SRC="tools/settings-ui/config.c"
OUT="tools/settings-ui/build"
FLAGS="-std=c11 -O2 -Wall -Wextra -Werror"
CROSS_CC="${CROSS_CC:-arm-linux-gnueabihf-gcc}"

die() { echo "build-config: $1" >&2; exit 1; }

if [ "${1:-}" = "--host" ]; then
  command -v "${CC:-gcc}" >/dev/null 2>&1 || die "no ${CC:-gcc}"
  mkdir -p "${OUT}/host"
  # shellcheck disable=SC2086
  "${CC:-gcc}" ${FLAGS} -g -fsanitize=address,undefined -o "${OUT}/host/tty2oledplus_config" "${SRC}"
  echo "built ${OUT}/host/tty2oledplus_config"
  exit 0
fi

mkdir -p "${OUT}"
if command -v "${CROSS_CC}" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  "${CROSS_CC}" ${FLAGS} -static -s -o "${OUT}/tty2oledplus_config" "${SRC}"
elif command -v docker >/dev/null 2>&1; then
  echo "No ${CROSS_CC} here - building in a Debian container."
  docker run --rm -v "${PWD}:/src" -w /src debian:bookworm-slim sh -c '
    set -e
    apt-get update -qq >/dev/null
    apt-get install -y -qq gcc-arm-linux-gnueabihf libc6-dev-armhf-cross >/dev/null
    ./tools/build-config.sh >/dev/null
    chown -R "$(stat -c %u:%g /src)" /src/tools/settings-ui/build'
else
  die "no ${CROSS_CC} and no docker - install gcc-arm-linux-gnueabihf, or set CROSS_CC"
fi

# An x86 binary shipped to a MiSTer is a settings entry that does nothing.
[ "$(od -An -tu1 -j18 -N1 "${OUT}/tty2oledplus_config" | tr -d ' ')" = "40" ] \
  || die "${OUT}/tty2oledplus_config is not an ARM binary"
echo "built ${OUT}/tty2oledplus_config ($(wc -c < "${OUT}/tty2oledplus_config") bytes)"
