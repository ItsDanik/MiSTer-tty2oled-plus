#!/bin/bash
#
# Tests for flashing: tools/fw-segments.py, which decides what part of a merged
# image to write, and tools/flash-mister.sh, which writes it.
#
# The property that matters: after a flash, the display's firmware is exactly
# the new image, and its settings store and boot-image filesystem are exactly
# what they were - unless the partitions moved, in which case the whole image
# goes, as it always used to. Checked by applying what would be written to a
# simulated flash chip and comparing byte for byte.
#
# flash-mister.sh runs for real, with esptool replaced by a stand-in that
# serves a partition table and records what it was asked to write.
#
#   ./tests/test-flash.sh

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${0}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TMP="${HERE}/fixtures/tmp/flash"
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

# ---------------------------------------------------------------------------
# Images. Laid out like the real one - the Arduino "default" 4MB scheme - with
# a bootloader, a partition table, otadata, and an app of a given size.
# ---------------------------------------------------------------------------
python3 - "${TMP}" <<'PY'
import struct, sys, os
tmp = sys.argv[1]
LAYOUT = [("nvs", 1, 0x02, 0x9000, 0x5000), ("otadata", 1, 0x00, 0xE000, 0x2000),
          ("app0", 0, 0x10, 0x10000, 0x140000), ("app1", 0, 0x11, 0x150000, 0x140000),
          ("spiffs", 1, 0x82, 0x290000, 0x160000), ("coredump", 1, 0x03, 0x3F0000, 0x10000)]

def table(layout):
    t = b"".join(b"\xaa\x50" + bytes([ty, st]) + struct.pack("<II", off, size)
                 + name.encode().ljust(16, b"\0") + b"\0" * 4
                 for name, ty, st, off, size in layout)
    return t + b"\xff" * (0xC00 - len(t))

def image(app_len, fill, layout=LAYOUT):
    img = bytearray(b"\xff" * 0x400000)
    img[0x1000:0x1000 + 0x5000] = bytes([fill]) * 0x5000          # bootloader
    img[0x8000:0x8C00] = table(layout)
    img[0xE000:0xE020] = b"\x00" * 32                              # otadata
    img[0x10000:0x10000 + app_len] = bytes([fill ^ 0x55]) * app_len
    return img

new = image(0x74000, 0xA1)
open(os.path.join(tmp, "new.bin"), "wb").write(new)
open(os.path.join(tmp, "table.bin"), "wb").write(new[0x8000:0x8C00])
moved = [(n, t, s, o + (0x1000 if n == "spiffs" else 0), sz - (0x1000 if n == "spiffs" else 0))
         for n, t, s, o, sz in LAYOUT]
open(os.path.join(tmp, "table-moved.bin"), "wb").write(table(moved))

