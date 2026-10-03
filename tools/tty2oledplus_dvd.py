#!/usr/bin/env python3
"""
tty2oledplus_dvd.py - what a DVD-Video disc says about itself, and what
Wikipedia says about it, for the display. Runs ON THE MISTER, in the
background, beside the DVD core.

The DVD core decodes and navigates in the FPGA, so the ARM side never learns
which title, chapter or time is playing. What it can see is where the core's
Main is reading: its descriptor on the disc (/dev/sr0, or the ISO) moves as
it reads, and the read-ahead is small - a pause stops it dead. The disc's own
navigation tables, the IFO files, map every sector of the movie to a title,
a chapter and a time. This turns them into one table the daemon searches.

    tty2oledplus_dvd.py scan --dev /dev/sr0 --cache DIR
        One line: <key>|<label>|<nav file>|<title>
        The title is what to show until Wikipedia says better, and what to ask
        it for: an ISO's file name, else the label made readable.
        The key is the volume's label, creation date and size - enough to
        tell two discs apart without reading more than one sector, so a disc
        seen before costs that sector and nothing else. The nav file is
        written into DIR the first time (a few dozen sectors: the ISO9660
        directory and the IFOs). Exit 3, nav file empty, when the volume is
        not DVD-Video.

    tty2oledplus_dvd.py lookup --key K --query Q --db scraped/DVD.txt
        Wikipedia, once per disc: title, year, studio, director, artist,
        genre and the article's introduction as the description, into the
        database as one line - the scraped/<system>.txt format, which the
        daemon's lookup_scraped already reads. Exit 0 found, 3 not found
        (recorded, and not asked again for RETRY_DAYS), 1 no answer
        (nothing recorded, so the next disc change asks again).

Standard library only: a MiSTer has Python 3.9 and nothing installed on top.
"""

import argparse
import bisect
import datetime
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from tty2oledplus_scrape import FIELDS, clip_desc, db_load, db_write, fold  # noqa: E402

SECTOR = 2048
NOT_DVD = 3
NOT_FOUND = 3
NAV_MAGIC = "tty2oledplus-dvd-nav 1"
# A time map point is kept only this far after the last one: every second of
# a two-hour film is 7200 rows for the daemon to load, and the firmware counts
# the seconds between them itself. A cell's start is always kept - it is where
# a chapter can begin.
POINT_SECS = 4


