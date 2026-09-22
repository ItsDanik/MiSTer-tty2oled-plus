#!/usr/bin/env python3
"""
Tests for tools/png2gsc.py, the converter people draw icons and boot screens
through.

Every check runs the tool the way a person does, as a command, and reads the
file it writes. Where the daemon is the consumer the file goes through the
daemon's own pipeline - `tail -n +4 | xxd -r -p` - rather than a parser written
for the test, since that pipeline is the contract.

Both image backends are covered where both are installed: Pillow, which is
what most people get, and ImageMagick, the fallback. They disagreed on three
things before these tests existed - 16-bit input, which grey levels a photo
lands on, and whether a small image is scaled up - so most checks run twice and
several compare the two directly.

    ./tests/test-png2gsc.py
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "png2gsc.py")
TMP = os.path.join(HERE, "fixtures", "tmp", "png2gsc")

PASS = FAIL = 0


def ok(label, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  \033[32mok\033[0m   {label}")
    else:
        FAIL += 1
        print(f"  \033[31mFAIL\033[0m {label}\n       want: [{want}]\n       got:  [{got}]")


def skip(label, why):
    print(f"  \033[33mskip\033[0m {label} ({why})")


def section(name):
    print(f"\n\033[1m{name}\033[0m")


try:
    from PIL import Image
except ImportError:
    print("Pillow is not installed - it is needed to draw the test images. Skipping.")
    sys.exit(0)

HAVE_MAGICK = bool(shutil.which("magick") or shutil.which("convert"))
BACKENDS = ["pillow"] + (["magick"] if HAVE_MAGICK else [])

shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP)

SIZES = {"icon": (86, 64, []), "boot": (256, 54, ["--boot"]),
         "banner": (256, 64, ["--banner"])}


def fx(name):
    return os.path.join(TMP, name)


def png2gsc(*args):
    return subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True)


def convert(src, out, *args, backend="pillow"):
    r = png2gsc("--backend", backend, *args, "-o", out, src)
    if r.returncode:
        raise SystemExit(f"png2gsc failed on {src}: {r.stderr}")
    return out


def body(path):
    """The pixel nibbles of a .gsc, one character per pixel."""
    with open(path) as fh:
        return "".join(fh.read().split("\n")[3:]).strip()


def rows(path, w):
    b = body(path)
    return [b[i:i + w] for i in range(0, len(b), w)]


def wire(path):
    """What the daemon sends: tty2oled.sh does `tail -n +4 | xxd -r -p`."""
    env = dict(os.environ, PATH=os.path.join(HERE, "bin") + os.pathsep + os.environ["PATH"])
    return subprocess.run(f"tail -n +4 '{path}' | xxd -r -p", shell=True,
                          capture_output=True, env=env).stdout


# ---------------------------------------------------------------------------
# Test images. Art in the intended palette: sixteen vertical bands, band i at
# grey i*17, so an exact conversion reads 0123...f across every row.
# ---------------------------------------------------------------------------
W, H = 86, 64
BAND = [min(x * 16 // W, 15) for x in range(W)]
WANT_BANDS = "".join("%x" % b for b in BAND) * H


def bands_l():
    im = Image.new("L", (W, H))
    im.putdata([BAND[x] * 17 for y in range(H) for x in range(W)])
    return im


bands_l().save(fx("bands-l8.png"))
bands_l().convert("RGB").save(fx("bands-rgb.png"))
bands_l().convert("P").save(fx("bands-pal.png"))
bands_l().convert("RGBA").save(fx("bands-rgba.png"))
# 16-bit greyscale, which is what GIMP and Krita export at 16-bit precision.
im16 = Image.new("I;16", (W, H))
im16.putdata([BAND[x] * 17 * 257 for y in range(H) for x in range(W)])
im16.save(fx("bands-l16.png"))
if HAVE_MAGICK:
    magick = shutil.which("magick") or shutil.which("convert")
    subprocess.run([magick, fx("bands-rgb.png"), "-depth", "16", fx("bands-rgb16.png")], check=True)

# A smooth ramp, 0..255 across a banner, for everything that is not palette art.
ramp = Image.new("L", (256, 64))
ramp.putdata([x for y in range(64) for x in range(256)])
ramp.save(fx("ramp.png"))

# ===========================================================================
section("the file format the daemon and firmware expect")
# ===========================================================================

# The sizes are literals here and in the firmware, which cannot read each
# other. A mismatch is a transfer the firmware drops as truncated.
with open(os.path.join(ROOT, "MiSTer_SSD1322_USB", "metadisplay.h")) as fh:
    md = fh.read()
fw_icon = (int(re.search(r"#define ICON_W\s+(\d+)", md).group(1)),
           int(re.search(r"#define ICON_H\s+(\d+)", md).group(1)))
ok("icon size agrees with the firmware's ICON_W x ICON_H", SIZES["icon"][:2], fw_icon)
ok("a banner is the whole 8192-byte panel", 256 * 64 // 2, 8192)

for kind, (w, h, flag) in SIZES.items():
    out = convert(fx("bands-l8.png"), fx(f"fmt-{kind}.gsc"), *flag)
    with open(out) as fh:
        lines = fh.read().split("\n")
    # tail -n +4 is hardcoded in the daemon: three header lines, exactly.
    ok(f"{kind}: exactly three header lines",
       lines[:3], [f"#define icon_width {w}", f"#define icon_height {h}",
                   "static unsigned char icon_bits[] = {"])
    ok(f"{kind}: the body is hex digits only",
       bool(re.fullmatch(r"[0-9a-f\n]*", "\n".join(lines[3:]))), True)
    ok(f"{kind}: one character per pixel", len(body(out)), w * h)
    ok(f"{kind}: the daemon's pipeline sends {w * h // 2} bytes", len(wire(out)), w * h // 2)

# ===========================================================================
section("palette art converts exactly")
# ===========================================================================

for be in BACKENDS:
    for name, what in [("l8", "8-bit grey"), ("rgb", "RGB"), ("pal", "palette"),
                       ("rgba", "opaque RGBA"), ("l16", "16-bit grey"),
                       ("rgb16", "16-bit RGB")]:
        if name == "rgb16" and not HAVE_MAGICK:
            skip(f"{be}: {what}", "no ImageMagick to make the file")
            continue
        out = convert(fx(f"bands-{name}.png"), fx(f"bands-{name}.{be}.gsc"), backend=be)
        ok(f"{be}: {what}, all sixteen levels exact", body(out), WANT_BANDS)

for be in BACKENDS:
    out = convert(fx("bands-l8.png"), fx(f"inv.{be}.gsc"), "--invert", backend=be)
    ok(f"{be}: --invert turns level i into 15-i",
       body(out), "".join("%x" % (15 - int(c, 16)) for c in WANT_BANDS))

# ===========================================================================
section("transparency, photos and gradients")
# ===========================================================================

# Left half transparent, right half opaque white: transparency is background,
# which on this panel is black, not the white a naive convert gives it.
half = Image.new("RGBA", (W, H), (255, 255, 255, 255))
for y in range(H):
    for x in range(W // 2):
        half.putpixel((x, y), (255, 255, 255, 0))
half.save(fx("half-transparent.png"))
for be in BACKENDS:
    r = rows(convert(fx("half-transparent.png"), fx(f"alpha.{be}.gsc"), backend=be), W)
    ok(f"{be}: transparent pixels are black", {c for row in r for c in row[:W // 2]}, {"0"})
    ok(f"{be}: opaque white stays white", {c for row in r for c in row[W // 2:]}, {"f"})

ramps = {}
for be in BACKENDS:
    out = convert(fx("ramp.png"), fx(f"ramp.{be}.gsc"), "--banner", backend=be)
    ramps[be] = body(out)
    row = ramps[be][:256]
    # ImageMagick's -colors picked sixteen greys to suit the image, not the
    # panel's sixteen, and several landed on one level: a ramp came out in ten.
    ok(f"{be}: a smooth ramp uses all sixteen levels", len(set(ramps[be])), 16)
    ok(f"{be}: and only ever gets brighter", all(row[i] <= row[i + 1] for i in range(255)), True)
    # Nearest level, not truncated: 255 is the top level and so is anything
    # within half a level of it.
    ok(f"{be}: grey 128 lands on level 8 (the nearest)", row[128], "8")
    ok(f"{be}: grey 9 lands on level 1, not 0", row[9], "1")

if len(BACKENDS) == 2:
    worst = max(abs(int(a, 16) - int(b, 16)) for a, b in zip(ramps["pillow"], ramps["magick"]))
    ok("the two backends agree on a ramp, pixel for pixel", worst, 0)
else:
    skip("the two backends agree on a ramp", "no ImageMagick")

for be in BACKENDS:
    plain = body(fx(f"ramp.{be}.gsc"))
    out = convert(fx("ramp.png"), fx(f"ramp-dither.{be}.gsc"), "--banner", "--dither", backend=be)
    d = body(out)
    mean = lambda s: sum(int(c, 16) for c in s) / len(s)
    ok(f"{be}: --dither keeps the overall brightness", abs(mean(d) - mean(plain)) < 0.25, True)
    ok(f"{be}: --dither still reaches all sixteen levels", len(set(d)), 16)

# ===========================================================================
section("fitting an image of another size")
# ===========================================================================

def lit_box(path, w):
    r = rows(path, w)
    pts = [(x, y) for y, row in enumerate(r) for x, c in enumerate(row) if c != "0"]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1

# A 172x32 white bar is twice as wide as the icon and the same shape as a
# 86x16 strip: it must shrink to that, centred, and keep its aspect ratio.
Image.new("L", (172, 32), 255).save(fx("wide.png"))
# Drawn at half size. thumbnail() never enlarged, so this came out as a
# postage stamp on Pillow and full-frame on ImageMagick.
Image.new("L", (43, 32), 255).save(fx("small.png"))
Image.new("L", (10, 100), 255).save(fx("tall.png"))
for be in BACKENDS:
    x, y, w, h = lit_box(convert(fx("wide.png"), fx(f"wide.{be}.gsc"), backend=be), W)
    ok(f"{be}: a large image shrinks to fit, aspect kept", (w, h), (86, 16))
    ok(f"{be}: and is centred vertically on black", y, (64 - 16) // 2)
    ok(f"{be}: a small image is scaled up to fit",
       lit_box(convert(fx("small.png"), fx(f"small.{be}.gsc"), backend=be), W)[2:], (86, 64))
    ok(f"{be}: --stretch fills the frame whatever the shape",
       body(convert(fx("tall.png"), fx(f"tall.{be}.gsc"), "--stretch", backend=be)), "f" * (W * H))

# ===========================================================================
section("--header, for compiling a picture into the firmware")
# ===========================================================================

def array(path):
    with open(path) as fh:
        return bytes(int(v, 16) for v in re.findall(r"0x([0-9a-f]{2})", fh.read().split("{", 1)[1]))

gsc = convert(fx("ramp.png"), fx("hdr.gsc"), "--boot")
hdr = convert(fx("ramp.png"), fx("hdr.h"), "--boot", "--header")
ok("the array holds exactly what the daemon would send", array(hdr), wire(gsc))
ok("and is 6912 bytes for a boot picture", len(array(hdr)), 6912)

# The array is named after the file, and a file name is not a C identifier.
hdr = convert(fx("ramp.png"), fx("boot-logo.h"), "--boot", "--header")
with open(hdr) as fh:
    text = fh.read()
ok("a hyphenated name becomes a valid array name", "boot_logo_bits[" in text, True)
ok("and a valid include guard", "#ifndef BOOT_LOGO_H" in text, True)
if shutil.which("g++"):
    src = fx("compile.cpp")
    with open(src, "w") as fh:
        fh.write('#include <stdint.h>\n#define PROGMEM\n#include "boot-logo.h"\n'
                 'int main() { return boot_logo_bits[0] + boot_logo_width; }\n')
    r = subprocess.run(["g++", "-fsyntax-only", "-Wall", "-Werror", src], capture_output=True, text=True)
    ok("the header compiles", r.returncode, 0)
else:
    skip("the header compiles", "no g++")

# bootlogo.h says "generated, do not edit" and records the command that made
# it. Hold it to that: the command must reproduce it from bootlogo.png, or the
# picture in the firmware is no longer the picture in the repository.
logo_h = os.path.join(ROOT, "MiSTer_SSD1322_USB", "bootlogo.h")
with open(logo_h) as fh:
    recorded = fh.read().split("\n")[2]
args = recorded.split("./tools/png2gsc.py ", 1)[1].split()
i = args.index("-o")
regen = fx("bootlogo.h")
args[i + 1] = regen
args = [a if not a.endswith(".png") else os.path.join(ROOT, a) for a in args]
r = png2gsc(*args)
with open(logo_h) as a, open(regen) as b:
    same = [l for n, l in enumerate(a.read().split("\n")) if n != 2] == \
           [l for n, l in enumerate(b.read().split("\n")) if n != 2]
ok("bootlogo.h is what its own recorded command produces", same, True)

# ===========================================================================
section("everything else a person can type")
# ===========================================================================

r = png2gsc("--blank", "-o", fx("blank.gsc"))
ok("--blank writes an all-black icon", body(fx("blank.gsc")), "0" * (W * H))
r = png2gsc("--blank", "--boot", "-o", fx("blank-boot.gsc"))
ok("--blank --boot is boot-sized", len(body(fx("blank-boot.gsc"))), 256 * 54)

shutil.copy(fx("bands-l8.png"), fx("beside.png"))
png2gsc(fx("beside.png"))
ok("with no --out the .gsc lands beside the image", os.path.exists(fx("beside.gsc")), True)

with open(fx("not-an-image.png"), "w") as fh:
    fh.write("this is text\n")


def refused(label, *args, out=None):
    r = png2gsc(*args)
    ok(f"{label}: refused", r.returncode != 0, True)
    ok(f"{label}: with a message, not a traceback",
       r.stderr.startswith(("png2gsc: ", "usage: ")) and "Traceback" not in r.stderr, True)
    if out:
        ok(f"{label}: and nothing written", os.path.exists(out), False)


refused("no image and no --blank")
refused("--blank without --out", "--blank")
refused("--boot with --banner", "--boot", "--banner", fx("bands-l8.png"))
refused("a file that does not exist", "-o", fx("gone.gsc"), fx("gone.png"), out=fx("gone.gsc"))
for be in BACKENDS:
    refused(f"{be}: a file that is not an image", "--backend", be,
            "-o", fx(f"junk.{be}.gsc"), fx("not-an-image.png"), out=fx(f"junk.{be}.gsc"))

print(f"\n\033[1mResults:\033[0m {PASS} passed, {FAIL} failed\n")
sys.exit(1 if FAIL else 0)
