#!/usr/bin/env python3
"""
gscpack.py - pack a folder of 256x64 .gsc banners into one file and an index.

    ./tools/gscpack.py ~/wheels-gsc -o ~/wheels-pack          # wheels.bin, wheels.idx
    ./tools/gscpack.py ~/wheels-gsc -o ~/wheels-pack --name arcade

Runs on the workstation. Written for the output of wheels2gsc.py, but takes
any folder of 256x64 .gsc files, in either spelling.

Why one file: /media/fat is exFAT with 128KB clusters on a large card, so
every file costs 128KB whatever its size. 4621 wheel pictures as files are
about 590MB on the card; packed they are 4621 x 8192 bytes, about 38MB, and
one file copies in seconds where thousands of small ones take minutes on a
card mounted sync.

<name>.bin is the pictures back to back, each exactly the 8192 bytes the
firmware reads after CMDCOR - 4bpp, two pixels a byte, high nibble on the
left, which is what `tail -n +4 | xxd -r -p` makes of a .gsc. Frame N starts
at byte N * 8192, so one is sent with

    dd if=<name>.bin bs=8192 skip=N count=1 2>/dev/null >"${TTYDEV}"

<name>.idx is text: a few '#' lines, then one line per set,

    <set>|<frame>

sorted, set names lower case. Identical pictures are stored once and every
set that shows one points at the same frame, so the index also does the job
of the duplicates.txt that wheels2gsc.py --nodupes writes: its entries are
read and each removed set points at its kept set's frame. Look a set up by
its whole name, lower-cased -

    awk -F'|' -v c="${core,,}" '$1 == c { print $2; exit }' <name>.idx

- and do not trim the name to find a near match: over the MAME 0.277 wheels,
trimming lands on a different game's picture for 367 of the sets that share
a picture (see CLAUDE.md, Arcade wheel logos).

Lower case because the lookup used to be a file name on exFAT, which ignores
case, and a core's CORENAME is not guaranteed to be spelled like the set.
Two names that differ only in case are one entry; the first is kept and the
collision reported.

The '# frames' line lets a reader check that the .bin it has is the one the
index was written for: its size must be frames * 8192.
"""

import argparse
import os
import subprocess
import sys

FRAME = 8192  # 256x64 at 4bpp
DUPES_FILE = "duplicates.txt"


def die(msg):
    sys.exit(f"gscpack: {msg}")


def gsc_bytes(path):
    # Through xxd itself, as the daemon does. The two .gsc spellings only
    # agree because of how xxd -r -p tokenises "0X1f," - see CLAUDE.md - and
    # a reimplementation is how a converter once produced 3072 bytes from a
    # 2048-byte picture.
    tail = subprocess.run(["tail", "-n", "+4", path], capture_output=True, check=True)
    xxd = subprocess.run(["xxd", "-r", "-p"], input=tail.stdout, capture_output=True, check=True)
    return xxd.stdout


def read_dupes(path):
    dupes = {}
    if os.path.isfile(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "|" in line:
                    name, keeper = line.split("|", 1)
                    dupes[name] = keeper
    return dupes


def main():
    ap = argparse.ArgumentParser(
        description="Pack a folder of 256x64 .gsc banners into <name>.bin and <name>.idx",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Why one file")[0])
    ap.add_argument("src", help="folder of .gsc files (and duplicates.txt, if any)")
    ap.add_argument("-o", "--out", required=True, help="folder to write the pack to")
    ap.add_argument("--name", default="wheels",
                    help="base name of the two files (default: wheels)")
    opts = ap.parse_args()

    if not os.path.isdir(opts.src):
        die(f"not a folder: {opts.src}")
    for tool in ("tail", "xxd"):
        if subprocess.run(["sh", "-c", f"command -v {tool}"], capture_output=True).returncode:
            die(f"'{tool}' is not installed")

    files = sorted(f for f in os.listdir(opts.src) if f.lower().endswith(".gsc"))
    if not files:
        die(f"no .gsc files in {opts.src}")

    frames = []          # picture bytes, in pack order
    frame_of = {}        # picture bytes -> frame number
    index = {}           # lower-case set -> frame
    spelled = {}         # lower-case set -> the name it came from
    skipped, clashes = [], []

    def add(name, frame):
        key = name.lower()
        if key in index:
            if index[key] != frame:
                clashes.append((spelled[key], name))
            return
        index[key] = frame
        spelled[key] = name

    for i, f in enumerate(files, 1):
        name = f[:-4]
        data = gsc_bytes(os.path.join(opts.src, f))
        if len(data) != FRAME:
            skipped.append((name, len(data)))
            continue
        key = name.lower()
        if key in index:
            # Spelled differently only in case: one entry. Stored only if
            # it wins, so a losing picture does not sit in the pack unused.
            if frame_of.get(data) != index[key]:
                clashes.append((spelled[key], name))
            continue
        if data not in frame_of:
            frame_of[data] = len(frames)
            frames.append(data)
        add(name, frame_of[data])
        if sys.stderr.isatty() and (i % 200 == 0 or i == len(files)):
            print(f"\r{i}/{len(files)}", end="", file=sys.stderr, flush=True)
    if sys.stderr.isatty():
        print(file=sys.stderr)

    # Sets wheels2gsc.py --nodupes removed: each is its kept set's picture.
    # A kept set that is not in the pack - skipped above, or gone - leaves
    # the entry nothing to point at.
    orphans = []
    for name, keeper in sorted(read_dupes(os.path.join(opts.src, DUPES_FILE)).items()):
        frame = index.get(keeper.lower())
        if frame is None:
            orphans.append((name, keeper))
        else:
            add(name, frame)

    os.makedirs(opts.out, exist_ok=True)
    bin_path = os.path.join(opts.out, opts.name + ".bin")
    idx_path = os.path.join(opts.out, opts.name + ".idx")
    with open(bin_path + ".tmp", "wb") as fh:
        for data in frames:
            fh.write(data)
    with open(idx_path + ".tmp", "w") as fh:
        fh.write(f"# tty2oled+ picture index for {opts.name}.bin, written by "
                 "tools/gscpack.py\n"
                 "# <set>|<frame>: the picture is 8192 bytes at frame * 8192.\n"
                 "# Set names are lower case; look one up whole, never trimmed.\n"
                 f"# frames {len(frames)}\n")
        for key in sorted(index):
            fh.write(f"{key}|{index[key]}\n")
    # The pack before the index, so an index is never newer than its pack.
    os.replace(bin_path + ".tmp", bin_path)
    os.replace(idx_path + ".tmp", idx_path)

    print(f"{len(index)} sets, {len(frames)} pictures: {bin_path} "
          f"({len(frames) * FRAME // 1024}KB), {idx_path}")
    for name, n in skipped:
        print(f"  skipped {name}: {n} bytes, not a 256x64 picture ({FRAME})", file=sys.stderr)
    for first, second in clashes:
        print(f"  warning: {first} and {second} differ only in case and show "
              f"different pictures; {first} kept", file=sys.stderr)
    for name, keeper in orphans:
        print(f"  warning: {name} is listed as a duplicate of {keeper}, which is "
              "not in the pack; left out", file=sys.stderr)
    sys.exit(1 if skipped or orphans else 0)


if __name__ == "__main__":
    main()
