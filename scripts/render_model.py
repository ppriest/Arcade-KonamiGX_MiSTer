#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A software model of Konami GX video, checked against MAME captures.

    python scripts/render_model.py daiskiss-title            # model vs reference.png
    python scripts/render_model.py daiskiss-title --stage bg # one stage only

Reads a capture written by scripts/mame_capture.py (debug/<set>-<name>/) and
renders it the way konamigx_v.cpp does, then compares against MAME's own
screenshot of the same frame. Phase 1 of docs/ROADMAP.md: the model is made
pixel-exact against MAME FIRST, and the RTL is then checked against the model,
layer by layer. That ordering matters more here than on the sibling cores:
three of the four vendored video chip modules arrived with no upstream bench,
so this model is their regression.

BUILT IN STAGES, each checked before the next is started:

  bg      the background fill -- K054338 solid colour, or the K055555
          gradient (konamigx_mixer, fill_backcolor). Written, NOT VERIFIED:
          the only captured frame that shows it (daiskiss 300) shows it
          black, so a wrong fill would pass.
  tiles   K056832 tilemaps A-D, plain X/Y scroll, 5 bpp, no screen flip.
  sprites K053246/K055673 solid objects, z-buffered against each other.
          Scored as: of the pixels the sprites draw, how many MAME shows
          unchanged. daiskiss title and frame 2400 are exact. Every miss on
          frames 3600, 4800 and 6000 is under an opaque tile pixel: either
          MAME shows that tile's exact colour (layer in front -- all 388 on
          frame 3600) or a blend of it (the glass bowl on 4800, spotlight
          beams on 6000). Both are the mix stage's. Shadow and alpha objects
          are counted and set aside, not drawn.
  mix     the whole frame: konamigx_mixer's object pool (layers and sprites
          in one priority sort), layer alpha, sprite shadow and highlight.
          Pixel-identical to MAME on six daiskiss frames (300, 1200, 2400,
          3600, 4800, 6000), which exercise priority, layer A alpha (4800),
          shadow (3600) and highlight (6000). Not exercised: additive blend,
          alpha sprites, brightness (VBRI), sub layers -- the last three are
          errors in the model.

