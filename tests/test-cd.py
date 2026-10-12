#!/usr/bin/env python3
"""
Tests for tools/tty2oledplus_cd.py: an audio CD named from its table of
contents, its tracks' titles, and what Wikipedia says of the album.

The disc is the one the MiSTer played - Jethro Tull's "Songs from the Wood",
nine tracks, its table as the drive gave it and its disc ID as MusicBrainz
has it. MusicBrainz and Wikipedia are stand-ins that answer from canned
replies, in the shapes the real ones returned for that disc.

    ./tests/test-cd.py
"""

import datetime
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "tty2oledplus_cd.py")
TMP = os.path.join(HERE, "fixtures", "tmp", "cd-py")

spec = importlib.util.spec_from_file_location("cd", TOOL)
cd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cd)

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


# The real disc: LBAs as CDROMREADTOCENTRY gave them, lead-out last.
LBAS = [55, 22245, 33595, 54162, 77662, 94647, 122005, 137885, 176682]
LEADOUT = 187725
DISC_ID = "XUf79bcXBBwGktQa0wYAxKvS2Qs-"
TOC_TEXT = "1 9 187875 205 22395 33745 54312 77812 94797 122155 138035 176832"
TITLES = ["Songs From the Wood", "Jack‐in‐the‐Green", "Cup of Wonder",
          "Hunting Girl", "Ring Out, Solstice Bells", "Velvet Green", "The Whistler",
          "Pibroch (Cap in Hand)", "Fire at Midnight"]
TULL = [{"name": "Jethro Tull", "joinphrase": "", "artist": {"name": "Jethro Tull"}}]


def mb_answer(disc_id=DISC_ID, titles=TITLES, guest=None):
    tracks = []
    for i, t in enumerate(titles):
        credit = TULL
        if guest and i == guest[0]:
            credit = [{"name": "Jethro Tull", "joinphrase": " feat. "}, {"name": guest[1], "joinphrase": ""}]
        tracks.append({"number": str(i + 1), "title": t, "length": 200000, "artist-credit": credit})
    return {"id": disc_id, "releases": [
        # A two-disc set first: its first disc is another, this one its second.
        {"title": "Songs From the Wood / Heavy Horses", "date": "1998", "artist-credit": TULL,
         "media": [{"discs": [{"id": "someOtherDisc-"}], "tracks": [{"title": "x"}] * 3}]},
        {"title": "Songs From the Wood", "date": "1985", "country": "US", "artist-credit": TULL,
         "release-group": {"first-release-date": "1977-02-11"},
         "label-info": [{"label": None}, {"label": {"name": "Chrysalis"}}],
         "media": [{"discs": [{"id": disc_id}] if disc_id else [], "tracks": tracks}]}]}


WIKI_SEARCH = {"query": {"search": [
    {"title": "Songs from the Wood (song)"}, {"title": "Heavy Horses"},
    {"title": "Songs from the Wood"}]}}
WIKI_SONG = {"query": {"pages": [{
    "title": "Songs from the Wood (song)",
    "extract": "\"Songs from the Wood\" is the title track off of English rock band Jethro Tull's "
               "album Songs from the Wood.",
    "revisions": [{"slots": {"main": {"content": "{{Infobox song|artist=[[Jethro Tull (band)|Jethro Tull]]}}"}}}]}]}}
WIKI_PAGE = {"query": {"pages": [{
    "title": "Songs from the Wood",
    "extract": "Songs from the Wood is the tenth studio album by British progressive rock band "
               "Jethro Tull, released on 11 February 1977 by Chrysalis Records.",
    "revisions": [{"slots": {"main": {"content":
        "{{Infobox album\n| name = Songs from the Wood\n| type = studio\n"
        "| artist = [[Jethro Tull (band)|Jethro Tull]]\n| released = {{Start date|1977|2|11}}\n"
        "| genre = {{hlist|[[Folk rock]]|[[progressive rock]]}}\n| label = [[Chrysalis Records|Chrysalis]]\n}}"}}}]}]}}


class Net:
    """The network: MusicBrainz by its host, Wikipedia's search and pages."""

    def __init__(self, mb=None, down=False, wiki_down=False):
        self.mb, self.down, self.wiki_down, self.asked = mb, down, wiki_down, []

    def __call__(self, url):
        self.asked.append(url)
        if self.down:
            raise OSError("network is unreachable")
        if "musicbrainz.org" in url:
            if self.mb is None:
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO(b""))
            return self.mb
        if self.wiki_down:
            raise OSError("timed out")
        if "list=search" in url:
            return WIKI_SEARCH
        return WIKI_SONG if "%28song%29" in url else WIKI_PAGE


def fresh():
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)


class Args:
    def __init__(self, **kw):
        self.dev, self.toc, self.no_lookup = "/dev/null", TOC_TEXT, False
        self.cache, self.db = os.path.join(TMP, "cache"), os.path.join(TMP, "scraped", "CD.txt")
        self.__dict__.update(kw)


