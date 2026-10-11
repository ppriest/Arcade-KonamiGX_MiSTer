#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""gx_t1_psac4 (sim/gx_t1_psac4_tb) against scripts/t1_psac4_model.py.

    python scripts/check_t1_psac4.py debug/racinfrc-t1dump f03600 [f04200 ...]

For each vblank dumped by scripts/mame/t1_dump.lua: the state as the bench
reads it (SDRAM granules for the map RAM, CROM and HROM; the CPU RAMs; the
registers), one bench run, and the drawn buffer compared with the model, pen
and priority per pixel; then what the display path gave for that buffer.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t1_psac4_model as m          # noqa: E402
from check_gx_obj import GIT_BASH  # noqa: E402

REPO = m.REPO


def hexfile(path, values, width):
    path.write_text("".join(f"{int(v):0{width}x}\n" for v in values))


def write_state(st, out, crom, hrom):
    out.mkdir(parents=True, exist_ok=True)
    # the map RAM as the CPU wrote it: each long big-endian, granule byte 0 at [7:0]
    ram = st["psacram"].astype(np.uint64)
    g = []
    for i in range(0x4000):
        b = int(ram[2 * i]).to_bytes(4, "big") + int(ram[2 * i + 1]).to_bytes(4, "big")
        g.append(int.from_bytes(b, "little"))
    hexfile(out / "map.hex", g, 16)
    for name, rom in (("crom", crom), ("hrom", hrom)):
        a = np.frombuffer(rom, dtype="<u8")
        (out / f"{name}.hex").write_text("".join(f"{int(v):016x}\n" for v in a))
    hexfile(out / "lc.hex", st["linectl"], 4)
    lr = []
    for v in st["lram"]:
        lr += [int(v) >> 16, int(v) & 0xffff]
    hexfile(out / "lr.hex", lr, 4)
    hexfile(out / "lk.hex", st["lookup"], 2)
    k = [int(v) for v in st["k936"]]
    p4 = (st["yorigin"] or 0) << 8               # register 0's bits 23-8
    p4b = (st["yorigin1"] or 0) << 8             # golf's second origin
    hexfile(out / "regs.hex", [k[0], k[1], k[6], k[7], p4 >> 16, p4 & 0xffff, st["bank"], k[14],
                               int(st["golf"]), p4b >> 16, p4b & 0xffff], 4)


def main():
    dump, tags = sys.argv[1], sys.argv[2:]
    import contextlib, io
    import build_rom_image as bri
    # the set's ROMs: the dump's meta says whether it is a golf set
    golf = m.load(dump, tags[0])["golf"]
    set_name = "opengolf" if golf else "racinfrc"
    with contextlib.redirect_stdout(io.StringIO()):
        crom, hrom = bri.build(set_name, "gfx3"), bri.build(set_name, "gfx4")
    tc, th = (m.decode8 if golf else m.decode6)(crom), m.decode6(hrom)
    bad = 0
    for tag in tags:
        st = m.load(dump, tag)
        out = REPO / "debug" / "gx_t1_psac4_tb" / tag
        write_state(st, out, crom, hrom)
        r = subprocess.run([GIT_BASH, "scripts/run_verilator.sh", "gx_t1_psac4_tb", f"+DIR={out.relative_to(REPO).as_posix()}"],
                           cwd=REPO, capture_output=True, text=True)
        log = r.stdout + r.stderr
        (out / "sim.log").write_text(log)
        if "T1_PSAC4_DONE" not in log:
            print(log[-3000:])
            return 1
        print(f"{tag}: " + next(l for l in log.splitlines() if "drawn" in l))
        y0, vh = m.window(st)
        v = [int(x, 16) for x in (out / "out.hex").read_text().split()]
        store = np.array(v[:vh * m.VIS_W], dtype=np.int64).reshape(vh, m.VIS_W)
        ltab = np.array(v[vh * m.VIS_W:], dtype=np.int64)
        par_s, c = store >> 8, store & 0xff
        on = store != 0
        rpen = np.where(on, c | ((ltab[par_s] & 0xf) << 8), 0xffff)
        rpar = np.where(on, par_s, 0)
        pen, par = m.render(st, tc, th)
        mpen = pen[y0:y0 + vh, m.VIS_X0:m.VIS_X0 + m.VIS_W].astype(np.int64)
        mpar = par[y0:y0 + vh, m.VIS_X0:m.VIS_X0 + m.VIS_W].astype(np.int64)
        mon = mpen != 0xffff
        diff = (on != mon) | (on & ((rpen != mpen) | (rpar != mpar)))
        n = int(diff.sum())
        print(f"  drawn: {int(on.sum())} pixels, model {int(mon.sum())}; {n} differ")
        if n:
            bad = 1
            ys, xs = np.nonzero(diff)
            for y, x in list(zip(ys, xs))[:8]:
                print(f"    ({y},{x}): rtl {'%03x/%02x' % (rpen[y, x], rpar[y, x]) if on[y, x] else '-'}"
                      f"  model {'%03x/%02x' % (mpen[y, x], mpar[y, x]) if mon[y, x] else '-'}")
        # the display path
        rows = [l.split() for l in (out / "shown.hex").read_text().splitlines()]
        sv = np.array([[int(a, 16), int(b, 16), int(cc, 16)] for a, b, cc in rows], dtype=np.int64)
        if len(sv) != vh * m.VIS_W:
            print(f"  shown: {len(sv)} pixels, not {vh * m.VIS_W}")
            bad = 1
            continue
        sv = sv.reshape(vh, m.VIS_W, 3)
        sd = (sv[..., 0] != on) | (on & ((sv[..., 1] != rpen) | (sv[..., 2] != rpar)))
        print(f"  shown: {int(sd.sum())} pixels differ from the drawn buffer")
        bad |= int(sd.sum()) != 0
    return bad


if __name__ == "__main__":
    sys.exit(main())
