# Working practice

The build, deploy, instrumentation and reference-capture practices this core adopts, carried over
from `Arcade-Psikyo_MiSTer`, `Arcade-Fuuki_MiSTer`, `Arcade-Seta_MiSTer` and
`Arcade-JalecoMS32_MiSTer`. **These are not suggestions.** Each one exists because its absence cost
one of those projects real time, and [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) records what it cost.
The single clearest example: Fuuki looked at Psikyo's `build_staged.py`, judged it optional, and left
it unported — the bill was a whole session of serialised work, a build that died mid-Fitter with an
edit in flight, and a `.qsf` hand-edit silently reverted by Quartus re-saving the project between
builds.

This core's largest difference from the four before it is that most of its custom chips already
exist in open RTL (see [`ROADMAP.md`](ROADMAP.md), "Component reuse map"). That moves the risk from
"can this be written" to "is this the same chip, wired the way this board wires it" — which makes
section 8's MAME reference capture and section 12's vendored-module regressions the load-bearing
parts of this document, and makes them wanted before the first game is launched rather than after.

Adopt the whole set at the start, not the parts that seem needed yet.

---

## 1. Build out of a snapshot, never in the tree

`scripts/build_staged.py` snapshots HEAD into a **git worktree at `build/`** (gitignored) and runs
the Quartus flow there. The main tree stays editable for the whole compile, every scrap of Quartus
scratch stays out of the repo root, and the build is exactly HEAD — a dirty tree is refused by
default. The built commit is recorded in `build/BUILT_COMMIT` beside the log.

Three properties matter and must survive the port:

- **Refuses a dirty tree.** "What was in that build?" has to be answerable.
- **Gates on negative slack on every clock**, not on the Fitter's opinion. Quartus reports "Fitter
  was successful" on a design that grossly fails timing; Psikyo shipped an `.rbf` at −8.879 ns setup
  slack with every log line saying "successful".
- **Keeps `output_files/` and the log under `build/`**, so a failed build cannot be mistaken for the
  previous good one.

### Two revisions from one source

`KonamiGX_stp` is the instrumented revision and `KonamiGX` the release one. The only difference
between the two `.qsf` files is `VERILOG_MACRO "DEBUG_ISSP=1"`: with it the ISSP probes are built
and the OSD's Debug page is visible, without it the probes, their ring buffer, their counters and
the menu page all compile out. No `#ifdef` clutter in the middle of the logic — the guard sits
around the probe instances in `KonamiGX.sv` and around one `localparam` that drives
`status_menumask`.

```
python scripts/build_staged.py                     # KonamiGX_stp, the default
python scripts/build_staged.py --rev KonamiGX      # the release build
```

Outputs are named after the revision (`build/output_files/KonamiGX_stp.rbf`), so the two never
overwrite each other.

### The fitter seed is part of the build, and it is recorded

Both `.qsf` files pin a seed, and `build/BUILT_COMMIT` records the seed each build used. This is not
tidiness: on Seta, two builds of the same commit at seeds 2 and 7 differed in whether five games ran,
and the one that ran them all had the *worse* worst slack. A commit alone does not identify a
bitstream. When a build regresses games whose code paths the diff cannot reach, rebuild the same
commit at another seed before bisecting the source.

Keep an in-tree `scripts/build.sh` for the one case that needs it — a compile that must see
uncommitted work — and treat it as the exception.

Do not run Quartus wrapped in `nohup ... &` (it detaches and the run becomes untracked), do not
switch branches while a Quartus process is reading the tree (it silently kills the run), and invoke
`quartus_sta` / `quartus_map` / `quartus_sh` by full path — they are not on `PATH`.

## 2. Build and probe are mutually exclusive, and it is enforced

`scripts/hwlock.py`, ported from Seta unchanged except for the repo it sits in. **This is the first
script to port, before the first build.**

