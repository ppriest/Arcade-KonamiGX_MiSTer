#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/gx_obj.v (jt053246 in GX configuration) against the model.

    python scripts/check_gx_obj.py daiskiss-f6000 [--hoffset N] [--voffset N] [--rom-lat N]

Writes the capture's sprite RAM, K053246/K055673 registers and the K055555
fields the sprite callback reads as bench vectors (debug/gx_obj_tb/), runs
sim/gx_obj_tb, and compares each pixel -- valid, pen, priority -- with the
solid-sprite stage of render_model.py, which is pixel-identical to MAME's
sprite picture on the same captures.

How the RTL's (vdump, hdump) map onto MAME's bitmap is two constants the
K053252 setup fixes later; the check reports the offset at which the RTL
matches best and scores every pixel at that offset. Anything but a full
match at one offset is a real difference.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm          # noqa: E402

REPO = rm.REPO
OUT = REPO / "debug" / "gx_obj_tb"
GIT_BASH = next((p for p in (r"C:\Program Files\Git\bin\bash.exe",
                             shutil.which("bash")) if p and Path(p).exists()), "bash")


def write_vectors(cap):
    OUT.mkdir(parents=True, exist_ok=True)
    spr = np.frombuffer((cap.path / "spriteram.bin").read_bytes()[:4096], dtype=">u2")
    (OUT / "spr.hex").write_text("".join(f"{v:04x}\n" for v in spr))
    k46 = (cap.path / "reg_k053246.bin").read_bytes()[:8]
    (OUT / "k46.hex").write_text("".join(f"{v:02x}\n" for v in k46))
    sr = rm.SpriteRegs(cap)
    (OUT / "k47.hex").write_text("".join(f"{v:04x}\n" for v in sr.kx47))
    k5 = cap.k055555
    shadowon, spri_min = rm.mixer_shadow_setup(cap, [k5[7], k5[10], k5[13], k5[14]])
    misc = [k5[15], k5[19], k5[27], cap.wrport[0x2001], rm.SPRITE_CFG[cap.set]["primode"],
            sum(1 << i for i in range(3) if shadowon[i]), k5[37], k5[38], k5[39], spri_min,
            0, 0, 0, 0, 0, 0]
    (OUT / "misc.hex").write_text("".join(f"{v:02x}\n" for v in misc))
    # K055673_LAYOUT_GX, assembled exactly as render_model.k055673_sprites does,
    # then one 5-byte half-row per line: index = (tile * 16 + row) * 2 + half
    rom = np.frombuffer((REPO / "debug" / f"{cap.set}-rom" / "k055673.bin").read_bytes(),
                        dtype=np.uint8)
    size4 = (len(rom) // 0x100000) // 5 * 0x400000
    four = rom[:size4].reshape(-1, 4)
    one = rom[size4:size4 + size4 // 4].reshape(-1, 1)
    comb = np.concatenate([four, one], axis=1).reshape(-1)
    n = size4 // 128
    halves = comb[:n * 160].reshape(-1, 5)
    (OUT / "rom.hex").write_text("".join(h.tobytes().hex() + "\n" for h in halves))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--hoffset", type=int, default=62, help="jt053246 HOFFSET parameter")
    ap.add_argument("--voffset", type=int, default=281,
                    help="jt053246 voffset input; 281 puts bitmap row 16 at vdump 0x110")
    ap.add_argument("--rom-lat", type=int, default=6)
    ap.add_argument("--sim", choices=["verilator", "modelsim"], default="verilator",
                    help="Verilator is ~10x faster; ModelSim is four-state (WORKFLOW 10)")
    ap.add_argument("--no-sim", action="store_true")
    a = ap.parse_args()
    cap = rm.Capture(REPO / "debug" / a.capture)

    if not a.no_sim:
        ntiles = write_vectors(cap)
        g = "-G" if a.sim == "verilator" else "-g"
        runner = "scripts/run_verilator.sh" if a.sim == "verilator" else "scripts/run_sim.sh"
        r = subprocess.run([GIT_BASH, runner, "gx_obj_tb",
                            f"{g}HOFFSET={a.hoffset}", f"+NTILES={ntiles}",
                            f"+ROM_LAT={a.rom_lat}", f"+VOFFSET={a.voffset}"],
                           cwd=REPO, capture_output=True, text=True)
        log = r.stdout + r.stderr
        (OUT / "sim.log").write_text(log)
        if r.returncode or "GX_OBJ_DONE" not in log:
            print(log[-3000:])
            return 1
        # jt053246_scan's only sign of running out of line time; the sprites
        # after that table entry are simply not drawn (LESSONS_LEARNED)
        overruns = log.count("did not finish")
        if overruns:
            print(f"FAIL: the object scan did not finish on {overruns} lines")
            return 1

    rows = [ln.split() for ln in (OUT / "out.hex").read_text().splitlines()]
    V, H = 264, 512
    valid = np.zeros((V, H), bool)
    pen, pri, idx = (np.zeros((V, H), np.int32) for _ in range(3))
    hval = np.zeros((V, H), bool)
    hfull, hcode, hidx = (np.zeros((V, H), np.int32) for _ in range(3))
    for v, h, d, i, sh in rows:
        vi, hi, x = int(v, 16) - 0xF8, int(h, 16), int(d, 16)
        valid[vi, hi] = x >> 32 & 1
        pri[vi, hi] = x >> 16 & 0xff
        pen[vi, hi] = x & 0x1fff
        idx[vi, hi] = int(i, 16)
        y = int(sh, 16)                        # valid, full, code, idx, spri, z
        hval[vi, hi] = y >> 32 & 1             # one hex digit each for valid, full, code
        hfull[vi, hi] = y >> 28 & 1
        hcode[vi, hi] = y >> 24 & 3
        hidx[vi, hi] = y >> 16 & 0xff

    _, opq, info = rm.stage_sprites_only(cap)
    mpen, mpri, midx = info["pen"], info["pri"], info["offs"] // 8
    _, (shrank, shcode, shcount), shoffs, shfull, _, _ = rm.mix_sources(cap, shadow_ids=True)
    mh = shcount > 0

    # find the (row, column) offset of the model's window in the RTL frame
    best = None
    for dv in range(V - rm.VIS_H + 1):
        for dh in range(0, H - rm.VIS_W + 1):
            w = np.s_[dv:dv + rm.VIS_H, dh:dh + rm.VIS_W]
            n = int((valid[w] & opq & (pen[w] == mpen)).sum())
            if best is None or n > best[0]:
                best = (n, dv, dh)
    n, dv, dh = best
    w = np.s_[dv:dv + rm.VIS_H, dh:dh + rm.VIS_W]
    same = (valid[w] == opq) & (~opq | ((pen[w] == mpen) & (pri[w] == mpri) & (idx[w] == midx)))
    hsame = (hval[w] == mh) & (~mh | ((hidx[w] == shoffs // 8) & (hcode[w] == shcode)
                                      & (hfull[w] == shfull)))
    print(f"{cap.set} frame {cap.manifest.get('frame')}: model window at vdump "
          f"{0xF8 + dv:#x}, hdump {dh:#x}")
    print(f"  solid  {int(same.sum())} of {same.size} pixels match (valid, pen, priority, "
          f"sprite); model {int(opq.sum())}, RTL {int(valid[w].sum())}")
    print(f"  shadow {int(hsame.sum())} of {hsame.size} pixels match (valid, sprite, code, "
          f"mode); model {int(mh.sum())}, RTL {int(hval[w].sum())}")
    return 0 if same.all() and hsame.all() else 1


if __name__ == "__main__":
    sys.exit(main())
