# Konami System GX core for MiSTer

A MiSTer FPGA core for Konami's [System GX](https://en.wikipedia.org/wiki/Konami_System_GX)
arcade hardware (MAME's `konami/konamigx.cpp`), built with Quartus Prime 17.0.2 Lite for the
DE10-nano.

## Contents

- [History](#history)
- [Status](#status)
- [Games](#games)
  - [Supported](#supported)
  - [Out of scope for now](#out-of-scope-for-now)
- [Hardware](#hardware)
  - [Video timing](#video-timing)
  - [Keyboard](#keyboard)
  - [Save states](#save-states)
  - [High scores](#high-scores)
  - [Cheats](#cheats)
  - [CRT Adjust](#crt-adjust)
- [Screenshots](#screenshots)
- [Installation](#installation)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## History

* **Arcade-KonamiGX_20261004**
  * OSD *Invert P1/P2*
  * Cheats: Added cheats, converted from Pugsy's MAME cheats, in every set. Note that MiSTer isn't as flexible, and so you may find issues (e.g. only enable them when in-game as I found it disabled some inputs in menus...)
  * High scores
  * Keyboard: MAME's default keys alongside the pads
  * Fix: Can save states when paused
  * Fix: EPROM saving in Dragoon Might's Gokujou Parodius's
  * Fix: Twin Bee: the bomb target marker is a circle again (mirrored sprites)
  * Fix: Fantastic Journey / Gokujou Parodius: flame fade
  * Fix: Fantastic Journey / Gokujou Parodius:* Sprite blend* (Effect bits) shows the dancer stage's background gradient

* **Arcade-KonamiGX_20261002**
  * Save states: four slots
    * States can be converted to and from MAME 0.289 for the same set (`scripts/gxss.py`)
  * Faster sprite list generation (ESC): Daisu-Kiss's title screen no longer runs at half speed
  * Sound DSP writes no longer stall it (for the reported audio droop; not yet confirmed)

* **Arcade-KonamiGX_20260928**
  * Sprites now keep up on busy lines due to various optimisations: Fixes Crazy Cross intro, Dragoon, Salamnder 2 later levels
  * EEPROM support
  * CRT Adjust

* **Arcade-KonamiGX_20260927**
  * **Beta**
  * Sprites still run out of line time on Dragoon Might's and Winning Spike's busiest lines
  * EEPROM is not saved.

## Status

**Status**: All listed games run and are playable with sound. The zoomed sprite rendering is arguably more accurate than MAME, using a single acculator for pixels when crossing multiple tiles in a sprite, versus MAME's whole pixel granularity.

Graphically, they're still WIP - but MAME has seen some great improvements in the past couple of weeks (targeted for MAME 0.290) thanks to R.Belmont, and that's reflected here too.

Known issues:
* **Dragoon Might's and Gokujou Parodius's power-on memory check can fail 4F and 4H**, the sound
  DSP's RAM: the sound CPU stops waiting for the DSP's RAM test before it finishes. Resetting the
  core from the OSD passes it.
* **EEPROM settings saves** (Dragoon Might's "EEPROM CHECKSUM ERROR", Gokujou Parodius's error
  after a second save): fixed in Arcade-KonamiGX_20261004 on the bench (the vblank interrupt
  dropped the EEPROM's chip select mid-save; docs/patches/mame-konamigx-syncen.md), not yet
  confirmed on the board.

Reported by players against the 20260928 release, compared with the original PCB:
* Fantastic Journey and Gokujou Parodius:
  * the big ship boss's flames: fixed (the additive layer's level is no longer inverted), checked
    on the board in Fantastic Journey; Salamander 2's effects still to be checked with it;
  * at the last stage's big dancer the background gradient is covered by a sprite: the OSD's
    *Sprite blend* (Effect bits) shows it, as the PCB does; off by default until more games have
    been played with it (docs/MAME_KLUDGES.md);
  * stage 2's clouds flickering: not seen since the sprite line-time changes; sprite draw time
    can still run short in busy scenes;
  * some sound effects and parts of the music are too loud.
* Twin Bee Yahhoo! / Magical Twin Bee: a bomb target marker drawn as ')(': fixed (a mirrored
  sprite ignores its x flip, as MAME's rule), checked on the board.

`docs/MAME_KLUDGES.md` lists what is taken from MAME as behaviour and what is known not to be right.
`docs/ROADMAP.md` is the plan and its progress; `docs/LESSONS_LEARNED.md` is what it cost.


## Games

Initial goal is the Type 2 boards of `konamigx.cpp`

### Supported

Every Type 2 set in `konamigx.cpp` except the bootleg.

| Name | Year | Tiles | Sprites | Notes |
|-|-|-|-|-|
| Daisu-Kiss | 1996 | 5bpp | 5bpp | ESC `generate_sprites` |
| Crazy Cross / Taisen Puzzle-dama | 1994 | 5bpp | 5bpp | |
| Fantastic Journey / Gokujou Parodius | 1994 | 5bpp | 5bpp | Fantastic Journey's DMA at 0xdb0000 |
| Twin Bee Yahhoo! / Magical Twin Bee | 1995 | 5bpp | 5bpp | ESC `generate_sprites` |
| Sexy Parodius | 1996 | 5bpp | 5bpp | `UNEMULATED_PROTECTION` in MAME |
| Taisen Tokkae-dama | 1996 | 6bpp | 5bpp | |
| Tokimeki Memorial Taisen Puzzle-dama | 1995 | 6bpp | 5bpp | ESC `esc_alert`; MAME's ROM patch carried in the `.mra` |
| Dragoon Might | 1995 | 5bpp | 4bpp | 16 MB of sprites; six buttons; sprites can run out of line time |
| Winning Spike | 1997 | 8bpp | 8bpp | Type 4 Xilinx protection |
| Salamander 2 | 1996 | 6bpp | 6bpp | ESC `esc_alert` mode 1 |
| Lethal Enforcers II | 1994 | 8bpp | 8bpp | Light guns: stick, d-pad or mouse, button 2 reloads, crosshair option; UAA and JAA flip their own screen |

### Out of scope for now

| MAME description | Why |
|-|-|
| Type 1: Racin' Force, Konami's Open Golf Championship, Golfing Greats 2 | `MACHINE_NOT_WORKING` in MAME; K053936 road plane, ADC0834, a LAN device MAME lacks; Open Golf is 33 MB |
| Type 3: Soccer Superstars | Two monitors on alternating frames, a second CRTC and palette, PSAC2 |
| Type 4: Versus Net Soccer, Run and Gun 2, Slam Dunk 2, Rushing Heroes | As Type 3; Rushing Heroes is 59 MB |
| Sexy Parodius (bootleg) | Two OKI6295s for sound, `MACHINE_NOT_WORKING` |

## Hardware

| Chip | Function | Status |
|-|-|-|
| 68EC020 @ 24 MHz | Main CPU | TG68K.C, on its own 24 MHz clock; a 16 KB ROM cache in front of the SDRAM |
| K053252 | CRTC, interrupts | jotego's, verified against MAME's timing |
| K054156 / K056832 | Four tilemap layers, 16 pages of VRAM | Written here (5, 6 and 8bpp), pixel-exact against MAME on captured frames |
| K053246 / K055673 | 256 sprites, zoom, shadows, 4 to 8bpp | jotego's K053246 with GX changes and a keyed line buffer; pixel-exact against MAME |
| K055555 | Priority mixer | Written here from MAME's `konamigx_mixer`, pixel-exact against MAME |
| K054338 | Alpha blending, shadows, background | Written here with the mixer |
| ESC | Sprite-list protection | MAME's `generate_sprites`, `esc_alert` modes 0 and 1 and Winning Spike's Type 4 protection, as a bus master |
| 93C46 | Serial EEPROM | Written here from MAME's `eepromser`; loaded with the set's default image from the `.mra`; not yet saved to the `.nvm` file |
| K056800 | Sound mailbox | Written here from MAME's `k056800.cpp` |
| 68000 @ 8 MHz | Sound CPU | fx68k, cycle-accurate, running the game's sound program |
| K054539 ×2 | PCM, 8 channels each | Written here from MAME's `k054539.cpp`: 8-bit, 16-bit and DPCM samples, reverb in the chip's RAM |
| TMS57002 | Effects DSP | Written here against MAME's `tms57002.cpp`; its 256 KB of RAM in SDRAM |

### Video timing

The dot clock is 6 MHz (`wrport2 & 3` = 0 on every set so far), 384 dots per line and 264 lines
per frame, from the K053252's own registers:

* 6,000,000 / 384 = **15,625 Hz** line rate
* 15,625 / 264 = **59.19 Hz** frame rate

288 × 224 visible. MAME's `konamigx()` declares `set_raw(8000000, 512, ...)`, 60 Hz; the values
above are what the game programs into the CRTC.

### Keyboard

MAME's default keys, alongside the pads:

| | Player 1 | Player 2 |
|---|---|---|
| Move | arrows | R F D G |
| Buttons 1-6 | Left Ctrl, Left Alt, Space, Left Shift, Z, X | A, S, Q, W, E |
| Start | 1 | 2 |
| Coin | 5 | 6 |

F2 is the service (test) switch, 9 and 0 the service coins, P pause.

The OSD's *Invert P1/P2* swaps the two players' controls: pads, keys and sticks.

### Save states

From Arcade-KonamiGX_20261002. Saving and restoring has been tried on the board with Daisu-Kiss. The OSD's *Save state slot*,
*Save state* and *Restore state* use four slots, which MiSTer keeps as files on the SD card. The
picture holds for about three frames while a state is written or read; the game itself does not
see a save.

States convert to and from MAME 0.289's (`.sta`, for the same set), so a moment can be taken in
MAME and looked at on the core, or the other way: `python scripts/gxss.py from-mame` and
`to-mame`. What MAME does not keep (the K053252's registers, the K054539 voices' fractions,
some timers' phases) starts afresh. [docs/SAVESTATES.md](docs/SAVESTATES.md) has the design and
what has been checked.

### High scores

From Arcade-KonamiGX_20261004. The sets MAME's `hiscore.dat` covers -- Gokujou Parodius, Fantastic Journey,
Sexy Parodius, Twin Bee Yahhoo!, Dragoon Might (ver JAA), Salamander 2 (ver JAA) and Lethal
Enforcers II (ver EAA, UAA) -- keep their high-score tables (`hiscore.v`, from the MiSTer hiscore
project). The table is read from work RAM when the OSD opens and saved, with *Autosave Hiscores*
on, in the same `.nvm` file as the EEPROM, after it; it is written back once the game has set up
its own table after power-on.

### Cheats

From Arcade-KonamiGX_20261004. The OSD's *Cheats* lists the set's cheats from its `.mra`, converted from
[Pugsy's MAME cheats](https://www.mamecheat.co.uk/) (cheat0279) by `scripts/mame_cheats.py`;
every set has some. A cheat does not
write memory: the value is replaced as the main CPU reads it (wickerwaka's engine, from the
Irem M92 core), so switching it off leaves no trace. Up to 16 codes at once. MAME cheats that
need conditions or arithmetic are not converted. A cheat MAME applies once (the "... Now!"
cheats) is held while it is on here; turn it off once it has done its job. Cheats on during the
power-on tests can make them fail.

## Screenshots

### Daisu-Kiss (ver JAA)

![daiskiss 20260927_021353-screen](docs/screenshots/daiskiss/20260927_021353-screen.png)
![daiskiss 20260927_021407-screen](docs/screenshots/daiskiss/20260927_021407-screen.png)
![daiskiss 20260927_021425-screen](docs/screenshots/daiskiss/20260927_021425-screen.png)
![daiskiss 20260927_021428-screen](docs/screenshots/daiskiss/20260927_021428-screen.png)

### Crazy Cross (ver EAA)

![crzcross 20260927_021243-screen](docs/screenshots/crzcross/20260927_021243-screen.png)
![crzcross 20260927_021227-screen](docs/screenshots/crzcross/20260927_021227-screen.png)
![crzcross 20260927_021254-screen](docs/screenshots/crzcross/20260927_021254-screen.png)

### Fantastic Journey (ver EAA)

![fantjour 20260927_021034-screen](docs/screenshots/fantjour/20260927_021034-screen.png)
![fantjour 20260927_020950-screen](docs/screenshots/fantjour/20260927_020950-screen.png)
![fantjour 20260927_021124-screen](docs/screenshots/fantjour/20260927_021124-screen.png)

### Magical Twin Bee (ver EAA)

![mtwinbee 20260927_022116-screen](docs/screenshots/mtwinbee/20260927_022116-screen.png)
![mtwinbee 20260927_022122-screen](docs/screenshots/mtwinbee/20260927_022122-screen.png)

### Sexy Parodius (ver AAA)

![sexyparoa 20260927_020540-screen](docs/screenshots/sexyparoa/20260927_020540-screen.png)
![sexyparoa 20260927_020615-screen](docs/screenshots/sexyparoa/20260927_020615-screen.png)

### Taisen Tokkae-dama (ver JAA)

![tokkae 20260927_021856-screen](docs/screenshots/tokkae/20260927_021856-screen.png)
![tokkae 20260927_021904-screen](docs/screenshots/tokkae/20260927_021904-screen.png)

### Tokimeki Memorial Taisen Puzzle-dama (ver JAB)

![tkmmpzdm 20260927_022020-screen](docs/screenshots/tkmmpzdm/20260927_022020-screen.png)
![tkmmpzdm 20260927_022014-screen](docs/screenshots/tkmmpzdm/20260927_022014-screen.png)
![tkmmpzdm 20260927_022027-screen](docs/screenshots/tkmmpzdm/20260927_022027-screen.png)

### Dragoon Might (ver AAB)

![dragoona 20260927_021555-screen](docs/screenshots/dragoona/20260927_021555-screen.png)
![dragoona 20260927_021538-screen](docs/screenshots/dragoona/20260927_021538-screen.png)
![dragoona 20260927_021540-screen](docs/screenshots/dragoona/20260927_021540-screen.png)
![dragoona 20260927_021551-screen](docs/screenshots/dragoona/20260927_021551-screen.png)
![dragoona 20260927_021602-screen](docs/screenshots/dragoona/20260927_021602-screen.png)

### Salamander 2 (ver JAA)

![salmndr2 20260927_020836-screen](docs/screenshots/salmndr2/20260927_020836-screen.png)
![salmndr2 20260927_020821-screen](docs/screenshots/salmndr2/20260927_020821-screen.png)
![salmndr2 20260927_020824-screen](docs/screenshots/salmndr2/20260927_020824-screen.png)
![salmndr2 20260927_020840-screen](docs/screenshots/salmndr2/20260927_020840-screen.png)
![salmndr2 20260927_020918-screen](docs/screenshots/salmndr2/20260927_020918-screen.png)

### Lethal Enforcers II: Gun Fighters (ver EAA)

![le2 20260927_021708-screen](docs/screenshots/le2/20260927_021708-screen.png)
![le2 20260927_021650-screen](docs/screenshots/le2/20260927_021650-screen.png)
![le2 20260927_021654-screen](docs/screenshots/le2/20260927_021654-screen.png)
![le2 20260927_021739-screen](docs/screenshots/le2/20260927_021739-screen.png)

## Installation

The release: copy `releases/Arcade-KonamiGX_<date>.rbf` to `_Arcade/cores` as `KonamiGX.rbf`
and the `.mra` files from `releases/` to `_Arcade` (clones in `_alternatives`), with the MAME
merged ROM sets and `konamigx.zip` (the BIOS, which every set needs) in `games/mame`.

To run a development build:

* `python scripts/build_staged.py`, then `python scripts/deploy.py` with a `mister.env` (see
  `scripts/deploy.py`): the core goes to `_Arcade/cores` as `KonamiGX_NNNNNNNN.rbf` (the name the
  `.mra`'s `<rbf>` tag asks for -- a release is `Arcade-KonamiGX_<date>.rbf` and is renamed to
  `KonamiGX.rbf` when copied there) and the
  `.mra` files to `_Arcade/_Konami System GX`
* Put the MAME merged ROM sets in `games/mame`, plus `konamigx.zip` (the BIOS, which every set
  needs)

### Todo

- [ ] Dragoon Might's DSP RAM test on first boot
- [ ] Dragoon Might's settings save: the EEPROM read-back check (and Gokujou Parodius's second save)
- [ ] Fantastic Journey / Gokujou Parodius: the big ship's flames, the dancer stage's background
- [ ] Sound mix levels against the PCB
- [ ] The K055673 and K056832 ROM readback windows, screen flip

### Resource usage

The release build (`KonamiGX`, commit `98ca190`, fitter seed 3) on the DE10-nano's Cyclone V
5CSEBA6, speed grade 7, timing met on every clock:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 36,916 (88%) | 41,910 |
| Block memory bits | 4,324,909 (76%) | 5,662,720 |
| RAM blocks | 545 (99%) | 553 |
| DSP blocks | 75 (67%) | 112 |
| PLLs | 3 | 6 |

The RAM block count is the one to watch: the K054539s' and the DSP's RAMs are in SDRAM for that
reason, the palette's colour bytes are kept once (in the mixer), and CRT Adjust's V-Size ring is
sized to what is left (30 blocks).

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties
(`MACHINE_IMPERFECT_GRAPHICS` on every set) noted where they matter.

* The CPU is diffed against MAME's own trace: every write of the BIOS, the memory tests and the
  game's setup, 1.59 million of them, identical in order; the game's main program and interrupt
  handlers each in their own order until a sound reply differs.
* The video path is diffed against MAME's screenshots: a software model of `konamigx_v.cpp`
  reproduces six captured frames pixel for pixel, and the RTL reproduces the model; the whole
  board, from reset, reproduces the title screenshot 64,512 of 64,512 pixels.
* The SDRAM image is downloaded into the controller against a command-decoding chip model and
  every region read back through the port the board uses, against MAME's region images, on two
  simulators.
* Each `.mra` is generated from the driver's `ROM_START` and re-read with mra-tools-c's semantics
  against the expected stream; the DIP switches come from the driver's input ports.

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework and the SDRAM
  controller (`sdram.sv`, via [Arcade-Jackal_MiSTer](https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer),
  with the burst-4 reads from the author's Psikyo core).
- **Jose Tejada** ([jotego](https://github.com/jotego)) for the K053252, K053246/K055673, K054156/K056832
  and K054338 modules and the jtframe primitives from [jtcores](https://github.com/jotego/jtcores).
- The **MAMEdev team** — **R. Belmont, Acho A. Tang, Phil Stroffolino and Olivier Galibert** — for
  `konamigx.cpp`, `konamigx_v.cpp` and the K05xxxx device emulations that are this core's
  specification.
- **furrtek** for the [SiliconRE](https://github.com/furrtek/SiliconRE) notes on the K055555 and the
  K054539.
- **Tobias Gubener** ([TobiFlex](https://github.com/TobiFlex)) for
  [TG68K.C](https://github.com/TobiFlex/TG68K.C).

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source; vendored modules carry a `PROVENANCE.md` |
| `releases` | `.mra` files |
| `docs` | the roadmap, design notes, lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | capture and verification tooling |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL v3 (see `LICENSE`). Imported components keep their own licences and are GPLv3-compatible:
TG68K.C (LGPLv3+), jotego's jtcores modules (GPL-3.0-or-later), the adapted SDR SDRAM controller
(Sorgelig, GPL-3.0-or-later), and the MiSTer framework in `sys/` (GPL-2.0-or-later). Every
modified vendored file states the change in its header, as GPLv3 §5(a) asks. `THIRD-PARTY.md` has
the detail.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
