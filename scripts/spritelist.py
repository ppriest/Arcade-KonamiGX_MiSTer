#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Decode a sprite list -- the board's, dumped by scripts/memdump.py, or
MAME's, from a capture -- and say what each active entry draws.

    python scripts/memdump.py d20000 1000 debug/board/spriteram.bin
    python scripts/spritelist.py debug/board/spriteram.bin
    python scripts/spritelist.py debug/daiskiss-f2400/spriteram.bin --top-left

An entry is eight big-endian words (k053247):

    0  bit 15 active, 14 square, 13 flip y, 12 flip x, 11:8 size, 7:0 z-code
    1  code        2  y        3  x        4  zoom y    5  zoom x
    6  attribute (colour, shadow code)     7  unused

--top-left lists only what lands in the first 64x64 of the screen, which is
where the board shows graphics the benches do not.
"""
import argparse
import struct
import sys
from pathlib import Path

SIZE = {0: "16", 1: "32", 2: "64", 3: "128"}


def entries(raw):
    for i in range(len(raw) // 16):
        w = struct.unpack(">8H", raw[i * 16:i * 16 + 16])
        yield i, w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--top-left", action="store_true",
                    help="only entries drawing in the first 64x64 of the screen")
    ap.add_argument("--all", action="store_true", help="inactive entries too")
    a = ap.parse_args()
    raw = Path(a.file).read_bytes()
    n = 0
    print(f"{'idx':>4} {'z':>3} {'code':>5} {'x':>5} {'y':>5} {'zx':>5} {'zy':>5} "
          f"{'attr':>5}  size  flip")
    for i, w in entries(raw):
        active = w[0] & 0x8000
        if not active and not a.all:
            continue
        # y and x are signed on the bus
        y = w[2] - 0x10000 if w[2] & 0x8000 else w[2]
        x = w[3] - 0x10000 if w[3] & 0x8000 else w[3]
        hsz, vsz = SIZE[(w[0] >> 8) & 3], SIZE[(w[0] >> 10) & 3]
        if a.top_left and not (-64 < x < 64 and -64 < y < 64):
            continue
        flip = ("x" if w[0] & 0x1000 else "-") + ("y" if w[0] & 0x2000 else "-")
        print(f"{i:4d} {w[0] & 0xff:3d} {w[1]:5x} {x:5d} {y:5d} {w[4]:5x} {w[5]:5x} "
              f"{w[6]:5x}  {hsz}x{vsz}  {flip}" + ("" if active else "   (inactive)"))
        n += 1
    print(f"-- {n} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
