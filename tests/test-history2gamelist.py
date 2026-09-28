#!/usr/bin/env python3
"""
Tests for tools/history2gamelist.py, which turns MAME's history.xml into the
gamelist.xml that Scrape metadata imports, for the sets in a ROM folder.

A small history.xml is written here, one entry per rule, in the shapes the
real file uses. The tool is run as a command over it and a fake ROM folder;
what it writes is read back directly, and then imported by the real importer
and looked up by the daemon's own arcade_lookup_scraped - the contract that
matters.

    ./tests/test-history2gamelist.py
"""

import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "history2gamelist.py")
SCRAPE = os.path.join(ROOT, "tools", "tty2oledplus_scrape.py")
META = os.path.join(ROOT, "tty2oled-meta.sh")
TMP = os.path.join(HERE, "fixtures", "tmp", "history2gamelist")

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


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)


# ---------------------------------------------------------------------------
# history.xml. Each entry is in the real file's shape: the "published ... ago"
# line, the "(c)" title line, the description, then "- SECTION -" headings.
# ---------------------------------------------------------------------------
# Descriptions longer than the 2048 the firmware keeps, one per way of
# shortening them. para() is n sentences of len(word) + 24, a space between.
def para(word, n):
    return " ".join(["%s rolls down the girders." % word] * n)


A, B, C = para("Barrel", 46), para("Fire", 20), para("Spring", 28)   # 1425, 579, 867
S900, S2000 = para("Barrel", 28), para("Fire", 65)                    # 867, 1884
LIST = "The courses are:\n" + "\n".join("* Course %d - Somewhere Valley, Elsewhere Road" % i
                                       for i in range(20))
RUNON = "and " * 700 + "on"


def machine(sets, text, kind="Arcade Video game published 45 years ago:"):
    names = "".join('<system name="%s" />' % s for s in sets)
    return "<entry><systems>%s</systems><text>%s\n\n%s</text></entry>" % (names, kind, text)


def software(lst, name, text, kind):
    return ('<entry><software><item list="%s" name="%s" /></software><text>%s\n\n%s</text></entry>'
            % (lst, name, kind, text))


