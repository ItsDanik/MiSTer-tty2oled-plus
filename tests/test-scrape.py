#!/usr/bin/env python3
"""
Tests for tools/tty2oledplus_scrape.py, which imports the gamelist.xml a
scraper left in each system's games folder and keeps what it says for the
daemon.

The importer is run as a command, over a fake install and a fake games tree,
and the database it writes is read back both directly and through the
daemon's own lookup_scraped - which is the contract that matters.

    ./tests/test-scrape.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "tty2oledplus_scrape.py")
META = os.path.join(ROOT, "tty2oled-meta.sh")
TMP = os.path.join(HERE, "fixtures", "tmp", "scrape")

PASS = FAIL = 0


def ok(label, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  \033[32mok\033[0m   {label}")
    else:
        FAIL += 1
        print(f"  \033[31mFAIL\033[0m {label}\n       want: [{want}]\n       got:  [{got}]")


def section(name):
    print(f"\n\033[1m{name}\033[0m")


# ---------------------------------------------------------------------------
# A fake install and a fake games tree, on two roots - the SD card and USB.
# ---------------------------------------------------------------------------
shutil.rmtree(TMP, ignore_errors=True)
INSTALL = os.path.join(TMP, "tty2oledplus")
ROOT_A = os.path.join(TMP, "sd")
ROOT_B = os.path.join(TMP, "usb0")
os.makedirs(os.path.join(INSTALL, "pics", "icon"))
shutil.copy(os.path.join(ROOT, "tty2oled-system.ini"), INSTALL)
for icon in ("NES", "SNES", "MegaDrive", "Genesis", "NEOGEO", "GBC"):
    open(os.path.join(INSTALL, "pics", "icon", icon + ".gsc"), "w").close()
with open(os.path.join(INSTALL, "tty2oled-user.ini"), "w") as f:
    f.write('GAME_ROOTS="%s %s %s"\n' % (ROOT_A, ROOT_B, os.path.join(TMP, "nowhere")))


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def run(*args):
    p = subprocess.run([sys.executable, TOOL, "--install", INSTALL] + list(args),
                       capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr


def db(system):
    path = os.path.join(INSTALL, "scraped", system + ".txt")
    try:
        with open(path) as f:
            return [l.rstrip("\n").split("|") for l in f if l.strip()]
    except OSError:
        return []


def entry(system, key):
    for row in db(system):
        if row[0] == key:
            return row
    return None


# ---------------------------------------------------------------------------
section("which systems are offered")
rc, out = run("--list-systems")
listed = [l.split("\t") for l in out.splitlines()]
ok("one per console with an icon, and the arcade, keyed and labelled", [l[0] for l in listed],
   ["NES", "SNES", "GBC", "MegaDrive", "NeoGeo", "Arcade"])
ok("the Mega Drive once, though both of its icons ship", sum(1 for l in listed if l[0] == "MegaDrive"), 1)
ok("a label to show in the menu", listed[0][1], "Nintendo NES")
rc, out = run("--systems", "")
ok("no systems named: exit 2", rc, 2)
rc, out = run("--systems", "GBA")
ok("nor a system without an icon", rc, 2)

# ---------------------------------------------------------------------------
section("gamelist.xml: what a scraper wrote, imported")
GL = """<?xml version="1.0"?>
<gameList>
  <folder><path>./sub</path><name>Sub</name></folder>
  <game id="1">
    <path>./Super Mario Bros. (World).nes</path>
    <name>Super Mario Bros.</name>
    <desc>Mario&#8217;s first café
adventure &amp; more | pipes.</desc>
    <rating>0.8</rating>
    <releasedate>19850913T000000</releasedate>
    <developer>Nintendo R&amp;D4</developer>
    <publisher>Nintendo</publisher>
    <genre>Platform</genre>
    <players>1-2</players>
    <family>Mario</family>
    <image>./images/smb.png</image>
  </game>
  <game>
    <path>./sub/Zelda (USA).nes</path>
    <name>The Legend of Zelda</name>
    <releasedate>19860000T000000</releasedate>
  </game>
  <game><path>./Nothing.nes</path></game>
