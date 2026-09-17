# K054338 (alpha blender) provenance

`jt054338.v`, vendored from <https://github.com/jotego/jtcores> at commit
`e7958c86d79d549cf5b14b7bbdb517b109a21691`, path `cores/moo/hdl/jt054338.v`.

SPDX header in the file: `GPL-3.0-or-later`, `SPDX-FileCopyrightText: 2026 Jose Tejada Gomez`.
Direct into this project's GPL-3.0-or-later; see [`../../../THIRD-PARTY.md`](../../../THIRD-PARTY.md).

**Verbatim.** No changes. `.gitattributes` marks this directory `-text` so the bytes round-trip
exactly and `git log -p` stays an exact record of any future divergence.

## Why this module, and why it was straightforward

The K054338 is one of the eight custom chips on a Konami System GX board, at `0xd80000` in
`gx_base_memmap`. It is the same part Wild West C.O.W.-Boys of Moo Mesa uses, which is why an
implementation existed to take.

It is **self-contained**: 81 lines, no submodule instantiations, and no dependency on jotego's
generated register-map files. That is unusual among the modules this project wants — see "The MMR
problem" below — and it is why this one could be vendored before that question was settled.
(`dump_mmr` in its port list is a signal name, not a module reference.)

## What it provides, against what GX needs

| upstream port / parameter | GX's use |
|---|---|
| `ALPHA_INV` parameter | `konamigx.cpp` calls `m_k054338->set_alpha_invert(1)`, so this is set |
| `cs`, `we`, `addr[3:0]`, `din[15:0]`, `dsn[1:0]`, `dout[15:0]` | the 16 registers at `0xd80000`–`0xd8001f` |
| `pblend[1:0]`, `shadow[1:0]` | from the K055555, which this project has to write |
| `bg_rgb[23:0]`, `video_en`, `alpha_level[7:0]`, `alpha_add` | the mixer output path |
| `mixpri`, `shdpri`, `brtpri`, `clipsl` | priority modifiers the GX mixer reads |
| `shadow_r/g/b` (signed 10-bit) | the shadow offsets `konamigx_mixer()` applies |

`K338_REG_BRI3` and `K338_REG_CONTROL`, which `konamigx_precache_registers()` reads, are `BRI3 = 11`
and `CONTROL = 15` in this module's `localparam` block — the same offsets.

**Not yet checked**: GX's palette is 24-bit `xRGB_888`, while Moo Mesa's is 5 bits per channel and
`jtmoo_colmix.v` widens it with a `conv58` function before this module's shadow offsets are applied.
Where that conversion belongs in a GX mixer is a Phase 1 question, and it is the first place to look
if shadows come out wrong.

## Verification

Upstream ships no standalone testbench for this module; it is exercised through the Moo Mesa core.
Per [`../../../docs/WORKFLOW.md`](../../../docs/WORKFLOW.md) §12, the regression here is therefore
this project's own: the Phase 1 software model of `konamigx_v.cpp` renders captured frames, and this
module is checked against the model's shadow, brightness and blend results.

Analysis under Quartus 17.0.2 is checked by the staged build; nothing instantiates it yet, so that
is an analysis check and not a synthesis one.

## The MMR problem, for whoever vendors the next jotego module

Most of the modules this project wants instantiate a `*_mmr` register-decode module that upstream
**generates** with `jtframe mmr <core>` from `cfg/mmr.yaml`, rather than checking in. Of the files
needed here:

| module | generated MMR needed | in upstream's tree |
|---|---|---|
| `jt054338.v` | no | — |
| `jt053246.sv` (sprites) | `jt053246_mmr.v` | **yes**, checked in |
| `jtk053252.v` (CRTC) | `jtk053252_mmr.v` | **no**, generated |
| `jt05415x.v` (tilemaps) | `jt054156_mmr.v`, `jt054157_mmr.v` | **no**, generated |

`jtframe` is a Go program and there is no Go toolchain on this machine, so those two cannot be
generated here as things stand. The options, and the tradeoff, are recorded in
[`../../../docs/ROADMAP.md`](../../../docs/ROADMAP.md) under "Open items".
