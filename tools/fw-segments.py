#!/usr/bin/env python3
"""
fw-segments.py - which parts of a merged firmware image actually need writing.

    fw-segments.py <merged.bin> <outdir> [<the display's partition table>]

Prints "<offset> <file>" pairs for esptool's write_flash, one per line, and
writes the files into <outdir>. Runs on the MiSTer, from flash-mister.sh.

A merged image is the whole flash chip - 4MB for 4MB of flash - and most of it
is erased bytes: the settings store (nvs), the filesystem the boot image lives
on (spiffs), the second app slot, the core dump area. Writing all of it at 0x0
erases all of those, so every flash used to forget the stored boot image and
every Preferences value. Those partitions are 0xFF in the image because the
build has nothing to put there, not because they should be wiped.

So this writes the part before the first partition (bootloader and partition
table) and each partition that has something in it, trimmed to where its data
ends, and leaves the rest of the chip alone - which is also a quarter of the
bytes to send.

That is only right while the partitions are where the new firmware expects
them. If the display's current table differs, or cannot be read, or the image
is not what this expects, the answer is the whole image at 0x0, exactly as
before. A partial write is never attempted on a guess.
"""

import os
import struct
import sys

TABLE_AT = 0x8000
TABLE_LEN = 0xC00
SECTOR = 0x1000


def table(blob):
    """The partition entries in a partition table, as (offset, size) tuples,
    in order - or None if this is not a partition table."""
    entries = []
    for pos in range(0, min(len(blob), TABLE_LEN), 32):
        e = blob[pos:pos + 32]
        if len(e) < 32 or e[:2] != b"\xaa\x50":
            break
        offset, size = struct.unpack("<II", e[4:12])
        entries.append((e[2], e[3], offset, size, e[12:28].rstrip(b"\0")))
    return entries or None


def last_data(buf):
    """Length of buf with trailing erased bytes removed."""
    return len(buf.rstrip(b"\xff"))


def plan(image, current):
    """[(offset, length)] to write, or None to write the whole image."""
    new = table(image[TABLE_AT:TABLE_AT + TABLE_LEN])
    if not new:
        return None, "no partition table in the image"
    if current is None:
        return None, "the display's partition table could not be read"
    if table(current) != new:
        return None, "the display's partitions are laid out differently"

    first = min(p[2] for p in new)
    segments = [(0, first)]                       # bootloader + partition table
    for _type, _sub, offset, size, _label in sorted(new, key=lambda p: p[2]):
        if offset + size > len(image):
            return None, "a partition runs past the end of the image"
        used = last_data(image[offset:offset + size])
        if used:
            used = (used + SECTOR - 1) // SECTOR * SECTOR
            segments.append((offset, min(used, size)))

    # Everything the image carries has to be in a segment. A byte of data
    # anywhere else means this image is not laid out the way it looks, and
    # the only safe write is the whole thing.
    covered = bytearray(len(image))
    for offset, length in segments:
        covered[offset:offset + length] = b"\x01" * length
    for i, byte in enumerate(image):
        if byte != 0xFF and not covered[i]:
            return None, "the image has data outside its partitions (at %#x)" % i
    return segments, None


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[2].strip())
    image_path, outdir = sys.argv[1], sys.argv[2]
    with open(image_path, "rb") as fh:
        image = fh.read()
    current = None
    if len(sys.argv) == 4:
        try:
            with open(sys.argv[3], "rb") as fh:
                current = fh.read()
        except OSError:
            current = None

    segments, why = plan(image, current)
    if segments is None:
        sys.stderr.write("fw-segments: writing the whole image - %s\n" % why)
        print("0x0 %s" % image_path)
        return

    os.makedirs(outdir, exist_ok=True)
    for offset, length in segments:
        path = os.path.join(outdir, "segment-%06x.bin" % offset)
        with open(path, "wb") as fh:
            fh.write(image[offset:offset + length])
        print("%#x %s" % (offset, path))


if __name__ == "__main__":
    main()
