#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The SDRAM image path, composed: download the set's .mra stream and read
every region back through the port the board reads it from.

    python scripts/build_mra.py daiskiss          # the stream (releases/*.mra)
    python scripts/check_gx_sdram.py daiskiss     # download it, read it back

sim/gx_sdram_tb streams the .mra's image into gx_sdram_top through the ioctl
port, byte by byte as the HPS does (skipping the zero fill: the transform is
by address, not by count), against the command-decoding SDRAM chip model, and
then reads:

  the CPU port     granules of the packed maincpu image, against
                   debug/<set>-rom/maincpu.bin
  the tile port    rows, against debug/gx_tilemap_tb/rom.hex -- the 40-bit
                   rows the video benches feed gx_tilemap, so what the
                   download spread to 8 bytes must come back as
  the sprite port  half-rows, against debug/gx_obj_tb/rom.hex

The three expectations come from MAME's region images, not from the .mra, so
a wrong spread or a wrong byte order in the stream cannot agree with itself.
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra                  # noqa: E402
import build_rom_image as bri     # noqa: E402
import check_gx_obj               # noqa: E402
import mra as mra_lib             # noqa: E402
import render_model as rm         # noqa: E402

REPO = rm.REPO
OUT = REPO / "debug" / "gx_sdram_tb"


