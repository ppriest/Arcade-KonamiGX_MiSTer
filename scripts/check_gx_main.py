#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The RTL main board (rtl/gx_main.sv) against MAME.

    python scripts/mame_sys_trace.py daiskiss 400     # MAME's reference
    python scripts/check_gx_main.py daiskiss 400      # run and compare

Runs sim/gx_main_tb for N frames -- on Verilator by default, TG68K.C coming in
as GHDL's Verilog conversion (scripts/tg68k_verilog.sh); --sim modelsim runs
the VHDL itself -- and compares
its trace with MAME's (scripts/mame/systrace.lua): the writes, as 16-bit
accesses, one ordered stream per interrupt mask level (writes_of says why).
Reports each stream's first write that differs. --shot N also compares the
RTL's picture with MAME's capture of frame N.

The K056800 replies the bench gives the CPU are MAME's own, extracted from
MAME's trace in order (debug/<set>-main_tb/snd.hex).
"""
import argparse
import shutil
import subprocess
import sys

import numpy as np
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm          # noqa: E402
import check_gx_obj                # noqa: E402
import check_gx_tilemap            # noqa: E402

REPO = rm.REPO
OUT = REPO / "debug" / "gx_main_tb"
# Snapshots (--save-at, --from): a saved simulation and its trace to that
# frame. A snapshot holds the ROM images and MAME's sound replies as they
# were when it was saved: remake it after either changes.
SNAP = OUT / "snap"
# The sound replies by time from the game's start (RTL frame 740, before its
# first main-program write at 748), MAME being 31 frames behind from there
# (the title: RTL 1169 = MAME 1200). Before that, in order.
SND_TIME_FROM, SND_OFFSET = 740, 31


STACK = (0xc1f000, 0xc1f800)    # below the ISP the game sets (0xC1F800)


def writes_of(path, last_frame=None):
    """The writes as 16-bit accesses (addr, mask, data, frame), one ordered
    stream per interrupt mask level (the trace's last column). MAME logs a
    32-bit access as one entry; it is split here.

    Why streams: where an interrupt lands in the main program's writes
    depends on each CPU's speed, so one merged order cannot match. Each
    level's own order is deterministic.

    Left out: the supervisor stack (STACK). It holds interrupt frames and
    the registers handlers save, whose values are wherever the interrupted
    code was -- timing again. What was saved shows up later in what is
    restored and written elsewhere."""
    streams, fr = {}, 0
    for ln in open(path):
        if ln.startswith("# frame"):
            fr = int(ln.split()[2])
            if last_frame is not None and fr > last_frame:
                break
            continue
        if ln.startswith("#"):
            continue
        f = ln.rstrip("\n").split("\t")
        if len(f) < 5 or f[1] != "w":     # < 5: a run still writing its last line
            continue
        a, m, d = int(f[2], 16), int(f[3], 16), int(f[4], 16)
        ipl = int(f[5]) if len(f) > 5 else 0
        for half in (0, 1):
            mm = (m >> (16 * (1 - half))) & 0xffff
            aa = a + 2 * half
            if mm and not STACK[0] <= aa < STACK[1]:
                streams.setdefault(ipl, []).append((aa, mm, (d >> (16 * (1 - half))) & 0xffff & mm, fr))
    # Work RAM is only observable through its contents, and MAME's 68020 and
    # TG68K split long and MOVEM writes into words in different orders
    # (-(An): low word first in MAME). So each stretch of work-RAM writes
    # between two writes elsewhere is compared sorted by address -- stable,
    # so writes to one address keep their order. Everything else stays in
    # strict order.
    for out in streams.values():
        i = 0
        while i < len(out):
            j = i
            while j < len(out) and 0xc00000 <= out[j][0] < 0xc20000:
                j += 1
            if j - i > 1:
                out[i:j] = sorted(out[i:j], key=lambda w: w[0])
            i = max(j, i + 1)
    return streams


def compare_shots(game, n, near, out):
    """Score the recorded RTL frames nearest `near` against MAME's screenshot
    of frame n; report the best."""
    caps = [d for d in REPO.glob(f"debug/{game}-*") if (d / "manifest.txt").exists()
            and rm.Capture(d).manifest.get("frame") == str(n)]
    if not caps:
        print(f"MAME frame {n}: no capture of that frame in debug/")
        return
    ref = rm.Capture(caps[0]).reference()
    best = None
    # shot_<frame>.hex; shot_frames.hex is the bench's input, not a picture
    pics = [f for f in out.glob("shot_*.hex") if f.stem[5:].isdigit()]
    for f in sorted(pics, key=lambda p: abs(int(p.stem[5:]) - near)):
        px = np.array([int(v, 16) for v in f.read_text().split()], dtype=np.int64)
        if len(px) != rm.VIS_W * rm.VIS_H:
            continue
        got = np.stack([px >> 16 & 0xff, px >> 8 & 0xff, px & 0xff], axis=-1)
        got = got.reshape(rm.VIS_H, rm.VIS_W, 3).astype(np.uint8)
        same = int(np.all(got == ref, axis=-1).sum())
        if best is None or same > best[0]:
            best = (same, int(f.stem[5:]), got)
        if same == got.shape[0] * got.shape[1]:
            break
    if best is None:
        print(f"MAME frame {n}: no RTL frame recorded near {near}")
        return
    print(f"MAME frame {n} (RTL frame ~{near}): best RTL frame {best[1]}, "
          f"{best[0]} of {rm.VIS_W * rm.VIS_H} pixels identical")
    np.save(out / f"shot_best_f{n}.npy", best[2])


# rtl/gx_board_cfg.sv's per-set values the bench needs: the ESC's list and the
# K055673's x offset less daiskiss's -26 (konamigx.cpp's machine configs).
ESC = {"daiskiss": (1, 0xc00000, 0x100), "mtwinbee": (1, 0xc00000, 0x100),
       "tbyahhoo": (1, 0xc00000, 0x100), "sexyparo": (1, 0xc00604, 0xfc),
       "sexyparoa": (1, 0xc00604, 0xfc)}
HADJ = {"crzcross": -20, "puzldama": -20, "fantjour": -20, "fantjoura": -20,
        "gokuparo": -20, "sexyparo": -16, "sexyparoa": -16}


def board_cfg(game):
    gen, src, count = ESC.get(game, (0, 0xc00000, 0x100))
    return [f"+ESC_GEN={gen}", f"+ESC_SRC={src:x}", f"+ESC_COUNT={count:x}",
            f"+OBJ_HADJ={HADJ.get(game, 0) & 0x3ff}"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames", type=int)
    ap.add_argument("--no-sim", action="store_true")
    ap.add_argument("--sim", choices=("verilator", "modelsim"), default="verilator")
    ap.add_argument("--shot", type=int, action="append", default=[],
                    help="MAME frame with a capture in debug/ to compare the picture with")
    ap.add_argument("--out", default=str(OUT.relative_to(REPO)),
                    help="this run's trace and pictures (two runs at once need two)")
    ap.add_argument("--threads", type=int, default=1,
                    help="Verilator threads; 4 ran 5x slower than 1 on this bench (a clock edge per eval)")
    ap.add_argument("--save-at", type=int, metavar="FRAME",
                    help="save the simulation at RTL frame FRAME to SNAP/boot_FRAME, then stop")
    ap.add_argument("--from", dest="start", type=int, metavar="FRAME",
                    help="start from SNAP/boot_FRAME instead of reset")
    ap.add_argument("--rom-wait", type=int, default=10,
                    help="the bench ROM's clocks per miss (+ROM_WAIT); odd values catch clock-phase faults")
    a = ap.parse_args()
    mame = REPO / "debug" / f"{a.game}-sys" / f"{a.game}_sys.trace"
    out = REPO / a.out
    rtl = out / f"{a.game}_rtl_sys.trace"
    snap = SNAP / f"boot_{a.save_at if a.save_at is not None else a.start}"
    if (a.save_at is not None or a.start is not None) and a.sim != "verilator":
        print("--save-at and --from need Verilator (sim/gx_main_tb/main.cpp)")
        return 1
    # MAME's trace as far as this run can reach (it may run thousands of
    # frames further), and at least to the frames to picture
    M = writes_of(mame, max([a.frames + SND_OFFSET + 50] + a.shot))
    M0 = M.get(0, [])
    # RTL frames to record: around the frame where the RTL reaches the first
    # write of MAME's frame N in the main program's stream, from the previous
    # run's trace if it got that far; otherwise N less the after-boot offset.
    shots, margin = {}, 3
    R0 = writes_of(rtl).get(0, []) if a.shot and rtl.exists() else []
    for n in a.shot:
        k = next((i for i, w in enumerate(M0) if w[3] >= n), len(M0))
        shots[n] = R0[k][3] if k < len(R0) else n - SND_OFFSET

    if not a.no_sim:
        OUT.mkdir(parents=True, exist_ok=True)
        out.mkdir(parents=True, exist_ok=True)
        SNAP.mkdir(parents=True, exist_ok=True)
        for f in out.glob("shot_*.hex"):
            f.unlink()
        # MAME's K056800 replies, in order
        with open(OUT / "snd.hex", "w") as f:
            mf = 0
            for ln in open(mame):
                if ln.startswith("# frame"):
                    mf = int(ln.split()[2]); continue
                if ln.startswith("#"):
                    continue
                _, rw, ad, m, d = ln.rstrip("\n").split("\t")[:5]
                ad, m, d = int(ad, 16), int(m, 16), int(d, 16)
                if rw == "r" and 0xd52000 <= ad < 0xd52020:
                    for lane in range(4):
                        if (m >> (8 * (3 - lane))) & 0xff and lane % 2 == 0:
                            f.write(f"{(ad - 0xd52000 + lane) // 2:x} {(d >> (8 * (3 - lane))) & 0xff:02x} {mf}\n")
        cap = rm.Capture(REPO / "debug" / "daiskiss-f6000")
        tn = check_gx_tilemap.write_vectors(cap)
        on = check_gx_obj.write_vectors(cap)
        args = [f"+FRAMES={a.frames}", f"+TNTILES={tn}", f"+ONTILES={on}", f"+OUT={a.out}/", f"+ROM_WAIT={a.rom_wait}",
                f"+SND_TIME_FROM={SND_TIME_FROM}", f"+SND_OFFSET={SND_OFFSET}",
                f"+SET={a.game}"] + board_cfg(a.game)
        # the frames to record, one window per --shot
        (out / "shot_frames.hex").write_text("".join(
            f"{f:x}\n" for n in shots for f in range(shots[n] - margin, shots[n] + margin + 1) if f > 0))
        if a.save_at is not None:
            args += [f"+SAVE={snap.relative_to(REPO)}.vlsave", f"+SAVE_AT={a.save_at}"]
        if a.start is not None:
            # the snapshot's trace up to its frame, which the run appends to
            shutil.copyfile(f"{snap}.trace", rtl)
            args += [f"+RESTORE={snap.relative_to(REPO)}.vlsave"]
        if a.sim == "verilator":
            cmd = ["scripts/run_verilator.sh", "gx_main_tb", f"--threads={a.threads}"] + args
        else:
            cmd = ["scripts/run_sim.sh", "gx_main_tb"] + args
        r = subprocess.run([check_gx_obj.GIT_BASH] + cmd, cwd=REPO, capture_output=True, text=True)
        log = r.stdout + r.stderr
        (out / "sim.log").write_text(log)
        if a.save_at is not None:
            if "SAVED" not in log:
                print(log[-4000:])
                return 1
            shutil.copyfile(rtl, f"{snap}.trace")
            print(f"saved {snap.relative_to(REPO)}.vlsave and .trace at RTL frame {a.save_at}")
        elif "GX_MAIN_DONE" not in log:
            print(log[-4000:])
            return 1

    # Frame markers do not line up between MAME and the RTL (the two CPUs
    # take different numbers of cycles for the same code), so each stream is
    # compared in order and its first divergence reported with the frame it
    # falls in on each side.
    R = writes_of(rtl)
    for n in a.shot:
        compare_shots(a.game, n, shots[n], out)
    bad = 0
    for ipl in sorted(set(M) | set(R)):
        m, r = M.get(ipl, []), R.get(ipl, [])
        n = 0
        while n < min(len(m), len(r)) and m[n][:3] == r[n][:3]:
            n += 1
        print(f"IPL {ipl}: MAME {len(m)} writes, RTL {len(r)}: the first {n} identical, in order")
        if n < min(len(m), len(r)):
            bad = 1
            print(f"  first difference: write {n}, MAME frame {m[n][3]}, RTL frame {r[n][3]}")
            for k in range(max(0, n - 3), min(n + 5, len(m))):
                print("  MAME %8d  %06X %04X %04X  f%d" % ((k,) + m[k]))
            for k in range(max(0, n - 3), min(n + 5, len(r))):
                print("  RTL  %8d  %06X %04X %04X  f%d" % ((k,) + r[k]))
    return bad


if __name__ == "__main__":
    sys.exit(main())
