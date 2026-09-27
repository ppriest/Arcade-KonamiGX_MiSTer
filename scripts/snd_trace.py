#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The sound 68000's bus trace, from the board or from MAME.

    python scripts/snd_trace.py fetch  debug/snd_board.txt      # the board's ring
    python scripts/snd_trace.py mame   crzcross debug/snd_mame.txt [--seconds S]
    python scripts/snd_trace.py tail   debug/snd_board.txt [-n 40]

fetch: with the OSD's "Sound trace" On and the sound board 68000, the core
writes every sound-CPU bus cycle into DDR3 (rtl/gx_trace.sv); this reads
the ring through python3 and mmap on the MiSTer (read() of /dev/mem
refuses core memory), copies it back and decodes it, one cycle a line:

    <clk> <fc> <R|W> <uds><lds> <irq2><irq1> <addr> <data>

clk is the 48 MHz count, 16 bits, so a gap is (clk - last) mod 65536 and
anything over 1.3 ms is ambiguous. /UDS and /LDS are active low: 01 is a
byte on the upper lane. The bench writes the same lines (+SND_TRACE).

mame: scripts/mame/sndtrace.lua's log, <us> <R|W> <addr> <mask> <data>.
"""
import argparse
import os
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

BASE = 0x34000000
RING = 1 << 23

REMOTE_PY = r'''
import mmap, struct, sys
f = open("/dev/mem", "r+b")
h = mmap.mmap(f.fileno(), 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=%(base)#x)
magic, dropped, written = struct.unpack("<HHI", h[6:8] + h[4:6] + h[0:4])
h.close()
if magic != 0xC0DE:
    print("no trace header (magic %%04x)" %% magic); sys.exit(1)
n = min(written, %(ring)d)
first = written - n
out = open("/tmp/snd_trace.bin", "wb")
out.write(struct.pack("<IIH", written, n, dropped))
# the ring in two pieces where it wraps; 1 MB at a time
r = mmap.mmap(f.fileno(), %(ring)d * 8, mmap.MAP_SHARED, mmap.PROT_READ, offset=%(base)#x + 0x1000)
i = first
while i < written:
    s = i %% %(ring)d
    k = min(written - i, %(ring)d - s, 1 << 17)
    out.write(r[s * 8:(s + k) * 8])
    i += k
out.close()
print("written %%d dropped %%d, %%d records copied" %% (written, dropped, n))
'''


def decode(rec):
    ts = rec >> 48
    fc = (rec >> 45) & 7
    rw = "R" if (rec >> 44) & 1 else "W"
    uds, lds = (rec >> 43) & 1, (rec >> 42) & 1
    i2, i1 = (rec >> 41) & 1, (rec >> 40) & 1
    addr = (rec >> 16) & 0xffffff
    data = rec & 0xffff
    return "%d %d %s %d%d %d%d %06x %04x" % (ts, fc, rw, uds, lds, i2, i1, addr, data)


def cmd_fetch(a):
    import deploy
    m = deploy.Mister(deploy.load_env(REPO / "mister.env"), False)
    tmp = REPO / "obj_verilator" / "snd_trace_remote.py"
    tmp.parent.mkdir(exist_ok=True)
    tmp.write_text(REMOTE_PY % dict(base=BASE, ring=RING))
    m.put(tmp, "/tmp/snd_trace_remote.py")
    print(m.run("python3 /tmp/snd_trace_remote.py"), end="")
    local = REPO / "obj_verilator" / "snd_trace.bin"
    p = subprocess.run([m.pscp, "-batch", "-pw", m.pw, f"{m.user}@{m.host}:/tmp/snd_trace.bin", str(local)],
                       capture_output=True, text=True, timeout=600)
    if p.returncode:
        sys.exit(p.stderr)
    b = local.read_bytes()
    written, n, dropped = struct.unpack("<IIH", b[:10])
    recs = struct.unpack("<%dQ" % n, b[10:10 + 8 * n])
    with open(a.out, "w") as o:
        o.write("# %d records written, %d here (from %d), %d dropped\n" % (written, n, written - n, dropped))
        for r in recs:
            o.write(decode(r) + "\n")
    print("%s: %d lines" % (a.out, n))


def cmd_mame(a):
    import dasp_survey
    env = dasp_survey.load_env(REPO / "mister.env")
    mame_dir = Path(env["MAME_DIR"])
    out = Path(a.out).resolve()
    e = dict(os.environ, GX_OUT=str(out).replace("\\", "/"), GX_SECONDS=str(a.seconds))
    p = subprocess.run([str(mame_dir / env["MAME_EXE"]), a.set, "-nodebug", "-nowindow", "-video", "none",
                        "-sound", "none", "-skip_gameinfo", "-nothrottle",
                        "-seconds_to_run", str(a.seconds + 10),
                        "-autoboot_script", str(REPO / "scripts" / "mame" / "sndtrace.lua"),
                        "-rompath", str(REPO / "roms")],
                       cwd=mame_dir, env=e, capture_output=True, text=True)
    tail = [l for l in (p.stdout + p.stderr).splitlines() if "SNDTRACE" in l]
    print("\n".join(tail) or (p.stdout + p.stderr)[-2000:])


def cmd_tail(a):
    lines = Path(a.file).read_text().splitlines()
    print("\n".join(lines[-a.n:]))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fetch"); p.add_argument("out")
    p = sub.add_parser("mame"); p.add_argument("set"); p.add_argument("out")
    p.add_argument("--seconds", type=int, default=10)
    p = sub.add_parser("tail"); p.add_argument("file"); p.add_argument("-n", type=int, default=40)
    a = ap.parse_args()
    {"fetch": cmd_fetch, "mame": cmd_mame, "tail": cmd_tail}[a.cmd](a)


if __name__ == "__main__":
    main()