ENTRIES = [
    # A description of its own: the header, the title and the sections go.
    machine(["dkongj"], "Donkey Kong (c) 1981 Nintendo.\n\n"
            "Donkey Kong is a legendary platform game.\n\n"
            "Jumpman must rescue Pauline &amp; climb.\n\n"
            "- TECHNICAL -\n\nMain CPU : Zilog Z80\n\n- TRIVIA -\n\nReleased in July 1981."),
    # A clone pointing at it by quoted title.
    machine(["dkong", "dkongo"], "Donkey Kong (c) 1981 Nintendo of America.\n\n"
            "Export version for North America. For more information about the game itself, "
            'please see the original Japanese upright version entry; "Donkey Kong [Upright model]".\n\n'
            "- TECHNICAL -\n\n[Upright model]"),
    # A clone pointing by nothing but its own title, and listing differences.
    machine(["karnovj"], "Karnov (c) 1987 Data East.\n\nKarnov is a platform game."),
    machine(["karnov"], "Karnov (c) 1987 Data East USA.\n\n"
            "North American release. Game developed in Japan. See the original version for "
            "more information.\n\nThis US version has:\n* More enemies.\n* The ostrich."),
    # A Japanese original, found by its romanisation.
    machine(["sscandal"], "青春スキャンダル (c) 1985 Sega.\n"
            "(Seishun Scandal)\n\nA maze game of young love."),
    machine(["myhero"], "My Hero (c) 1985 Sega.\n\nExport release. Game developed in Japan. "
            "For more information about the game itself, please see the original Japanese "
            'release entry; "Seishun Scandal".'),
    # Two entries share a title; the bracket's ID picks the right one.
    machine(["ddonpach"], "DoDonPachi (c) 1997 Atlus.\n\nThe short one.\n\n"
            "- TECHNICAL -\n\nGame ID : AT-DD1"),
    machine(["ddonpachj"], "DoDonPachi (c) 1997 Cave.\n\nThe real one, which is longer "
            "than the other in every respect.\n\n- TECHNICAL -\n\nGame ID : CV-DDP"),
    machine(["ddonpacha"], "DoDonPachi (c) 1997 Cave.\n\nExport release. For more information, "
            'please see the original entry; "DoDonPachi [Model AT-DD1]".'),
    # PlayChoice's Tennis: the NES cartridge, not the longer Atari 2600 one of
    # the same name, and not the tabletop machine called Tennis either.
    software("a2600", "tennis", "Tennis (c) 1981 Activision.\n\n"
             "Tennis on the Atari 2600, described at far greater length than any other "
             "entry here so that length alone would pick it.", "Atari 2600 cart.:"),
    machine(["tmtennis"], "Tennis (c) 1980 Tomy.\n\nTabletop VFD game.",
            kind="Tabletop game published 46 years ago:"),
    software("nes", "tennisu", "Tennis (c) 1985 Nintendo.\n\nNES tennis, a match.",
             "Nintendo NES NTSC cart. published 41 years ago:"),
    machine(["pc_tenis"], "Tennis (c) 1985 Nintendo.\n\nPlayChoice-10 version. For more "
            "information about the game itself, please see the original NES version.",
            kind="Nintendo PlayChoice-10 cart. published 40 years ago:"),
    # A chain: PlayChoice -> the NES cartridge, itself a pointer -> Famicom.
    software("famicom", "golf", "Golf (c) 1984 Nintendo.\n\nFamicom golf, eighteen holes.",
             "Nintendo Famicom cart. published 42 years ago:"),
    software("nes", "golfu", "Golf (c) 1985 Nintendo.\n\nNorth American release. "
             "For more information, please see the original Famicom version.",
             "Nintendo NES NTSC cart. published 41 years ago:"),
    machine(["pc_golf"], "Golf (c) 1985 Nintendo.\n\nPlayChoice-10 version. For more "
            "information about the game itself, please see the original NES version.",
            kind="Nintendo PlayChoice-10 cart. published 40 years ago:"),
    # Pointers whose original has no description: an informative note is
    # kept, a bare release note is not.
    machine(["barekj"], "Bare Knuckle (c) 1991 Sega.\n\n- TRIVIA -\n\nReleased in 1991."),
    machine(["barekch"], "Bare Knuckle (c) 1991 bootleg.\n\n"
            "Coin-op pirate version of the Mega Drive game."),
    machine(["aerofgts"], "Bare Knuckle (c) 1991 Sega.\n\nNorth American release."),
    # An entry with a description of its own and a "see the original" about
    # its ports: only that sentence goes.
    machine(["gradius"], "Gradius (c) 1985 Konami.\n\nA horizontal shooter. For the list of "
            "ports, please see the original Japanese version entry. Options follow you."),
    # No description at all.
    machine(["ldrun4"], "Lode Runner (c) 1986 Irem.\n\n- TECHNICAL -\n\nIrem M-62"),
    # Longer than the firmware keeps.
    machine(["dkongjr"], "Donkey Kong Jr. (c) 1982 Nintendo.\n\n"
            + "\n\n".join([A, B, C])),
    machine(["mpatrol"], "Moon Patrol (c) 1982 Irem.\n\n"
            + "\n\n".join([A, "*CAST OF CHARACTERS*", C])),
    machine(["simon"], "Simon (c) 1978 Milton Bradley.\n\n" + "\n\n".join([S900, S2000])),
    machine(["pdrift"], "Power Drift (c) 1988 Sega.\n\n" + "\n\n".join([S900, LIST, C])),
    machine(["runon"], "Run On (c) 1980 Nobody.\n\n" + RUNON),
]
HISTORY = os.path.join(TMP, "history.xml")
ROMS = os.path.join(TMP, "roms")
OUT = os.path.join(TMP, "out")

shutil.rmtree(TMP, ignore_errors=True)
write(HISTORY, '<?xml version="1.0" encoding="UTF-8"?>\n<history version="2.89">\n'
      + "\n".join(ENTRIES) + "\n</history>\n")
for name in ("dkong.zip", "karnov.zip", "myhero.zip", "ddonpacha.zip", "pc_tenis.zip",
             "pc_golf.zip", "barekch.zip", "aerofgts.zip", "gradius.7z", "ldrun4.zip",
             "dkongjr.zip", "mpatrol.zip", "simon.zip", "pdrift.zip", "runon.zip",
             "notinhistory.zip", "readme.txt", ".dkongj.zip", "Karnovj.ZIP"):
    write(os.path.join(ROMS, name), "")