</gameList>
"""
write(os.path.join(ROOT_A, "games", "NES", "gamelist.xml"), GL.encode())
write(os.path.join(ROOT_B, "games", "nes", "GameList.xml"),
      b"<gameList><game><path>./Metroid (USA).nes</path><name>Metroid</name>"
      b"<desc>Samus again.</desc></game></gameList>")
# The Game Boy Color's games may live in GAMEBOY, whose gamelist lists .gb
# games too - only the .gbc ones are the Color's.
write(os.path.join(ROOT_A, "games", "GAMEBOY", "gamelist.xml"),
      b"<gameList><game><path>./Tetris.gb</path><name>Tetris</name></game>"
      b"<game><path>./Wario Land 2.gbc</path><name>Wario Land II</name></game></gameList>")

rc, out = run("--systems", "NES,GBC")
ok("imported", rc, 0)
ok("from both roots, whatever the file's case", len(db("NES")), 3)
smb = entry("NES", "Super Mario Bros. (World)")
ok("keyed on the file name without its extension", smb and smb[2], "ok")
ok("twelve fields, as the daemon reads them", len(smb), 12)
ok("the name",       smb[3], "Super Mario Bros.")
ok("the date, as ours", smb[4], "1985-09-13")
ok("players",        smb[5], "1-2")
ok("the rating, 0.8 of 1 as 16 of 20", smb[6], "16")
ok("genre, developer, publisher", (smb[7], smb[8], smb[9]), ("Platform", "Nintendo R&D4", "Nintendo"))
ok("the family is the series", smb[10], "Mario")
ok("the description: entities undone, ASCII, one line, no separators",
   smb[11], "Mario's first cafe adventure & more / pipes.")
ok("no CRC - it keys on the name", smb[1], "")
zelda = entry("NES", "Zelda (USA)")
ok("a game in a subfolder", zelda and zelda[3], "The Legend of Zelda")
ok("a year alone stays a year", zelda[4], "1986")
ok("an entry with nothing but a path is not a game found", entry("NES", "Nothing"), None)
ok("a folder shared with another system gives only this one's games",
   [r[0] for r in db("GBC")], ["Wario Land 2"])
ok("the summary counts files, games and descriptions", "2      3            2" in out, True)

# ---------------------------------------------------------------------------
section("the daemon reads what the importer wrote")
sh = r'''
SCRAPE_DIR="%s/scraped"
. "%s"
lookup_scraped "$1" "" NES || { echo miss; exit; }
printf '%%s|%%s|%%s|%%s|%%s' "${SCR_TITLE}" "${SCR_PLAYERS}" "${SCR_RATING}" "${SCR_RELEASED}" "${SCR_DESC}"
''' % (INSTALL, META)


def daemon(name):
    return subprocess.run(["bash", "-c", sh, "x", name], capture_output=True, text=True).stdout.strip()


ok("the same fields, in the same places", daemon("Super Mario Bros. (World).nes"),
   "Super Mario Bros.|1-2|16|1985-09-13|Mario's first cafe adventure & more / pipes.")
ok("found without the extension too", daemon("Zelda (USA)").split("|")[0], "The Legend of Zelda")
ok("and a game no gamelist lists is no hit", daemon("Castlevania (USA).nes"), "miss")

# ---------------------------------------------------------------------------
section("arcade: games/mame, beside the zips, keyed by set")
write(os.path.join(ROOT_B, "games", "MAME", "gamelist.xml"), b"""<gameList>
  <game><path>./dkong.zip</path><name>Donkey Kong</name>
    <desc>A barrel of fun.</desc><players>2</players>
    <developer>Nintendo R&amp;D1, Ikegami</developer><rating>0.9</rating></game>
  <game><path>./notes.txt</path><name>Not a game</name></game>
