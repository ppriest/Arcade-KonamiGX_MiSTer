# gx_tilemap standalone synthesis

A Quartus project holding `rtl/video/gx_tilemap.sv` (and `gx_sdpram.sv`) and nothing else. Inputs
come from a shift-register chain and outputs are XOR-reduced into a register, so every path starts
and ends on a flop; pins are virtual.

```
cd rtl/synth_check/gx_tilemap
quartus_sh --flow compile gx_tilemap_synth -c gx_tilemap_synth     # after scripts/hwlock.py --require-no-jtag
```

## Result

5CSEBA6U23I7, Quartus 17.0.2, `HIGH PERFORMANCE EFFORT`, seed 1, constrained at 48 MHz
(`gx_tilemap_synth.sdc`):

| | |
|---|---|
| Fmax, slow 1100 mV 100 °C | **117.72 MHz** (setup slack +12.3 ns at 48 MHz) |
| ALMs | 454 |
| registers | 999 |
| block memory bits | 1,093,632 — VRAM 1,048,576 + line buffers 45,056, nothing duplicated |
| M10K | 136 (VRAM 128, line buffers 8) |

The synthesis RAM summary lists exactly four 32K × 8 lanes and four 1K × 11 line buffers, all
simple dual-port. The 8-byte tile-bank table is logic on purpose (`ramstyle "logic"`: it is read
combinationally).

## What it took to get there

Three versions of the memories did not synthesize as intended; each finding is in
`docs/LESSONS_LEARNED.md` ("[GX] Quartus 17 infers RAM only from the plain template"):

1. VRAM as one packed `[3:0][7:0]` array with byte enables and two read ports: reported
   "uninferred due to asynchronous read logic" (276007) and failed with 276003.
2. Four byte-lane arrays with two read ports each: inferred, but every lane duplicated, one copy per
   read port — 2 Mbit.
3. Line buffers as arrays inside a `generate` loop driving an output-port array element: not
   inferred, ~24K ALMs of logic and 46K registers, with no inference message naming them.

What worked: every memory is an instance of `gx_sdpram` (the textbook one-write, one-read template
in a module of its own), and the VRAM has one read port shared by CPU reads and the tile fetcher.
