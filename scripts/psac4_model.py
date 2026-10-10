#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Type 4 K053936 (PSAC2) layer, from MAME's code, against MAME's screen.

    python scripts/psac4_model.py <dump-dir> <n> [--set rungun2] [--png out.png]

<dump-dir> holds scripts/mame/psac_dump.lua's files (T3_T4=1) for dump n:
registers, line control, the map RAM at 0xf00000, both 32 KB palettes, and
the snapshot of both screens. The layer as konamigx_v.cpp and k053936.cpp
draw it on the Type 4 boards:

  K053936GP_zoom_draw, K053936GP_set_offset(0, -36, my): copyroz32clip
  writes each row one below the row it computed, so bitmap row y is
  computed for y - oy, oy = my + 1 (OFFS_Y: rungun2's -1 gives 0,
  rushhero's +1 gives 2; against MAME's screens, 53-60% of the layer's
  pixels match, the rest under sprites and text, and oy one either side
  under 20%).
  Super mode (ctrl[7] & 0x40): the line is linectrl[4 * ((y - oy) & 0x1ff)],
  startx = 256 * s16(line[0] + ctrl[0]) + 36 * incxx (incxx = s16(line[2]),
  times 256 if ctrl[6] bit 15), likewise y. Simple mode: startx =
  256 * s16(ctrl[0]) + 36 * incxx + (y - oy) * incyx, incyx = s16(ctrl[2]),
  incyy ctrl[3] (times 256 if ctrl[6] bit 14), incxx ctrl[4], incxy ctrl[5]
  (times 256 if ctrl[6] bit 6), likewise y. Column x reads map pixel
  srcx = ((startx + x * incxx) << 5 >> 16) & 0x1fff, srcy likewise, at
  offset srcy * 2048 + srcx of the 2048 x 2048 pixmap -- skipped if past its
  end, so an srcx over 2047 reads the next rows' start (MAME's arithmetic).

  get_gx_psac_tile_info: 128 x 128 tiles in column order (TILEMAP_SCAN_COLS,
  index = column * 128 + row), a word a tile in the CPU's order: tile bits
  12:0, colour bit 13, flip x 14, flip y 15 (m_psac_colorbase stays 0: the
  Type 4 video starts leave m_gx_rozenable 0). gfx3 as Type 3's, 8 bpp, a
  tile stored by column. The pen is 0x1800 + colour * 256 + pixel; pixel 0
  is not drawn.