# What the display's chip holds before the flash: an older, longer firmware,
# and the user's things in nvs and spiffs.
old = image(0x90000, 0x3C)
old[0x9000:0xE000] = b"SETTINGS" * (0x5000 // 8)
old[0x290000:0x3F0000] = b"BOOTIMG!" * (0x160000 // 8)
open(os.path.join(tmp, "old-chip.bin"), "wb").write(old)

# An 8MB image with data at 5MB, past every partition: laid out some way this
# does not understand.
stray = bytearray(new) + bytearray(b"\xff" * 0x400000); stray[0x500000] = 0x00
open(os.path.join(tmp, "stray.bin"), "wb").write(stray)
PY

# Apply "<offset> <file>" pairs from fw-segments.py to a copy of a chip.
apply_plan() {  # apply_plan <chip image> <plan file> <result>
  python3 - "$@" <<'PY'
import sys
chip = bytearray(open(sys.argv[1], "rb").read())
for line in open(sys.argv[2]):
    off, path = line.split(None, 1)
    data = open(path.strip(), "rb").read()
    off = int(off, 16)
    chip[off:off + len(data)] = data
open(sys.argv[3], "wb").write(chip)
PY
}
region() { python3 -c "import sys; d=open(sys.argv[1],'rb').read(); print(__import__('hashlib').sha256(d[int(sys.argv[2],16):int(sys.argv[3],16)]).hexdigest()[:16])" "$@"; }
same_region() { [ "$(region "$1" "$3" "$4")" = "$(region "$2" "$3" "$4")" ] && echo same || echo different; }

SEG="${ROOT}/tools/fw-segments.py"

# ===========================================================================
section "fw-segments.py: the display's partitions match"
# ===========================================================================

python3 "${SEG}" "${TMP}/new.bin" "${TMP}/segs" "${TMP}/table.bin" > "${TMP}/plan" 2>"${TMP}/err"
ok "it plans a partial write" "$(cut -d' ' -f1 "${TMP}/plan" | tr '\n' ' ')" "0x0 0xe000 0x10000 "
ok "quietly" "$(cat "${TMP}/err")" ""
ok "writing the app only as far as its data goes" "$(stat -c%s "${TMP}/segs/segment-010000.bin")" "$((0x74000))"

apply_plan "${TMP}/old-chip.bin" "${TMP}/plan" "${TMP}/after.bin"
ok "the bootloader and partition table are the new ones" "$(same_region "${TMP}/after.bin" "${TMP}/new.bin" 0 0x9000)" "same"
ok "so is otadata" "$(same_region "${TMP}/after.bin" "${TMP}/new.bin" 0xe000 0x10000)" "same"
ok "so is the app" "$(same_region "${TMP}/after.bin" "${TMP}/new.bin" 0x10000 0x84000)" "same"
ok "the settings store is untouched" "$(same_region "${TMP}/after.bin" "${TMP}/old-chip.bin" 0x9000 0xe000)" "same"
ok "the boot image's filesystem is untouched" "$(same_region "${TMP}/after.bin" "${TMP}/old-chip.bin" 0x290000 0x3f0000)" "same"

# ===========================================================================
section "fw-segments.py: anything uncertain writes the whole image"
# ===========================================================================

whole() {  # whole <image> [table]  ->  prints the plan's single offset, or the plan
  python3 "${SEG}" "$1" "${TMP}/segs2" ${2:+"$2"} 2>"${TMP}/err" | tr '\n' ' '
}
ok "no table from the display"            "$(whole "${TMP}/new.bin")"                            "0x0 ${TMP}/new.bin "
ok "and says why"                          "$(grep -c 'could not be read' "${TMP}/err")"          "1"
ok "an unreadable table file"              "$(whole "${TMP}/new.bin" "${TMP}/nope.bin")"          "0x0 ${TMP}/new.bin "
ok "partitions laid out differently"       "$(whole "${TMP}/new.bin" "${TMP}/table-moved.bin")"   "0x0 ${TMP}/new.bin "
ok "and says why"                          "$(grep -c 'laid out differently' "${TMP}/err")"       "1"
head -c 300000 /dev/urandom > "${TMP}/junk.bin"
ok "an image with no partition table"      "$(whole "${TMP}/junk.bin" "${TMP}/table.bin")"        "0x0 ${TMP}/junk.bin "
ok "an image with data outside its partitions" "$(whole "${TMP}/stray.bin" "${TMP}/table.bin")"  "0x0 ${TMP}/stray.bin "

python3 "${SEG}" "${TMP}/new.bin" "${TMP}/segs3" "${TMP}/table-moved.bin" > "${TMP}/plan-moved" 2>/dev/null
apply_plan "${TMP}/old-chip.bin" "${TMP}/plan-moved" "${TMP}/after-moved.bin"
ok "a full write leaves exactly the new image" "$(same_region "${TMP}/after-moved.bin" "${TMP}/new.bin" 0 0x400000)" "same"

REAL="$(ls -t "${ROOT}"/MiSTer_SSD1322_USB/build-out-*/MiSTer_SSD1322_USB.ino.merged.bin 2>/dev/null | head -n1)"
if [ -n "${REAL}" ]; then
  dd if="${REAL}" of="${TMP}/real-table.bin" bs=4096 skip=8 count=1 status=none
  python3 "${SEG}" "${REAL}" "${TMP}/real" "${TMP}/real-table.bin" > "${TMP}/real-plan" 2>/dev/null
  ok "a real build plans a partial write" "$(grep -c '' "${TMP}/real-plan")" "3"
  ok "that leaves nvs and spiffs alone" "$(cut -d' ' -f1 "${TMP}/real-plan" | grep -c -e '^0x9000$' -e '^0x290000$')" "0"
else
  printf '  \033[33mskip\033[0m a real build (none built here)\n'
fi

# ===========================================================================
section "flash-mister.sh"
# ===========================================================================

T2O="${TMP}/install"
FAKEBIN="${TMP}/bin"
mkdir -p "${T2O}" "${FAKEBIN}"
cp "${ROOT}/tools/flash-mister.sh" "${ROOT}/tools/fw-segments.py" "${T2O}/"
{ cat "${ROOT}/tty2oled-system.ini"; echo 'TTYDEV="/dev/null"'; } > "${T2O}/tty2oled-system.ini"
: > "${T2O}/tty2oled-user.ini"
cp "${TMP}/new.bin" "${T2O}/tty2oledplus-lolin32.bin"
LOG="${TMP}/esptool.log"

# The init script: remembers whether "the daemon" is running.
cat > "${T2O}/S60tty2oled" <<'FAKE'
#!/bin/bash
case "$1" in
  start)  echo running > "${FAKE_STATE}" ;;
  stop)   echo stopped > "${FAKE_STATE}" ;;
  status) [ "$(cat "${FAKE_STATE}" 2>/dev/null)" = running ] ;;