There is one PC, one USB-Blaster and one Quartus install shared by five MiSTer core repositories.
Running a JTAG session while a Quartus compile was in flight took the machine down three times on
2026-09-06 — `KERNEL_SECURITY_CHECK_FAILURE`, bugcheck 0x139 — each one costing a running
measurement, and the third costing a fault state that had taken a while to reach. It was written
down as a caution after the first two and happened anyway, which is why it is a lock and not a note.

Both directions:

- a JTAG tool refuses to start while Quartus **or** ModelSim is running;
- a build, or a simulation, refuses to start while a JTAG tool holds the marker.

Quartus and ModelSim are not a hazard to each other: builds and simulations may run side by side,
and several of either at once. Verilator is outside the lock entirely.

Two properties that must survive the port:

- **The marker is machine-wide, not per-repo** — `%LOCALAPPDATA%/mister_jtag_running`, beside the
  user profile, so this repository's copy and the other four agree on the same file. A marker under
  `build/` would let a GX compile start while a Seta probe was reading, which is the exact
  combination being guarded against.
- **A stale marker whose pid is gone is cleared automatically.** A crashed tool must not wedge every
  later build.

Every entry point that touches either side calls it: `build_staged.py`, `run_sim.sh`, `read_issp.py`,
`memdump.py`, `tracer_readout.py`, and anything else that opens the Blaster.

## 3. Deploy only what the build actually produced

`scripts/deploy.py` refuses to copy a `.rbf` unless:

- the build log says the compile succeeded,
- the `.rbf` is **not older than that log**, and
- the timing summary has **no negative slack** on any clock.

It prints every clock's slack before copying anything. This exists because a Psikyo build died
mid-Fitter and the deploy that followed happily verified the *previous* build's stale `.rbf` as
green.

Cores land as `KonamiGX_NNNNNNNN.rbf` with an **incrementing number read back from the device**, so
earlier builds stay on the machine as fallbacks. MiSTer launches the highest-numbered one, so
renaming the newest to `.held` drops back one — a one-command bisection across deployed builds.

The `.rbf` must be in `/media/fat/_Arcade/cores/`: `.mra` files resolve `<rbf>` by prefix-matching
filenames there, not by a path relative to the `.mra`. A misplaced `.rbf` gives a silent
flash-and-return-to-menu before ROM loading even begins.

Deploying and launching back-to-back needs an explicit `sync` plus a settle gap; the race does not
appear when the same steps are run manually seconds apart.

The two revisions are held to different standards, and `docs/RELEASE_PROCESS.md` (ported from
Psikyo) carries the procedure: the debug revision **may** ship with negative slack onto our own
board; a release revision **must** close timing, because a path that only just fails becomes an
intermittent glitch someone else has to chase and cannot diagnose.

## 4. Debug switches live in the OSD, on a hidden page

A full compile took roughly 13 minutes on the prior cores, so **anything that might need changing
during an investigation belongs on a runtime switch, not in the RTL.** LESSONS_LEARNED puts it as
"Add runtime A/B switches when the alternative is a rebuild per bisection step".

GX wants more of these than its predecessors did, because it has four tilemap layers, a sprite
plane, three sub layers and a mixer nobody has implemented. Per-layer render disables are the
cheapest bisection tool there is, and the K055555's priority decisions are exactly the kind of
"MAME's version versus the other reading" question that belongs on an A/B switch rather than in a
rebuild.

Rules that come with the pattern:

- **Every debug line carries an `H<n>` prefix** so the whole page hides in release builds, with the
  menumask bit tracking a macro defined only by the instrumented revision.
- **Render-disable switches per layer and for sprites**, from the first video build.
- **Make the all-zero configuration the correct one.** A fresh or missing `.CFG` is all zeroes, so
  invert any switch whose enabled state is required, and write the OSD option order to match.
- **Put the OSD Reset entries before the joystick lines in CONF_STR** — an MS32 finding.
- `scripts/cfg.py` sets bits by **read-modify-write** on `/media/fat/config/<setname>.CFG` (16 bytes
  = the 128-bit status word, little-endian, byte N = `status[8N+7:8N]`). Never hand-write a `.CFG` —
  the mistake of zeroing every DIP while setting one debug bit was made twice on Psikyo, and it
  silently enabled Service Mode. The CFG is only read when the core loads.