write(os.path.join(ROMS, "sscandal", "sscandal.chd"), "")     # a CHD set is a folder
os.makedirs(os.path.join(ROMS, "0.277-merged"))               # a folder that is not one


def run(*args):
    p = subprocess.run([sys.executable, TOOL, HISTORY, ROMS] + list(args),
                       capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr


def gamelist(folder=OUT):
    root = ET.parse(os.path.join(folder, "gamelist.xml")).getroot()
    return {g.findtext("path"): (g.findtext("name"), g.findtext("desc")) for g in root.iter("game")}


def desc(path):
    return gl.get(path, (None, None))[1]


def title(path):
    return gl.get(path, (None, None))[0]


# ---------------------------------------------------------------------------
section("the ROM folder")
rc, out = run("-o", OUT)
ok("runs", rc, 0)
ok("counts the sets it found: zips, a 7z, a CHD folder, any case",
   "18 set(s) in" in out, True)
gl = gamelist()
paths = set(gl)
ok("a set is written by its file name as it is on disk", "./Karnovj.ZIP" in paths, True)
ok("a CHD set by its folder", "./sscandal" in paths, True)
ok("a 7z is a set", "./gradius.7z" in paths, True)
ok("dotfiles, other files and folders without a CHD are not",
   [p for p in paths if "readme" in p or ".dkongj" in p or "merged" in p], [])
ok("a set history.xml does not know is left out", "./notinhistory.zip" in paths, False)

# ---------------------------------------------------------------------------
section("a description of its own")
ok("the title, from the (c) line", title("./Karnovj.ZIP"), "Karnov")
ok("the description only: no header, no title", desc("./Karnovj.ZIP"), "Karnov is a platform game.")
ok("paragraphs kept, sections cut, entities undone",
   desc("./sscandal"), "A maze game of young love.")
ok("a Japanese title is written in its romanisation", title("./sscandal"), "Seishun Scandal")
ok("a 'see the original' about ports goes, the description stays",
   desc("./gradius.7z"), "A horizontal shooter. Options follow you.")

# ---------------------------------------------------------------------------
section("clones take the original's description")
ok("by the quoted title",
   desc("./dkong.zip"),
   "Donkey Kong is a legendary platform game.\n\nJumpman must rescue Pauline & climb.")
ok("but keep their own title", title("./dkong.zip"), "Donkey Kong")
ok("by their own title when nothing is quoted, the differences list dropped",
   desc("./karnov.zip"), "Karnov is a platform game.")
ok("by a Japanese original's romanisation", desc("./myhero.zip"), "A maze game of young love.")
ok("the bracket's model ID picks between entries of one title",
   desc("./ddonpacha.zip"), "The short one.")
ok("a cartridge only on the platform named, not by length, not another machine kind",
   desc("./pc_tenis.zip"), "NES tennis, a match.")
ok("a pointer to a pointer is followed", desc("./pc_golf.zip"), "Famicom golf, eighteen holes.")
ok("an original with nothing: an informative note of its own is kept",
   desc("./barekch.zip"), "Coin-op pirate version of the Mega Drive game.")
ok("and a bare release note leaves the set out", "./aerofgts.zip" in paths, False)
ok("a set with no description is left out, not written empty", "./ldrun4.zip" in paths, False)

# ---------------------------------------------------------------------------
section("2048.txt: what did not fit, and where it now ends")
with open(os.path.join(OUT, "2048.txt")) as f:
    rows = {l.split("|")[0]: l.rstrip("\n").split("|") for l in f if not l.startswith("#")}


def row(s):
    return rows.get(s, [s, "", "0", "", ""])


ok("lists each set that was shortened, and only those",
   sorted(rows), ["dkongjr", "mpatrol", "pdrift", "runon", "simon"])
ok("with the length it had, what is kept, where it ends, and the title",
   row("dkongjr"), ["dkongjr", str(len(A) + len(B) + len(C) + 2),
                     str(len(A) + len(B) + 1), "paragraph", "Donkey Kong Jr."])
ok("whole paragraphs while they fit",
   desc("./dkongjr.zip"), A + "\n\n" + B)
ok("and not ending on a heading that introduces what was left out",
   (desc("./mpatrol.zip"), row("mpatrol")[3]), (A, "paragraph"))
ok("when that keeps too little, whole sentences of the next paragraph",
   (row("simon")[3], desc("./simon.zip").startswith(S900 + "\n\nFire rolls"),
    desc("./simon.zip").endswith("girders."), int(row("simon")[2]) > 2000), ("sentence", True, True, True))
ok("but never ending on a list, which has no full stop to end at",
   (desc("./pdrift.zip"), row("pdrift")[3]), (S900, "paragraph"))
ok("one sentence too long to keep is left to the importer's cut at a word",
   (desc("./runon.zip"), row("runon")[3], int(row("runon")[2]) <= 2048), (RUNON, "word", True))
ok("a description that fits is written whole", desc("./gradius.7z"),
   "A horizontal shooter. Options follow you.")

# ---------------------------------------------------------------------------
section("not overwriting what it did not write")
rc, out = run("-o", OUT)
ok("its own gamelist.xml is replaced", rc, 0)
FOREIGN = os.path.join(TMP, "foreign")
write(os.path.join(FOREIGN, "gamelist.xml"), "<gameList><game><path>./x.zip</path></game></gameList>")
rc, out = run("-o", FOREIGN)
ok("a scraper's is refused", (rc, "--force" in out), (2, True))
with open(os.path.join(FOREIGN, "gamelist.xml")) as f:
    ok("and left as it was", "./x.zip" in f.read(), True)
rc, out = run("-o", FOREIGN, "--force")
ok("--force replaces it", (rc, "./dkong.zip" in gamelist(FOREIGN)), (0, True))
p = subprocess.run([sys.executable, TOOL, HISTORY, os.path.join(TMP, "nowhere"), "-o", OUT],
                   capture_output=True, text=True)
ok("a ROM folder that is not there: exit 2", p.returncode, 2)

# ---------------------------------------------------------------------------
section("imported, and looked up by the daemon")
INSTALL = os.path.join(TMP, "tty2oledplus")
GAMES = os.path.join(TMP, "sd", "games", "mame")
os.makedirs(os.path.join(INSTALL, "pics", "icon"))
shutil.copy(os.path.join(ROOT, "tty2oled-system.ini"), INSTALL)
write(os.path.join(INSTALL, "tty2oled-user.ini"), 'GAME_ROOTS="%s"\n' % os.path.join(TMP, "sd"))
os.makedirs(GAMES)
shutil.copy(os.path.join(OUT, "gamelist.xml"), GAMES)
p = subprocess.run([sys.executable, SCRAPE, "--install", INSTALL, "--systems", "Arcade"],
                   capture_output=True, text=True, timeout=120)
ok("the importer takes it", p.returncode, 0)

sh = r'''
SCRAPE_DIR="%s/scraped"
. "%s"
MRA_SETNAME="$1"
arcade_lookup_scraped "$1" || { echo miss; exit; }
printf '%%s|%%s' "${SCR_TITLE}" "${SCR_DESC}"
''' % (INSTALL, META)


def daemon(setname):
    return subprocess.run(["bash", "-c", sh, "x", setname], capture_output=True, text=True).stdout.strip()


ok("a clone's description, by its set name",
   daemon("dkong"),
   "Donkey Kong|Donkey Kong is a legendary platform game. Jumpman must rescue Pauline & climb.")
ok("a set named in another case on disk is found by the .mra's lower-case name",
   daemon("karnovj"), "Karnov|Karnov is a platform game.")
ok("a shortened one arrives as it was written, ending at its sentence",
   daemon("dkongjr"), "Donkey Kong Jr.|" + A + " " + B)
got = daemon("runon").split("|", 1)[1]
ok("and one that could not be arrives cut at a word, within 2048",
   (len(got) <= 2048, got.endswith("...")), (True, True))
ok("a set left out is not there", daemon("ldrun4"), "miss")

print(f"\n\033[1mResults:\033[0m {PASS} passed, {FAIL} failed\n")
sys.exit(1 if FAIL else 0)
