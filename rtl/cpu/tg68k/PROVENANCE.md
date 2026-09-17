# TG68K.C provenance

The 68EC020 main CPU, vendored from <https://github.com/TobiFlex/TG68K.C> at commit
`ade33e396a1e647c2de9daf71ff9d5b3979639b2` (2025-03-24).

Copyright (c) 2009-2020 Tobias Gubener, with patches by MikeJ, Till Harbaum, Rok Krajnk and others;
subdesign fAMpIGA by TobiFlex. **LGPL-3.0-or-later**, stated in each file's own header block — there
is no separate `LICENSE` file upstream. LGPL-3 into this project's GPL-3.0-or-later is direct; see
[`../../../THIRD-PARTY.md`](../../../THIRD-PARTY.md).

`UPSTREAM_README.md` is upstream's `README.md`, kept verbatim.

## What was taken, and its state

| file | in `files.qip` | in `run_sim.sh` | state |
|---|---|---|---|
| `TG68K_Pack.vhd` | yes | yes (vcom, first) | **verbatim** |
| `TG68K_ALU.vhd` | yes | yes (vcom) | modified — see "Changes" |
| `TG68KdotC_Kernel.vhd` | yes | yes (vcom) | modified — see "Changes" |
| `TG68K.vhd` | **no** | **no** | verbatim, reference only |

All four were taken byte-identical to upstream in the commit that added this directory, so
`git log -p` on this directory is an exact record of every divergence from upstream.

### Why `TG68K.vhd` is here but not built

`TG68K.vhd` is not the CPU. It is an **async-68000-bus adapter** that wraps the kernel in a
bus-protocol emulator assuming `CLK` *is* the CPU clock — hence its `falling_edge` registers
(`as_e`, `rw_e`, `uds_e`, `lds_e`, `clkena_e`, `data_akt_e`, `cpuIPL`, `waitm`, `E`). This project
instantiates `TG68KdotC_Kernel` directly and owns the bus interface, which is what
`Arcade-Psikyo_MiSTer` arrived at after trying the wrapper first; its `docs/LESSONS_LEARNED.md`
entry "Instantiate `TG68KdotC_Kernel` directly and own the bus interface" is the chain of failures
that caused, and it is carried in this repository's copy of that file.

It is kept in the tree unbuilt because its DTACK state machine is the authority on what the kernel
expects, and the wrapper this project writes is derived from reading it. Deleting it would mean
re-fetching it every time that question comes up.

`CPU` generic: `"00"` = 68000, `"01"` = 68010, `"11"` = 68020. **Konami GX needs `"11"`.**

## Changes made here

Every change is listed. GPLv3/LGPLv3 §5(a) requires a modified file to state prominently that it was
changed and when; each file below carries that notice in its own header, and those notices are
licence terms rather than comments to tidy away.

| files | what |
|---|---|
| `TG68K_ALU.vhd`, `TG68KdotC_Kernel.vhd` | explicit zero initializers on signal declarations — see below |
| `TG68K_Pack.vhd`, `TG68K.vhd` | none; verbatim |

### Explicit zero initializers

VHDL signals without an initial value start as `'U'` in a four-state simulator and as zero in real
hardware. Left alone, the `'U'` propagates as a permanent `'X'` through the ALU's arithmetic
datapaths from time zero and never clears, even after reset. `Arcade-Psikyo_MiSTer` hit this and
recorded it: sustained per-cycle X propagation produced enough warnings to exhaust memory and take
ModelSim down with a SIGSEGV. It matches upstream issue
<https://github.com/TobiFlex/TG68K.C/issues/21>, whose reporter identified the same class of signal
and fixed a subset of them.

The fix applied here covers the whole declarative region rather than guessing at a sufficient
subset, because it is zero-risk: an initial value only affects a signal before its first real write,
and hardware already powers these to zero. It is a **simulation-fidelity fix, not an algorithm
change** — the diff is `:= (others => '0')` and `:= '0'` on declarations and nothing else.

`TG68K_Pack.vhd` needs none and stays verbatim.

