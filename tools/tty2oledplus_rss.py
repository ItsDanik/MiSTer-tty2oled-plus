#!/usr/bin/env python3
"""
tty2oledplus_rss.py - an RSS or Atom feed's headlines, for the display's band.

The daemon runs this in the background (tty2oled.sh, rss_pass) and sends what
it leaves in --out to the firmware, which runs the headlines through the ten
rows under the menu's picture, taking turns with the date and time.

    tty2oledplus_rss.py --url https://misterzine.fyi/releases/feed.xml \
                        --out /tmp/.tty2oledplus-rss.txt [--max 20]

--out's first line is "# <url>" - so a file left by another feed is not taken
for this one's - and then a headline a line, newest first as the feed has
them: each item's <title>, folded to printable ASCII as the scraper folds a
game's name (the panel's 5x7 font has nothing else), at most --max of them
and BYTES_MAX bytes in all, which is what the firmware keeps (RSS_MAX in
bandnote.h; tests/test-rss.py holds the two together).

Prints "ok <headlines>" and exits 0, or "error: <why>" and exits 1 leaving
--out as it was: a feed that cannot be fetched keeps the headlines it had.

RSS 2.0 (<item>), RSS 1.0 (the same, namespaced) and Atom (<entry>) are told
apart by nothing but those names: any element called item or entry with a
title in it is a headline. Standard library only - MiSTer's Python has no more.
"""

import argparse
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty2oledplus_scrape import fold  # noqa: E402

CAFILE = "/etc/ssl/certs/cacert.pem"   # MiSTer's Python finds none by itself
TIMEOUT = 20
FEED_MAX = 4 * 1024 * 1024             # a feed bigger than this is not read
BYTES_MAX = 2048                       # the firmware's RSS_MAX
ITEMS_MAX = 48                         # ...and its RSS_ITEMS_MAX
TITLE_MAX = 160                        # one headline: half a minute of ticker
AGENT = "tty2oledplus-rss/1 (+https://github.com/ItsDanik/MiSTer-tty2oled-plus)"

_TAG = re.compile(r"<[^>]{0,200}>")


def fetch(url, cafile=CAFILE):
    ctx = None
    if url.lower().startswith("https:"):
        import ssl
        if cafile and os.path.exists(cafile):
            ctx = ssl.create_default_context(cafile=cafile)
    req = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
        data = r.read(FEED_MAX + 1)
    if len(data) > FEED_MAX:
        raise ValueError("the feed is larger than %d bytes" % FEED_MAX)
    return data


def _local(tag):
    return tag.rsplit("}", 1)[-1].lower() if isinstance(tag, str) else ""


def headline(text):
    """A title as the band can show it: no markup, printable ASCII, one line."""
    s = fold(_TAG.sub(" ", text or ""))
    s = fold(_TAG.sub(" ", s))          # a title that was escaped HTML
    if len(s) > TITLE_MAX:
        s = s[:TITLE_MAX - 3].rstrip() + "..."
    return s


def headlines(data, limit):
    """The feed's titles in its own order, at most `limit` and BYTES_MAX."""
    root = ET.fromstring(data)
    out, size = [], 0
    limit = max(1, min(limit, ITEMS_MAX))
    for el in root.iter():
        if _local(el.tag) not in ("item", "entry"):
            continue
        title = next((c for c in el if _local(c.tag) == "title"), None)
        if title is None:
            continue
        s = headline("".join(title.itertext()))
        if not s:
            continue
        if size + len(s) + (1 if out else 0) > BYTES_MAX:
            break
        size += len(s) + (1 if out else 0)
        out.append(s)
        if len(out) >= limit:
            break
    return out


def write(path, url, lines):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="ascii", newline="\n") as f:
        f.write("# %s\n" % url)
        for s in lines:
            f.write(s + "\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max", type=int, default=20)
    ap.add_argument("--cacert", default=CAFILE)
    a = ap.parse_args()
    try:
        lines = headlines(fetch(a.url, a.cacert), a.max)
        if not lines:
            raise ValueError("no headlines in the feed")
        write(a.out, a.url, lines)
    except Exception as e:  # the daemon wants one line, whatever went wrong
        print("error: %s" % (str(e) or e.__class__.__name__))
        return 1
    print("ok %d" % len(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