# ---------------------------------------------------------------------------
# The volume: ISO9660, which every DVD-Video disc carries beside its UDF (the
# "UDF bridge" the format requires). The primary volume descriptor at sector
# 16 holds the label; its root directory leads to VIDEO_TS.
# ---------------------------------------------------------------------------
class Volume:
    def __init__(self, f):
        self.f = f

    def read(self, lba, count=1):
        self.f.seek(lba * SECTOR)
        return self.f.read(count * SECTOR)

    def pvd(self):
        d = self.read(16)
        if len(d) < SECTOR or d[1:6] != b"CD001" or d[0] != 1:
            return None
        label = d[40:72].decode("ascii", "replace").strip()
        blocks = struct.unpack("<I", d[80:84])[0]
        created = d[813:829].decode("ascii", "replace")
        if not created.isdigit():
            created = ""
        root = d[156:190]
        return {
            "label": label,
            "blocks": blocks,
            "created": created,
            "root": (struct.unpack("<I", root[2:6])[0], struct.unpack("<I", root[10:14])[0]),
        }

    def listdir(self, lba, size):
        d = self.read(lba, max(1, (size + SECTOR - 1) // SECTOR))
        out, i = {}, 0
        while i + 33 < len(d):
            n = d[i]
            if n == 0:                       # records never span a sector
                i = (i // SECTOR + 1) * SECTOR
                continue
            ext = struct.unpack("<I", d[i + 2:i + 6])[0]
            length = struct.unpack("<I", d[i + 10:i + 14])[0]
            nl = d[i + 32]
            name = d[i + 33:i + 33 + nl].decode("ascii", "replace").split(";")[0]
            if name not in ("\x00", "\x01"):
                out.setdefault(name.upper(), (ext, length))
            i += n
        return out


def disc_key(pv):
    """The volume, as the daemon and the database know it: the label, and
    the creation date and size that tell two "DVD_VIDEO" discs apart."""
    key = pv["label"] or "DVD"
    if pv["created"] and pv["created"].strip("0"):
        key += "-" + pv["created"][:14]
    return "%s-%d" % (key, pv["blocks"])


# ---------------------------------------------------------------------------
# The IFOs. Offsets as libdvdread names them (ifo_types.h).
# ---------------------------------------------------------------------------
def u8(b, o):
    return b[o] if o < len(b) else 0


def u16(b, o):
    return struct.unpack(">H", b[o:o + 2])[0] if o + 2 <= len(b) else 0


def u32(b, o):
    return struct.unpack(">I", b[o:o + 4])[0] if o + 4 <= len(b) else 0


def _bcd(b):
    return (b >> 4) * 10 + (b & 0x0F)


def bcd_time(b):
    """dvd_time_t in seconds: hours, minutes, seconds, then frames with the
    frame rate in the top two bits (01 = 25, 11 = 29.97)."""
    if len(b) < 4:
        return 0.0
    rate = 25.0 if (b[3] >> 6) == 1 else 29.97
    return _bcd(b[0]) * 3600 + _bcd(b[1]) * 60 + _bcd(b[2]) + _bcd(b[3] & 0x3F) / rate


class Pgc:
    def __init__(self, b):
        self.programs = u8(b, 2)
        n = u8(b, 3)
        self.total = bcd_time(b[4:8])
        pm = u16(b, 0xE6)
        self.pmap = list(b[pm:pm + self.programs]) if pm else []
        cp = u16(b, 0xE8)
        self.cells = []                      # (first, last, t0, duration, angle_alt)
        t = 0.0
        block_t0 = 0.0
        for c in range(n if cp else 0):
            e = b[cp + 24 * c:cp + 24 * c + 24]
            if len(e) < 24:
                break
            mode, kind = e[0] >> 6, (e[0] >> 4) & 3
            dur = bcd_time(e[4:8])
            # The cells of an angle block are the same moments, filmed
            # differently: the block takes the time of one of them.
            alt = kind == 1 and mode in (2, 3)
            if alt:
                t0 = block_t0
            else:
                t0 = t
                block_t0 = t
                t += dur
            self.cells.append((u32(e, 8), u32(e, 20), t0, dur, alt))
        if not self.total:
            self.total = t

    def cell_at(self, t):
        """The cell (0-based) playing at t seconds into the PGC."""
        idx = 0
        for i, (_, _, t0, _, alt) in enumerate(self.cells):
            if not alt and t0 <= t:
                idx = i
        return idx


class Vts:
    def __init__(self, vol, lba, size):
        self.lba = lba
        ifo = vol.read(lba, max(1, (size + SECTOR - 1) // SECTOR))
        if ifo[:12] != b"DVDVIDEO-VTS":
            raise ValueError("not a VTS IFO")
        self.menu_vobs = u32(ifo, 0xC0)
        self.title_vobs = u32(ifo, 0xC4)
        self.last = u32(ifo, 0x0C)

        # The PGCs, numbered from 1 as the PTTs name them.
        self.pgcs = {}
        base = u32(ifo, 0xCC) * SECTOR
        for i in range(u16(ifo, base)):
            off = u32(ifo, base + 8 + 8 * i + 4)
            self.pgcs[i + 1] = Pgc(ifo[base + off:])

        # Each title's chapters: (pgcn, pgn) in order.
        self.ptts = {}
        base = u32(ifo, 0xC8) * SECTOR
        if base:
            n = u16(ifo, base)
            end = base + u32(ifo, base + 4) + 1
            offs = [base + u32(ifo, base + 8 + 4 * i) for i in range(n)] + [end]
            for t in range(n):
                lst = []
                for o in range(offs[t], offs[t + 1] - 3, 4):
                    lst.append((u16(ifo, o), u16(ifo, o + 2)))
                self.ptts[t + 1] = lst

        # The time maps, one per PGC: (seconds per entry, [sector, ...]).
        self.tmaps = {}
        base = u32(ifo, 0xD4) * SECTOR
        if base:
            for i in range(u16(ifo, base)):
                o = base + u32(ifo, base + 8 + 4 * i)
                unit, n = u8(ifo, o), u16(ifo, o + 2)
                if unit:
                    self.tmaps[i + 1] = (unit, [u32(ifo, o + 4 + 4 * k) & 0x7FFFFFFF
                                                for k in range(n)])

    def abs(self, sector):
        return self.lba + self.title_vobs + sector


def title_points(vts, ptts):
    """A title's timeline as runs of (sector, seconds, chapter) points, one
    run per PGC: sectors climb within a run, and a chapter is the PTT whose
    entry cell is the last one at or before the point's. Also the title's
    length, and the second each of its chapters starts at."""
    order = []
    for pgcn, _ in ptts:
        if pgcn in vts.pgcs and pgcn not in order:
            order.append(pgcn)
    rank = {p: i for i, p in enumerate(order)}

    def chapter(pgcn, cell):          # cell 1-based
        ch = 1
        for k, (pn, pgn) in enumerate(ptts):
            if pn not in rank:
                continue
            pgc = vts.pgcs[pn]
            entry = pgc.pmap[pgn - 1] if 0 < pgn <= len(pgc.pmap) else 1
            if rank[pn] < rank[pgcn] or (pn == pgcn and entry <= cell):
                ch = k + 1
        return ch

    runs, base, bases = [], 0.0, {}
    for pgcn in order:
        pgc = vts.pgcs[pgcn]
        bases[pgcn] = base
        pts = []
        for i, (first, _, t0, _, alt) in enumerate(pgc.cells):
            if not alt:
                pts.append((vts.abs(first), base + t0, chapter(pgcn, i + 1), True))
        unit, entries = vts.tmaps.get(pgcn, (0, []))
        for k, sec in enumerate(entries):
            t = (k + 1) * unit
            if t >= pgc.total:
                break
            pts.append((vts.abs(sec), base + t, chapter(pgcn, pgc.cell_at(t) + 1), False))
        if pgc.cells:
            last = max(c[1] for c in pgc.cells)
            pts.append((vts.abs(last) + 1, base + pgc.total, None, True))
        pts.sort(key=lambda p: (p[1], not p[3]))

        kept = []
        for p in pts:
            if kept and not p[3] and p[1] - kept[-1][1] < POINT_SECS:
                continue
            if kept and p[0] <= kept[-1][0]:
                continue                       # an angle's sectors, or a jump back
            kept.append(p)
        runs.append(kept)
        base += pgc.total

    starts = []
    for pn, pgn in ptts:
        pgc = vts.pgcs.get(pn)
        if pn not in bases or not pgc or not pgc.cells:
            continue
        entry = pgc.pmap[pgn - 1] if 0 < pgn <= len(pgc.pmap) else 1
        entry = min(max(entry, 1), len(pgc.cells))
        starts.append(bases[pn] + pgc.cells[entry - 1][2])
    return runs, base, starts


class Coverage:
    """Sectors already given to a title, as sorted disjoint [start, end]."""
    def __init__(self):
        self.starts, self.ends = [], []

    def free(self, a, b):
        """The parts of [a, b] not covered yet."""
        out, i = [], bisect.bisect_right(self.ends, a - 1)
        cur = a
        while cur <= b and i < len(self.starts):
            s, e = self.starts[i], self.ends[i]
            if s > b:
                break
            if s > cur:
                out.append((cur, s - 1))
            cur = max(cur, e + 1)
            i += 1
        if cur <= b:
            out.append((cur, b))
        return out

    def add(self, a, b):
        i = bisect.bisect_left(self.starts, a)
        self.starts.insert(i, a)
        self.ends.insert(i, b)


def build_nav(vol, pv):
    """The table the daemon searches, or None when this is no DVD-Video."""
    top = vol.listdir(*pv["root"])
    if "VIDEO_TS" not in top:
        return None
    vt = vol.listdir(*top["VIDEO_TS"])
    if "VIDEO_TS.IFO" not in vt:
        return None
    vmg = vol.read(vt["VIDEO_TS.IFO"][0], max(1, (vt["VIDEO_TS.IFO"][1] + SECTOR - 1) // SECTOR))
    if vmg[:12] != b"DVDVIDEO-VMG":
        return None

    menus = []
    if "VIDEO_TS.VOB" in vt and vt["VIDEO_TS.VOB"][1]:
        lba, size = vt["VIDEO_TS.VOB"]
        menus.append((lba, lba + (size + SECTOR - 1) // SECTOR - 1))

    # The titles as the disc numbers them, and where each lives. The title
    # set's sector in this table is not always right (seen 287 sectors out);
    # the IFO's own place in the directory is.
    tt = u32(vmg, 0xC4) * SECTOR
    titles = []
    for t in range(u16(vmg, tt)):
        e = vmg[tt + 8 + 12 * t:tt + 20 + 12 * t]
        titles.append((t + 1, u8(e, 6), u8(e, 7)))

    sets = {}
    for _, vtsn, _ in titles:
        if vtsn in sets:
            continue
        name = "VTS_%02d_0.IFO" % vtsn
        if name not in vt:
            continue
        try:
            sets[vtsn] = Vts(vol, *vt[name])
        except (ValueError, struct.error, IndexError):
            continue
        v = sets[vtsn]
        if v.menu_vobs and v.title_vobs > v.menu_vobs:
            menus.append((v.lba + v.menu_vobs, v.lba + v.title_vobs - 1))

    # Each title's timeline, then the sectors shared between titles given to
    # one of them: a concert disc plays the same songs as one long title and
    # as a title a song. The one with the most chapters, then the longest,
    # then the first - the main feature, as a player's display would number it.
    built = []
    for num, vtsn, ttn in titles:
        v = sets.get(vtsn)
        if not v or ttn not in v.ptts:
            continue
        runs, total, starts = title_points(v, v.ptts[ttn])
        built.append((num, len(v.ptts[ttn]), total, runs, starts))
    built.sort(key=lambda x: (-x[1], -x[2], x[0]))

    cover, segs = Coverage(), []
    for num, chapters, total, runs, _ in built:
        for run in runs:
            for p, q in zip(run, run[1:]):
                a, b = p[0], q[0] - 1
                if b < a:
                    continue
                for fa, fb in cover.free(a, b):
                    span = b - a + 1
                    t0 = p[1] + (q[1] - p[1]) * (fa - a) / span
                    t1 = p[1] + (q[1] - p[1]) * (fb + 1 - a) / span
                    segs.append((fa, fb, num, p[2] or 1, chapters, t0, t1, total))
                    cover.add(fa, fb)
    segs.sort()
    main = max(built, key=lambda x: x[2]) if built else None
    return {
        "titles": len(titles),
        "main": (main[0], main[2], main[1]) if main else (0, 0, 0),
        "segs": segs,
        "menus": menus,
        "chapters": {b[0]: (b[2], b[4]) for b in built},
    }


def write_nav(path, key, pv, nav):
    """Column a line, so the daemon loads each with one read -a."""
    cols = list(zip(*nav["segs"])) if nav["segs"] else [()] * 8
    names = ["start", "end", "title", "chapter", "chapters", "t0", "t1", "total"]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii", errors="replace") as f:
        f.write(NAV_MAGIC + "\n")
        f.write("key %s\n" % key)
        f.write("label %s\n" % pv["label"])
        f.write("titles %d\n" % nav["titles"])
        f.write("main %d %d %d\n" % (nav["main"][0], int(nav["main"][1] + 0.5), nav["main"][2]))
        for i, name in enumerate(names):
            vals = cols[i] if i < len(cols) else ()
            if name in ("t0", "t1", "total"):
                vals = [int(v + 0.5) for v in vals]
            f.write("%s %s\n" % (name, " ".join(str(v) for v in vals)))
        f.write("menu %s\n" % " ".join("%d %d" % m for m in nav["menus"]))
        # A title's length and its chapters' starts, for the daemon's clock:
        # it counts the seconds itself and needs the chapter they fall in.
        for num in sorted(nav["chapters"]):
            total, starts = nav["chapters"][num]
            f.write("starts%d %d %s\n" % (num, int(total + 0.5),
                                             " ".join(str(int(t + 0.5)) for t in starts)))
    os.replace(tmp, path)


def nav_ok(path):
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            return f.readline().rstrip("\n") == NAV_MAGIC
    except OSError:
        return False


def fallback_title(dev, label):
    """An image's name says more than its label ("DVD_VIDEO"); a disc has
    only its label."""
    if os.path.isfile(dev):
        return file_title(dev)
    return label_title(label) if label else ""


def cmd_scan(args):
    try:
        f = open(args.dev, "rb")
    except OSError as e:
        print("cannot open %s: %s" % (args.dev, e), file=sys.stderr)
        return 1
    with f:
        vol = Volume(f)
        pv = vol.pvd()
        if not pv:
            print("|||")
            return NOT_DVD
        key = disc_key(pv)
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", key)
        path = os.path.join(args.cache, safe + ".nav")
        if not nav_ok(path):
            try:
                nav = build_nav(vol, pv)
            except (struct.error, IndexError, ValueError, OSError):
                nav = None
            if not nav:
                print("%s|%s||%s" % (key, pv["label"], fallback_title(args.dev, pv["label"])))
                return NOT_DVD
            os.makedirs(args.cache, exist_ok=True)
            write_nav(path, key, pv, nav)
    print("%s|%s|%s|%s" % (key, pv["label"], path, fallback_title(args.dev, pv["label"])))
    return 0


# ---------------------------------------------------------------------------
# Wikipedia. The search finds the article; its introduction is the
# description, and its infobox - Infobox film, Infobox album, often both on a
# concert's page - has the rest.
# ---------------------------------------------------------------------------
API = "https://en.wikipedia.org/w/api.php"
CAFILE = "/etc/ssl/certs/cacert.pem"     # MiSTer's Python finds none by itself
TIMEOUT = 15
USER_AGENT = "tty2oledplus (https://github.com/ItsDanik/MiSTer-tty2oled-plus)"
RETRY_DAYS = 30

# A label is upper case with underscores, and often ends in what is not the
# film: the disc of a set, the screen shape, the region.
_LABEL_TAIL = re.compile(
    r"(?:[ _](?:DISC|DISK|D|CD|DVD|SIDE)[ _]?[0-9AB]{1,2}|[ _](?:WS|FS|WIDESCREEN|FULLSCREEN|"
    r"FULL_SCREEN|16X9|4X3|NTSC|PAL|R[0-9]|DVD|SE|CE|UK|US|EU|DE|FR|IT|ES|NL|JP))+$",
    re.IGNORECASE)
_STOP = {"the", "a", "an", "of", "and", "at", "in", "on", "to", "live", "dvd", "video",
         "disc", "edition", "special", "collectors", "s"}


def label_title(label):
    """QUEEN_ON_FIRE_AT_THE_BOWL -> Queen On Fire At The Bowl."""
    s = _LABEL_TAIL.sub("", label.strip()) or label.strip()
    s = re.sub(r"[_\s]+", " ", s).strip()
    if s.isupper() or s.islower():
        s = " ".join(w.capitalize() if w.isalpha() else w for w in s.split(" "))
    return s


def file_title(name):
    """A file's name, less its extension and the dots and underscores some
    rips use for spaces."""
    base = os.path.basename(name)
    base = re.sub(r"\.(iso|img|bin)$", "", base, flags=re.IGNORECASE)
    if " " not in base:
        base = re.sub(r"[._]+", " ", base)
    return re.sub(r"\s+", " ", base).strip()


def _words(text):
    return [w for w in re.findall(r"[a-z0-9]+", fold(text).lower()) if w not in _STOP]


def score(query, title):
    """How much of the query the article's title says: a search ranks by the
    whole article, and the first hit for a cryptic label can be anything."""
    q, t = set(_words(query)), set(_words(re.sub(r"\(.*?\)", "", title)))
    if not q:
        return 0.0
    return len(q & t) / len(q)


def fetch_json(url, opener=None):
    if opener:
        return opener(url)
    import json            # here, not above: a scan, the common case, needs none
    import ssl             # of the network, and its imports cost a second on
    import urllib.request  # the DE10
    ctx = ssl.create_default_context(cafile=CAFILE) if os.path.exists(CAFILE) else None
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
        return json.load(r)


def _strip_templates(s):
    """Templates out, innermost first; the list ones and the wrappers leave
    their first item, which is all a row on the panel has room for."""
    for _ in range(10):
        m = re.search(r"\{\{([^{}]*)\}\}", s)
        if not m:
            break
        parts = [p.strip() for p in m.group(1).split("|")]
        name = parts[0].lower().strip()
        keep = ""
        if name in ("plainlist", "plain list", "flatlist", "flat list"):
            items = [x.strip(" *") for x in "|".join(parts[1:]).split("\n") if x.strip(" *")]
            keep = items[0] if items else ""
        elif name in ("ubl", "unbulleted list", "hlist", "nowrap", "small", "plain list"):
            vals = [p for p in parts[1:] if "=" not in p]
            keep = vals[0] if vals else ""
        elif name in ("lang", "langx"):
            keep = parts[2] if len(parts) > 2 else ""
        elif name.startswith(("film date", "start date", "release date", "dts")):
            nums = [p for p in parts[1:] if p.isdigit()]
            keep = nums[0] if nums else ""
        s = s[:m.start()] + keep + s[m.end():]
    return s


def wiki_plain(value):
    """An infobox value as a row: links as their text, the first of a list,
    no markup, no notes in brackets."""
    s = re.sub(r"<!--.*?-->", "", value, flags=re.S)
    s = re.sub(r"<ref[^>]*/>", "", s)
    s = re.sub(r"<ref.*?</ref>", "", s, flags=re.S)
    # Links first: a link's own pipe would split a template's items.
    s = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", s)
    s = _strip_templates(s)
    s = re.split(r"<br\s*/?>|\n\s*\*", s.strip(" *\n"))[0]
    s = re.sub(r"\[https?://\S+ ([^\]]*)\]", r"\1", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"\s*\([^)]*\)", "", s)
    s = fold(s).strip(" ,;:*")
    return s


def infoboxes(wikitext):
    """Every {{Infobox ...}} at the top of an article as {key: raw value},
    first box first. Parsed by brace depth: values hold templates and links,
    and their own pipes."""
    out, i = [], 0
    while True:
        i = wikitext.find("{{Infobox", i)
        if i < 0:
            return out
        depth, j, start = 0, i, i
        fields, cur = {}, None
        while j < len(wikitext):
            two = wikitext[j:j + 2]
            if two in ("{{", "[["):
                depth += 1
                j += 2
                continue
            if two in ("}}", "]]"):
                depth -= 1
                j += 2
                if depth == 0:
                    break
                continue
            if wikitext[j] == "|" and depth == 1:
                if cur is not None:
                    k, _, v = wikitext[start:j].partition("=")
                    fields[k.strip().lower()] = v.strip()
                cur, start = True, j + 1
            j += 1
        if cur is not None:
            k, _, v = wikitext[start:j - 2].partition("=")
            fields.setdefault(k.strip().lower(), v.strip())
        out.append(fields)
        i = j


def _first(boxes, *keys):
    for box in boxes:
        for k in keys:
            v = wiki_plain(box.get(k, ""))
            if v:
                return v
    return ""


def _year(boxes):
    for box in boxes:
        for k in ("released", "release_date", "release date", "released date", "date"):
            m = re.search(r"\b(1[89]\d\d|20\d\d)\b", box.get(k, ""))
            if m:
                return m.group(1)
    return ""


def describe(page):
    """The database's fields out of one article."""
    text = ""
    revs = page.get("revisions") or []
    if revs:
        text = revs[0].get("slots", {}).get("main", {}).get("content", "")
    boxes = infoboxes(text)
    intro = page.get("extract", "") or ""
    # Pronunciations and other bracketed asides in the first sentence.
    intro = re.sub(r"\s*\((?:[^()]*?;|/)[^()]*\)", "", intro)
    return {
        "title": fold(page.get("title", "")),
        "released": _year(boxes),
        "genre": _first(boxes, "genre"),
        "developer": _first(boxes, "director", "directed_by"),
        "publisher": _first(boxes, "studio", "production_companies", "production_company",
                            "label", "distributor", "publisher"),
        "series": _first(boxes, "artist"),
        "desc": clip_desc(fold(intro.replace("\n", " "))),
    }


def wiki_lookup(query, opener=None):
    """The article for a disc, as database fields, or None."""
    import urllib.parse
    q = urllib.parse.urlencode({"action": "query", "list": "search", "srsearch": query,
                                "srlimit": 8, "format": "json"})
    hits = fetch_json(API + "?" + q, opener).get("query", {}).get("search", [])
    for hit in hits:
        title = hit.get("title", "")
        if score(query, title) < 0.6:
            continue
        q = urllib.parse.urlencode({
            "action": "query", "prop": "extracts|pageprops|revisions", "exintro": 1,
            "explaintext": 1, "rvprop": "content", "rvslots": "main", "rvsection": 0,
            "redirects": 1, "format": "json", "formatversion": 2, "titles": title})
        pages = fetch_json(API + "?" + q, opener).get("query", {}).get("pages", [])
        if not pages or "disambiguation" in (pages[0].get("pageprops") or {}):
            continue
        return describe(pages[0])
    return None


def db_entry(key, status, info):
    vals = [key, "", status] + [info.get(f, "") for f in FIELDS[3:]]
    return "|".join(v.replace("|", "/").replace("\n", " ") for v in vals)


def cmd_lookup(args, opener=None, today=None):
    today = today or datetime.date.today()
    entries = db_load(args.db)
    old = entries.get(args.key, "").split("|")
    if len(old) > 4 and old[2] == "ok":
        print("ok %s" % old[3])
        return 0
    if len(old) > 4 and old[2] == "miss":
        try:
            tried = datetime.date.fromisoformat(old[4])
            if (today - tried).days < RETRY_DAYS:
                print("miss (asked %s)" % old[4])
                return NOT_FOUND
        except ValueError:
            pass
    try:
        info = wiki_lookup(args.query, opener)
    except (OSError, ValueError) as e:      # URLError is an OSError
        print("no answer: %s" % e)
        return 1
    if info and info.get("title"):
        entries[args.key] = db_entry(args.key, "ok", info)
        rc = 0
        print("ok %s" % info["title"])
    else:
        entries[args.key] = db_entry(args.key, "miss", {"released": today.isoformat()})
        rc = NOT_FOUND
        print("miss")
    os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
    db_write(args.db, entries)
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("--dev", required=True)
    s.add_argument("--cache", required=True)
    s = sub.add_parser("lookup")
    s.add_argument("--key", required=True)
    s.add_argument("--query", required=True)
    s.add_argument("--db", required=True)
    s = sub.add_parser("title")
    s.add_argument("--label", default="")
    s.add_argument("--file", default="")
    args = ap.parse_args(argv)
    if args.cmd == "scan":
        return cmd_scan(args)
    if args.cmd == "lookup":
        return cmd_lookup(args)
    print(file_title(args.file) if args.file else label_title(args.label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
