#!/usr/bin/env python3
"""tty2oled+ metadata import. Runs ON THE MISTER, from the install folder.

Reads the gamelist.xml that a scraper - Skraper, ES-DE, Batocera, Skyscraper -
left in a system's own games folder, games/NES/gamelist.xml, and keeps what it
says about each game in scraped/<system>.txt for the daemon: the title,
release date, players, rating, genre, developer, publisher, series and a
description. No account and no network: the scraping was done elsewhere.
Arcade games are one more system, whose gamelist sits in games/mame beside
the zips, and ScummVM's another, in games/ScummVM beside its games' folders.

    tty2oledplus_scrape.py --list-systems
    tty2oledplus_scrape.py --systems NES,SNES,Arcade
    tty2oledplus_scrape.py --systems all

The Scripts menu reaches it through tty2oledplus_scrape.sh, which asks which
systems; over SSH it can be run as it is.

Standard library only: a MiSTer has Python 3.9 and nothing installed on top.

Exit codes: 0 done, 2 nothing asked for.
"""

import argparse
import html
import os
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET

DESC_MAX = 2048   # the firmware keeps this much (DESC_MAX in metadisplay.h)

# ---------------------------------------------------------------------------
# The systems: one per console icon in pics/icon, since a console's
# description page is part of the split layout the icons are for. Keyed by the
# icon's name, which is the core name the daemon looks the file up by.
#
#   key, menu label, folders under games/, extensions
#
# The first folder is the system's own, and its gamelist is taken whole. A
# later one is shared with another system - the Game Boy Color's games may
# live in GAMEBOY - and only this system's extensions are taken from it.
# Folders are matched without regard to case, on every root in GAME_ROOTS.
# ---------------------------------------------------------------------------
SYSTEMS = [
    ("NES",             "Nintendo NES",              ["NES"],                  "nes fds unf unif"),
    ("SNES",            "Super Nintendo",            ["SNES"],                 "sfc smc bs"),
    ("GAMEBOY",         "Game Boy",                  ["GAMEBOY"],              "gb"),
    ("GBC",             "Game Boy Color",            ["GBC", "GAMEBOY"],       "gbc"),
    ("GBA",             "Game Boy Advance",          ["GBA"],                  "gba"),
    ("VirtualBoy",      "Virtual Boy",               ["VirtualBoy"],           "vb vboy"),
    ("N64",             "Nintendo 64",               ["N64"],                  "z64 n64 v64"),
    ("SMS",             "Master System",             ["SMS"],                  "sms sg"),
    ("GameGear",        "Game Gear",                 ["GameGear"],             "gg"),
    ("MegaDrive",       "Mega Drive / Genesis",      ["MegaDrive", "Genesis"], "md gen bin smd"),
    ("S32X",            "Sega 32X",                  ["S32X"],                 "32x"),
    ("MegaCD",          "Mega-CD / Sega CD",         ["MegaCD"],               "chd cue"),
    ("Saturn",          "Sega Saturn",               ["Saturn"],               "chd cue"),
    ("PSX",             "PlayStation",               ["PSX"],                  "chd cue"),
    ("TGFX16",          "PC Engine / TurboGrafx-16", ["TGFX16"],               "pce bin"),
    ("TGFX16CD",        "PC Engine CD",              ["TGFX16-CD"],            "chd cue"),
    ("NeoGeo",          "Neo Geo",                   ["NEOGEO"],               "neo zip"),
    ("3DO",             "3DO",                       ["3DO"],                  "chd cue iso"),
    ("Jaguar",          "Atari Jaguar",              ["Jaguar"],               "j64 jag rom bin"),
    ("AtariLynx",       "Atari Lynx",                ["AtariLynx"],            "lnx"),
    ("Atari2600",       "Atari 2600",                ["Atari2600"],            "a26 bin"),
    ("Atari5200",       "Atari 5200",                ["ATARI5200"],            "a52 car bin rom"),
    ("Atari7800",       "Atari 7800",                ["ATARI7800"],            "a78 bin"),
    ("WonderSwan",      "WonderSwan",                ["WonderSwan"],           "ws"),
    ("WonderSwanColor", "WonderSwan Color",          ["WonderSwanColor"],      "wsc"),
]

# Arcade needs no icon - the card is the whole panel - so it is always
# offered. Its gamelist is the one in games/mame, beside the zips, so it is
# keyed by MAME set name, which is what an .mra's <setname> says and what the
# daemon looks it up by. _Arcade is not searched: its .mra files are not what
# a scraper scrapes, and a set's name is the key both sides agree on.
ARCADE = ("Arcade", "Arcade (games/mame)", ["mame", "hbmame"], "zip 7z")