def disc(net, today=datetime.date(2026, 10, 12), **kw):
    out, old = io.StringIO(), sys.stdout
    sys.stdout = out
    try:
        rc = cd.cmd_disc(Args(**kw), net, today)
    finally:
        sys.stdout = old
    return rc, out.getvalue().strip()


def db():
    try:
        with open(os.path.join(TMP, "scraped", "CD.txt")) as f:
            return f.read().strip()
    except OSError:
        return ""


TRACKS = os.path.join(TMP, "cache", DISC_ID + ".cd")

# ---------------------------------------------------------------------------
section("the table of contents, and the disc's ID")
# ---------------------------------------------------------------------------
toc = cd.toc_from_entries([(i + 1, False, lba) for i, lba in enumerate(LBAS)], LEADOUT)
ok("first and last track", (toc.first, toc.last, toc.tracks), (1, 9, 9))
ok("the lead-out, counted from the lead-in", toc.leadout, 187875)
ok("each track's start, likewise", toc.offsets[:3], [205, 22395, 33745])
ok("MusicBrainz's ID for the real disc", toc.disc_id(), DISC_ID)
ok("its own base64: 28 characters, the last a dash", (len(toc.disc_id()), toc.disc_id()[-1]), (28, "-"))
ok("the table as a fuzzy match takes it", toc.query(), TOC_TEXT.replace(" ", "+"))
ok("and read back from that", cd.parse_toc(toc.query()).disc_id(), DISC_ID)
other = cd.toc_from_entries([(i + 1, False, lba + (1 if i == 4 else 0)) for i, lba in enumerate(LBAS)], LEADOUT)
ok("one frame's difference is another disc", other.disc_id() != DISC_ID, True)
# A CD-Extra: the audio session, then a data track in a second one.
extra = cd.toc_from_entries([(1, False, 0), (2, False, 20000), (3, True, 51400)], 90000)
ok("a data track after the music is not counted", (extra.first, extra.last), (1, 2))
ok("and the lead-out is the first session's", extra.leadout, 51400 - 11400 + 150)
ok("a data disc has no ID", cd.toc_from_entries([(1, True, 0)], 300000), None)
mixed = cd.toc_from_entries([(1, True, 0), (2, False, 20000), (3, False, 40000)], 60000)
ok("a game disc's music: from its first audio track", (mixed.first, mixed.last, mixed.leadout), (2, 3, 60150))

# ---------------------------------------------------------------------------
section("MusicBrainz's answer")
# ---------------------------------------------------------------------------
album = cd.mb_album(mb_answer(), DISC_ID, 9)
ok("the release holding this disc, not the first listed", album["title"], "Songs From the Wood")
ok("its artist", album["series"], "Jethro Tull")
ok("the year the album came out, not this pressing's", album["released"], "1977")
ok("its label, past an entry with none", album["publisher"], "Chrysalis")
ok("nine titles", len(album["tracks"]), 9)
ok("typographic hyphens folded, not dropped", album["tracks"][1][0], "Jack-in-the-Green")
ok("a track by the album's artist names none", album["tracks"][0][1], "")
ok("one with a guest does", cd.mb_album(mb_answer(guest=(2, "Somebody")), DISC_ID, 9)["tracks"][2][1],
   "Jethro Tull feat. Somebody")
ok("a fuzzy match has no ID: the disc with as many tracks", cd.mb_album(mb_answer(disc_id=""), DISC_ID, 9)["title"],
   "Songs From the Wood")
ok("no disc like it", cd.mb_album(mb_answer(disc_id=""), DISC_ID, 12), None)
ok("nothing listed", cd.mb_album({"releases": []}, DISC_ID, 9), None)
net = Net(mb_answer())
cd.mb_lookup(toc, net)
ok("asked by the ID, with the table for a fuzzy match",
   net.asked[0].startswith("https://musicbrainz.org/ws/2/discid/" + DISC_ID + "?") and
   net.asked[0].endswith("&toc=" + toc.query()), True)
ok("a disc it has never heard of (404)", cd.mb_lookup(toc, Net(None)), None)

# ---------------------------------------------------------------------------
section("Wikipedia: the album's article")
# ---------------------------------------------------------------------------
net = Net()
info = cd.wiki_album("Songs From the Wood", "Jethro Tull", net)
ok("searched with the artist", "%22Songs+From+the+Wood%22+Jethro+Tull+album" in net.asked[0], True)
ok("the album's article, past its title track's - the real first hit on the MiSTer", info["title"], "Songs from the Wood")
ok("which was never fetched", [u for u in net.asked if "%28song%29" in u], [])
ok("an article marked as the album is one", cd._same_title("Help!", "Help! (album)"), True)
ok("and a band's album of a common name", cd._same_title("Rumours", "Rumours (Fleetwood Mac album)"), True)
ok("a film of the name is not", cd._same_title("Help!", "Help! (film)"), False)
ok("its genre", info["genre"], "Folk rock")
ok("the introduction as the description", info["desc"].startswith("Songs from the Wood is the tenth"), True)
ok("another artist's record of the name is not it", cd.wiki_album("Songs From the Wood", "Nobody Known", Net()), None)
ok("nor an article with another title", cd.wiki_album("Heavy Weather", "Jethro Tull", Net()), None)

