#!/usr/bin/env python3
"""tty2oled+ system update check. Runs ON THE MISTER, from the install folder.

Would update_all update something you have? Answered without running it, from
what update_all's downloader leaves behind after every successful run:

  /media/fat/downloader.ini, downloader_*.ini
      every database update_all uses, and its URL (update_all writes the
      drop-in ones itself - arcade ROMs, artwork, custom sources)
  Scripts/.config/downloader/downloader_fingerprints.json
      each database as it was when last applied: the md5 and size of the file
      downloaded from that URL
  Scripts/.config/downloader/downloader.json
      what each database installed: every file with its hash, every archive
  /MiSTer.version
      the Linux the MiSTer is running

Two levels, the second only where the first finds something:

  1. Download each database and compare its md5 and size with the
     fingerprint. The same: nothing in it has changed since the last run.
  2. A database that changed is compared with what it installed. Any change
     to the files you have counts - but only those: a database covers every
     core in it, including the ones your filter leaves out, and a change to
     one of those is not an update for you. So:
       - an installed file whose hash differs
       - an installed dated file (NES_20260101.rbf) the database has
         replaced with another date of the same name
       - an installed archive (palettes, cheats...) whose summary changed
       - the Linux release, in a database that carries one
     New cores and files you do not have yet are not counted: whether your
     filter would take them is the downloader's business. Nor is a file two
     databases both install: the downloader settles which one's copy it
     keeps, and the other's entry stays stale for ever - found on a real
     MiSTer, kuzecores and mister_ongo both shipping one .mra.

Every half hour, 65 databases are a megabyte and a half and a TLS handshake
each. So --cache keeps each URL's ETag beside the md5 it had: while that md5
is still the fingerprint's, the request is conditional, and GitHub's 304 is
"the same" with no body.

Prints one line and exits:
    yes <database>: <what>    0   something you have would be updated
    no                        0   nothing, or nothing reachable changed
    nostate                   3   no downloader state: update_all never ran
    error <why>               1   no database could be checked (offline)

Standard library only: a MiSTer has Python 3.9 and nothing installed on top.
The downloader's files are internal to it, not an interface; anything in them
this does not recognise counts as unchanged rather than as an update.
"""

import argparse
import concurrent.futures
import glob
import hashlib
import io
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
import zipfile

CAFILE = "/etc/ssl/certs/cacert.pem"   # MiSTer's Python finds none by itself
TIMEOUT = 20                            # seconds, per database
THREADS = 6                             # the downloader's own default

# A dated build: NES_20260928.rbf, Arcade-NamcoS2_SG_20260927.rbf. The date
# is the only part of the name a new build changes.
DATED = re.compile(r"_(\d{8})(?=\.[A-Za-z0-9]+$)")


def read_inis(fat):
    """{database id: url}, ids lower-cased as the fingerprints have them."""
    paths = [os.path.join(fat, "downloader.ini")]
    paths += sorted(glob.glob(os.path.join(fat, "downloader_*.ini")))
    dbs = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        section = None
        for line in lines:
            line = line.strip()
            if not line or line[0] in "#;":
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip().lower()
                continue
            key, sep, value = line.partition("=")
            if sep and section and section != "mister" and key.strip().lower() == "db_url":
                dbs.setdefault(section, value.strip())
    return dbs


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def fetch(url, cafile, etag=None):
    """(body, etag); body None for a 304 to the ETag given."""
    ctx = ssl.create_default_context(cafile=cafile) if cafile and os.path.exists(cafile) else None
    headers = {"User-Agent": "tty2oledplus"}
    if etag:
        headers["If-None-Match"] = etag
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
            return resp.read(), resp.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304 and etag:
            return None, etag
        raise


def parse_db(data):
    """A database as the downloader reads it: JSON, or JSON inside a zip."""
    if data[:2] == b"PK":
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = [n for n in z.namelist() if n.endswith(".json")] or z.namelist()
            data = z.read(names[0])
    db = json.loads(data.decode("utf-8"))
    return db if isinstance(db, dict) else {}


def undated(path):
    return DATED.sub("", path)


def _hash(desc):
    return desc.get("hash") if isinstance(desc, dict) else None


def shared_paths(local_dbs):
    """Files more than one database lists as installed."""
    seen, shared = set(), set()
    for local in local_dbs.values():
        files = local.get("files") if isinstance(local, dict) else None
        for path in files if isinstance(files, dict) else ():
            (shared if path in seen else seen).add(path)
    return shared


