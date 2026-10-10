# Type 3 and Type 4 boards

Soccer Superstars (Type 3), and Versus Net Soccer, Run and Gun 2 / Slam Dunk 2 and Rushing Heroes
(Type 4): the twin-monitor GX boards. They are built as a second bitstream from the same sources
(`KonamiGXT34`), which each of their `.mra`s names, and need the 128 MB SDRAM module. The name
has no underscore after `KonamiGX`: MiSTer matches `<rbf>KonamiGX</rbf>` against `KonamiGX_*.rbf`, so
`KonamiGX_T34_<date>.rbf` would be picked by the Type 2 sets.

## The hardware, from MAME

Everything here is from `konamigx.cpp`/`konamigx_v.cpp` (mamedev master, `C:/mame-gx`); none of it
has been checked against a board.

- **One picture pipeline, two monitors on alternate frames.** `screen_update_konamigx_left/right`
  render the left monitor on one frame and the right on the next, each with its own palette; MAME's
  comment: "the video gets demuxed by a board which plugs into the jamma connector". Each monitor
  therefore changes picture at 30 Hz and is held in between.
- **Palettes outside the K055555.** `0xE80000` (main monitor) and `0xEA0000` (sub monitor):
  - Type 3: 16 KB each, xRGB 555, two colours a long (`palformat` 1);
  - Type 4: 32 KB each, xRGB 888, a colour a long (`palformat` 0).

  The Type 2 palette range `0xD90000-0xD97FFF` is plain RAM on these boards.
- **K053936 (PSAC2), a rotate/zoom layer** on the ROM board, drawn as the K055555's SUB1/SUB2
  input (`gx_draw_basic_extended_tilemaps_1/2`):
  - registers at `0xE00000` (32 bytes);
  - line control at `0xE60000` (4 KB);
  - tiles 16x16 from `gfx3`;
  - Type 3: a 256x256-tile map from ROM (`gfx4`, `get_gx_psac3_tile_info`), with an alternate map;
  - Type 4: a 128x128-tile map in RAM at `0xF00000` (32 KB, `psacram`);
  - offsets per set (`K053936_set_offset`, `K053936GP_set_offset`).
- **Bank register** `0xE40000` (`type3_bank_w`) and **sync read** `0xEC0000` (`type3_sync_r`).
- **Tiles** 6 bpp (Type 3) or 8 bpp (Type 4); **sprites** in the GX6 layout. The core already does
  both (Salamander 2, Le2, Winning Spike).
- **Type 4 protection** (Xilinx, `type4_prot_w` at `0xCC0000`), C in MAME per game:
  - Rushing Heroes (`0xd97`);
  - Slam Dunk 2 (`0xb16`, right screen `0x3a4f`);
  - Versus Net Soccer (`0x515` screen 1, `0x115d` screen 2);
  - Winning Spike's (`0x57a`), which `gx_esc.v` already reproduces.

  Type 3 has none.
- **Timing**: the main screen is the base `konamigx` raster; the sub screen is declared at 6 MHz,
  288 wide. Each set's K053252 values come from a MAME capture, as for Type 2.

MAME marks every one of these sets `MACHINE_IMPERFECT_GRAPHICS` (Versus Net Soccer also sound), so
MAME is a weaker reference here than for Type 2; PCB footage of a twin-monitor cabinet decides.

## Screens on MiSTer

Every Type 3/4 set takes MAME's `type3` inputs, which have the DIP switch *Number of Screens*
(SW1:4, 1 or 2). In MAME the game alternates the monitors every frame with either setting
(`scripts/mame` runs at 20-80 s, both settings): `type3_bank_w` alternates `0e`/`4d` (sometimes
`1e`/`5d`) and both palettes are drawn from. With 1, the sub monitor's frames say
"1 MONITOR SETTING!! (DIP-SW4=OFF)". So the board's output is two pictures interleaved at 60 Hz in
both settings, and each monitor's picture changes at 30 Hz.

- **HDMI** (`rtl/video/gx_t34_fb.sv`): the frames go to the scaler's DDR3 framebuffer; OSD
  *Screen (HDMI)*: First, Second, or Both side by side. A buffer is shown only once its picture is
  finished, so a monitor's 30 Hz picture is not interleaved with an older one
  (`sim/gx_t34_fb_tb`).
- **Which frame is which**: the frame scanned out while `0xEC0000` reads `ffff` (`t3_frame` 0)
  is the main monitor's. MAME draws a frame at the next update, after its flag has turned, so
  MAME's pairing is one frame off from a raster's. Checked in `sim/gx_main_tb` from MAME's
  state after Start (below): team select, MAME's main screen, in the frames with `t3_frame` 0.
- **Analog**: the board's interleaved frames as they are. Showing one monitor needs the demux
  board's frame hold, which needs a frame store (in DDR3, read back for the analog output); without
  one, blanking the other monitor's frames gives a 30 Hz flicker. **Open: the earlier decision
  (use the DIP, no frame store) assumed 1 screen meant a 60 Hz single picture, which MAME does not
  show.**

## Video at 12 MHz