esac
FAKE
# esptool: serves FAKE_TABLE to read_flash (or fails without one), records the
# rest. The flash-mister.sh on a MiSTer runs "python", which is python3 there.
cat > "${T2O}/esptool.py" <<'FAKE'
import sys, os, shutil
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    if "read_flash" in args:
        i = args.index("read_flash")
        if not os.environ.get("FAKE_TABLE"):
            log.write("read_flash failed\n"); sys.exit(2)
        shutil.copy(os.environ["FAKE_TABLE"], args[i + 3])
        log.write("read_flash\n")
    elif "write_flash" in args:
        pairs = args[args.index("--flash_size") + 2:]
        log.write("write_flash " + " ".join(p if p.startswith("0x") else os.path.basename(p) for p in pairs) + "\n")
FAKE
cat > "${FAKEBIN}/python" <<'FAKE'
#!/bin/bash
[ "$1" = "-c" ] && [ "$2" = "import serial" ] && exit 0
exec python3 "$@"
FAKE
chmod +x "${T2O}/S60tty2oled" "${FAKEBIN}/python"
export FAKE_LOG="${LOG}" FAKE_STATE="${TMP}/state"

flash() {
  : > "${LOG}"
  PATH="${FAKEBIN}:${PATH}" TTY2OLED_PATH="${T2O}" CHIP_OVERRIDE=esp32 \
    bash "${T2O}/flash-mister.sh" "${T2O}/tty2oledplus-lolin32.bin" > "${TMP}/out" 2>&1 </dev/null
}
written() { sed -n 's/^write_flash //p' "${LOG}"; }

echo running > "${TMP}/state"
FAKE_TABLE="${TMP}/table.bin" flash; RC="${?}"
ok "a flash succeeds" "${RC}" "0"
ok "the display's table is read first" "$(head -n1 "${LOG}")" "read_flash"
ok "and only the parts with data are written" "$(written)" "0x0 segment-000000.bin 0xe000 segment-00e000.bin 0x10000 segment-010000.bin"
ok "saying the boot screen and settings are kept" "$(grep -c 'are kept' "${TMP}/out")" "1"
ok "the daemon is running again afterwards" "$(cat "${TMP}/state")" "running"
ok "no segment files are left in /tmp" "$(ls -d /tmp/tty2oled-fw.* 2>/dev/null | wc -l | tr -d ' ')" "0"

FAKE_TABLE="" flash
ok "an unreadable table writes the whole image" "$(written)" "0x0 tty2oledplus-lolin32.bin"
ok "and says what that costs" "$(grep -c 'are erased' "${TMP}/out")" "1"

FAKE_TABLE="${TMP}/table-moved.bin" flash
ok "moved partitions write the whole image" "$(written)" "0x0 tty2oledplus-lolin32.bin"

rm "${T2O}/fw-segments.py"
FAKE_TABLE="${TMP}/table.bin" flash
ok "an install without fw-segments.py writes the whole image" "$(written)" "0x0 tty2oledplus-lolin32.bin"
ok "without asking for the table" "$(grep -c read_flash "${LOG}")" "0"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
