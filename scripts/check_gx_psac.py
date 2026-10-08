#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/video/gx_psac.sv against scripts/psac2_model.py.

    python scripts/check_gx_psac.py <dump-dir> <n> [--lat N]

Writes dump n's registers, line control and bank, and soccerss's gfx3 and
gfx4 as 64-bit granules (byte 0 in [63:56]), runs sim/gx_psac_tb, and
compares every { colour, pixel } of rows 16-239 with the model's. --lat is
the SDRAM fetch time in clocks for a granule the port does not hold.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import psac2_model as pm        # noqa: E402

REPO = pm.REPO
OUT = REPO / "debug" / "gx_psac_tb"
GIT_BASH = next((p for p in (r"C:\Program Files\Git\bin\bash.exe",
                             shutil.which("bash")) if p and Path(p).exists()), "bash")


def granules(b):
    return "".join(b[i:i + 8].hex() + "\n" for i in range(0, len(b), 8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("n", type=int)
    ap.add_argument("--lat", type=int, default=12)
    ap.add_argument("--occ", type=int, default=5, help="clocks one SDRAM access occupies it")
    ap.add_argument("--passes", type=int, default=1, help="render the frame this many times (the cache warm after the first)")
    a = ap.parse_args()
    d, p = Path(a.dir), f"d{a.n}_"
    OUT.mkdir(parents=True, exist_ok=True)
    ctrl, line = (d / f"{p}ctrl.bin").read_bytes(), (d / f"{p}line.bin").read_bytes()
    bank = int((d / f"{p}info.txt").read_text().split()[1], 16)
    (OUT / "regs.hex").write_text("".join(f"{w:04x}\n" for w in pm.words(ctrl)))
    (OUT / "line.hex").write_text("".join(f"{w:04x}\n" for w in pm.words(line)))
    (OUT / "misc.hex").write_text(f"{bank:02x}\n")
    gfx3, gfx4 = pm.roms()
    (OUT / "gfx3.hex").write_text(granules(gfx3))
    (OUT / "gfx4.hex").write_text(granules(gfx4))

    (OUT / "out.hex").unlink(missing_ok=True)
    run = subprocess.run([GIT_BASH, "scripts/run_verilator.sh", "gx_psac_tb", f"+LAT={a.lat}", f"+OCC={a.occ}", f"+PASSES={a.passes}"],
                         cwd=REPO, capture_output=True, text=True)
    done = [ln for ln in run.stdout.splitlines() if "GX_PSAC_DONE" in ln]
    if not done:
        print(run.stdout[-2000:], run.stderr[-2000:])
        return 1
    print(done[0].strip())

    rtl = [int(v, 16) for v in (OUT / "out.hex").read_text().split()]
    lay = pm.layer(ctrl, line, bank, 1)
    bad = 0
    for i, y in enumerate(range(16, 240)):
        want = [v & 0x3ff if v else 0 for v in lay[y]]
        got = rtl[i * 288:(i + 1) * 288]
        for x in range(288):
            if got[x] != want[x]:
                if not bad:
                    print(f"first difference row {y} column {x}: RTL {got[x]:03x}, model {want[x]:03x}")
                bad += 1
    print(f"{224 * 288 - bad} of {224 * 288} pixels as the model's")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