def sample(n, first=64, stride=4099):
    """The first `first` indices, then every `stride`th (a prime)."""
    return list(range(min(first, n))) + list(range(first, n, stride))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set", choices=build_mra.SETS)
    ap.add_argument("--sim", choices=("verilator", "modelsim"), default="verilator")
    ap.add_argument("--fill", default="", metavar="LO:HI",
                    help="stream this range of the .mra even where it is zeros. The zero fill "
                         "padding a graphics region to its nominal size is what drove the "
                         "one-byte spread off the end of the chip and back over the image, so "
                         "skipping it (the default, for speed) hides that class of fault.")
    ap.add_argument("--dense", type=lambda x: int(x, 0), default=0, metavar="N",
                    help="check every CPU granule below N (a byte address), not just the sample")
    ap.add_argument("--plus", nargs="*", default=[],
                    help="extra plusargs for the bench, without the + (HAMMER=1, LATENCY=1)")
    ap.add_argument("--limit", type=int, default=0,
                    help="stream only the first N bytes of each run, and sample within them (a quick ModelSim run)")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    games, blocks = bri.parse(bri.DRIVER)
    gl = build_mra.game_lines()
    mod = build_mra.SETS.index(a.set)
    lo = build_mra.rtl_arm(mod)
    parent = games.get(a.set)
    folder = build_mra.OUT_DIR if parent in (None, "0", "konamigx") else \
        build_mra.OUT_DIR / "_alternatives" / ("_" + build_mra.mra_filename(gl[parent]["title"])[:-4])
    mra = folder / build_mra.mra_filename(gl[a.set]["title"])
    import xml.etree.ElementTree as ET
    rom0 = next(r for r in ET.parse(mra).getroot().findall("rom") if r.get("index") == "0")
    zips = [REPO / "roms" / z for z in rom0.get("zip").split("|")
            if (REPO / "roms" / z).exists()]        # a clone whose files are in its parent's zip
    img = mra_lib.build_image(mra, zips)

    # the stream as runs of data: a zero fill of 4096 bytes or more is skipped
    N = len(img)
    fill_lo, fill_hi = (int(x, 0) for x in a.fill.split(":")) if a.fill else (0, 0)

    def keep(at):
        """a zero run at `at` is streamed anyway when --fill covers it"""
        return fill_lo <= at < fill_hi

    runs, bytes_out, cut = [], bytearray(), []     # cut: the tails --limit left out
    i = 0
    while i < N:
        if img[i] == 0 and not keep(i):
            j = i
            while j < N and img[j] == 0 and not keep(j):
                j += 1
            if j - i >= 4096:
                i = j
                continue
        j = i
        while j < N:
            if img[j] == 0 and not keep(j):
                k = j
                while k < N and img[k] == 0 and not keep(k):
                    k += 1
                if k - j >= 4096:
                    break
                j = k
            else:
                j += 1
        n = min(j - i, a.limit) if a.limit else j - i
        runs.append((i, n, len(bytes_out)))
        bytes_out += img[i:i + n]
        if n < j - i:
            cut.append((i + n, j))
        i = j

    def streamed(lo, hi):
        """No byte of [lo, hi) is in a tail --limit left out (a zero gap that
        was skipped reads as the zero it is)."""
        return not any(c0 < hi and lo < c1 for c0, c1 in cut)

    def spread_ok(base, size4, r, w1=1):
        return (streamed(base + 4 * r, base + 4 * r + 4)
                and streamed(base + size4 + w1 * r, base + size4 + w1 * r + w1))
    (OUT / "stream.hex").write_text("".join(f"{b:02x}\n" for b in bytes_out))
    (OUT / "runs.hex").write_text("".join(f"{s:07x} {n:07x} {o:07x}\n" for s, n, o in runs))

    # expectations
    main_img = bri.build(a.set, "maincpu")
    packed = main_img[:0x20000] + main_img[0x200000:]
    ng = min(len(packed), lo["tile_base"]) // 8      # the window past its loads is not in the image
    tile_size4, obj_size4 = lo["tile_size4"], lo["obj_size4"]
    cpu_gr = sorted(set(sample(ng)) | set(range(min(a.dense // 8, ng))))
    with open(OUT / "cpu.hex", "w") as f:
        for gi in cpu_gr:
            if not streamed(8 * gi, 8 * gi + 8):
                continue
            gran = packed[8 * gi:8 * gi + 8]
            f.write(f"{gi:05x} {int.from_bytes(gran, 'little'):016x}\n")
    # the rows as the video benches' ROM models hold them (check_gx_tilemap
    # and check_gx_obj write_vectors do this for the captured set)
    trom = bri.build(a.set, "k056832")
    tbw = build_mra.TILE_BYTES.get(a.set, 5)      # tile_data: the row's bytes, byte 0 on top
    trows = [(trom[tbw * r:tbw * r + tbw] + bytes(8 - tbw)).hex() for r in range(len(trom) // tbw)]
    # the k055673 region is its four-byte part then its fifth bytes, as MAME
    # loads it (check_gx_obj.write_vectors builds the rows the same way)
    import render_model as rm
    lay = rm.OBJ_LAYOUT.get(a.set, "GX")
    obw = {"GX": 5, "GX6": 6}.get(lay, 0)      # two-part layouts: row bytes; 0: as it comes
    orom = bri.build(a.set, "k055673")
    o4 = lo["obj_size4"]
    if lay == "GX6":                            # MAME's region: six-byte half-rows as they are
        orows = [(orom[6 * r:6 * r + 6] + bytes(2)).hex() for r in range(o4 // 4)]
    elif obw:
        orows = [(orom[4 * r:4 * r + 4] + orom[o4 + (obw - 4) * r:o4 + (obw - 4) * (r + 1)] + bytes(8 - obw)).hex()
                 for r in range(o4 // 4)]
    else:                                       # RNG 4, LE2 8 bytes a half-row
        hb = rm.OBJ_BPP[lay]
        orows = [(orom[hb * r:hb * r + hb] + bytes(8 - hb)).hex() for r in range(len(orom) // hb)]
    with open(OUT / "tile.hex", "w") as f:
        for r in sample(len(trows)):
            if spread_ok(lo["tile_base"], tile_size4, r, tbw - 4):
                f.write(f"{r:06x} {trows[r]}\n")
    with open(OUT / "obj.hex", "w") as f:
        for r in sample(len(orows)):
            if (spread_ok(lo["obj_base"], obj_size4, r, obw - 4) if obw
                    else streamed(lo["obj_base"] + hb * r, lo["obj_base"] + hb * r + hb)):
                f.write(f"{r:06x} {orows[r]}\n")
    # the sound board's ROMs: stored as they come from snd_base, so the SDRAM
    # granule is the image's own eight bytes, read through the absolute port
    snd = build_mra.snd_base(lo)
    snd_end = min(N, snd + build_mra.SND_CPU + lo["snd_pcm"])
    with open(OUT / "snd.hex", "w") as f:
        for gi in sample((snd_end - snd) // 8):
            g = snd // 8 + gi
            if not streamed(8 * g, 8 * g + 8):
                continue
            f.write(f"{g:06x} {int.from_bytes(img[8 * g:8 * g + 8], 'little'):016x}\n")
    (OUT / "cfg.hex").write_text(f"{lo['tile_base']:07x}\n{lo['obj_base']:07x}\n{tile_size4:06x}\n{obj_size4:06x}\n"
                                 f"{ {5: 0, 6: 1, 8: 2}[tbw] }\n{ {'GX': 0, 'RNG': 1, 'GX6': 2, 'LE2': 3}[lay] }\n")
    print(f"stream: {len(bytes_out):#x} bytes in {len(runs)} runs of {len(img):#x}; "
          f"{ng} CPU granules, {len(trows)} tile rows, {len(orows)} sprite half-rows")

    runner = "scripts/run_verilator.sh" if a.sim == "verilator" else "scripts/run_sim.sh"
    # the Type 3/4 sets: the 128 MB module (two chips)
    sd128 = ["-GSD128=1"] if a.set in build_mra.T34 else []
    r = subprocess.run([check_gx_obj.GIT_BASH, runner, "gx_sdram_tb"] + sd128
                       + [f"+{x}" for x in a.plus], cwd=REPO,
                       capture_output=True, text=True)
    log = r.stdout + r.stderr
    (OUT / "sim.log").write_text(log)
    lines = [ln[2:] if ln.startswith("# ") else ln for ln in log.splitlines()]   # ModelSim prefixes "# "
    tail = [ln for ln in lines if ln.startswith("  ") or ln.startswith("FAIL") or ln.startswith("PASS")]
    print("\n".join(tail[-16:]))
    return 0 if "PASS" in log and "FAIL" not in log else 1


if __name__ == "__main__":
    sys.exit(main())
