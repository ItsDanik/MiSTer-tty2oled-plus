#!/bin/bash
#
# Run the whole test suite. No MiSTer, no ESP32, no serial port required.
#
#   ./tests/run-all.sh
#
# Covers:
#   test-meta.sh        metadata extraction from MiSTer's /tmp state and MRA files
#   test-wire.sh        the exact bytes the daemon sends to the display
#   test-index.sh       the libretro title-index builder and the CRC lookup
#   test-version.sh     one version across the scripts and the firmware
#   test-daemon.sh      the daemon loop's device recovery, and the init script
#   test-deploy.sh      deploy-mister.sh against a fake MiSTer, and the boot hook
#   test-settings.sh    the Scripts-menu settings editor and the ini it writes
#   test-png2gsc.py     the image converter, on both of its backends
#   test-installer.sh   the release package, and the installer that unpacks it
#   test-flash.sh       flashing: what is written, and what is kept
#   test_meta_parse     the firmware's CMDMETA parser
#   test_meta_layout    the firmware's layout code, under ASan/UBSan

set -u
HERE="$(cd "$(dirname "${0}")" && pwd)"
RC=0

run() {
  local name="${1}"; shift
  printf '\n\033[1;36m=== %s ===\033[0m\n' "${name}"
  if "${@}"; then
    printf '\033[32m%s passed\033[0m\n' "${name}"
  else
    printf '\033[31m%s FAILED\033[0m\n' "${name}"
    RC=1
  fi
}

run "shell: metadata extraction" "${HERE}/test-meta.sh"
run "shell: wire protocol"       "${HERE}/test-wire.sh"
run "shell: title index"         "${HERE}/test-index.sh"
run "shell: versioning"          "${HERE}/test-version.sh"
run "shell: daemon lifecycle"    "${HERE}/test-daemon.sh"
run "shell: deploy"              "${HERE}/test-deploy.sh"
run "shell: settings editor"     "${HERE}/test-settings.sh"
run "tools: png2gsc"             "${HERE}/test-png2gsc.py"
run "release: installer"        "${HERE}/test-installer.sh"
run "tools: flashing"            "${HERE}/test-flash.sh"

# The firmware tests need a host C++ compiler. Skipped rather than failed when
# one is unavailable, so the shell suite still runs anywhere.
if command -v g++ >/dev/null 2>&1; then
  FW="${HERE}/firmware"

  printf '\n\033[1;36m=== firmware: building host tests ===\033[0m\n'
  if g++ -std=c++11 -Wall -Wextra -Werror \
         -o "${FW}/test_meta_parse" "${FW}/test_meta_parse.cpp" &&
     g++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined \
         -o "${FW}/test_meta_layout" "${FW}/test_meta_layout.cpp"; then
    printf '\033[32mbuilt clean under -Wall -Wextra -Werror\033[0m\n'
    run "firmware: CMDMETA parser" "${FW}/test_meta_parse"
    run "firmware: display layout" "${FW}/test_meta_layout"
  else
    printf '\033[31mfirmware test build FAILED\033[0m\n'
    RC=1
  fi
else
  printf '\n\033[33mg++ not found - skipping firmware host tests\033[0m\n'
fi

printf '\n'
if [ "${RC}" -eq 0 ]; then
  printf '\033[1;32mAll suites passed.\033[0m\n\n'
else
  printf '\033[1;31mSome suites failed.\033[0m\n\n'
fi
exit "${RC}"
