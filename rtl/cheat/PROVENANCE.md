# rtl/cheat — provenance

`cheatengine.sv` (module `cheatengine_32_16`): Martin Donlon (wickerwaka), "based on cheat code
handling by Kitrinx". GPL-2.0-or-later, as its header states. Copied from
[MiSTer-devel/Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer)
`rtl/cheatengine.sv` at commit `68a4683`. The unmodified file is beside it as
`cheatengine.sv_upstream_reference`.

It overrides data as the CPU reads it: a code names an address, an optional compare value and a
replacement (or an OR or AND), so nothing is written to memory and a cheat switched off leaves no
trace. Codes come from the `.mra`'s `<cheats>` block through Main_MiSTer, 16 bytes each on ioctl
index 255.

## Local changes

Marked in the file:

- **LOCAL CHANGE**: byte lanes for a big-endian CPU. Upstream serves the little-endian V33/V35,
  where the byte at an even address is bits 7:0. On the 68020's 16-bit bus it is bits 15:8, and a
  long's high word is at the lower address.
- **LOCAL FIX**: a 4-byte code with the compare flag never matched. The engine views a 16-bit read
  as half of a 32-bit word with the other half zero, and compared all 32 bits; upstream also set
  the 4-byte compare value to 0. Each read now compares only its own half, against its half of
  the code's compare value.
- **LOCAL CHANGE**: `data_out` declared `logic`: it is assigned in `always_comb`, which Verilator
  refuses for a net (Quartus accepts it).
- **LOCAL CHANGE**: `code_t` declared `packed`: Verilator cannot save an unpacked struct, and the
  main bench's model is built `--savable` (snapshots). Every field is a bit vector.