# ScummVM runs its games through the split layout too, with its own icons, so
# it is always offered. A scraper names a ScummVM game by its folder - "Full
# Throttle (CD DOS)" - or by a .scummvm file holding its target, "ft.scummvm";
# the daemon looks the running game up both ways.
SCUMMVM = ("ScummVM", "ScummVM (games/ScummVM)", ["ScummVM"], "scummvm svm")

# Other names an icon goes by. Both spellings ship in pics/icon, and one
# system should appear once in the menu, not twice.
ICON_ALIASES = {"MegaDrive": ["Genesis"], "NeoGeo": ["NEOGEO"]}

# One line a game, "|"-separated like the title index - the daemon's
# lookup_scraped reads exactly these. The CRC is empty: a gamelist keys on
# the file name, and so does the daemon, first.
FIELDS = ["key", "crc", "status", "title", "released", "players", "rating",
          "genre", "developer", "publisher", "series", "desc"]


def say(msg=""):
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# The ini. Parsed, not sourced - the same rules as the settings editor: the
# last uncommented assignment wins, one layer of quotes comes off, and the
# user's file overrides the system's. ${NAME} is expanded from values already
# read, which is all the system ini uses it for.
# ---------------------------------------------------------------------------
def read_ini(path, into, pinned=()):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return into
    for line in lines:
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if val[:1] in ('"', "'"):
            q = val[0]
            end = val.find(q, 1)
            val = val[1:end] if end > 0 else val[1:]
        else:
            val = val.split("#", 1)[0].strip()
        val = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda mm: into.get(mm.group(1), ""), val)
        if key not in pinned:
            into[key] = val
    return into


def load_config(install):
    # TTY2OLED_PATH is wherever this install actually is, whatever the ini
    # says, so everything derived from it - SCRAPE_DIR - is beside it too.
    cfg = {"TTY2OLED_PATH": install}
    pin = ("TTY2OLED_PATH",)
    read_ini(os.path.join(install, "tty2oled-system.ini"), cfg, pin)
    read_ini(os.path.join(install, "tty2oled-user.ini"), cfg, pin)
    if not cfg.get("SCRAPE_DIR"):
        cfg["SCRAPE_DIR"] = os.path.join(install, "scraped")
    cfg.setdefault("GAME_ROOTS", "/media/fat /media/usb0 /media/usb1 /media/usb2 "
                                 "/media/usb3 /media/usb4 /media/usb5 /media/usb6 /media/usb7 "
                                 "/media/fat/cifs")
    return cfg


def icon_names(install):
    folder = os.path.join(install, "pics", "icon")
    try:
        return {n[:-4].lower() for n in os.listdir(folder) if n.lower().endswith(".gsc")}
    except OSError:
        return set()


def supported_systems(install):
    """The consoles with an icon - the only ones with a split layout to put a
    description page in - and the arcade, whose card needs none."""
    have = icon_names(install)
    out = []
    for s in SYSTEMS:
        names = [s[0]] + ICON_ALIASES.get(s[0], [])
        if any(n.lower() in have for n in names):
            out.append(s)
    out.append(ARCADE)
    out.append(SCUMMVM)
    return out


# ---------------------------------------------------------------------------
# Text: printable ASCII, one line, no "|". The panel's font and the firmware's
# wrap both take a byte for a character, and the database is "|"-separated.
# ---------------------------------------------------------------------------
_FOLD = {"‘": "'", "’": "'", "‚": "'", "“": '"', "”": '"',
         "„": '"', "–": "-", "—": "-", "…": "...", " ": " ",
         "ß": "ss", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE",
         "ø": "o", "Ø": "O", "ł": "l", "Ł": "L", "đ": "d",
         "Ð": "D", "þ": "th", "Þ": "Th", "²": "2", "³": "3"}


