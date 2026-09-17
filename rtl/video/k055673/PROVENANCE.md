# K053246/K055673 (sprite generator) provenance

From <https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`,
path `cores/simson/hdl/`. **Verbatim**, GPL-3.0-or-later by their SPDX headers. See
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
