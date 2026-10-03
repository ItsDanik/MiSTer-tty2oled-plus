#!/usr/bin/env python3
"""
Tests for tools/tty2oledplus_dvd.py: a DVD's titles, chapters and times read
off the disc, and what Wikipedia says the disc is.

The disc is tests/dvdiso.py's image - ISO9660 with VIDEO_TS IFOs shaped like
the real disc the MiSTer played. Wikipedia is a stand-in that answers from
canned replies, in the shapes the real API returned for that disc.

    ./tests/test-dvd.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "tty2oledplus_dvd.py")
TMP = os.path.join(HERE, "fixtures", "tmp", "dvd-py")

sys.path.insert(0, HERE)
import dvdiso  # noqa: E402

spec = importlib.util.spec_from_file_location("dvd", TOOL)
dvd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dvd)

PASS = FAIL = 0


def ok(label, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print("  \033[32mok\033[0m   %s" % label)
    else:
        FAIL += 1
        print("  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]" % (label, want, got))


def section(s):
    print("\n\033[1m%s\033[0m" % s)


def run(*args):
    p = subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def nav(path):
    cols = {}
    with open(path) as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition(" ")
            cols[k] = v
    return cols


def place(cols, sector):
    """What the daemon's search would find: (title, chapter, seconds)."""
    s = [int(x) for x in cols["start"].split()]
    for i, a in enumerate(s):
        e = [int(x) for x in cols["end"].split()][i]
        if a <= sector <= e:
            t0 = int(cols["t0"].split()[i])
            t1 = int(cols["t1"].split()[i])
            t = t0 + (t1 - t0) * (sector - a) / (e - a + 1)
            return (int(cols["title"].split()[i]), int(cols["chapter"].split()[i]), round(t, 1))
    return None


shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP)
ISO = os.path.join(TMP, "Some Film (2004).iso")
dvdiso.make_iso(ISO)
CACHE = os.path.join(TMP, "cache")

# ---------------------------------------------------------------------------
section("scan: the volume, and its table")
# ---------------------------------------------------------------------------
rc, out = run("scan", "--dev", ISO, "--cache", CACHE)
ok("a DVD-Video volume: exit 0", rc, 0)
key, label, navfile, title = out.split("|")
ok("keyed by its label, date and size", key, "TEST_MOVIE_WS_D1-20041004230725-10120")
ok("the label", label, "TEST_MOVIE_WS_D1")
ok("the table in the cache, named by the key", navfile,
   os.path.join(CACHE, "TEST_MOVIE_WS_D1-20041004230725-10120.nav"))
ok("an image's title is its file's name", title, "Some Film (2004)")

cols = nav(navfile)
ok("it says what it is", open(navfile).readline().strip(), "tty2oledplus-dvd-nav 1")
ok("two titles", cols["titles"], "2")
ok("the main one: title 1, 100s, three chapters", cols["main"], "1 100 3")
ok("its chapters start at 0, 30 and 70s", cols["starts1"], "100 0 30 70")
ok("title 2's at 0 and 20s, 60s in all", cols["starts2"], "60 0 20")
ok("the menus: VIDEO_TS.VOB, and the title set's", cols["menu"], "30 39 110 119")
ok("the films start at the title set's sector 0 - its IFO's place, not the"
   " sector the title table gives (77)", place(cols, 120), (1, 1, 0.0))
ok("a second into cell 1", place(cols, 220), (1, 1, 1.0))
ok("cell 2 starts chapter 2 at 30s", place(cols, 3120), (1, 2, 30.0))
ok("the time map, not a line through the cell: 1000 sectors in is 50s",
   place(cols, 4120), (1, 2, 50.0))
