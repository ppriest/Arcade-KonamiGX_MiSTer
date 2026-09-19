#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The main CPU's writes and I/O reads for the first N frames, from MAME.

    python scripts/mame_sys_trace.py daiskiss 120
    -> debug/daiskiss-sys/daiskiss_sys.trace

The reference the RTL main board (rtl/gx_main.sv) is compared with. See
scripts/mame/systrace.lua for what is logged.

THE EEPROM IS PINNED. The game's behaviour from reset depends on the 93C46's
contents, and MAME writes its EEPROM back to nvram/ on exit, so a run that
reads MAME's own nvram directory changes the reference for the next one.
Each run gets a fresh copy of debug/<set>-nvram/<set>/eeprom in a scratch
nvram directory, and the RTL bench loads the same file. The copy in debug/
was taken from MAME's nvram after the Phase 1 captures (docs/ROADMAP.md).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_boot_trace import load_env      # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames", type=int)
    ap.add_argument("--seconds", type=int, default=120)
    a = ap.parse_args()

    env = load_env(REPO / "mister.env")
    mame_dir = Path(os.environ.get("MAME_DIR", env.get("MAME_DIR", "")))
    mame = mame_dir / os.environ.get("MAME_EXE", env.get("MAME_EXE", "mame.exe"))
    if not mame.exists():
        sys.exit(f"MAME not found at {mame}; set MAME_DIR / MAME_EXE")
    pinned = REPO / "debug" / f"{a.game}-nvram" / a.game / "eeprom"
    if not pinned.exists():
        sys.exit(f"{pinned} missing: the pinned EEPROM image")

    out = REPO / "debug" / f"{a.game}-sys"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    with tempfile.TemporaryDirectory() as nv:
        (Path(nv) / a.game).mkdir()
        shutil.copyfile(pinned, Path(nv) / a.game / "eeprom")
        run_env = dict(os.environ, GX_OUT=out.as_posix(), GX_TAG=a.game,
                       GX_FRAMES=str(a.frames))
        cmd = [str(mame), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
               "-sound", "none", "-video", "none", "-nowindow",
               "-rompath", str(REPO / "roms"),
               "-nvram_directory", nv,
               "-seconds_to_run", str(a.seconds),
               "-autoboot_delay", "0",
               "-autoboot_script", (REPO / "scripts" / "mame" / "systrace.lua").as_posix()]
        r = subprocess.run(cmd, cwd=mame_dir, env=run_env, capture_output=True, text=True)

    trace = out / f"{a.game}_sys.trace"
    if not trace.exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no trace written -- see MAME output above")
    tail = trace.read_text().splitlines()[-2:]
    print("\n".join(tail))
    if any("FIRST ERROR" in t for t in tail):
        sys.exit("the trace recorded a tap error")
    print(f"-> {trace}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
