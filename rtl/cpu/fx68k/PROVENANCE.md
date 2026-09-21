# fx68k provenance

Cycle-accurate 68000, Copyright (c) 2018, 2021 Jorge Cwik. GPLv3 (`LICENSE`).
Upstream: https://github.com/ijor/fx68k.

The sound CPU (Phase 3a, `rtl/sound/gx_sound.sv`). It replaced TG68K.C there:
Seta's `sim/tg68k_pace_tb` measured TG68K running a `nop; dbra` loop in 4
clock enables an iteration against the 68000's 14, and here the sound program
answered the main CPU's power-on handshake visibly sooner than MAME's does. The
main CPU stays TG68K.C: it is a 68EC020, which fx68k does not implement.

## Chain of custody

| Stage | What |
|-|-|
| Upstream | ijor/fx68k |
| Then | `Arcade-SegaXBoard_MiSTer-1.0.0/rtl/cpu/fx68k/` |
| Then | `Arcade-Seta_MiSTer/rtl/cpu/fx68k/`, with the local change below |
| Here | copied from that Seta tree unchanged |

`microrom.mem` and `nanorom.mem` match the SHA-1s Seta records for the
SegaXBoard copy (62036424..., a1f291b6...).

## Local changes

Seta's, carried here: the two `$readmemb` paths in `fx68k.sv` are relative to
the project root (`rtl/cpu/fx68k/microrom.mem`, `nanorom.mem`), where both
Quartus (the `build/` worktree) and the simulation scripts run.

And one of this project's, for Verilator: the three structs in `fx68k.sv`
(`s_clks`, `s_irdecod`, `s_nanod`) are declared `packed`. `Nanod` is driven
both by continuous assigns and by an `always_ff`, which Verilator refuses for
an unpacked struct ("BLKANDNBLK: Unsupported"); every field is a `logic`, so
packing them changes nothing else, and Quartus accepts either. Seta never met
this because it only simulates fx68k in ModelSim; the board bench here runs
it under Verilator, where ModelSim would take hours for the frames needed.
Marked `[GX]` on each line.