Soccer Superstars writes `0xc2` to the control register (`wrport2`: the 12 MHz dot clock) and
programs the K053252 for 768 dots a line, 576 visible (MAME's screen is 576 x 224). Every Type 2
set runs at 6 or 8 MHz (288 or 384 visible). At 12 MHz a pixel is 4 clocks of `clk_vid`:

- `gx_mixer` took 5 (fixed, `5033be1`);
- the line buffers and counters are 9 bits (512): `gx_tilemap`'s `rd_x`/`vis_w` and line buffers,
  `gx_video`'s `hdump`, `gx_obj`, the scaler's `arcade_video` WIDTH (384);
- `gx_tilemap` renders the four layers one after another, a pixel a clock: 4 x 576 = 2,304 of the
  line's 3,072 clocks, before tile fetches that wait on SDRAM.

MAME draws the K053936 at half that resolution (288 a line) and doubles it
(`gx_draw_basic_extended_tilemaps_2`).

## SDRAM

| Set | Program | Tiles | Sprites | PSAC2 | PCM | Total (raw) |
|---|---|---|---|---|---|---|
| soccerss | 2.1 MB | 1.5 MB | 12 MB | 1.5 MB | 2 MB | 19.4 MB |
| vsnetscr | 3.1 MB | 2 MB | 24 MB | 2 MB | 4 MB | 35.4 MB |
| rungun2, slamdnk2 | 3.1 MB | 2 MB | 24 MB | 2 MB | 4 MB | 35.4 MB |
| rushhero | 3.1 MB | 2 MB | 48 MB | 2 MB | 4 MB | 59.4 MB |

The Type 2 layout assumes the 32 MB module; Type 3/4 assume 128 MB. With the PSAC2 regions after
the sound board's RAMs (`scripts/build_mra.py`), Soccer Superstars' map ends past 32 MB too.

## Resources

The Type 2 build: 38,987 / 41,910 ALMs (93%), 532 / 553 RAM blocks. The second bitstream drops what
only Type 2 sets use -- the 056734 (ESC), the Le2 guns, Fantastic Journey's DMA -- and adds the
K053936 (jotego's `jt053936.v` from jtcores' Run and Gun, after furrtek's module), the second
palette, the PSAC2 RAMs and the Type 4 protection commands.

The Type 3 build (`3a3bab7`): 36,329 ALMs (87%), 542 / 553 M10K blocks, 4,259,053 / 5,662,720 block
bits. `0xD90000` is
kept in the Type 2 palette RAM: soccerss's RAM test, its only user, reads back bytes 2-0 of each
long, so the x byte is not kept. Both 555 palettes are in `gx_mixer`, which draws from the frame's.

**Open: the RAM budget.** 11 blocks are left. 576-wide line buffers (tilemap about 8, sprites about
16, the scaler's line about 7) and the K053936's line buffer and caches do not fit; something large
has to leave block RAM. The largest: work RAM 128 blocks, VRAM 128, the sound CPU's RAM 64.
The sound CPU's is the one that can go to SDRAM at least cost: its program is already there, and
`gx_sound` holds the 68000's clock until an access is ready, so its cycle counts stay the 68000's
(a slow access costs time, not cycles). That frees 64 blocks: the 576-wide line buffers and a
K053936 tile cache fit in them. Done (`973ea48`, `b3a0827`): 483 / 553 blocks. Every access going to
SDRAM slowed the sound program enough that its power-on check reported 4H bad in the bench (with a
one-clock RAM model it did not), so a 4 KB write-through cache (5 blocks) answers hits in the
block-RAM path's clocks. With the real sound CPU (`--snd-real`) soccerss's 2,591,010 main-CPU writes
over 1,300 frames are the block-RAM build's.

## On the board

`KonamiGXT34` at `d2d97f1` (seed 3): Soccer Superstars boots and runs its attract at 576 x 224 with the
pitch drawn (`debug/t34r_title_burst.png`). The faults found on the way, each now fixed: the line
total read from one bit of K053252 register 0 (every layer repeated every 256 columns); the fast
ROM load stopping before the K053936's regions (the pitch was SDRAM's power-up contents); hdump's
jump falling after HS, where the sprite gate re-synchronises (sprites lost left of column 168).
Not yet compared with MAME frame for frame; the sub monitor's frames are not checked.

## Save states with MAME

The Type 3/4 build's state (`rtl/gx_ss_layout.svh`, sections 21-24) adds the K053936's registers
and line control, both palettes, and on the board vector the bank register and the frame flag.
MAME saves neither of the last two, nor the K053252; `scripts/mame/save_at.lua` records them
beside the state it saves:

    GX_SAVE_AT=45 GX_SAVE_NAME=m45 GX_SAVE_SIDE=<dir>/m45.sta.json     GX_INPUTS="25:Coin 1,28:1 Player Start" mame soccerss -autoboot_script scripts/mame/save_at.lua ...
    python scripts/gxss.py from-mame <sta dir>/soccerss/m45.sta m45.ss --side <dir>/m45.sta.json
    python scripts/check_gx_main.py soccerss 80 --snd-real --plus +SS_LOAD_AT=20         --plus +SS_LOAD=<abs path>/m45.ss --plus +SHOT_FROM=32 --plus +SHOT_TO=80

The bench loads it about frame 31 and writes each frame, logging which monitor it is
(`SHOT n main|sub`). A state saved on the board loads the same way.

## K053936

`rtl/video/gx_psac.sv`, from `scripts/psac2_model.py` (MAME's code, checked against MAME's screen:
on the main monitor's frames every uncovered layer pixel matches). `sim/gx_psac_tb`: every pixel of
a frame equals the model's. Not connected yet.

Line time is the problem. A 12 MHz line is 3,072 clocks; with a 12-clock SDRAM fetch the renderer
takes 887 to 4,341. Where the pitch is turned, a line crosses a tile column (16 bytes) every 1.4
pixels: 216 fetches on row 85 against 43 where it is not turned. Adjacent lines read the same
tiles, so a tile cache in block RAM would take most of those fetches off the SDRAM, which the
576-wide tile layers and the sprites also need. Estimated from the model on two dumps (a column
cache, direct-mapped, kept from line to line):

| Cache | Fetches a line, mean | Worst line |
|---|---|---|
| none | 109-216 | 227 |
| 8 KB | 33-54 | 156-224 |
| 16 KB | 20-25 | 156-224 |
| 32 KB | 16-17 | 150-223 |

The worst lines are where the projection changes (10 to 38 lines a frame over 60 fetches), not
only the first, so 16 KB and rendering two lines ahead (a third line buffer, one block) to absorb
them is the plan; the bench measures it.

## Plan

1. **The second bitstream.** The `KonamiGXT34` revision (`GX_T34` macro), its `.mra`s naming it,
   the ROM download and SDRAM layout for 128 MB, the Type 3/4 memory maps. Exit: Soccer Superstars
   boots in the main bench to its first frames, its writes matching MAME's.
   Done for Type 3 (`755ed59`): in `sim/gx_main_tb`, Soccer Superstars' 1,759,817 writes in 300
   frames are MAME's, in order -- its power-on tests, all at IPL 7. The 128 MB module is checked in
   `sim/gx_sdram_tb` (`-GSD128=1`, `+HI=` to put regions on the second chip).
2. **Palettes and screens.** The two palettes, frame parity, the OSD *Screen* option on HDMI.
   Exit: Soccer Superstars' attract screens on both monitors on the board, against MAME's.
3. **K053936.** jt053936 vendored, its tile fetch, the SUB layer in the mixer. Exit: the pitch
   matches MAME's render on captured frames.
4. **Type 4.** Protection commands, 8 bpp, the PSAC2 RAM map. Exit: each set reaches play.
   In the bench (`sim/gx_main_tb`, from MAME states): Run and Gun 2, Rushing Heroes and Versus Net
   Soccer draw their attract play on both monitors. Run and Gun 2's first 1,234,685 writes from
   reset (400 frames) are MAME's, in order. Not yet on the board.

## Type 4

Mods 27-34: rungun2, slamdnk2, rushhero, vsnetscr and four clones (`gx_board_cfg`'s `t4`).

- **Palettes:** 32 KB each, xRGB 888 a long: R in a third byte RAM in `gx_mixer`, G and B where
  Type 3's 555 word is. The x byte is not kept.
- **K053936:** the map is RAM at `0xF00000`, 128 x 128 tiles a word each. `gx_psac`'s Type 4 mode
  is `K053936GP_zoom_draw` (`scripts/psac4_model.py`): super and simple modes, 13-bit map pixels
  at srcy * 2048 + srcx, skipped past the map's end. 384 columns, or 288 doubled for Versus Net
  Soccer's 576-wide screen (MAME's `pixeldouble_output`, GP offset x -30). Row y is computed for
  y - `ps_oy`, MAME's GP offset y + 1 (MAME_KLUDGES). Drawn as SUB1 (PRIINP_9) from pen 0x1800,
  blended by OSBLEND_ENABLES bits 3:2.
- **MAME's `rushingheroes_hack`**, reproduced: SUB1 drawn whatever INPUT_ENABLES says, K338 KILL
  not tested, every shadow -80 a channel.
- **Protection** (`type4_prot_w`, in `gx_esc`): 0x0a56/0x0d96/0x0d14/0x0d1c and 0x057a as before;
  0x0b16 and 0x3a4f (Slam Dunk 2), 0x0d97 (Rushing Heroes, with the parameter word: 0x0062
  for the second screen), 0x0515 and 0x115d (Versus Net Soccer).
- **SDRAM:** Rushing Heroes' 48 MB of GX6 sprites spread to 64 MB; the sound board's region then
  starts past 64 MB, so its absolute addresses are 27 bits. 82 MB in all.
- **Room:** the Type 3/4 bitstream leaves out hiscore, the light guns and the cheat engine (no set
  of its has them), and gx_esc's Type 2-only modes. The EEPROM is a RAM in both bitstreams, and
  the K053936's tile cache 8 KB.