def fold(text):
    if not text:
        return ""
    s = html.unescape(str(text))
    for a, b in _FOLD.items():
        s = s.replace(a, b)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    s = s.replace("|", "/")
    s = re.sub(r"[\x00-\x1f\x7f]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


# A sentence ends at a full stop, "!" or "?" - and a closing quote or bracket
# after it - followed by a space and what can start the next one. "Dr. Mario"
# and "Vs. Excitebike" do not end one.
_SENTENCE_END = re.compile(r"[.!?][\"')\]]?(?= [A-Z0-9\"'(])")
_NOT_AN_END = {"dr", "mr", "mrs", "ms", "st", "mt", "vs", "jr", "sr", "no", "vol"}


def clip_desc(text):
    """A description the firmware can keep: whole sentences up to DESC_MAX,
    so the page stops rather than trailing off, when a sentence ends in the
    second half; otherwise cut at a word, with "..."."""
    if len(text) <= DESC_MAX:
        return text
    end = 0
    for m in _SENTENCE_END.finditer(text, 0, DESC_MAX + 2):
        if m.end() > DESC_MAX:
            break
        word = text[:m.start()].rsplit(" ", 1)[-1].lower()
        if text[m.start()] == "." and word in _NOT_AN_END:
            continue
        end = m.end()
    if end > DESC_MAX // 2:
        return text[:end]
    cut = text[:DESC_MAX - 3]
    sp = cut.rfind(" ")
    if sp > DESC_MAX // 2:
        cut = cut[:sp]
    return cut.rstrip(" ,;:.") + "..."


# ---------------------------------------------------------------------------
# The database: scraped/<system>.txt, one game a line. Rewritten whole after
# each system, atomically, so a run cut short leaves the last good file.
# ---------------------------------------------------------------------------
def db_path(cfg, key):
    return os.path.join(cfg["SCRAPE_DIR"], key + ".txt")


def db_load(path):
    out = {}
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("|")
                if len(parts) >= 3 and parts[0]:
                    out[parts[0]] = line.rstrip("\n")
    except OSError:
        pass
    return out


def db_line(key, info):
    vals = [key, "", "ok"] + [info.get(f, "") for f in FIELDS[3:]]
    return "|".join(v.replace("|", "/").replace("\n", " ") for v in vals)


def db_write(path, entries):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii", errors="replace") as f:
        for k in sorted(entries, key=str.lower):
            f.write(entries[k] + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# gamelist.xml. EmulationStation's format, shared by every frontend that
# scrapes: a <game> per ROM, keyed by <path> relative to the file. The file
# name is our key too - both came from the same ROMs - so no CRC is needed.
#
#   <path>./Super Mario Bros. (World).nes</path>   -> the key
#   <name> <desc> <developer> <publisher> <genre> <players>  -> as they are
#   <releasedate>19850913T000000</releasedate>       -> 1985-09-13
#   <rating>0.8</rating>                              -> 16, out of 20
#   <family>                                          -> series (Batocera)
#
# Only the system's own folder is looked in, games/<folder>/gamelist.xml: that
# is where the frontends write it, beside the games it describes.
# ---------------------------------------------------------------------------
# What a game is known by: its file name less the extension - the same rule
# the daemon's lookup_scraped applies to CURRENTPATH, so the two agree on
# names with a dot in them ("Castle of Dr. Brain (CD DOS)" has no extension;
# splitext thought it was " Brain (CD DOS)"). ScummVM's own long extensions
# go too.
_EXT = re.compile(r"\.([A-Za-z0-9]{1,4}|scummvm)$", re.IGNORECASE)


def _key(name):
    return _EXT.sub("", os.path.basename(name)).replace("|", "/")


def find_gamelists(system, roots):
    """Every games/<folder>/gamelist.xml for this system, with whether the
    folder is the system's own.

    Each file once, however many roots reach it. MiSTer can mount one drive
    twice - the same /dev/sda1 on /media/usb0 and /media/usb1 - and a path
    tells two copies of a file from one file seen twice no better than a
    name does, so the file is known by its device and inode. The first root
    to reach it names it."""
    out, seen = [], set()
    for root in roots.split():
        games = os.path.join(root, "games")
        try:
            present = os.listdir(games)
        except OSError:
            continue
        for n, folder in enumerate(system[2]):
            for entry in present:
                if entry.lower() != folder.lower():
                    continue
                base = os.path.join(games, entry)
                try:
                    names = os.listdir(base)
                except OSError:
                    continue
                for fn in names:
                    path = os.path.join(base, fn)
                    if fn.lower() != "gamelist.xml":
                        continue
                    try:
                        st = os.stat(path)
                    except OSError:
                        continue
                    ident = (st.st_dev, st.st_ino)
                    if ident not in seen:
                        seen.add(ident)
                        out.append((path, n == 0))
    return out


def gl_date(text):
    m = re.match(r"\s*(\d{4})-?(\d{2})?-?(\d{2})?", text or "")
    if not m or m.group(1) == "0000":
        return ""
    y, mo, d = m.groups()
    if not mo or mo == "00":
        return y
    if not d or d == "00":
        return "%s-%s" % (y, mo)
    return "%s-%s-%s" % (y, mo, d)


def gl_rating(text):
    try:
        r = float((text or "").strip())
    except ValueError:
        return ""
    if not 0 < r <= 1:
        return ""
    return str(int(round(r * 20)))


def parse_gamelist(path, exts=None):
    """(key, info) for every <game> in the file; exts, when given, keeps
    only the games with one of those extensions (or a zip)."""
    tree = ET.parse(path)
    for game in tree.getroot().iter("game"):
        rel = (game.findtext("path") or "").strip().replace("\\", "/")
        if not rel:
            continue
        name = os.path.basename(rel.rstrip("/"))
        ext = os.path.splitext(name)[1][1:].lower()
        if exts is not None and ext not in exts and ext not in ("zip", "7z"):
            continue
        info = {
            "title": fold(game.findtext("name")),
            "released": gl_date(game.findtext("releasedate")),
            "players": fold(game.findtext("players")),
            "rating": gl_rating(game.findtext("rating")),
            "genre": fold(game.findtext("genre")),
            "developer": fold(game.findtext("developer")),
            "publisher": fold(game.findtext("publisher")),
            "series": fold(game.findtext("family")),
            "desc": clip_desc(fold(game.findtext("desc"))),
        }
        if any(info.values()):
            yield _key(name), info


def import_gamelists(cfg, systems):
    os.makedirs(cfg["SCRAPE_DIR"], exist_ok=True)
    totals, problems = [], []
    for system in systems:
        key, label = system[0], system[1]
        lists = find_gamelists(system, cfg["GAME_ROOTS"])
        path = db_path(cfg, key)
        entries = db_load(path)
        games = described = 0
        for gl, own in lists:
            try:
                found = list(parse_gamelist(gl, None if own else set(system[3].split())))
            except (ET.ParseError, OSError) as e:
                problems.append("%s: %s" % (gl, e))
                say("  %s - could not be read: %s" % (gl, e))
                continue
            say("  %s - %d game(s)" % (gl, len(found)))
            for k, info in found:
                # What the file says wins over what was there: it is the one
                # the user chose, and it describes their own ROMs.
                entries[k] = db_line(k, info)
                games += 1
                described += 1 if info["desc"] else 0
        if lists:
            db_write(path, entries)
        totals.append((label, len(lists), games, described))
    return totals, problems


def import_summary(totals, problems):
    lines = ["%-26s %9s %6s %12s" % ("", "gamelists", "games", "descriptions")]
    for label, n, g, d in totals:
        lines.append("%-26s %9d %6d %12d" % (label[:26], n, g, d))
    if not any(t[1] for t in totals):
        lines.append("")
        lines.append("No gamelist.xml was found. Put one in each system's own games")
        lines.append("folder - games/NES/gamelist.xml, or games/mame/gamelist.xml")
        lines.append("for arcade, games/ScummVM/gamelist.xml for ScummVM - and")
        lines.append("import again.")
    if problems:
        lines.append("")
        lines.append("Could not be read:")
        lines.extend("  " + p for p in problems)
    return "\n".join(lines)


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Import the gamelist.xml in each system's games folder.")
    ap.add_argument("--install", default=os.environ.get("T2OP_INSTALL", here))
    ap.add_argument("--list-systems", action="store_true")
    ap.add_argument("--systems", default="", help="comma separated keys, or 'all'")
    ap.add_argument("--summary", help="also write the summary here")
    args = ap.parse_args(argv)

    cfg = load_config(args.install)
    supported = supported_systems(args.install)

    if args.list_systems:
        for s in supported:
            print("%s\t%s" % (s[0], s[1]))
        return 0

    wanted = [w.strip().lower() for w in args.systems.split(",") if w.strip()]
    systems = [s for s in supported if "all" in wanted or s[0].lower() in wanted]
    if not systems:
        say("Name the systems to import: --systems NES,SNES,Arcade (or all).")
        say("Of the consoles, only those with an icon have a description page.")
        return 2

    totals, problems = import_gamelists(cfg, systems)
    text = import_summary(totals, problems)
    say("")
    say(text)
    if args.summary:
        try:
            with open(args.summary, "w") as f:
                f.write(text + "\n")
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
