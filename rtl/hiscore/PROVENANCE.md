# hiscore.v

MAME `hiscore.dat` support for MiSTer arcade cores, by Alan Steremberg and Jim Gregory
(https://github.com/JimmyStones/Hiscores_MiSTer), GPL-3.0-or-later, module version 14.

Taken from `Arcade-Psikyo_MiSTer` `rtl/hiscore.v` at `7500d51`, which is upstream version 14 with
Psikyo's local changes for a work-RAM read registered next to the RAM (marked `// Psikyo:`: one
dead cycle in the compare, two skipped cycles in the start/end checks, so `CHECK_HOLD` must be at
least 2). This core's read has the same shape (`gx_main.sv`, `hs_q`), so they are kept.
`hiscore.v_psikyo_reference` is that file unchanged.

Local changes, marked `// [GX]`:

- A dump download counts as loaded only if one of its bytes is non-zero. Main_MiSTer sends the
  `.mra`'s whole `<nvram size>`, zero-filled past a shorter file, and this core's `.nvm` holds the
  EEPROM before the hiscore data, so a file saved before hiscore support (the EEPROM's 128 bytes
  only) would otherwise restore a table of zeros over the game's. The module never saves an
  all-zero dump (`compare_nonzero`), so nothing it wrote is refused.
- `dpram_hs` is written as two ports that each read the old data, and `hiscore_buffer`'s unused
  port B is tied off. Upstream's ports also returned the written byte on a write; Quartus then
  built `hiscore_data` and `hiscore_buffer` (512 bytes each at `HS_SCOREWIDTH` 9) from registers,
  about 4,400 ALMs, and the core no longer fitted (105 %). No state reads a byte in the cycle it
  writes it.
- `hiscore_data` is a simple dual-port RAM (`dpram_hs_sdp`): one write port, the download's or the
  extract's (they never overlap), and one read port. With two writing ports that each read old
  data Quartus still refused it ("unsupported read-during-write behavior") and built it from
  registers.
