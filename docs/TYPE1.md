# Type 1 boards: Racin' Force, Open Golf Championship, Golfing Greats 2

MAME source: upstream mamedev a5889c83221 (newest konamigx commit; the reference binary is
C:/mame-gx/konamigx.exe, 352a5fbb8bb, which contains it). Citations: `gx.cpp` =
src/mame/konami/konamigx.cpp, `gxv.cpp` = konamigx_v.cpp, `gx.h` = konamigx.h,
`936.cpp` = src/devices/video/k053936.cpp.

**About "shifter layout":** 93d08c8a3dd is NOT a gfx layout. It adds `racinfrc.lh`
(src/mame/layout/racinfrc.lay), an artwork overlay that shows the gear shifter's state from INPUTS
bit 0x04000000. It does nothing to emulation. The planar gfx layouts came from af5376797f1.

**Provenance:** af5376797f1's message says: "GPT-6 Astra assisted with the reverse-engineering,
math, and analysis of direct-feed video from hardware." The schematic names in the comments (HBK,
CBK, BRK, CROM/HROM, chips 21Q/22N) suggest schematic access. The renderer itself is labelled an
approximation (below).

## 1. Memory map: Type 1 vs Type 2

Both maps are `gx_base_memmap` (gx.cpp:1072-1096) plus the palette at 0xd90000-0xd97fff
(`konamigx_palette_r/w`, the same in both: gx.cpp:1101, 1127). The differences:

| Address | Type 2 (gx_type2_map, gx.cpp:1124) | Type 1 (gx_type1_map, gx.cpp:1098-1114) |
|---|---|---|
| cc0000-cc0003 | ESC `esc_w` | **absent** (no ESC) |
| dda000-ddafff | - | ADC0834 write port: bit 24 CLK, 25 DI, 26 CS (gx.cpp:1360-1363) |
| ddc000-ddcfff | - | ADC0834 read port: bit 24 DO |
| dde000-dde003 | - | cabinet lamp: `lamp0 = BIT(data,24)` (gx.cpp:1062-1065) |
| e00000-e0001f | - | K053936 ctrl, device 16-bit handlers (`ctrl_r/w`) |
| e20000-e2000f | - | 056540 (PSAC4) registers, write-only RAM (`type1_psac4_ctrl`) |
| e40000-e40003 | - | `type1_bank_w`: a u16 handler on the 32-bit bus, so both halves COMBINE into one 16-bit `m_type1_bank` |
| e80000-e81fff | - | K053936 line control (`linectrl_r/w`), "chips 21L+19L" |
| ec0000-edffff | - | PSAC VRAM 128 KB (`psacram`, `konamigx_t1_psacmap_w` gxv.cpp:1787), "20J+23J+18J" |
| f00000-f3ffff | - | `type1_roz_r1`: HROM (gfx4) byte readback |
| f40000-f7ffff | - | `type1_roz_r2`: CROM (gfx3) byte readback |
| f80000-f80fff | - | 056540 line RAM, 1024 longs (`type1_psac4_lram`), "21Q" |
| fc0000-fc00ff | - | palette lookup SRAM "22N", umask 0xff00ff00 (128 bytes a bank) |

racinfrc_map adds (gx.cpp:1116-1121): dc0000-dc1fff RAM ("056230 RAM?", LAN) and dd0000-dd00ff
nop ("056230 regs?").
The machine config is the base `konamigx()`: the same vblank IRQ (`konamigx_type2_vblank_irq`,
gx.cpp:639) and DMA timing. There is no scanline timer. init is `init_posthack`, the 68020 2/3
clock for POST (gx.cpp:4023-4031, 4191). gameDefs are `11, 0, BPP4`: no special and no readback
hook (gx.cpp:4056-4060).

## 2. Video

