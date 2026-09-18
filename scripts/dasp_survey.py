#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Does each in-scope set use the TMS57002 "DASP" effects DSP?

    python scripts/dasp_survey.py                  # every in-scope set, 60 s each
    python scripts/dasp_survey.py daiskiss le2     # just these
    python scripts/dasp_survey.py --seconds 120

Phase 0 exit criterion 5 (docs/ROADMAP.md). The DSP matters because it has no
FPGA implementation anywhere and MAME gives it 256K words of external data RAM
-- if no in-scope game used it, that would be a large block of work the core
could skip. This survey answers the question with a write tap on the sound
68000's bus rather than by reading the sound programs: see
scripts/mame/tap_dasp.lua for what is counted and why.

What "used" means here: at least one program-load session, i.e. the sound CPU
drove the DSP's PLOAD line active and then streamed bytes to it. A set that
loads a program is running code on the DSP; a set that never does is leaving
it idle in reset or at whatever it powered up with.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LUA = REPO / "scripts" / "mame" / "tap_dasp.lua"

# The 22 working Type 2 sets (docs/ROADMAP.md, "Scope decision"). Clones are
# included deliberately: a regional release can ship a different sound program.
IN_SCOPE = [
    "dragoonj", "dragoona", "winspike", "winspikea", "winspikej",
    "le2", "le2u", "le2j", "tokkae", "tkmmpzdm", "salmndr2", "salmndr2a",
    "sexyparo", "sexyparoa", "gokuparo", "fantjour", "fantjoura",
    "tbyahhoo", "mtwinbee", "crzcross", "puzldama", "daiskiss",
]


def load_env(path):
    env = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def run_one(mame, mame_dir, s, seconds, outdir):
    out = outdir / f"{s}.txt"
    if out.exists():
        out.unlink()
    env = dict(os.environ, GX_OUT=str(out).replace("\\", "/"),
               GX_SECONDS=str(seconds))
    # -nodebug / -nowindow explicitly: this machine's mame.ini sets both on,
    # and a run left in the debugger never advances a frame (WORKFLOW s9).
    p = subprocess.run([str(mame), s, "-nodebug", "-nowindow", "-video", "none",
                        "-sound", "none", "-skip_gameinfo", "-nothrottle",
                        "-seconds_to_run", str(seconds + 10),
                        "-autoboot_script", str(LUA),
                        "-rompath", str(REPO / "roms")],
                       cwd=mame_dir, env=env, capture_output=True, text=True)
    if "GX_DASP_OK" not in p.stdout + p.stderr or not out.exists():
        tail = (p.stdout + p.stderr).strip().splitlines()[-4:]
        return None, " / ".join(tail)
    lines = out.read_text(encoding="utf-8").splitlines()
    kv = dict(tok.split("=", 1) for tok in lines[0].split())
    kv["session_words"] = lines[1].split("=", 1)[1] if len(lines) > 1 else ""
    return kv, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", default=IN_SCOPE)
    ap.add_argument("--seconds", type=int, default=60)
    a = ap.parse_args()

    env = load_env(REPO / "mister.env")
    mame_dir = Path(os.environ.get("MAME_DIR", env.get("MAME_DIR", "")))
    mame = mame_dir / os.environ.get("MAME_EXE", env.get("MAME_EXE", "mame.exe"))
    if not mame.exists():
        sys.exit(f"MAME not found at {mame}")

    outdir = REPO / "debug" / "dasp_survey"
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"{'set':<11} {'loads':>5} {'words':>11} {'coef':>6} {'first':>6}  sessions")
    used = []
    for s in a.sets:
        kv, err = run_one(mame, mame_dir, s, a.seconds, outdir)
        if err:
            print(f"{s:<11} FAILED: {err}")
            continue
        loads = int(kv["pload_entries"])
        words = f"{kv['words_min']}-{kv['words_max']}" if loads else "-"
        sess = kv["session_words"]
        if len(sess) > 40:
            sess = sess[:37] + "..."
        print(f"{s:<11} {loads:>5} {words:>11} {kv['cload_bytes']:>6} "
              f"{kv['first_frame']:>6}  {sess}")
        if loads:
            used.append(s)

    print()
    print(f"{len(used)} of {len(a.sets)} sets load a DSP program in the first "
          f"{a.seconds} s of attract mode.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
