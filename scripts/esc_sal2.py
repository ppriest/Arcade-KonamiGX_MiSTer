#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's konamigx_esc_alert mode 1 (sal2_esc), in Python, against a capture.

    python scripts/esc_sal2.py salmndr2-f3600

konamigx_m.cpp's C, ported line for line: srcbase is the work RAM as
big-endian dwords, dst the K053247 sprite RAM (8 words a sprite, word 7
left alone). Applied to the capture's workram.bin it should give the
capture's spriteram.bin, which checks the port and the capture together;
rtl/gx_esc.v's gen_sal2 is then checked against the same work RAM.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

ZTABLE = [[5, 4, 3, 2, 1, 7, 6, 0], [4, 3, 2, 1, 0, 7, 6, 5], [4, 3, 2, 1, 0, 7, 6, 5],
          [3, 2, 1, 0, 5, 7, 4, 6], [6, 5, 1, 4, 3, 7, 0, 2], [5, 4, 3, 2, 1, 7, 6, 0],
          [5, 4, 3, 2, 1, 7, 6, 0]]
PTABLE = [[0x00, 0x00, 0x00, 0x10, 0x20, 0x00, 0x00, 0x30], [0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x20, 0x20],
          [0x00, 0x00, 0x00, 0x20, 0x20, 0x00, 0x00, 0x00], [0x10, 0x10, 0x10, 0x20, 0x00, 0x00, 0x10, 0x00],
          [0x00, 0x00, 0x20, 0x00, 0x10, 0x00, 0x20, 0x20], [0x00, 0x00, 0x00, 0x10, 0x10, 0x00, 0x00, 0x10],
          [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10]]


def esc_mode1(wram, sram, srcoffs=0x1c8c, count=0x172):
    """wram: bytes (work RAM, big-endian); sram: list of 0x2000 words, modified."""
    S = lambda i: int.from_bytes(wram[4 * i:4 * i + 4], "big")     # srcbase[i], u32
    st = {"dst": 0, "j": 256}

    magic = S(0x71f0 // 4)
    vmask = 0x3ff
    if magic != 0x11010111:
        i = {0x10010801: 6, 0x11010010: 5, 0x01111018: 4, 0x10010011: 3,
             0x11010811: 2, 0x10000010: 1}.get(magic, 0)
        if magic == 0x11010010:
            vmask = 0x1ff
        vcorr = S(0x26a0 // 4) & 0xffff
        hcorr = (S(0x26a4 // 4) >> 16) - 10
    else:
        hcorr = vcorr = i = 0
    zcode, pcode = ZTABLE[i], PTABLE[i]

    def emit(words):
        d = st["dst"]
        for k, w in words.items():
            sram[d + k] = w & 0xffff
        st["dst"] = d + 8
        st["j"] -= 1
        return st["j"] == 0

    def odd(o, hoffs, voffs):
        d1 = S(o)
        if not d1 & 0x8000:
            return False
        i2 = d1 & 7
        w = {0: (d1 & 0xff00) | zcode[i2]}
        d1 = S(o + 1); w[1] = d1 >> 16; vpos = d1 & 0xffff
        d1 = S(o + 2); vpos += voffs; w[4] = d1; vpos &= vmask; hpos = d1 >> 16
        d1 = S(o + 3); hpos += hoffs; w[2] = vpos; w[3] = hpos; w[5] = d1 >> 16
        w[6] = d1 | pcode[i2] << 4
        return emit(w)

    def even(o, hoffs, voffs):
        d1 = S(o)
        if not d1 & 0x80000000:
            return False
        w = {1: d1}
        d1 >>= 16
        i2 = d1 & 7
        w[0] = (d1 & 0xff00) | zcode[i2]
        d1 = S(o + 1); hpos = d1 & 0xffff; vpos = d1 >> 16
        hpos += hoffs; vpos += voffs
        d1 = S(o + 2); vpos &= vmask; w[3] = hpos; w[2] = vpos; w[5] = d1; w[4] = d1 >> 16
        d1 = S(o + 3) >> 16
        w[6] = d1 | pcode[i2] << 4
        return emit(w)

    if S(0x049c // 4) & 0xffff0000:                          # the Vic Viper
        hoffs = (S(0x0502 // 4) & 0xffff) - hcorr
        voffs = (S(0x0506 // 4) & 0xffff) - vcorr
        for o in (0x049e // 4, 0x04ae // 4, 0x04be // 4):
            if odd(o, hoffs, voffs):
                return
    if S(0x0848 // 4) & 0x0000ffff:                          # Lord British
        hoffs = (S(0x08b0 // 4) >> 16) - hcorr
        voffs = (S(0x08b4 // 4) >> 16) - vcorr
        for o in (0x084c // 4, 0x085c // 4, 0x086c // 4):
            if even(o, hoffs, voffs):
                return
    for g in range(count):                                   # the groups
        src = srcoffs + g * 0x30
        if not S(src):
            continue
        n = S(src + 7) & 0xf
        if not n:
            continue
        hoffs = (S(src + 5) >> 16) - hcorr
        voffs = (S(src + 6) >> 16) - vcorr
        for k in range(n):
            if even(src + 8 + 4 * k, hoffs, voffs):
                return
    while st["j"]:                                           # clear residual data
        sram[st["dst"]] = 0
        st["dst"] += 8
        st["j"] -= 1


def main():
    cap = REPO / "debug" / sys.argv[1]
    wram = (cap / "workram.bin").read_bytes()
    raw = (cap / "spriteram.bin").read_bytes()
    ref = [int.from_bytes(raw[2 * i:2 * i + 2], "big") for i in range(len(raw) // 2)]
    out = ref[:]
    esc_mode1(wram, out)
    diff = [i for i in range(256 * 8) if (i & 7) != 7 and out[i] != ref[i]]
    print(f"{sys.argv[1]}: {256 * 7 - len(diff)} of {256 * 7} sprite words as the capture's")
    for i in diff[:12]:
        print(f"  sprite {i // 8} word {i & 7}: port {out[i]:04x}, capture {ref[i]:04x}")
    return 0 if not diff else 1


if __name__ == "__main__":
    sys.exit(main())