- Validate bit assignments with <https://agg23.github.io/mister-config/> rather than reasoning about
  ranges. Collisions are silent; the symptom is an option that simply does not respond.
- **`status[0]` is Soft Reset.** Never use it for anything else.

## 5. The JTAG probe

`rtl/debug/issp_probe.sv` — In-System Sources and Probes, read and poked over JTAG with
`quartus_stp -t scripts/read_issp.tcl`, under the section 2 lock.

**Why ISSP and not SignalTap:** SignalTap acquisition is not scriptable in Quartus Prime Lite 17.0 —
GUI only. ISSP is (`start_insystem_source_probe`, `read_probe_data`, `write_source_data`), which is
what a headless workflow needs. It also suits the questions a bring-up actually asks, which are
rarely "what does this waveform look like" and usually "did this ever happen, and how often".

Keep the wrapper generic and build the probe bus in the module that owns the signals, so the
instrumentation sits next to what it instruments and the wrapper stays stable. The Tcl decoder must
be kept in step with the bit layout — say so in a comment at both ends.

The **source** direction is as valuable as the probe direction: pausing the CPU, selecting a memory
page to dump, re-arming a capture and stepping the SDRAM clock phase are all runtime pokes that
would otherwise be rebuilds. One trap, paid for on Fuuki: `write_source_data -value` takes a
**binary string**, and a decimal one is silently rejected while still printing "source set to N".
Pass `-value_in_hex`, and read every source back after writing it.

## 6. Counters and the trace ring

`rtl/debug/debug_counter.sv` and `rtl/debug/debug_tracer.sv`, both carried over with their design
rationale in the file headers. The properties are the point:

- **No reset port at all.** Quartus powers registers to zero at configuration, so a counter with no
  reset shows what genuinely happened since the FPGA was programmed. Two Psikyo measurements read
  `0x000000` and were reported as findings before anyone noticed the counters were cleared by the
  reset under investigation — which MiSTer asserts for the entire ROM download.
- **Counters saturate rather than wrap.** A wrapped 3 could mean "three times" or "65,539 times",
  and those lead to opposite conclusions.
- **Every "bad event" counter is paired with a "total events" counter.** A zero otherwise cannot
  distinguish "did not happen" from "was never allowed to count".
- The tracer takes an explicit one-cycle `cap_stb` from the caller, so the capture point is a
  deliberate decision — and it must be proven in simulation against a known-good run before its
  hardware output is trusted. If a new probe reports a fault on a known-good setup, the probe is the
  fault.
- **`ctl_window` walks the capture across a long boot sequence from the OSD with no rebuild.** Make
  the step size odd (`window * 8191`) so it cannot alias with a power-of-two period.
- **Capture the full address.** Packing only `addr[7:0]` into a pixel made a genuine linear ROM sweep
  look exactly like a read path dropping its high bits.

The first counters this core needs, from the ROADMAP's worst-case section: sprites walked per frame,
sprite pixels written per line, tilemap fetch stalls per line, and ESC DMA cycles per command. Each
paired with a total, each in from the first video build rather than added after a game looks wrong.

## 7. Reading the trace out through the video output

The trace ring is read back as pixels on the screen and decoded from a screenshot
(`scripts/decode_debug_screenshot.py`, `scripts/tracer_readout.py`). Two things must be right:

- **Force the gamma LUT off under the overlay.** The framework applies the user's gamma curve to the
  core's RGB before the scaler and before screenshots. Fuuki's trace values came back remapped
  (`0x40 → 0x38`, `0x02 → 0x01`), which read exactly like SDRAM data-lane corruption and survived an
  `SDRAM_CLK` phase change. Clear `gamma_bus[19]` whenever the overlay is on, leaving the user's
  display settings alone.
