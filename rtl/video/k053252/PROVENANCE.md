# K053252 (CRTC / interrupt generator) provenance

From <https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`.

| file | upstream path | state |
|---|---|---|
| `jtk053252.v` | `cores/rungun/hdl/jtk053252.v` | **verbatim** |
| `jtk053252_mmr.v` | *generated* — see below | **as generated** |

SPDX header: `GPL-3.0-or-later`, `SPDX-FileCopyrightText: 2026 Jose Tejada Gomez`. Direct into this
project's GPL-3.0-or-later; see [`../../../THIRD-PARTY.md`](../../../THIRD-PARTY.md).
`.gitattributes` marks this directory `-text` so the bytes round-trip exactly.

Helper modules it instantiates — `jtframe_edge`, `jtframe_count_ld`, `jtframe_ff_jk` — are vendored
separately in [`../../jtframe/`](../../jtframe/PROVENANCE.md), because other jotego modules will
want them too.

## `jtk053252_mmr.v` is generated, not checked in upstream

jotego generates the register-decode modules with `jtframe mmr <core>` from `cfg/mmr.yaml` rather
than committing them. `jtframe` is a Go program in `modules/jtframe/src/jtframe`.

What was done here, so it can be redone:

```
pacman -S mingw-w64-x86_64-go            # MSYS2; GOROOT=/e/msys64/mingw64/lib/go
git clone --depth 1 --filter=blob:none --sparse https://github.com/jotego/jtcores.git
git -C jtcores sparse-checkout set modules/jtframe cores/rungun cores/moo cores/simson modules/jt05415x
cd jtcores/modules/jtframe/src/jtframe && go build -o jtframe.exe .
JTROOT=... JTFRAME=... CORES=... MODULES=... JTBIN=... jtframe mmr rungun
```

**The generator was checked before its output was trusted.** `cores/simson/hdl/jt053246_mmr.v` is
one jotego *does* commit; regenerating it with this build reproduced the committed file
byte-for-byte (`git diff` empty). So the copy here is what upstream's own toolchain produces, not a
reconstruction.

Regenerate rather than hand-edit if upstream's `mmr.yaml` changes.

## What it provides, against what GX needs

The K053252 is the GX CRTC at `0xd4c000` (`CCUS1`), `umask32(0xff00ff00)` — sixteen 8-bit registers
on alternate byte lanes. `konamigx.cpp` clocks it at `MASTER_CLOCK/4` = 6 MHz, wires
`int1_ack`/`int2_ack` to the driver's vblank and hblank acknowledges, and calls `set_offsets()` with
a per-game X/Y offset ranging from `(0,16)` to `(24+16,16)`.

The module carries `int1`, `int2`, `int1ack`, `int2ack`, `lhbl`, `lvbl`, `hs`, `vs` and an
`ioctl_addr`/`ioctl_din` dump port. Its header records one deliberate omission, which
LESSONS_LEARNED's "*Treat a conspicuous omission in a vendored module as deliberate*" says to read
rather than fill in:

> `sel[1:0]` clock divider — "the clock divider is not implemented. Apply the expected `pxl_cen`
> directly."

GX selects its dot clock (6, 8 or 12 MHz) outside the chip anyway, so this project supplies
`pxl_cen` from its own clock plan. That is a fit, not a gap.

`INIT` is a 128-bit parameter giving the sixteen registers' power-on values, register *k* at
`INIT[(15-k)*8 +: 8]`. The default in the module is Run and Gun's. **GX's has to come from the
driver's own CCU table** — `konamigx.cpp`'s header comments it as `HCH/HCL/HFP/HBP/VCH/VCL/VFP/VBP/
VSW/HSW` for 6M/288, 8M/384 and 12M/576 — and setting it is Phase 1 work, not something inherited.

## Verification

**Upstream's own bench runs here and passes**, which is the WORKFLOW §12 rule satisfied rather than
waived. It is *differential*: `cores/rungun/ver/k053252/test.v` drives `jtk053252.v` and furrtek's
silicon-derived `053252.v` together and compares them. Both, plus the bench, are vendored into
`sim/k053252_tb/`.

```
scripts/run_jt_unit.sh k053252_tb        # PASS
```

Run it before and after any edit to this directory. A regression here is a porting fault, not a GX
finding.

Upstream drives it with `modules/jtframe/bin/simunit.sh`, which needs `$JTROOT`/`$JTFRAME`/`$JTBIN`,
a Go helper per bench, `envsubst` and `.` on `PATH`. `scripts/run_jt_unit.sh` calls Icarus directly
with the same file list instead; `sim/k053252_tb/files.f` is that list.

One benign warning: `invalid file descriptor (0x0) given to $fseek` is the module's optional
`SIMFILE` power-on-state file (`ccu.bin`) being absent.
