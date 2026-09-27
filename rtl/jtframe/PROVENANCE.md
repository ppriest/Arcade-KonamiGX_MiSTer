# jtframe helper modules provenance

Small shared primitives from <https://github.com/jotego/jtcores> at commit
`e7958c86d79d549cf5b14b7bbdb517b109a21691`, path `modules/jtframe/hdl/`. **Verbatim except two
files** (see "Local changes").

| file | pulled in by |
|---|---|
| `jtframe_edge.v` | K053252 |
| `jtframe_count_ld.v` | K053252 |
| `jtframe_ff_jk.v` | K053252 |
| `jtframe_dual_ram.v` | K056832 tilemaps, K053246/K055673 sprites |
| `jtframe_dual_nvram.v` | K056832 tilemaps, K053246/K055673 sprites |
| `jtframe_dual_ram16.v` | K053246/K055673 sprites |
| `jtframe_dual_nvram16.v` | K053246/K055673 sprites |
| `jtframe_8x8x4_packed_msb.v` | K053246/K055673 sprites |
| `jtframe_obj_buffer.v` | K053246/K055673 sprites |
| `jtframe_objdraw.v` | K053246/K055673 sprites |
| `jtframe_objdraw_gate.v` | K053246/K055673 sprites |
| `jtframe_draw.v` | K053246/K055673 sprites |

The last four are not primitives. They are jotego's **object-drawing pipeline**, and taking the
sprite chip means taking them — see [`../video/k055673/PROVENANCE.md`](../video/k055673/PROVENANCE.md)
for why that is a fit for this project rather than an accident.

The closure was resolved by `verilator --lint-only`, which names missing modules, rather than by
grepping for instantiations: jotego writes multi-line instances whose module name and instance name
are on different lines, and a grep pass missed `jtframe_dual_nvram` completely.

SPDX headers: `GPL-3.0-or-later`. See [`../../THIRD-PARTY.md`](../../THIRD-PARTY.md).
`.gitattributes` marks this directory `-text`.

They live here rather than beside the K053252 because the other jotego modules this project plans
to vendor — `jt05415x` (tilemaps) and `jt053246` (sprites) — draw on the same set. Add to this
directory as each lands, and record what pulled it in.

**Only what is instantiated by vendored RTL belongs here.** jtframe modules a *bench* needs and the
design does not (`jtframe_frac_cen`, `jtframe_vtimer`, `jtframe_test_clocks`, `test_tasks.vh`) are in
`sim/jtframe_ver/` instead, so they never reach `files.qip` and never reach a bitstream.

This is not a vendoring of jtframe. It is the handful of files the vendored chip modules need, taken
one at a time. Pulling in jtframe wholesale would bring a framework this project does not use and
does not want — `sys/` is the framework here.

## Local changes

Two files are **modified**, with the GPL-3.0 §5(a) notice after jotego's header, changed lines
marked `[GX]`, and the unmodified file beside each as `<name>_upstream_reference.v`. With the new
parameters at their defaults both behave exactly as upstream.

| file | change | why |
|---|---|---|
| `jtframe_draw.v` | `BPP` parameter, 4 (default) or 5: `rom_data` is `8*BPP` bits, one plane per byte, and the pixel takes one bit from each byte | K055673_LAYOUT_GX sprites are 5 bpp |
| `jtframe_draw.v` | `FIRST_PX` parameter, 0 (default) or 1: when reducing, write only the first source pixel that lands on each buffer address | Upstream writes every source pixel and its buffer keeps the last. MAME samples `(x * step) >> 19`, which is the first of each group. With a keyed buffer that keeps the first *opaque* one, frame 3600's half-size sprites drew 16 shadow pixels MAME does not |
| `jtframe_draw.v` | `PAIR` parameter: an unzoomed, untruncated tile draws two pixels a clock (`buf_we2`/`buf_din2` at `buf_addr + 1`) | One pixel a clock plus the fetch handshake was about 22 clocks a tile; dragoonj's busiest lines (~125 tiles) ran out of the 3072-clock line |
| `jtframe_objdraw_gate.v` | `BPP` and `FIRST_PX` passed through; `KEYW` parameter: when non-zero the line buffer is [`../video/gx_obj_linebuf.v`](../video/gx_obj_linebuf.v) instead of `jtframe_obj_buffer` | the per-pixel `{z-code, priority}` order GX needs. `jtframe_obj_buffer`'s `KEEP_OLD` path reads and writes through one RAM port, so a pixel takes two clocks, and on `daiskiss` frame 4800 (145 sprites) `jt053246_scan` then ran out of line time on 94 lines and dropped every sprite after table entry 0xb0. The GX buffer gives each line half its own RAM and runs at one pixel per clock |
| `jtframe_objdraw_gate.v` | `PAIR` parameter: jtframe_draw's second pixel (`buf_we2`/`buf_din2`) to gx_obj_linebuf's second write port, at the next address | Two pixels a clock for unzoomed tiles; the buffer's even and odd banks take one each |

`jtframe_obj_buffer.v` itself is unmodified.
