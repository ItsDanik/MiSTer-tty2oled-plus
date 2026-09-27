#!/usr/bin/env python3
"""
wheels2gsc.py - turn a folder of arcade wheel logos into 256x64 .gsc banners.

    ./tools/wheels2gsc.py ~/Downloads/MAME0.277Wheels -o ~/wheels-gsc
    ./tools/wheels2gsc.py ~/Downloads/MAME0.277Wheels -o ~/wheels-gsc sf2 pacman

Runs on the workstation and needs Pillow. Every .png in the folder becomes a
.gsc of the same name in the output folder - a wheel is named after its MAME
set, which is what an arcade core reports as CORENAME, so the names carry over
as they are. Give set names after the folders to convert only those.

A wheel is a colour logo on a transparent background, with a margin of its own
and any aspect ratio from about 2:1 to 5:1. For each one:

  1. Crop to the logo: the bounding box of the pixels with alpha above
     --alpha-cut. A file with no transparency is cropped to what differs from
     its top-left pixel instead, which is its background.
  2. Fit it into the frame less --margin on every side, keeping the aspect
     ratio - scaling up as well as down - and centre it on black.
  3. Colour to grey: --value-mix of the brightest channel, the rest luma.
     Luma alone makes a saturated red or blue a dark grey, and on a panel that
     glows, a saturated colour is a bright one.
  4. Stretch the levels of the logo itself: the 2nd..99th percentile of its
     opaque pixels spread over --floor..255 with --gamma. A logo's darkest
     shading would otherwise be lost against the black around it, and a dim
     logo would stay dim. A logo in one flat colour has no spread to stretch,
     so its colour is taken as the top instead (MIN_SPAN).
  5. Composite on black by its alpha, so edges stay anti-aliased, and round to
     the nearest of the panel's sixteen levels - png2gsc.py's level(), and its
     .gsc writer.
  6. If nothing came out above DARK_TOP, the logo is dark lettering meant for
     a light background: convert it again with its greys inverted.
  7. If the brightest pixel is still below level 15, raise every pixel that
     is not black by the shortfall, at most MAX_LIFT levels.

--nodupes then removes every picture that is byte-identical to another in the
output folder - the whole folder, not just what this run wrote. A MAME set's
clones and bootlegs usually share the parent's wheel, so of the 0.277 set's
12235 wheels 7614 go, leaving 4621 files. Of each group of identical pictures
the shortest name is kept (alphabetically first on a tie), which is nearly
always the parent set, and every name removed is written to duplicates.txt
beside them as

    <removed set>|<kept set>

That file is what makes a removed set still findable: its picture is
<kept set>.gsc. Look a core up as the exact file, then in duplicates.txt, and
only then by trimming the name - the trimming the daemon does for banners
lands on a *different* game's wheel for 367 of the removed sets (hook_408 ->
hook) and on nothing at all for 2350 (rayforcej's wheel is kept as gunlock).

Runs are cumulative: entries already in duplicates.txt are kept, re-pointed
if their kept set has since been removed in turn, and dropped once the set
has a file of its own again - which a later run without --nodupes gives it.

The defaults are what looked best on a contact sheet of a few dozen wheels;
the options are there to try others and look at them on the panel with
./tools/mistergscpreview.
"""

import argparse
import hashlib
import io
import os
import struct
import sys
import zlib
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png2gsc import BANNER_W, BANNER_H, level, to_gsc  # noqa: E402

try:
    from PIL import Image, ImageChops, ImageOps
except ImportError:
    sys.exit("wheels2gsc: needs Pillow (pip install pillow, or your distro's python-pillow)")

# Some wheels are 4K renders; 89MP is Pillow's own bomb limit and none come
# close, but a warning per file would bury the progress line.
Image.MAX_IMAGE_PIXELS = None

OPTS = None  # set in each worker by init()


def init(opts):
    global OPTS
    OPTS = opts


def logo_bbox(img):
    """The box around the logo, or None if there is nothing to see."""
    alpha = img.getchannel("A")
    if alpha.getextrema()[0] < 255:
        return alpha.point(lambda a: 255 if a > OPTS.alpha_cut else 0).getbbox()
    # Opaque all over: the background is whatever the corner is.
    bg = Image.new("RGBA", img.size, img.getpixel((0, 0)))
    diff = ImageChops.difference(img, bg).convert("L")
    return diff.point(lambda d: 255 if d > 24 else 0).getbbox()


