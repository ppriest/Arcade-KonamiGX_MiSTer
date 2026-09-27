# Konami System GX — MiSTer Core Roadmap

## Context

Goal: a DE10-nano MiSTer core for Konami's System GX, emulated by MAME's `konami/konamigx.cpp`,
`konamigx_v.cpp` and `konamigx_m.cpp` plus the eight custom-chip devices those files instantiate — a
Quartus 17.0.2 Verilog/SystemVerilog project producing one `.rbf` and a `.mra` per supported game,
reusing proven open components where they exist.

**The shape of this project is set by one fact: most of the GX chipset already exists in open
FPGA form.** [jotego/jtcores](https://github.com/jotego/jtcores) (GPL-3.0-or-later) ships working
implementations of the K053252 CRTC, the K054156/K054157 tilemap pair, the K053246/K053247 sprite
pair with its K055673 wide-ROM variant, the K054338 alpha blender and the K053936 PSAC2, across its
`moo`, `rungun`, `simson` and `riders` cores. [furrtek/SiliconRE](https://github.com/furrtek/SiliconRE)
carries silicon-derived schematics for most of the same chips and a 41 KB Verilog K054539. The CPU
side is already proven in-house: `Arcade-Psikyo_MiSTer` runs TG68K.C as a 68EC020 and
`Arcade-Seta_MiSTer` runs fx68k as a 68000.

So the order of size here is **integration, not invention** — the opposite of the Jaleco MS32
project, whose CPU and sound chip both had to be written. What is genuinely new work is short and
identifiable:

1. **The K055555 mixer.** furrtek has traced the die and published a pinout and a register
   description, but no schematic and no HDL (status "WIP" in his own table). MAME's `k055555.cpp`
   is 150 lines of write-only register file; the actual mixing is done in `konamigx_v.cpp`'s
   `konamigx_mixer()` in C++ against a software z-buffer. This is the one video chip with nothing to
   port, and the one whose behaviour is least determined.
2. **The ESC protection chip**, a microcontroller whose microprogram the game uploads. MAME
   hardcodes the common program in C and has per-game variants; it has full DMA over the 68020
   address space and builds the sprite list.
3. **K056832 colour depths above the K054157's.** jotego's `jt05415x` is the K054156/K054157 pair;
   its own README says that pair reaches 5 bpp where K054156/K056832 reaches 8. GX uses 4, 5, 6 and
   8 bpp across the game list.
4. **The K054539**, written from MAME's `sound/k054539.cpp`: furrtek's HDL is GPL-2.0-only as far
   as this project can tell ([`THIRD-PARTY.md`](../THIRD-PARTY.md)) and is not used.
5. **The TMS57002 "DASP" effects DSP.** Phase 0 measured that all 22 in-scope sets load programs
   into it, so it is required, and no FPGA implementation exists. It was a measure-first item until
   the survey ran; see "Sound".

Everything else is a port with verification.

Cross-cutting technical findings from the previous four cores — Quartus-vs-ModelSim divergences,
SDRAM gotchas, testbench pitfalls, hardware bring-up technique — are in
**[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**. Working practice built on top of them (staged builds,
the build/probe lock, the JTAG probe, OSD debug switches, the MAME capture pipeline) is in
**[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already bind decisions in this document are
collected below under "Pitfalls that already bind decisions here".

## Progress

**No RTL is written. Phase 0 has not started.** The repository is MiSTer-devel/Template_MiSTer as
seeded, plus this document set and the build harness. Every number below is read out of MAME source,
out of the four sibling projects' measurements, or out of a public repository's files; none of it has
been measured on this hardware, and each claim says which.

What exists: `scripts/hwlock.py` and `scripts/build_staged.py`, ported from the sibling cores; the
`Template.*` project renamed to `KonamiGX.*` and split into the `KonamiGX` and `KonamiGX_stp`
revisions; `.gitattributes` and a `.gitignore` that covers the staged build, ROMs and simulation
scratch. Both directions of the lock were exercised and both refuse correctly. `build_staged.py` was
run against HEAD and its whole path works — worktree created and reset, Quartus invoked in the
stage, log captured, all three gates reported, no stale marker left behind.

**The first staged build is green** (`9e39b46`, `KonamiGX_stp`, seed default, 4m29s): all seven
clocks positive, worst +0.591 ns on the framework's HDMI PLL, `hps_io` present in the fitted
netlist, a 2.4 MB `.rbf`. That is the template plus the framework and nothing else, which makes it
the baseline every later figure is measured against:

| | template + framework | device |
|---|---|---|
| Logic (ALMs) | 7,228 | 41,910 (17%) |
| Block memory bits | 384,501 | 5,662,720 (7%) |
| M10K blocks | 59 | 553 (11%) |
| DSP | 33 | 112 (29%) |
| PLLs | 3 | 6 (50%) |

The 7% of block memory bits is the number to carry into the RAM budget below: GX's declared
memories are 55% of the device on their own, so the design starts at **62%** before any engine has
a line buffer or a ROM cache. The 33 DSP blocks the framework already spends are also worth noting
against WORKFLOW §14 — the budget for new multipliers is smaller than the 112 suggests.

The ROM sets for all 22 in-scope games are in `roms/` (gitignored), twelve merged zips verified
against `ROM_START` by filename, size and CRC.

**Vendoring is done for the video chipset and the main CPU.** Every module below analyses cleanly
under Quartus 17.0.2 — checked in the map report, not inferred from the build's exit code — and
resource usage is still the bare framework's 7,228 ALMs, because nothing instantiates any of them
yet. Each directory carries a `PROVENANCE.md`; `.gitattributes` stores every vendored file `-text`
so "verbatim at <commit>" stays checkable.

| block | where | upstream | bench |
|---|---|---|---|
| 68EC020 | `rtl/cpu/tg68k/` | TG68K.C `ade33e39`, LGPL-3.0-or-later | none upstream; Phase 0 criteria stand in |
| K053252 CRTC | `rtl/video/k053252/` | jtcores `e7958c86` | **upstream differential bench, passing** |
| K054338 alpha | `rtl/video/k054338/` | jtcores `e7958c86` | none upstream |
| K053246/K055673 sprites | `rtl/video/k055673/` | jtcores `e7958c86` | none upstream |
| K054156/K056832 tilemaps | `rtl/video/k056832/` | jtcores `e7958c86` | none upstream |
| jtframe dependencies (12) | `rtl/jtframe/` | jtcores `e7958c86` | — |

Only one modification has been made to any of it: explicit zero initializers in TG68K.C's ALU and
kernel, with §5(a) notices, checked mechanically to contain nothing but initializers.

`jtframe mmr` is vendored in `tools/jtframe/` and produces the register-decode modules jotego
generates rather than commits. The generator was validated against `jt053246_mmr.v`, which jotego
*does* commit: regenerating it reproduced the committed file byte-for-byte.
`scripts/regen_mmr.sh --check` is what keeps them from drifting.

**The MAME capture pipeline runs.** `scripts/mame_capture.py` dumps work RAM, sprite RAM and the
palette through the CPU's own address space, reconstructs the write-only register files and the
banked tilemap VRAM from write taps, and saves MAME's screenshot beside a manifest. Its first run on
`daiskiss` answered the tilemap-VRAM question below.

**The capture is proven, not assumed.** After the snapshot, the capture selects each VRAM page
through the bank register and reads it straight back out of MAME. The write-tap reconstruction
agrees with that ground truth on **4,096 of 4,096 words, all 16 pages**. Every colour on MAME's
screen is found in the captured palette — zero unexplained — which also shows MAME applied no
brightness or shadow to that frame.

**Phase 1 has started: the tilemap stage of `scripts/render_model.py` reproduces MAME.** Scored
the only way that means anything before the mixer exists — on the pixels whose colour can only
have come from one tile layer, which that layer rendered alone must reproduce:

| `daiskiss` frame | layer B | layer C | layer D |
|---|---|---|---|
| 1200 | 20,941 / 20,941 | — | — |
| 2400 | — | 33,188 / 33,188 | 409 / 409 |
| 4800 | — | 28,442 / 28,442 | 409 / 409 |
| 6000 | 1,576 / 1,576 | 18,993 / 19,011 | 409 / 721 |

That covers plain X/Y scroll, 5 bpp, no screen flip — what these frames exercise; line and row
scroll, flip and the other depths are errors in the model rather than silent guesses. Frame 6000
leaves two patches the tile stage does not reproduce, and neither is a tile fault. The 312 "layer
D" pixels are layer C under a spotlight beam: layer C draws (255,255,0) and (241,222,0) there, MAME
shows (255,255,64), which is each +0x40 per channel clamped — and happens to equal pen `0xe4f`, so
the attribution put it in layer D's bank. (The earlier guess, sprites using bank-3 pens, was tested
and is wrong: no enabled sprite has a colour in that bank.) The same +0x40 rule accounts for 2,397
layer-C pixels across that frame. The 18 layer-C pixels show (255,113,113) where layer C draws
(198,0,0) — not +0x40, and unexplained until the mixer is modelled.

**The sprite stage reproduces MAME wherever MAME shows a sprite unmodified.** Solid objects only,
z-buffered against each other; shadow and alpha objects are set aside. Scored on the pixels the
sprites draw:

| `daiskiss` frame | sprite pixels shown unchanged by MAME | the rest |
|---|---|---|
| title | 43,571 / 43,571 | — |
| 2400 | 19,788 / 19,788 | — |
| 3600 | 23,039 / 23,427 | all 388 show layer C's exact colour: a layer in front |
| 4800 | 22,669 / 28,792 | under layers A/C: the translucent glass bowl, blended |
| 6000 | 18,440 / 18,741 | under layers B/C: spotlight beams |

Every miss is under an opaque tile pixel, so all of them are the mixer's — priority, alpha and the
K054338 highlight — not the sprite stage's. The sprite pool, zoom stepping and z-buffer are
transcriptions of `konamigx_mixer`, `k053247_draw_single_sprite_gxcore` and `zdrawgfxzoom32GP`.

**The mix stage completes the model: six `daiskiss` frames are pixel-identical to MAME**
(frames 300, 1200, 2400, 3600, 4800, 6000 — 64,512 of 64,512 pixels each). It transcribes
`konamigx_mixer`: tile layers and sprites share one object pool sorted by K055555 priority, a
higher value drawn further back; layer alpha from the K054338 blend levels; sprite shadows through
MAME's 15-bit shadow tables. Every miss the tile and sprite stages left is accounted for by it —
layer in front (3600), the glass bowl at layer-A alpha 165/256 (4800), and spotlight highlight
+0x40/+0x80 (6000, 12,302 pixels changed by shadow objects). The MAME kludges it reproduces are
listed in [`MAME_KLUDGES.md`](MAME_KLUDGES.md). Not exercised by any capture yet: additive blend,
alpha sprites, layer brightness, sub layers, and a visible non-black background.

**The first video RTL matches the model: `rtl/video/gx_tilemap.sv` reproduces all four tile layers
on every captured frame.** `scripts/check_gx_tilemap.py <capture>` loads the capture's registers,
tile banks and all 16 VRAM pages into the module through its write ports, renders every visible
line in ModelSim, and compares each pixel's 6-bit colour field and 5-bit pixel with
`render_model.layer_fields()`. `daiskiss` frames 300, 1200, 2400, 3600, 4800 and 6000: **64,512 of
64,512 on each of layers A–D**. The check does catch errors: frame 6000's RTL output scored against
frame 4800's model gives 52,224 and 28,597 matches on layers A and B.

It is written from the model rather than ported, because `jt05415x` does not fit GX in three ways
the planned 6/8 bpp extension would not fix (details in the module header): it addresses 4 VRAM
pages where `daiskiss` uses all 16; it outputs tile-ROM addresses and leaves the pixel path to each
game's video module; and its register outputs drop the top bits of the scroll registers, which
MAME uses whenever a layer is not a power of two tall. `jt05415x` stays vendored as the reference
for line scroll and flip, which this module does not do yet (it raises `unsupported` instead).

It is a line renderer: per line, each layer's 288 pixels go into a line buffer, a tile fetcher
running one tile ahead of a one-pixel-a-cycle emitter. Measured on the bench: **1,835 cycles for
the worst line with a 6-cycle tile ROM, 3,826 with a 20-cycle one.** A line is 512 dots at 8 MHz
(`set_raw(8000000, 512, ...)`), 3,072 cycles of a 48 MHz `clk_sys`, so the tile ROM path must
answer within about 14 cycles on average. That is a requirement on the SDRAM arbiter, to be met or
the renderer widened when the arbiter exists.

Standalone synthesis (`rtl/synth_check/gx_tilemap/`): **117.72 MHz** at the slow 100 °C corner,
454 ALMs, and **136 M10K** holding exactly the arithmetic 1,093,632 bits — the 1 Mbit VRAM and four
line buffers, nothing duplicated. The VRAM is the RAM budget's 16 × 8 KB, now measured in blocks.
Getting there took three rewrites of the memories, recorded in LESSONS_LEARNED ("[GX] Put every
inferred memory in a one-write, one-read template module of its own").

**Sprites and mixer follow the hardware's structure, not MAME's painter** (decided after the
tilemap RTL). The sprite path is `jt053246`'s: a per-line list scan feeding a line buffer, one
winning sprite pixel per position, whose priority the K055555 then compares with the tile layers
pixel by pixel. MAME's object pool with a shared z-buffer gives the same per-pixel structure, so
the two should agree except where noted, and every place they differ is explained and recorded
in `MAME_KLUDGES.md` rather than copied.

**`jt053246`'s DMA ordering does not work on GX, and is not hardware evidence.** It copies each
sprite into the table slot named by its z-code byte, so sprites sharing a z-code overwrite each
other. jotego's README calls that "this implementation" and cites PCB measurements only for the
DMA's duration. `daiskiss` shares z-codes heavily. Scored in software against the captures, the
one-slot-per-z-code table keeps **2 of 35 objects on the title frame, 1 of 19 on frame 2400, 8 of
122 on frame 6000**. The hardware-shaped alternative — scan the list in RAM order and give the
line buffer a key per pixel, written only when the new key is strictly lower — reproduces
MAME's sprite picture on all five sprite frames, 64,512 of 64,512 pixels each. That is the plan:
keep `jt053246`'s register file, scan state machine, zoom tables and `jtframe_objdraw` line
buffer; replace the slot sort with the compare in the line buffer; widen the pen to 5 bpp.

**Ties follow MAME.** On sprites either the first or the last of two equal entries wins, visibly,
so MAME's choice is taken. MAME paints back to front (the draw order is the reverse of priority),
so its "last drawn wins" is "first in priority wins": `konamigx_mixer` draws the pool in
descending (priority, z-code, RAM offset) and its z test skips only when the stored z-code is
lower, so the visible sprite is the lowest **(z-code, priority, RAM offset)**. In RAM-order
scanning that is a strict less-than on (z-code, priority). The captures separate first-wins from
last-wins — taking ties the other way loses 369 pixels on frame 3600 and 2,560 on frame 6000 — but
none has overlapping equal-z sprites of different priority, so the priority term is transcribed,
not yet exercised.

**The sprite RTL matches the model: `jt053246` with the GX changes reproduces every solid-sprite
pixel on all five sprite frames.** `scripts/check_gx_obj.py <capture> --voffset 281` loads sprite
RAM and registers through the module's ports, runs GX-shaped video timing in ModelSim until the DMA
has copied the list, records a whole frame and compares valid bit, pen and priority per pixel with
the model: title, 2400, 3600, 4800 and 6000, **64,512 of 64,512 each**. The changes to jotego's
files and why are in `rtl/video/k055673/PROVENANCE.md` and `rtl/jtframe/PROVENANCE.md`, "Local
changes": RAM-order DMA, z-code and word-6 outputs from the scan, 5 bpp drawing, and a line buffer
(`rtl/video/gx_obj_linebuf.v`) that orders pixels on `{z-code, priority}` at one pixel per clock.
The GX callback, solid/shadow split and `primode` filter are in `rtl/video/gx_obj.v`, derived from
`jtsimson_obj.v`.

Two things the bench established that the integration has to keep:

- **`jt053246_scan` walks the whole 256-entry table every line, and runs out of time silently.**
  With a line buffer taking two clocks per pixel, frame 4800's busiest lines ended before the scan
  passed entry 0xb0, and every sprite after it — the large text across rows 176–213 — was not
  drawn. The scan's only sign is a `$display`. The one-pixel-per-clock buffer removed it (no line
  fails on the five frames), but the margin on a heavier frame is not measured yet.
- **`hs` must span `hdump`'s wrap** for `jtframe_objdraw_gate`'s readout counter, or the display
  reads the unused half of the line buffer. A constraint on the K053252 setup.

Not covered yet: shadow pens and full-shadow sprites (drawn by neither side of the comparison so
far), alpha sprites, zoom beyond the one 4x-magnified sprite on the title frame, flip X, and 6/8 bpp.

**The mixer's hardware structure reproduces MAME, in software first.** Two checks against MAME's
screenshots, all six `daiskiss` frames, 64,512 of 64,512 each:

1. `stage_mix(cap, one_sprite_pixel=True)`: MAME's painter, but each solid sprite drawn only where
   it wins the line buffer. So the one sprite pixel per position the hardware hands the mixer loses
   nothing MAME shows — MAME's shared z-buffer never lets a losing sprite pixel reach the screen.
2. `stage_mix_hw`: no painter at all. Per pixel, the sources (background, layers A–D, the winning
   sprite pixel, at most one sprite shadow) each carry a rank — their place in `konamigx_mixer`'s
   draw order, which is the K055555 priority compare with its tie-breaks (a layer beats a sprite at
   equal priority). The top source and the one behind it are chosen; an alpha layer on top is
   blended over the second; the shadow shades whatever is behind its rank. This is the
   specification for the RTL mixer.

What the captures exercise and so what the RTL may assume until a capture says otherwise: at most
one shadow on a pixel (frame 6000 has 12,302 shadowed pixels, none twice) and one alpha layer
(layer A on frame 4800); `stage_mix_hw` raises on anything deeper. Shadows need their own line in
the sprite buffer: MAME's shadow objects have their own z-buffer and priority (`SHAD1_PRI`…), so a
shadow pen must not displace a solid sprite pixel. **Done:** `gx_obj_linebuf.v` has a shadow plane
beside the solid one, and the sprite bench scores both on all five frames — 570 shadow pixels on
frame 3600 and 12,302 on frame 6000, all matching (`rtl/video/k055673/PROVENANCE.md`).

**The mixer RTL reproduces MAME's screenshots.** `rtl/video/gx_mixer.v`, written from
`stage_mix_hw`: per pixel a sort key per source (layer `{pri, 0, layer}` — A in front at equal
priority, which is what MAME's sort gives for every pair — sprite `{pri, 1, z, index, 0}`, shadow
`{shadow pri, 1, z, index, 1}`), top and second picked, three palette reads (top, second,
background), alpha blend and MAME's 15-bit shadow arithmetic. `scripts/check_gx_mixer.py` feeds it
the per-pixel outputs of the tilemap and sprite stages (which the RTL of both reproduces exactly)
and compares its RGB with **MAME's own `reference.png`**: frames 300, 1200, 2400, 3600, 4800 and
6000, **64,512 of 64,512 each**, on Verilator and, for 4800 and 6000, on ModelSim. The check does
catch errors: frame 6000's output scored against frame 4800's screenshot matches 1,426 pixels.

Standalone Quartus of all three blocks together (`rtl/synth_check/gx_video/`): **67.65 MHz**,
1,554 ALMs, 188 M10K holding exactly the arithmetic 1,524,224 bits. That came after pipelining the
mixer's ranking: the first fit was 52.96 MHz, its worst path running from the tilemap's
line-buffer RAM through the whole rank in one clock.

**The whole video path in RTL reproduces MAME's screenshots.** `rtl/video/gx_video.sv` wires
`gx_tilemap`, `gx_obj` and `gx_mixer` to one timing. `scripts/check_gx_video.py` loads a capture's
VRAM, sprite RAM, registers and palette through its ports, lets two ROM models answer the fetches,
runs a whole frame and compares the visible window with MAME's `reference.png`. Nothing from the
software model is in that comparison. Frames 300, 1200, 2400, 3600, 4800 and 6000: **64,512 of
64,512 each** on Verilator (about 7 s a frame), and on ModelSim for frame 6000. Frame 6000's
output scored against frame 4800's screenshot: 1,426.

**Now with the board's timing.** `gx_video.sv` contains the K053252 (jotego's `jtk053252`),
programmed through its port with the registers `daiskiss` writes (`01 7f 00 10 00 30 00 00 01 07
11 0e 73 00 00 00`, the same on every captured frame). `sim/k053252_gx_tb` measures what it
generates with them: **384 × 264 total, 288 × 224 visible**, as MAME's `res_change` decodes the
same registers. Sync sits one pixel and one line earlier than MAME's register names suggest
(front porch / sync / back porch 15 / 32 / 49 and 16 / 9 / 15, against 16 / 32 / 48 and 17 / 8 /
15). MAME never generates sync, so that is its naming, not a measurement. The dot clock is 6 MHz
(`wrport2 & 3` = 0, `pixclock[0]`), not the 8 MHz of `konamigx()`'s `set_raw`. The line is 64 µs
either way, and a pixel gets eight 48 MHz clocks. `hdump`/`vdump` are derived from the K053252's
blanking so that MAME's visarea origin (24, 16) is the first visible pixel (`gx_video.sv` header).
The bench records every pixel `gx_video`'s own blanking marks visible — exactly 64,512 — and
compares that list with MAME's screenshot, with no window position assumed. Frames 300, 1200,
2400, 3600, 4800 and 6000: **64,512 of 64,512 each** on Verilator, and on ModelSim for 3600.

What that does not yet cover: the CPU is not writing the state, the capture is; one game; the
interrupts the K053252 raises are generated but unchecked.

**The main board runs `daiskiss` from reset to its title, and the title is MAME's.**
`rtl/gx_main.sv` — TG68K.C, the Type 2 memory map, the interrupts, the 93C46, the ESC as a bus
master, `gx_video` — against MAME's trace of every write (`scripts/mame_sys_trace.py`,
`check_gx_main.py`). The K056800 is MAME's own replies, replayed. **RTL frames 1168-1170 are
identical to MAME's frame 1200 screenshot, 64,512 of 64,512 pixels**, from state the CPU and the
ESC wrote. The writes are compared per interrupt level (the RTL's interrupts land at other points
in the main program, its CPU being faster): **all 1,589,531 writes at mask 7 — the BIOS, the
memory tests, the setup — are identical, in order**; the ESC's level matches. The main program
diverges at MAME frame 801 on a sound-status reply that the in-order replay cannot follow, and
the vblank handler at frame 797 on work-RAM state set at a timing-dependent point; from there the
picture at matching points is the test. After boot the RTL runs 31 frames ahead of MAME.

Faults this found, each fixed (LESSONS_LEARNED has them): the bench's EEPROM image byte-swapped;
TG68K.C ignoring `MOVEC` to ISP, which the BIOS uses to set the game's stack
(`rtl/cpu/tg68k/PROVENANCE.md`); and the K055673 and K054338 register ports ignoring byte lanes,
which fetched blank sprite ROM for every sprite. Run on Verilator through GHDL's conversion of
TG68K.C, about 0.9 s a frame; a run can start from a saved snapshot (WORKFLOW).

The CPU's speed against MAME's: decoding a request on the clock it is taken and passing the ack
straight to the kernel gives a RAM access one wait state, Phase 0's budget. With the bench ROM
answering the clock after `rom_cs` (a cache hit), RTL frame 100 does what MAME does by its frame
112, 200 by 224, 300 by 333: **1.11× MAME** on this code. Before that change it was 0.58×. Phase 0
measured 1.001× for one wait state on a window of game code; this span is BIOS and memory tests.
MAME's 68EC020 timing is itself a model, so the figure to hold is the order of magnitude and the
`+ROM_WAIT` knob, not the last per cent.

One finding from the sprite stage: **`daiskiss` runs with K053246 OBJSET1 bit 1 (flip Y) set on every frame**,
and its picture is the right way up, because MAME negates Y twice (`oy = -oy` for the flip, then
`oy = (-oy - offy)`). On GX that bit set is the normal orientation, so the RTL must not read it as
"screen flipped".

Three things this stage found, all now in the model's comments:

- **K056832 colour granularity is 16 whatever the bit depth.** The driver decodes 5 bpp tiles with
  a 32-colour stride and then overrides it (`set_granularity(16)`), so a layer's bank is `PAL × 1024`
  pens — as furrtek's K055555 notes say. Modelled at 32 first, every pen came out exactly `0x800`
  high; the structure was right and only the colour wrong, which is what pointed at it.
- **`daiskiss`'s title frame is almost all sprites.** Both characters and the green are drawn by
  sprites over two full-screen black tilemap planes. A tilemap scored on that frame alone would pass
  black-on-black — the reason the stage is scored across five frames.
- **The background-fill stage is unverified.** No frame captured so far shows a background pixel,
  so a wrong fill would pass (LESSONS_LEARNED, "[Seta] A branch no capture exercises is not
  covered"). It needs a frame where the fill is visible.

What has been done is the survey, and two of its results changed the plan before it was written:

- **The chip inventory above.** It was found by listing the boards that use each GX chip and then
  looking at what those boards' cores contain, which is the method LESSONS_LEARNED's "*A web search
  returning nothing is not evidence that nothing exists*" prescribes after MS32 nearly missed an
  existing V70. Four of the seven custom video and sound chips a Type 2 board needs are in jotego's
  tree, under a licence this project can use, and one more is in furrtek's.
- **The scope arithmetic.** Type 3 and Type 4 GX boards drive **two monitors**, alternating frames
  between them through a demux board on the JAMMA connector (`screen_update_konamigx_left`:
  "the video gets demuxed by a board which plugs into the jamma connector"). That is not a rendering
  detail to be worked around later; it decides whether those thirteen sets are in the first scope at
  all. They are not.

**What has been read, and what has not.** The MAME driver, the video file, the memory maps, the
machine configs and every `ROM_START` were read directly. The jotego and furrtek modules were
identified from file listings, module headers, port lists and READMEs — not from reading their
implementations end to end. So "jotego has a K053252" is evidence that a port is the right plan; it
is not evidence that the port is small. Confirming that is Phase 0 work, and the first thing Phase 0
does with each vendored module is run it, unchanged, against a MAME reference.


**Phase 2 has started: the core builds.** `KonamiGX.sv` replaces the template: the PLL (96 MHz
SDRAM, 48 MHz board, 24 MHz CPU, one PLL at phase 0, so the three are related clocks and the
crossings are timed paths, no synchronisers), the SDRAM image (`rtl/memory/`: Sorgelig's
controller with Seta's burst-4 reads, the arbiter and download from Seta; this project's layout,
clock crossing and row spreading), a 16 KB ROM cache in front of the CPU (`rtl/cpu/gx_romcache.sv`,
a hit one wait state as the bench's ROM model was), inputs from `konamigx.cpp`'s ports, and
`arcade_video`. The K056800 is a mailbox echo until Phase 3.

The image: `maincpu` packed (BIOS, then 0x200000.. moved down by 0x1e0000), then the two graphics
regions with their 5-byte rows spread to 8 so a row is one granule -- 8/5 the space, 24 MB of the
32 MB module for daiskiss; a set whose graphics do not fit needs packed rows fetched as two
granules (`gx_sdram_top.sv` header). `scripts/build_mra.py` writes the `.mra` and proves it against
the region images; `scripts/check_gx_sdram.py` downloads that stream into the RTL against the
chip model and reads every region back: **900 samples of the three regions equal MAME's images**
on Verilator and ModelSim. It found the download losing every second byte when pushed a byte a
clock (fixed), and the vendored chip model modelling two banks: the sprite region is in bank 2,
above anything a sibling core's image reached (LESSONS_LEARNED).

**Ten sets have `.mra` files.** The image layout is per set (`rtl/gx_board_cfg.sv`, generated and
checked by `scripts/build_mra.py`): every 5 bpp Type 2 set -- daiskiss, crzcross, puzldama,
fantjour, fantjoura, gokuparo, mtwinbee, tbyahhoo, sexyparo, sexyparoa -- fits the 32 MB module
with its sound ROM still to come (18 to 26 MB used). The DIP switches come from the driver through
Seta's extractor and rules. The other Type 2 sets wait on their video paths: dragoonj's 4 bpp
sprites (16 MB, which the 8/5 spread would not fit either), tokkae/tkmmpzdm/salmndr2's 6 bpp,
le2/winspike's 8 bpp.

Quartus (`build_staged.py`, `KonamiGX_stp`): **timing met on every clock** (worst setup slack
1.06 ns), 14,748 ALMs (35%), 446 of 553 M10K (81%), 43 DSPs. The RAM figure is the one to watch
before the sound side arrives (its 64 KB RAM alone is 52 M10K).

**On the board.** The first build to run (`970423f`) took daiskiss through its RAM check to the
title; the builds since fixed what the board showed and the simulation had not: the sound-board
RAM tests (the K056800 stand-in, `rtl/gx_snd_stub.sv`, now answers the test the way the game's
own routine checks it, and holds the result until the next command), the 93C46's power-up state
(a sweep, then the set's default image from the `.mra`, LESSONS_LEARNED), and SYSTEM_DSW bit 15
(the gokuparo port set declares it active-high). tbyahhoo passes every RAM and sound test on
build 11 except the EEPROM's, which reads the part without writing it and needs the default
image. daiskiss stopped on its title from build 4 to build 16: the CPU's ready after an ESC
command was pulsed in a cycle the 24 MHz kernel does not sample, so the ESC ran the same command
for ever (LESSONS_LEARNED, found with ISSP instances H and I); on build 17 the attract runs
through its demo. tbyahhoo passes its checks with the default EEPROM image; it then waited
for a vblank interrupt that only MAME's syncen latch gives (build 18), and lost its sprites at
the first zoomed ones to a dropped sprite-ROM `ok` (build 20). On build 20 it runs its title and
demo with sprites. Open for it: a 16-line band and one screen area where a full-screen shadow
sprite is not drawn on a demo frame (the video bench, `tbyahhoo-f3200` with DMAEN set: 57,325 of
64,512 pixels), consistent with the line buffer's per-line drawing time running out.

## Game scope

Four ROM-board types share one motherboard. `konamigx.cpp` defines 42 sets; the table is generated
from each `ROM_START` (sizes are **loaded bytes**, i.e. what has to reach SDRAM, not the declared
`ROM_REGION` footprint — `maincpu`'s region is 8 MB on every set and is mostly holes).

| set | type | machine | total | maincpu | soundcpu | k056832 | k055673 | k054539 | psac | MAME flags |
|---|---|---|---|---|---|---|---|---|---|---|
| opengolf, opengolf2 | 1 | opengolf | 32.88 | 3.12 | 0.25 | 3.50 | 9.00 | 3.00 | 14.00 | IMPERFECT_GRAPHICS, **NOT_WORKING** |
| ggreats2 | 1 | opengolf | 31.88 | 2.12 | 0.25 | 3.50 | 9.00 | 3.00 | 14.00 | IMPERFECT_GRAPHICS, **NOT_WORKING** |
| racinfrc, racinfrcu | 1 | racinfrc | 26.88 | 5.12 | 0.25 | 1.50 | 10.00 | 4.00 | 6.00 | IMPERFECT_GRAPHICS, **NOT_WORKING**, NODEVICE_LAN |
| dragoonj, dragoona | 2 | dragoonj | 23.38 | 3.12 | 0.25 | 2.00 | 16.00 | 2.00 | — | IMPERFECT_GRAPHICS |
| winspike, winspikea, winspikej | 2 | winspike | 23.38 | 1.12 | 0.25 | 2.00 | 16.00 | 4.00 | — | IMPERFECT_GRAPHICS |
| le2, le2u, le2j | 2 | le2 | 19.88 | 0.62 | 0.25 | 8.00 | 8.00 | 3.00 | — | IMPERFECT_GRAPHICS |
| tokkae, tkmmpzdm | 2 | konamigx_6bpp | 16.88 | 1.12 | 0.25 | 1.50 | 10.00 | 4.00 | — | IMPERFECT_GRAPHICS |
| salmndr2, salmndr2a | 2 | salmndr2 | 15.25 | 1.12 | 0.12 | 5.00 | 6.00 | 3.00 | — | IMPERFECT_GRAPHICS |
| sexyparo, sexyparoa | 2 | sexyparo | 13.88 | 1.12 | 0.25 | 2.50 | 6.00 | 4.00 | — | IMPERFECT_GRAPHICS, IMPERFECT_SOUND, UNEMULATED_PROTECTION |
| gokuparo, fantjour, fantjoura | 2 | gokuparo | 12.88 | 1.12 | 0.25 | 2.50 | 5.00 | 4.00 | — | IMPERFECT_GRAPHICS |
| tbyahhoo, mtwinbee | 2 | tbyahhoo | 12.88 | 1.12 | 0.25 | 2.50 | 5.00 | 4.00 | — | IMPERFECT_GRAPHICS |
| crzcross, puzldama | 2 | gokuparo | 12.88 | 1.12 | 0.25 | 2.50 | 5.00 | 4.00 | — | IMPERFECT_GRAPHICS |
| sexyparoebl | 2 | sexyparoebl | 10.75 | 1.00 | — | 2.50 | 6.00 | — | — | bootleg, **NOT_WORKING** |
| daiskiss | 2 | konamigx | 8.38 | 1.12 | 0.25 | 2.50 | 2.50 | 2.00 | — | IMPERFECT_GRAPHICS |
| soccerss ×5 | 3 | gxtype3 | 19.38 | 2.12 | 0.25 | 1.50 | 12.00 | 2.00 | 1.50 | IMPERFECT_GRAPHICS |
| vsnetscr ×5 | 4 | gxtype4_vsn | 35.38 | 3.12 | 0.25 | 2.00 | 24.00 | 4.00 | 2.00 | IMPERFECT_GRAPHICS, IMPERFECT_SOUND |
| rungun2, slamdnk2 | 4 | gxtype4sd2 | 35.38 | 3.12 | 0.25 | 2.00 | 24.00 | 4.00 | 2.00 | IMPERFECT_GRAPHICS |
| rushhero | 4 | gxtype4 | 59.38 | 3.12 | 0.25 | 2.00 | 48.00 | 4.00 | 2.00 | IMPERFECT_GRAPHICS |

The `konamigx` BIOS set is not a game: the 128 KB `300a01.34k` BIOS is a region of **every** set's
`maincpu` and must appear in every `.mra`.

### Scope decision

- **In scope: the Type 2 sets.** Twenty-two working sets across nine machine configurations, 8.38 to
  23.38 MB, every one of them inside a 32 MB SDRAM module with room to spare. They share one memory
  map (`gx_type2_map`), one screen, and one chipset. That is the core.
- **Out of the first scope: Type 3 and Type 4** (`soccerss`, `vsnetscr`, `rungun2`, `slamdnk2`,
  `rushhero` and their clones). Two monitors, alternating frames, a second palette RAM, a second
  CRTC, a PSAC2 plane and a different protection device. `rushhero` at 59.38 MB does not fit a
  32 MB module in any case. Revisit as Phase 5 with an explicit decision about what a single MiSTer
  video output should show — MAME renders these into a 576-pixel-wide bitmap per monitor, which
  makes a side-by-side output at least arithmetically possible, but it is not what the cabinet did.
- **Out of the first scope: Type 1** (`racinfrc`, `opengolf`, `ggreats2`). All five sets are
  `MACHINE_NOT_WORKING` in MAME, they add an ADC0834, cabinet lamps, a K053936 road plane with 6 to
  14 MB of its own graphics, and `racinfrc` wants a K056230 LAN device MAME does not have. Two
  independent reasons; `opengolf` at 32.88 MB also exceeds 32 MB.
- **`sexyparoebl` is a bootleg** with the sound system replaced by two OKI6295s and no K054539, and
  is `MACHINE_NOT_WORKING`. Out.

First-target set is **`daiskiss`** (8.38 MB, plain `konamigx` machine config, 5 bpp tiles, ESC
protection) or **`gokuparo`/`fantjour`** (12.88 MB, same config with a sprite offset change). The
final choice is a Phase 0 decision and should be made on which boots furthest with the least
protection involvement, measured, not guessed. `tkmmpzdm` is the natural second target because its
ESC callback is the simplest one in the driver (`konamigx_esc_alert` with three constants and no
sprite-list construction).

## Hardware reality (from the driver, not assumption)

### Chips

| chip | role | in scope |
|---|---|---|
| MC68EC020 @ 24 MHz | main CPU | yes |
| MC68000 @ 8 MHz (`SUB_CLOCK/2`) | sound CPU | yes |
| TMS57002 @ 12 MHz (`MASTER_CLOCK/2`) | "DASP" effects DSP | **yes — all 22 sets use it** (Phase 0, criterion 5) |
| K053252 @ 6 MHz (`MASTER_CLOCK/4`) | CRTC / interrupt generator | yes |
| K054156 + K056832 | tilemap generator, 4 layers, 4–8 bpp | yes |
| K053246 + K055673 | sprite generator, 5–8 bpp | yes |
| K055555 | priority encoder / mixer ("PCU2") | yes |
| K054338 | alpha blender | yes |
| K056800 | main↔sound communication ("MIRAC") | yes |
| K054539 ×2 @ 18.432 MHz | PCM, 8 channels each | yes |
| EEPROM 93C46 (16-bit) | settings, and games check it at boot | yes |
| ESC ("E Security Chip") | protection, sprite-list DMA | yes, Type 2 |
| K053936 | PSAC2 rotating plane | Type 1/3/4 only — out |
| K053250 | declared in `konamigx.h`, **never instantiated** by any GX machine config | no |

The driver header's own summary of the chipset is worth reading before any of this is implemented;
it names which earlier Konami boards each chip is compatible with, which is the map to where the
existing FPGA work lives.

### Clocks

`MASTER_CLOCK` is 24 MHz and `SUB_CLOCK` 16 MHz, both marked `// TODO: check on PCB`.

| part | rate | source |
|---|---|---|
| 68EC020 | 24 MHz | `MASTER_CLOCK` |
| 68000 sound | 8 MHz | `SUB_CLOCK/2` |
| TMS57002 | 12 MHz | `MASTER_CLOCK/2` |
| K053252 | 6 MHz | `MASTER_CLOCK/4` |
| K054539 ×2, K056800 | 18.432 MHz | own XTAL |
| dot clock | 6, 8 or **12** MHz | the CCU table in the driver header gives HCH/HCL for 6M/288, 8M/384 and 12M/576 |

The default screen is `set_raw(8000000, 384+24+64+40, 0, 383, 224+16+8+16, 0, 223)` — an 8 MHz dot
clock, 512 total columns, 264 total lines, **59.21 Hz**, with a 384×224 active area of which the
common visible window is 288×224 (`set_visarea(24, 24+288-1, 16, 16+224-1)`). The driver's comment
says those are the actual values written to the CCU. Like MS32, **the video timing comes from CRTC
registers, not from constants**: the K053252 has a full programmable register file and the dot clock
is selectable. Unlike MS32, there is an FPGA implementation of that CRTC to port
(`jotego/jtcores/cores/rungun/hdl/jtk053252.v`, with its own testbench under `cores/rungun/ver/k053252`).

An exact clock plan is a Phase 0 output, but the arithmetic already narrows it: a 48 MHz `clk_sys`
divides exactly to 24 (CPU), 12, 8 and 6 MHz (all three dot clocks) and 8 MHz (sound 68000), and
96 MHz does the same with one more halving. 18.432 MHz for the K054539 pair needs its own PLL
output. See "Design decisions" for why `clk_sys` and the CPU clock probably cannot be the same
domain.

### Interrupts

Four levels on the 68EC020, from the driver header and `konamigx_type2_vblank_irq`:

| level | source | ack |
|---|---|---|
| 1 | vblank, 60 Hz | `d56001` bit 0; `m_gx_syncen` bit 5 arms it |
| 2 | hblank, programmable scanline | `d56001` bit 1; only Lethal Enforcers 2 installs the scanline timer, and MAME `popmessage`s "HBlank IRQ enabled, contact MAMEdev" when it fires |
| 3 | sprite-DMA complete | `d56001` bit 2, after a delay MAME models as 342+42 µs at 6/12 MHz dot clock or 256+32 µs at 8 MHz |
| 4 | ESC command complete | `d56001` bit 3 |

`d56001`'s high nibble is the per-level enable and the low nibble the acknowledge, and
`m_gx_wrport1_1` holds it. Every interrupt in the driver is `HOLD_LINE`, and there is a comment that
`ASSERT_LINE` on level 1 "breaks opengolf" — a divergence to record rather than to reason about.
The K053252 generates INT1/INT2 in hardware (`int1_ack`/`int2_ack` are wired to the driver), which
the jotego module already models (`int1`, `int2`, `int1ack`, `int2ack` in `jtk053252.v`).

### Memory map (Type 2, `gx_base_memmap` + `gx_type2_map`)

| region | window | size | notes |
|---|---|---|---|
| BIOS ROM | `000000` | 0x20000 | `300a01.34k`, shared by every set |
| Program ROM | `200000` | 0x200000 | `ROM_LOAD32_WORD_SWAP` pairs |
| Data ROM | `400000` | 0x400000 | sparse on most sets |
| Work RAM | `c00000` | 0x20000 | 128 KB |
| ESC command port | `cc0000` | 4 | Type 2 only |
| K056832 ROM readback | `d00000` | 0x2000 | `k_5bpp_rom_long_r`, for the memory test |
| Sprite RAM | `d20000` | 0x4000 | 16 KB; DMA'd to a 0x1000-byte shadow |
| K056832 registers (VACSET) | `d40000` | 0x40 | |
| Tile bank selectors (VSCCS) | `d44000` | 0x10 | also the LE2 gun inputs, installed over it by `init_konamigx` |
| K053246 registers (OBJSET1) | `d48000` | 8 | |
| K055673 ROM readback (OBJSET2) | `d4a000` | 0x10 | |
| K055673 registers | `d4a010` | 0x10 | |
| K053252 CCU1 | `d4c000` | 0x20 | `umask32(0xff00ff00)` |
| CCU2 | `d4e000` | 0x20 | `nopw` on Type 2 |
| K055555 (PCUCS) | `d50000` | 0x100 | write-only |
| K056800 sound comms | `d52000` | 0x20 | `umask32(0xff00ff00)` |
| EEPROM / watchdog | `d56000` | 4 | bit 7 watchdog, and `d56001` is the IRQ enable/ack byte |
| Control register (WRPOR2) | `d58000` | 4 | OBJCHA, 68000 enable/disable |
| DIPs and service | `d5a000` | 4 | two DIP banks, service switch, EEPROM data/ready |
| Player inputs | `d5c000` | 4 | |
| Test switch | `d5e000` | 4 | |
| K054338 | `d80000` | 0x20 | |
| Palette RAM | `d90000` | 0x8000 | 8192 entries × 32 bits, xRGB_888 |
| Tilemap RAM window | `da0000` | 0x4000 | two 8 KB windows into 16 banked pages |

### Video

Everything is 8×8 tiles on four tilemap layers plus one sprite plane, and the palette is 24-bit
`xRGB_888` — no 5-bit colour conversion anywhere, unlike the earlier Konami boards jotego's modules
were written for. That difference has to be checked against every ported module's colour path.

**Tilemaps (K054156 + K056832).** Four layers (A, B, C, D) built from pages of a 4×4 page grid, each
page 64×32 tiles. Each tile is two 16-bit words. MAME allocates `0x2000 * (16 + 1) / 2` u16
(136 KB) for the whole thing; the CPU sees 16 KB of it at a time through `da0000`, banked by a write
to `d40033`. The colour depth is per-game (`K056832_BPP_4/5/6/8`), and the tile callback is
per-game too — five different ones in this driver, one of which (`alpha_tile_callback`, used by
`sexyparo` and `winspike`) reads a bit out of the tile attribute to drive the K054338 blend.

Line scroll, row scroll and plain X/Y scroll are per-layer two-bit modes. Global H and V flip carry
signed correction registers. All of this is in jotego's `jt05415x`, which was reconstructed from
furrtek's 054156 and 054157 schematics; its README states plainly that where MAME's comments and the
silicon-derived logic disagree, the silicon is taken as the source of truth. That is a different
accuracy target from this project's (MAME is ours, because there is no GX PCB here) and the
difference has to be watched, not assumed away.

**Sprites (K053246 + K055673).** 256 sprites in a 0x1000-byte list DMA'd out of the 16 KB sprite RAM
at vblank — `konamigx_objdma()` is a `memcpy`, not a bank swap. Eight 16-bit words per sprite:
active bit, aspect-ratio lock, flip X/Y, a 4-bit size field, an 8-bit z-code, a 16-bit tile code,
10-bit X and Y, 16-bit zoom X and Y where 0x40 is 1:1, mirror X/Y, a shadow code, an effect code and
a "colour" field whose meaning depends on external wiring. MAME draws them into a software z-buffer
with 256 shadow entries alongside, sorted by z-code.

Four ROM layouts appear across the game list — `GX` (5 bpp, assembled at runtime from a 4 bpp region
plus a 1 bpp region), `GX6` (6 bpp), `LE2` (8 bpp) and `RNG` (4 bpp, used by `dragoonj`). Only `RNG`
is what jotego's Run and Gun core exercises, so the higher depths are the extension work on that
port.

**The mixer (K055555 + K054338).** This is the least-determined part of the hardware and the only
part with no implementation anywhere. What is known:

- MAME's `k055555.cpp` is a 128-entry write-only register file with named offsets
  (`K55_PALBASE_*`, `K55_PRIINP_0..11`, `K55_BLEND_ENABLES`, `K55_SHAD*_PRI`, `K55_VBRI`,
  `K55_INPUT_ENABLES`, ...). It does no mixing.
- The mixing is `konamigx_mixer()` in `konamigx_v.cpp`: build a list of up to 256 sprites plus
  6 layers, sort by priority, draw back to front into a z-buffer, with per-layer colour-depth
  decode, shadow/highlight, brightness and alpha decisions taken per object.
- furrtek's [`Konami/055555/README.md`](https://github.com/furrtek/SiliconRE/tree/master/Konami/055555)
  adds what the die shows: 4 scroll layers, 1 sprite layer, 3 sub layers; selectable 4/5/6/7/8 colour
  bits per input; a palette-RAM bank per layer; 2-bit MIX and BRIGHT codes per layer routed to the
  K054338; a 512-colour background gradient with H or V auto-map. Registers are write-only, and only
  four have a defined reset state.

So the mixer gets MAME's behaviour transcribed first and furrtek's register description used to
explain it, in that order. See "Design decisions".

### Sound

68000 at 8 MHz, 0x40000 of ROM, 64 KB of RAM at `100000`, two K054539s sharing one 2–4 MB sample ROM
at `200000` (one on each byte lane of a 16-bit access — `umask16(0xff00)` and `umask16(0x00ff)`),
the TMS57002 at `300001`, the K056800 at `400000` and a status/control word at `500000`.

Interrupts: K056800 raises IRQ 1 on a message from the 68020; the first K054539's timer raises
IRQ 2, gated by bit 0 of the sound control word.

The TMS57002's data space is `map(0x00000, 0x3ffff).ram()` — 256K words of external RAM in MAME's
model — and it is routed at 0.3 gain into the K054539s' aux inputs against their 1.0, so its
contribution is effects rather than primary audio.

**Every in-scope game uses it.** `scripts/dasp_survey.py` taps the sound 68000's writes to the DSP's
control word and data port over the first 60 s of attract mode: all 22 sets drive it into
program-load mode, 12 to 28 times each, and all but the three `le2` sets also load coefficients. So
the DSP is not optional — it is a fifth block with no FPGA implementation anywhere, alongside the
K055555, the ESC and the two colour-depth extensions. The fallback, if it proves too large, is to
run the games without it: the K054539 outputs carry the primary audio on their own, and what would be
lost is the effects mix. That is a Phase 3 decision, and it needs listening to MAME with the DASP's
four routes muted before it is made.

What the survey does **not** establish is what each upload contains. The chip's program space is
256 words (`tms57002.cpp`, `internal_pgm`: `map(0x00, 0xff)`), yet every set has upload sessions of
1,023 bytes — more than a full program's 774 under the simple three-bytes-per-word model. Either a
session carries more than one program, the program counter wraps, or the stream is not what that
model assumes. It has to be settled before the DSP is designed, not after.

### Protection

**ESC**, on the Type 2 boards (`cc0000`). A microcontroller with external SRAM whose microprogram
the game uploads; MAME does not run it, it recognises three opcodes at a magic-word header
(`0xfef724fb`) — reset, load 4096 bytes of program, and run — and dispatches "run" to a per-game
C function. Six games have one:

| set | callback | what it does |
|---|---|---|
| `tbyahhoo`, `mtwinbee` | `tbyahhoo_esc` | `generate_sprites(0xc00000 → 0xd20000, 0x100)` |
| `daiskiss` | `daiskiss_esc` | same |
| `sexyparo`, `sexyparoa` | `sexyparo_esc` | `generate_sprites(0xc00604 → 0xd20000, 0xfc)` |
| `tkmmpzdm` | `tkmmpzdm_esc` | `konamigx_esc_alert(workram, 0x0142, 0x100, 0)` |
| `dragoonj`, `dragoona` | `dragoonj_esc` | `konamigx_esc_alert(workram, 0x5c00, 0x100, 0)` |
| `salmndr2`, `salmndr2a` | `sal2_esc` | `konamigx_esc_alert(workram, 0x1c8c, 0x172, 1)` |

`generate_sprites` walks up to 256 records of 0x100 bytes in work RAM, follows a per-record pointer
into a variable-length display list in ROM, applies zoom-scaled offsets and four different colour
transforms, and writes at most 256 eight-word sprite records. It is bounded, it is entirely
integer, and it is a straightforward microsequencer in RTL — but it has DMA access to the whole
68020 map, so it is a bus master and has to be designed as one from the start.

**Type 4** uses a different device (a Xilinx FPGA, per the driver comment) at `cc0000` with its own
command set; out of scope with Type 4.

### Per-game configuration

`gameDefs[]` in `konamigx.cpp` gives each set a `cfgport`, a `readback` selector and a tile-ROM
readback format (`BPP4/5/6/66`), and `init_konamigx`'s switch adds per-game handlers — the Lethal
Enforcers 2 light guns at `d44000`, a `tkmmpzdm` ROM patch, and so on. Together with the machine
config differences (sprite X/Y offsets, K056832 bpp, tile and sprite callbacks, CRTC offsets) that
is the whole per-game surface, and all of it is `.mra` mod-byte configuration rather than a
compile-time split. Sprite offsets alone range from −26 to −132 in X.

## Component reuse map

Every row's "source" is a file that was located and whose header was read. None has been compiled
here yet.

| block | plan | source |
|---|---|---|
| **68EC020** | **TG68K.C**, `CPU => "11"`, with this project's own bus wrapper. Proven in `Arcade-Psikyo_MiSTer` at 16 MHz including `MOVEC`/`CACR` | [TobiFlex/TG68K.C](https://github.com/TobiFlex/TG68K.C), LGPL-3.0-or-later. Psikyo's `rtl/cpu/maincpu.sv` is the integration reference and its `PROVENANCE.md` the warning list |
| **68000 (sound)** | **fx68k**, cycle-accurate, already vendored and running in `Arcade-Seta_MiSTer` | `Arcade-Seta_MiSTer/rtl/cpu/fx68k/` |
| **K053252 CRTC** | **Port `jtk053252.v`** | `jotego/jtcores/cores/rungun/hdl/jtk053252.v` (+ `cores/rungun/ver/k053252/` testbench), GPL-3.0-or-later. furrtek has the schematic and a netlist |
| **K054156/K056832 tilemaps** | **Written from the software model** (`rtl/video/gx_tilemap.sv`); `jt05415x` did not fit — 4 VRAM pages, no pixel path (see "Progress"). Kept as the reference for line scroll and flip | `jotego/jtcores/modules/jt05415x/`, GPL-3.0-or-later, reconstructed from furrtek's 054156/054157 schematics |
| **K053246/K055673 sprites** | **Port `jt053246.sv` + `jt053246_mmr.v` + `jt053246_scan.sv` + `jtsimson_obj.v`**, extend the graphics side to 5/6/8 bpp. **Not `jt053246_dma.v`'s slot-per-z-code sort**, which loses most of `daiskiss`'s sprites: RAM-order scan and a z-compared line buffer instead (see "Progress") | `jotego/jtcores/cores/simson/hdl/`, as wired by `cores/rungun` (which drives a real K055673), GPL-3.0-or-later |
| **K054338 alpha blender** | **Port `jt054338.v`**, which already has the `ALPHA_INV` parameter GX's `set_alpha_invert(1)` needs | `jotego/jtcores/cores/moo/hdl/jt054338.v`, GPL-3.0-or-later |
| **K055555 mixer** | **From scratch.** MAME's `konamigx_mixer()` transcribed literally; furrtek's register notes as the explanation. `jtmoo_colmix.v` is the shape of the surrounding wiring even though its priority chip is the earlier K053251 | `konamigx_v.cpp`, `k055555.cpp/.h`, furrtek `Konami/055555/README.md` |
| **K054539 ×2 PCM** | **From scratch** against MAME's `k054539.cpp` (`rtl/sound/gx_k054539.sv`); furrtek's HDL is not used ([`THIRD-PARTY.md`](../THIRD-PARTY.md)) | [furrtek/SiliconRE `Konami/054539/hdl/`](https://github.com/furrtek/SiliconRE/tree/master/Konami/054539) (41 KB of Verilog plus ROM contents dumped from the die). jotego's `jt539` is used by `moo`, `xmen` and `rungun` but is a **private submodule** and 404s |
| **K056800 sound comms** | Small. `jt054321.v` is the same family and is a starting point | `jotego/jtcores/cores/riders/hdl/jt054321.v`; MAME `sound/k056800.cpp` |
| **ESC protection** | **From scratch**, as a bus-mastering microsequencer reproducing MAME's C | `konamigx.cpp:generate_sprites`, `esc_w`, and `konamigx_m.cpp:konamigx_esc_alert` |
| **EEPROM 93C46** | `jt5911.sv`, or the pattern from the sibling cores | `jotego/jteeprom`, GPL-3.0 |
| SDRAM backend | Psikyo/Seta's `sdram.sv` + arbiter + download path, **including Seta's `dq_in` capture fix** | `Arcade-Seta_MiSTer/rtl/memory/` |
| DDRAM backend | Psikyo's `ddram_phy`/`ddram_arbiter`/`ddram_download` | `Arcade-Psikyo_MiSTer/rtl/memory/` |
| Debug probe, tracer, counters, pause | Port from Seta with header comments intact | `Arcade-Seta_MiSTer/rtl/debug/` |
| Top-level framework | **MiSTer-devel/Template_MiSTer** (already checked in) | this repo's `sys/` |
| **TMS57002 DASP** | **From scratch — required.** All 22 in-scope sets load programs into it. No implementation found anywhere | MAME `cpu/tms57002/` is the behavioural reference |

## On-chip RAM budget

The DE10-nano's `5CSEBA6U23I7` has 553 M10K blocks = 5,662,720 block memory bits. GX's declared
memories, before anything the core needs for itself:

| RAM | bytes | bits | % of device |
|---|---|---|---|
| Tilemap VRAM (16 pages + 1) | 139,264 | 1,114,112 | 19.7% |
| Work RAM | 131,072 | 1,048,576 | 18.5% |
| Sound 68000 RAM | 65,536 | 524,288 | 9.3% |
| Palette RAM | 32,768 | 262,144 | 4.6% |
| Sprite RAM | 16,384 | 131,072 | 2.3% |
| Sprite DMA shadow | 4,096 | 32,768 | 0.6% |
| K055555 register file | 128 | 1,024 | — |
| **Total** | **389,248** | **3,113,984** | **55.0%** |

55% before a line buffer, a ROM cache, a K054539 channel-state RAM or the K053252's registers. That
is the whole reason the sprite plane's structure is not an open question: **GX sprites are rendered
per scanline into a line buffer, not into a frame buffer.** 256 sprites per frame is what the
K053246 walks, and jotego's implementation is already line-based (`ln_done`, `hdump`, `vdump`,
`pxl_cen`), which is the hardware's own structure and the one this budget can afford. MAME's
z-buffered whole-frame draw is a software convenience, not a description of the chip.

Two numbers in that table need checking rather than trusting, and both are Phase 1 tasks:

- **The tilemap VRAM figure is MAME's allocation, not the board's.** jotego's Moo Mesa wiring is
  three 8 K × 8 SRAMs (24 KB) for the same chip pair, because that is what that PCB populates. GX
  banks 16 pages through a 16 KB window, which suggests all sixteen are present, but a MAME write
  tap across the game list is what settles it, and the answer is worth up to 900 Kbit.
- **The sound 68000's 64 KB** is a plain `.ram()` in MAME's map. If the board populates less, the
  same tap finds it.

Three rules from LESSONS_LEARNED apply to every one of those arrays and are cheap now, expensive
later: every inferred RAM gets a **power-of-two depth**; any true dual-port array is **one
`always_ff` with both ports in it**; and driving a second read port on a RAM Quartus has already
decided is single-port **replicates the array**. The palette is read at pixel rate by a mixer that
takes several lookups per pixel, so it is the array those rules will bite on first.

## Memory plan

Target: a **32 MB** MiSTer SDRAM module, because that is what most people have. The largest in-scope
set is 23.38 MB.

| what | where | why |
|---|---|---|
| BIOS + program + data ROM, `k056832`, `k055673`, `soundcpu` | SDRAM | hard real-time fetch budgets for the graphics; the CPU needs low latency |
| `k054539` sample ROM (2–4 MB) | SDRAM, or DDR3 behind a sample cache | latency-tolerant; decide by measurement once the SDRAM client count is known. There is room either way at 23.38 MB |
| Everything in the RAM table above | BRAM | CPU-random-access or pixel-rate |

The SDRAM-over-DDRAM rule in LESSONS_LEARNED is about **hard real-time fetch budgets**. Tilemap and
sprite graphics fetch has a per-scanline deadline and belongs on SDRAM. A PCM sample cache does not,
and neither does the CPU's data ROM. Both need measuring rather than assuming, and both need that
stated in their port comments.

The `maincpu` window is sparse — 0x20000 of BIOS at 0, up to 0x200000 of program at `0x200000`,
up to 0x400000 of data at `0x400000`, of which most sets fill under 1.2 MB in total. The SDRAM map
packs the three pieces and translates; it does not reproduce the 8 MB hole.

## Design decisions

**The CPU probably cannot share `clk_sys`, and the measurement that says so is already in hand.**
TG68K.C has no clock enable of its own: with `clkena_in` gating the kernel, the kernel is clocked at
`clk_sys` and *enabled* at the CPU rate, so `clk_sys` must clear the kernel's Fmax. Psikyo measured
that Fmax on the real post-fit netlist, Cyclone V speed grade 7, at **48.74 MHz**, with all fifty
worst-slack paths inside `TG68KdotC_Kernel`. A 48 MHz `clk_sys` — the rate that divides exactly to
every GX clock — leaves 1.5% margin against a measurement taken in a different design. So the plan
is the MS32 shape: a dedicated `clk_cpu` at 24 MHz with `clkena_in` tied high, `clk_sys` chosen for
the video and memory path, and a real clock-domain crossing between them. Phase 0 measures TG68K.C
standalone at this project's settings and the decision is made on that number, in the same commit.

**Instantiate `TG68KdotC_Kernel` directly and own the bus interface.** `TG68K.vhd` is an
async-68000-bus adapter that assumes `CLK` *is* the CPU clock; Psikyo's PROVENANCE records what
happened to the attempt to slow it down from the outside. The kernel is entirely rising-edge and
exposes `clkena_in` for exactly this.

**Budget for the missing instruction cache.** The real 68EC020 has a 256-byte direct-mapped
instruction cache and the GX BIOS enables it (`movec D0,CACR` at `000410` in the disassembly Psikyo
captured from the same family of code). TG68K.C has none, and exposes `CACR_out` so the wrapper can
see that the game asked for one. MS32 found that its CPU spent 73% of its cycles refilling from a
32-bit data adapter and that an instruction port served in one clock took CPI from 20.1 to 7.57.
The same lever exists here and should be designed in from Phase 2 rather than retrofitted. What the
gap actually is on GX is a Phase 0 measurement, not an assumption.

**This core is GPL-3.0-or-later. Decision taken; `LICENSE` carries the GPLv3 text.** TG68K.C is LGPL-3.0-or-later and
jotego's modules are GPL-3.0-or-later; the combination is lawful only because every file in `sys/`
reads "either version 2 of the License, or (at your option) any later version". The consequence is
permanent in one direction: code can flow in from GPL-2-or-later MiSTer cores and cannot flow back
out to them. **GPLv3 §5(a) requires every modified vendored file to carry prominent notice that it
was changed, and a date.** jotego's files carry SPDX headers; our changes append to them and never
replace them. `sys/` is never edited.

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no GX
PCB here. That makes MAME the accuracy target and its acknowledged guesses inherited deliberately:
the `HOLD_LINE` interrupts and the comment that `ASSERT_LINE` breaks `opengolf`; the sprite-DMA
delay constants; `m_gx_rushingheroes_hack`; the `tkmmpzdm` ROM patch; the mixer, described in its own
source as needing hardware tests. Each goes in `docs/MAME_KLUDGES.md` when it is implemented, with
what MAME does, what the hardware is suspected to do, and what would settle it. Seta's and MS32's
files of the same name are the model.

**But the ported modules are not MAME's, and that is a conflict to manage, not to ignore.**
jotego's `jt05415x` README states that where MAME and the silicon disagree, the silicon wins. This
project's reference is MAME. Both positions are correct for their own project, and the place they
collide is the first frame that does not match. The rule: when a ported module disagrees with MAME,
**record it in `docs/MAME_KLUDGES.md` and keep the module's behaviour**, because a silicon-derived
disagreement is evidence about the hardware and MAME's is evidence about nothing except MAME. Do
not "fix" a ported module towards MAME without understanding which of the two is describing the
chip.

**Transcribe the mixer from MAME literally first, then look for the chip.** The K055555 is a lookup
and priority network with about fifty named registers and no implementation to check against.
The Psikyo lesson "read both halves of a mechanism before changing it" says to build MAME's version,
get pixel-exact agreement with captured frames, and only then experiment — with the experiment on an
OSD switch so it is an A/B, not a rebuild.

**One `.rbf` for all games.** Per-game differences are sprite offsets, tile and sprite callback
variants, K056832 colour depth, the ESC callback selection, the LE2 gun inputs and ROM region sizes.
All of them are `.mra` mod-byte configuration.

**Two Quartus revisions, `KonamiGX_stp` and `KonamiGX`,** differing only by a `DEBUG_ISSP` macro, as
in Seta and MS32. See [`WORKFLOW.md`](WORKFLOW.md).

## Pitfalls that already bind decisions here

These are the entries from [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) that are not general advice but
already constrain something written above. Read the entry, not the summary.

| Entry | What it binds here |
|---|---|
| *[MS32] A web search returning nothing is not evidence that nothing exists* | The whole component reuse map. It was built by enumerating the boards that use each chip and then looking at those boards' cores — not by searching for the chip number |
| *Suspect your own integration before any vendored module* | Seven of the eleven major blocks will be vendored, from two upstreams, and every one of them runs in a shipping core. When GX misbehaves, the wiring, the memory map and the clock domains are ours |
| *Treat a conspicuous omission in a vendored module as deliberate* | `jtk053252.v` says "the clock divider is not implemented. Apply the expected pxl_cen directly". That is a documented interface decision, not a gap to fill |
| *Re-run the regression on a clean stash before debugging your change* | jotego's modules arrive with testbenches (`cores/rungun/ver/k053252`, `cores/aliens/ver/*`). Run them on arrival, before touching anything, so a porting failure is never mistaken for a GX change |
| *A design can be BRAM-bound while logic sits at 40%* | The RAM budget section. 55% before any core RAM, and it is why the sprite plane is line-based from the start |
| *An inferred RAM must have a power-of-two depth* | Every array in that table. 136 KB of tilemap VRAM is 17 pages, which is not a power of two — the seventeenth page is MAME's scratch page and must not become a seventeenth M10K bank by accident |
| *A true dual-port RAM must be ONE always block* | The palette, which the mixer reads more than once per pixel |
| *Driving a dual-port RAM's second read port can silently REPLICATE the array* | Same array. 262,144 bits replicated is 4.6% of the device per copy |
| *A region whose base is not aligned to its size must be indexed by subtraction* | The tilemap window is two 8 KB halves at `da0000` and `da2000` inside one decode, and the palette sub-banks are per-layer offsets set by `K55_PALBASE_*`, not maskable windows |
| *An unbacked RAM region does not read as garbage, it reads as a failed power-on memory test* | GX has two readback paths that exist only for the memory test — `d00000` (`k_5bpp_rom_long_r`) and `d4a000` (`k055673_rom_word_r`). Both must return what MAME returns before any boot failure is blamed on transport |
| *[Seta] Decode the RAM a power-on test walks, even the RAM nothing else uses* | Same, and it is why the tilemap-VRAM measurement above must be a write tap over a boot, not over an attract mode |
| *[Seta] Read the interrupt vectors before trusting a board's interrupt config* | Four levels, `HOLD_LINE`, a shared enable/ack byte at `d56001`, and a driver comment saying `ASSERT_LINE` breaks a game. Read the vectors before trusting any of it |
| *Give a held interrupt line's acknowledge priority* | `d56001`'s low nibble acknowledges and its high nibble enables, in one byte, and levels 1, 3 and 4 can all be pending at once |
| *DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU* | The CPU sits in its own clock domain under `clkena_in`; every ready crossing into it must survive the crossing |
| *Derive the clock-enable ratio exactly rather than rounding* | 24, 12, 8 and 6 MHz all divide exactly from 48 MHz. Nothing here needs a Bresenham accumulator — check that it stays true before adopting any other `clk_sys` |
| *Budget for the 68k core to be the Fmax-limiting block* | 48.74 MHz measured, and the reason `clk_sys` and `clk_cpu` are planned as separate domains |
| *Instantiate `TG68KdotC_Kernel` directly and own the bus interface* | Stated as a design decision above; the alternative was tried on Psikyo and failed |
| *A swap is not a copy* | `konamigx_objdma()` is a `memcpy` into a 0x1000-byte shadow. Do not ping-pong it |
| *[Seta] A snapshot is a race with whoever writes the thing being copied* | That same copy runs at vblank, which is when the game's vblank handler rewrites the list. MAME's `memcpy` is atomic and an RTL copy is not |
| *[Seta] A golden frame taken after vblank cannot check what pairs with what across vblank* | The sprite list is DMA'd at vblank and drawn from the copy. A one-frame reference cannot check that pairing; the bench has to run two |
| *[Seta] A back-to-front line buffer cannot drop the right sprites* | 256 sprites sorted by an 8-bit z-code. Overflow must drop what the chip drops — carry the index, do not encode priority in write order |
| *[Seta] Estimate the worst case from the hardware, not from the frames you happened to look at* | 256 sprites, each up to 128×128 at zoom, against 264 lines. Instrument the RTL for worst-line and worst-frame counts from the first build |
| *Copy a driver's register expression including its operators* | `zoom = 0x40` is 1:1 and larger values *reduce*; the K053252 stores `0x1000 - value`-style counts; `K55_CTL_FLIPPRI` reverses the whole priority sense. Inverted senses before any video RTL exists |
| *[Seta] Two MAME conventions that read backwards* | The sprite list is walked and the pixel op is priority-masked; which end lands on top is decided by both, and MS32 paid for assuming one |
| *Treat the map-digit rule as mechanical and check it* | The twenty-two in-scope sets use **eleven** distinct load forms: `ROM_LOAD`, `ROM_LOAD16_BYTE`, `ROM_LOAD32_BYTE`, `ROM_LOAD32_WORD`, `ROM_LOAD32_WORD_SWAP`, `ROM_LOAD64_WORD`, and five `ROMX_LOAD` macros (`TILE_WORD`, `TILE_BYTE`, `TILE_WORDS2`, `TILE_BYTES2`, `_48_WORD`) with `ROM_GROUPDWORD`/`WORD`/`BYTE` and `ROM_SKIP(1/2/4)`. Four different interleaves in one `.mra` |
| *Prove the interleave against MAME's disassembly offline, before building* | The 5 bpp sprite region is *assembled at runtime* by MAME from a 4 bpp region plus a 1 bpp region. The `.mra` has to produce what the RTL expects and the RTL has to expect what the chip reads — prove it offline, in both directions |
| *A hardware-vs-image comparison cannot detect a wrong image* | Directly applicable to that assembled 5 bpp region |
| *Never hold the memory path in the core reset* | The download path runs while MiSTer holds core `RESET` asserted |
| *List `<rom index="1">` before `<rom index="0">` when a mod byte gates download-time logic* | The per-game mod byte selects sprite offsets, bpp and ESC variant |
| *[Seta] A `<dip>`'s `bits` is a range, "first,last", not a list* | GX has two 8-position DIP banks plus a service and a test switch |
| *A correct `.mra` DIP block still needs one line in CONF_STR* | `"DIP;"` goes in CONF_STR in the same commit as the first `.mra` |
| *Make the all-zero configuration the correct one* | Every OSD debug switch, from the first one |
| *[Seta] Check flip screen against the rotation, not against the emulator* | `le2u` and `le2j` are `ORIENTATION_FLIP_Y` sets and the K054156 has global H/V flip with signed correction registers |
| *[Seta] A bidirectional bus captured into four lane registers gets one I/O register and three lottery tickets* | Port Seta's fixed `sdram.sv`, the one that does `dq_in <= SDRAM_DQ` unconditionally |
| *[Seta] A liveness test needs a timescale* | GX boot length is unknown. Measure it before asserting that anything should have happened by frame N |
| *Ask of every stimulus whether it is the shape the real system produces* | vblank is held for a blanking interval and the 68020's IPL lines stay asserted while a level is pending |
| *[Seta] A constraint proved in a side project is not in your design* | Phase 0's TG68K.C measurement is a side project. Its SDC moves with its measurement, in the same commit |
| *[Seta] A clean STA summary is a property of one placement, not of the design* | Record the seed in `BUILT_COMMIT`. When a build regresses games the diff cannot reach, rebuild the same commit at another seed first |
| *Open the STA summary before believing any hardware-vs-simulation divergence* | `build_staged.py` gates on it; do not route around the gate |
| *[MS32] Do not edit a script or a source file while a run that reads it is in flight* | And the build/probe lock below is the enforced half of the same rule |

## Phased roadmap

**Phase 0 — Vendoring spike and the CPU measurement. The gate.**

Vendor TG68K.C, fx68k, and each jotego module into `rtl/` with a `PROVENANCE.md` per directory
recording the upstream commit and the licence. Run every upstream testbench that came with them,
unchanged, before editing anything. Stand TG68K.C up in its own Quartus project
(`rtl/synth_check/`, Seta's pattern) with the bus wrapper and the SDRAM transport and nothing else.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.** A vendored block that fails its
   own tests is a porting problem, and finding that out after GX-specific edits is how a day is lost.
   — **Met, as far as tests exist.** Only the K053252 arrived with one; its differential bench
   against furrtek's silicon-derived reference passes (`scripts/run_jt_unit.sh k053252_tb`). The
   sprites, tilemaps and K054338 have none upstream, so their regression is Phase 1's model.
2. **TG68K.C boots the first target's program ROM and matches MAME's bus trace**, diffed access by
   access as a subsequence with duplicates collapsed (Seta's method), every peripheral stubbed to
   whatever MAME's would return. This is the test that catches a wrong interleave, a wrong reset
   vector and wrong DTACK behaviour in one run, and none of TG68K.C's prior use here ran GX's
   `ROM_LOAD32_WORD_SWAP` layout.
   — **Met for `daiskiss`.** The program-ROM image was proven first, offline: 1,049,951 of 1,049,951
   MAME reads agree with it, where the three wrong permutations of the same two files score 12–21%.
   Then `sim/gx_boot_tb` over 1.2M accesses: **194 of 194 writes** match MAME in address, lanes, data
   and order, both I/O reads match, and every MAME ROM read in the window is covered. The RTL's
   first program-ROM read is at access 884,944 — **the same access number as MAME's** — and it is
   executing the game's program when the run ends. Not yet exercised: interrupts, since the window
   contains none.
3. **Measured CPI on real game code**, against the 24 MHz the board runs at, with the split between
   execution and memory stall reported the way Model 1 and MS32 did. The number that matters is not
   CPI but which half of it a wider instruction port can move.
   — **Measured, and it sets the memory budget.** Between two writes inside the game's program
   (the 31st and 49th byte writes to `0xD56000`, ~197,000 accesses of game code — not the BIOS
   checksum), MAME's 68EC020 takes **394,808 cycles** at 24 MHz, ±~1% (each mark can be early by one
   6 kHz scheduler quantum). TG68K.C takes **197,592 kernel clocks** of execution — it makes almost
   exactly one bus access per clock — so its zero-wait floor is **0.50×** the board. The bench's own
   one-wait-state handshake lands at **1.001×**. So at a 24 MHz `clk_cpu`, **the memory system has
   a budget of one wait state per access on average** to match the real board; zero-wait would be
   2× faster, two wait states 1.5× slower. That is the target the Phase 2 instruction path is sized
   against.
4. **Standalone Fmax and area for TG68K.C at this project's settings**, on Cyclone V speed grade 7,
   with the constraint that proves it committed **in the same commit as the measurement**. Starting
   point: 48.74 MHz in the Psikyo design. This decides the clock plan.
   — **Met: 48.97 MHz** at the slow 100°C corner, 2,927 ALMs, 6 DSPs, 2 M10K
   (`rtl/synth_check/tg68k/`). The limit is the register-file bypass network, as on Psikyo. A shared
   48 MHz `clk_sys` would leave 2.0%; a dedicated 24 MHz `clk_cpu` leaves ~2×. **The separate CPU
   clock domain is decided.**
5. **The TMS57002 question answered**: a MAME tap showing whether any in-scope set writes a program
   to `0x300001`, and what the audio sounds like with the DASP's four routes muted.
   — **Answered: yes, all 22.** See "Sound" above. The listening half is not done.

**Phase 1 — Video, against a software model.**

Build the MAME capture pipeline first (`mame_capture.py` + a `render_model.py` that reproduces
`konamigx_v.cpp`), get it pixel-exact on captured frames, and only then check RTL against it — the
Seta and MS32 pattern. Then: K053252 CRTC; K054156/K056832 tilemaps at 4/5/6/8 bpp; K053246/K055673
sprites with the line buffer; palette; K054338; and the K055555 mixer transcribed from MAME. Exit
criteria: the first target set renders frames pixel-identical to MAME's for a captured set of
scenes, silent, in simulation.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM backend with all clients, the ROM download path, `.mra` generation, inputs, DIPs, EEPROM
persistence, the ISSP probe and the OSD debug page. The ESC microsequencer lands here, because
without it the games with one have no sprites. Exit criteria: three Type 2 sets — one without ESC
(`tokkae` or `winspike`), one with `generate_sprites` (`tbyahhoo`), one with `konamigx_esc_alert`
(`tkmmpzdm`) — boot and play on a DE10-nano, silent.

**Phase 3 — Sound.**

68000 + K056800 + two K054539s, the PCM chip written from MAME's `k054539.cpp`
([`THIRD-PARTY.md`](../THIRD-PARTY.md)). Exit criteria: register-write traces captured from MAME reproduce
correct audio, verified by ear and by a decoded capture against MAME's own output.

Split so that the part that unblocks games comes first. Crazy Cross's power-on check, and
plausibly Fantastic Journey's palette, wait on the sound CPU answering over the K056800; the
board's `gx_snd_stub` was built from Daisu-Kiss's test alone and answers the others wrongly. A
real sound CPU running the real sound program answers every game's test by construction, where
a better stub would mean guessing each game's protocol.

- **3a -- the sound CPU answering.** `gxsndmap`: a 68000 at 8 MHz (`SUB_CLOCK/2`), ROM
  0x000000-0x03ffff, RAM 0x100000-0x10ffff, the two K054539s at 0x200000 (#1 high byte, #2 low),
  the TMS57002 at 0x300001 and 0x500000, the K056800's sound side at 0x400000. Released from
  reset by bit 22 of the main CPU's control write. IRQ 2 is the K054539's timer, rising edge,
  enabled by bit 0 of the control word at 0x500000 -- so the 054539's timer is needed before any
  audio. For 3a the 054539s are their register files, timer and ROM readback; the TMS57002 is its
  status and control words.
  * **Done: the ROMs in the SDRAM image** (after the sprite spread; every set fits 32 MB, crzcross
    and puzldama at 95%). Adding them needed the sprite transform bounded above: the padding
    between the two regions otherwise wraps past 32 MB into the BIOS, yesterday's fault again.
  * Budget: logic is at 43%, RAM blocks at 81% (107 M10K free). **Decided:** the sound CPU's
    64 KB work RAM is block RAM (~52 M10K; it is on every instruction's path), and each K054539's
    32 KB (MAME's `m_ram`, 0x8000) goes in SDRAM -- the two together with the CPU's would be
    128 KB against ~107 left. The chips reach that RAM through a byte-at-a-time pointer port
    (registers 0x22d/0x22e, `rom_addr == 0x80`), and even at audio rate eight channels at 48 kHz
    is little bandwidth. The TMS57002's 256 KB (3c) is SDRAM for the same reason.
  * The K054539's timer drives IRQ 2: a write to 0x227 sets a square wave of
    `(38 + n) * clock / 384 / 14400` Hz (clock 18.432 MHz), output while 0x22f bit 5 is set;
    the sound CPU interrupts on its rising edge. Register 0x22d reads the sample ROM's bank
    `rom_addr` at an auto-incrementing pointer (or the RAM when `rom_addr == 0x80`), which is
    how the sound CPU checksums the sample ROMs its power-on test reports.
  * **Crazy Cross gets past its power-on check on the board** with the sound board selected
    (build 46, fx68k). Probe S shows the sound CPU released and running its main loop
    (0x1990), and the main CPU in the game's frame loop at 0x210090 -- wait for the vblank
    flag, then program the K053246 -- where with the stub, and with TG68K, it sat in the
    handshake subroutine at 0x20aa1c. In the board bench (`check_gx_main --snd-real
    +SND_LOG=n`) the whole exchange runs: `F7` acknowledged, the pattern echo, the heartbeat,
    `FE` answered with `C0` and then the result `01`.
  * **TG68K was the wrong core for it.** Chosen for convenience (one Verilog conversion for both
    CPUs); Seta had measured it 3.5x fast on a plain 68000, and here it answered the handshake
    visibly early and the board sat in it. fx68k, cycle-accurate, is what got through. The
    main CPU stays TG68K.C, a 68EC020 that fx68k does not implement.
  * Open: the sound program holds `C0` for 70 frames in the bench, where gx_snd_stub's notes
    say MAME holds it about 230. The main CPU accepts both; the difference is unexplained.
  * Open: no sound yet -- the voices are 3b. And the OSD still defaults to the stub.
- **3b -- audio.** The K054539s' PCM and the mix.
- **3c -- the DASP effects.** The TMS57002, its RAM in SDRAM.
  * `rtl/sound/gx_tms57002.sv`, against MAME's tms57002 through a Python model of it
    (`scripts/tms57002.py`) and MAME's own host traffic (`scripts/mame/dasp_log.lua`,
    `scripts/check_gx_tms57002.py`). Two clocks a word at 48 MHz: 500 words' time a sample
    against the programs' 250, the rest for SDRAM stalls. The RAM is at snd_base + 0x450000.
  * Every set uses 256 KB in WORD mode; st0 SEL varies (01c6ba, 0186ba, 01869a), so both the
    byte and the nibble layouts are in.
  * Fantastic Journey: the self-test program (a RAM test, 140 words) returns `e4 02 00 00` as
    in MAME, and gx_main_tb with the real sound board matches MAME's main-CPU writes through
    frame 200.
  * Open: the outputs (`so`) are not yet routed anywhere (3b), and the inputs are zero.

**Phase 4 — The rest of the Type 2 list, and accuracy.**

The remaining nineteen sets, every clone's `.mra`, the LE2 light guns, the four sprite ROM layouts,
`salmndr2`'s and `dragoonj`'s ESC variants, `sexyparo`'s `UNEMULATED_PROTECTION`, the alpha tile
callback, screen flip. `docs/MAME_KLUDGES.md` is the deliverable that says what is still not right
and what would settle it.

Phase 4 progress (by set, what each needs):

| Set | Tiles | Sprites | Other | State |
|---|---|---|---|---|
| tokkae | BPP_6 | GX (5 bpp) | primode 5; OPSET bit 4 z inversion; DMAEN clear | benches pixel-exact on 3 captures; main bench and board open |
| tkmmpzdm | BPP_6 | GX | ESC: `konamigx_esc_alert` mode 0 copy; layer brightness (VBRI, all levels 0xff so far); MAME patches two ROM words (checksum, planes B-D) | f2400 and f4000 pixel-exact in gx_video; the patch question open |
| dragoona/j | BPP_5, TILE_WORD only | RNG (4 bpp, 4 bytes a half-row) | own sprite callback, layer offsets +1, ESC copy at 0x5c00; 384 x 224 at bitmap x 40 | in: model exact on 3 frames; gx_video f1500/f3000 identical to MAME at 384 wide; f4500's sprites overrun the line (126 tiles) |
| salmndr2(a) | BPP_6 (two TILE_WORDS2) | GX6 (6 bytes a half-row, `_48_WORD`) | ESC `konamigx_esc_alert` mode 1 (0x1c8c, 0x172) as gx_esc's gen_sal2; sprite callback pri = attr[9:4]; readback BPP66 (`k_6bpp_rom_long_r`); VMIXON 0x3f (layer D's colour bits 5:4 are its mix code) | model exact on 5 frames; gx_video 4 of 5 identical, f2400 differs in the zoomed dragon only; main bench and board open |
| winspike(a/j) | BPP_8 | LE2 (8 bytes a half-row) | K056832 layer association off (djmain_hack 2); 384 x 224 at bitmap x 39; type 4 protection (0xd1c copy c01000 -> c01400, 0x57a input-buffer copies; command word at 0xcc0004, run on the falling edge of 0xcc0000 bit 9) | model exact on 6 frames (the K053252 at 24 + 15); protection as gx_esc's `p4` commands; main bench and board open |
| le2(u/j) | BPP_8 | LE2 | primode -1, light guns (gx_guns, as Seta's Zombie Raid: held aim moved by the stick absolutely, the d-pad, or the mouse; per-player stick mode Auto/Aim/D-pad; button 2 or right-click reloads; crosshair option), le2u/le2j flip their own screen in Y and MAME turns it back (ORIENTATION_FLIP_Y): tilemaps drawn unflipped, sprite plane mirrored (gx_obj vmirror), gun Y reversed | all three in: model exact on le2 x3, le2u x2; RTL le2/le2u f1200 exact, f2400 differ only in zoomed sprites; guns untested on the board |

Zoomed sprites: MAME maps each 16x16 tile on its own -- its screen width zw from the rounded tile
positions, and destination pixel x sampling source column (x * floor((16 << 19) / zw)) >> 19 --
where jtframe_draw steps one zoom accumulator across the sprite. le2's attract zooms heavily and ~11%
of its frames' pixels come out a column to the side of MAME's; unzoomed sprites match. winspike f3000
and salmndr2 f2400 differ the same way. Decided: the core keeps the continuous accumulator, which
is closer to the hardware than MAME's per-tile placement (the user's call); these differences are
MAME's, listed in docs/MAME_KLUDGES.md, and a bench frame that differs only in zoomed sprites passes.

dragoonj and winspike run 384 x 224 (MAME resizes the screen from the CRTC; wrport DOTSEL 8 MHz).
The video path takes the line total from the CRTC and the window from gx_board_cfg (vis_x0, vis_w).

Sprite drawing time: the heaviest lines carry more sprite pixels than a line has clocks -- dragoonj
f4500 126 tiles (2016 pixels), sexyparo play2400 159 (2544), against 3072 clocks a line at either
dot clock -- and gx_obj_tb reports the scan unfinished there. Drawing faster than a pixel a clock
(two a clock, or the drawer at 96 MHz) is what would settle it.

Each sprite half-row fits a granule for every layout: GX6 and LE2 spread to 8 bytes as the 5 bpp regions are, RNG stored as it comes (a whole 8-byte row a granule, the half choosing the four bytes) -- spread, dragoonj's 16 MB region would be 32 MB. gx_obj decodes by layout, with the pen at colour x 2^bpp and the shadow pen 2^bpp - 1. Whether dragoonj's image fits the 32 MB module with its sound RAMs is to be checked by build_mra.

**Phase 5 — Type 3/4, or not.** A decision with evidence rather than a default: what one video
output should show for a two-monitor game, and whether `rushhero`'s 59.38 MB justifies requiring a
128 MB SDRAM module.

**Phase 6 — Savestates.** Not before Phase 4. Psikyo's `docs/savestates.md` is the feasibility study
and its conclusions mostly transfer, including its assessment of what TG68K.C's register file makes
reachable.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces, VRAM
  and register dumps at known frames, palette dumps, register-write logs. All of WORKFLOW section 8
  applies, including its traps.
- **The software model comes before the RTL.** `render_model.py` reproduces `konamigx_v.cpp` in
  Python and is checked pixel-exact against MAME's own screenshots first; the RTL is then checked
  against the model layer by layer. This is what made MS32's video work, and it is the only practical
  way to debug a mixer nobody has implemented.
- **Every vendored module is verified against MAME before it is wired to anything**, and its own
  testbench is the regression for every subsequent change to it.
- **Layouts are verified before ROMs are involved**: every sprite and tile `gfx_layout` gets the
  "every bit of a tile exactly once" check, and the runtime-assembled 5 bpp sprite region gets it
  twice — once for what the `.mra` produces and once for what the RTL reads.
- **`.mra` files are generated, not written**, re-read and compared byte-for-byte against an image
  built from `ROM_START`, and gated on an XML well-formedness check before every deploy.
- **Worst cases are measured in the RTL**, not modelled in Python. Sprites walked per frame, pixels
  written per line, fetch stalls — counters with no reset port, saturating, each paired with a total.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer** (`sys/`, `rtl/`, `files.qip`, `Template.*`). The
`Template.*` files are already renamed to `KonamiGX.*` and split into the two revisions below,
because `build_staged.py` builds a named revision; the unused Quartus 13 project was dropped, as on
the four sibling cores. Quartus **17.0.2**, which
is the version the [MiSTer developer reference](https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/)
names and what the previous four cores were built with.

Conventions, all carried over and all described in [`WORKFLOW.md`](WORKFLOW.md):

- **The project is `KonamiGX`, in two revisions** — `KonamiGX_stp` (instrumented: `DEBUG_ISSP=1`,
  the OSD Debug page visible) and `KonamiGX` (release, both compiled out) — one source, two `.qsf`
  files identical above their last block.
- **Builds are staged, never in-tree.** `scripts/build_staged.py` (ported) snapshots HEAD into a git worktree
  at `build/` (gitignored) and runs Quartus there. A dirty tree is refused by default. It gates on
  negative slack on **every** clock, checks that required blocks survived to the fitted netlist,
  checks that required `VERILOG_MACRO`s are defined, and records commit, timestamp and fitter seed
  in `build/BUILT_COMMIT`.
- **Build and probe are mutually exclusive, enforced not remembered.** `scripts/hwlock.py` holds a
  machine-wide marker beside the user profile, shared with the Psikyo, Fuuki, Seta and MS32
  repositories on this PC (ported; all five copies resolve the same
  `%LOCALAPPDATA%/mister_jtag_running`). A JTAG tool refuses to start while Quartus or ModelSim is running; a
  build or a simulation refuses to start while a JTAG tool holds the marker. Concurrent JTAG and
  Quartus bugchecked this PC three times (`KERNEL_SECURITY_CHECK_FAILURE`, 0x139). This repository
  got its own copy of `hwlock.py` pointing at the same marker before the first build, not after.
- **Releases** are the `.rbf` plus the whole `.mra` set together under `releases/`, parents at the
  top level and clones in `releases/_alternatives/`. They are coupled: the SDRAM layout is encoded in
  both. The release revision must close timing; the debug revision may not. `docs/RELEASE_PROCESS.md`
  carries the procedure, ported from Psikyo.
- **Branching**: `develop` carries granular commits, squashed onto `master` at milestones. ROMs live
  in `roms/` and are gitignored.
- `.gitattributes` pins `*.sh` and this project's `.tcl`/`.lua` to LF. With `core.autocrlf` on, a
  `git reset --hard` gives them CRLF and bash rejects `set -euo pipefail\r` on line 1.
- **Licence: GPL-3.0-or-later**, and `LICENSE` now carries the GPLv3 text. Every dependency, what it
  obliges and the release checklist are in [`THIRD-PARTY.md`](../THIRD-PARTY.md). `sys/` is never
  edited.

## Open items

- **The K054539's licence: settled against using furrtek's HDL.** SiliconRE#40 was closed without a
  grant and the project owner assumes strictly GPL-2.0, so the chip is written from scratch against
  MAME's `sound/k054539.cpp` (Phase 3b). What follows is the earlier state of the question.
  furrtek's `SiliconRE` repository carries a
  GPL-2.0 `LICENSE` file and `Konami/054539/hdl/054539.v` has no SPDX header of its own, so whether
  the grant is GPL-2.0-only (incompatible with the GPL-3 modules here) or GPL-2.0-or-later
  (compatible) is not stated upstream. **The project owner has decided to proceed as though it is
  usable under GPL-3**; that decision, the facts behind it and the fallback are recorded in
  [`THIRD-PARTY.md`](../THIRD-PARTY.md). **The question is with the author:
  [furrtek/SiliconRE#40](https://github.com/furrtek/SiliconRE/issues/40).** It stays on this list
  until that issue has an answer, because a public release has to vendor from a commit that states
  the grant. If the answer is GPL-2.0-only, Phase 3 becomes a from-scratch K054539 against MAME's
  `sound/k054539.cpp` and furrtek's register notes, which are documentation and carry no such
  problem.
- **Whether jotego is already building this.** A 2021 announcement relayed by atrac17 says "Konami
  GX System, X-Men based hardware, TMNT based hardware, and Mystic Warriors based hardware is coming
  to MiSTerFPGA", and `xmen`, `moo` and `rungun` have since shipped. That is not a reason to stop —
  it is the reason the chip modules exist — but it should be known rather than discovered, and it
  changes what "release" means for this project.
- **jotego's generated register-map modules, and how to get them.** Most of the modules this project
  wants instantiate a `*_mmr` register-decode module that upstream **generates** with
  `jtframe mmr <core>` from `cfg/mmr.yaml` rather than checking in. `jt053246_mmr.v` (sprites) is
  checked in and fine; `jtk053252_mmr.v` (CRTC) and `jt054156_mmr.v`/`jt054157_mmr.v` (tilemaps) are
  not. `jtframe` is a Go program and there is no Go toolchain on this machine, so neither the
  modules nor their upstream testbenches can be built as things stand. Three ways out, none yet
  taken:
  1. **Install Go and build `jtframe`.** Authentic output, and it also unlocks upstream's own
     benches — `cores/rungun/ver/k053252` is a *differential* bench that checks `jtk053252.v`
     against furrtek's silicon-derived `doc/053252.v`, which is a far better regression than
     anything this project would write. Cost: a toolchain on the build machine.
  2. **Reconstruct the MMR modules here** from `cfg/mmr.yaml`, which is small and mechanical (the
     K053252's is sixteen 8-bit registers with bit-slice extraction). They would be this project's
     files, not jotego's, and would drift if upstream's generator changes. Verifiable by the
     differential bench in (1), which needs (1).
  3. **Ask upstream to check them in**, as `jt053246_mmr.v` already is.
  The choice matters beyond convenience: without (1) there is no way to run the upstream tests that
  WORKFLOW §12 makes the rule for every vendored module.

- **How much of each vendored module actually transfers.** Read at the level of headers and READMEs
  so far. The K056832 colour-depth extension, the K055673 sprite depths and the 24-bit `xRGB_888`
  palette (against the 5-bit palettes those modules were written for) are the three places a port is
  most likely to become a rewrite. Phase 0 finds out.
- **The K055555 mixer's behaviour beyond MAME's.** MAME's mixer is 287 lines of per-object decisions
  over a z-buffer. furrtek's register notes describe a chip with per-layer colour-bit selection,
  palette banking, a background gradient and MIX/BRIGHT codes. Reconciling the two is Phase 1's
  largest unknown, and the one thing here with no prior implementation at all.
- ~~**Whether the TMS57002 is needed.**~~ **It is: all 22 in-scope sets load programs into it.**
  What stays open is what each upload contains — sessions exceed the chip's 256-word program space —
  and whether the games are acceptable without it, which is a listening test against MAME with the
  DASP muted.
- ~~**The tilemap VRAM size the board actually populates.**~~ **Answered, and it is the full
  128 KB.** A write tap over `daiskiss` to frame 1200 shows **16 distinct tilemap bank selections**,
  and no write in any bank ever passes offset `0x2000` — so the game reaches 16 × 8 KB and never
  touches the second half of the 16 KB window at `0xda2000`. MAME's 16-page model is what the board
  uses; it is not reducible to Moo Mesa's 24 KB, and the RAM budget's 19.7% stands. Worth repeating
  on a set with more layers in play (`winspike`, `le2`) before treating it as settled for the whole
  list.
- **The sample-ROM placement**, SDRAM or DDR3. Decide by measurement once the SDRAM client count and
  the per-scanline graphics fetch budget are known.
- **`sexyparo`'s `MACHINE_UNEMULATED_PROTECTION`** — its ESC does something MAME does not reproduce,
  and the driver's TODO list names three more games whose ESC behaviour is not understood
  (`daiskiss` sticky sprites, `sexyparo` missing effects, `tkmmpzdm` wrong horizontal flip).
- **No GX PCB.** MAME's output is the accuracy target including its acknowledged guesses, except
  where a silicon-derived vendored module disagrees — see "Design decisions".

## Next steps

1. ~~Port `hwlock.py` and `build_staged.py`, and get the first staged build through every gate.~~
   Done; the baseline figures are under "Progress".
2. ~~Port `deploy.py` and `run_sim.sh`.~~ Done. `run_sim.sh` takes the lock; `deploy.py` does not
   and should not — it is scp over the network and never touches JTAG or Quartus. Its stale-artifact
   guard was tested against the baseline build by backdating the `.rbf`, and it refused.
3. ~~Ask the K054539 licence question.~~ Asked:
   [furrtek/SiliconRE#40](https://github.com/furrtek/SiliconRE/issues/40). Work proceeds meanwhile on
   the assumption that it is usable under GPL-3, recorded in
   [`THIRD-PARTY.md`](../THIRD-PARTY.md) with the fallback if the answer goes the other way.
4. ~~Vendor TG68K.C and the jotego modules with `PROVENANCE.md` files, and run every upstream
   testbench unchanged.~~ Done for the video chipset and the main CPU; see "Progress". `fx68k` (the
   sound 68000) is Phase 3 and the K054539 waits on
   [furrtek/SiliconRE#40](https://github.com/furrtek/SiliconRE/issues/40).
5. ~~Build the MAME capture pipeline.~~ Done — `scripts/mame_capture.py`, plus a boot tracer and
   the tools Phase 0 needed. The first-target set is **`daiskiss`**: the smallest ROM set, and the
   one Phase 0's CPU work was proven on.
6. **Phase 0 is met on criteria 1, 2, 4 and 5, and measured on 3.** What it leaves open is
   written against each criterion under "Phased roadmap": interrupts unexercised by the boot bench,
   and what each DSP upload contains.
7. **Phase 1: the software model is pixel-identical to MAME on six `daiskiss` frames, and
   `gx_tilemap.sv` matches the model on all four layers of all six** (see "Progress"). Sprites and
   mixer follow the hardware's structure. `jt053246` with the GX changes matches
   `stage_sprites_only` on all five sprite frames, solid and shadow planes, and the per-pixel
   mixer structure reproduces MAME in software (`stage_mix_hw`), and `gx_mixer.v` reproduces
   MAME's screenshots from those inputs, and `gx_video.sv` — the three together — reproduces
   MAME's screenshots from VRAM, sprite RAM, registers and palette, with the K053252 generating
   the timing from the game's own registers (see "Progress"). Next: the CPU writing the state
   instead of the capture. The main board reproduces MAME's title (frame 1200) from reset;
   next, the later capture frames (2400-6000), with the sound replies keyed to time rather
   than order.
8. **Phase 2 on the board, in this order:**
   - ~~**Fast ROM loading through the HPS DDR3.**~~ Done: the `.mra`'s index-0 ROM loads into
     DDR3 at 0x30000000 and `rtl/memory/gx_rom_loader.sv` copies it through the byte download
     path, as Seta, Psikyo and Fuuki do. Measured on the board (probe K): daiskiss loaded and
     running **7.8 s** after the launch command against about 27 s on the byte path, the copy
     itself 191 ms. `sim/gx_rom_loader_tb` covers the loader against a DDR3 model with random
     busy and latency.
   - ~~**Garbage sprites (Sexy Parodius, and the top-left in others).**~~ The sprite DMA started
     while the ESC was still writing the list, hundreds of times a second (probe J,
     `dma_during_esc`): a frame could get half of one list and half of the next. MAME's ESC runs
     instantly and never sees it. `jt053246_dma` now takes a `dma_hold` and `gx_main` starts the
     copy when the ESC finishes; on the board the counter is 0 and the attract and gameplay
     frames look coherent.
   - **Sprite drawing time: fixed in simulation, to be confirmed on the board.** The sprite
     scan did not finish 20 to 118 lines a frame in daiskiss's attract (probe J,
     `short_last_frm`); Sexy Parodius mostly 0 with bursts.

     What it costs, measured rather than guessed. `gx_sdram_tb +LATENCY=1` reads the sprite
     port the way `jtframe_draw` does and reports the clocks: **a fetch answers in 11**,
     contention or not, and a 16-pixel row is two of them. The drawer asks for a row's second
     half as it starts drawing the first, so it has eight clocks of slack and no more: a row
     cost `11 + 8 + 3 + 8 = 28` clocks of which 16 are pixels. At that latency the sprite bench
     runs out of line on 64 of 234 lines (`check_gx_obj daiskiss-f4800 --rom-lat 11`); at 6
     clocks, none. The pair prefetch added earlier could not help, because it starts only after
     the first half is served -- the same eight-clock window -- which is why the board's count
     did not move.

     Two changes, together worth the difference:

     * **The scan hints the next row.** `jt053246_scan` already computes the next tile of a
       sprite (`hcode + hsum`) while the drawer is on the current one, so it now carries that
       out as `pf_on`/`pf_code`; `gx_obj` turns it into the address `jtframe_draw` will ask
       for, and `gx_rom_port` fetches it in the idle time it already has. The port also keeps
       the last four granules, which are read-only and so can never be stale.
     * **The arbiter drives the SDRAM port directly**, instead of through `sdram_phy`, which
       cost a cycle each way, and picks a client the cycle its request arrives. `c_req` to
       `c_valid` went from 17 to 14 `clk_mem` cycles, and a fetch from 11 clocks to 10.

     `sim/gx_obj_tb +PORT=1` runs the bench against the real `gx_rom_port` and a memory that
     answers in `+ROM_LAT_M` `clk_mem` cycles, so the board's own number drives it. At the
     measured 14: **32 lines short without the hint, none with it**, and all four daiskiss
     sprite frames stay pixel-identical to the model. The cliff is between 16 and 18, so the
     three cycles the arbiter gave back are part of the margin, not spare.

     **Confirmed on the board** (probe J): `short_lines` stayed at 2,056 while `vblanks` went
     from 2,366 to 3,738 -- 1,372 consecutive frames of attract with none -- and
     `short_last_frm` was 0 on every sample. It was 20 to 118 a frame. The 2,056 predate the
     window and are not yet accounted for; the ESC's runaway held the CPU port and starved the
     sprite fetches at launch, which would do it.

     Left if it comes back: a row in one SDRAM burst (the chip is idle half the time even now),
     and Seta's and MS32's lesson about dropping the sprites the chip draws last.
   - ~~**Alpha and line scroll (Sexy Parodius's ink stage).**~~ Done: the mixer takes each pixel's
     mix code from the tile's colour bits as `K055555GX_decode_vmixcolor` does, and adds an
     additive layer instead of MAME's inverted-alpha fade, so the ink's black is transparent;
     `gx_tilemap` does line scroll per line and per eight lines. The board's own registers in that
     scene (probe L) match MAME's capture of it: layer B VMIXON 0, K054338 alpha 2 = 0x2000,
     scroll modes 0xc3.
   - ~~**Stray graphics in Daisu-Kiss's top-left corner.**~~ Found and fixed: CPU reads above the
     packed image's length returned the tile graphics that follow it in SDRAM, where MAME's map
     reads zero. The ESC takes five of that scene's sprite piece lists from such addresses, so it
     read a piece count of 65,278 instead of 0 and walked them, holding the bus for frames and
     leaving the sprite list half written -- the strays are its tail, still carrying the previous
     frame's entries with their active bit set. Evidence: the board's own list
     (`scripts/memdump.py d20000 1000`, decoded by `scripts/spritelist.py`), probe I mid-run
     (`esc_busy` yes, `count2` 0x7ef1), and `scripts/esc_model.py daiskiss-f2400 [--board]`, which
     is konamigx.cpp's `generate_sprites` in Python: 19 pieces walked with MAME's map, 220,659
     with the board's. `gx_main` now answers those reads with zero.

     **Confirmed on the board.** CPU 0x4f0080 reads zero where it held `fe fe ff 00`; the ESC's
     piece counts are 0 to 4, the scale MAME shows; and the sprite list's tail slots read
     `00f0 00f1 ... 00ff` -- the slot numbers MAME's fill writes, bit 15 clear -- where they held
     0x9052 with four still active. 35 active entries, contiguous, no strays.
   - **On the board, still wrong** (each needs the next measurement named, not another guess):
     * **Crazy Cross's RAM/ROM check: waits for Phase 3.** The BAD entries are the checks the
       *sound* CPU does. The main CPU asks for them over the K056800 mailbox and waits for the
       reply at 0xd52010 (0x20a826-0x20a876), with a countdown in d7 that marks the test failed
       when no answer comes (0x20a81c). The board has no sound CPU -- the mailbox is an echo --
       so every one times out. 7C/S and 9C/S are the sound program ROMs; 7G/M is where
       315a18.7g, a K054539 sample ROM, sits: on the main board but the sound CPU's to read.
       Found in simulation: MAME's reference extended to frame 800 (it ended at 399, before the
       test, which is why the first runs matched), and the first divergence is the return
       address 0x20a836 against MAME's 0x20a880 at MAME frame 545. MAME shows the check all OK
       at frame 600. The graphics entries were OK before the readback windows existed, so those
       windows were not the blocker; they are MAME's behaviour and stay.
     * **Fantastic Journey's pens.** The video path is not at fault: `check_gx_video
       fantjour-f1800` is 64,512 of 64,512 against MAME. So it is the state the board builds.
       Palette regions 0xd92000 and 0xd94000 read empty where MAME's capture has 594 and 155
       nonzero bytes, while 0xd96400 matches exactly (192 of 256) -- but the board was at frame
       300 and the capture is frame 1800, so that comparison proves nothing on its own. The
       reference trace is built (`debug/fantjour-sys`, 5.9M accesses) and the write-stream
       comparison to frame 1820 is the measurement that settles it.
     * **Sexy Parodius runs slow.** Not the ESC in simulation: the main bench (+ESC_LOG, to frame
       1174) has one command a frame holding the CPU at most 4,244 clocks (88 us, under 0.5% of a
       frame; median 2,308), and the RTL keeps MAME's pace (RTL frame = MAME frame - 32, as on the
       other sets; all 1,638,241 POST writes identical). What is slow on the board is still
       unmeasured: `cpu_accesses` per frame from probe F against daiskiss's is the next number,
       and whether the board's SDRAM latency (the bench's ROM model answers in 10 clocks) is
       what differs.
   - Stacked shadows (MAME_KLUDGES), the other `.mra` sets on the board, the `.nvm` EEPROM save.
