#!/usr/bin/env python3
"""
png2gsc.py - convert an image to the .gsc format tty2oled displays.

    ./tools/png2gsc.py icon.png                     -> icon.gsc   (86x64)
    ./tools/png2gsc.py --boot splash.png            -> splash.gsc (256x64)
    ./tools/png2gsc.py --out pics/ICON/NES.gsc nes.png

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
    boot   256x64    the whole screen, stored in the ESP's own flash

Both are fixed. An image of another size is scaled to fit and centred on
black rather than stretched, so aspect ratio is kept; pass --stretch to fill
the frame instead.

Pillow is used when it is installed, ImageMagick otherwise.
"""

import argparse
import os
import shutil
import subprocess
import sys

ICON_W, ICON_H = 86, 64
BOOT_W, BOOT_H = 256, 64


def die(msg):
    print(f"png2gsc: {msg}", file=sys.stderr)
    sys.exit(1)


def load_grey_pillow(path, w, h, stretch, dither, invert):
    from PIL import Image

    img = Image.open(path)
    # Composite onto black so transparency reads as background, not as white.
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (0, 0, 0, 255))
        img = Image.alpha_composite(bg, img)
    img = img.convert("L")

    if stretch:
        img = img.resize((w, h), Image.LANCZOS)
    elif img.size != (w, h):
        fitted = img.copy()
        fitted.thumbnail((w, h), Image.LANCZOS)
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
        img = img.quantize(palette=pal, dither=Image.FLOYDSTEINBERG).convert("L")

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
    cmd += ["-dither", "FloydSteinberg" if dither else "None",
            "-colors", "16", "-depth", "8", "gray:-"]

    out = subprocess.run(cmd, capture_output=True).stdout
    if len(out) != w * h:
        die(f"ImageMagick returned {len(out)} bytes, expected {w * h}")
    return list(out)


def to_gsc(pixels, w, h):
    # 8 bits per sample down to 4: the top nibble is the level. 255 -> f.
    nibbles = "".join("%x" % (p >> 4) for p in pixels)
    body = "\n".join(nibbles[i:i + 128] for i in range(0, len(nibbles), 128))
    return (f"#define icon_width {w}\n"
            f"#define icon_height {h}\n"
            "static unsigned char icon_bits[] = {\n"
            f"{body}\n")


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
    ap.add_argument("--stretch", action="store_true",
                    help="fill the frame instead of fitting and centring")
    ap.add_argument("--dither", action="store_true",
                    help="dither to the 16 levels; better for photos, worse for "
                         "flat pixel art")
    ap.add_argument("--invert", action="store_true",
                    help="invert brightness, for art drawn dark-on-light")
    args = ap.parse_args()

    w, h = (BOOT_W, BOOT_H) if args.boot else (ICON_W, ICON_H)

    if args.blank:
        if not args.out:
            die("--blank needs --out")
        pixels = [0] * (w * h)
    else:
        if not args.image:
            die("give an image, or --blank to write an empty one")
        if not os.path.isfile(args.image):
            die(f"no such file: {args.image}")
        try:
            import PIL  # noqa: F401
            pixels = load_grey_pillow(args.image, w, h, args.stretch, args.dither, args.invert)
        except ImportError:
            pixels = load_grey_magick(args.image, w, h, args.stretch, args.dither, args.invert)

    if len(pixels) != w * h:
        die(f"got {len(pixels)} pixels, expected {w * h}")

    out = args.out or os.path.splitext(args.image)[0] + ".gsc"
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w") as fh:
        fh.write(to_gsc(pixels, w, h))

    print(f"{out}  ({w}x{h}, {w * h // 2} bytes on the wire)")
    levels = len(set(p >> 4 for p in pixels))
    if args.blank:
        pass
    elif levels <= 2:
        print(f"  note: only {levels} grey level(s) used - the panel has 16, "
              f"so there is a lot of shading available")


if __name__ == "__main__":
    main()
