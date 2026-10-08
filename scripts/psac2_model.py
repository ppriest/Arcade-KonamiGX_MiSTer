#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Type 3 K053936 (PSAC2) layer, from MAME's code, against MAME's screen.

    python scripts/psac2_model.py <dump-dir> <n> [--swap 0|1] [--png out.png]

<dump-dir> holds scripts/mame/psac_dump.lua's files for dump n: the
registers (0xe00000), line control (0xe60000), both palettes, the bank, and
the snapshot of both screens. The layer is drawn as konamigx_v.cpp and
k053936.cpp draw it for soccerss:

  K053936_zoom_draw, line mode (ctrl[7] & 0x40), K053936_set_offset(0, -30, +1),
  wraparound: for bitmap row y the line is linectrl[4 * ((y - 1) & 0x1ff)]
  startx = 256 * s16(line[0] + ctrl[0]) + 30 * incxx (incxx = s16(line[2]),
  times 256 if ctrl[6] bit 15), the same for y with line[1], line[3] and
  ctrl[6] bit 7; column x of the layer reads the map pixel
  ((startx + x * incxx) << 5 >> 16) & 4095, likewise y.

  get_gx_psac3_tile_info: a 256 x 256 map of 16 x 16 tiles in column order,
  two bytes a tile (gfx4, + 0x20000 when type3_bank_w bit 4 is set): tile =
  b0 | (b1 & 0x0f) << 8, colour (b1 >> 6), flip y b1 & 0x20, flip x b1 & 0x10.
  gfx3 is 8 bpp, a tile 256 bytes stored by column (bglayout_8bpp: x steps
  16 bytes, y one): byte x * 16 + y. The pen is 0x1000 + colour * 256 +
  pixel; pixel 0 is not drawn.

  gx_draw_basic_extended_tilemaps_2: the layer is drawn at half the screen's
  576 columns, each pixel doubled.

MAME's ctrl and linectrl are 16-bit views of 32-bit RAM: on a little-endian
host index n is the CPU's word n ^ 1. --swap 1 reads them so (MAME), --swap
0 in the CPU's order.

Result (dumps at 40 s, attract): on the main monitor's frames every layer
pixel not under a sprite, a tile or the side panels matches MAME's screen
(76.6% of the layer's pixels; --swap 0 or the tile read by row give under
5%). On the sub monitor's frames MAME's picture matches at alternate
columns only (37%; shifting by one column matches the other half), as if
that screen's layer were not doubled. The board makes both monitors' frames
with one pipeline, so the main monitor's is taken as the reference.
"""
import argparse
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[1]


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


def words(b):
    return [b[i] << 8 | b[i + 1] for i in range(0, len(b), 2)]


def roms():
    z = zipfile.ZipFile(REPO / "roms" / "soccerss.zip")
    return z.read("427a18.145"), z.read("427a17.24c")


def palette(raw):
    """xBBBBBGGGGGRRRRR a word, as set_color_555 (0, 5, 10) and pal5bit."""
    w = words(raw)
    out = np.zeros((len(w), 3), np.uint8)
    for i, c in enumerate(w):
        for k, sh in enumerate((0, 5, 10)):
            v = c >> sh & 31
            out[i, k] = v << 3 | v >> 2
    return out


def layer(ctrl_raw, line_raw, bank, swap, rows=range(16, 240), cols=288):
    gfx3, gfx4 = roms()
    cw, lw = words(ctrl_raw), words(line_raw)
    x = 1 if swap else 0
    ctrl = [cw[i ^ x] for i in range(16)]
    line = [lw[i ^ x] for i in range(len(lw))]
    if not ctrl[7] & 0x40:
        raise SystemExit(f"ctrl[7] = {ctrl[7]:04x}: simple mode, not modelled")
    mbase = 0x20000 if bank & 0x10 else 0
    out = {}
    for y in rows:
        la = 4 * ((y - 1) & 0x1ff)
        ixx, ixy = s16(line[la + 2]), s16(line[la + 3])
        if ctrl[6] & 0x8000:
            ixx *= 256
        if ctrl[6] & 0x0080:
            ixy *= 256
        sx = 256 * s16(line[la] + ctrl[0]) + 30 * ixx
        sy = 256 * s16(line[la + 1] + ctrl[1]) + 30 * ixy
        r = np.zeros(cols, np.uint16)
        for c in range(cols):
            px = ((((sx + c * ixx) & 0xffffffff) << 5) >> 16) & 4095
            py = ((((sy + c * ixy) & 0xffffffff) << 5) >> 16) & 4095
            t = (px >> 4) * 256 + (py >> 4)
            b0, b1 = gfx4[mbase + 2 * t], gfx4[mbase + 2 * t + 1]
            code = b0 | (b1 & 0x0f) << 8
            fx, fy = px & 15, py & 15
            if b1 & 0x10:
                fx ^= 15
            if b1 & 0x20:
                fy ^= 15
            pix = gfx3[code * 256 + fx * 16 + fy]
            r[c] = 0x1000 + (b1 >> 6) * 256 + pix if pix else 0
        out[y] = r
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("n", type=int)
    ap.add_argument("--swap", type=int, default=1)
    ap.add_argument("--png")
    a = ap.parse_args()
    d = Path(a.dir)
    p = f"d{a.n}_"
    bank = int((d / f"{p}info.txt").read_text().split()[1], 16)
    lay = layer((d / f"{p}ctrl.bin").read_bytes(), (d / f"{p}line.bin").read_bytes(), bank, a.swap)
    shot = np.asarray(Image.open(d / f"{p}screen.png").convert("RGB"))
    # each monitor against its own palette; MAME's palette is 16384 entries,
    # and each screen update reloads 0-8191 from that monitor's RAM
    for name, x0, pal_file in (("left", 0, "palm"), ("right", 580, "pals")):
        pal = palette((d / f"{p}{pal_file}.bin").read_bytes())
        drawn = same = 0
        img = np.zeros((224, 576, 3), np.uint8)
        for y, r in lay.items():
            for xx in range(576):
                v = r[xx // 2]
                if not v:
                    continue
                c = pal[v & 0x1fff]
                img[y - 16, xx] = c
                drawn += 1
                same += bool((shot[y - 16, x0 + xx] == c).all())
        print(f"{name}: {same} of {drawn} drawn layer pixels match MAME's screen")
        if a.png:
            Image.fromarray(img).save(a.png.replace(".png", f"_{name}.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