WHAT A MISMATCH MEANS. Every GX set is MACHINE_IMPERFECT_GRAPHICS, so MAME's
picture is not ground truth for the hardware -- but it IS the reference this
project has chosen (docs/ROADMAP.md, "Follow MAME, including where MAME is
wrong"). The model therefore reproduces MAME, kludges included, and every
place it does so deliberately is listed in docs/MAME_KLUDGES.md.

COORDINATES. MAME draws into a 1024x1024 bitmap and shows a window of it:
set_visarea(24, 24+288-1, 16, 16+224-1) for the base GX machine. Anything
indexed by position -- the gradient is indexed by bitmap ROW -- uses bitmap
coordinates, so the top visible row is y=16, not y=0. Getting that wrong
shifts the gradient by exactly sixteen rows and still looks plausible.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent

# konamigx(): set_visarea(24, 24+288-1, 16, 16+224-1). Machine configs that
# change this (opengolf, the type 3/4 boards) are out of the first scope.
VIS_X0, VIS_Y0, VIS_W, VIS_H = 24, 16, 288, 224


class Capture:
    """Everything a capture directory holds, decoded once."""

    def __init__(self, path):
        self.path = Path(path)
        man = {}
        for line in (self.path / "manifest.txt").read_text(encoding="utf-8").splitlines():
            k, _, v = line.partition(" ")
            man[k] = v
        self.manifest = man
        self.set = man.get("set", "?")

        # Palette RAM at 0xd90000: 8192 dwords, big-endian, xRGB_888
        # (konamigx(): PALETTE(...).set_format(palette_device::xRGB_888, 8192)).
        raw = np.frombuffer((self.path / "palette.bin").read_bytes(), dtype=">u4")
        self.pal = np.stack([(raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff],
                            axis=-1).astype(np.uint8)

        self.wrport = (self.path / "reg_wrport.bin").read_bytes()
        # K055555: K055555_long_w puts even registers on byte lane 0 and odd ones
        # on lane 2 of each dword, so register N is byte 2N of the dump.
        k5 = (self.path / "reg_k055555.bin").read_bytes()
        self.k055555 = [k5[2 * n] for n in range(46)]
        k3 = (self.path / "reg_k054338.bin").read_bytes()
        self.k054338 = [int.from_bytes(k3[i:i + 2], "big") for i in range(0, 32, 2)]

    @property
    def wrport1_0(self):
        # eeprom_w, ACCESSING_BITS_24_31: byte 0 of the 0xd56000 dword
        return self.wrport[0]

    def reference(self):
        img = Image.open(self.path / "reference.png").convert("RGB")
        return np.asarray(img, dtype=np.uint8)


def stage_bg(cap):
    """konamigx_mixer's first step: fill the whole bitmap with the background.

    wrport1_0 bit 5 selects the source (eeprom_w: "0 = 338 solid color,
    1 = 5^5 gradient"). The gradient is k054338_device::fill_backcolor with
    pal_ptr = pens + (K055555 BGC CBLK << 9) and mode = K055555 BGC SET:
    bit 1 clear is a single colour, bit 1 set a gradient, and then bit 0 clear
    means one colour per ROW and set one per COLUMN -- in bitmap coordinates.
    """
    out = np.zeros((VIS_H, VIS_W, 3), dtype=np.uint8)
    if cap.wrport1_0 & 0x20:
        base = cap.k055555[0] << 9
        mode = cap.k055555[1]
        if not (mode & 0x02):
            out[:, :] = cap.pal[base]
        elif not (mode & 0x01):
            rows = cap.pal[base + VIS_Y0 + np.arange(VIS_H)]
            out[:, :] = rows[:, None, :]
        else:
            cols = cap.pal[base + VIS_X0 + np.arange(VIS_W)]
            out[:, :] = cols[None, :, :]
    else:
        # fill_solid_bg: K054338 BGC_R low byte is red, BGC_GB is green|blue
        r = cap.k054338[0] & 0xff
        g, b = cap.k054338[1] >> 8, cap.k054338[1] & 0xff
        out[:, :] = (r, g, b)
    return out


# ---------------------------------------------------------------- K056832 ---

K056832_PAGE_W, K056832_PAGE_H = 512, 256    # 64 x 32 tiles of 8 x 8


def k056832_regs(cap):
    """m_regs[i] is the big-endian word at byte 2i of 0xd40000 (word_w on a
    32-bit bus: offset = byte / 2)."""
    b = (cap.path / "reg_k056832.bin").read_bytes()
    return [int.from_bytes(b[2 * i:2 * i + 2], "big") for i in range(32)]


def k056832_pages(cap):
    """The 16 VRAM pages, each 4096 u16 (attr, code pairs).

    The capture buckets VRAM writes by the byte the CPU last wrote to
    0xd40033, the low byte of m_regs[0x19]; change_rambank() turns that into a
    page with ((bank >> 1) & 0xc) | (bank & 3). With m_regs[0] bit 1 set the
    writes go to the external-linescroll page instead -- not handled, and an
    error if the capture needs it.
    """
    pages = np.zeros((16, 4096), dtype=np.uint16)
    for f in cap.path.glob("vram_bank*.bin"):
        bank = int(f.stem[len("vram_bank"):], 16)
        page = ((bank >> 1) & 0xc) | (bank & 3)
        raw = np.frombuffer(f.read_bytes()[:0x2000], dtype=">u2")
        pages[page] = raw
    return pages


def k056832_tiles(set_name, bpp):
    """Decode the whole tile ROM to an (ntiles, 8, 8) array of pixel values.

    5 bpp is charlayout5 in k054156_k054157_k056832.cpp: 40 bytes a tile,
    5 bytes a row, plane bit offsets {32, 24, 8, 16, 0} MSB plane first, and
    MAME's bit order is MSB-first within each byte. So for row byte b0..b4,
    pixel x = b4[x]<<4 | b3[x]<<3 | b1[x]<<2 | b2[x]<<1 | b0[x].
    """
    if bpp != 5:
        raise SystemExit(f"K056832 {bpp} bpp not modelled yet")
    rom_path = REPO / "debug" / f"{set_name}-rom" / "k056832.bin"
    if not rom_path.exists():
        raise SystemExit(f"{rom_path} missing -- run scripts/build_rom_image.py "
                         f"{set_name} k056832")
    rom = np.frombuffer(rom_path.read_bytes(), dtype=np.uint8)
    n = len(rom) // 40
    rows = rom[:n * 40].reshape(n, 8, 5)
    bits = np.unpackbits(rows[..., None], axis=-1)          # (n, 8, 5, 8), MSB first
    return (bits[:, :, 4] << 4 | bits[:, :, 3] << 3 | bits[:, :, 1] << 2
            | bits[:, :, 2] << 1 | bits[:, :, 0]).astype(np.uint8)


# common_init() in konamigx_v.cpp; every konamigx_5bpp set gets these.
LAYER_OFFS = [(-2, 0), (0, 0), (2, 0), (3, 0)]


def layer_fields(cap, layer):
    """One K056832 tilemap layer before the K055555: per visible pixel, the
    tile's 6-bit colour field (after the attribute decode) and its 5-bit
    pixel. This is what rtl/video/gx_tilemap.sv outputs, and what
    scripts/check_gx_tilemap.py compares it against.

    Only plain X/Y scroll (m_regs[5] mode 3) and no screen flip are modelled;
    anything else is an error rather than a wrong picture.
    """
    r = k056832_regs(cap)
    if r[0] & 0x30:
        raise SystemExit("K056832 screen flip not modelled yet")
    if (r[5] >> (2 * layer) & 3) != 3:
        raise SystemExit(f"layer {layer}: line/row scroll not modelled yet")

    rowstart, rowspan = r[8 + layer] >> 3 & 3, (r[8 + layer] & 3) + 1
    colstart, colspan = r[12 + layer] >> 3 & 3, (r[12 + layer] & 3) + 1
    s16 = lambda v: v - 0x10000 if v & 0x8000 else v     # (int16_t)new_data
    dy = s16(r[16 + layer])
    dx = s16(r[20 + layer])
    width, height = colspan * K056832_PAGE_W, rowspan * K056832_PAGE_H

    # tilemap_draw_common: ay = (dy - offs_y) % height; the X scroll is dx plus
    # corr = -offs_x, and `sx = dx & (width - 1)`.
    offs_x, offs_y = LAYER_OFFS[layer]
    ay = (dy - offs_y) % height
    sx = (dx - offs_x) & (width - 1)

    pages = k056832_pages(cap)
    tiles = k056832_tiles(cap.set, 5)
    fbits = r[3] >> 6 & 3
    flips, palm1, pals2, palm2 = [(6, 0x3f, 0, 0x00), (4, 0x0f, 2, 0x30),
                                  (2, 0x03, 2, 0x3c), (0, 0x00, 2, 0x3f)][fbits]
    flip_en = r[1] >> (layer << 1) & 3
    tilebank = (cap.path / "reg_tilebank.bin").read_bytes()

    # Map coordinates for every visible pixel, in BITMAP coordinates.
    by = VIS_Y0 + np.arange(VIS_H)[:, None]
    bx = VIS_X0 + np.arange(VIS_W)[None, :]
    my = (by + ay) % height
    mx = (bx + sx) % width
    page = (((rowstart + my // K056832_PAGE_H) & 3) << 2) + ((colstart + mx // K056832_PAGE_W) & 3)
    tidx = ((my % K056832_PAGE_H) >> 3) * 64 + ((mx % K056832_PAGE_W) >> 3)
    attr = pages[page, tidx * 2].astype(np.int32)
    code = pages[page, tidx * 2 + 1].astype(np.int32)

    flip = (attr >> flips & 3) & flip_en
    color = (attr & palm1) | (attr >> pals2 & palm2)
    # type2_tile_callback: tile bank substitution, then K055555 vmixcolor.
    tb = np.frombuffer(tilebank[:8], dtype=np.uint8).astype(np.int32)
    code = (tb[(code & 0xe000) >> 13] << 13) + (code & 0x1fff)

    ty = my & 7
    tx = mx & 7
    ty = np.where(flip & 2, 7 - ty, ty)
    tx = np.where(flip & 1, 7 - tx, tx)
    pix = tiles[code % len(tiles), ty, tx]
    return color & 0x3f, pix


def stage_layer(cap, layer):
    """One K056832 tilemap layer, rendered alone.

    Returns (rgb, opaque): the layer's colours, and where it drew anything.
    """
    col6, pix = layer_fields(cap, layer)
    vcb = cap.k055555[23 + layer] << 6          # K55_PALBASE_A + layer
    pal = col6 | vcb        # V INMIX ON = 0xff here: all six bits internal
    # COLOUR GRANULARITY IS 16, WHATEVER THE BIT DEPTH. k054156_k054157_k056832.cpp
    # decodes the tiles with konami_decode_gfx -- which would give 32 for 5 bpp --
    # and then immediately overrides it: gfx(gfx_index)->set_granularity(16).
    # So a 5 bpp pixel's upper half spills into the next colour, and a layer's
    # bank lands at PAL << 6 colours x 16 = PAL * 1024 pens, which is what
    # furrtek's K055555 notes say too ("Palette RAM bank (0~7)*1024"). Modelled
    # at 32 first, and the pens came out exactly 0x800 too high on layer C.
    pen = pal * 16 + pix
    rgb = cap.pal[pen]
    return rgb, pix != 0


def stage_tiles(cap):
    """The four layers over the background, in fixed A-B-C-D order.

    THE PICTURE THIS RETURNS IS ILLUSTRATIVE ONLY. Which layer is in front is
    the K055555's decision, and the mixer is not modelled yet, so the composite
    is not expected to match MAME and its whole-frame score means nothing. The
    tile stage is SCORED per layer instead, by score_layers() -- see main().
    """
    out = stage_bg(cap)
    for layer in range(4):
        rgb, opaque = stage_layer(cap, layer)
        out[opaque] = rgb[opaque]
    return out


def score_layers(cap, ref, src):
    """Per layer: of the reference pixels only that layer can have drawn, how
    many does the model's rendering of that layer, alone, reproduce?

    This is the tile stage's real test. It needs no mixer -- it asks only
    whether the layer is right where MAME shows it -- and a miss is a genuine
    fault or a genuine unmodelled effect, never a covered pixel. Its blind
    spot is the other direction: it cannot see a layer drawn wrongly where
    something else covers it in MAME.
    """
    rows = []
    for layer, name in enumerate("ABCD"):
        mine = src == name
        if not mine.any():
            continue
        rgb, _ = stage_layer(cap, layer)
        ok = int((np.all(rgb == ref, axis=-1) & mine).sum())
        rows.append((name, ok, int(mine.sum())))
    return rows


# ------------------------------------------------------ K053246 / K055673 ---

# Per machine config: K055673 set_config(layout, dx, dy) and the mixer primode
# the video start selects. Only what the in-scope 5 bpp sets need so far.
SPRITE_CFG = {
    "daiskiss": dict(dx=-26, dy=-23, primode=4),   # konamigx(); konamigx_5bpp: primode 4
    "gokuparo": dict(dx=-46, dy=-23, primode=0),
    "fantjour": dict(dx=-46, dy=-23, primode=0),
    "fantjoura": dict(dx=-46, dy=-23, primode=0),
    "crzcross": dict(dx=-46, dy=-23, primode=5),
    "puzldama": dict(dx=-46, dy=-23, primode=5),
    "tbyahhoo": dict(dx=-26, dy=-23, primode=0),   # konamigx() base config; tilemode 1
    "mtwinbee": dict(dx=-26, dy=-23, primode=0),
    "sexyparo": dict(dx=-42, dy=-23, primode=0),   # sexyparo(): -42
    "sexyparoa": dict(dx=-42, dy=-23, primode=0),
}


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def k055673_sprites(set_name):
    """The sprite graphics, (n, 16, 16), assembled and decoded as MAME does.

    K055673_LAYOUT_GX in k053246_k053247_k055673.cpp builds a 5 bpp image at
    start-up: size4 = (region / 0x100000) / 5 * 0x400000, then for every 4
    bytes of the 4 bpp area it emits those 4 bytes plus 1 from the 1 bpp area
    at size4. That is then decoded with the GX spritelayout: 16 x 16, 160
    bytes a sprite, 10 bytes a row with pixels 0-7 in bytes 0-4 and 8-15 in
    bytes 5-9, plane bit offsets {32, 24, 16, 8, 0} -- NOT the tiles'
    {32, 24, 8, 16, 0}; the two orders are easy to copy across by mistake.
    """
    rom_path = REPO / "debug" / f"{set_name}-rom" / "k055673.bin"
    if not rom_path.exists():
        raise SystemExit(f"{rom_path} missing -- run scripts/build_rom_image.py "
                         f"{set_name} k055673")
    rom = np.frombuffer(rom_path.read_bytes(), dtype=np.uint8)
    size4 = (len(rom) // 0x100000) // 5 * 0x400000
    four = rom[:size4].reshape(-1, 4)
    one = rom[size4:size4 + size4 // 4].reshape(-1, 1)
    comb = np.concatenate([four, one], axis=1).reshape(-1)       # 5 bytes per 4
    n = size4 // 128
    groups = comb[:n * 160].reshape(n, 16, 2, 5)                 # row, half, byte
    bits = np.unpackbits(groups[..., None], axis=-1)             # (n,16,2,5,8)
    pix = (bits[:, :, :, 4] << 4 | bits[:, :, :, 3] << 3 | bits[:, :, :, 2] << 2
           | bits[:, :, :, 1] << 1 | bits[:, :, :, 0])           # (n,16,2,8)
    return pix.reshape(n, 16, 16).astype(np.uint8)


class SpriteRegs:
    """konamigx_precache_registers(), plus what the callbacks read."""

    def __init__(self, cap):
        k46 = (cap.path / "reg_k053246.bin").read_bytes()
        k47b = (cap.path / "reg_k055673.bin").read_bytes()
        self.kx46 = list(k46[:8])                                # k053246_w: bytes
        self.kx47 = [int.from_bytes(k47b[2 * i:2 * i + 2], "big") for i in range(8)]
        self.wrport2 = cap.wrport[0x2001]                        # control_w: byte 1 of 0xd58000
        i = self.kx47[4]
        self.vrcbk = [(i & 0xf) << 14, (i & 0xf00) << 6]
        i = self.kx47[5]
        self.vrcbk += [(i & 0xf) << 14, (i & 0xf00) << 6]
        self.opset = self.kx47[6]
        j = min(self.opset & 7, 4)
        self.coreg = ((self.kx47[6] >> 8 & 0xf) & [0xf, 0xe, 0xc, 0x8, 0x0][j]) << 12
        self.coregshift = [4, 5, 6, 7, 8][j]
        k5 = cap.k055555
        self.opri, self.oinprion, self.ocblk = k5[15], k5[19], k5[27]

    def combine_c18(self, attrib):
        c18 = (attrib & 0xff) << self.coregshift | self.coreg
        if self.wrport2 & 4:
            c18 &= 0x3fff
        elif not (self.wrport2 & 8):
            c18 = (c18 & 0x3fff) | (attrib << 6 & 0xc000)
        return c18

    def objcolor(self, c18):
        opon = self.oinprion << 8 | 0xff
        ocb = ((self.ocblk & 7) << 10) & ~opon
        return (ocb | (c18 & opon)) >> self.coregshift

    def inpri(self, c18):
        return (c18 >> 8) & ~self.oinprion | (self.opri & self.oinprion)

    def type2_callback(self, code, color):
        code = self.vrcbk[code >> 14] | (code & 0x3fff)
        c18 = self.combine_c18(color)
        return code, self.objcolor(c18), self.inpri(c18)


XOFFSET = [0, 1, 4, 5, 16, 17, 20, 21]
YOFFSET = [0, 2, 8, 10, 32, 34, 40, 42]


def mixer_shadow_setup(cap, layerpri_abcd):
    """konamigx_mixer's shadow enables and spri_min, before any object is added.

    shadowon[i] is set when any of K054338 shadow set i's three deltas is
    outside +/-7 -- SHD_PRI_SEL is read and then overwritten, so it has no
    effect. (MAME tests the deltas the PREVIOUS frame exported; the capture
    has one frame's registers, so a frame that changes them is out by one
    here.) spri_min is the highest priority of a layer SHD_ON leaves
    unshadowed; primodes 4 and 5 lift every shadow's priority to at least it.
    """
    shadowon = [any(v < -7 or v > 7 for v in k054338_shadow_deltas(cap, i))
                for i in range(3)]
    shd_on = cap.k055555[40]
    spri_min = 0
    for i in range(4):
        if not (shd_on >> i & 1) and spri_min < layerpri_abcd[i]:
            spri_min = layerpri_abcd[i]
    return shadowon, spri_min


def k054338_shadow_deltas(cap, i):
    """update_all_shadows: shadow set i's R, G, B deltas, 9-bit signed."""
    d = [cap.k054338[2 + 3 * i + c] & 0x1ff for c in range(3)]
    return [v - 0x200 if v >= 0x100 else v for v in d]


def sprite_objects(cap, sr, primode, shadowon=(False, False, False), spri_min=0):
    """konamigx_mixer's sprite loop: the sprite part of the object pool.

    Returns ([(order, offs, code, color)], skipped, spriteram). Solid objects
    carry drawmode 0/1 in order bits 4-7; shadow objects 4/5, plus the shadow
    code in bits 0-1, exactly as MAME packs them. Alpha-tagged solids
    (drawmode 2/3) cannot occur with type2_sprite_callback, whose colour has
    nothing above bit 15, so one is an error rather than a guess.
    """
    spr = np.frombuffer((cap.path / "spriteram.bin").read_bytes(), dtype=">u2").astype(np.int64)
    pool, skipped = [], {"shadow": 0, "primode": 0}
    objset1 = sr.kx46[5]
    shdpri = cap.k055555[37:40]
    for x in range(256):
        offs = x * 8                                            # start_addr 0 on type 2
        if not spr[offs] & 0x8000:
            continue
        zcode = int(spr[offs] & 0xff)
        if sr.opset & 0x10:
            zcode = 0xff - zcode
        k = int(spr[offs + 6])
        code, color, pri = sr.type2_callback(int(spr[offs + 1]), k)

        add_solid = add_shadow = False
        solid_mode = shadow_mode = 0
        spri = 0
        shadow = k >> 10 & 3
        if shadow:
            if shadow != 1 or objset1 & 0x20:
                shadow -= 1
                add_solid, solid_mode = True, 1
                if shadowon[shadow]:
                    add_shadow, shadow_mode = True, 4
            else:
                shadow = 0
                if not shadowon[0]:
                    continue
                add_shadow, shadow_mode = True, 5
        else:
            add_solid = True
        if add_solid and (color >> 16 & 3):                     # K055555_MIXSHIFT
            raise SystemExit("alpha-blended sprite: not modelled")
        if add_shadow:
            spri = pri if sr.opset & 0x20 else shdpri[shadow]

        if primode & 0xf == 1:
            zcode = 0
        elif primode & 0xf in (4, 5):
            if primode & 0xf == 4 and (k & 0x3000 or k == 0x0800):   # "Daisukiss bad shadow filter"
                skipped["primode"] += 1
                continue
            spri = max(spri, spri_min)                          # "Tokkae shadow masking"

        if add_solid:
            pool.append((pri << 24 | zcode << 16 | offs << 5 | solid_mode << 4,
                         offs, code, color & 0xffff))
        if add_shadow:
            skipped["shadow"] += 1
            pool.append((spri << 24 | zcode << 16 | offs << 5 | shadow_mode << 4 | shadow,
                         offs, code, color & 0xffff))
    return pool, skipped, spr


def sort_pool(pool):
    """MAME: "sort objects in descending order ... reverse objpool to retain
    order in case of ties" -- reverse, then a stable sort, descending."""
    pool = pool[::-1]
    pool.sort(key=lambda o: -o[0])
    return pool


def sprite_blits(sr, cfg, spr, offs, code):
    """k053247_draw_single_sprite_gxcore + k053247_draw_yxloop_gx: every
    16x16 tile one object draws, as (code, flipx, flipy, sx, sy, w, h) in
    bitmap coordinates."""
    if sr.opset & 0x40:
        wrapsize, xwraplim, ywraplim = 512, 512 - 64, 512 - 128
    else:
        wrapsize, xwraplim, ywraplim = 1024, 1024 - 384, 1024 - 512
    offx = s16(sr.kx46[0] << 8 | sr.kx46[1])
    offy = s16(sr.kx46[2] << 8 | sr.kx46[3])
    # OBJSET1 bits 0/1 are NOT refused. daiskiss runs with bit 1 (flip Y) set
    # on every frame and its picture is the right way up, because MAME's
    # geometry negates Y twice -- `oy = -oy` for the flip, then
    # `oy = (-oy - offy)` -- so on GX that bit set is the NORMAL orientation.
    flipscreenx = sr.kx46[5] & 0x01
    flipscreeny = sr.kx46[5] & 0x02
    if sr.kx46[5] & 0x08:
        raise SystemExit("K053246 OBJSET1 bit 3 (Escape Kids half width) not modelled")

    xa = (code & 1) + (code >> 2 & 1) * 2 + (code >> 4 & 1) * 4
    ya = (code >> 1 & 1) + (code >> 3 & 1) * 2 + (code >> 5 & 1) * 4
    code &= ~0x3f
    temp4 = int(spr[offs])
    oy = int(spr[offs + 2] & 0x3ff)
    ox = int(spr[offs + 3] & 0x3ff)
    scaley = zoomy = int(spr[offs + 4] & 0x3ff)
    zoomy = (0x400000 + (zoomy >> 1)) // zoomy if zoomy else 0x800000
    if not temp4 & 0x4000:
        scalex = zoomx = int(spr[offs + 5] & 0x3ff)
        zoomx = (0x400000 + (zoomx >> 1)) // zoomx if zoomx else 0x800000
    else:
        zoomx, scalex = zoomy, scaley
    nozoom = scalex == 0x40 and scaley == 0x40
    flipx = bool(temp4 & 0x1000)
    flipy = bool(temp4 & 0x2000)
    t6 = int(spr[offs + 6])
    mirrorx = bool(t6 & 0x4000)
    if mirrorx:
        flipx = False
    mirrory = bool(t6 & 0x8000)

    if flipscreenx:
        ox = -ox
        if not mirrorx:
            flipx = not flipx
    if flipscreeny:
        oy = -oy
        if not mirrory:
            flipy = not flipy

    ox += cfg["dx"]
    oy -= cfg["dy"]
    ox = (ox - offx) & (wrapsize - 1)
    oy = (-oy - offy) & (wrapsize - 1)
    if ox >= xwraplim:
        ox -= wrapsize
    if oy >= ywraplim:
        oy -= wrapsize
    t = temp4 >> 8 & 0x0f
    width, height = 1 << (t & 3), 1 << (t >> 2 & 3)
    ox -= (zoomx * width) >> 13
    oy -= (zoomy * height) >> 13

    for y in range(height):
        sy = oy + ((zoomy * y + (1 << 11)) >> 12)
        zh = (oy + ((zoomy * (y + 1) + (1 << 11)) >> 12)) - sy
        for x in range(width):
            sx = ox + ((zoomx * x + (1 << 11)) >> 12)
            zw = (ox + ((zoomx * (x + 1) + (1 << 11)) >> 12)) - sx
            tc = code
            if mirrorx:
                if (not flipx) ^ ((x << 1) < width):
                    tc += XOFFSET[(width - 1 - x + xa) & 7]; fx = True
                else:
                    tc += XOFFSET[(x + xa) & 7]; fx = False
            else:
                tc += XOFFSET[((width - 1 - x) if flipx else x) + xa & 7]
                fx = flipx
            if mirrory:
                if (not flipy) ^ ((y << 1) >= height):
                    tc += YOFFSET[(height - 1 - y + ya) & 7]; fy = True
                else:
                    tc += YOFFSET[(y + ya) & 7]; fy = False
            else:
                tc += YOFFSET[((height - 1 - y) if flipy else y) + ya & 7]
                fy = flipy
            if nozoom:
                zw = zh = 0x10
            yield tc, fx, fy, sx, sy, zw, zh


class Canvas:
    """The visible window of MAME's bitmap, plus the GX z-buffers (wipezbuf:
    all memset to 0xff). rgb is int32 so the blends can widen."""

    def __init__(self, rgb):
        self.rgb = rgb.astype(np.int32)
        self.zbuf = np.full((VIS_H, VIS_W), 0xff, dtype=np.int32)
        self.shd_z = np.full((VIS_H, VIS_W), 0xff, dtype=np.int32)
        self.shd_pri = np.full((VIS_H, VIS_W), 0xff, dtype=np.int32)
        self.opaque = np.zeros((VIS_H, VIS_W), dtype=bool)
        self.pen = np.zeros((VIS_H, VIS_W), dtype=np.int32)     # solid sprite pixels only
        self.pri = np.zeros((VIS_H, VIS_W), dtype=np.int32)
        self.offs = np.full((VIS_H, VIS_W), -1, dtype=np.int32)  # which sprite (RAM offset)


def draw_sprite_tile(cv, cap, gfx, code, color, fx, fy, sx, sy, zw, zh,
                     drawmode, z8, pri=0, shd_table=None, offs=-1, winner=None):
    """zdrawgfxzoom32GP with the z-buffer on (zcode >= 0), drawmodes 0, 1, 4, 5.

    dst size is zw x zh; the source is stepped in 13.19 fixed point at
    (16 << 19) / size; flips XOR the 16x16 index. Solid (0/1): skip pen 0,
    skip the shadow pen (>= granularity - 1 = 31) in mode 1, skip where the
    z-buffer holds a LOWER z. Shadow (4; 5 is 4 with shdpen 1): only shadow
    pens, against the shadow z-buffer and its priority byte, and the
    destination goes through the 15-bit shadow table.
    """
    FP = 19
    w, h = zw, zh
    if w <= 0 or h <= 0:
        return
    shdpen = 31
    if drawmode == 5:
        drawmode, shdpen = 4, 1
    x_off = (np.arange(w) * ((16 << FP) // w)) >> FP
    y_off = (np.arange(h) * ((16 << FP) // h)) >> FP
    if fx:
        x_off = 15 - x_off
    if fy:
        y_off = 15 - y_off
    src = gfx[code % len(gfx)][y_off[:, None], x_off[None, :]].astype(np.int32)

    dx0, dy0 = sx - VIS_X0, sy - VIS_Y0
    x0, x1 = max(dx0, 0), min(dx0 + w, VIS_W)
    y0, y1 = max(dy0, 0), min(dy0 + h, VIS_H)
    if x0 >= x1 or y0 >= y1:
        return
    s = src[y0 - dy0:y1 - dy0, x0 - dx0:x1 - dx0]
    win = np.s_[y0:y1, x0:x1]
    rgb = cv.rgb[win]
    if drawmode < 4:
        zb = cv.zbuf[win]
        draw = s != 0
        if drawmode & 3:
            draw &= s < shdpen
        draw &= ~(zb < z8)
        if winner is not None:              # stage_mix(one_sprite_pixel=True)
            draw &= winner[win] == offs
        zb[draw] = z8
        rgb[draw] = cap.pal[(color % 256) * 32 + s[draw]]
        cv.opaque[win] |= draw
        cv.pen[win][draw] = (color % 256) * 32 + s[draw]
        cv.pri[win][draw] = pri
        cv.offs[win][draw] = offs
    else:
        sz, sp = cv.shd_z[win], cv.shd_pri[win]
        draw = (s >= shdpen) & ~(sz < z8) & ~(sp <= pri)
        sz[draw] = z8
        sp[draw] = pri
        rgb[draw] = shd_table(rgb[draw])


def shadow_table(deltas, noclip):
    """palette_device::set_shadow_dRGB32, as the GX sprite code indexes it:
    shd_base[pix.as_rgb15()] -- the destination is cut to 5 bits a channel,
    re-expanded with pal5bit, then offset. Lossy, as MAME's comment says."""
    d = np.array([max(-0xff, min(0xff, v)) for v in deltas], dtype=np.int32)

    def apply(px):
        c5 = px >> 3
        v = ((c5 << 3) | (c5 >> 2)) + d
        return v & 0xff if noclip else np.clip(v, 0, 255)
    return apply


def stage_sprites_only(cap):
    """The solid sprites alone, z-buffered against each other, on black.

    Returns (rgb, opaque, info). Shadow objects are not added here: they
    need the pixels under them, which is the mix stage.
    """
    cfg = SPRITE_CFG.get(cap.set)
    if cfg is None:
        raise SystemExit(f"no SPRITE_CFG entry for {cap.set}")
    sr = SpriteRegs(cap)
    gfx = k055673_sprites(cap.set)
    pool, skipped, spr = sprite_objects(cap, sr, cfg["primode"])
    cv = Canvas(np.zeros((VIS_H, VIS_W, 3), dtype=np.uint8))
    for order, offs, code, color in sort_pool(pool):
        for blit in sprite_blits(sr, cfg, spr, offs, code):
            draw_sprite_tile(cv, cap, gfx, blit[0], color, *blit[1:], order >> 4 & 0xf,
                             order >> 16 & 0xff, order >> 24 & 0xff, offs=offs)
    info = dict(objects=len(pool), **skipped, pen=cv.pen, pri=cv.pri, offs=cv.offs,
                z=np.where(cv.opaque, cv.zbuf, 0))
    return cv.rgb.astype(np.uint8), cv.opaque, info


def alpha_blend(d, s, level):
    """alpha_blend_r32: per channel (s * level + d * (256 - level)) >> 8."""
    return (s * level + d * (256 - level)) >> 8


def k054338_alpha_level(cap, pblend):
    """k054338_device::set_alpha_level, with invert_alpha(1) from
    konamigx_mixer_init. Returns 10 bits: MIXPRI, additive, level."""
    if not pblend:
        return 255
    pblend &= 3
    reg = cap.k054338[13 + (pblend >> 1 & 1)]
    mixset = (reg >> (~pblend << 3 & 8)) & 0xff
    mixlv = 0x1f - (mixset & 0x1f)
    mixlv = (mixlv << 3) | (mixlv >> 2)
    mixlv |= bool(mixset & 0x20) << 8
    mixlv |= bool(cap.k054338[15] & 0x02) << 9
    return mixlv


def stage_mix(cap, one_sprite_pixel=False):
    """konamigx_mixer and konamigx_mixer_draw: the whole frame.

    Tile layers and sprites go into one object pool -- a layer is an object
    with order PRI << 24 -- sorted DESCENDING and drawn in that order, so a
    HIGHER K055555 priority value is further BACK. A tile layer paints over
    whatever is there (MAME's tilemap draw leaves the priority bitmap, which
    is the sprite z-buffer here, untouched); a sprite shadow darkens or
    lights whatever is there when it is drawn.
    """
    cfg = SPRITE_CFG.get(cap.set)
    if cfg is None:
        raise SystemExit(f"no SPRITE_CFG entry for {cap.set}")
    k5, k3 = cap.k055555, cap.k054338
    cv = Canvas(stage_bg(cap))
    disp = k5[45]
    if not disp or not (k3[15] & 0x01):                         # K338_CTL_KILL
        return cv.rgb.astype(np.uint8)
    if k5[42]:
        raise SystemExit("K055555 VBRI (layer brightness) not modelled")
    if k3[15] & 0x02:
        raise SystemExit("K054338 MIXPRI not modelled")

    layerpri = [k5[7], k5[10], k5[13], k5[14], k5[16], k5[17]]
    shadowon, spri_min = mixer_shadow_setup(cap, layerpri[:4])
    noclip = bool(k3[15] & 0x20)
    tables = [shadow_table(k054338_shadow_deltas(cap, i), noclip) for i in range(3)]
    tables.append(shadow_table((-80, -80, -80), False))        # set_shadow_dRGB32(3, ...)

    # pre-sort the layers exactly as MAME does, then add them i = 5..0
    layerid = list(range(6))
    lp = layerpri[:]
    for j in range(5):
        for i in range(j + 1, 6):
            if lp[j] <= lp[i]:
                lp[j], lp[i] = lp[i], lp[j]
                layerid[j], layerid[i] = layerid[i], layerid[j]
    pool = [(lp[i] << 24, -1, layerid[i], 0) for i in range(5, -1, -1)
            if layerid[i] < 4]                                  # no sub layers on these sets

    sr = SpriteRegs(cap)
    gfx = k055673_sprites(cap.set)
    spool, _, spr = sprite_objects(cap, sr, cfg["primode"], shadowon, spri_min)
    # one_sprite_pixel: draw each solid sprite only where it is the line
    # buffer's winner (stage_sprites_only), as the hardware hands the mixer one
    # sprite pixel per position. Equal to MAME if its shared z-buffer never
    # lets a losing sprite pixel reach the screen.
    winner = stage_sprites_only(cap)[2]["offs"] if one_sprite_pixel else None
    layers = {}
    for order, offs, code, color in sort_pool(pool + spool):
        if offs >= 0:
            if not disp & 0x10:
                continue
            drawmode = order >> 4 & 0xf
            tab = tables[order & 3] if drawmode >= 4 else None
            for blit in sprite_blits(sr, cfg, spr, offs, code):
                draw_sprite_tile(cv, cap, gfx, blit[0], color, *blit[1:], drawmode,
                                 order >> 16 & 0xff, order >> 24 & 0xff, tab,
                                 offs=offs, winner=winner if drawmode < 4 else None)
            continue
        layer = code
        if not disp >> layer & 1:
            continue
        # gx_draw_basic_tilemaps: the internal mix code from the K055555, and
        # MAME's hack that turns an additive level into an inverted alpha.
        mix = (k5[33] >> 2 * layer & 3) & (k5[34] >> 2 * layer & 3)
        alpha = k054338_alpha_level(cap, mix) & 0x1ff
        if alpha & 0x100:
            alpha &= 0xff
            if alpha:
                alpha = ~alpha & 0xff
        if layer not in layers:
            layers[layer] = stage_layer(cap, layer)
        rgb, opq = layers[layer]
        src = rgb.astype(np.int32)
        if alpha < 255:
            cv.rgb[opq] = alpha_blend(cv.rgb[opq], src[opq], alpha)
        else:
            cv.rgb[opq] = src[opq]
    return cv.rgb.astype(np.uint8)


def mix_sources(cap, shadow_ids=False):
    """What the K055555 receives per pixel, as the hardware delivers it.

    Each source is a colour, whether it is opaque, and a RANK: its position in
    konamigx_mixer's draw order (higher = drawn later = in front). The rank
    reproduces MAME's comparison of K055555 priorities exactly -- a layer's
    order is PRI << 24, a sprite's pri << 24 | z << 16 | offs << 5 | mode << 4,
    so at equal priority a layer is in front of a sprite, and equal layers keep
    the pool's stable-sort order -- which in RTL is a priority compare with
    those tie-breaks.

    Sources: the background (rank -1, always opaque), layers A-D, the one
    winning solid sprite pixel from the line buffer, and at most one sprite
    shadow per pixel (the captures never stack two; more is flagged).
    """
    cfg = SPRITE_CFG[cap.set]
    k5, k3 = cap.k055555, cap.k054338
    disp = k5[45]
    layerpri = [k5[7], k5[10], k5[13], k5[14], k5[16], k5[17]]
    shadowon, spri_min = mixer_shadow_setup(cap, layerpri[:4])
    layerid = list(range(6))
    lp = layerpri[:]
    for j in range(5):
        for i in range(j + 1, 6):
            if lp[j] <= lp[i]:
                lp[j], lp[i] = lp[i], lp[j]
                layerid[j], layerid[i] = layerid[i], layerid[j]
    pool = [(lp[i] << 24, -1, layerid[i], 0) for i in range(5, -1, -1) if layerid[i] < 4]
    sr = SpriteRegs(cap)
    spool, _, spr = sprite_objects(cap, sr, cfg["primode"], shadowon, spri_min)
    seq = sort_pool(pool + spool)                 # MAME's draw order, back to front
    rank_layer = {o[2]: i for i, o in enumerate(seq) if o[1] < 0}
    rank_solid = {o[1]: i for i, o in enumerate(seq) if o[1] >= 0 and (o[0] >> 4 & 0xf) < 4}

    src = {}
    src["bg"] = (stage_bg(cap).astype(np.int32), np.ones((VIS_H, VIS_W), bool), -1)
    for L in range(4):
        rgb, opq = stage_layer(cap, L)
        on = bool(disp >> L & 1)
        src["ABCD"[L]] = (rgb.astype(np.int32), opq & on, rank_layer[L])

    srgb, sopq, info = stage_sprites_only(cap)
    srank = np.full((VIS_H, VIS_W), -2, np.int32)
    for offs, r in rank_solid.items():
        srank[info["offs"] == offs] = r
    src["S"] = (srgb.astype(np.int32), sopq & bool(disp & 0x10), srank)

    # the shadow line: MAME's shadow objects, in draw order, through the
    # shadow z-buffer and priority byte, recording which one lands per pixel
    gfx = k055673_sprites(cap.set)
    cv = Canvas(np.zeros((VIS_H, VIS_W, 3), np.uint8))
    shrank = np.full((VIS_H, VIS_W), -2, np.int32)
    shcode = np.zeros((VIS_H, VIS_W), np.int32)
    shcount = np.zeros((VIS_H, VIS_W), np.int32)
    shoffs = np.full((VIS_H, VIS_W), -1, np.int32)
    shfull = np.zeros((VIS_H, VIS_W), np.int32)
    shpri = np.zeros((VIS_H, VIS_W), np.int32)
    shz = np.zeros((VIS_H, VIS_W), np.int32)
    for i, (order, offs, code, color) in enumerate(seq):
        if offs < 0 or (order >> 4 & 0xf) < 4 or not disp & 0x10:
            continue
        for blit in sprite_blits(sr, cfg, spr, offs, code):
            before_z, before_p = cv.shd_z.copy(), cv.shd_pri.copy()
            draw_sprite_tile(cv, cap, gfx, blit[0], color, *blit[1:], order >> 4 & 0xf,
                             order >> 16 & 0xff, order >> 24 & 0xff, lambda px: px)
            hit = (cv.shd_z != before_z) | (cv.shd_pri != before_p)
            shrank[hit] = i
            shcode[hit] = order & 3
            shcount[hit] += 1
            shoffs[hit] = offs
            shfull[hit] = (order >> 4 & 0xf) == 5
            shpri[hit] = order >> 24 & 0xff
            shz[hit] = order >> 16 & 0xff
    if shadow_ids:                 # for scripts/check_gx_obj.py and check_gx_mixer.py
        return src, (shrank, shcode, shcount), shoffs, shfull, shpri, shz
    return src, (shrank, shcode, shcount)


def stage_mix_hw(cap):
    """The mixer as the hardware is structured: per pixel, the K055555 picks
    the top source and the one behind it by rank; the K054338 blends the top
    over the second when the top is an alpha layer, and applies the shadow
    to whatever is behind the shadow's rank. Specification for the RTL mixer.

    Exact to MAME's painter while at most one alpha layer and one shadow are
    stacked on a pixel; anything deeper raises, rather than drawing wrong.
    """
    k5, k3 = cap.k055555, cap.k054338
    out = stage_bg(cap).astype(np.int32)
    if not k5[45] or not (k3[15] & 0x01):
        return out.astype(np.uint8)
    if k5[42]:
        raise SystemExit("K055555 VBRI (layer brightness) not modelled")
    src, (shrank, shcode, shcount) = mix_sources(cap)
    if (shcount > 1).any():
        raise SystemExit("more than one shadow on a pixel: not modelled")

    alpha = {}
    for L in range(4):
        mix = (k5[33] >> 2 * L & 3) & (k5[34] >> 2 * L & 3)
        a = k054338_alpha_level(cap, mix) & 0x1ff
        if a & 0x100:
            a &= 0xff
            if a:
                a = ~a & 0xff
        alpha["ABCD"[L]] = a

    names = list(src)
    rank = np.stack([np.where(src[n][1], src[n][2], -3) for n in names])   # -3: absent
    order = np.argsort(-rank, axis=0, kind="stable")
    top, second = order[0], order[1]
    rgb = np.stack([src[n][0] for n in names])
    rtop = np.take_along_axis(rank, top[None], 0)[0]
    rsec = np.take_along_axis(rank, second[None], 0)[0]
    ctop = np.take_along_axis(rgb, top[None, ..., None], 0)[0]
    csec = np.take_along_axis(rgb, second[None, ..., None], 0)[0]

    noclip = bool(k3[15] & 0x20)
    tables = [shadow_table(k054338_shadow_deltas(cap, i), noclip) for i in range(3)]
    tables.append(shadow_table((-80, -80, -80), False))

    def shade(c, mask):
        c = c.copy()
        for t in range(4):
            m = mask & (shcode == t)
            if m.any():
                c[m] = tables[t](c[m])
        return c

    has_sh = shcount > 0
    alpha_top = np.zeros((VIS_H, VIS_W), bool)
    lvl = np.full((VIS_H, VIS_W), 255, np.int32)
    for i, n in enumerate(names):
        if n in alpha and alpha[n] < 255:
            m = top == i
            alpha_top |= m
            lvl[m] = alpha[n]
            if (m & np.isin(second, [j for j, q in enumerate(names)
                                     if q in alpha and alpha[q] < 255])).any():
                raise SystemExit("alpha layer over an alpha layer: not modelled")

    csec = shade(csec, has_sh & alpha_top & (shrank > rsec) & (shrank < rtop))
    out = np.where(alpha_top[..., None], alpha_blend(csec, ctop, lvl[..., None]), ctop)
    out = shade(out, has_sh & (shrank > rtop))
    return out.astype(np.uint8)


def stage_sprites(cap):
    """The solid sprites over black. Illustrative, like stage_tiles: the
    mixer decides what covers them, so the score is score_sprites()."""
    rgb, _, _ = stage_sprites_only(cap)
    return rgb


def score_sprites(cap, ref):
    """(reproduced, drawn, info): of the pixels the solid sprites draw, how
    many MAME shows with exactly the sprite's colour. A miss is a pixel MAME
    shows covered or blended -- or a sprite fault; the numbers cannot tell
    which, so every miss has to be looked at until the mixer exists."""
    rgb, opq, info = stage_sprites_only(cap)
    ok = int((np.all(rgb == ref, axis=-1) & opq).sum())
    return ok, int(opq.sum()), info


STAGES = {"bg": stage_bg, "tiles": stage_tiles, "sprites": stage_sprites, "mix": stage_mix,
          "mixhw": stage_mix_hw}


def attribution(cap, ref):
    """Which source must have produced each reference pixel, by palette bank.

    A tile layer's pens are [PAL << 10, +1023] (K056832 colour granularity is
    16, so PAL << 6 colours is PAL * 1024 pens). Sprite pens can land in any
    bank, so a colour is reported by bank only. A colour that occurs only
    inside one source's range can only have come from that source, so a
    stage can be scored on exactly the pixels it is responsible for, without
    a separate MAME render per layer.

    IT ASSUMES MAME'S PIXEL IS AN UNMODIFIED PEN. A blended or highlighted
    pixel can equal some other pen by coincidence: daiskiss frame 6000's 312
    "layer D" misses are layer C yellow (255,255,0) under a spotlight, +0x40
    per channel clamped, which happens to be pen 0xe4f's (255,255,64).
    """
    raw = (cap.pal[:, 0].astype(np.uint32) << 16 | cap.pal[:, 1].astype(np.uint32) << 8
           | cap.pal[:, 2])
    cols = (ref[..., 0].astype(np.uint32) << 16 | ref[..., 1].astype(np.uint32) << 8
            | ref[..., 2])
    src = {}
    for c in np.unique(cols):
        if c == 0:
            src[int(c)] = "black"
            continue
        idx = np.nonzero(raw == c)[0]
        names = set()
        for i in idx:
            bank = int(i) >> 10
            names.add("ABCD"[bank] if bank < 4 else "bank%d" % bank)
        src[int(c)] = "/".join(sorted(names)) if names else "unexplained"
    return np.vectorize(lambda c: src[int(c)])(cols)


def compare(model, ref, out_png):
    """Exact per-pixel comparison, and a diff image for eyes.

    Diff image: matching pixels are drawn dimmed, mismatches in magenta, so a
    region the model has right shows up as a coherent shape.
    """
    same = np.all(model == ref, axis=-1)
    diff = (ref // 3).copy()
    diff[~same] = (255, 0, 255)
    Image.fromarray(np.concatenate([ref, model, diff], axis=1)).save(out_png)
    return int(same.sum()), same


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", help="capture name under debug/, e.g. daiskiss-title")
    ap.add_argument("--stage", choices=sorted(STAGES), default="bg")
    a = ap.parse_args()

    cap = Capture(REPO / "debug" / a.capture)
    ref = cap.reference()
    if ref.shape != (VIS_H, VIS_W, 3):
        sys.exit(f"reference is {ref.shape}, expected {(VIS_H, VIS_W, 3)}")

    model = STAGES[a.stage](cap)
    out_png = cap.path / f"model_{a.stage}.png"
    n, same = compare(model, ref, out_png)
    total = VIS_W * VIS_H
    print(f"{cap.set} frame {cap.manifest.get('frame')}  stage {a.stage}: "
          f"{n} of {total} pixels match MAME ({100 * n / total:.1f}%)")

    # Score each layer on the pixels only it can have produced. That is the
    # number that means something while later stages are still missing: the
    # whole-frame figure is dominated by what has not been modelled yet.
    src = attribution(cap, ref)
    for name, ok, n in score_layers(cap, ref, src):
        print(f"  layer {name}  {ok:>6} of {n:<6} pixels only it can have drawn are "
              f"reproduced")
    if a.stage == "sprites":
        ok, n, info = score_sprites(cap, ref)
        print(f"  sprites  {ok:>6} of {n:<6} pixels they draw are shown unchanged by MAME"
              f"   objects {info['objects']}, shadow {info['shadow']}, primode-filtered {info['primode']}")
    print(f"  reference | model | diff  ->  {out_png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
