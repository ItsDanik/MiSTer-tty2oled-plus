#!/usr/bin/env python3
"""
tty2oledplus_scummvm.py - what ScummVM itself knows about its games, for the
display.

ScummVM's grid launcher ships its artwork and metadata as icon packs,
gui-icons-<date>.dat in its iconspath: zip files holding a 512x512 PNG per
game (icons/<engine>-<gameid>.png, and one per engine as icons/<engine>.png)
and the project's own game list - games.xml, companies.xml, engines.xml,
series.xml. Everything the display wants to say about a ScummVM game is in
there, on the MiSTer already.

    tty2oledplus_scummvm.py index --out games.idx DIR...
        One line a game, "|"-separated like the title index:
            engine|gameid|name|company|year|series|engine name
        The first line records which packs it was built from; run again with
        the same packs it exits at once without writing. Later packs win,
        which is the order ScummVM's own dated names sort in.

    tty2oledplus_scummvm.py icon --out <file.gsc> --engine E --game G DIR...
        The game's icon as an 86x64 .gsc, or the engine's when the packs have
        none for the game. Exit 3 when there is neither.

The daemon runs both in the background, niced: on the MiSTer's standard
library PNG reader a 512x512 icon takes seconds, so each is converted once and
kept.
"""

import argparse
import glob
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from tty2oledplus_scrape import fold  # noqa: E402  printable ASCII, no "|"
import png2gsc  # noqa: E402

NO_ICON = 3


def packs(dirs):
    """Every icon pack in the given folders, oldest first. ScummVM names them
    gui-icons-YYYYMMDD.dat, so the name is the order."""
    found = {}
    for d in dirs:
        for p in glob.glob(os.path.join(d, "gui-icons*.dat")):
            found.setdefault(os.path.basename(p), p)
    return [found[n] for n in sorted(found)]


def signature(paths):
    out = []
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        out.append("%s:%d:%d" % (os.path.basename(p), st.st_size, int(st.st_mtime)))
    return "# packs " + " ".join(out)


def read_xml(z, name, tag):
    """{id: attributes} for every <tag> in one of a pack's lists."""
    try:
        root = ET.fromstring(z.read(name))
    except (KeyError, ET.ParseError):
        return {}
    return {e.get("id", ""): e.attrib for e in root.iter(tag) if e.get("id")}


def build_index(paths):
    games, companies, engines, series = {}, {}, {}, {}
    for p in paths:
        try:
            z = zipfile.ZipFile(p)
        except (OSError, zipfile.BadZipFile):
            continue
        with z:
            # A game id is unique only within its engine: "ft" is SCUMM's.
            for gid, a in read_xml(z, "games.xml", "game").items():
                games[(a.get("engine_id", "").lower(), gid.lower())] = a
            companies.update(read_xml(z, "companies.xml", "company"))
            engines.update(read_xml(z, "engines.xml", "engine"))
            series.update(read_xml(z, "series.xml", "serie"))

    def name_of(table, key):
        return fold(table.get(key, {}).get("name", "")) if key else ""

    lines = []
    for (engine, gid) in sorted(games):
        a = games[(engine, gid)]
        year = a.get("year", "")
        year = year if re.fullmatch(r"\d{4}", year or "") else ""
        lines.append("|".join([
            engine, gid, fold(a.get("name", "")),
            name_of(companies, a.get("company_id", "")), year,
            name_of(series, a.get("series_id", "")),
            name_of(engines, a.get("engine_id", "")),
        ]))
    return lines


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_index(args):
    paths = packs(args.dirs)
    sig = signature(paths)
    try:
        with open(args.out) as fh:
            if fh.readline().rstrip("\n") == sig:
                print("up to date")
                return 0
    except OSError:
        pass
    lines = build_index(paths)
    write_atomic(args.out, sig + "\n" + "".join(l + "\n" for l in lines))
    print("%d games from %d packs" % (len(lines), len(paths)))
    return 0


def find_icon(paths, engine, game):
    """(pack, member) of the newest pack's icon for the game, else for its
    engine."""
    for member in ("icons/%s-%s.png" % (engine, game), "icons/%s.png" % engine):
        for p in reversed(paths):
            try:
                with zipfile.ZipFile(p) as z:
                    z.getinfo(member)
                    return p, member
            except (OSError, KeyError, zipfile.BadZipFile):
                continue
    return None, None


def cmd_icon(args):
    engine, game = args.engine.lower(), args.game.lower()
    pack, member = find_icon(packs(args.dirs), engine, game)
    if not pack:
        print("no icon for %s-%s" % (engine, game))
        return NO_ICON
    fd, png = tempfile.mkstemp(suffix=".png")
    try:
        with os.fdopen(fd, "wb") as fh, zipfile.ZipFile(pack) as z:
            fh.write(z.read(member))
        pixels = png2gsc.load_grey(png, png2gsc.ICON_W, png2gsc.ICON_H,
                                   backend=args.backend)
    finally:
        os.unlink(png)
    write_atomic(args.out, png2gsc.to_gsc(pixels, png2gsc.ICON_W, png2gsc.ICON_H))
    print("%s from %s" % (member, os.path.basename(pack)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ix = sub.add_parser("index", help="the games index from the icon packs")
    ix.add_argument("--out", required=True)
    ix.add_argument("dirs", nargs="+")
    ic = sub.add_parser("icon", help="one game's icon as an 86x64 .gsc")
    ic.add_argument("--out", required=True)
    ic.add_argument("--engine", required=True)
    ic.add_argument("--game", required=True)
    ic.add_argument("--backend", default="auto",
                    choices=("auto", "pillow", "magick", "pure"))
    ic.add_argument("dirs", nargs="+")
    args = ap.parse_args(argv)
    return cmd_index(args) if args.cmd == "index" else cmd_icon(args)


if __name__ == "__main__":
    sys.exit(main())