### What the board adds
- **K053936** `m_type1_roz`, `set_wrap(1)` (gx.cpp:1887, 1910). Neither config calls
  `set_offsets`, so the device's x/y offsets are 0. Line mode is used (936.cpp:313-371): per
  bitmap row y, `lineaddr = linectrl + 4*(y & 0x1ff)`, startx = 256*s16(l[0]+ctrl[0]),
  starty = 256*s16(l[1]+ctrl[1]), incxx = s16(l[2]) (x256 if ctrl[6] bit 15), incxy = s16(l[3])
  (x256 if ctrl[6] bit 7). Unlike Type 3, there is no `^1` word swap here: these are device
  handlers, not the legacy shared-RAM path.
- **Two tilemaps from one VRAM entry**, each 128x128 tiles of 16x16 in row order (gxv.cpp:1381-1382,
  1415-1416), so the map is 2048x2048 px and wraps. Entry = 2 longs (gxv.cpp:1098-1111):
  - tilemap A, height (gfx 1 = gfx4/HROM): code = long0[14:0], colour = long0[23:16] ("tile-wide
    height byte"), flipx = long1 bit 23, flipy = long1 bit 22.
  - tilemap B, colour (gfx 0 = gfx3/CROM): code = long1[14:0], colour = long1[19:18] (PL0/PL1),
    flipx = long1 bit 21, flipy = long1 bit 20.
  - Comment: "HROM/CROM have 15 tile address bits; Racin' Force only populates half of each."
- **056540 "PSAC4"**:
  - Registers at e20000. MAME uses only long 0 bits 23:8, as the y origin (gxv.cpp:1445). The map
    comment says "partially understood" (gx.cpp:1106).
  - LRAM at f80000: entry e = [7:0] s8 displacement, [15:8] parameter (0xff = line skipped; it
    also serves as priority and lookup index), [31:16] scale (gxv.cpp:1475-1489).
- **Bank register** `m_type1_bank` (gx.cpp:779-822):
  - [2:0] HBK, HROM address bits 18-20;
  - [4:3] HROM byte lane (3 reads 0xff: "The fourth height ROM is unpopulated");
  - [10:6] CBK: [8:6] CROM address bits 18-20, [10:9] lane (golf 4 lanes, racinfrc 3, others 0xff);
  - [15:12] BRK, the lookup bank.
  - The readback windows are 256 KB of single bytes: byte = rom[(bank*0x40000 + offset) *
    lanes + lane], i.e. one raw ROM chip.
- **Lookup SRAM 22N** at fc0000: 16 banks of 128 bytes (`m_type1_lookup[0x800]`, index
  `(bank>>12)<<7 | offset`). Per the comment: "PR0 selects a nibble, PR1-7 address the byte, BRK0-3
  select one of sixteen banks". The nibble is p even = high, p odd = low (gxv.cpp:1489-1491).
  Nibble[2:0] gives pen bits 10:8 (COL8-10) and nibble[3] gives pen bit 11, the MIX bit.
  MAME reads it at render time with the bank as it is then.

### gfx decode (gx.cpp:1658-1696)
- `t1_charlayout6`: 16x16, 6 planes {16,20,8,12,0,4}, x {3,2,1,0, 27,26,25,24, 51..48, 75..72},
  rows STEP16(0,96). That is 12 bytes a row and 192 bytes a tile.
  - Each byte triple (one byte per ROM: ROM_GROUPBYTE|ROM_SKIP(2), gx.cpp:2134) holds 4 pixels.
  - Each ROM byte carries two planes, as its high and low nibble, for 4 adjacent pixels. Pixel k
    of the group is nibble bit k ("Each ROM byte supplies two bitplanes for four adjacent
    horizontal pixels", gx.cpp:1670-1671).
  - Plane MSB first: byte2 high nibble, byte2 low, byte1 high, byte1 low, byte0 high, byte0 low.
- `t1_charlayout8`: 8 planes {24,28,16,20,8,12,0,4}, 4-byte groups (ROM_SKIP(3)), 16 bytes a
  row, 256 bytes a tile.
- golf: CROM 8 bpp (granularity 256), HROM 6 bpp. racinfrc: both 6 bpp. MAME uses gfx(0)
  granularity == 256 as its "golf" flag throughout.
- In the ind16 bitmaps, pen = colour * granularity + pixel. So the height sample is
  h = tilebyte<<6 | hpix6, and the colour sample is c = PL<<6 | cpix6 (racinfrc) or
  PL<<8 | cpix8 (golf).

### Screen
- Base: `set_raw(8000000, 512, 0, 383, 264, 0, 223)`, visarea 24..311 x 16..239 (288 wide)
  (gx.cpp:1747-1754).
- racinfrc keeps that. Its K053252 offsets are (32, 0) (gx.cpp:1917), and its tilemap layer
  offsets are x {-1,1,3,4}, y -16 on all four (gxv.cpp:1411-1414).
- opengolf: visarea 40..423 (384 wide), K053252 offsets (32, 16), layer x {-1,1,3,4}, y 0
  (gx.cpp:1890-1893, gxv.cpp:1377-1380).
- Sprites: racinfrc LAYOUT_GX (-53, **-34**); golf LAYOUT_GX6 (-69, -23).
- K056832: racinfrc BPP_6; golf BPP_5 (the default).

### type1_vblank_w (gxv.cpp:1435-1447)
The screen is VIDEO_UPDATE_AFTER_VBLANK. On vblank start the handler returns. On vblank end it
latches `yorigin[phase] = (psac4_ctrl[0] >> 8) & 0xffff` and sets valid bit `phase`:
- golf: phase = K053936 ctrl reg 0x0e bit 7, the "external RAM address counter start" in the
  936.cpp header. A comment removed in f10cb86 explained it: "Open Golf alternates near/far table
  ranges, with a different vertical origin for each".
- racinfrc: phase is 0.

So a frame is drawn, at the next vblank start, with the origin written in the previous vblank.

### The renderer, type1_draw_terrain (gxv.cpp:1452-1527)
MAME's own words: "Approximate PSAC4 height-field renderer" (gxv.cpp:1449), and "The PSAC4
software renderer approximates height projection and coverage; the DRAM pipeline and per-pixel
mixer parameters remain to be emulated" (gx.h:307-310).

1. If K053936 ctrl[7] bit 5 is clear, nothing is drawn.
2. Otherwise both tilemaps are drawn through the K053936 into 512x512 bitmaps. Pen 0 is not
   transparent here ("transparency will be handled manually in post-processing").
3. limit[x] = 240 (visible max_y+1) for all 512 x.
4. For line = 1 .. (golf ? 480 : 255), in "near to far" order:
   - e = lram[line]; p = e[15:8]; skip if p == 0xff.
   - bank = golf && line > 224; skip if that bank's origin was never latched.
   - ground = 256 + yorigin[bank] - line - s8(e[7:0]) ("The displacement wraps past 0x7f during
     elevated camera views").
   - scale = e[31:16]; lookup nibble from p.
   - For x = 0..511:
     - c = colour.pix(line+14, x). Skip if (c & (golf ? 0xff : 0x3f)) == 0: "Transparency comes
       from CROM".
     - h = height.pix(line+14, x); level = ((h & 0x3f) + (h >> 6)) & 0xff (pixel height + tile
       byte).
     - top = max(ground - level*scale/(golf ? 256 : 64), 0): "Racin' Force's LRAM projection uses
       6 fractional bits".
     - pen = (c & 0xff) | (lookup & 0xf) << 8. For golf, CROM's PL bits are dropped.
     - If scale == 0, write one pixel at row `ground` (if visible) and leave limit alone (the flat
       title artwork).
     - Otherwise fill rows top .. limit[x]-1 with pen and priority p, then
       limit[x] = min(limit[x], top).
   - The "+14": "The two games upload matching eight-byte PSAC2 and four-byte PSAC4 records,
     separated by 14 raster lines" (gxv.cpp:1449-1450). So LRAM line l pairs with K053936
     line-control row l+14.
   - Terrain x is the ROZ bitmap x, 1:1 with screen bitmap x (offsets 0).

Guesswork (empirical fits by the commit's own account, not schematic): +14, 256+yorigin, /64
vs /256, the near-to-far column fill and limit rule, scale==0 as flat, the two-origin golf split
at line 224. Stated as schematic in the comments: the bank bit fields, lookup nibble/bank
addressing, CROM transparency, the PL bits.

The header comment in 936.cpp:304-311 ("rendered upside down ... hold W in Racin' Force") is
stale: the W/E debug keys were removed in f10cb86.

### Mixer placement (gxv.cpp:483-503, 727-731, 1529-1561)
- The terrain is K055555 SUB2 (layer code 5), gated by `disp & K55_INP_SUB2`.
- Each used parameter p becomes its own object-pool entry with
  pri = (p & ~mask) | (PRIINP_10 & mask), where mask = K055555 reg 21 (S2 INPRI ON). So the
  priority is per pixel and 8-bit.
- Key `(pri<<24) | 0x00ffffff`. Comment: "OBJ wins a priority tie against SUB2. Draw this
  terrain before all objects at the same priority".
- Palette: pen & 0x7ff in the main palette (0xd90000, 888).
- Alpha: "The Type-1 board provides one external mix bit and no brightness bits". The mix code
  for the K054338 level is ((m & ~mixmask) | internal), with mixmask = OSMIXON[5:4],
  internal = OSINMIX[5:4] & mixmask, and m = pen bit 11.
- Brightness: from OSBRI/OSBRI_ON[5:4].

## 3. Inputs, lamps, LAN

- **racinfrc** (gx.cpp:1342-1389):
  - Steering: AN0, a paddle, 0x38-0xc8, centre 0x80, reversed. Gas: AN1, a pedal, 0x90-0xff
    (default 0xf0), reversed.
  - Both are read through a serial ADC0834 (`adc0834_callback` CH0/CH1, Vref 5, gx.cpp:741-753).
  - INPUTS: Brake = bit 27 (BUTTON2); Gear Shift = bit 26 (BUTTON3, PORT_TOGGLE); "Calibration
    skip?" = bit 20, with "FIXME: this maps to nowhere according to service mode, verify".
  - DIPs: flip, cabinet (2in1 / mono / stereo), and car number & colour (SW1:6-8, which sets this
    cabinet's car in a linked setup).
  - The EEPROM default comes from `racinfrc.nv`: "it seems impossible to calibrate the controls
    (again!), this has nothing to do with the default eeprom!" (gx.cpp:3711).
  - "racin' force expects bit 1 of the eeprom port to toggle" (gx.cpp:1302): that is
    gx_rdport1_3, as for Type 2.
- **opengolf** (gx.cpp:1391-1438): one Shoot button for each of P1-P4 (bits 28, 20, 12, 4).
  AN0/AN1 are unused; Coin3/4 and Service3/4 exist; DIPs are sound, coin slots, and 2P/4P.
- **ggreats2** (gx.cpp:1440-1474): P1/P2 have 7 buttons each (Direction/Club/Stance L/R,
  Advice) plus Start. AN0/AN1 are pedals, P1 and P2: the "ball device". "TODO: if on 3P/4P mode
  inputs are re-routed (ignore it for now)".
- **Trackball**: the header lists "dd6000: trackball 1, dd8000: trackball 2" (gx.cpp:76-77), but
  neither is mapped in gx_type1_map.
- **Lamp**: one output (dde000 bit 24).
- **LAN**: MACHINE_NODEVICE_LAN. The 056230 is stubbed as 8 KB RAM plus nop regs (gx.cpp:1116-1121);
  `machine/k056230.h` is commented out (gx.cpp:108). racinfrc is marked working with only that
  stub, so the stub is all a single cabinet needs.

## 4. Sound
No difference. opengolf() and racinfrc() call `konamigx()` and touch no sound device: 68000,
2x K054539, TMS57002, K056800 (gx.cpp:1720-1800). opengolf's DIP SW1:1 selects stereo or mono.

## 5. ROM regions (gx.cpp:3665-3962)

| Region | racinfrc / racinfrcu | opengolf / opengolf2 / ggreats2 |
|---|---|---|
| BIOS | 128 KB | 128 KB |
| program | 2x512 KB (1 MB) at 0x200000 | 2x512 KB at 0x200000; opengolf* also load the same pair again at 0x300000 (mirror) |
| data | 2x2 MB (4 MB) at 0x400000 | 2x512 KB (1 MB) at 0x400000 |
| sound prog | 256 KB | 256 KB |
| k056832 | region 3 MB, ROMs 1.5 MB (WORDS2+BYTES2, 6bpp) | region 6 MB, ROMs 3.5 MB (TILE_WORD/BYTE, 5bpp) |
| k055673 | 10 MB (4x2 MB 32_WORD + 2 MB 5th) | region 9 MB, ROMs 9 MB (_48_WORD, GX6) |
| gfx3 CROM | 3 MB (3x1 MB, byte lanes) | 8 MB (4x2 MB, byte lanes) |
| gfx4 HROM | 3 MB (3x1 MB) | 6 MB (3x2 MB) |
| k054539 | 4 MB | region 4 MB, ROMs 3 MB |
| ROM bytes | 28,180,480 (26.9 MB) | 33,423,360 (31.9 MB) |

The SDRAM layout below is computed by hand from scripts/build_mra.py `layout()`/`snd_ram_end()`
rules, with gfx3/gfx4 appended as T34 does (not run):
- racinfrc: tile_base 7 MB; obj_base 11 MB; spread sprites to 27 MB; sound RAMs to about 31.4 MB;
  then gfx3 and gfx4 to **38 MB**.
- opengolf: tile_base 4 MB; obj_base 14 MB; sprites to 26 MB; sound to about 30.7 MB; gfx3 and
  gfx4 to **45 MB**.

Both need the 64 MB module (or 128). Neither fits 32 MB, even raw for golf.

## 6. Flags (gx.cpp:4210-4215)
- racinfrc/racinfrcu: IMPERFECT_GRAPHICS | NODEVICE_LAN. They were promoted to working in
  bdf269a2ddf.
- opengolf, opengolf2, ggreats2: IMPERFECT_GRAPHICS | NOT_WORKING. **The source states no
  reason.** Related loose ends in the source:
  - "TODO: enabling ASSERT_LINE breaks opengolf" (gx.cpp:656);
  - the two-origin phase handling is golf-only;
  - opengolf's AN0/AN1 are unused;
  - trackball ports are not mapped;
  - ggreats2's 3P/4P TODO.
  Unverified which of these keeps them NOT_WORKING.

## 7. Against the core

| Feature | Core today | Reuse / new |
|---|---|---|
| Main map | gx_main.sv decodes Type 2 and T34 ranges (gx_main.sv:871-1036); T34's e00000/e40000/e60000/ec0000/f00000 decode differently | New Type 1 decode. The ESC must be off (no cc0000) |
| Palette 0xd90000 | Type 2 888 path, gx_mixer palette (gx_main.sv:1029-1035) | Reusable. **Conflict:** the core keeps the x byte as RAM ("the RAM test checks it", gx_main.sv:360-363), while MAME masks it to 0 on read: "Racin' Force relies on this when reusing a register from palette fading to calculate the sky's Y scroll" (gxv.cpp:1735-1739) |
| K056832 6bpp / 5bpp, layer offs | tile_bpp, offs_x/offs_y per set (gx_board_cfg.sv) | Reusable; new arm values (y -16 racinfrc) |
| Sprites GX / GX6 | obj_layout 0/2 | Reusable. racinfrc dy -34 vs -23: VOFFSET is a fixed gx_video parameter (gx_video.sv:41), so a per-set y adjust is new |
| K053936 | gx_psac.sv: line mode, line-control read, ax/ay stepping, 4 SDRAM tile ports + 8 KB direct-mapped cache, 2-clock/pixel draw, line buffer of 288/384 cols | Partly reusable (lc read, stepping, cache/dispatcher). New: offsets 0 (not 30/36), no `^1`, row-order 128x128 map of 2-long entries in RAM (not ROM column order / 1 word), 2 outputs per sample (HROM 6bpp + CROM 6/8bpp), 3/4-byte nibble-planar decode, flips per tilemap, 512 cols and rows line+14 |
| PSAC4 renderer | none | New: LRAM, lookup, projection, column fill, frame store (see 8) |
| Mixer SUB2 | cand[5] with fixed key lpri5, pen 0x1000/0x1800, layer wins ties (class bit 0 < sprite's 1) (gx_mixer.v:200-244) | New: per-pixel 8-bit priority masked by reg 21, OBJ-wins-tie for SUB2, pen 0x000-0xfff, per-pixel mix bit to the K054338 level |
| ADC0834 + steering/pedal | none (MiSTer analog sticks only feed the guns) | New: serial ADC at dda000/ddc000 |
| Lamp, 056230 RAM | none | Trivial |
| RAM | release builds: KonamiGX 533/553 M10K, KonamiGXT34 542/553 (README) | New RAMs: psacram 128 KB (about 128 M10K), K053936 linectrl 8 KB, LRAM 4 KB, lookup 2 KB, LAN 8 KB. Does not fit either build as is |
| SDRAM | Type 2 assumes 32 MB | 64 MB (section 5) |

## 8. PSAC4 work estimate (not measured)

Clocks: clk_vid 48 MHz (KonamiGX.sv:7-9), clk_sys 96 MHz for SDRAM.
- An 8 MHz line is 512 dots x 6 = 3,072 clk_vid (a 6 MHz line of 384 dots is the same).
- A frame is 264 lines = 811,008 clk_vid.
- Vblank is 40 lines = 122,880 clk_vid.
- Which dot clock racinfrc programs into the CCU is unverified. MAME's raw screen is 8 MHz for
  both.

Work per frame, only visible columns (racinfrc 288 x 255 LRAM lines, golf 384 x 480):
- **Samples:** 73,440 for racinfrc, 184,320 for golf. MAME computes 512 columns
  (130,560 / 245,760). Each sample needs:
  - one CROM pixel (from a 3- or 4-byte group);
  - one HROM pixel (3-byte group);
  - the VRAM entry (2 longs, shared across a 16-texel run);
  - one 8x16 multiply (level*scale), a shift, compares against ground/limit[x].
- **Per line:** 1 LRAM long, 4 K053936 line-control words, 1 lookup byte, and the K053936 start
  (2 adds).
- **Writes:** at most one per screen pixel, since the spans in a column never overlap (limit only
  falls), plus scale==0 points. That is at most 64,512 (288x224) or 86,016 (384x224) writes of
  {pen 12 bits, priority 8 bits}.
- **Not raster order:** each column is filled front to back across all LRAM lines. A pixel's
  value is the first line l with top_l(x) <= y, so it cannot be produced at scan time without
  every line's top. That means a frame store:
  - double-buffered, 20 bits a pixel: 2.58 Mbit (racinfrc) or 3.44 Mbit (golf), about 260-345
    M10K. That is beyond block RAM, so DDR3 or SDRAM.
  - The board's 12x M514256 DRAM (gx.cpp:3779-3797 layout) is consistent with this. MAME
    leaves "the DRAM pipeline" unemulated.
- **Clock budget:** rendering over a whole frame gives about 11 clk_vid a sample for racinfrc
  and about 4.4 for golf. Within vblank only, it is 1.7 or 0.67, which is not feasible.
  - MAME renders from the state at vblank start, so rendering during the frame needs psacram,
    LRAM, lookup and regs snapshotted or double-buffered, or it reads newer CPU data.
  - Which one the board does is unknown.
- **ROM bandwidth:**
  - Near lines are magnified (many samples per 8-byte granule). Far lines are minified: up to one
    CROM and one HROM granule miss per sample, plus a VRAM entry once the step passes 16 texels.
  - Worst case is 2 SDRAM fetches a sample: about 147k/frame (racinfrc) or 369k (golf).
  - gx_psac's 4-port pipeline does 216 fetches a 288-column line in at most 4,341 clocks at
    12 clk/fetch (docs/TYPE34.md), roughly 3-12 clk a fetch with overlap.
  - Taking about 3 clk: racinfrc worst ≈ 440k clk (fits a frame), golf worst ≈ 1.1M (does not,
    unless the cache hit rate passes about 30%).
  - These numbers are guesses. A Python model of type1_draw_terrain on dumped frames (as
    psac2_model.py did for Type 3) would give real fetch counts per line.
