#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""gx_tms57002 against MAME's host traffic (sim/gx_tms57002_tb).

    python scripts/check_gx_tms57002.py debug/dasp_logs/fantjour.txt [--seconds S] [--lat N]

The log is scripts/mame/dasp_log.lua's. Its microseconds become 48 MHz
clocks from the first access; the bench replays writes and compares reads.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KIND = {"C": 0, "W": 1, "R": 2, "S": 3}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--seconds", type=float)
    ap.add_argument("--lat", type=int, default=12)
    ap.add_argument("--lock", help="lockstep against this scripts/tms57002.py lock output")
    ap.add_argument("--samples", type=int)
    a = ap.parse_args()
    if a.lock:
        return lock(a)
    out = REPO / "obj_verilator" / "tms_events.txt"
    out.parent.mkdir(exist_ok=True)
    t0 = None
    last = 0
    n = 0
    with open(a.log) as f, open(out, "w") as o:
        for line in f:
            us, fr, k, v = line.split()
            us = int(us)
            if t0 is None:
                t0 = us - 100
            if a.seconds and us - t0 > a.seconds * 1e6:
                break
            c = max((us - t0) * 48, last + 4)     # keep accesses apart
            last = c
            o.write("%d %d %s\n" % (c, KIND[k], v))
            n += 1
    print("%d events" % n)
    sys.path.insert(0, str(REPO / "scripts"))
    import check_gx_obj
    r = subprocess.run([check_gx_obj.GIT_BASH, "scripts/run_verilator.sh", "gx_tms57002_tb",
                        "+EVENTS=" + str(out.relative_to(REPO)).replace("\\", "/"), "+LAT=%d" % a.lat], cwd=REPO)
    sys.exit(r.returncode)


def lock(a):
    sys.path.insert(0, str(REPO / "scripts"))
    import check_gx_obj
    import tms57002
    ev = tms57002.read_log(a.log)
    t0 = ev[0][0] - 100
    out = REPO / "obj_verilator" / "tms_lock_events.txt"
    out.parent.mkdir(exist_ok=True)
    with open(out, "w") as o:
        for n, k, v in tms57002.lockstep_events(ev, t0):
            if k != "S":
                o.write("%d %d %02x\n" % (n, KIND[k], v))
    rel = lambda p: str(Path(p).resolve().relative_to(REPO)).replace("\\", "/")
    args = ["+EVENTS=" + rel(out), "+LOCK=" + rel(a.lock), "+LAT=%d" % a.lat]
    if a.samples:
        args.append("+SAMPLES=%d" % a.samples)
    r = subprocess.run([check_gx_obj.GIT_BASH, "scripts/run_verilator.sh", "gx_tms57002_tb"] + args, cwd=REPO)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
