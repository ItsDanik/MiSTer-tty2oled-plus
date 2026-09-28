#!/usr/bin/env python3
"""
history2gamelist.py - arcade descriptions out of MAME's history.xml, as the
gamelist.xml that Scrape metadata imports.

    ./tools/history2gamelist.py history.xml /mnt/misterusb/games/mame
    ./tools/history2gamelist.py history.xml ~/roms/mame -o /tmp/out

Runs on the workstation. Reads the ROM folder given - the MiSTer's own
games/mame, over a share, is the point - and writes two files into the
output folder (the current one unless -o says otherwise):

    gamelist.xml   a <game> for every set in the folder that history.xml
                   has a description for; copy it to games/mame on the
                   MiSTer and run Scrape metadata -> Arcade
    2048.txt       the sets among those whose description is longer than
                   the 2048 bytes the firmware keeps (DESC_MAX, which also
                   names the file), how much is kept, and where it ends

No network and no quota: history.xml is Arcade-History's database, which
MAME frontends read offline, keyed by MAME set name - the same name an .mra's
<setname> says and the daemon looks the description up by. It is not
shipped with tty2oled+; its header asks that it be used with MAME or a
frontend and not republished, so each user converts their own download
(https://www.arcade-history.com/index.php?page=download).

What is a description. An entry is a whole article:

    Arcade Video game published 45 years ago:      <- dropped, it goes stale
    Donkey Kong (c) 1981 Nintendo.                 <- the title
    Donkey Kong is a legendary arcade platform...  <- the description
    - TECHNICAL -                                  <- from here on, not
    - TRIVIA -

Clones and export releases mostly say where they came from and point at the
original - "Export release. Game developed in Japan. For more information
about the game itself, please see the original Japanese release entry;
"1941 - Counter Attack [B-Board 89625B-1]"." - and nothing else worth
reading. An entry made of nothing but such sentences (NOTE, SEE) is a
pointer, and takes the description of the entry it points at:

  - found by the quoted title, or by its own title when nothing is quoted,
    matching the romanisation a Japanese entry gives as well as its title;
  - a machine only of its own kind (an arcade set does not lead to the
    tabletop VFD game of the same name), a console cartridge only when the
    pointer names its platform ("the original NES version") or its model ID;
  - the bracket, "[Model HVC-BF]", picks by that ID between entries that
    share a title; then a machine beats a cartridge and the longest
    description wins, the others being that game's release notes;
  - followed on when it leads to another pointer, a few hops at most - a
    Vs. set to the Famicom cartridge.

A pointer that leads to no description gives the set its own note when that
says something ("Coin-op pirate version of the Mega Drive game."), and none
when it does not ("North American release.").

A set with no description is left out of the gamelist altogether, rather
than written with an empty one: the importer replaces a game's whole line,
so an empty entry would wipe whatever a scraper had already imported for it.

A description longer than that is shortened here, where its paragraphs are
still known - the importer folds them into one line. Whole paragraphs while
they fit, since a paragraph end is where the text itself pauses; then, if
that keeps less than two thirds of what fits, whole sentences of the next
one. History's first paragraph is usually the synopsis, and what gets left
out is mostly flyer text and stage-by-stage detail. A first sentence that
alone will not fit is left for the importer, which cuts it at a word.

Standard library only. The length is measured the way the importer will
measure it - its own fold() and clip_desc(), which is what reaches the
firmware.
"""

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty2oledplus_scrape import DESC_MAX, clip_desc, fold  # noqa: E402

MARK = "written by tty2oled+ history2gamelist.py"
ROM_EXTS = (".zip", ".7z")

SECTION = re.compile(r"^- [A-Z][A-Z0-9 &/'.,-]*[A-Z] -\s*$", re.M)
COPYRIGHT = re.compile(r"\s*\(c\)\s*[0-9?]{4}")
BRACKET = re.compile(r"\s*\[([^\]]*)\]\s*$")
QUOTE = re.compile(r'"([^"]+)"')
# A sentence, with a quoted title inside it kept whole - "Dr. Mario" does not
# end one - and a full stop not ending one either when it is not followed by
# a space (R.C. Pro-Am) or is followed by lower case ("VS. arcade version").
SENTENCE = re.compile(r'(?:[^."]|"[^"]*"|\.(?=\S)|\.(?=\s+[a-z0-9]))+\.?')
# "For more information about the game itself, please see the original
# Japanese release entry; "Black Dragon"." / "See the original for more
# information; "Hyper Olympic"." / "please see the NTSC release's entry" -
# and "visit" or "refer to" in place of "see".
MORE_INFO = re.compile(r"\bmore info", re.I)
SEE = re.compile(r"\b(?:see|visit|refer to)\b.*?(?:\boriginal\b|\bentry\b|for more information)", re.I)
# What the pointer says the original is: "the original NES version",
# "the original Japanese release entry" -> "NES", "Japanese".
VIA = re.compile(r"(?:see|visit|refer to) the original\s+(.*?)\s*(?:\b(?:version|release|entry|for)\b|[;.]|$)", re.I)
# A sentence about the release rather than the game: "Export version.",
# "North American release.", "Budget re-release.", "Bootleg made for the
# Ambush hardware.", "Out Run Upgrade KIT edition.", "Game developed in
# Japan.", "Stand-alone release of "Hamburger"."
NOTE = re.compile(
    r"^(?:[\w'&/().,]+[ -]){0,5}?(?:releases?|re-releases?|versions?|ver\b|bootlegs?|clones?|"
    r"conversions?|editions?|hacks?|kits?|upgrades?|licen[cs]ed?|portage|export|models?|"
    r"cabinets?|prototypes?|pirate|updates?)\b"
    r"|^(?:the )?(?:game )?(?:originally )?(?:developed|manufactured|licensed|distributed|"
    r"made|produced|published) (?:in|by|for|under)\b", re.I)
