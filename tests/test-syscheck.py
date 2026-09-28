#!/usr/bin/env python3
"""
Tests for tools/tty2oledplus_syscheck.py, which works out whether update_all
would update something installed, from what its downloader left behind.

Run as a command, as the daemon runs it, over a fake /media/fat: the
downloader's inis, its fingerprints and its store, and databases served from
local files by file:// URLs - which urllib reads the way it reads https.
The shapes are the real ones, taken from a MiSTer: fingerprints
{hash, size, timestamp, filter}; a store's db with files {path: {hash, size}}
and zips {id: {summary_file, contents_file}}; a remote db with files,
archives {id: {summary_file, archive_file}} and linux {version}.

    ./tests/test-syscheck.py
"""

import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "tools", "tty2oledplus_syscheck.py")
TMP = os.path.join(HERE, "fixtures", "tmp", "syscheck")

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


FAT = os.path.join(TMP, "fat")
CONFIG = os.path.join(FAT, "Scripts", ".config", "downloader")
REMOTE = os.path.join(TMP, "remote")
VERSION = os.path.join(TMP, "MiSTer.version")


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def zipped(obj, name="db.json"):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(name, json.dumps(obj))
    return buf.getvalue()


def f(h):
    return {"hash": h * 32, "size": 10}


# The databases as they were when update_all last ran: what is on the server
# now, until a test changes it. "main" is zipped, like distribution_mister;
# "extra" is plain JSON, like the MultiDatabases ones.
MAIN = {
    "db_id": "distribution_mister",
    "files": {
        "_Console/NES_20260101.rbf": f("a"),
        "_Console/SNES_20260101.rbf": f("b"),
        "_Computer/C64_20260101.rbf": f("c"),     # filtered out: not installed
        "MiSTer": f("d"),
    },
    "archives": {"cheats_folder_nes": {"summary_file": f("e"), "archive_file": f("f")},
                 "gba_palettes": {"summary_file": f("1"), "archive_file": f("2")}},
    "linux": {"version": "260912", "hash": "9" * 32, "size": 1},
}
EXTRA = {"db_id": "extra", "files": {"games/X/x.bin": f("3")}}
OTHER = {"db_id": "other", "files": {"_Arcade/Shared.mra": f("4"), "_Arcade/Own.mra": f("a")}}

# What the downloader installed from them: C64 left out by the filter, and
# gba_palettes likewise. "_Arcade/Shared.mra" is installed by two databases,
# as kuzecores and mister_ongo both ship one on a real MiSTer.
STORE = {"dbs": {
    "distribution_mister": {
        "files": {k: v for k, v in MAIN["files"].items() if not k.startswith("_Computer")},
        "zips": {"cheats_folder_nes": {"summary_file": f("e"), "contents_file": f("f")}},
        "folders": {}, "base_path": "/media/fat"},
    "extra": {"files": dict(EXTRA["files"]), "zips": {}},
    "other": {"files": {"_Arcade/Shared.mra": f("4"), "_Arcade/Own.mra": f("a")}, "zips": {}},
    "coin-op/dist": {"files": {"_Arcade/Shared.mra": f("5")}, "zips": {}},
}, "db_fingerprints": {}, "migration_version": 13, "internal": True}


def serve(name, data):
    path = os.path.join(REMOTE, name)
    write(path, data)
    return path


def fingerprint(data):
    return {"hash": hashlib.md5(data).hexdigest(), "size": len(data),
            "timestamp": 1790000000, "filter": ""}


def setup(main=MAIN, extra=EXTRA, other=OTHER, store=STORE, applied=None, linux="260912"):
    """A MiSTer whose update_all last applied `applied` (default: what is served)."""
    shutil.rmtree(TMP, ignore_errors=True)
    served = {"distribution_mister": serve("main.json.zip", zipped(main)),
              "extra": serve("extra.json", json.dumps(extra).encode()),
              "other": serve("other.json", json.dumps(other).encode())}
    applied = applied or {"distribution_mister": zipped(MAIN),
                          "extra": json.dumps(EXTRA).encode(),
                          "other": json.dumps(OTHER).encode()}
    fps = {k: fingerprint(v) for k, v in applied.items()}
    # A fingerprint whose database is in no ini any more: dropped from
    # update_all's settings. It must be skipped, not fetched.
    fps["names_txt"] = fingerprint(b"gone")
    write(os.path.join(CONFIG, "downloader_fingerprints.json"), json.dumps(fps))
    write(os.path.join(CONFIG, "downloader.json"), json.dumps(store))
    # The main ini, with the [mister] section of options every one has, and a
    # section name in its own case - the fingerprints lower-case it.
    write(os.path.join(FAT, "downloader.ini"),
          "[mister]\nfilter = !c64\n\n"
          "[distribution_mister]\ndb_url = file://%s\n\n"
          "[Extra]\ndb_url = file://%s\nfilter = arcade\n" % (served["distribution_mister"], served["extra"]))
    # A drop-in ini of update_all's own.
    write(os.path.join(FAT, "downloader_custom_sources.ini"),
          "[other]\ndb_url = file://%s\n" % served["other"])
    write(VERSION, linux + "\n")
    return served


