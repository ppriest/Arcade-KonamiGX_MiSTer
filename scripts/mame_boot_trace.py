#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture the first N main-CPU bus accesses of a game's boot from MAME.

    python scripts/mame_boot_trace.py daiskiss 20000
    -> debug/daiskiss-boot/daiskiss_boot.trace

The reference TG68K.C's boot is diffed against -- docs/ROADMAP.md, Phase 0 exit
criterion 2. Ported from the Jaleco MS32 core's script of the same name.

Conventions carried over, each for a reason recorded in LESSONS_LEARNED:

  * -nodebug and -nowindow are passed explicitly. This machine's mame.ini says
    `debug 1` and `window 1`, and then every launch halts in the debugger while
    the autoboot script still loads and still prints, so it looks like it is
    working while the machine never advances a frame.
  * -autoboot_delay 0. A boot trace that starts late has missed the reset
    vector fetch, which is the first thing it exists to check.
  * -nothrottle. Nothing here needs real time, and without it MAME runs at
    100% speed.
  * The output directory is deleted and recreated, so a trace is never a
    mixture of two runs.
  * The Lua side counts tap hits beside logged lines; an error inside a tap is
    swallowed by MAME and would otherwise read as "no accesses happened".
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


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
    ap.add_argument("game")
    ap.add_argument("n", type=int, help="accesses to log")
    ap.add_argument("--seconds", type=int, default=30,
                    help="MAME -seconds_to_run backstop (default 30)")
    a = ap.parse_args()

    env = load_env(REPO / "mister.env")
    mame_dir = Path(os.environ.get("MAME_DIR", env.get("MAME_DIR", "")))
    mame = mame_dir / os.environ.get("MAME_EXE", env.get("MAME_EXE", "mame.exe"))
    if not mame.exists():
        sys.exit(f"MAME not found at {mame}; set MAME_DIR / MAME_EXE")

    out = REPO / "debug" / f"{a.game}-boot"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    run_env = dict(os.environ, GX_OUT=out.as_posix(), GX_TAG=a.game,
                   GX_TRACE_N=str(a.n))
    cmd = [str(mame), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-rompath", str(REPO / "roms"),
           "-seconds_to_run", str(a.seconds),
           "-autoboot_delay", "0",
           "-autoboot_script", (REPO / "scripts" / "mame" / "boottrace.lua").as_posix()]
    r = subprocess.run(cmd, cwd=mame_dir, env=run_env, capture_output=True, text=True)

    trace = out / f"{a.game}_boot.trace"
    if not trace.exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no trace written -- see MAME output above")
    lines = trace.read_text().splitlines()
    for ln in lines[-2:]:
        print(ln)
    if any(ln.startswith("# FIRST ERROR") for ln in lines):
        sys.exit("the trace recorded a tap error -- see the file")
    print(f"-> {trace}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
