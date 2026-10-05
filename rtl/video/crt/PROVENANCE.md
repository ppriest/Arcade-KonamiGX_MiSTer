# rtl/video/crt — provenance

Author: Umberto Parisi (rmonic79). GPL-3.0-or-later.

Copied from `Arcade-Psikyo_MiSTer` at commit `8e39bb6` (`rtl/video/`), which vendored it from:

| file | upstream | commit |
|---|---|---|
| `crt_adjust.sv` | `rmonic79/Arcade-Raiden_MiSTer`, `rtl/Raiden/crt_adjust.sv` | not recorded by Psikyo |

`crt_vsize.sv` (V-Size, from <https://github.com/rmonic79/MiSTer-CRT-Adjust>) was removed: its
line ring's 30 M10K went to the 056734 (ESC) local memory.

## Local changes

Marked `LOCAL FIX` in the file.

- `crt_adjust.sv` (Psikyo's): `hoff_s`'s `?:` kept signed. Mixing a signed and an unsigned operand
  makes the whole expression unsigned, so a negative H-Position was zero-extended and blanked the
  picture.

The glue, `rtl/video/gx_crt_chain.sv`, is this project's, after Psikyo's `crt_chain.sv`.
