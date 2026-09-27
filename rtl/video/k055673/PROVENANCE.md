# K053246/K055673 (sprite generator) provenance

From <https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`,
path `cores/simson/hdl/`. **Verbatim except three files** (see "Local changes"), GPL-3.0-or-later
by their SPDX headers. See
[`../../../THIRD-PARTY.md`](../../../THIRD-PARTY.md); `.gitattributes` marks this directory `-text`.

| file | role |
|---|---|
| `jt053246.sv` | the sprite controller: list scan, zoom, position, ROM address generation |
| `jt053246_mmr.v` | its registers. jotego **commits** this one, unlike the K053252's |
| `jt053246_scan.sv` | the list walker |
| `jt053246_dma.v` | the object-RAM DMA |
| `jtsimson_obj.v` | the wrapper joining the above to the drawing pipeline |

## Why this is the right module for a K055673

MAME's `k055673_device` derives from `k053247_device`: the K055673 is the 5-8 bpp, wider-ROM
variant of the same sprite pair, not a different chip. jotego's `cores/rungun` drives a real
K055673 with exactly these files, which is the evidence that the pairing works — Run and Gun's
`files.yaml` lists `jt053246.sv`, `jt053246_scan.sv`, `jt053246_dma.v`, `jt053246_mmr.v` and
`jtsimson_obj.v` from `simson`.

**What Run and Gun does not exercise is the colour depth.** `rungun.cpp` sets
`K055673_LAYOUT_RNG`, which is 4 bpp. Konami GX uses four layouts across its game list:

| layout | bpp | GX sets |
|---|---|---|
| `K055673_LAYOUT_GX` | 5 | gokuparo, fantjour, crzcross, tbyahhoo, sexyparo, daiskiss, tokkae, racinfrc |
| `K055673_LAYOUT_GX6` | 6 | salmndr2, opengolf, and the Type 3/4 sets |
| `K055673_LAYOUT_LE2` | 8 | le2, winspike |
| `K055673_LAYOUT_RNG` | 4 | dragoonj — the one depth jotego's use covers |

So the depths above 4 bpp are this project's extension work, and they are the first thing to check
against the Phase 1 software model. The 5 bpp case is the awkward one: MAME **assembles** that
region at runtime from a 4 bpp region plus a separate 1 bpp region
(`k053246_k053247_k055673.cpp`, `K055673_LAYOUT_GX`), so the `.mra` has to produce what the RTL
expects and the RTL has to expect what the chip reads. LESSONS_LEARNED's "*A hardware-vs-image
comparison cannot detect a wrong image*" applies directly.

## The jtframe footprint this brings with it

Unlike the K053252, which needed three small primitives, the sprite path pulls in **nine** jtframe
files, and some are a pipeline rather than a primitive: `jtframe_objdraw`, `jtframe_objdraw_gate`,
`jtframe_draw` and `jtframe_obj_buffer` are jotego's object-drawing framework. They are vendored in
[`../../jtframe/`](../../jtframe/PROVENANCE.md).

That is a design decision, not just a file copy: it means the GX sprite plane is built on the shape
of jotego's object pipeline — a line-based engine with a line buffer — rather than a from-scratch
one. That happens to be what this project's RAM budget requires anyway (see `docs/ROADMAP.md`,
"On-chip RAM budget": a frame buffer does not fit, and the chip is line-based), so it is a fit. But
it should be a known commitment rather than something discovered later.

The closure was resolved by lint rather than by grep — jotego writes multi-line instantiations whose
module name and instance name are on different lines, and a first pass by grep missed
`jtframe_dual_nvram` entirely. `verilator --lint-only` reports missing modules by name; the set
below resolves with none left over.

## Verification

Upstream ships **no unit bench** for these modules — `cores/rungun/ver/objdump` is an NVRAM test,
unrelated. So unlike the K053252 there is no differential regression to inherit, and the regression
here is this project's own: the Phase 1 software model of `konamigx_v.cpp`, checked pixel-exact
against MAME captures first, then the RTL checked against the model.

Analysis under Quartus 17.0.2 is checked by the staged build.

## Local changes

Three files are **modified**; the rest are verbatim. Each modified file carries the GPL-3.0 §5(a)
notice after jotego's header, its changed lines are marked `[GX]`, and the unmodified upstream
file sits beside it as `<name>_upstream_reference.<ext>`, so the whole change is

```
git diff --no-index rtl/video/k055673/jt053246_dma_upstream_reference.v rtl/video/k055673/jt053246_dma.v
```

(`scripts/run_sim.sh` skips `*_upstream_reference.*`, and `files.qip` does not list them.)

| file | change | why |
|---|---|---|
| `jt053246_dma.v` | `GX_ORDER` parameter: copy the first 256 sprites (words 0–2047) in RAM order, instead of into the table slot named by each sprite's priority byte | The slot sort keeps one sprite per priority value. `daiskiss` gives many sprites the same z-code — 35 sprites on 2 values on its title frame — and scored in software the slot sort kept 2 of them. jotego's README calls the sort "this implementation"; its PCB measurements are of the DMA's duration only. Ordering moves to the line buffer (below). |
| `jt053246_scan.sv` | outputs `zcode` (word 0 bits 7:0), `attr_full` (word 6 as scanned) and `obj_idx` (the table index, latched with `zcode`); `HADJ` made a parameter | the line buffer's key needs the z-code; GX's colour callback and `primode` filter need word 6 bits 10–15; the mixer ranks a sprite against a shadow by index, as MAME's order does. `obj_idx` must be latched: `scan_obj` advances in the same step that issues a multi-tile sprite's last draw, and read live it was one high on 60% of frame 6000's sprite pixels. `HADJ` is a Simpsons-specific shift for sprites starting left of `hdump` 0x20; GX runs with 0 |
| `jt053246_scan.sv` | outputs `pf_on`/`pf_code`: the tile the drawer will be given next | the SDRAM behind the sprite ROM answers in 10 clocks and `jtframe_draw` has eight to spare, so every row waited for memory before its first pixel and the scan ran out of line time on 32 of 234 lines (`docs/ROADMAP.md`). The scan already computes the next tile of a sprite one step early (`hcode + hsum`), so `gx_rom_port` fetches it in the idle time it has. No line runs short with it |
| `jt053246_scan.sv`, `jt053246.sv` | the scan steps every clock instead of every other (`cen2`); the scan RAMs' read port is clocked on the falling edge, so a word is there half a clock after its address; two wait steps keep the visibility test four clocks after step 2, where the zoom pipeline has it; the draw state is 7, `pf_on` only there | a candidate entry cost 10 clocks and Sexy Parodius's player select scans ~210 of its 256 entries a line: the scan alone took ~2100 of 3072 clocks and 54 lines ran short in `sim/gx_obj_tb`. Now 7 clocks (1 for an empty entry): every line finishes, and the sprite pixels on ten captures are unchanged |
| `jt053246.sv` | passes `GX_ORDER`, `HADJ`, `zcode`, `attr_full`, `obj_idx`, `pf_on`, `pf_code` through | plumbing |
| `jt053246.sv` | `GX_DMA_ALWAYS` parameter: the DMA runs whatever OBJSET1 bit 4 (DMAEN) says | MAME's GX mixer draws the K053247 RAM itself (`konamigx_mixer_init(screen, 0)`), so DMAEN has no effect there; `tokkae` runs with DMAEN clear and sprites on screen. |

`jtsimson_obj.v` is **not used by GX**, and differs only by tying off the two new scan outputs. Its GX counterpart is
[`../gx_obj.v`](../gx_obj.v), derived from it and saying so in its header: GX's sprite callback
(VRC code banks, colour and priority through the K055555 fields), `konamigx_mixer`'s solid/shadow
split and `primode` 4 filter, 5 bpp, and the line buffer with a `{z-code, priority}` key —
[`../gx_obj_linebuf.v`](../gx_obj_linebuf.v), written for this project. It has two planes. The
solid plane keeps the lowest `{z-code, priority}`, first written winning a tie. The shadow plane
keeps the *highest* `{shadow priority, z-code}`, last written winning a tie, because MAME draws
shadows back to front and its shadow z-buffer lets the first one drawn stand (`docs/MAME_KLUDGES.md`).

**Result.** `scripts/check_gx_obj.py <capture>` runs `sim/gx_obj_tb` (Verilator by default,
`--sim modelsim` for the four-state run) and compares every pixel with the model. Solid plane:
valid bit, pen, priority and sprite index. Shadow plane: valid bit, sprite, shadow code and mode.
Both planes match on `daiskiss` title, 2400, 3600, 4800 and 6000, **64,512 of 64,512 each**. That
includes 570 shadow pixels on frame 3600 and 12,302 on frame 6000, and no line on which the list
scan fails to finish. Frames 3600 and 6000 were also run on ModelSim with the same result. `voffset` 281 and `HOFFSET` 62 place bitmap row 16 at `vdump` 0x110 and bitmap column 24 at
`hdump` 0x70 in the bench's timing; the real values come with the K053252 setup.

**A timing constraint for that setup:** `jtframe_objdraw_gate` reads the line buffer through a
counter (`HFIX`) that re-synchronises to `hdump` only while `hs` is high, so `hs` must span
`hdump`'s wrap. With `hs` placed before the wrap, the bench drew every sprite and displayed none.

### `jt053246_scan.sv`: the vertical mirror decided in step 4

A sprite with the vertical-mirror bit (word 6 bit 15) draws its second half flipped. Upstream sets
`vflip` in step 3 from `ydiff`, but `ydiff` comes through a two-register pipeline (`ydiff_b`,
`yz_add`) that is only valid by step 4, where the tile row is added to the code; so the flip
switched some lines away from the sprite's midpoint. On Twin Bee's full-screen shadow sprite
(zoomed 3.2x vertically) that was a 16-line band of the wrong tile row. The flip is now set in
step 4, from the latched mirror bit, with the row taken from the same flip. With the global Y
flip (`gvf`, always set on GX) `ydiff` counts rows from the other end, so the mirrored half is the
one with the row's top bit set; the upstream polarity is kept for `gvf` clear. Checked on the
sprite bench (tbyahhoo-f3200 with DMAEN set: solid pixels 64,229 to 64,512 of 64,512) and on
the video bench (Daisu-Kiss frames 300-6000 unchanged, 64,512 of 64,512 each).

### `jt053246_dma.v`: `dma_hold`

The sprite DMA waits while this core's ESC is still writing the sprite list. MAME's ESC runs in no
time, so its copy never sees a half-built list; this one takes SDRAM time, and on the board the
copy began during it hundreds of times a second (probe J, `dma_during_esc`). `gx_main.sv` holds
the copy off while `esc_busy` and pulses `dma_trig` when the ESC finishes, so a frame gets a whole
list a little late rather than half of the last one and half of this one.