# Only this, of a stub whose original has no description, is worth showing:
# "Coin-op pirate version of the Mega Drive game." says something, "North
# American release. Game developed in Japan." does not.
NOTE_WORDS = 6
DEVELOPED = re.compile(r"^(?:game )?(?:originally )?developed in\b", re.I)
NOTE_MAX = 300


# ---------------------------------------------------------------------------
# The ROM folder. A set is a .zip or .7z, or a folder of CHDs named after it.
# ---------------------------------------------------------------------------
def enumerate_sets(folder):
    """{set name, lower case: file name as it is on disk}."""
    found = {}
    with os.scandir(folder) as it:
        entries = sorted(it, key=lambda e: e.name)
    for e in entries:
        if e.name.startswith("."):
            continue
        stem, ext = os.path.splitext(e.name)
        if e.is_file() and ext.lower() in ROM_EXTS:
            found.setdefault(stem.lower(), e.name)
        elif e.is_dir() and _has_chd(e.path):
            found.setdefault(e.name.lower(), e.name)
    return found


def _has_chd(path):
    try:
        return any(n.lower().endswith(".chd") for n in os.listdir(path))
    except OSError:
        return False


# ---------------------------------------------------------------------------
# history.xml
# ---------------------------------------------------------------------------
class Entry:
    __slots__ = ("sets", "header", "title", "names", "desc", "pointer", "target", "via",
                 "note", "text")

    def __init__(self, sets, text):
        self.sets = sets
        self.text = text
        self.header = text.lstrip().split("\n", 1)[0].strip()   # "Nintendo Famicom cart. ..."
        self.title, self.names, self.desc = split_article(text)
        self.pointer, self.target, self.via, self.note = False, "", "", ""
        sents = _sentences(self.desc)
        sees = [x for x in sents if SEE.search(x)]
        lead = _sentences(self.desc.split("\n\n", 1)[0])
        stub = all(SEE.search(x) or NOTE.search(x) for x in sents)
        # Or where it came from, "for more information" on the game, and then
        # a list of how this release differs - which is not a description.
        differs = any(MORE_INFO.search(x) for x in sees) \
            and all(SEE.search(x) or NOTE.search(x) for x in lead)
        if sents and ((stub and len(self.desc) <= NOTE_MAX) or differs):
            self.pointer = True
            quoted = [q for x in sees + sents for q in QUOTE.findall(x)]
            self.target = quoted[0].strip() if quoted else ""
            m = VIA.search(" ".join(sees))
            self.via = m.group(1).strip() if m else ""
            rest = [x for x in sents if not SEE.search(x)]
            if any(len(x.split()) >= NOTE_WORDS and not DEVELOPED.search(x) for x in rest):
                self.note = " ".join(rest)
        elif sees:
            # "For the ports, please see the original ... entry." in an
            # entry with a description of its own: only the sentence goes.
            self.desc = _tidy("\n\n".join(
                " ".join(x for x in _sentences(p) if not SEE.search(x))
                for p in self.desc.split("\n\n")))


def _sentences(text):
    return [x.strip() for x in SENTENCE.findall(text) if x.strip()]


