#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A capture from a save state, in scripts/mame/capture.lua's layout.

    python scripts/ss_capture.py debug/tbx/tb1.ss mtwinbee tb1

A .ss (docs/SAVESTATES.md) holds what scripts/board_capture.py reads over
JTAG -- gx_main's register copy, sprite RAM, palette, work RAM -- and the
K056832's VRAM whole, so a state saved on the board renders on the video
benches (scripts/check_gx_video.py <set>-ss-<name>) with nothing borrowed
from MAME. reference.png is the board's own frame only if one is given
(--reference); otherwise it is black and the comparison means nothing.
"""
import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import gxss                      # noqa: E402
from board_capture import RANGES  # noqa: E402


def words_be(ws):
    return struct.pack(f">{len(ws)}H", *ws)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ss")
    ap.add_argument("set")
    ap.add_argument("name")
    ap.add_argument("--reference", help="a 288x224 picture of the frame, for the comparison")
    a = ap.parse_args()

    g = gxss.GxState.read(a.ss)
    out = REPO / "debug" / f"{a.set}-ss-{a.name}"
    out.mkdir(parents=True, exist_ok=True)

    # the register copy holds a byte per word: the chips are written bytes
    # alone, and board_capture.py takes the same words' bytes
    regs = words_be(g.sec("regs"))
    for name, lo, hi, w0 in RANGES:
        n = hi - lo + 1
        (out / f"reg_{name}.bin").write_bytes(regs[2 * w0: 2 * w0 + n])
    wr = bytearray(0x2004)
    wr[0:4] = regs[2 * 0xd4: 2 * 0xd4 + 4]
    wr[0x2000:0x2004] = regs[2 * 0xd6: 2 * 0xd6 + 4]
    (out / "reg_wrport.bin").write_bytes(bytes(wr))

    (out / "spriteram.bin").write_bytes(words_be(g.sec("spr")))
    (out / "palette.bin").write_bytes(words_be(g.sec("pal")))
    (out / "workram.bin").write_bytes(words_be(g.sec("wram")))
    vram = g.sec("vram")
    for p in range(16):
        (out / f"vram_direct_page{p:02d}.bin").write_bytes(words_be(vram[4096 * p: 4096 * (p + 1)]))

    from PIL import Image
    if a.reference:
        Image.open(a.reference).convert("RGB").save(out / "reference.png")
    else:
        Image.new("RGB", (288, 224)).save(out / "reference.png")
    (out / "manifest.txt").write_text(f"set {a.set}\nframe 0\nscreen 288x224\nfrom save state {a.ss}\n")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