ok("150 sectors a second after that", place(cols, 4120 + 1500), (1, 2, 60.0))
ok("chapter 3", place(cols, 7120), (1, 3, 70.0))
ok("title 2's own sectors are title 2's", place(cols, 9120 + 500), (2, 1, 10.0))
ok("the sectors two titles share go to the one with more chapters", place(cols, 5000)[0], 1)
starts = [int(x) for x in cols["start"].split()]
ends = [int(x) for x in cols["end"].split()]
ok("no sector in two segments", all(e < s for e, s in zip(ends, starts[1:])), True)
ok("each column as long as the rest",
   len({len(cols[k].split()) for k in ("start", "end", "title", "chapter", "chapters", "t0", "t1", "total")}), 1)

# A disc seen before: one sector read, the IFOs never.
with open(ISO, "r+b") as f:
    f.seek(20 * 2048)
    f.write(b"\0" * 2048)          # VIDEO_TS.IFO gone
rc, out = run("scan", "--dev", ISO, "--cache", CACHE)
ok("seen before: the cached table, without the IFOs", (rc, out.split("|")[2]), (0, navfile))

rc, out = run("scan", "--dev", ISO, "--cache", os.path.join(TMP, "other-cache"))
ok("not seen before and unreadable: not DVD-Video, exit 3", rc, 3)
ok("its key and label still said, no table", out.split("|")[:3],
   ["TEST_MOVIE_WS_D1-20041004230725-10120", "TEST_MOVIE_WS_D1", ""])

PLAIN = os.path.join(TMP, "data.iso")
dvdiso.make_iso(PLAIN, label="BACKUP_2001", dvd=False)
rc, out = run("scan", "--dev", PLAIN, "--cache", CACHE)
ok("a data disc: exit 3, no table", (rc, out.split("|")[2]), (3, ""))
with open(os.path.join(TMP, "blank.iso"), "wb") as f:
    f.truncate(40 * 2048)
rc, out = run("scan", "--dev", os.path.join(TMP, "blank.iso"), "--cache", CACHE)
ok("no ISO9660 at all: exit 3, nothing", (rc, out), (3, "|||"))
rc, out = run("scan", "--dev", os.path.join(TMP, "missing.iso"), "--cache", CACHE)
ok("nothing there: exit 1", rc, 1)

# ---------------------------------------------------------------------------
section("a disc's label, made readable")
# ---------------------------------------------------------------------------
ok("underscores, and capitals", dvd.label_title("QUEEN_ON_FIRE_AT_THE_BOWL"), "Queen On Fire At The Bowl")
ok("the disc of a set and the screen shape go", dvd.label_title("MATRIX_WS_D1"), "Matrix")
ok("DISC_2 too", dvd.label_title("THE_DARK_KNIGHT_DISC_2"), "The Dark Knight")
ok("a region and a format", dvd.label_title("ALIEN_16X9_PAL_R2"), "Alien")
ok("nothing left would be nothing: kept", dvd.label_title("DVD_VIDEO"), "Dvd Video")
ok("mixed case is left alone", dvd.label_title("Amelie_2001"), "Amelie 2001")
ok("an image's name, less the dots of a rip", dvd.file_title("/x/Blade.Runner.1982.ISO"), "Blade Runner 1982")
ok("one with spaces as it is", dvd.file_title("/x/Some Film (2004).iso"), "Some Film (2004)")
ok("the key of a disc with no date", dvd.disc_key({"label": "X", "created": "0000000000000000", "blocks": 5}), "X-5")

# ---------------------------------------------------------------------------
section("Wikipedia: the article, its infobox, its introduction")
# ---------------------------------------------------------------------------
QUEEN_BOX = """{{Use dmy dates|date=April 2022}}
{{Infobox album
| name       = Queen on Fire – Live at the Bowl
| type       = Live album
| artist     = [[Queen (band)|Queen]]
| released   = 25 October 2004 (Europe)<br/>9 November 2004 (US)
| studio     =
| genre      = Rock
| label      = [[EMI Records|EMI]]/[[Parlophone]] (Europe)<br/>[[Hollywood Records|Hollywood]] (US)
| producer   = [[Brian May]]<br>[[Roger Taylor (Queen drummer)|Roger Taylor]]
}}
{{Infobox film
| name           = Queen on Fire – Live at the Bowl
| director       = Gavin Taylor
| released       = {{Film date|df=y|2004}}
| runtime        = 170 minutes
}}
'''Queen on Fire''' is a live album."""
QUEEN_INTRO = ("Queen on Fire – Live at the Bowl is a DVD/live album by the British rock band "
               "Queen released on 25 October 2004.\nIt was recorded live at the Milton Keynes Bowl.")


