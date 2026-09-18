#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/gx_video.sv -- tilemap, sprites and mixer together -- against MAME.

    python scripts/check_gx_video.py daiskiss-f6000 [--sim modelsim]

Writes the capture's state as the three block benches' vector files, runs
sim/gx_video_tb, and compares the whole visible frame with MAME's own
screenshot (reference.png). Nothing from the software model is in the
comparison: VRAM, sprite RAM, registers, palette and ROMs go in, RGB comes
out, and it is scored against MAME's picture.

The timing is the K053252's, programmed with the registers the game wrote
(reg_k053252.bin: MAME maps the chip with umask32(0xff00ff00), so register
n is byte 2n). The bench records every pixel gx_video's own delayed
blanking marks visible, in raster order; that list must be exactly MAME's
288 x 224 visible area. No window position is assumed.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm          # noqa: E402
import check_gx_tilemap            # noqa: E402
import check_gx_obj                # noqa: E402
import check_gx_mixer              # noqa: E402

REPO = rm.REPO
OUT = REPO / "debug" / "gx_mixer_tb"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--sim", choices=["verilator", "modelsim"], default="verilator")
    ap.add_argument("--no-sim", action="store_true")
    a = ap.parse_args()
    cap = rm.Capture(REPO / "debug" / a.capture)

    if not a.no_sim:
        tn = check_gx_tilemap.write_vectors(cap)
        on = check_gx_obj.write_vectors(cap)
        check_gx_mixer.write_vectors(cap)
        crtc = (cap.path / "reg_k053252.bin").read_bytes()
        (OUT / "crtc.hex").write_text("".join(f"{crtc[2 * n]:02x}\n" for n in range(16)))
        runner = "scripts/run_verilator.sh" if a.sim == "verilator" else "scripts/run_sim.sh"
        r = subprocess.run([check_gx_obj.GIT_BASH, runner, "gx_video_tb",
                            f"+TNTILES={tn}", f"+ONTILES={on}"],
                           cwd=REPO, capture_output=True, text=True)
        log = r.stdout + r.stderr
        (OUT / "video_sim.log").write_text(log)
        if r.returncode or "GX_VIDEO_DONE" not in log:
            print(log[-3000:])
            return 1
        if "UNSUPPORTED" in log:
            print("FAIL: the mixer flagged an unsupported mode")
            return 1
        overruns = log.count("did not finish")
        if overruns:
            print(f"FAIL: the object scan did not finish on {overruns} lines")
            return 1

    px = [int(v, 16) for v in (OUT / "video_out.hex").read_text().split()]
    if len(px) != rm.VIS_W * rm.VIS_H:
        print(f"FAIL: {len(px)} visible pixels, MAME's visible area is {rm.VIS_W} x {rm.VIS_H}")
        return 1
    px = np.array(px, dtype=np.int64)
    got = np.stack([px >> 16 & 0xff, px >> 8 & 0xff, px & 0xff], axis=-1)
    got = got.reshape(rm.VIS_H, rm.VIS_W, 3).astype(np.uint8)
    ref = cap.reference()
    same = np.all(got == ref, axis=-1)
    print(f"{cap.set} frame {cap.manifest.get('frame')}: {int(same.sum())} of {same.size} "
          f"pixels identical to MAME's screenshot")
    if not same.all():
        y, x = np.argwhere(~same)[0]
        print(f"  first difference row {y} col {x}: RTL {got[y, x]}, MAME {ref[y, x]}")
    np.save(OUT / "video_rgb.npy", got)
    return 0 if same.all() else 1


if __name__ == "__main__":
    sys.exit(main())
