# K054156/K056832 (tilemap generator) provenance

From <https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`,
path `modules/jt05415x/hdl/`. GPL-3.0-or-later. See
[`../../../THIRD-PARTY.md`](../../../THIRD-PARTY.md); `.gitattributes` marks this directory `-text`.

| file | state |
|---|---|
| `jt05415x.v` | **verbatim** |
| `jt054156_mmr.v` | *generated* by `jtframe mmr -m jt05415x` |
| `jt054157_mmr.v` | *generated* by `jtframe mmr -m jt05415x` |

The generation procedure, and the check that the generator reproduces a file jotego does commit, are
in [`../k053252/PROVENANCE.md`](../k053252/PROVENANCE.md). Regenerate rather than hand-edit.

Dependencies: `jtframe_dual_nvram` and `jtframe_dual_ram`, in
[`../../jtframe/`](../../jtframe/PROVENANCE.md).

## What it is, and the gap to GX

Upstream's `modules/jt05415x/README.md` is worth reading in full. Two things from it that bind work
here:

1. **It is reconstructed from furrtek's silicon schematics for the K054156 and K054157**, and its
   README states that where MAME's comments and the silicon-derived logic disagree, **the silicon is
   the source of truth**. This project's accuracy target is MAME, because there is no GX PCB here.
   Both positions are right for their own project. The rule, from `docs/ROADMAP.md` under "Design
   decisions": where they collide, record it in `docs/MAME_KLUDGES.md` and keep the module's
   behaviour.
2. **The pair it models reaches 5 bpp; GX's K056832 reaches 8.** Upstream: "The later K056832 is a
   superset companion with higher color depth." GX uses `K056832_BPP_4`, `_5`, `_6` and `_8` across
   the game list, so the depths above 5 are this project's extension work. This is the largest known
   gap in the vendored set.

Also unsettled, and flagged in the roadmap's RAM budget: **how much tilemap VRAM a GX board actually
populates.** MAME allocates `0x2000 * 17` bytes (136 KB). jotego's Moo Mesa wiring is three
8K×8 SRAMs — 24 KB — for the same chip pair, because that is what that PCB has. GX banks 16 pages
through a 16 KB window, which suggests more, but a MAME write tap over a boot is what settles it,
and the answer is worth up to 900 Kbit of a device that starts at 62%.

## Verification

Upstream ships no unit bench for this module. The regression is this project's own Phase 1 software
model, as for the sprites. Analysis under Quartus 17.0.2 is checked by the staged build.