The change was **replayed onto upstream's bytes rather than copied from Psikyo's files**, because
Psikyo's copies have uniform CRLF where upstream has mixed CRLF and LF: copying them wholesale made
the Kernel read as 6,924 changed lines instead of 220, which would have buried the one real change.
The result was then checked to be content-identical to Psikyo's proven copies (`diff
--strip-trailing-cr`, no differences) and every added line checked to be an initializer, a comment or
blank.

`.gitattributes` marks this directory `-text` so git stores and checks out these bytes unchanged.
Without it `core.autocrlf` normalises on commit, and the two mixed-ending files silently become
uniform — which would make "verbatim at `ade33e39`" unverifiable.

## Integration notes carried from `Arcade-Psikyo_MiSTer`

That project ran this core as a 68EC020 at 16 MHz and its
`rtl/cpu/tg68k/PROVENANCE.md` and `rtl/cpu/maincpu.sv` are the reference. What to know before
writing the bus wrapper here:

- **`clkena_in` is the only correct way to slow the kernel down.** The kernel is entirely
  rising-edge (verified upstream: zero `falling_edge` occurrences) and exposes `clkena_in` for
  exactly this. Adding an external enable to `TG68K.vhd` and gating every clocked process was tried
  on Psikyo and failed: the two clock edges need two separate enables, and the timing report then
  needs a `set_multicycle_path` to accept the result. `mist-devel/plus_too`'s `tg68k.v` is the
  canonical example of doing it the right way.
- **Fmax is the constraint on `clk_sys`, not on the CPU rate.** Under `clkena_in` the kernel is
  clocked at `clk_sys` and merely *enabled* at the CPU rate. Psikyo measured **48.74 MHz** on the
  real post-fit netlist, Cyclone V speed grade 7, with all fifty worst-slack paths inside
  `TG68KdotC_Kernel` — the `altsyncram` register file and the `regfile_rtl_*_bypass` network. This
  is why the roadmap plans a separate `clk_cpu` domain rather than a 48 MHz `clk_sys`.
- **IPL is inverted inside the core.** `TG68KdotC_Kernel.vhd` does `IPL_nr <= NOT IPL` before
  comparing against the interrupt mask. Requesting level 1 means driving `IPL = 3'b110`, not
  `3'b001`. Konami GX uses levels 1 to 4; get this wrong and the wrong handler runs.
- **`VPA` must be gated to interrupt-acknowledge cycles only.**
- **`RESET`/`HALT` are a genuine open-collector net** — the core can self-assert them while the
  wrapper also drives them. `tri1` models it correctly in simulation; Quartus 17.0 does not resolve
  it the same way, and Psikyo confirmed on hardware that the idle-high default never resolves,
  holding the CPU in reset forever. Read Psikyo's `maincpu.sv` header before wiring these.
- **There is no instruction cache.** The real 68EC020 has a 256-byte direct-mapped one and the GX
  BIOS enables it (`movec D0,CACR`). The kernel exposes `CACR_out`, so the wrapper can see that the
  game asked for a cache it is not getting. Roadmap, "Design decisions".
- **Upstream's own caveat:** "The core does not value cycle accuracy." If a GX game runs logically
  correctly but glitches on a timing-sensitive effect, suspect this first.

## Verification

**Analysis under Quartus 17.0.2 (`ef2a321`): clean.** `Found 1 design units, including 0 entities`
for the package and `2 design units, including 1 entities` for each of the ALU and the kernel, with
no VHDL warnings. Resource usage was byte-identical to the build before this directory existed —
7,228 ALMs, 384,501 block memory bits, 59 M10K — which is the expected result while nothing
instantiates the kernel, and confirms that adding it pulled nothing else in. That is an analysis
check, not a synthesis one; area and Fmax for the kernel are Phase 0 measurements and need a
`rtl/synth_check/` project of their own.

Per [`../../../docs/WORKFLOW.md`](../../../docs/WORKFLOW.md) §12, a vendored module's own tests are
its regression. TG68K.C ships none, so Phase 0's exit criteria stand in for them: the boot-trace diff
against MAME on the first target set, a measured CPI, and a standalone Fmax and area figure with the
constraint that proves it committed in the same commit as the measurement.
