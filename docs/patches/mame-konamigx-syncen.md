# MAME patch: konamigx interrupt "syncen" latch

`mame-konamigx-syncen.patch` (one commit, `git am`-able) against mamedev `5c75784`.
It changes `src/mame/konami/konamigx.cpp` only. The core has the same change (`rtl/gx_main.sv`,
`64e0fc8`).

## The fault

`m_gx_syncen` bits 0-4 arm one interrupt per enabled level on any write of the IRQ register
(`0xd56001`) with bit 7 set. The armed interrupt is delivered at the next vblank (DMA end for
IRQ 3), even if the game has cleared that enable bit, or bit 7, since. Two games turn interrupts
off for an EEPROM save and are interrupted anyway. Their vblank handler writes the EEPROM port
(`0xd56000`) from its shadow, which drops the 93C46's CS. A 93C46 with CS low "is held in a Reset
status" (Microchip DS21749H §3.1), so the command being shifted is lost.

- **Dragoon Might** (`dragoona`, `dragoonj`): the service-menu save (`0x243b1e`) does four things:
  1. clears bit 7 and writes the changed words;
  2. sets bit 7, which arms `syncen`;
  3. clears bit 7 again;
  4. reads all 64 words back and compares their byte sum with word 0.

  The vblank handler (`0x202fde`) runs during the read-back and calls `0x20313c`, which writes
  `0xd56000` twice. The sum fails and the save retries. In MAME the first try fails and the second
  passes. On the FPGA core every try is slower, so all three fail: "EEPROM CHECKSUM ERROR".
- **Gokujou Parodius / Fantastic Journey** (`gokuparo`, `fantjour`): the vblank handler (`0x2a09d4`)
  writes `0x90` then `0x91` every frame, which arms `syncen` each time. The save writes `0x90` to
  stop the handler, but the armed interrupt keeps it running. Writes interrupted during their bits
  are lost. In one MAME run of a settings save, 6 commands were split this way. The save survives
  only while the lost words are ones that did not change; otherwise the next boot fails its EEPROM
  check.

## The change

1. An armed interrupt waits while bit 7 ("mask all IRQ") is clear.
2. A write made by a level's own handler does not arm that level. "Own handler" means the CPU's
   interrupt mask equals the level.

Writes from the main program still arm. Twin Bee Yahhoo! needs that: it writes `0x91`, `0xd1` and
`0x90` from its main program (mask 0) and then waits for its vblank handler.

## Why the latch is not hardware

- **No documented origin.** `syncen` is absent from MAME 0.67 and present in 0.68, under "Various
  Konami Related Fixes and Improvements [Acho A. Tang, R. Belmont]", with no rationale
  ([mame067](https://github.com/mamedev/historic-mame/blob/mame067/src/drivers/konamigx.c),
  [mame068](https://github.com/mamedev/historic-mame/blob/mame068/src/drivers/konamigx.c),
  [whatsnew 0.68](https://www.mamedev.org/releases/whatsnew_068.txt)). No GX schematic or PAL
  equations were found.
- **What the CCU does.** The K053252's INT1 is a flip-flop: vblank sets it, and only a write to
  register 0x0e clears it. It is a held level, not a pulse
  ([furrtek SiliconRE 053252](https://github.com/furrtek/SiliconRE/tree/master/Konami/053252),
  [hdl/053252.v](https://github.com/furrtek/SiliconRE/blob/master/Konami/053252/hdl/053252.v)).
  `syncen` bits 0x20/0x40 model that part, and this patch leaves them alone.
- **Other drivers.** No other K053252 driver arms on an enable write: `rollerg`, `dbz`,
  `konmedal`, `tasman`. Neither do the related Konami boards, which gate on the current enable bits:
  [`mystwarr.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/konami/mystwarr.cpp),
  [`xexex.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/konami/xexex.cpp),
  [`lethal.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/konami/lethal.cpp),
  [`rungun.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/konami/rungun.cpp).
  Nothing outside MAME and its forks has `gx_syncen`.
- **The games' own code.** Both save routines turn interrupts off around the EEPROM traffic,
  which only makes sense if the hardware then stops delivering them.

Removing the arming entirely would be the simplest model consistent with the above. It is not
done here because Twin Bee's boot waits on it; that case needs a board to settle.

## How it was found and checked

MAME 0.289 was driven by Lua into each service menu: Game Options, change a setting, Save and Exit.
The main CPU's writes to `0xd56000`/`0xd56001` and reads of `0xd5a003` were logged with their PC.
The same moments were saved as `.sta` files, converted for the core's simulation, and replayed
there.

Patched build (`konamigx` single driver, this commit):

| Case | Stock 0.289 | Patched |
|---|---|---|
| `dragoonj` settings save | 2 tries (first interrupted at word 44) | 1 try, 81 commands, no handler writes inside the routine |
| `gokuparo` settings save | vblank handler runs every frame of the save; split commands | all 64 writes complete, no handler writes inside the routine |
| 12 sets × 2500 frames from power-on (`daiskiss` `crzcross` `fantjour` `gokuparo` `tbyahhoo` `sexyparo` `tokkae` `tkmmpzdm` `dragoona` `salmndr2` `winspike` `le2`): IRQ-register writes | — | identical for 10 sets; `tkmmpzdm` 17,489 vs 17,509 and `dragoona` 10,088 vs 10,032, both at the same screen at frame 2500 |

On the FPGA core, run from MAME states: `tbyahhoo` (from before its `0x91`/`0xd1`/`0x90`
sequence), `crzcross`, `tkmmpzdm`, `dragoonj` and `winspike` all keep their vblank and DMA handlers
every frame.

Not yet checked: either game's save on a real PCB with this behaviour, and the full `konamigx`
set list beyond the twelve above.
