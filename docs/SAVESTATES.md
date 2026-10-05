# Save states

A state saved by the core loads in the core, in the Verilator bench, and (converted) in MAME
0.289; a MAME 0.289 state converts and loads in the core and the bench. One RTL engine does
the capture and the restore. The board and the bench differ only in what moves the slot:
Main_MiSTer on the board, the bench's DDR3 model in simulation.

## Pieces

| Piece | Where | State |
|---|---|---|
| MAME `.sta` read/write, pinned to 0.289 | `scripts/mame_sta.py`, `scripts/mame/sta_items/0289/` | done |
| CPU registers through the bus | `rtl/cpu/gx_ss_m68k.sv`; `sim/gx_ss_cpu_tb`, `sim/gx_ss_fx_tb` pass | done |
| Engine: the sequencer over `rtl/gx_ss_layout.svh` | `rtl/gx_savestate.sv` | done |
| Main-bus master (RAMs, register copy) | `gx_main` access unit, beside `md_*` | done |
| State bus for internal-only registers | board latches, 93C46, K054539 x2, TMS57002, K056800, sound glue | done |
| SDRAM-resident RAMs (K054539 64 KB, DSP 256 KB) | `gx_sound`'s ports | done |
| Bench: `+SS_SAVE_AT= +SS_SAVE=`, `+SS_LOAD_AT= +SS_LOAD=` | `sim/gx_main_tb` | done; boot and in-game round trips match |
| MAME -> slot converter | `scripts/gxss.py from-mame` | done |
| slot -> MAME converter | `scripts/gxss.py to-mame`, `scripts/mame/ss_fixup.lua` | done |
| DDR3 slot client, the rotator's port shared | `rtl/gx_ss_ddr.sv`; in `sim/gx_main_tb` against a DDR3 model | done |
| Board: `SS` in CONF_STR, OSD Save/Restore and slot, wiring | `KonamiGX.sv` | done: Daisu-Kiss saved and restored on the board (`KonamiGX_30000039`, `1e89d1b`; again with `KonamiGX_30000040`, `8300ccb`) |

## MAME's state

MAME's save registry is the checklist for what the core must hold. `.sta` has no item boundaries:
the order and sizes come from the registry of the build that wrote it, and the header's signature
(a CRC over names and sizes) identifies that registry. `mame_sta.py table <set>` dumps it from
MAME through Lua; a state with another signature is refused. Each set has its own signature.
Lua names only items registered under a device; timers, sound streams and globals are carried
through from a template state by index.

MAME has no K053252 device and an HLE ESC, so neither is in its state. A MAME state converts
with the set's K053252 registers as the game writes them at boot.

Checked in `sim/gx_main_tb`: MAME's Daisu-Kiss at frame 600 (with the pinned EEPROM), converted
and loaded at frame 60; the core's next 178 writes are MAME's after its frame 600, in order.