- **Draw each value and its bitwise inverse in alternating bands.** The pair must XOR to `0xFFFFFF`
  whatever the memory holds, so any transform anywhere in the capture path is *detected* rather than
  read as data.

`/dev/fb0` is the ARM-side OSD overlay surface, not the FPGA's composited video — never use it as
evidence about the core's video pipeline. Use the screenshot API, and poll for a new file under
`/media/fat/screenshots/<core-shortname>/` because `POST /api/screenshots` returns an effectively
empty body regardless of success.

VGA-colour-override builds remain the crudest and most reliable instrument for a yes/no question:
override `VGA_R/G/B` with a solid colour gated by an internal signal and take one screenshot.

## 8. Reading memory back out of a running core

`scripts/memdump.py` reads SDRAM, tilemap VRAM, palette, sprite RAM, video registers and work RAM
back out of the running core over JTAG with the CPU paused, optionally diffing against an expected
image. `scripts/boot_trace.py` captures the first N CPU accesses, or the N before the first
exception, or the N before a JTAG pause, and compares against MAME.

This is the instrument that settled several Fuuki bugs simulation could not see — work RAM indexed
one bit too narrowly, an arbiter still packing 25-bit addresses after a widening. Build it early;
its value is that it answers hardware questions directly instead of arguing from simulation.

`scripts/wait_scene.py` polls screenshots until the frame matches a reference crop and then holds
the CPU paused there, so a dump is one instant of one chosen scene rather than whatever happened to
be on screen. `scripts/sweep.py` launches every deployed set in turn and tabulates the probe side by
side — one black screen is consistent with several different faults, and comparing sets separates
them. `scripts/soak.py` runs a game for N seconds sampling the probe and a screenshot periodically,
and flags a hang.

## 9. MAME as a reference generator

Reference data is **captured, not hand-made**, so any claim about the hardware can be re-checked
cheaply and the same way by anyone else with a MAME install and the ROM sets.
`scripts/mame_capture.py` drives MAME headlessly through `scripts/mame/*.lua` and captures video
regions, screenshots and register write logs.

What this makes provable offline, before hardware exists:

| Reference | Validates |
|---|---|
| Boot program trace (PC / bus cycles) | TG68K.C end to end against GX's map — diffed against the ModelSim trace rather than eyeballing "it looks like it is running". Catches wrong interleave, wrong reset vector, wrong IRQ timing and wrong DTACK behaviour in one test |
| Program ROM disassembly at known offsets | The `.mra` interleave, with no build and no hardware |
| Tilemap VRAM / K056832 + K053246 + K055555 + K054338 register dumps at a known frame | Every video engine: preload the dump, render one frame in sim, compare against MAME's output for that frame |
| Palette RAM dump | The colour path, which is `xRGB_888` here and 5-bit in the cores the vendored modules came from |
| Write taps over a boot | The two measurements the RAM budget depends on: which tilemap pages a game actually writes, and how much of the sound 68000's 64 KB it uses |
| A tap on `0x300001` | Whether any in-scope game uploads a program to the TMS57002 |

The pipeline this project needs, in order: `mame_capture.py <set> --frame N` dumping every video RAM
and register block through the CPU's address space; `render_model.py` reproducing
`konamigx_v.cpp` — tilemaps, sprites, the z-buffer sort and the K055555/K054338 mixer — and reporting
the pixel match against MAME's own screenshot; then the RTL checked against the model, layer by
layer. **The model is checked against MAME first and the RTL against the model.** For a mixer with
no prior implementation this is not a convenience, it is the only way to tell a wiring mistake from a
misreading of `konamigx_mixer()`.

Traps, all paid for on Fuuki:

- **Keep every Lua subscription in a variable that outlives the call.** `add_machine_frame_notifier`
  and `install_write_tap` return subscription objects; dropping the return value lets the GC reclaim
  them and the callback **silently stops firing**. A capture at frame 120 worked and the identical
  capture at frame 1100 produced no files, no error, and exit status 0.