def run(*extra):
    p = subprocess.run([sys.executable, TOOL, "--fat", FAT, "--version-file", VERSION] + list(extra),
                       capture_output=True, text=True)
    return p.stdout.strip(), p.returncode


def changed(**kw):
    d = json.loads(json.dumps(MAIN))
    for k, v in kw.items():
        d[k] = v
    return d


# ---------------------------------------------------------------------------
section("nothing new: every database is the one last applied")
# ---------------------------------------------------------------------------
setup()
ok("no", run(), ("no", 0))
out = subprocess.run([sys.executable, TOOL, "--fat", FAT, "--version-file", VERSION, "-v"],
                     capture_output=True, text=True).stderr
ok("every database in an ini is looked at", sorted(l.split()[0] for l in out.splitlines()),
   ["distribution_mister", "extra", "other"])
ok("a fingerprint with no ini is not", "names_txt" in out, False)

# ---------------------------------------------------------------------------
section("level 1 only: a database changed, nothing installed from it did")
# ---------------------------------------------------------------------------
m = changed()
m["files"]["_Computer/C64_20260928.rbf"] = m["files"].pop("_Computer/C64_20260101.rbf")
m["archives"]["gba_palettes"]["summary_file"] = f("7")
m["files"]["_Console/Brand_New_20260928.rbf"] = f("8")
m["timestamp"] = 1790999999
setup(main=m)
ok("a new build of a filtered-out core, a new core, an archive not installed: no",
   run(), ("no", 0))

# ---------------------------------------------------------------------------
section("level 2: something installed would be updated")
# ---------------------------------------------------------------------------
m = changed()
m["files"]["_Console/NES_20260928.rbf"] = m["files"].pop("_Console/NES_20260101.rbf")
setup(main=m)
ok("a new build of an installed core", run(),
   ("yes distribution_mister: _Console/NES_20260928.rbf", 0))

m = changed()
m["files"]["MiSTer"] = f("0")
setup(main=m)
ok("an installed file whose hash changed", run(), ("yes distribution_mister: MiSTer", 0))

m = changed()
m["archives"]["cheats_folder_nes"]["summary_file"] = f("0")
setup(main=m)
ok("an installed archive whose summary changed", run(),
   ("yes distribution_mister: cheats_folder_nes", 0))

m = changed()
m["linux"] = {"version": "261001", "hash": "8" * 32, "size": 1}
setup(main=m)
ok("a new Linux", run(), ("yes distribution_mister: Linux 261001", 0))

x = json.loads(json.dumps(EXTRA))
x["files"]["games/X/x.bin"] = f("0")
setup(extra=x)
ok("in a plain-JSON database, from a drop-in's neighbour", run(), ("yes extra: games/X/x.bin", 0))

o = json.loads(json.dumps(OTHER))
o["files"]["_Arcade/Own.mra"] = f("6")
setup(other=o)
ok("in a database from a downloader_*.ini", run(), ("yes other: _Arcade/Own.mra", 0))

m = changed()
m["zips"] = m.pop("archives")
m["zips"]["cheats_folder_nes"]["summary_file"] = f("0")
setup(main=m)
ok("archives under the older name, zips", run(), ("yes distribution_mister: cheats_folder_nes", 0))

# ---------------------------------------------------------------------------
section("what is not an update")
# ---------------------------------------------------------------------------
o = json.loads(json.dumps(OTHER))
o["files"]["_Arcade/Shared.mra"] = f("6")
setup(other=o)
ok("a file two databases install: the downloader keeps one copy, not this", run(), ("no", 0))

m = changed()
del m["files"]["_Console/SNES_20260101.rbf"]
setup(main=m)
ok("a file the database dropped, with nothing replacing it", run(), ("no", 0))

m = changed()
m["linux"] = {"version": "260912", "hash": "7" * 32, "size": 2}
setup(main=m)
ok("the Linux this MiSTer runs", run(), ("no", 0))

m = changed()
m["files"]["_Console/NES_20260928.rbf"] = f("0")
setup(main=m)
ok("a second date beside the installed one, which is still listed", run(), ("no", 0))

