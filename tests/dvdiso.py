#!/usr/bin/env python3
"""
A small DVD-Video disc image for the tests: ISO9660 with a VIDEO_TS folder
whose IFOs have the shapes tty2oledplus_dvd.py reads, laid out the way the
real Queen disc on the MiSTer was (tests/test-dvd.py, tests/test-dvd.sh).

    python3 tests/dvdiso.py <out.iso> [label] [--not-dvd]

The image is sparse: its films are 10000 sectors of nothing.

  sector  16      primary volume descriptor - the label, the date, the size
          18, 19  the root and VIDEO_TS directories
          20      VIDEO_TS.IFO - two titles; their title set's sector is wrong
                  on purpose (77), as the real disc's was
          30-39   VIDEO_TS.VOB, the disc's menu
          100     VTS_01_0.IFO - the title set starts here
          110-119 VTS_01_0.VOB, the title set's menu
          120-    VTS_01_1.VOB, the films: the title set's sector 0 is 120

  title 1   PGC 1, three chapters, 100s
            cell 1  sectors    0-2999   30s
            cell 2  sectors 3000-6999   40s - but its first 20s are only
                    3000-3999: the time map says so, and a straight line
                    through the cell would not
            cell 3  sectors 7000-8999   30s
  title 2   two chapters, a PGC each: PGC 2, sectors 9000-9999 (20s, its
            own), then PGC 3 - cell 2 of title 1 again, 40s
"""

import os
import struct
import sys

S = 2048
VTS = 100            # the title set's first sector
MENU_VOBS = 10       # ...its menu, relative to it
TITLE_VOBS = 20      # ...its films, relative to it
FILM = 10000         # sectors of film