class Wiki:
    """Answers the two requests the lookup makes from canned pages."""
    def __init__(self, hits, pages, fail=False):
        self.hits, self.pages, self.fail, self.asked = hits, pages, fail, []

    def __call__(self, url):
        self.asked.append(url)
        if self.fail:
            raise OSError("no route to host")
        if "list=search" in url:
            return {"query": {"search": [{"title": t} for t in self.hits]}}
        for title, page in self.pages.items():
            if "titles=" + __import__("urllib.parse").parse.quote_plus(title) in url:
                return {"query": {"pages": [page]}}
        return {"query": {"pages": [{"title": "?", "missing": True}]}}


queen = {"title": "Queen on Fire – Live at the Bowl", "extract": QUEEN_INTRO,
         "revisions": [{"slots": {"main": {"content": QUEEN_BOX}}}]}
camilla = {"title": "Queen Camilla", "extract": "Camilla is Queen.",
           "revisions": [{"slots": {"main": {"content": ""}}}]}
w = Wiki(["Queen Camilla", "Queen on Fire – Live at the Bowl"],
         {"Queen Camilla": camilla, "Queen on Fire – Live at the Bowl": queen})
info = dvd.wiki_lookup("Queen On Fire At The Bowl", w)
ok("a search hit that is not the disc is passed over", info and info["title"],
   "Queen on Fire - Live at the Bowl")
ok("the year, from the first box that has one", info["released"], "2004")
ok("the record label, first of the list, no notes in brackets", info["publisher"], "EMI/Parlophone")
ok("the director, from the film's box", info["developer"], "Gavin Taylor")
ok("the band, from a link", info["series"], "Queen")
ok("the genre", info["genre"], "Rock")
ok("the introduction, folded to ASCII, one line", info["desc"],
   "Queen on Fire - Live at the Bowl is a DVD/live album by the British rock band Queen "
   "released on 25 October 2004. It was recorded live at the Milton Keynes Bowl.")
ok("one search and one page: a poor hit is not even fetched",
   len(w.asked), 2)

film = {"title": "Blade Runner", "extract": "Blade Runner (/bleId/; stylised) is a 1982 film.",
        "revisions": [{"slots": {"main": {"content": """{{Short description|1982 film}}
{{Infobox film
| name = Blade Runner
| director = [[Ridley Scott]]
| studio = {{ubl|[[The Ladd Company]]|[[Shaw Brothers Studio|Shaw Brothers]]}}
| production_companies = Not this one
| released = {{Film date|1982|6|25}}
}}"""}}}]}
info = dvd.wiki_lookup("Blade Runner 1982", Wiki(["Blade Runner"], {"Blade Runner": film}))
ok("a film: its studio, first of a list template", info["publisher"], "The Ladd Company")
ok("its director, out of a link", info["developer"], "Ridley Scott")
ok("its year, out of a date template", info["released"], "1982")
ok("no artist", info["series"], "")
ok("pronunciations out of the first sentence", info["desc"], "Blade Runner is a 1982 film.")

amb = {"title": "Alien", "pageprops": {"disambiguation": ""}, "extract": "Alien may refer to:"}
info = dvd.wiki_lookup("Alien", Wiki(["Alien"], {"Alien": amb}))
ok("a disambiguation page is no answer", info, None)
info = dvd.wiki_lookup("Matrix Reloaded Bonus", Wiki(["The Matrix"], {"The Matrix": film}))
ok("a hit that says too little of the query is no answer", info, None)