def split_article(text):
    """(title, every name the title paragraph gives, description)."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    m = SECTION.search(text)
    body = text[:m.start()] if m else text
    paras = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    if paras and paras[0].endswith(":") and "\n" not in paras[0]:
        paras = paras[1:]                      # "... published 45 years ago:"
    title, names = "", []
    for i, p in enumerate(paras[:2]):
        first = p.split("\n", 1)[0]
        c = COPYRIGHT.search(first)
        if not c:
            continue
        names.append(first[:c.start()].strip())
        # A Japanese title is followed by its romanisation, in brackets,
        # on a line of its own - "(Seishun Scandal)".
        for line in p.split("\n")[1:]:
            line = line.strip()
            if line.startswith("(") and line.endswith(")"):
                names.append(line[1:-1].strip())
        ascii_names = [n for n in names if n.isascii()]
        title = ascii_names[0] if ascii_names else names[0]
        paras = paras[i + 1:]
        break
    return title, [n for n in names if n], _tidy("\n\n".join(paras))


def _tidy(text):
    paras = [re.sub(r"[ \t]+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
    return "\n\n".join(p for p in paras if p)


def load_history(path):
    """Every entry, in file order. The arcade ones are keyed by MAME machine,
    <systems>, and only those are sets; a software-list entry (<software>, a
    console's cartridge) has no set of its own but can still be what a
    pointer leads to - a PlayChoice or Vs. set says "please see the original
    NES version"."""
    out = []
    for _, elem in ET.iterparse(path, events=("end",)):
        if elem.tag != "entry":
            continue
        systems = elem.find("systems")
        sets = []
        if systems is not None:
            sets = [s.get("name", "").lower() for s in systems.findall("system")]
            sets = [s for s in sets if s]
        if sets or elem.find("software") is not None:
            out.append(Entry(sets, elem.findtext("text") or ""))
        elem.clear()
    return out


def build_index(entries):
    by_set, by_title = {}, {}
    for e in entries:
        for s in e.sets:
            by_set.setdefault(s, e)
        if e.desc:
            for n in e.names:
                by_title.setdefault(n.lower(), []).append(e)
    return by_set, by_title


HOPS = 4


def resolve(entry, by_title):
    """(description, how) for one entry: its own, or the one it points at -
    which may itself point on, a PlayChoice set to its Vs. set to the NES
    cartridge, so a pointer is followed up to HOPS times."""
    if not entry.desc:
        return "", "none"
    if not entry.pointer:
        return entry.desc, "own"
    first, seen = entry, {id(entry)}
    for _ in range(HOPS):
        entry = _pointee(entry, by_title, seen)
        if entry is None:
            break
        if not entry.pointer:
            return entry.desc, "parent"
        seen.add(id(entry))
    if first.note:
        return first.note, "note"
    return "", "unresolved"


def _pointee(entry, by_title, seen):
    wanted = entry.target or entry.title
    bracket = BRACKET.search(wanted)
    name = BRACKET.sub("", wanted).strip().lower()
    words = bracket.group(1).split() if bracket else []
    ident = words[-1] if words else ""          # "[Model HVC-BF]" -> "HVC-BF"
    cands = [c for c in by_title.get(name, [])
             if id(c) not in seen and (_same_kind(entry, c) if c.sets
                                       else _names_platform(entry, c, ident))]
    if ident and len(cands) > 1:
        narrowed = [c for c in cands if ident in c.text]
        cands = narrowed or cands
    # A description of its own beats one that points on; a machine beats a
    # cartridge, since a model ID can turn up in a home port's trivia too;
    # and of what is left the longest wins - the others are the same game's
    # release notes.
    cands.sort(key=lambda c: (c.pointer, not c.sets, -len(c.desc)))
    return cands[0] if cands else None


def _kind(e):
    """ "Arcade Video game kit published 39 years ago:" -> "arcade video"."""
    kind = re.split(r" published|:", e.header, maxsplit=1)[0].strip().lower()
    return " ".join(kind.split()[:2])


def _same_kind(entry, cand):
    """Machines share titles too - PlayChoice's Tennis and a tabletop VFD
    Tennis are both MAME sets - so a machine is only the original of one of
    its own kind."""
    return _kind(entry) == _kind(cand)


def _names_platform(entry, cand, ident):
    """Whether a pointer leads to this software-list entry. A title alone
    does not: "Tennis" is a PlayChoice set, an Atari 2600 cartridge and a
    dozen others. It has to name the platform - "the original NES version"
    against "Nintendo NES NTSC cart." - or carry the cartridge's model ID."""
    if ident and ident in cand.text:
        return True
    via = entry.via.lower()
    return bool(via) and re.search(r"\b%s\b" % re.escape(via), cand.header.lower()) is not None


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
def ours(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return MARK in f.read(512)
    except OSError:
        return True                             # nothing there to lose


def write_gamelist(path, games):
    root = ET.Element("gameList")
    for filename, title, desc in games:
        g = ET.SubElement(root, "game")
        ET.SubElement(g, "path").text = "./" + filename
        ET.SubElement(g, "name").text = title
        ET.SubElement(g, "desc").text = desc
    ET.indent(root, "\t")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write("<!-- %s, from MAME's history.xml -->\n" % MARK)
        f.write(ET.tostring(root, encoding="unicode"))
        f.write("\n")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Shortening. Lengths are what the importer makes of the text: fold() joins
# the paragraphs with a space, so "\n\n" counts one.
# ---------------------------------------------------------------------------
FILL = 2 / 3        # below this share of DESC_MAX, a paragraph end costs too much
_ENDS_SENTENCE = re.compile(r"[.!?][\"')\]]*\s*$")


def _flen(paras):
    return len(fold("\n\n".join(paras)))


def shorten(desc):
    """(text, where it now ends): the description as it is when it fits -
    "" - or cut to whole paragraphs, "paragraph", or to whole sentences of
    the next one, "sentence". A first sentence too long to keep is left
    whole, for the importer's cut at a word: "word"."""
    if len(fold(desc)) <= DESC_MAX:
        return desc, ""
    paras = desc.split("\n\n")
    kept = []
    for p in paras:
        if _flen(kept + [p]) > DESC_MAX:
            break
        kept.append(p)
    # Not ending on what introduces the part left out: "*CAST OF
    # CHARACTERS*", "The stages are:".
    while kept and not _ENDS_SENTENCE.search(kept[-1]):
        kept.pop()
    if kept and _flen(kept) >= DESC_MAX * FILL:
        return "\n\n".join(kept), "paragraph"
    part = []
    for x in _sentences(paras[len(kept)]):
        if _flen(kept + [" ".join(part + [x])]) > DESC_MAX:
            break
        part.append(x)
    # A list's items have no full stops, so half a list reads as a sentence.
    while part and not _ENDS_SENTENCE.search(part[-1]):
        part.pop()
    if part:
        return "\n\n".join(kept + [" ".join(part)]), "sentence"
    if kept:
        return "\n\n".join(kept), "paragraph"
    return desc, "word"


def write_overflow(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        f.write("# Descriptions longer than the %d bytes the firmware keeps, shortened to\n"
                "# end at a paragraph or a sentence - or, when not even one sentence fits,\n"
                "# at a word, with '...'.\n"
                "# set|bytes|kept|ends at|title\n" % DESC_MAX)
        for s, n, kept, where, title in rows:
            f.write("%s|%d|%d|%s|%s\n" % (s, n, kept, where, title.replace("|", "/")))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Write a gamelist.xml of arcade descriptions from MAME's history.xml, "
                    "for the sets in a ROM folder.")
    ap.add_argument("history", help="history.xml")
    ap.add_argument("roms", help="the folder of MAME sets to describe, e.g. games/mame")
    ap.add_argument("-o", "--out", default=".",
                    help="where to write gamelist.xml and %d.txt" % DESC_MAX)
    ap.add_argument("--force", action="store_true",
                    help="overwrite a gamelist.xml this tool did not write")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.roms):
        print("Not a folder: %s" % args.roms, file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    gl_path = os.path.join(args.out, "gamelist.xml")
    if not args.force and not ours(gl_path):
        print("%s was not written by this tool - a scraper's, perhaps. "
              "Choose another -o, or --force to replace it." % gl_path, file=sys.stderr)
        return 2

    sets = enumerate_sets(args.roms)
    print("%d set(s) in %s" % (len(sets), args.roms))
    entries = load_history(args.history)
    by_set, by_title = build_index(entries)
    print("%d arcade entries in %s, and %d others a pointer may lead to"
          % (sum(1 for e in entries if e.sets), args.history, sum(1 for e in entries if not e.sets)))

    games, overflow = [], []
    count = {"own": 0, "parent": 0, "note": 0, "none": 0, "unresolved": 0, "absent": 0}
    for s in sorted(sets):
        entry = by_set.get(s)
        if entry is None:
            count["absent"] += 1
            continue
        desc, how = resolve(entry, by_title)
        count[how] += 1
        if not desc:
            continue
        title = entry.title or s
        short, where = shorten(desc)
        games.append((sets[s], title, short))
        if where:
            overflow.append((s, len(fold(desc)), len(clip_desc(fold(short))), where, fold(title)))

    ov_path = os.path.join(args.out, "%d.txt" % DESC_MAX)
    write_gamelist(gl_path, games)
    write_overflow(ov_path, overflow)

    print("")
    print("  %6d described by their own entry" % count["own"])
    print("  %6d by the entry they point at (clones, export releases)" % count["parent"])
    print("  %6d by their own release note, the original having no description"
          % count["note"])
    print("  %6d have an entry with no description" % count["none"])
    print("  %6d point at an entry that has none, or that was not found" % count["unresolved"])
    print("  %6d are not in history.xml" % count["absent"])
    print("")
    print("%d game(s) -> %s" % (len(games), gl_path))
    ends = {w: sum(1 for o in overflow if o[3] == w) for w in ("paragraph", "sentence", "word")}
    print("%d longer than %d bytes, shortened to a paragraph end %d, a sentence end %d, "
          "a word %d -> %s" % (len(overflow), DESC_MAX, ends["paragraph"], ends["sentence"],
                              ends["word"], ov_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