def bcd(n):
    return ((n // 10) << 4) | (n % 10)


def dvd_time(secs):
    """dvd_time_t: hours, minutes, seconds in BCD, then frames with 11 in the
    top bits - 29.97 frames a second."""
    return bytes([bcd(secs // 3600), bcd(secs % 3600 // 60), bcd(secs % 60), 0xC0])


def be16(n):
    return struct.pack(">H", n)


def be32(n):
    return struct.pack(">I", n)


def both16(n):
    return struct.pack("<H", n) + struct.pack(">H", n)


def both32(n):
    return struct.pack("<I", n) + struct.pack(">I", n)


def put(buf, off, data):
    buf[off:off + len(data)] = data


def pgc(cells, programs, total):
    """A PGC: cells as (first, last, seconds), programs as entry cells."""
    b = bytearray(0xEC)
    b[2] = len(programs)
    b[3] = len(cells)
    put(b, 4, dvd_time(total))
    pm = len(b)
    b += bytes(programs)
    if len(b) % 2:
        b += b"\0"
    cp = len(b)
    for first, last, secs in cells:
        e = bytearray(24)
        put(e, 4, dvd_time(secs))
        put(e, 8, be32(first))
        put(e, 16, be32(last))
        put(e, 20, be32(last))
        b += e
    pos = len(b)
    b += b"\0\0\0\0" * len(cells)
    put(b, 0xE6, be16(pm))
    put(b, 0xE8, be16(cp))
    put(b, 0xEA, be16(pos))
    return bytes(b)


def vts_ifo():
    ifo = bytearray(4 * S)
    put(ifo, 0, b"DVDVIDEO-VTS")
    put(ifo, 0x0C, be32(TITLE_VOBS + FILM - 1))
    put(ifo, 0xC0, be32(MENU_VOBS))
    put(ifo, 0xC4, be32(TITLE_VOBS))
    put(ifo, 0xC8, be32(1))            # PTT_SRPT
    put(ifo, 0xCC, be32(2))            # PGCITI
    put(ifo, 0xD4, be32(3))            # TMAPTI

    # The titles' chapters: (pgcn, pgn).
    t1 = [(1, 1), (1, 2), (1, 3)]
    t2 = [(2, 1), (3, 1)]
    ptt = bytearray(16)
    put(ptt, 0, be16(2))
    put(ptt, 8, be32(16))
    put(ptt, 12, be32(16 + 4 * len(t1)))
    for pgcn, pgn in t1 + t2:
        ptt += be16(pgcn) + be16(pgn)
    put(ptt, 4, be32(len(ptt) - 1))
    put(ifo, 1 * S, ptt)

    pgcs = [
        pgc([(0, 2999, 30), (3000, 6999, 40), (7000, 8999, 30)], [1, 2, 3], 100),
        pgc([(9000, 9999, 20)], [1], 20),
        pgc([(3000, 6999, 40)], [1], 40),
    ]
    pgci = bytearray(8 + 8 * len(pgcs))
    put(pgci, 0, be16(len(pgcs)))
    for i, p in enumerate(pgcs):
        put(pgci, 8 + 8 * i, bytes([0x81 if i < 2 else 0x01, 0, 0, 0]) + be32(len(pgci)))
        pgci += p
    put(pgci, 4, be32(len(pgci) - 1))
    put(ifo, 2 * S, pgci)

    # PGC 1's time map, an entry each 2s: 100 sectors a second in cell 1,
    # 50 for cell 2's first 20s, 150 for its last, 66.67 in cell 3.
    def sector_at(t):
        if t <= 30:
            return t * 100
        if t <= 50:
            return 3000 + (t - 30) * 50
        if t <= 70:
            return 4000 + (t - 50) * 150
        return 7000 + (t - 70) * 2000 // 30
    entries = [sector_at(t) for t in range(2, 100, 2)]
    maps = [(2, entries), (0, []), (0, [])]
    tm = bytearray(8 + 4 * len(maps))
    put(tm, 0, be16(len(maps)))
    for i, (unit, ents) in enumerate(maps):
        put(tm, 8 + 4 * i, be32(len(tm)))
        tm += bytes([unit, 0]) + be16(len(ents)) + b"".join(be32(e) for e in ents)
    put(tm, 4, be32(len(tm) - 1))
    put(ifo, 3 * S, tm)
    return bytes(ifo)


def vmg_ifo():
    ifo = bytearray(2 * S)
    put(ifo, 0, b"DVDVIDEO-VMG")
    put(ifo, 0xC4, be32(1))
    tt = bytearray(8)
    put(tt, 0, be16(2))
    for ttn, chapters in ((1, 3), (2, 2)):
        tt += bytes([0x3C, 1]) + be16(chapters) + be16(0) + bytes([1, ttn]) + be32(77)
    put(tt, 4, be32(len(tt) - 1))
    put(ifo, S, tt)
    return bytes(ifo)


def record(name, lba, size, is_dir=False):
    n = name.encode("ascii")
    rec = bytearray(33 + len(n) + (0 if len(n) % 2 else 1))
    rec[0] = len(rec)
    put(rec, 2, both32(lba))
    put(rec, 10, both32(size))
    rec[25] = 2 if is_dir else 0
    put(rec, 28, both16(1))
    rec[32] = len(n)
    put(rec, 33, n)
    return bytes(rec)


def directory(lba, entries, parent):
    d = record("\0", lba, S, True) + record("\1", parent, S, True)
    for e in entries:
        d += e
    return d.ljust(S, b"\0")


def make_iso(path, label="TEST_MOVIE_WS_D1", created="2004100423072500", dvd=True):
    total = VTS + TITLE_VOBS + FILM
    with open(path, "wb") as f:
        f.truncate(total * S)
        pvd = bytearray(S)
        pvd[0] = 1
        put(pvd, 1, b"CD001")
        pvd[6] = 1
        put(pvd, 40, label.encode("ascii").ljust(32, b" "))
        put(pvd, 80, both32(total))
        put(pvd, 156, record("\0", 18, S, True))
        put(pvd, 813, (created + "\0").encode("ascii"))
        f.seek(16 * S); f.write(pvd)
        f.seek(17 * S); f.write(b"\xffCD001\x01".ljust(S, b"\0"))
        if dvd:
            f.seek(18 * S); f.write(directory(18, [record("VIDEO_TS", 19, S, True)], 18))
            f.seek(19 * S)
            f.write(directory(19, [
                record("VIDEO_TS.IFO;1", 20, 2 * S),
                record("VIDEO_TS.VOB;1", 30, 10 * S),
                record("VTS_01_0.IFO;1", VTS, 4 * S),
                record("VTS_01_0.VOB;1", VTS + MENU_VOBS, 10 * S),
                record("VTS_01_1.VOB;1", VTS + TITLE_VOBS, FILM * S),
            ], 18))
            f.seek(20 * S); f.write(vmg_ifo())
            f.seek(VTS * S); f.write(vts_ifo())
        else:
            f.seek(18 * S); f.write(directory(18, [record("README.TXT;1", 20, 10)], 18))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    make_iso(args[0], *(args[1:2] or []), dvd="--not-dvd" not in sys.argv)