In game: MAME's frame 1500 (the title screen), loaded in the bench, runs at half rate -- the
game's main loop finishes a pass every other vblank. That is the core, not the conversion: the
core reaches the same screen by itself at frame 1866 and runs it at half rate too. Each of the
title's ESC commands reads 53,568 words of ROM (the sprites' piece lists) and holds the CPU for
about 19 ms, longer than a frame; MAME's ESC takes no time. The ranking screen, saved on the board
and loaded in the bench, runs at full rate (about 400 ROM reads a command). Most of those 19 ms was gx_esc's zoom
division, one quotient bit a clock and y before x; with both divided at once, two bits a clock,
a command takes 11.4 ms and the title runs at full rate (the ESC's writes unchanged).

The 056734 (docs/ESC.md) is three sections on the state bus: its local memory's high and low
halves and its registers. A save or load holds it at an instruction boundary for the whole walk
(`ss_freeze`). A state from MAME, which has none, gets one made by the Python model
(`scripts/k056734/synth.py`): the kernel loaded, RESET, and the set's program LOADed under the
handle the game's packets use (0x00010014 in every title). Images from before these sections
(version 1) are refused by the header check.

What MAME's state lacks, a converted state takes as: the K053252's registers from the set's boot
values (`sim/gx_crt_chain_tb/<set>.hex` or a capture's `reg_k053252.bin`, or `--k053252`); the
K054539 voices' fractions and last values zero (MAME does not save them either); the sample
counter, the K054539 timer's phase and the DMA-end timer zero; no ESC in progress.

To MAME: the core's state goes into a template state of the set (`debug/sta_templates/`, made
by MAME on first use), which supplies what the core does not hold -- timers, sound streams, the
screen's times. MAME then loads it once (`ss_fixup.lua`): the palette and the chips' registers are
written through MAME's own handlers, so their derived state follows, both CPUs' PCs are set through
their state interface, and the result is saved a microsecond of emulated time later. A CPU in STOP
is resumed on the STOP. Checked: the core's frame-100 save of Daisu-Kiss, converted and loaded in
MAME; MAME's next 84 writes are the core's after the save, in order.

On the board: Main_MiSTer writes slot n of a set to
`/media/fat/savestates/Arcade/<the .mra's name>_<n>.ss` (Daisu-Kiss's slot 1:
`Daisu-Kiss (ver JAA)_1.ss`, 715,188 bytes), and reads it back from there when the core loads;
a state converted from MAME goes there to be restored on the board. That file, saved on the board
mid-game and converted with `to-mame`, runs in MAME 0.289 (its ranking screen, 30 frames on).

MAME's 68000 (the sound CPU) can be saved mid-instruction (`m_inst_substate` != 0); the core's
cannot resume another core's microcode, so such a state restarts that instruction at `m_ipc`
and the converter says so.

## CPUs

Neither TG68K.C nor fx68k has a register port; `gx_ss_m68k` uses the bus. A forced level-7
interrupt; the vector, a stub and the registers' bank are answered from outside the address map.
The stub stores D0-A6, USP, VBR/CACR (68020) and A7, waits, loads them back and ends in RTE,
whose frame comes from the bank. A load overwrites the bank while the stub waits. A CPU taken
in STOP returns to the STOP (`stop_out`, one `[GX]` port on each core). The 68000 pushes PC low
before its acknowledge, so that one word reaches the stack below SP.

## Area

The release build with save states: 35,320 ALMs (84 %; 73 % without), 540 of 553 RAM blocks,
timing met on every clock. A first version kept a shadow copy of every chip's registers and needed
102 % of the ALMs; the K054539s and the TMS57002, frozen for the walk, are read in place as shift
chains instead, and the CPUs' register banks are small memories.

## Timing

A save records the raster position at which both CPUs were held and snaps every module's
registers there. Both a save and a load end by holding the CPUs until the raster reaches that
position again, committing the snapshot there and releasing them: after a load the CPUs resume
where they were relative to the video, and after a save the latches undo whatever the board did
while the image was written, so the game does not see the save. The picture stalls for the frames
the walk takes (a save at frame 100 of Daisu-Kiss in the bench: about 40 ms).

The sound chips and the DSP are frozen when a save or load starts; the snapshot is taken a sample
period later, so neither is caught mid-sample. A load whose raster position never comes round
(registers that are not the set's) gives up seeking after 2^22 clocks and resumes anyway.

Checked in `sim/gx_main_tb`: Daisu-Kiss saved at frame 100 and loaded into another run at frame
60; the accesses after the save and after the load are identical (84, all of the shorter run).
In game, from a bench snapshot at frame 1100 (attract mode): saved at 1150 in one run, loaded at
1110 in another. After the release, all 510,821 accesses of the save's run (to frame 1250) appear
in the load's run in the same order, apart from extra toggles of the EEPROM's pins (0xd56000) in
a polling loop; the screens at matched frames are byte-identical for 82 frames, after which the
load's run shows one frame twice and continues one frame behind, its screens again identical to
the other's. What a state does not carry is timing: the 68020's ROM cache contents (gx_romcache)
and the clocks' phases, so the CPUs' speed after a load differs slightly from the run that saved.

Save waits for the sprite DMA and the ESC to be idle.

## Slot

Main_MiSTer maps four slots at `SS<base>:<size>`, each a 64-bit control word (a counter the core
bumps to have the slot written to the SD card, and the size in 32-bit words) and the data.
`SS3C000000:100000`: four slots of 1 MB from `0x3C000000`, clear of `ascal` (`0x20000000`), the
rotator (`0x24000000`-`0x257FFFFF`) and the ROM loader's image (`0x30000000`-`0x31E90000`). The
image is 715,184 bytes. `gx_ss_ddr` writes the control word last, with a counter that changes on
every save, so Main_MiSTer writes the file once the image is complete.

After the ROM load the DDR3 port belongs to the rotator, on `clk_vid`, the engine's clock;
`gx_ss_ddr` takes it by showing the rotator BUSY. The rotator writes single beats and holds a
write until it is taken, so the port changes hands on any clock.

The OSD's Save state / Restore state act on the selected slot. Neither starts while the sound CPU
is in reset or Pause holds the 68020: neither CPU could be taken.
