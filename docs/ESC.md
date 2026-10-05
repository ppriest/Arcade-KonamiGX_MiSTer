# The 056734 (ESC)

The protection microcontroller on the ESC titles' boards. MAME replaces its program with C per
game (`konamigx.cpp`, `*_esc`); `rtl/gx_esc.v` reproduces that C. `rtl/esc/k056734.sv` runs the
chip instead: the kernel from the game ROM, decrypted with the chip's key, and whatever program the
game uploads, decrypted by that kernel.

The instruction set, kernel, image format, ciphers and per-chip constants are in
`konami_056734_manual.md`, in `ppriest/mame-ai-tips`, branch `056734-cipher` (R. Belmont's
document plus §8 and the decrypted listings).

## Per chip

| Set | `s10[15:0]` | `s11[27:24]` | descrambler XOR |
|---|---|---|---|
| puzldama | `5D32` | 3 | `91C2C6FB` |
| tokkae | `9E8E` | B | `6BFBB5B9` |
| tkmmpzdm | `4924` | C | `88600EF4` |
| daiskiss | `89EE` | D | `39556CC0` |
| tbyahhoo | `0424` | A | `DE78B8AE` |
| gokuparo | `8D8C` | 3 | `2C3EA1C4` |
| dragoonj | `5963` | B | `049DB8E5` |
| salmndr2 | `1EC6` | A | `B3F135B3` |
| sexyparo | `896A` | E | `1886AE1D` |

The lane maps are in `scripts/k056734/esccipher.py` (`CHIPS`). Clones were not checked.

## Differences from the chip

- The internal boot ROM and the boot object (RAM tests, BIOS checksum, warning text check) are not
  run. A loader decrypts the kernel and enters it with `r2`, `r3`, `r24`, `r25` and `s1` as the boot
  code leaves them. In the model this gives the same result for every captured packet as running
  the boot code (Sexy Parodius: packet results, work RAM and sprite RAM identical).
- Local memory is 4K words; `0x1000`-`0x1FFF` alias it. The model gives identical results with 4K
  and 64K for every capture below.
- Opcode `30002` (boot RAM test only) is taken as `neg`; nothing after the boot uses it.

On the board (`KonamiGX_30000050`, `fa152d3`): Sexy Parodius shows stage 1's snow, which no
build before the chip drew; save states taken and restored.

## Save states

Three sections of the image (`rtl/gx_ss_layout.svh`: `esch`, `escl`, `escr`). A save or load
stops the chip at an instruction for the walk. A state converted from MAME gets the chip's state
from `scripts/k056734/synth.py` (docs/SAVESTATES.md). `sim/k056734_tb` checks a round trip:
`esc_chip_check.py --ss-at k` reads the state after packet k, resets the chip, writes the state
back, and the remaining packets must still match the model (Sexy Parodius, k = 5: they do).

## Versus MAME's C

Running the real programs, the sprite lists differ from MAME's in two ways for the titles whose
program builds the list from object records (Daisu-Kiss, Twin Bee Yahhoo!, Sexy Parodius): word 0
carries the output index where MAME puts the priority, and x is 20 (`0x14`) larger. Otherwise the
entries match. Dragoon Might's and Tokimeki Memorial's lists are identical to MAME's.

## Checking

```
python scripts/esc_chip_check.py <set> --rom <68020 0x200000-0x3FFFFF> --bios <0x000000-0x07FFFF> --cap <dir>
```

runs `sim/k056734_tb` against `scripts/k056734/chip.py` on captured packets (work RAM at each
mailbox write, from a MAME Lua tap). Passing: the boot packets and 40 packets from power-on for
daiskiss, tbyahhoo, salmndr2, dragoonj, puzldama, tokkae and tkmmpzdm, and Sexy Parodius's boot
packets plus 9 attract-mode RUNs. Gokujou Parodius sent no packet in 2400 frames.
