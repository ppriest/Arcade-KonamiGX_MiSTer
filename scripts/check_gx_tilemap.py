#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/gx_tilemap.sv against the software model, on a MAME capture.

    python scripts/check_gx_tilemap.py daiskiss-f6000

Writes the capture's K056832 state as bench vectors (debug/gx_tilemap_tb/),
runs sim/gx_tilemap_tb through scripts/run_sim.sh, and compares every
visible pixel of every layer -- the 6-bit colour field and the 5-bit pixel --
with render_model.layer_fields(). The model is pixel-identical to MAME on the
same captures (docs/ROADMAP.md, Progress), so a match here is a match to MAME
for the tile layers.

The RTL is compared on the fields, not on RGB, so a transparent pixel's
colour field is checked too: on hardware it still reaches the mixer.
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

# NOT plain "bash": on this machine PATH also reaches WSL's bash, which cannot
# run the Windows ModelSim tools (the same trap scripts/run_sim.sh describes).
GIT_BASH = next((p for p in (r"C:\Program Files\Git\bin\bash.exe",
                             shutil.which("bash")) if p and Path(p).exists()), "bash")
OUT = REPO / "debug" / "gx_tilemap_tb"

# konamigx_v.cpp, konamigx_5bpp video start: set_layer_offs(layer, x, y)
# (common_init: the same for every set)
LAYER_OFFS = {s: ((-2, 0), (0, 0), (2, 0), (3, 0)) for s in
              ("daiskiss", "crzcross", "puzldama", "fantjour", "fantjoura", "gokuparo",
               "mtwinbee", "tbyahhoo", "sexyparo", "sexyparoa")}


def write_vectors(cap):
    OUT.mkdir(parents=True, exist_ok=True)
    regs = rm.k056832_regs(cap)
    (OUT / "regs.hex").write_text("".join(f"{v:04x}\n" for v in regs))
    tb = (cap.path / "reg_tilebank.bin").read_bytes()[:8]
    (OUT / "tbank.hex").write_text("".join(f"{v:02x}\n" for v in tb))
    pages = rm.k056832_pages(cap).reshape(-1)
    (OUT / "vram.hex").write_text("".join(f"{v:04x}\n" for v in pages))
    offs = LAYER_OFFS[cap.set]
    (OUT / "offs.hex").write_text("".join(f"{x & 0xff:02x}\n" for x, _ in offs)
                                  + "".join(f"{y & 0xff:02x}\n" for _, y in offs))
    rom = np.frombuffer((REPO / "debug" / f"{cap.set}-rom" / "k056832.bin").read_bytes(),
                        dtype=np.uint8)
    rows = rom[:len(rom) // 40 * 40].reshape(-1, 5)
    (OUT / "rom.hex").write_text("".join(r.tobytes().hex() + "\n" for r in rows))
    return len(rows) // 8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--rom-lat", type=int, default=6, help="tile ROM latency, cycles")
    ap.add_argument("--no-sim", action="store_true", help="compare an existing out.hex")
    a = ap.parse_args()
    cap = rm.Capture(REPO / "debug" / a.capture)

    if not a.no_sim:
        ntiles = write_vectors(cap)
        r = subprocess.run([GIT_BASH, "scripts/run_sim.sh", "gx_tilemap_tb", f"+NTILES={ntiles}", f"+ROM_LAT={a.rom_lat}"],
                           cwd=REPO, capture_output=True, text=True)
        log = r.stdout + r.stderr
        (OUT / "sim.log").write_text(log)
        if r.returncode or "GX_TILEMAP_DONE" not in log:
            print(log[-3000:])
            return 1
        if "UNSUPPORTED" in log:
            print("RTL flagged an unsupported mode")
            return 1

    got = np.array([int(v, 16) for v in (OUT / "out.hex").read_text().split()], dtype=np.int32)
    got = got.reshape(rm.VIS_H, 4, rm.VIS_W)
    rc = 0
    for layer in range(4):
        col6, pix = rm.layer_fields(cap, layer)
        want = (col6.astype(np.int32) << 5) | pix
        ok = got[:, layer, :] == want
        n = int(ok.sum())
        print(f"{cap.set} frame {cap.manifest.get('frame')} layer {'ABCD'[layer]}: "
              f"{n} of {ok.size} pixels match the model")
        if n != ok.size:
            y, x = np.argwhere(~ok)[0]
            print(f"  first mismatch row {y} col {x}: RTL {got[y, layer, x]:03x}, "
                  f"model {want[y, x]:03x}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
