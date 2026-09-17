# jtframe helper modules provenance

Small shared primitives from <https://github.com/jotego/jtcores> at commit
`e7958c86d79d549cf5b14b7bbdb517b109a21691`, path `modules/jtframe/hdl/`. **Verbatim.**

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