def drop_bad_ancillary(data):
    """The PNG without any ancillary chunk whose CRC is wrong, or None.

    None when there is nothing to drop, or when a *critical* chunk is the
    damaged one - that is a broken picture, not a broken annotation.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    out, pos, dropped = [data[:8]], 8, False
    while pos + 12 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        end = pos + 12 + length
        chunk = data[pos:end]
        if len(chunk) < 12 + length:
            return None
        ctype, body = chunk[4:8], chunk[8:8 + length]
        crc = struct.unpack(">I", chunk[8 + length:])[0]
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc:
            if not ctype[0] & 0x20:  # upper-case first letter: critical
                return None
            dropped = True
        else:
            out.append(chunk)
        pos = end
    return b"".join(out) if dropped else None


def open_image(src):
    """Open and decode, or raise. Returns (image, warning or None)."""
    try:
        img = Image.open(src)
        img.load()
        return img, None
    except (OSError, SyntaxError) as first:
        failure = first
    # Two wheels of the MAME 0.277 set carry an iCCP colour profile with a bad
    # CRC, and Pillow refuses the whole file over it. The profile is optional
    # and unused here, so the file is decoded without it. Not by Pillow's
    # LOAD_TRUNCATED_IMAGES, which does skip that check but also lets a
    # genuinely truncated file through, converted with a black bottom half.
    with open(src, "rb") as fh:
        fixed = drop_bad_ancillary(fh.read())
    if fixed is None:
        raise failure
    img = Image.open(io.BytesIO(fixed))
    img.load()
    return img, "damaged ancillary chunk dropped"


# The level stretch spreads the logo's 2nd..99th percentile over the whole
# range. A logo drawn in one flat colour has those two nearly equal, and the
# stretch then put its body on --floor and only the resampling ringing at its
# edges at white: Cloud 9, Marine Boy and The Goonies came out near black. A
# span narrower than this is widened downwards, so the colour itself is the
# top of the stretch.
MIN_SPAN = 64
# A logo whose brightest pixel still falls short of level 15 has every
# non-black pixel raised by the shortfall, but by no more than this many
# levels: enough to lift a dim logo, not enough to flatten it.
MAX_LIFT = 2
# A logo that is dark lettering - drawn for a light background - comes out of
# the stretch with nothing above --floor, and is invisible on the panel: 13
# of the 0.277 set, all at level 2, with the next-dimmest logo at level 8.
# Nothing brighter than this level means the logo is converted again with
# its greys inverted, so the lettering is the light part.
DARK_TOP = 4


def percentile(hist, frac):
    want = sum(hist) * frac
    run = 0
    for v, n in enumerate(hist):
        run += n
        if run > want:
            return v
    return 255


def tone_map(img, invert=False):
    """The fitted RGBA logo to an L image of 0..255 greys, and its alpha.

    invert turns the greys over before the stretch, for dark lettering.
    """
    r, g, b, alpha = img.split()
    luma = img.convert("L")
    value = ImageChops.lighter(ImageChops.lighter(r, g), b)
    grey = Image.blend(luma, value, OPTS.value_mix)
    if invert:
        grey = ImageOps.invert(grey)

    solid = alpha.point(lambda a: 255 if a > 128 else 0)
    hist = grey.histogram(mask=solid)
    if sum(hist):
        hi = percentile(hist, 0.99)
        lo = min(percentile(hist, 0.02), hi - 1)
        if hi - lo < MIN_SPAN:
            lo = max(0, hi - MIN_SPAN)
        hi = max(hi, lo + 1)
        floor, gamma = OPTS.floor, OPTS.gamma
        lut = [round(floor + (255 - floor) * min(1.0, max(0.0, (v - lo) / (hi - lo))) ** gamma)
               for v in range(256)]
        grey = grey.point(lut)
    return grey, alpha


def lift(levels):
    """Raise a logo that never reaches level 15. Returns (levels, top, lift)."""
    top = max(levels)
    up = min(MAX_LIFT, 15 - top) if top else 0
    if up:
        levels = [v + up if v else 0 for v in levels]
    return levels, top, up


def convert(src):
    """One wheel to a .gsc file.

    Returns (name, error or None, warning or None, info) - info being
    (brightest level before the lift, the lift, whether inverted), for
    --report.
    """
    name = os.path.splitext(os.path.basename(src))[0]
    warn, info = None, None
    try:
        img, warn = open_image(src)
        if img.mode.startswith("I;16") or img.mode == "I":
            img = img.convert("I").point(lambda v: v * (1 / 257)).convert("L")
        img = img.convert("RGBA")

        box = logo_bbox(img)
        if not box:
            return name, "nothing visible in it", warn, info
        img = img.crop(box)

        m = OPTS.margin
        fw, fh = BANNER_W - 2 * m, BANNER_H - 2 * m
        scale = min(fw / img.width, fh / img.height)
        size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        # Pillow resizes RGBA premultiplied, so transparent pixels' colours do
        # not bleed into the edges.
        img = img.resize(size, Image.LANCZOS)

        def render(invert):
            grey, alpha = tone_map(img, invert)
            logo = Image.composite(grey, Image.new("L", grey.size, 0), alpha)
            frame = Image.new("L", (BANNER_W, BANNER_H), 0)
            frame.paste(logo, ((BANNER_W - logo.width) // 2, (BANNER_H - logo.height) // 2))
            return [level(p) for p in frame.tobytes()]

        levels, inverted = render(False), False
        if max(levels) <= DARK_TOP:
            levels, inverted = render(True), True
        levels, top, up = lift(levels)
        info = (top, up, inverted)

        out = os.path.join(OPTS.out, name + ".gsc")
        tmp = out + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(to_gsc([v * 17 for v in levels], BANNER_W, BANNER_H))
        os.replace(tmp, out)
        return name, None, warn, info
    except Exception as e:  # one bad file must not stop twelve thousand
        return name, f"{e.__class__.__name__}: {e}", warn, info


DUPES_FILE = "duplicates.txt"
DUPES_HEADER = """\
# Sets whose wheel is byte-identical to another set's, written by
# tools/wheels2gsc.py --nodupes. <removed set>|<kept set>: the removed set's
# picture is <kept set>.gsc. Look a set up as its own file first, then here,
# and only then by trimming its name - trimming finds the wrong game's wheel
# or none at all for a third of these.
"""


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


def write_dupes(path, dupes):
    if not dupes:
        if os.path.exists(path):
            os.remove(path)
        return
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(DUPES_HEADER)
        for name in sorted(dupes):
            fh.write(f"{name}|{dupes[name]}\n")
    os.replace(tmp, path)


def have(out, name):
    return os.path.isfile(os.path.join(out, name + ".gsc"))


def remove_dupes(out, dupes):
    """Delete every .gsc identical to another in out; record each in dupes.

    Returns how many files were removed.
    """
    groups = {}
    for f in os.listdir(out):
        if f.endswith(".gsc"):
            with open(os.path.join(out, f), "rb") as fh:
                digest = hashlib.sha256(fh.read()).digest()
            groups.setdefault(digest, []).append(f[:-4])

    removed = {}
    for names in groups.values():
        if len(names) < 2:
            continue
        # Shortest first: a parent set's name is a prefix of most of its
        # clones', so this keeps the parent in nearly every group.
        names.sort(key=lambda n: (len(n), n))
        for name in names[1:]:
            removed[name] = names[0]
            os.remove(os.path.join(out, name + ".gsc"))

    # Earlier entries whose kept set has just been removed follow it on.
    for name, keeper in dupes.items():
        dupes[name] = removed.get(keeper, keeper)
    dupes.update(removed)
    return len(removed)


def main():
    ap = argparse.ArgumentParser(
        description="Convert a folder of arcade wheel PNGs to 256x64 .gsc banners",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("A wheel is")[0])
    ap.add_argument("src", help="folder of wheel .png files")
    ap.add_argument("names", nargs="*",
                    help="convert only these sets (file names without .png)")
    ap.add_argument("-o", "--out", required=True, help="folder to write the .gsc files to")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1,
                    help="conversions in parallel (default: every CPU)")
    ap.add_argument("--nodupes", action="store_true",
                    help=f"afterwards, remove every .gsc in the output folder "
                         f"identical to another, and list each in {DUPES_FILE}")
    ap.add_argument("--margin", type=int, default=2,
                    help="black pixels kept clear on every side (default 2)")
    ap.add_argument("--value-mix", type=float, default=0.5,
                    help="share of the brightest channel in the grey, 0 = pure "
                         "luma, 1 = pure max(R,G,B) (default 0.5)")
    ap.add_argument("--floor", type=int, default=40,
                    help="the grey the logo's darkest solid pixels get, 0..255 "
                         "(default 40, a little above black)")
    ap.add_argument("--gamma", type=float, default=0.8,
                    help="gamma of the level stretch; below 1 brightens the "
                         "mid-tones (default 0.8)")
    ap.add_argument("--report", metavar="CSV",
                    help="write set,brightest level,lift,inverted for every "
                         "logo converted")
    ap.add_argument("--alpha-cut", type=int, default=24,
                    help="alpha at or below which a pixel is not part of the "
                         "logo when cropping (default 24)")
    opts = ap.parse_args()

    if not os.path.isdir(opts.src):
        sys.exit(f"wheels2gsc: not a folder: {opts.src}")
    if not 0 <= opts.margin < BANNER_H // 2:
        sys.exit("wheels2gsc: --margin must be 0..31")
    if not 0.0 <= opts.value_mix <= 1.0:
        sys.exit("wheels2gsc: --value-mix must be 0..1")
    if not 0 <= opts.floor <= 255 or opts.gamma <= 0:
        sys.exit("wheels2gsc: --floor must be 0..255 and --gamma above 0")

    if opts.names:
        srcs = [os.path.join(opts.src, n if n.lower().endswith(".png") else n + ".png")
                for n in opts.names]
        missing = [s for s in srcs if not os.path.isfile(s)]
        if missing:
            sys.exit("wheels2gsc: no such file: " + ", ".join(missing))
    else:
        srcs = sorted(os.path.join(opts.src, f) for f in os.listdir(opts.src)
                      if f.lower().endswith(".png"))
    if not srcs:
        sys.exit(f"wheels2gsc: no .png files in {opts.src}")

    # Two wheels whose names differ only in case would be one file on the
    # MiSTer's exFAT card, and whichever was copied last would win.
    seen = {}
    for s in srcs:
        k = os.path.basename(s).lower()
        if k in seen:
            print(f"warning: {os.path.basename(seen[k])} and {os.path.basename(s)} "
                  "are one file on exFAT", file=sys.stderr)
        seen[k] = s

    os.makedirs(opts.out, exist_ok=True)
    failed, warned, report = [], [], []
    tty = sys.stderr.isatty()
    with Pool(max(1, opts.jobs), initializer=init, initargs=(opts,)) as pool:
        for i, (name, err, warn, info) in enumerate(pool.imap_unordered(convert, srcs, chunksize=16), 1):
            if info:
                report.append((name,) + info)
            if err:
                failed.append((name, err))
            elif warn:
                warned.append((name, warn))
            if tty and (i % 50 == 0 or i == len(srcs)):
                print(f"\r{i}/{len(srcs)}", end="", file=sys.stderr, flush=True)
    if tty:
        print(file=sys.stderr)

    print(f"{len(srcs) - len(failed)} of {len(srcs)} written to {opts.out}")
    if report:
        lifted = [(top, up) for _, top, up, _ in report if up]
        print(f"  {len(report) - len(lifted)} reach level 15; {len(lifted)} lifted "
              f"(by 1: {sum(1 for _, u in lifted if u == 1)}, by 2: "
              f"{sum(1 for _, u in lifted if u == 2)}), "
              f"{sum(1 for t, u in lifted if t + u < 15)} of those still below 15; "
              f"{sum(1 for *_, inv in report if inv)} dark lettering inverted")
    if opts.report:
        with open(opts.report, "w") as fh:
            fh.write("set,brightest_level,lift,inverted\n")
            for name, top, up, inv in sorted(report):
                fh.write(f"{name},{top},{up},{'yes' if inv else 'no'}\n")

    # A set with a file of its own again is not a duplicate any more; one
    # whose kept set has vanished altogether has nothing left to point at.
    map_path = os.path.join(opts.out, DUPES_FILE)
    dupes = {n: k for n, k in read_dupes(map_path).items() if not have(opts.out, n)}
    if opts.nodupes:
        gone = remove_dupes(opts.out, dupes)
        kept = sum(1 for f in os.listdir(opts.out) if f.endswith(".gsc"))
        print(f"{gone} duplicates removed, {kept} pictures left; "
              f"{len(dupes)} sets listed in {map_path}")
    lost = sorted(n for n, k in dupes.items() if not have(opts.out, k))
    for name in lost:
        print(f"  warning {name}: its kept set {dupes.pop(name)} has no file - "
              f"dropped from {DUPES_FILE}", file=sys.stderr)
    write_dupes(map_path, dupes)
    for name, warn in sorted(warned):
        print(f"  warning {name}: {warn}", file=sys.stderr)
    for name, err in sorted(failed):
        print(f"  failed {name}: {err}", file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