def installed_changes(db, local, linux_version, shared=frozenset()):
    """What in a changed database would update something installed, or None."""
    remote_files = db.get("files") or {}
    local_files = (local or {}).get("files") or {}
    if not isinstance(remote_files, dict) or not isinstance(local_files, dict):
        return None

    # Installed dated files by their name without the date, for the ones the
    # database no longer lists: those are the ones a new date replaces.
    gone = {}
    for path in local_files:
        if path not in remote_files and path not in shared and DATED.search(path):
            gone[undated(path)] = path

    for path, desc in remote_files.items():
        if path in shared:
            continue
        mine = local_files.get(path)
        if mine is not None:
            if _hash(desc) and _hash(mine) and _hash(desc) != _hash(mine):
                return path
        elif gone and undated(path) in gone:
            return path

    # Archives: "archives" in the current format, "zips" in the older one,
    # and "zips" in the downloader's own store either way.
    remote_arch = db.get("archives") or db.get("zips") or {}
    local_arch = (local or {}).get("zips") or {}
    if isinstance(remote_arch, dict) and isinstance(local_arch, dict):
        for aid, desc in remote_arch.items():
            mine = local_arch.get(aid)
            if not isinstance(desc, dict) or not isinstance(mine, dict):
                continue
            theirs = _hash(desc.get("summary_file"))
            ours = _hash(mine.get("summary_file"))
            if theirs and ours and theirs != ours:
                return aid

    linux = db.get("linux")
    if isinstance(linux, dict) and linux.get("version") and linux_version:
        if str(linux["version"]) != linux_version:
            return "Linux " + str(linux["version"])
    return None


def check(fat, config, version_file, cafile, verbose=False, cache_path=None, force=False):
    """(verdict line, exit code). force: every database to level 2."""
    say = (lambda m: print(m, file=sys.stderr)) if verbose else (lambda m: None)
    fingerprints = load_json(os.path.join(config, "downloader_fingerprints.json"))
    if not isinstance(fingerprints, dict) or not fingerprints:
        return "nostate", 3
    urls = {i: u for i, u in read_inis(fat).items() if isinstance(fingerprints.get(i), dict)}
    if not urls:
        return "nostate", 3

    cache = (load_json(cache_path) if cache_path else None) or {}
    if not isinstance(cache, dict):
        cache = {}

    def one(item):
        dbid, url = item
        fp = fingerprints[dbid]
        seen = cache.get(url)
        # Conditional only while what was seen is what was applied: a body
        # that differs is wanted whole, for level 2.
        etag = None
        if not force and isinstance(seen, dict) and seen.get("md5") == fp.get("hash") \
                and seen.get("size") == fp.get("size"):
            etag = seen.get("etag")
        try:
            data, tag = fetch(url, cafile, etag)
            return dbid, url, data, tag, None
        except Exception as e:                    # noqa: BLE001 - any failure is "not checked"
            return dbid, url, None, None, e

    changed, reached, failed = [], 0, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as pool:
        for dbid, url, data, tag, err in pool.map(one, sorted(urls.items())):
            if err is not None:
                failed += 1
                say("%-45s failed: %s" % (dbid, err))
                continue
            reached += 1
            if data is None:
                say("%-45s same (304)" % dbid)
                continue
            fp = fingerprints[dbid]
            md5 = hashlib.md5(data).hexdigest()
            if tag:
                cache[url] = {"etag": tag, "md5": md5, "size": len(data)}
            same = md5 == fp.get("hash") and len(data) == fp.get("size")
            say("%-45s %s (%d bytes)" % (dbid, "same" if same else "CHANGED", len(data)))
            if force or not same:
                changed.append((dbid, data))

    if cache_path:
        try:
            tmp = cache_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(cache, fh)
            os.replace(tmp, cache_path)
        except OSError:
            pass

    if not reached:
        return "error none of %d databases could be reached" % failed, 1
    if not changed:
        return "no", 0

    # Level 2. The store is the big one - megabytes, seconds to read on a
    # DE10 - so it is read only now, when a database has actually changed.
    store = load_json(os.path.join(config, "downloader.json"))
    local_dbs = store.get("dbs") if isinstance(store, dict) else None
    if not isinstance(local_dbs, dict):
        return "no", 0
    linux_version = ""
    try:
        with open(version_file, encoding="utf-8", errors="replace") as fh:
            linux_version = fh.read().strip()
    except OSError:
        pass
    shared = shared_paths(local_dbs)
    for dbid, data in changed:
        try:
            db = parse_db(data)
        except (ValueError, zipfile.BadZipFile, KeyError, IndexError, UnicodeDecodeError):
            say("%-45s could not be read" % dbid)
            continue
        what = installed_changes(db, local_dbs.get(dbid), linux_version, shared)
        say("%-45s %s" % (dbid, ("installed: " + what) if what else "nothing you have"))
        if what:
            return "yes %s: %s" % (dbid, what), 0
    return "no", 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Would update_all update something installed?")
    ap.add_argument("--fat", default="/media/fat")
    ap.add_argument("--config", help="the downloader's state (default <fat>/Scripts/.config/downloader)")
    ap.add_argument("--version-file", default="/MiSTer.version")
    ap.add_argument("--cafile", default=CAFILE)
    ap.add_argument("--cache", help="ETags from the last check, kept here between runs")
    ap.add_argument("--all", action="store_true",
                    help="compare every database with what it installed, changed or not")
    ap.add_argument("-v", "--verbose", action="store_true", help="each database, on stderr")
    args = ap.parse_args(argv)
    config = args.config or os.path.join(args.fat, "Scripts", ".config", "downloader")
    line, code = check(args.fat, config, args.version_file, args.cafile, args.verbose,
                       args.cache, args.all)
    print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
