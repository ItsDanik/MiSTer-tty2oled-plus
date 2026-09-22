#!/usr/bin/env python3
"""
png2gsc.py - convert an image to the .gsc format tty2oled displays.

    ./tools/png2gsc.py icon.png                     -> icon.gsc   (86x64)
    ./tools/png2gsc.py --boot splash.png            -> splash.gsc (256x54)
    ./tools/png2gsc.py --banner -o pics/GSC/NES.gsc nes.png       (256x64)
    ./tools/png2gsc.py --out pics/ICON/NES.gsc nes.png
    ./tools/png2gsc.py --boot --header -o x/bootlogo.h logo.png   -> a C header

A .gsc is a three-line header followed by the pixels as hex, ONE HEX
CHARACTER PER PIXEL, row by row, left to right, top to bottom:

    #define icon_width 86
    #define icon_height 64
    static unsigned char icon_bits[] = {
    0000000000ff...

So the display has 16 grey levels, 0 = black through f = full brightness.
There is no colour and no alpha: an SSD1322 is a greyscale panel. Anything
transparent is composited onto black before conversion.

Sizes the firmware accepts:

    icon    86x64    the panel on the right of the console split layout
    banner 256x64    the full-screen core artwork in pics/GSC, named after
                     the core - what CMDCOR puts on screen
    boot   256x54    the top of the screen, stored in the ESP's own flash

A boot screen is 54 rows, not 64: the bottom ten rows of the panel are the
firmware's, where the power-on sweep animates and the build version is
printed when it finishes. Those happen whatever image is stored, so the
image has to stop above them.

Both are fixed. An image of another size is scaled to fit and centred on
black rather than stretched, so aspect ratio is kept; pass --stretch to fill
the frame instead.

--header writes the same pixels as a C header for the firmware to compile in,
rather than a .gsc for the daemon to send. The built-in boot logo is made this
way; the regeneration command is written into the header it produces.

The artwork pack's own .gsc files look different - three comment lines and
then "0X1f,0Xa2," bytes rather than one hex character per pixel - but the two
are interchangeable. The daemon sends a picture with `tail -n +4 | xxd -r -p`
(tty2oled.sh:191), which consumes hex digits and ignores the rest, so both
spellings land as the same 8192 bytes. Files written here use this tool's own
layout; upstream's parse identically.

Pillow is used when it is installed, ImageMagick otherwise; --backend picks
one outright. Both quantise to the same sixteen fixed levels, 0, 17, 34 ... 255,
so art drawn in that palette converts exactly either way, and 16-bit images -
what GIMP and Krita write at 16-bit precision - are scaled, not clipped.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

ICON_W, ICON_H = 86, 64
BOOT_W, BOOT_H = 256, 54
BANNER_W, BANNER_H = 256, 64


def die(msg):
    print(f"png2gsc: {msg}", file=sys.stderr)
    sys.exit(1)


def level(p):
    """An 8-bit grey to one of the panel's 16 levels, 0..15, to the nearest.

    The levels are 0, 17, 34 ... 255, the 16-step palette the art is meant to be
    drawn in, and each of those maps to exactly its own level. This used to be
    p >> 4, which truncates: fine for that palette, but on anything in between
    it rounded down, so a photo came out up to a level darker than it should,
    and differently from ImageMagick's posterize, which rounds to the nearest.
    """
    return (p * 15 + 127) // 255


def load_grey_pillow(path, w, h, stretch, dither, invert):
    from PIL import Image

    try:
        img = Image.open(path)
        img.load()
    except (OSError, SyntaxError) as e:
        die(f"cannot read {path} as an image ({e.__class__.__name__})")

    # 16-bit greyscale opens as "I;16" (or "I"), and convert("L") on those
    # clips at 255 rather than scaling - every value above 255 of 65535 comes
    # out white, so a 16-level picture arrives as black and white. Scale into
    # 8 bits first; 65535 / 257 is exactly 255.
    if img.mode.startswith("I;16") or img.mode == "I":
        img = img.convert("I").point(lambda v: v * (1 / 257))

    # Composite onto black so transparency reads as background, not as white.
    if img.mode in ("RGBA", "LA", "P", "PA"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (0, 0, 0, 255))
        img = Image.alpha_composite(bg, img)
    img = img.convert("L")

    if stretch:
        img = img.resize((w, h), Image.LANCZOS)
    elif img.size != (w, h):
        # contain(), not thumbnail(): thumbnail only ever shrinks, so an icon
        # drawn at half size stayed half size, a postage stamp in the middle of
        # the frame - while ImageMagick's -resize scaled the same file up to
        # fill it. "Scaled to fit" is both directions.
        from PIL import ImageOps

        fitted = ImageOps.contain(img, (w, h), Image.LANCZOS)
        canvas = Image.new("L", (w, h), 0)
        canvas.paste(fitted, ((w - fitted.width) // 2, (h - fitted.height) // 2))
        img = canvas

    if invert:
        from PIL import ImageOps

        img = ImageOps.invert(img)

    if dither:
        # Dither to 16 levels by quantising through a 16-entry grey palette.
        pal = Image.new("P", (1, 1))
        pal.putpalette([v for i in range(16) for v in (i * 17,) * 3] + [0] * (768 - 48))
        # Through RGB, not straight from "L". Quantizing a greyscale image
        # reads each grey as a palette *index* rather than matching it against
        # the palette's colours, so only greys 0..15 found their entries and
        # everything brighter landed on the black filler above them: --dither
        # turned a picture almost entirely black.
        fs = getattr(Image, "Dither", Image).FLOYDSTEINBERG
        img = img.convert("RGB").quantize(palette=pal, dither=fs).convert("L")

    # tobytes() rather than getdata(): mode "L" is one byte per pixel, and
    # getdata() is deprecated in Pillow 14.
    return list(img.tobytes())


def load_grey_magick(path, w, h, stretch, dither, invert):
    exe = shutil.which("magick") or shutil.which("convert")
    if not exe:
        die("neither Pillow nor ImageMagick is available")

    geom = f"{w}x{h}!" if stretch else f"{w}x{h}"
    cmd = [exe, path, "-background", "black", "-alpha", "remove", "-alpha", "off",
           "-colorspace", "Gray", "-resize", geom]
    if not stretch:
        cmd += ["-gravity", "center", "-extent", f"{w}x{h}"]
    if invert:
        cmd += ["-negate"]
    # -posterize, not -colors. -colors 16 picks the sixteen greys that best
    # suit this particular image, which are not the panel's sixteen, so two of
    # them could land on the same level: a smooth gradient came out in ten.
    # -posterize 16 is exactly 0, 17, 34 ... 255.
    cmd += ["-dither", "FloydSteinberg" if dither else "None",
            "-posterize", "16", "-depth", "8", "gray:-"]

    run = subprocess.run(cmd, capture_output=True)
    out = run.stdout
    if run.returncode or len(out) != w * h:
        why = run.stderr.decode(errors="replace").strip().splitlines()
        die(f"ImageMagick could not convert {path}"
            + (f": {why[0]}" if why else f" ({len(out)} bytes, expected {w * h})"))
    return list(out)


def to_gsc(pixels, w, h):
    # 8 bits per sample down to 4, to the nearest level. 255 -> f.
    nibbles = "".join("%x" % level(p) for p in pixels)
    body = "\n".join(nibbles[i:i + 128] for i in range(0, len(nibbles), 128))
    return (f"#define icon_width {w}\n"
            f"#define icon_height {h}\n"
            "static unsigned char icon_bits[] = {\n"
            f"{body}\n")


def to_header(pixels, w, h, name, argv):
    # Two pixels per byte, high nibble on the left. That is the SSD1322
    # framebuffer layout and exactly what `xxd -r -p` makes of a .gsc, so the
    # array can be handed to draw4bppBitmap() as it stands.
    if w % 2:
        die(f"width {w} is odd - a 4bpp row must be a whole number of bytes")
    data = [(level(pixels[i]) << 4) | level(pixels[i + 1])
            for i in range(0, len(pixels), 2)]
    body = "\n".join("  " + ", ".join("0x%02x" % b for b in data[i:i + 12])
                     + ("," if i + 12 < len(data) else "")
                     for i in range(0, len(data), 12))
    guard = name.upper() + "_H"
    cmd = "./tools/png2gsc.py " + " ".join(argv)
    return (f"// {name}.h - generated by tools/png2gsc.py. Do not edit.\n"
            "//\n"
            f"//   {cmd}\n"
            "//\n"
            f"// {w}x{h} at 4bpp, two pixels per byte, high nibble on the left -\n"
            "// the SSD1322 framebuffer layout, so it is copied straight into a\n"
            "// picture buffer and handed to draw4bppBitmap().\n"
            "\n"
            f"#ifndef {guard}\n"
            f"#define {guard}\n"
            "\n"
            f"#define {name}_width  {w}\n"
            f"#define {name}_height {h}\n"
            f"const uint8_t PROGMEM {name}_bits[{len(data)}] = {{\n"
            f"{body}\n"
            "};\n"
            "\n"
            f"#endif  // {guard}\n")


def main():
    ap = argparse.ArgumentParser(
        description="Convert an image to a tty2oled .gsc",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("A .gsc is")[0])
    ap.add_argument("image", nargs="?",
                    help="source image; omit it with --blank")
    ap.add_argument("--blank", action="store_true",
                    help="write an all-black image of the right size and "
                         "format, with no source - a placeholder to overwrite")
    ap.add_argument("--out", "-o", help="output path (default: alongside the input)")
    ap.add_argument("--boot", action="store_true",
                    help=f"produce a {BOOT_W}x{BOOT_H} boot screen instead of an "
                         f"{ICON_W}x{ICON_H} icon")
    ap.add_argument("--banner", action="store_true",
                    help=f"produce a {BANNER_W}x{BANNER_H} core banner for "
                         f"pics/GSC instead of an {ICON_W}x{ICON_H} icon")
    ap.add_argument("--stretch", action="store_true",
                    help="fill the frame instead of fitting and centring")
    ap.add_argument("--dither", action="store_true",
                    help="dither to the 16 levels; better for photos, worse for "
                         "flat pixel art")
    ap.add_argument("--invert", action="store_true",
                    help="invert brightness, for art drawn dark-on-light")
    ap.add_argument("--header", action="store_true",
                    help="write a C header for the firmware to compile in "
                         "instead of a .gsc; the array is named after --out")
    ap.add_argument("--backend", choices=("auto", "pillow", "magick"),
                    default="auto",
                    help="image library to use; auto is Pillow when installed, "
                         "ImageMagick otherwise")
    args = ap.parse_args()

    if args.boot and args.banner:
        die("--boot and --banner are different sizes; pick one")
    if args.boot:
        w, h = BOOT_W, BOOT_H
    elif args.banner:
        w, h = BANNER_W, BANNER_H
    else:
        w, h = ICON_W, ICON_H

    if args.blank:
        if not args.out:
            die("--blank needs --out")
        pixels = [0] * (w * h)
    else:
        if not args.image:
            die("give an image, or --blank to write an empty one")
        if not os.path.isfile(args.image):
            die(f"no such file: {args.image}")
        backend = args.backend
        if backend == "auto":
            try:
                import PIL  # noqa: F401
                backend = "pillow"
            except ImportError:
                backend = "magick"
        if backend == "pillow":
            try:
                import PIL  # noqa: F401
            except ImportError:
                die("--backend pillow, but Pillow is not installed")
            pixels = load_grey_pillow(args.image, w, h, args.stretch, args.dither, args.invert)
        else:
            pixels = load_grey_magick(args.image, w, h, args.stretch, args.dither, args.invert)

    if len(pixels) != w * h:
        die(f"got {len(pixels)} pixels, expected {w * h}")

    ext = ".h" if args.header else ".gsc"
    out = args.out or os.path.splitext(args.image)[0] + ext
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w") as fh:
        if args.header:
            # The array and guard are named after the file, so the name has to
            # be a C identifier: "boot-logo.h" would otherwise produce
            # boot-logo_bits[] and fail the firmware build, not this tool.
            name = re.sub(r"\W", "_", os.path.splitext(os.path.basename(out))[0])
            if name[:1].isdigit():
                name = "_" + name
            fh.write(to_header(pixels, w, h, name, sys.argv[1:]))
        else:
            fh.write(to_gsc(pixels, w, h))

    where = "in the firmware" if args.header else "on the wire"
    print(f"{out}  ({w}x{h}, {w * h // 2} bytes {where})")
    levels = len(set(level(p) for p in pixels))
    if args.blank:
        pass
    elif levels <= 2:
        print(f"  note: only {levels} grey level(s) used - the panel has 16, "
              f"so there is a lot of shading available")


if __name__ == "__main__":
    main()
