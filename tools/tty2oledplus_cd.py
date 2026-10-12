#!/usr/bin/env python3
"""
tty2oledplus_cd.py - which audio CD is in the drive, and what its tracks are
called, for the display. Runs ON THE MISTER, in the background, beside
MiSTer Hi-Fi playing the disc.

An audio CD says nothing about itself but where its tracks start. That table
of contents is enough to name it: MusicBrainz keys its discs on exactly that
(the "disc ID", a hash of the first and last track and every track's start),
and answers with the album, its artist and the tracks' titles. Wikipedia has
the rest - a genre, and the article's introduction as the description.

    tty2oledplus_cd.py disc --dev /dev/sr0 --cache DIR --db scraped/CD.txt
        One line: <disc id>|<tracks>|<track file>|<album>
        The table of contents is read with two ioctls, which the drive
        answers while the player is reading the disc. The track file is
        DIR/<disc id>.cd - a title a line, "<title>|<artist>", the artist
        given only where it is not the album's - written the first time
        MusicBrainz knows the disc and never fetched again. The album goes to
        the database as one line in the scraped/<system>.txt format, which
        the daemon's lookup_scraped already reads: title the album, series
        its artist, publisher its label. A line there marked "ok" - the
        user's correction included - is never overwritten; a disc MusicBrainz
        does not know is recorded as a "miss" and not asked about again for
        RETRY_DAYS. With --no-lookup nothing is asked: the disc's id and
        whatever was fetched before.
        Exit 0 named, 3 not known (or not asked), 1 no answer or no disc.

    tty2oledplus_cd.py fold
        Each line of standard input as the display can show it: printable
        ASCII, accents folded. For the titles a player reports of its files.

Standard library only: a MiSTer has Python 3.9 and nothing installed on top.
"""

import argparse
import base64
import datetime
import hashlib
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from tty2oledplus_scrape import db_load, db_write, fold  # noqa: E402
from tty2oledplus_dvd import (  # noqa: E402
    API, RETRY_DAYS, db_entry, describe, fetch_json, score)

NOT_FOUND = 3
CD_MAGIC = "tty2oledplus-cd 1"
MB_API = "https://musicbrainz.org/ws/2/discid/"

# linux/cdrom.h
CDROMREADTOCHDR = 0x5305
CDROMREADTOCENTRY = 0x5306
CDROM_LBA = 0x01
CDROM_LEADOUT = 0xAA
CDROM_DATA_TRACK = 0x04
PREGAP = 150              # frames before LBA 0: a disc ID counts from the lead-in
# A CD-Extra has its data in a second session, and a disc ID is the first
# session's alone: its lead-out is this far before the data track.
SESSION_GAP = 11400


# ---------------------------------------------------------------------------
# The table of contents
# ---------------------------------------------------------------------------

class Toc:
    """first and last audio track, the lead-out and each track's start - all
    in frames from the start of the lead-in, as a disc ID has them."""

    def __init__(self, first, last, leadout, offsets):
        self.first, self.last, self.leadout, self.offsets = first, last, leadout, list(offsets)

    @property
    def tracks(self):
        return self.last - self.first + 1

    def disc_id(self):
        """MusicBrainz's: SHA-1 over the numbers in upper-case hex, as its
        own base64 - "." "_" and "-" where "+", "/" and "=" would be."""
        offs = [self.leadout] + self.offsets + [0] * (99 - len(self.offsets))
        text = "%02X%02X" % (self.first, self.last) + "".join("%08X" % o for o in offs)
        b = base64.b64encode(hashlib.sha1(text.encode("ascii")).digest()).decode("ascii")
        return b.replace("+", ".").replace("/", "_").replace("=", "-")

    def query(self):
        """As MusicBrainz takes it for a fuzzy match: first+last+leadout+..."""
        return "+".join(str(n) for n in [self.first, self.last, self.leadout] + self.offsets)


def toc_from_entries(entries, leadout_lba):
    """entries: (track number, is data, start LBA), in order. The audio
    tracks of the first session, or None when there are none."""
    audio = [e for e in entries if not e[1]]
    if not audio:
        return None
    first, last = audio[0][0], audio[-1][0]
    leadout = leadout_lba
    after = [e for e in entries if e[1] and e[0] > last]
    if after:
        leadout = after[0][2] - SESSION_GAP
    return Toc(first, last, leadout + PREGAP, [e[2] + PREGAP for e in audio])