# ---------------------------------------------------------------------------
section("when it cannot say")
# ---------------------------------------------------------------------------
served = setup()
for p in served.values():
    os.remove(p)
out, rc = run()
ok("nothing reachable: error", (out.split()[0], rc), ("error", 1))

served = setup()
os.remove(served["other"])
ok("some reachable: what they say", run(), ("no", 0))
m = changed()
m["files"]["MiSTer"] = f("0")
served = setup(main=m)
os.remove(served["extra"])
ok("an update found among the ones reached", run(), ("yes distribution_mister: MiSTer", 0))

setup()
os.remove(os.path.join(CONFIG, "downloader_fingerprints.json"))
ok("no fingerprints - update_all never ran: nostate", run(), ("nostate", 3))

setup()
write(os.path.join(CONFIG, "downloader_fingerprints.json"), "{not json")
ok("fingerprints it cannot read: nostate", run(), ("nostate", 3))

m = changed()
m["files"]["MiSTer"] = f("0")
setup(main=m)
write(os.path.join(CONFIG, "downloader.json"), "[]")
ok("a store it does not recognise: no update, not a guess", run(), ("no", 0))

m = changed()
m["files"]["MiSTer"] = f("0")
served = setup(main=m)
write(served["distribution_mister"], b"PK\x03\x04 not a zip")
ok("a database it cannot read: skipped", run(), ("no", 0))

# ---------------------------------------------------------------------------
section("--all: every database to level 2, changed or not")
# ---------------------------------------------------------------------------
setup()
ok("an up-to-date MiSTer has nothing, even compared file by file", run("--all"), ("no", 0))
store = json.loads(json.dumps(STORE))
store["dbs"]["distribution_mister"]["files"]["MiSTer"] = f("0")
setup(store=store)
ok("so a store behind its own fingerprint shows up there", run("--all"), ("yes distribution_mister: MiSTer", 0))
ok("but not without it: the fingerprint says nothing changed", run(), ("no", 0))

# ---------------------------------------------------------------------------
section("the ETag cache: conditional only while what was seen was applied")
# ---------------------------------------------------------------------------
spec = importlib.util.spec_from_file_location("syscheck", TOOL)
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)
sent = []


def fake_fetch(url, cafile, etag=None):
    sent.append(etag)
    if etag == "E1":
        return None, etag                   # 304
    with open(url[len("file://"):], "rb") as fh:
        return fh.read(), "E1"


sc.fetch = fake_fetch
setup()
cache = os.path.join(TMP, "etags.json")
ok("first time: unconditional", (sc.check(FAT, CONFIG, VERSION, None, cache_path=cache), sent),
   (("no", 0), [None, None, None]))
kept = json.load(open(cache))
ok("the ETag and the md5 it had are kept", sorted(v["etag"] for v in kept.values()), ["E1", "E1", "E1"])
sent.clear()
ok("next time: conditional, and a 304 is the same", (sc.check(FAT, CONFIG, VERSION, None, cache_path=cache), sent),
   (("no", 0), ["E1", "E1", "E1"]))
# update_all has run since: the fingerprint is no longer what was seen, so
# the body is wanted whole.
fps = json.load(open(os.path.join(CONFIG, "downloader_fingerprints.json")))
fps["extra"]["hash"] = "0" * 32
write(os.path.join(CONFIG, "downloader_fingerprints.json"), json.dumps(fps))
sent.clear()
sc.check(FAT, CONFIG, VERSION, None, cache_path=cache)
ok("a fingerprint that moved asks without the ETag", sorted(map(str, sent)), ["E1", "E1", "None"])
sent.clear()
sc.check(FAT, CONFIG, VERSION, None, cache_path=cache, force=True)
ok("--all asks for every body", sent, [None, None, None])

# ---------------------------------------------------------------------------
section("what a dated name is")
# ---------------------------------------------------------------------------
ok("the date goes, the rest stays",
   [sc.undated(p) for p in ("_Console/NES_20260101.rbf", "_Arcade/cores/Arcade-NamcoS2_SG_20260927.rbf",
                            "MiSTer", "menu.rbf", "games/X/Y_2026.bin", "a_20260101.tar.gz")],
   ["_Console/NES.rbf", "_Arcade/cores/Arcade-NamcoS2_SG.rbf", "MiSTer", "menu.rbf",
    "games/X/Y_2026.bin", "a_20260101.tar.gz"])

shutil.rmtree(TMP, ignore_errors=True)
print(f"\n\033[1mResults:\033[0m {PASS} passed, {FAIL} failed\n")
sys.exit(1 if FAIL else 0)
