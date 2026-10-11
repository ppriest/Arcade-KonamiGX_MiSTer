#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Racin' Force's terrain (Type 1: K053936 + 056540 "PSAC4"), transcribed from
MAME's type1_draw_terrain (konamigx_v.cpp) and the K053936's line mode
(k053936.cpp zoom_draw_common), for the RTL to be checked against.

    python scripts/t1_psac4_model.py debug/racinfrc-t1dump f03600 [--png out.png]

Reads a vblank's state dumped by scripts/mame/t1_dump.lua and produces the
terrain: per screen pixel, the pen (12 bits: CROM colour | lookup << 8) and
the LRAM parameter (the priority), or nothing. --png composes it through the
main palette over black, for a look; --cmp scores it against MAME's picture
where the two agree (sprites and text cover parts of MAME's).

MAME calls this renderer an approximation (docs/TYPE1.md, "The renderer").
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
REPO = Path(__file__).resolve().parent.parent

VIS_X0, VIS_W = 32, 384


def window(st):
    """The shown bitmap rows: (first, count). Racin' Force 255 from 0, golf
    224 from 16 (the K053252's offsets)."""
    return (16, 224) if st["golf"] else (0, 255)


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


def s8(v):
    v &= 0xff
    return v - 0x100 if v & 0x80 else v


# ---- gfx: t1_charlayout6 (konamigx.cpp), 16x16, 6 planes, 192 bytes a tile
PLANES = (16, 20, 8, 12, 0, 4)
XOFF = (3, 2, 1, 0, 27, 26, 25, 24, 51, 50, 49, 48, 75, 74, 73, 72)


def decode6(rom):
    """Every tile's 16x16 pixels (6 bits), as MAME's gfx decode reads them:
    bit b of the tile is byte b // 8, mask 0x80 >> b % 8; plane 0 is the MSB."""
    n = len(rom) // 192
    t = np.frombuffer(rom[:n * 192], dtype=np.uint8).reshape(n, 16, 12)
    bits = np.unpackbits(t, axis=2)                          # n, 16 rows, 96 bits (MSB first)
    pix = np.zeros((n, 16, 16), dtype=np.uint8)
    for i, p in enumerate(PLANES):
        for x, xo in enumerate(XOFF):
            pix[:, :, x] |= bits[:, :, p + xo] << (5 - i)
    return pix


# t1_charlayout8 (golf's CROM): 8 planes, 256 bytes a tile
PLANES8 = (24, 28, 16, 20, 8, 12, 0, 4)
XOFF8 = (3, 2, 1, 0, 35, 34, 33, 32, 67, 66, 65, 64, 99, 98, 97, 96)


def decode8(rom):
    n = len(rom) // 256
    t = np.frombuffer(rom[:n * 256], dtype=np.uint8).reshape(n, 16, 16)
    bits = np.unpackbits(t, axis=2)
    pix = np.zeros((n, 16, 16), dtype=np.uint8)
    for i, p in enumerate(PLANES8):
        for x, xo in enumerate(XOFF8):
            pix[:, :, x] |= bits[:, :, p + xo] << (7 - i)
    return pix


def load(dump, tag):
    d = Path(dump)
    rd = lambda n, dt: np.frombuffer((d / f"{tag}_{n}.bin").read_bytes(), dtype=dt).astype(np.int64)
    st = {
        "psacram": rd("psacram", "<u4"),
        "lram": rd("lram", "<u4"),
        "p4": rd("p4", "<u4"),
        "k936": rd("k936", "<u2"),
        "linectl": rd("linectl", "<u2"),
        "lookup": rd("lookup", "u1"),
    }
    meta = dict(l.split(None, 1) for l in (d / f"{tag}_meta.txt").read_text().splitlines())
    st["bank"] = int(meta["bank"], 16)
    org = lambda k: None if meta.get(k, "none").strip() == "none" else int(meta[k], 16)
    st["yorigin"], st["yorigin1"] = org("yorigin"), org("yorigin1")
    st["golf"] = meta.get("golf", "0").strip() == "1"
    return st


def roz_rows(st, rows, tiles_c, tiles_h):
    """The K053936 line mode drawn into the two 512x512 bitmaps (rows `rows`):
    colour pen (PL << 6 | pixel; golf's 8 bpp, PL << 8 | pixel) and height
    pen (byte << 6 | pixel)."""
    ctrl, lc, ram = [int(v) for v in st["k936"]], [int(v) for v in st["linectl"]], st["psacram"]
    x = np.arange(512, dtype=np.int64)
    col = np.zeros((512, 512), dtype=np.uint16)
    hgt = np.zeros((512, 512), dtype=np.uint16)
    for y in rows:
        la = 4 * (y & 0x1ff)                                  # offsets 0: yoff = 0
        startx = (256 * s16(lc[la] + ctrl[0])) & 0xffffffff
        starty = (256 * s16(lc[la + 1] + ctrl[1])) & 0xffffffff
        incxx, incxy = s16(lc[la + 2]), s16(lc[la + 3])
        if ctrl[6] & 0x8000:
            incxx *= 256
        if ctrl[6] & 0x0080:
            incxy *= 256
        # draw_roz (wrap): pixel ((start << 5) + x * (inc << 5)) >> 16, 2048-pixel map
        cx = (((startx << 5) + x * (incxx << 5)) & 0xffffffff) >> 16 & 0x7ff
        cy = (((starty << 5) + x * (incxy << 5)) & 0xffffffff) >> 16 & 0x7ff
        ti = (cy >> 4) * 128 + (cx >> 4)                      # TILEMAP_SCAN_ROWS, 128x128
        a, b = ram[2 * ti], ram[2 * ti + 1]
        px, py = cx & 15, cy & 15
        # tilemap B, colour: gfx 0 (CROM), code b[14:0], colour b[19:18], flips b[21], b[20]
        fx, fy = (b >> 21) & 1, (b >> 20) & 1
        cpx = np.where(fx, 15 - px, px); cpy = np.where(fy, 15 - py, py)
        code = (b & 0x7fff) % len(tiles_c)
        col[y] = (((b >> 18) & 3) << (8 if st["golf"] else 6)) | tiles_c[code, cpy, cpx]
        # tilemap A, height: gfx 1 (HROM), code a[14:0], colour a[23:16], flips b[23], b[22]
        fx, fy = (b >> 23) & 1, (b >> 22) & 1
        hpx = np.where(fx, 15 - px, px); hpy = np.where(fy, 15 - py, py)
        code = (a & 0x7fff) % len(tiles_h)
        hgt[y] = (((a >> 16) & 0xff) << 6) | tiles_h[code, hpy, hpx]
    return col, hgt


def render(st, tiles_c, tiles_h):
    """type1_draw_terrain: pen (0xffff = nothing) and parameter, 512x512 by
    screen-bitmap (y, x)."""
    pen = np.full((512, 512), 0xffff, dtype=np.uint16)
    par = np.zeros((512, 512), dtype=np.uint8)
    golf = st["golf"]
    y0, vh = window(st)
    max_y = y0 + vh - 1
    nl = 480 if golf else 255
    if not (st["k936"][7] & 0x20):
        return pen, par
    col, hgt = roz_rows(st, range(1 + 14, nl + 14 + 1), tiles_c, tiles_h)
    limit = np.full(512, max_y + 1, dtype=np.int64)
    for line in range(1, nl + 1):
        e = int(st["lram"][line])
        p = (e >> 8) & 0xff
        if p == 0xff:
            continue
        # golf: lines past 224 are the second table range, with its own origin
        org = st["yorigin1"] if golf and line > 224 else st["yorigin"]
        if org is None:
            continue
        ground = 256 + org - line - s8(e)
        scale = e >> 16
        lk = int(st["lookup"][((st["bank"] >> 12) << 7) | (p >> 1)]) >> (0 if p & 1 else 4)
        c = col[line + 14].astype(np.int64)
        h = hgt[line + 14].astype(np.int64)
        on = (c & (0xff if golf else 0x3f)) != 0
        level = ((h & 0x3f) + (h >> 6)) & 0xff
        # C's '/' truncates toward zero: level * scale is never negative
        top = np.maximum(ground - (level * scale) // (256 if golf else 64), 0)
        pv = (c & 0xff) | ((lk & 0xf) << 8)
        if scale == 0:
            if 0 <= ground <= max_y:
                pen[ground, on] = pv[on]
                par[ground, on] = p
            continue
        for xx in np.nonzero(on)[0]:
            t, lim = top[xx], limit[xx]
            if t < lim:
                pen[t:lim, xx] = pv[xx]
                par[t:lim, xx] = p
            limit[xx] = min(lim, t)
    return pen, par


def palette_rgb(pal_bytes):
    """The main palette (0xd90000), 888: x, R, G, B a long."""
    p = np.frombuffer(pal_bytes, dtype=">u4")
    return np.stack([(p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff], axis=-1).astype(np.uint8)


def roms(set_name="racinfrc"):
    import contextlib, io
    import build_rom_image as bri
    with contextlib.redirect_stdout(io.StringIO()):
        g3, g4 = bri.build(set_name, "gfx3"), bri.build(set_name, "gfx4")
    return (decode8(g3) if set_name != "racinfrc" and set_name != "racinfrcu" else decode6(g3)), decode6(g4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("tag")
    ap.add_argument("--png")
    a = ap.parse_args()
    st = load(a.dump, a.tag)
    tc, th = roms("opengolf" if st["golf"] else "racinfrc")
    pen, par = render(st, tc, th)
    y0, vh = window(st)
    vis = pen[y0:y0 + vh, VIS_X0:VIS_X0 + VIS_W]
    n = int((vis != 0xffff).sum())
    print(f"{a.tag}: yorigin {st['yorigin']} {st['yorigin1']}, bank {st['bank']:04x}, k936[7] {st['k936'][7]:04x}: "
          f"{n} of {VIS_W * vh} visible pixels drawn, {len(set(par[y0:y0 + vh, VIS_X0:VIS_X0 + VIS_W][vis != 0xffff].tolist()))} parameters")
    from PIL import Image
    pal = palette_rgb((Path(a.dump) / f"{a.tag}_pal.bin").read_bytes())
    on = vis != 0xffff
    img = np.zeros((vh, VIS_W, 3), dtype=np.uint8)
    img[on] = pal[vis[on] & 0x7ff]
    ref = np.array(Image.open(Path(a.dump) / f"{a.tag}_ref.png").convert("RGB"))
    same = int((np.all(img == ref, axis=-1) & on).sum())
    print(f"  against MAME's picture: {same} of {n} drawn pixels identical ({100 * same / max(n, 1):.1f}%)")
    if a.png:
        Image.fromarray(img).save(a.png)


if __name__ == "__main__":
    main()