def read_toc(dev):
    """The disc's table of contents, off the drive. O_NONBLOCK: the drive is
    asked, not the disc read - and the player has it open."""
    import fcntl
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    try:
        hdr = bytearray(2)
        fcntl.ioctl(fd, CDROMREADTOCHDR, hdr)

        def entry(track):
            b = bytearray(struct.pack("BBBxii", track, 0, CDROM_LBA, 0, 0))
            fcntl.ioctl(fd, CDROMREADTOCENTRY, b)
            _, adr_ctrl, _, lba, _ = struct.unpack("BBBxii", b)
            return bool((adr_ctrl >> 4) & CDROM_DATA_TRACK), lba

        entries = []
        for t in range(hdr[0], hdr[1] + 1):
            data, lba = entry(t)
            entries.append((t, data, lba))
        return toc_from_entries(entries, entry(CDROM_LEADOUT)[1])
    finally:
        os.close(fd)


def parse_toc(text):
    """"1 9 187875 205 22395 ..." - a table given outright, for the tests."""
    n = [int(x) for x in text.replace("+", " ").split()]
    return Toc(n[0], n[1], n[2], n[3:])


# ---------------------------------------------------------------------------
# MusicBrainz
# ---------------------------------------------------------------------------

def _credit(credits):
    """An artist credit as it is written: names and what joins them."""
    return "".join((c.get("name") or c.get("artist", {}).get("name", "")) + c.get("joinphrase", "")
                   for c in credits or [])


def _medium(release, disc_id, tracks):
    """The disc of a release that is this one: by its ID, else - a fuzzy
    match has none - the first with as many tracks."""
    media = release.get("media") or []
    for m in media:
        if any(d.get("id") == disc_id for d in m.get("discs") or []):
            return m
    for m in media:
        if len(m.get("tracks") or []) == tracks:
            return m
    return None


def mb_album(answer, disc_id, tracks):
    """MusicBrainz's answer as what the display wants, or None: the album,
    its artist, year and label, and (title, artist) for each track."""
    for rel in answer.get("releases") or []:
        medium = _medium(rel, disc_id, tracks)
        if not medium:
            continue
        artist = fold(_credit(rel.get("artist-credit")))
        group = rel.get("release-group") or {}
        year = (group.get("first-release-date") or rel.get("date") or "")[:4]
        label = ""
        for info in rel.get("label-info") or []:
            label = fold((info.get("label") or {}).get("name", ""))
            if label:
                break
        titles = []
        for t in medium.get("tracks") or []:
            who = fold(_credit(t.get("artist-credit")))
            titles.append((fold(t.get("title", "")), "" if who == artist else who))
        return {"title": fold(rel.get("title", "")), "series": artist,
                "released": year if year.isdigit() else "", "publisher": label,
                "tracks": titles}
    return None


def mb_lookup(toc, opener=None):
    """The disc at MusicBrainz, or None when it knows none like it."""
    import urllib.error
    url = "%s%s?fmt=json&inc=artist-credits+recordings+labels+release-groups&toc=%s" % (
        MB_API, toc.disc_id(), toc.query())
    try:
        answer = fetch_json(url, opener)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return mb_album(answer, toc.disc_id(), toc.tracks)


# ---------------------------------------------------------------------------
# Wikipedia: the album's article. Searched with the artist, so that "Help!"
# is the Beatles' record; accepted when its title is the album's - bare, or
# marked as an album - and the article is about that artist.
# ---------------------------------------------------------------------------

def _plain(text):
    return re.sub(r"[^a-z0-9]+", " ", fold(text).lower()).strip()


def _same_title(album, title):
    # "(song)", "(film)", "(band)": the article of something else of the
    # name - an album's title track comes first in a search as often as not.
    m = re.search(r"\s*\((.*?)\)\s*$", title)
    if m:
        if not re.search(r"\b(album|ep|soundtrack|record)\b", m.group(1), re.IGNORECASE):
            return False
        title = title[:m.start()]
    return _plain(album) == _plain(title) or score(album, title) >= 0.6 and score(title, album) >= 0.6