- **Check `mame.ini` for `debug 1` and pass `-nodebug` explicitly.** Otherwise every launch halts in
  the debugger while the autoboot script still loads and still prints, so it looks like it is working
  while the machine never advances a frame. Same for `window 1` when headless.
- **Wrap the Lua in an error-catching runner** that writes failures to a file the Python side reads
  back — otherwise a broken script fails as a modal dialog that is invisible headlessly.
- **Probe which Lua API this MAME build actually provides** rather than writing against the current
  online docs.
- **Read dumps through the CPU's own address space** (`spaces["program"]:read_u16(addr)`), not out of
  MAME's internal structures — that returns what the CPU would read, device handlers included, which
  is the thing the RTL has to match. On GX that distinction is sharp: `d00000` and `d4a000` are ROM
  readback windows that exist only for the memory test and have no backing array at all.
- Snapshots work under `-video none` and land one directory deeper than the one given; search
  recursively.

Two cautions on what a comparison proves: a hardware-vs-image comparison **cannot detect a wrong
image** when both sides were built from the same byte-order assumption, and any test using uniform or
all-zero content is invariant under byte order and cannot catch endianness bugs at all. Use real
content. That applies with extra force to the 5 bpp sprite region, which MAME assembles at runtime
from two differently-sized regions.

## 10. Simulation

`scripts/run_sim.sh` compiles the RTL and runs one testbench from the repository root, and
**rebuilds the `work` library every run**. That last part is not tidiness: a ModelSim compile killed
by a tool timeout leaves `work/_lock`, on which every later `vlog`/`vcom` waits silently — three
Fuuki "silent chip" investigations were a lock. A bench that prints nothing has usually not run.

Vendored jotego modules need `+define+SIMULATION +initreg=r+0 +initmem=r+0`: their un-reset
pipelines are X in a four-state simulator and zero in hardware. That flag has its own trap, recorded
under "[MS32] `+initreg=r+0` turns an un-evaluated `always @*` into a confident zero" — it makes a
combinational block that never evaluates look like a settled value rather than an X, which is how a
boot once stopped at the reset vector with nothing reporting an error.

Sweep for orphaned `vsimk.exe` kernels at the start of any session that runs simulations — killed
runs leave them spinning at 100% CPU indefinitely, and their working set is not a liveness signal:

```powershell
Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
```

`taskkill //PID <n> //F` fails against these; `Stop-Process -Force` succeeds.

**Verilator is the second simulator, and the fast one.** MSYS2's mingw64 package
(`pacman -S mingw-w64-x86_64-verilator`), driven through the msys bash so its `make` and `g++`
resolve. It turns a 15–20 minute ModelSim iteration into a build of ~10 s plus a run measured in
tens of seconds. Two things it is not: it is two-state, so anything that turns on X-propagation stays
on ModelSim; and VHDL is outside it, which matters here because TG68K.C is VHDL — the CPU benches
stay on ModelSim. A disagreement between the two simulators is a finding, not a nuisance. Verilator
does not need the section 2 lock.

The rest of testbench discipline is in LESSONS_LEARNED's "Testbench discipline" section — read it
before writing a new bench rather than after one gives a confident wrong answer.

## 11. `.mra` generation

Generate every `.mra` from a script (`scripts/build_mra.py`), not by hand:

- Each region is built from the driver's `ROM_START` semantics, and **the map digits are found by
  testing against that**, not derived by reasoning. Every interleave Psikyo derived by reasoning was
  wrong. The twenty-two in-scope sets use eleven distinct load forms — `ROM_LOAD`,
  `ROM_LOAD16_BYTE`, `ROM_LOAD32_BYTE`, `ROM_LOAD32_WORD`, `ROM_LOAD32_WORD_SWAP`,
  `ROM_LOAD64_WORD` and five `ROMX_LOAD` macros with `ROM_GROUPDWORD`/`WORD`/`BYTE` and
  `ROM_SKIP(1/2/4)` — so this is not a formality.
