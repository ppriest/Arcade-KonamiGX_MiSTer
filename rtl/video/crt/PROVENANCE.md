# rtl/video/crt — provenance

Author: Umberto Parisi (rmonic79). GPL-3.0-or-later.

Both files are copied from `Arcade-Psikyo_MiSTer` at commit `8e39bb6` (`rtl/video/`), which
vendored them from:

| file | upstream | commit |
|---|---|---|
| `crt_adjust.sv` | `rmonic79/Arcade-Raiden_MiSTer`, `rtl/Raiden/crt_adjust.sv` | not recorded by Psikyo |
| `crt_vsize.sv` | <https://github.com/rmonic79/MiSTer-CRT-Adjust>, `rtl/crt_vsize.sv` | `c682de9` |

## Local changes

Each is marked `LOCAL FIX` in the file.

- `crt_adjust.sv` (Psikyo's): `hoff_s`'s `?:` kept signed. Mixing a signed and an unsigned operand
  makes the whole expression unsigned, so a negative H-Position was zero-extended and blanked the
  picture.
- `crt_vsize.sv` (this project's): the write index `wpx` stopped at `LINE_PX-1`, so a line of
  exactly `LINE_PX` pixels stored `LINE_PX-1` and PVM mode dropped the last pixel of each of GX's
  384-wide lines (`sim/gx_crt_chain_tb`, `dragoonj.hex`).
- `crt_vsize.sv` (this project's, marked `LOCAL CHANGE`): the ring carries `max_depth = 2048`, so
  Quartus builds GX's 32 x 384 x 24 ring from 2048 x 5 blocks, 30 M10K, where it chose 1024 x 10,
  36. The core had 6 blocks left with 36.

The glue, `rtl/video/gx_crt_chain.sv`, is this project's, after Psikyo's `crt_chain.sv`.
