#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/gx_mixer.v against MAME's screenshot.

    python scripts/check_gx_mixer.py daiskiss-f6000 [--sim modelsim]

Writes the capture's K055555/K054338 registers, palette and background
select, and per pixel the inputs the mixer receives -- the four tile layer
words gx_tilemap produces and the solid and shadow planes gx_obj produces,
taken from render_model.py, which those RTL blocks match exactly on these
captures -- runs sim/gx_mixer_tb and compares every output pixel with MAME's
own screenshot (reference.png). No model in the comparison: RTL against MAME.
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
OUT = REPO / "debug" / "gx_mixer_tb"
GIT_BASH = next((p for p in (r"C:\Program Files\Git\bin\bash.exe",
                             shutil.which("bash")) if p and Path(p).exists()), "bash")


def write_vectors(cap):
    OUT.mkdir(parents=True, exist_ok=True)
    k55 = list(cap.k055555) + [0] * (64 - len(cap.k055555))
    (OUT / "k55.hex").write_text("".join(f"{v:02x}\n" for v in k55))
    (OUT / "k338.hex").write_text("".join(f"{v:04x}\n" for v in cap.k054338))
    pal = (cap.pal[:, 0].astype(int) << 16) | (cap.pal[:, 1].astype(int) << 8) | cap.pal[:, 2]
    (OUT / "pal.hex").write_text("".join(f"{v:06x}\n" for v in pal))
    (OUT / "misc.hex").write_text(f"{1 if cap.wrport1_0 & 0x20 else 0:02x}\n00\n00\n00\n")

    lw = []
    for L in range(4):
        col6, pix = rm.layer_fields(cap, L)
        lw.append((col6.astype(np.int64) << 5) | pix)
    lyr = (lw[0] << 33) | (lw[1] << 22) | (lw[2] << 11) | lw[3]
    (OUT / "lyr.hex").write_text("".join(f"{v:011x}\n" for v in lyr.ravel()))

    _, opq, info = rm.stage_sprites_only(cap)
    spr = ((opq.astype(np.int64) << 45) | (info["pen"].astype(np.int64) << 32)
           | (info["pri"].astype(np.int64) << 24) | (info["z"].astype(np.int64) << 16)
           | ((np.maximum(info["offs"], 0) // 8).astype(np.int64) << 8))
    spr = np.where(opq, spr, 0)
    (OUT / "spr.hex").write_text("".join(f"{v:012x}\n" for v in spr.ravel()))

    _, (_, shcode, shcount), shoffs, _, shpri, shz = rm.mix_sources(cap, shadow_ids=True)
    hv = shcount > 0
    shd = ((hv.astype(np.int64) << 34) | (shcode.astype(np.int64) << 32)
           | (shpri.astype(np.int64) << 24) | (shz.astype(np.int64) << 16)
           | ((np.maximum(shoffs, 0) // 8).astype(np.int64) << 8))
    shd = np.where(hv, shd, 0)
    (OUT / "shd.hex").write_text("".join(f"{v:09x}\n" for v in shd.ravel()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--sim", choices=["verilator", "modelsim"], default="verilator")
    ap.add_argument("--no-sim", action="store_true")
    a = ap.parse_args()
    cap = rm.Capture(REPO / "debug" / a.capture)

    if not a.no_sim:
        write_vectors(cap)
        runner = "scripts/run_verilator.sh" if a.sim == "verilator" else "scripts/run_sim.sh"
        r = subprocess.run([GIT_BASH, runner, "gx_mixer_tb"], cwd=REPO,
                           capture_output=True, text=True)
        log = r.stdout + r.stderr
        (OUT / "sim.log").write_text(log)
        if r.returncode or "GX_MIXER_DONE" not in log:
            print(log[-3000:])
            return 1
        if "UNSUPPORTED" in log:
            print("FAIL: the mixer flagged an unsupported mode")
            return 1

    got = np.array([int(v, 16) for v in (OUT / "out.hex").read_text().split()], dtype=np.int64)
    got = np.stack([got >> 16 & 0xff, got >> 8 & 0xff, got & 0xff], axis=-1)
    got = got.reshape(rm.VIS_H, rm.VIS_W, 3).astype(np.uint8)
    ref = cap.reference()
    same = np.all(got == ref, axis=-1)
    print(f"{cap.set} frame {cap.manifest.get('frame')}: {int(same.sum())} of {same.size} "
          f"pixels identical to MAME's screenshot")
    if not same.all():
        y, x = np.argwhere(~same)[0]
        print(f"  first difference row {y} col {x}: RTL {got[y, x]}, MAME {ref[y, x]}")
    np.save(OUT / "last_rgb.npy", got)
    return 0 if same.all() else 1


if __name__ == "__main__":
    sys.exit(main())