boxes = dvd.infoboxes("{{Infobox film\n| a = [[x|y]] {{z|q}}\n| b = 2\n}}")
ok("an infobox's values keep their own pipes", boxes, [{"a": "[[x|y]] {{z|q}}", "b": "2"}])
ok("a plainlist's first item", dvd.wiki_plain("{{Plainlist|\n* [[Warner Bros.]]\n* Village}}"),
   "Warner Bros.")
ok("a comment and a reference go", dvd.wiki_plain("Fox<!-- a note --><ref name=a>cite</ref>"), "Fox")

# ---------------------------------------------------------------------------
section("lookup: into scraped/DVD.txt, once")
# ---------------------------------------------------------------------------
DB = os.path.join(TMP, "scraped", "DVD.txt")


class Args:
    def __init__(self, key, query):
        self.key, self.query, self.db = key, query, DB


w = Wiki(["Queen on Fire – Live at the Bowl"], {"Queen on Fire – Live at the Bowl": queen})
rc = dvd.cmd_lookup(Args("QUEEN-1", "Queen On Fire At The Bowl"), w)
ok("found: exit 0", rc, 0)
line = open(DB).read().strip().split("|")
ok("a line in scraped/<system>.txt's format: key, no crc, ok, the title",
   line[:4], ["QUEEN-1", "", "ok", "Queen on Fire - Live at the Bowl"])
ok("released, genre, director as developer, studio as publisher, artist as series",
   [line[4], line[7], line[8], line[9], line[10]],
   ["2004", "Rock", "Gavin Taylor", "EMI/Parlophone", "Queen"])
ok("as many fields as the importer writes", len(line), 12)
asked = len(w.asked)
rc = dvd.cmd_lookup(Args("QUEEN-1", "Queen On Fire At The Bowl"), w)
ok("known: not asked again", (rc, len(w.asked)), (0, asked))

import datetime  # noqa: E402
day = datetime.date(2026, 10, 3)
w = Wiki([], {})
rc = dvd.cmd_lookup(Args("NOBODY-1", "Nothing Like It"), w, today=day)
ok("not found: exit 3", rc, 3)
miss = [x for x in open(DB).read().split("\n") if x.startswith("NOBODY-1|")][0].split("|")
ok("recorded as a miss, with the day asked", (miss[2], miss[4]), ("miss", "2026-10-03"))
n = len(w.asked)
rc = dvd.cmd_lookup(Args("NOBODY-1", "Nothing Like It"), w, today=day + datetime.timedelta(days=29))
ok("not asked again within 30 days", (rc, len(w.asked)), (3, n))
rc = dvd.cmd_lookup(Args("NOBODY-1", "Nothing Like It"), w, today=day + datetime.timedelta(days=30))
ok("asked again after", len(w.asked), n + 1)

before = open(DB).read()
rc = dvd.cmd_lookup(Args("OFFLINE-1", "Some Film"), Wiki([], {}, fail=True))
ok("no answer at all: exit 1", rc, 1)
ok("and nothing recorded, so the next disc change asks", open(DB).read(), before)

# The daemon's own reader agrees with the file.
out = subprocess.run(["bash", "-c", '. "$1"; SCRAPE_DIR="$2"; lookup_scraped QUEEN-1 "" DVD; '
                      'printf "%s|%s|%s|%s|%s" "$SCR_TITLE" "$SCR_RELEASED" "$SCR_PUBLISHER" "$SCR_DEVELOPER" "$SCR_SERIES"',
                      "x", os.path.join(ROOT, "tty2oled-meta.sh"), os.path.dirname(DB)],
                     capture_output=True, text=True).stdout
ok("lookup_scraped reads the line back", out,
   "Queen on Fire - Live at the Bowl|2004|EMI/Parlophone|Gavin Taylor|Queen")

print("\n\033[1mResults:\033[0m %d passed, %d failed\n" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