</gameList>""")
write(os.path.join(ROOT_A, "games", "hbmame", "gamelist.xml"),
      b"<gameList><game><path>./sf2hack.zip</path><name>SF2 Hack</name></game>"
      b"<game><path>./readme.txt</path><name>Readme</name></game></gameList>")
# _Arcade holds the .mra files, not what a scraper writes: not searched.
write(os.path.join(ROOT_A, "_Arcade", "gamelist.xml"),
      b"<gameList><game><path>./1942 (Revision B).mra</path><name>1942</name></game></gameList>")
rc, out = run("--systems", "Arcade")
ok("imported", rc, 0)
ok("keyed on the set's name", entry("Arcade", "dkong")[11], "A barrel of fun.")
ok("its fields as a console game's", (entry("Arcade", "dkong")[5], entry("Arcade", "dkong")[6]), ("2", "18"))
ok("games/mame is the arcade's own: taken whole", entry("Arcade", "notes")[3], "Not a game")
ok("games/hbmame is shared: its sets only", (entry("Arcade", "sf2hack")[3], entry("Arcade", "readme")),
   ("SF2 Hack", None))
ok("and _Arcade is not searched at all", entry("Arcade", "1942 (Revision B)"), None)

sh_arcade = r'''
SCRAPE_DIR="%s/scraped"
. "%s"
MRA_SETNAME="$1"
arcade_lookup_scraped "$2" || { echo miss; exit; }
printf '%%s|%%s' "${SCR_TITLE}" "${SCR_DESC}"
''' % (INSTALL, META)


def daemon_arcade(setname, core):
    return subprocess.run(["bash", "-c", sh_arcade, "x", setname, core],
                          capture_output=True, text=True).stdout.strip()


ok("the daemon finds a set by the .mra's set name",
   daemon_arcade("dkong", "dkong"), "Donkey Kong|A barrel of fun.")
ok("or by the core name when the .mra names no set",
   daemon_arcade("", "dkong"), "Donkey Kong|A barrel of fun.")
ok("and nothing for a set no gamelist lists", daemon_arcade("puckman", "puckman"), "miss")

# ---------------------------------------------------------------------------
section("importing again")
# It replaces what was there for the games it lists and leaves every other
# game alone.
with open(os.path.join(INSTALL, "scraped", "NES.txt"), "a") as f:
    f.write("Other Game||ok|Other||||||||kept\n")
write(os.path.join(ROOT_B, "games", "nes", "GameList.xml"),
      b"<gameList><game><path>./Metroid (USA).nes</path><name>Metroid II</name></game></gameList>")
run("--systems", "NES")
ok("an import replaces the game's line", entry("NES", "Metroid (USA)")[3], "Metroid II")
ok("and keeps the others", entry("NES", "Other Game")[11], "kept")
ok("one line a game", len([r for r in db("NES") if r[0] == "Metroid (USA)"]), 1)

write(os.path.join(ROOT_B, "games", "nes", "GameList.xml"), b"<gameList><game><path>broken")
rc, out = run("--systems", "NES")
ok("a broken file is reported", "could not be read" in out.lower(), True)
ok("the good one is still imported", entry("NES", "Super Mario Bros. (World)")[3], "Super Mario Bros.")
ok("and nothing already there is lost", entry("NES", "Metroid (USA)")[3], "Metroid II")

rc, out = run("--systems", "SNES")
ok("none to be found says where to put one",
   ("games/NES/gamelist.xml" in out, "games/mame/gamelist.xml" in out), (True, True))
ok("and writes no file for it", os.path.exists(os.path.join(INSTALL, "scraped", "SNES.txt")), False)

# ---------------------------------------------------------------------------
section("in-process: the parts that are easier to reach directly")
spec = importlib.util.spec_from_file_location("scrape", TOOL)
scrape = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scrape)

ok("folding: accents, typography, separators",
   scrape.fold("Pøkémon—“Red” | Blue…"), 'Pokemon-"Red" / Blue...')
ok("folding: HTML entities", scrape.fold("Tom &amp; Jerry"), "Tom & Jerry")
long = ("word " * 600).strip()
ok("a long description with no sentence to end at is cut at a word, within 2048",
   (len(scrape.clip_desc(long)) <= 2048, scrape.clip_desc(long).endswith("word...")), (True, True))
said = ("It is a game. " * 200).strip()
ok("one with sentences stops at the last that fits, with no '...'",
   (len(scrape.clip_desc(said)) <= 2048, scrape.clip_desc(said).endswith("a game.")), (True, True))
dr = "x" * 1500 + ". Then " + "y" * 20 + " and Dr. Mario " + "z " * 400
ok("'Dr.' does not end a sentence",
   scrape.clip_desc(dr).endswith("x."), True)
short = "A short one. It fits."
ok("a description that fits is left alone", scrape.clip_desc(short), short)


# One limit, in three files that cannot read each other: the firmware's
# buffer, the daemon's cut and the importer's. A daemon sending more than the
# firmware keeps loses the end mid-word; an importer keeping more than the
# daemon sends has its sentence end cut off.
def const(path, pattern):
    import re
    with open(os.path.join(ROOT, path)) as f:
        m = re.search(pattern, f.read(), re.M)
    return int(m.group(1)) if m else None


ok("the firmware, the daemon and the importer keep the same length",
   (const("MiSTer_SSD1322_USB/metadisplay.h", r"^#define DESC_MAX\s+(\d+)"),
    const("tty2oled.sh", r"^DESC_MAX_BYTES=(\d+)")),
   (scrape.DESC_MAX, scrape.DESC_MAX))
ok("dates: full, month, year, none",
   [scrape.gl_date(d) for d in ("19850913T000000", "19850900T000000", "19850000T000000",
                                "1991-06-23", "", "00000000T000000")],
   ["1985-09-13", "1985-09", "1985", "1991-06-23", "", ""])
ok("ratings: 0..1 onto 20, anything else nothing",
   [scrape.gl_rating(r) for r in ("0.8", "0.75", "1", "0", "5", "x", "")],
   ["16", "15", "20", "", "", "", ""])

print(f"\n\033[1mResults:\033[0m {PASS} passed, {FAIL} failed\n")
sys.exit(1 if FAIL else 0)