- The 128 KB BIOS (`300a01.34k`) is a region of every set and belongs in every `.mra`.
- The finished file is **re-read and compared byte-for-byte** against an image built directly from
  the driver's `ROM_START` (`scripts/mra.py` reimplements what mra-tools-c does).
- SDRAM offsets come from the RTL's own address map, never duplicated into the generator.
- Parents land in `releases/`, clones in `releases/_alternatives/`.
- Every `.mra` is gated on an **XML well-formedness check** before deploy. A stray `<` inside a
  prematurely-closed comment once gave a black screen whose every symptom pointed at the RTL.
- A `<dip>`'s `bits` attribute is a **range**, `"first,last"` — `Main_MiSTer` reads it with
  `sscanf("%d,%d")`. Writing every bit makes a three-bit switch reach half its settings.
- Pad every game to a fixed button count with `-` so Start, Coin and Pause always land on the same
  joystick bits whatever the game's real button count. The CONF_STR `J1` list **must** agree with the
  `.mra` `<buttons>` positions.
- The per-game mod byte carries sprite offsets, colour depth and the ESC variant, and it gates
  download-time logic — so list `<rom index="1">` **before** `<rom index="0">`.
- When testing an `.mra` change, **force a genuine reload** by bouncing through `menu.rbf` — a
  relaunch reuses the cached ROM and produces a byte-identical trace.

## 12. Vendored modules: their own tests are the regression

This core vendors more than the previous four combined, from two upstreams with different accuracy
targets. The discipline that goes with that:

- **Every vendored directory gets a `PROVENANCE.md`** recording the upstream repository, the exact
  commit, the licence as stated in the files (not as stated by GitHub's licence detector), what was
  changed and why.
- **Run the upstream tests on arrival, before editing anything.** jotego's tree ships benches under
  `cores/<core>/ver/` — `cores/rungun/ver/k053252` for the CRTC, `cores/aliens/ver/*` for the
  earlier tilemap and sprite chips. A vendored block that fails its own tests on arrival is a porting
  problem, and finding that out after GX-specific edits is how a day is lost.
- **Re-run them after every edit**, as the regression they now are.
- **GPLv3 §5(a): a modified file must state prominently that it was changed, and when.** jotego's
  files carry SPDX headers; append to them, never replace them, and never tidy the notice away. It is
  a licence term, not a comment.
- **Where a vendored module and MAME disagree, record it and keep the module.** jotego's `jt05415x`
  README states that its silicon-derived logic wins over MAME's comments. This project's accuracy
  target is MAME, because there is no GX PCB here. Both are right for their own project. A
  silicon-derived disagreement is evidence about the chip; MAME's is evidence about MAME. It goes in
  `docs/MAME_KLUDGES.md`, not into a "fix".

The TG68K.C side has its own list, in `Arcade-Psikyo_MiSTer/rtl/cpu/tg68k/PROVENANCE.md`: instantiate
`TG68KdotC_Kernel` directly rather than `TG68K.vhd`, add explicit zero initializers to the VHDL
signals before simulating real programs, model `RESET`/`HALT` as an open-collector net with `tri1`,
gate `VPA` to interrupt-acknowledge cycles only, and keep the vector table real in any testbench that
exercises an interrupt.

## 13. Branching and history

`develop` is the working branch and carries granular commits. At intervals that work is **squashed
onto `master`**, which is what gets pushed. `master` is a curated history of meaningful milestones,
not a replay of every bisection step.

ROMs live in `roms/` and are **gitignored** — no ROM data is ever committed.

`.gitattributes` pins `*.sh` and this project's `.tcl`/`.lua` to LF. With `core.autocrlf` on, a
`git reset --hard` gives them CRLF and bash rejects `set -euo pipefail\r` on line 1.

## 14. No multiplies, no divides, in new RTL

A `*` in RTL is a DSP block or a wide LUT multiplier; a `/` is a large combinational divider. Neither
is what the original chips did, and both cost area and Fmax. Express the arithmetic with **shifts,
masks and adds** even where MAME writes a multiply or a divide: `x * inc` inside a loop is an
accumulator stepped by `inc`, `/ 256` is `>> 8`. Where a product is genuinely needed and not every
clock, a serial shift-add stepper over a few cycles is the form. Where one must stay at pixel rate,
keep it to a DSP-sized width and say so in a comment. Before committing RTL, grep it for `*` and `/`
outside comments.

GX's sprite zoom (`x * 0x40 / zoom_x` in the ESC's `generate_sprites`, and the K053246's own
16-bit zoom) is where this will bite first. The zoom accumulator is the hardware's own form; MAME's
division is not.

