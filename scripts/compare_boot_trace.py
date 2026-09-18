#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff TG68K.C's boot against MAME's. Phase 0 exit criterion 2.

    python scripts/compare_boot_trace.py replay  daiskiss   # MAME's I/O reads -> replay file
    python scripts/compare_boot_trace.py compare daiskiss   # RTL trace vs MAME trace

Both traces are "seq rw addr mask data", addr being the dword-aligned 24-bit
address and mask the byte lanes of the 32-bit bus -- which is what MAME's tap
reports and what sim/gx_boot_tb/tb_gx_boot.sv writes.

WHAT IS COMPARED, AND WHAT IS NOT (after the MS32 core's comparator, which
arrived at this through the Seta core's)

  * WRITES, strictly, in order: address, lanes, and data under the mask. This
    is the strong check. A CPU that executes the same program correctly makes
    the same writes with the same data in the same order, whatever it does
    with the bus in between.
  * NON-ROM READS, in order: these are the replayed I/O reads. A mismatch means
    the RTL asked a peripheral a different question from MAME's CPU.
  * ROM FETCHES, as a superset only. TG68K.C prefetches and MAME's core does
    not, so two correct CPUs read the same words in different orders and the
    RTL reads words MAME never asks for (LESSONS_LEARNED, "[Seta] Two cores
    that both boot correctly still fetch different words, so compare as a
    subsequence with duplicates collapsed"). What is checked is that every ROM
    word MAME read inside the RTL's window, the RTL also read.

The RTL trace is shorter than MAME's by design; it is compared up to the
number of writes it reached.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROM_END = 0x800000          # 0x000000-0x7fffff: BIOS, program, data ROM
WORKRAM = (0xC00000, 0xC20000)


def load(path):
    rows = []
    for ln in open(path, encoding="utf8"):
        if ln.startswith("#") or not ln.strip():
            continue
        seq, rw, a, m, d = ln.split()
        m = int(m, 16)
        rows.append((int(seq), rw, int(a, 16), m, int(d, 16) & m))
    return rows


def merge_halves(rows):
    """Join two consecutive accesses to the same dword into one.

    TG68K.C's bus is 16 bits wide, so a 32-bit access is two word accesses,
    upper half then lower. MAME's tap is inconsistent about the same thing:
    it reports INSTRUCTION FETCHES as two halves but DATA accesses as one
    32-bit access. Comparing raw traces therefore puts the two sides one entry
    out of step at every 32-bit data access -- the first run's write #71, a
    32-bit write to D40004, which MAME logged as one FFFFFFFF write and the RTL
    as FFFF0000 + 0000FFFF with identical data.

    Worse, it skews everything that is aligned by write COUNT, which is how the
    comparison window is cut: the RTL's N writes were fewer of MAME's, the
    window ran past where the RTL stopped, and ROM coverage read as 13,911 of
    131,939 when the RTL was simply partway through the same byte-scan loop.

    Normalising both sides the same way removes the difference entirely: an
    adjacent pair with the same direction, the same dword and disjoint lanes
    becomes one access with the lanes and data ORed together.
    """
    out = []
    for r in rows:
        if out:
            s0, rw0, a0, m0, d0 = out[-1]
            _, rw1, a1, m1, d1 = r
            if rw0 == rw1 and a0 == a1 and not (m0 & m1):
                out[-1] = (s0, rw0, a0, m0 | m1, d0 | d1)
                continue
        out.append(r)
    return out


def is_rom(a):
    return a < ROM_END


def is_ram(a):
    return WORKRAM[0] <= a < WORKRAM[1]


def cmd_replay(game):
    mame = REPO / "debug" / f"{game}-boot" / f"{game}_boot.trace"
    out = REPO / "debug" / f"{game}-boot" / f"{game}_replay.txt"
    n = 0
    with open(out, "w", encoding="utf8") as f:
        for seq, rw, a, m, d in load(mame):
            if rw == "r" and not is_rom(a) and not is_ram(a):
                f.write(f"{a:06X} {m:08X} {d:08X}\n")
                n += 1
    print(f"{n} I/O reads -> {out}")
    return 0


def cmd_compare(game):
    base = REPO / "debug" / f"{game}-boot"
    raw_mame = load(base / f"{game}_boot.trace")
    raw_rtl = load(base / f"{game}_rtl.trace")
    if not raw_rtl:
        sys.exit("the RTL trace is empty -- did the bench run?")
    mame = merge_halves(raw_mame)
    rtl = merge_halves(raw_rtl)
    print(f"merged split halves: MAME {len(raw_mame)} -> {len(mame)} accesses, "
          f"RTL {len(raw_rtl)} -> {len(rtl)}")

    mw = [(a, m, d) for _, rw, a, m, d in mame if rw == "w"]
    rw_ = [(a, m, d) for _, rw, a, m, d in rtl if rw == "w"]
    rc = 0

    # --- writes, strictly in order
    n = len(rw_)
    first = next((i for i in range(min(n, len(mw))) if rw_[i] != mw[i]), None)
    if first is None and n <= len(mw):
        print(f"WRITES    {n} of {n} match MAME in address, lanes, data and order")
    else:
        rc = 1
        if first is None:
            print(f"WRITES    the RTL made {n} writes, MAME only {len(mw)} in its trace")
        else:
            print(f"WRITES    MISMATCH at write {first + 1} of {n}:")
            for i in range(max(0, first - 3), min(first + 4, n, len(mw))):
                flag = "  <--" if i == first else ""
                a1, m1, d1 = mw[i]
                a2, m2, d2 = rw_[i]
                print(f"    #{i + 1:<6} MAME {a1:06X} {m1:08X} {d1:08X}   "
                      f"RTL {a2:06X} {m2:08X} {d2:08X}{flag}")

    # How far into MAME's trace does the RTL's progress reach? Up to the
    # MAME access that made the RTL's last write.
    wseen = 0
    mame_cut = len(mame)
    for i, (_, rw, *_rest) in enumerate(mame):
        if rw == "w":
            wseen += 1
            if wseen == n:
                mame_cut = i + 1
                break
    window = mame[:mame_cut]

    # --- non-ROM reads, in order
    mio = [(a, m, d) for _, rw, a, m, d in window if rw == "r" and not is_rom(a)]
    rio = [(a, m, d) for _, rw, a, m, d in rtl if rw == "r" and not is_rom(a)]
    k = min(len(mio), len(rio))
    bad = next((i for i in range(k) if mio[i] != rio[i]), None)
    if bad is None and len(mio) == len(rio):
        print(f"I/O READS {len(rio)} of {len(rio)} match MAME in order")
    else:
        rc = 1
        print(f"I/O READS MAME {len(mio)}, RTL {len(rio)}; first difference at "
              f"{bad + 1 if bad is not None else k + 1}")

    # --- ROM fetches, superset
    mrom = {(a, m) for _, rw, a, m, d in window if rw == "r" and is_rom(a)}
    # Coverage is per BYTE LANE, not per (address, mask) pair: the RTL may have
    # read a whole dword where MAME read one half, or two halves where MAME
    # read the dword, and either way the lanes MAME asked for were read.
    rlanes = {}
    for _, rw, a, m, d in rtl:
        if rw == "r" and is_rom(a):
            rlanes[a] = rlanes.get(a, 0) | m
    def covered(a, m):
        return (m & ~rlanes.get(a, 0)) == 0
    missing = [x for x in mrom if not covered(*x)]
    if missing:
        rc = 1
        missing.sort()
        print(f"ROM       {len(mrom) - len(missing)} of {len(mrom)} MAME ROM reads were also "
              f"made by the RTL; first missing: {missing[0][0]:06X} {missing[0][1]:08X}")
    else:
        print(f"ROM       every one of MAME's {len(mrom)} distinct ROM reads in the window "
              f"was also made by the RTL")

    print(f"\nwindow: RTL {len(rtl)} accesses, MAME {mame_cut} accesses to the same "
          f"write ({n} writes)")
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["replay", "compare"])
    ap.add_argument("game")
    a = ap.parse_args()
    return cmd_replay(a.game) if a.cmd == "replay" else cmd_compare(a.game)


if __name__ == "__main__":
    sys.exit(main())