# ---------------------------------------------------------------------------
section("a disc seen for the first time")
# ---------------------------------------------------------------------------
fresh()
net = Net(mb_answer())
rc, out = disc(net)
ok("named", (rc, out), (0, "%s|9|%s|Songs From the Wood" % (DISC_ID, TRACKS)))
with open(TRACKS) as f:
    lines = f.read().split("\n")
ok("the track file: its mark, then a title a line", lines[:3],
   [cd.CD_MAGIC, "Songs From the Wood|", "Jack-in-the-Green|"])
ok("nine of them", len([x for x in lines[1:] if x]), 9)
row = db().split("|")
ok("the album in the database, lookup_scraped's columns", row[:11],
   [DISC_ID, "", "ok", "Songs From the Wood", "1977", "", "", "Folk rock", "", "Chrysalis", "Jethro Tull"])
ok("and its description", row[11].startswith("Songs from the Wood is the tenth studio album"), True)
ok("printable ASCII, one line", all(32 <= ord(c) < 127 for c in db()), True)
net = Net(mb_answer())
rc, out = disc(net)
ok("the second time: the same answer", (rc, out), (0, "%s|9|%s|Songs From the Wood" % (DISC_ID, TRACKS)))
ok("and nobody asked", net.asked, [])

# ---------------------------------------------------------------------------
section("the user's correction is kept")
# ---------------------------------------------------------------------------
fresh()
os.makedirs(os.path.join(TMP, "scraped"))
MINE = DISC_ID + "||ok|My Own Title|1977|||Folk||Chrysalis|Tull|Mine."
with open(os.path.join(TMP, "scraped", "CD.txt"), "w") as f:
    f.write(MINE + "\n")
net = Net(mb_answer())
rc, out = disc(net)
ok("the titles are still fetched, the album is the user's", (rc, out),
   (0, "%s|9|%s|My Own Title" % (DISC_ID, TRACKS)))
ok("the line untouched", db(), MINE)
ok("Wikipedia not asked for what is already written", [u for u in net.asked if "wikipedia" in u], [])

# ---------------------------------------------------------------------------
section("a disc MusicBrainz does not know, and no answer at all")
# ---------------------------------------------------------------------------
fresh()
rc, out = disc(Net(None))
ok("not known: the ID, no titles, no album", (rc, out), (3, "%s|9||" % DISC_ID))
ok("recorded as a miss, with the day", db(), DISC_ID + "||miss||2026-10-12|||||||")
net = Net(mb_answer())
rc, out = disc(net, today=datetime.date(2026, 10, 30))
ok("not asked again within the month", (rc, net.asked), (3, []))
rc, out = disc(Net(mb_answer()), today=datetime.date(2026, 11, 20))
ok("asked again after it, and found", (rc, out.split("|")[3]), (0, "Songs From the Wood"))
fresh()
rc, out = disc(Net(mb_answer(), down=True))
ok("no network: nothing said of the disc", (rc, out.startswith("no answer")), (1, True))
ok("and nothing recorded, so the next start asks", (db(), os.path.exists(TRACKS)), ("", False))
rc, out = disc(Net(mb_answer(), wiki_down=True))
ok("MusicBrainz but no Wikipedia: named all the same", (rc, out.split("|")[3]), (0, "Songs From the Wood"))
ok("with no description", db().split("|")[11], "")
fresh()
net = Net(mb_answer())
rc, out = disc(net, no_lookup=True)
ok("lookups off: the ID alone, nobody asked", (rc, out, net.asked), (3, "%s|9||" % DISC_ID, []))
ok("nor a miss recorded", db(), "")
rc, out = disc(Net(), toc="")
ok("no disc in the drive", (rc, out.startswith("no disc")), (1, True))

# ---------------------------------------------------------------------------
section("the command line")
# ---------------------------------------------------------------------------
fresh()
p = subprocess.run([sys.executable, TOOL, "disc", "--toc", TOC_TEXT, "--no-lookup",
                    "--cache", os.path.join(TMP, "cache"), "--db", os.path.join(TMP, "scraped", "CD.txt")],
                   capture_output=True, text=True)
ok("disc --no-lookup", (p.returncode, p.stdout.strip()), (3, "%s|9||" % DISC_ID))
p = subprocess.run([sys.executable, TOOL, "fold"], capture_output=True,
                   input="Jack‐in‐the‐Green\nÉté — déjà vu\nA|B\n".encode("utf-8"))
ok("fold: a line in, a line out, ASCII", p.stdout.decode("ascii").split("\n")[:3],
   ["Jack-in-the-Green", "Ete - deja vu", "A/B"])

shutil.rmtree(TMP, ignore_errors=True)
print("\n\033[1mResults:\033[0m %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
