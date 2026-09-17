#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture Konami GX video state from MAME at a chosen frame.

    python scripts/mame_capture.py daiskiss --frame 1200 --name title
    python scripts/mame_capture.py daiskiss --frame 1200 --name title --keep-going

Writes debug/<set>-<name>/ containing the RAM dumps, the reconstructed
register files, the banked tilemap VRAM, MAME's own screenshot and a
manifest. See scripts/mame/capture.lua for what is captured how, and
docs/WORKFLOW.md section 9 for why it is captured rather than hand-made.

WHAT THE REFERENCE IS AND IS NOT

Every System GX set in MAME is MACHINE_IMPERFECT_GRAPHICS, and the driver
says so about itself: konamigx_v.cpp is headed "here there be dragons", and
the mixer it implements is the part MAME is least sure of. So:

  * The RAM and register dumps are the strong artifact. They are what the
    game's own code wrote, and the RTL has to hold the same bytes. A
    difference there is a fault on our side, full stop.

  * reference.png is the weak artifact. It is MAME's rendering of that state,
    not a photograph of a PCB. A pixel difference against it is a question,
    not a verdict -- it may be our bug, or it may be one of MAME's known
    imperfections, and deciding which is what docs/MAME_KLUDGES.md is for.

Build the software model against the state, compare the picture second, and
never "fix" the model to match a pixel difference without working out which
side is wrong first.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUA = REPO / "scripts" / "mame" / "capture.lua"


def load_env(path):
    env = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set", help="MAME set name, e.g. daiskiss")
    ap.add_argument("--frame", type=int, default=1200)
    ap.add_argument("--name", default=None,
                    help="label for the output directory (default: the frame)")
    ap.add_argument("--seconds", type=int, default=None,
                    help="emulated seconds to run; default is the frame count "
                         "over 60 plus a margin")
    ap.add_argument("--out", default=None, help="override the output directory")
    ap.add_argument("--keep-going", action="store_true",
                    help="do not delete a previous capture of the same name")
    a = ap.parse_args()

    env = load_env(REPO / "mister.env")
    mame_dir = Path(os.environ.get("MAME_DIR", env.get("MAME_DIR", "")))
    mame_exe = os.environ.get("MAME_EXE", env.get("MAME_EXE", "mame.exe"))
    if not (mame_dir / mame_exe).exists():
        sys.exit(f"MAME not found at {mame_dir / mame_exe}; set MAME_DIR/MAME_EXE "
                 f"in mister.env or the environment")

    name = a.name or str(a.frame)
    out = Path(a.out) if a.out else REPO / "debug" / f"{a.set}-{name}"
    if out.exists() and not a.keep_going:
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    seconds = a.seconds if a.seconds is not None else max(10, a.frame // 60 + 10)

    # -nodebug and -nowindow are passed EXPLICITLY. This machine's mame.ini has
    # `debug 1` and `window 1`, and without these the run halts in the debugger
    # while the autoboot script still loads and still prints, so it looks like
    # it is working while the machine never advances a frame (WORKFLOW s9).
    cmd = [str(mame_dir / mame_exe), a.set,
           "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
           "-skip_gameinfo", "-seconds_to_run", str(seconds),
           "-autoboot_script", str(LUA),
           "-rompath", f"{REPO / 'roms'};{mame_dir / 'roms'}"]

    run_env = dict(os.environ, GX_OUT=str(out).replace("\\", "/"),
                   GX_FRAME=str(a.frame))
    print(f"{a.set} frame {a.frame} -> {out}")
    p = subprocess.run(cmd, cwd=mame_dir, env=run_env,
                       capture_output=True, text=True)
    blob = p.stdout + p.stderr

    err = out / "ERROR.txt"
    if err.exists():
        sys.exit(f"capture.lua failed:\n{err.read_text(encoding='utf-8')}")
    if "GX_CAPTURE_OK" not in blob:
        # A Lua failure is invisible without this: MAME exits 0 having done
        # nothing. Show what it did say.
        tail = "\n".join(blob.strip().splitlines()[-15:])
        sys.exit(f"capture did not complete (no GX_CAPTURE_OK).\n{tail}")

    man = (out / "manifest.txt").read_text(encoding="utf-8")
    print(man.strip())
    n = len(list(out.glob("*.bin")))
    print(f"{n} binary dumps + reference.png in {out}")

    # The reference is MAME's rendering, and every GX set is
    # MACHINE_IMPERFECT_GRAPHICS. Say so at the point of use, not only in the
    # docstring, so nobody treats reference.png as ground truth by habit.
    print("NOTE: reference.png is MAME's output for a MACHINE_IMPERFECT_GRAPHICS")
    print("      driver. The dumps are the reference; the picture is a question.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
