#!/usr/bin/env python3
"""
Tests for tools/tty2oledplus_rss.py, which turns an RSS or Atom feed into the
headlines the display runs under the menu's picture.

Run as a command, as the daemon runs it, on feeds served from local files by
file:// URLs - which urllib reads the way it reads https. The first feed has
the shape of the default one, MisterZine's releases feed.

    ./tests/test-rss.py
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "tty2oledplus_rss.py")
TMP = os.path.join(HERE, "fixtures", "tmp", "rss")

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


shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(TMP)
OUT = os.path.join(TMP, "out.txt")


def feed(name, text):
    path = os.path.join(TMP, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return "file://" + path


def run(url, *extra):
    r = subprocess.run([sys.executable, TOOL, "--url", url, "--out", OUT, *extra],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def out():
    with open(OUT, "rb") as f:
        return f.read().decode("ascii").split("\n")


def item(title, extra=""):
    return f"<item><title>{title}</title><link>https://example.org/</link>{extra}</item>\n"


RSS = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
<title>MiSTer FPGA Core &amp; Arcade Tracker: All changes</title>
<link>https://misterzine.fyi/releases/?ref=rss</link>
<description>New cores/games and shipped updates.</description>
<atom:link rel="self" type="application/rss+xml" href="https://misterzine.fyi/releases/feed.xml"/>
%s</channel>
</rss>
"""

section("an RSS 2.0 feed")
url = feed("rss.xml", RSS % (
    item("[Updated] Cosmo Gang the Video (Arcade)",
         "<description>&lt;p&gt;Shooter / 1991 / Namco&lt;/p&gt;</description>")
    + item("[New] Pokémon &amp; Friends – “Deluxe” (GBA)")
    + item("<![CDATA[<b>Bold</b> &amp; <i>plain</i>]]>")
    + item("  spread\n   over\tlines  ")
    + item("")
    + "<item><link>https://example.org/untitled</link></item>\n"
    + item("The last one")))
rc, said = run(url)
ok("it succeeds", rc, 0)
ok("and says how many headlines", said, "ok 5")
lines = out()
ok("the file opens by naming its feed", lines[0], "# " + url)
ok("then the items' titles, in the feed's order - not the channel's", lines[1],
   "[Updated] Cosmo Gang the Video (Arcade)")
ok("accents and typographic marks folded to ASCII, entities read", lines[2],
   '[New] Pokemon & Friends - "Deluxe" (GBA)')
ok("markup in a title dropped, escaped or not", lines[3], "Bold & plain")
ok("a title is one line", lines[4], "spread over lines")
ok("an empty title and an item with none are skipped", lines[5], "The last one")
ok("a newline after the last, and nothing more", lines[6:], [""])
ok("every byte printable ASCII", all(re.fullmatch(r"[ -~]*", s) for s in lines), True)

section("the other shapes")
url = feed("atom.xml", """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>The feed's own title</title>
  <entry><title type="html">An &lt;em&gt;Atom&lt;/em&gt; entry</title><id>1</id></entry>
  <entry><title>A second</title><id>2</id></entry>
</feed>
""")
rc, said = run(url)
ok("Atom: its entries", (rc, said, out()[1:3]), (0, "ok 2", ["An Atom entry", "A second"]))
url = feed("rdf.xml", """<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
  <channel rdf:about="x"><title>Channel</title></channel>
  <item rdf:about="a"><title>An RSS 1.0 item</title></item>
</rdf:RDF>
""")
rc, said = run(url)
ok("RSS 1.0: its items, namespace and all", (rc, said, out()[1]), (0, "ok 1", "An RSS 1.0 item"))

section("what is kept")
url = feed("many.xml", RSS % "".join(item(f"Headline number {i}") for i in range(100)))
rc, said = run(url)
ok("20 headlines unless told otherwise", said, "ok 20")
ok("the first 20: a feed is newest first", out()[20], "Headline number 19")
ok("--max", run(url, "--max", "3")[1], "ok 3")
ok("never more than the firmware keeps", run(url, "--max", "500")[1], "ok 48")
ok("nor fewer than one", run(url, "--max", "0")[1], "ok 1")
url = feed("long.xml", RSS % "".join(item(f"{i:02d} " + "long words " * 12) for i in range(48)))
rc, said = run(url, "--max", "48")
body = "\n".join(out()[1:-1])
ok("whole headlines up to the firmware's 2048 bytes, newlines counted",
   len(body) <= 2048 and len(body) > 2048 - 140, True)
ok("the last one whole", out()[-2].endswith("long words"), True)
url = feed("huge.xml", RSS % item("word " * 200))
run(url)
ok("one headline is cut at 160, and says so", (len(out()[1]), out()[1][-3:]), (160, "..."))


def define(path, name):
    with open(os.path.join(ROOT, path)) as f:
        m = re.search(r"^#define\s+%s\s+(\d+)" % name, f.read(), re.M)
    return int(m.group(1)) if m else None


with open(TOOL) as f:
    src = f.read()
ok("the tool's byte limit is the firmware's RSS_MAX",
   int(re.search(r"^BYTES_MAX = (\d+)", src, re.M).group(1)),
   define("MiSTer_SSD1322_USB/bandnote.h", "RSS_MAX"))
ok("and its headline limit the firmware's RSS_ITEMS_MAX",
   int(re.search(r"^ITEMS_MAX = (\d+)", src, re.M).group(1)),
   define("MiSTer_SSD1322_USB/bandnote.h", "RSS_ITEMS_MAX"))

section("a feed that cannot be read leaves the headlines there were")
url = feed("rss.xml", RSS % item("Kept"))
run(url)
before = out()
for name, text, why in (
        ("broken.xml", "<rss><channel><item><title>cut off", "XML that does not parse"),
        ("empty.xml", RSS % "", "a feed with no items"),
        ("page.html", "<html><body><p>Not found</p></body></html>", "a page that is no feed")):
    rc, said = run(feed(name, text))
    ok(f"{why}: an error, on one line", (rc, said.startswith("error: "), "\n" in said), (1, True, False))
    ok("...and the file as it was", out(), before)
rc, said = run("file://" + os.path.join(TMP, "missing.xml"))
ok("nothing there: an error", (rc, said.startswith("error: ")), (1, True))
ok("...and the file as it was", out(), before)
ok("no half-written file left beside it", sorted(os.listdir(TMP)).count("out.txt"), 1)
ok("nor a temporary one", [n for n in os.listdir(TMP) if ".tmp." in n], [])

print(f"\n\033[1mResults:\033[0m {PASS} passed, {FAIL} failed\n")
sys.exit(0 if FAIL == 0 else 1)