MAME's ctrl and linectrl are 16-bit views of 32-bit RAM: index n is the
CPU's word n ^ 1.
"""
import argparse
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
OFFS_Y = {"rungun2": 0, "slamdnk2": 0, "rushhero": 2,
          **{k: 1 for k in ("vsnetscr", "vsnetscreb", "vsnetscru", "vsnetscra", "vsnetscrj")}}
GFX3 = {"rungun2": ("rungun2.zip", "505a24.22h"), "slamdnk2": ("rungun2.zip", "505a24.22h"),
        "rushhero": ("rushhero.zip", "605a24.22h"),
        **{k: ("vsnetscr.zip", "627a24.22h") for k in ("vsnetscr", "vsnetscreb", "vsnetscru", "vsnetscra", "vsnetscrj")}}


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


def words(b):
    return [b[i] << 8 | b[i + 1] for i in range(0, len(b), 2)]


def gfx3(setname):
    z, f = GFX3.get(setname, GFX3["rungun2"])
    return zipfile.ZipFile(REPO / "roms" / z).read(f)


def palette(raw):
    """xRGB 888 a long (palformat 0)."""
    a = np.frombuffer(raw, np.uint8).reshape(-1, 4)
    return a[:, 1:4].copy()


# Versus Net Soccer's screen is 576 wide: MAME draws the layer with
# pixeldouble_output, 288 columns each doubled, at GP offset x -30
DBL = ("vsnetscr", "vsnetscreb", "vsnetscru", "vsnetscra", "vsnetscrj")


# The map wraps (each coordinate modulo 2048) for these: their crowd repeats
# round the field, where MAME, which does not wrap here, draws it once
WRAP = ("rushhero",) + DBL


def layer(ctrl_raw, line_raw, map_raw, setname, rows=range(16, 240), cols=None, oy=None, ox=None, wrap=None):
    g3 = gfx3(setname)
    oy = OFFS_Y[setname] if oy is None else oy
    cols = cols or (288 if setname in DBL else 384)
    ox = (30 if setname in DBL else 36) if ox is None else ox
    wrap = (setname in WRAP) if wrap is None else wrap
    cw, lw, mw = words(ctrl_raw), words(line_raw), words(map_raw)
    ctrl = [cw[i ^ 1] for i in range(16)]
    line = [lw[i ^ 1] for i in range(len(lw))]
    out = {}
    for y in rows:
        if ctrl[7] & 0x40:
            la = 4 * ((y - oy) & 0x1ff)
            ixx, ixy = s16(line[la + 2]), s16(line[la + 3])
            if ctrl[6] & 0x8000:
                ixx *= 256
            if ctrl[6] & 0x0080:
                ixy *= 256
            sx = 256 * s16(line[la] + ctrl[0]) + ox * ixx
            sy = 256 * s16(line[la + 1] + ctrl[1]) + ox * ixy
        else:
            iyx, iyy, ixx, ixy = (s16(ctrl[k]) for k in (2, 3, 4, 5))
            if ctrl[6] & 0x4000:
                iyx, iyy = iyx * 256, iyy * 256
            if ctrl[6] & 0x0040:
                ixx, ixy = ixx * 256, ixy * 256
            sx = 256 * s16(ctrl[0]) + ox * ixx + (y - oy) * iyx
            sy = 256 * s16(ctrl[1]) + ox * ixy + (y - oy) * iyy
        r = np.zeros(cols, np.uint16)
        for c in range(cols):
            px = ((((sx + c * ixx) << 5) & 0xffffffff) >> 16) & 0x1fff
            py = ((((sy + c * ixy) << 5) & 0xffffffff) >> 16) & 0x1fff
            if wrap:
                px, py = px & 2047, py & 2047
            else:
                offs = py * 2048 + px
                if offs >= 2048 * 2048:
                    continue
                px, py = offs & 2047, offs >> 11
            e = mw[(px >> 4) * 128 + (py >> 4)]
            fx, fy = px & 15, py & 15
            if e & 0x4000:
                fx ^= 15
            if e & 0x8000:
                fy ^= 15
            pix = g3[(e & 0x1fff) * 256 + fx * 16 + fy]
            r[c] = 0x1800 + ((e >> 13) & 1) * 256 + pix if pix else 0
        out[y] = r
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("n", type=int)
    ap.add_argument("--set", default="rungun2")
    ap.add_argument("--png")
    ap.add_argument("--n2", type=int, help="compare with this dump's screen and palettes (another frame's)")
    a = ap.parse_args()
    d = Path(a.dir)
    p = f"d{a.n}_"
    lay = layer((d / f"{p}ctrl.bin").read_bytes(), (d / f"{p}line.bin").read_bytes(),
                (d / f"{p}map.bin").read_bytes(), a.set)
    shot = np.asarray(Image.open(d / f"{p}screen.png").convert("RGB"))
    dbl = a.set in DBL
    w = 576 if dbl else 384
    # MAME's snapshot of both screens: the second starts at column 389 (775
    # wide), or 580 for the 576-wide sets (1156)
    for name, x0, pal_file in (("left", 0, "palm"), ("right", 580 if dbl else 389, "pals")):
        pal = palette((d / f"{p}{pal_file}.bin").read_bytes())
        drawn = same = 0
        img = np.zeros((224, w, 3), np.uint8)
        for y, r in lay.items():
            for x in range(w):
                v = r[x // 2] if dbl else r[x]
                if not v:
                    continue
                c = pal[v & 0x1fff]
                img[y - 16, x] = c
                drawn += 1
                same += bool((shot[y - 16, x0 + x] == c).all())
        print(f"{name}: {drawn} layer pixels, {same} match MAME's screen ({100 * same / max(drawn, 1):.1f}%)")
        if a.png:
            Image.fromarray(img).save(a.png.replace(".png", f"_{name}.png"))


if __name__ == "__main__":
    main()
