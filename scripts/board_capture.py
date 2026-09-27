#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A capture from the board, in scripts/mame/capture.lua's layout.

    python scripts/board_capture.py tkmmpzdm sel --vram-from tkmmpzdm-play2200

Reads, over JTAG (scripts/memdump.py, an instrumented build running):
  * the video chips' registers from gx_main's register copy at 0xe00000,
    which keeps every write to them as capture.lua's write tap does
  * sprite RAM, palette and work RAM, which the CPU can read

and writes debug/<set>-board-<name>/ with the same reg_*.bin, spriteram.bin,
palette.bin and workram.bin as a MAME capture. The tilemap VRAM is banked
behind an 8 KB window, so it (and manifest.txt, reference.png) is copied
from the MAME capture named by --vram-from: the video benches then render
the board's registers, sprites and palette over MAME's tilemaps.

Run it with nothing compiling (JTAG, WORKFLOW).
"""
import argparse
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import memdump  # noqa: E402

# (file, first byte address, last byte address, first word in the copy);
# gx_main.sv's table
RANGES = [
    ("k056832",  0xd40000, 0xd4003f, 0x000),
    ("tilebank", 0xd44000, 0xd4400f, 0x020),
    ("k053246",  0xd48000, 0xd48007, 0x028),
    ("k055673",  0xd4a010, 0xd4a01f, 0x02c),
    ("k053252",  0xd4c000, 0xd4c01f, 0x034),
    ("k055555",  0xd50000, 0xd500ff, 0x044),
    ("k054338",  0xd80000, 0xd8001f, 0x0c4),
]
WORDS = 0xd8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("name")
    ap.add_argument("--vram-from", required=True, help="a MAME capture under debug/ for the tilemaps")
    a = ap.parse_args()

    src = REPO / "debug" / a.vram_from
    out = REPO / "debug" / f"{a.set}-board-{a.name}"
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out)

    regs = memdump.dump(0xe00000, 2 * WORDS)
    for name, lo, hi, w0 in RANGES:
        n = hi - lo + 1
        (out / f"reg_{name}.bin").write_bytes(regs[2 * w0: 2 * w0 + n])
    # the write ports: d56000-d56003 and d58000-d58003 of a 0x2004-byte image
    wr = bytearray(0x2004)
    wr[0:4] = regs[2 * 0xd4: 2 * 0xd4 + 4]
    wr[0x2000:0x2004] = regs[2 * 0xd6: 2 * 0xd6 + 4]
    (out / "reg_wrport.bin").write_bytes(bytes(wr))

    (out / "spriteram.bin").write_bytes(memdump.dump(0xd20000, 0x4000))
    (out / "palette.bin").write_bytes(memdump.dump(0xd90000, 0x8000))
    (out / "workram.bin").write_bytes(memdump.dump(0xc00000, 0x20000))
    with open(out / "manifest.txt", "a") as f:
        f.write(f"board registers, sprites, palette, work RAM; tilemaps from {a.vram_from}\n")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
