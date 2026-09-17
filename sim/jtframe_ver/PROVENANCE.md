# jtframe bench-only support

From <https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`.
**Verbatim**, GPL-3.0-or-later.

| file | upstream path |
|---|---|
| `jtframe_frac_cen.v` | `modules/jtframe/hdl/clocking/jtframe_frac_cen.v` |
| `jtframe_vtimer.v` | `modules/jtframe/hdl/video/jtframe_vtimer.v` |
| `jtframe_test_clocks.v` | `modules/jtframe/hdl/ver/jtframe_test_clocks.v` |
| `test_tasks.vh` | `modules/jtframe/ver/inc/test_tasks.vh` |

These are needed by jotego's unit benches and by **nothing in the design**. They are kept out of
`rtl/` and out of `files.qip` deliberately, so they cannot reach a bitstream. `scripts/run_jt_unit.sh`
passes `-I sim/jtframe_ver` for the include file.

Design-side jtframe primitives are in `rtl/jtframe/` instead.
