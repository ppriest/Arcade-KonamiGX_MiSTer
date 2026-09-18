# Video blocks, standalone synthesis

`gx_tilemap`, `gx_obj` (jotego's `jt053246` pipeline with the GX changes) and `gx_mixer` in one
Quartus project, wired to each other as the core will wire them (tile and sprite pixels into the
mixer). Inputs come from a shift-register chain, outputs are XOR-reduced into a register, pins are
virtual.

```
cd rtl/synth_check/gx_video
quartus_sh --flow compile gx_video_synth -c gx_video_synth     # after scripts/hwlock.py --require-no-jtag
quartus_sta -t worst.tcl                                       # ten worst setup paths -> worst_paths.txt
```

## Result

5CSEBA6U23I7, Quartus 17.0.2, `HIGH PERFORMANCE EFFORT`, seed 1, constrained at 48 MHz:

| | |
|---|---|
| Fmax, slow 1100 mV 100 °C | **67.65 MHz** (setup slack +6.05 ns at 48 MHz) |
| ALMs | 1,554 |
| registers | 2,795 |
| block memory bits | 1,524,224 — the arithmetic sum of every memory below, nothing duplicated |
| M10K | 188 |
| DSP | 4 |

| memory | shape | bits |
|---|---|---|
| tilemap VRAM, 4 byte lanes | 32K × 8 each | 1,048,576 |
| tilemap line buffers, 4 layers | 1K × 11 each | 45,056 |
| palette (`gx_mixer`) | 8K × 24 | 196,608 |
| sprite RAM (`gx_obj`) | 4K × 16, true dual-port | 65,536 |
| `jt053246` scan table | 2 × 1K × 16 | 32,768 |
| sprite line buffer, solid plane | 2 × 1K × 37 | 75,776 |
| sprite line buffer, shadow plane | 2 × 1K × 28 | 57,344 |
| `jt053246_scan` zoom tables (ROM) | 2 × 256 × 5 | 2,560 |

Quartus prints "uninferred due to asynchronous read logic" (276007) for the four halves of
`jt053246`'s scan table on a first pass, then infers them as simple dual-port RAMs; the RAM summary
above is what it built.

The first fit ran at 52.96 MHz. Its worst paths ran from the tilemap's line-buffer RAM output
through `gx_mixer`'s whole ranking in one clock. The mixer now registers its pixel inputs on
`pxl_cen` and ranks on the next clock, which uses all six clocks a GX pixel has at 48 MHz. The
worst path is now the mixer's shade–blend–shade chain into `rgb`.

None of this is the full core: the CPU, SDRAM and framework are not in it. The in-design numbers
come from the staged build.