## 15. Licence headers

This core is **GPL-3.0-or-later**. Full reasoning and the release checklist go in `THIRD-PARTY.md`.
Three rules while writing code:

- **Every new source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`** and a
  copyright line. One line each, at the top, before anything else.
- **A vendored file keeps its upstream copyright and its upstream change notice** (see section 12).
- **`sys/` is never edited.** It is GPL-2-or-later framework code taken unmodified, and the or-later
  clause in its file headers is the only thing making this repository's licence combination lawful.
  Build-time behaviour changes go in the `.qsf` as `VERILOG_MACRO` settings.

## Script inventory to port

From `E:\Arcade-Seta_MiSTer\scripts\` and `E:\Arcade-JalecoMS32_MiSTer\scripts\` (the two most
evolved sets), falling back to `E:\Arcade-Psikyo_MiSTer\scripts\`. **Done** marks what is in this
repository already.

| script | why |
|---|---|
| **done** `hwlock.py` | **first**, before any build — section 2 |
| **done** `build_staged.py` | worktree build at `build/`, refuses dirty tree, gates on slack |
| **done** `deploy.py` | slack-gated deploy, incrementing `.rbf` numbering, fallbacks on device. MS32's capture-blob path deliberately not carried over |
| **done** `run_sim.sh` | one testbench, fresh `work` library every run, and it takes the lock |
| **done** `run_verilator.sh` | the fast second simulator; outside the lock. Ported from Seta; `-G` parameter overrides go to the build. `scripts/check_gx_obj.py` uses it by default: ~3 s a frame against ~15 s in ModelSim, same result on all five sprite frames |
| `cfg.py` | read-modify-write of the per-core `.CFG` status word |
| `read_issp.tcl`, `read_issp.py` | read the probe / write the source bus over JTAG |
| `report_worst_paths.tcl` | worst setup paths from the compiled database |
| `mame_capture.py` + `mame/*.lua` | headless MAME reference capture |
| `extract_romstart.py` | read every set's `ROM_START` straight from the driver rather than transcribing 42 of them |
| `build_mra.py`, `mra.py`, `extract_dips.py`, `check_dips.py` | generate, verify byte-for-byte, and parse-check every `.mra` |
| `build_rom_image.py`, `build_region.py` | the ROM image the benches load, built from `ROM_START` |
| `boot_trace.py`, `compare_boot_trace.py`, `diff_core_trace.py` | the CPU trace diff against MAME |
| `decode_gfx.py`, `gfx_sheet.py` | decode tiles straight from the ROM zip |
| `memdump.py` | read any CPU-visible memory out of a running core |
| `decode_debug_screenshot.py`, `tracer_readout.py` | trace ring readout through the video path |
| `hw.py`, `wait_scene.py`, `sweep.py`, `soak.py` | launch, hold a chosen scene, compare sets, detect hangs |
| `sdram_pattern_test.py`, `sdram_dump_check.py` | known-pattern SDRAM test through the real download path |

And from `rtl/debug/`: `issp_probe.sv`, `debug_tracer.sv`, `debug_counter.sv`, plus
`pause_control.sv`.

Port them with their header comments intact. The rationale in those headers is the reason they have
the shape they do, and a stripped copy invites someone to add the reset port back.