def wiki_album(album, artist, opener=None):
    import urllib.parse
    q = urllib.parse.urlencode({"action": "query", "list": "search",
                                "srsearch": '"%s" %s album' % (album, artist),
                                "srlimit": 8, "format": "json"})
    hits = fetch_json(API + "?" + q, opener).get("query", {}).get("search", [])
    who = set(_plain(artist).split()) - {"the", "and", "a"}
    for hit in hits:
        title = hit.get("title", "")
        if not _same_title(album, title):
            continue
        q = urllib.parse.urlencode({
            "action": "query", "prop": "extracts|pageprops|revisions", "exintro": 1,
            "explaintext": 1, "rvprop": "content", "rvslots": "main", "rvsection": 0,
            "redirects": 1, "format": "json", "formatversion": 2, "titles": title})
        pages = fetch_json(API + "?" + q, opener).get("query", {}).get("pages", [])
        if not pages or "disambiguation" in (pages[0].get("pageprops") or {}):
            continue
        info = describe(pages[0])
        about = set(_plain(info.get("series", "") + " " + info.get("desc", "")[:400]).split())
        if who and not who & about:
            continue
        return info
    return None


# ---------------------------------------------------------------------------
# The track file, and the command
# ---------------------------------------------------------------------------

def track_file(cache, disc_id):
    return os.path.join(cache, disc_id + ".cd")


def tracks_ok(path, tracks):
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        return False
    return lines[0] == CD_MAGIC and len([x for x in lines[1:] if x]) >= tracks


def write_tracks(path, titles):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii", errors="replace") as f:
        f.write(CD_MAGIC + "\n")
        for title, artist in titles:
            f.write("%s|%s\n" % (title.replace("|", "/") or "-", artist.replace("|", "/")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _recent_miss(old, today):
    if len(old) > 4 and old[2] == "miss":
        try:
            return (today - datetime.date.fromisoformat(old[4])).days < RETRY_DAYS
        except ValueError:
            pass
    return False


def cmd_disc(args, opener=None, today=None, toc=None):
    today = today or datetime.date.today()
    try:
        toc = toc or (parse_toc(args.toc) if args.toc else read_toc(args.dev))
    except (OSError, ValueError, IndexError) as e:
        print("no disc: %s" % e)
        return 1
    if toc is None:
        print("no audio tracks")
        return 1
    disc_id = toc.disc_id()
    path = track_file(args.cache, disc_id)
    entries = db_load(args.db)
    old = entries.get(disc_id, "").split("|")
    named = len(old) > 4 and old[2] == "ok"
    have = tracks_ok(path, toc.tracks)

    def line(album):
        print("%s|%d|%s|%s" % (disc_id, toc.tracks, path if tracks_ok(path, toc.tracks) else "", album))

    if have and named:
        line(old[3])
        return 0
    if args.no_lookup or (not have and _recent_miss(old, today)):
        line(old[3] if named else "")
        return 0 if named else NOT_FOUND
    try:
        album = mb_lookup(toc, opener)
        info = None
        if album and album["title"] and not named:
            try:
                info = wiki_album(album["title"], album["series"], opener)
            except (OSError, ValueError):
                info = None             # the album is named all the same
    except (OSError, ValueError) as e:  # URLError is an OSError
        print("no answer: %s" % e)
        return 1
    if not album or not album["title"]:
        if not named:
            entries[disc_id] = db_entry(disc_id, "miss", {"released": today.isoformat()})
            os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
            db_write(args.db, entries)
        line(old[3] if named else "")
        return 0 if named else NOT_FOUND
    if len(album["tracks"]) >= toc.tracks:
        write_tracks(path, album["tracks"][:toc.tracks])
    if not named:
        row = {"title": album["title"], "released": album["released"],
               "publisher": album["publisher"], "series": album["series"],
               "genre": (info or {}).get("genre", ""), "desc": (info or {}).get("desc", "")}
        entries[disc_id] = db_entry(disc_id, "ok", row)
        os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
        db_write(args.db, entries)
    line(old[3] if named else album["title"])
    return 0


def cmd_fold():
    for raw in sys.stdin.buffer:
        print(fold(raw.decode("utf-8", "replace").rstrip("\r\n")))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("disc")
    s.add_argument("--dev", default="/dev/sr0")
    s.add_argument("--toc", default="")
    s.add_argument("--cache", required=True)
    s.add_argument("--db", required=True)
    s.add_argument("--no-lookup", action="store_true")
    sub.add_parser("fold")
    args = ap.parse_args(argv)
    if args.cmd == "disc":
        return cmd_disc(args)
    return cmd_fold()


if __name__ == "__main__":
    sys.exit(main())
