#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/esc/k056734.sv against the Python model (scripts/k056734/).

    python scripts/esc_chip_check.py <set> --rom <dump> --bios <dump> --cap <dir> [--cap <dir> ...]

<dump>s are the 68020 space from 0x200000 (2 MB) and from 0 (512 KB), as
MAME's debugger saves them. A capture directory is what
debug/esccrypt/cap.lua writes: index.txt ("<tag> f<frame> data <ptr>") and
w<tag>.bin, the work RAM at each mailbox write. Each packet is replayed: its
work RAM loaded, the mailbox posted, run to the kernel's wait. The model runs
twice, with 4K words of local memory as the RTL has and with 64K, which
checks that nothing the kernel or program uses overlaps under the alias;
then sim/k056734_tb runs the same packets. Work RAM and sprite RAM must
match after every packet. The data goes to obj_verilator/k056734_data
(ROM-derived: not committed).
"""
import argparse, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'scripts' / 'k056734'))
import chip as model                                    # noqa: E402
sys.path.insert(0, str(REPO / 'scripts'))
from check_gx_obj import GIT_BASH                       # noqa: E402
from esccipher import CHIPS                             # noqa: E402

WRAM, SPR = (0xC00000, 0x20000), (0xD20000, 0x4000)


def run_model(setname, rom, bios, packets, alias):
    h = model.Host()
    for i, b in enumerate(bios):
        dict.__setitem__(h, i, b)
    for i, b in enumerate(rom):
        dict.__setitem__(h, 0x200000 + i, b)
    c = model.Chip(setname, h, rom, alias=alias)
    c.run_until_idle()
    out = []
    for w, ptr in packets:
        for i, b in enumerate(w):
            dict.__setitem__(h, WRAM[0] + i, b)
        n = c.post(ptr)
        out.append((n, bytes(h.get(WRAM[0] + i) for i in range(WRAM[1])),
                    bytes(h.get(SPR[0] + i) for i in range(SPR[1]))))
    return out


def hexfile(path, data):
    path.write_text(''.join('%02x\n' % b for b in data))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--rom', required=True)
    ap.add_argument('--bios', required=True)
    ap.add_argument('--cap', action='append', required=True)
    ap.add_argument('--ss-at', type=int, help='a save state round trip after this packet')
    a = ap.parse_args()
    rom = Path(a.rom).read_bytes()[:0x200000]
    bios = Path(a.bios).read_bytes()[:0x80000]
    packets = []
    for d in a.cap:
        for line in (Path(d) / 'index.txt').read_text().split('\n'):
            if line.strip():
                tag, _, _, ptr = line.split()
                packets.append(((Path(d) / ('w%s.bin' % tag)).read_bytes(), int(ptr, 16)))

    s10, nib, xor, lanes, _ = CHIPS[a.set]
    lane64 = sum(l << (4 * k) for k, l in enumerate(lanes))
    data = REPO / 'obj_verilator' / 'k056734_data'
    data.mkdir(parents=True, exist_ok=True)
    hexfile(data / 'bios.hex', bios)
    hexfile(data / 'rom.hex', rom)
    (data / 'cfg.hex').write_text('%08x\n%08x\n%08x\n%08x\n%08x\n' % (s10, nib, xor, lane64 >> 32, lane64 & 0xFFFFFFFF))
    lines = []
    for n, (w, ptr) in enumerate(packets):
        hexfile(data / ('in_%d.hex' % n), w)
        lines.append('in_%d.hex %06x' % (n, ptr))
    (data / 'packets.txt').write_text('\n'.join(lines) + '\n')

    m4k = run_model(a.set, rom, bios, packets, True)
    m64k = run_model(a.set, rom, bios, packets, False)
    fails = 0
    for n, (x, y) in enumerate(zip(m4k, m64k)):
        if x != y:
            print('packet %d: the 4K and 64K models differ' % n)
            fails += 1

    r = subprocess.run([GIT_BASH, 'scripts/run_verilator.sh', 'k056734_tb', '+DATA=' + data.as_posix()] + (['+SS_AT=%d' % a.ss_at] if a.ss_at is not None else []),
                       cwd=REPO, capture_output=True, text=True)
    log = r.stdout + r.stderr
    print('\n'.join(l for l in log.splitlines() if l.startswith(('packet', 'kernel', 'idle', 'TIMEOUT', 'write', 'K056734', '%Error', 'state'))))
    if 'K056734_DONE' not in log:
        print(log[-3000:])
        sys.exit(1)
    for n, (steps, w, s) in enumerate(m4k):
        rw = bytes(int(x, 16) for x in (data / ('out_%d_w.hex' % n)).read_text().split())
        rs = bytes(int(x, 16) for x in (data / ('out_%d_s.hex' % n)).read_text().split())
        dw = [i for i in range(len(w)) if w[i] != rw[i]]
        ds = [i for i in range(len(s)) if s[i] != rs[i]]
        ok = not dw and not ds
        fails += not ok
        print('packet %2d: model %7d steps  work RAM %s  sprite RAM %s' % (
            n, steps, 'ok' if not dw else '%d bytes differ from %06x' % (len(dw), WRAM[0] + dw[0]),
            'ok' if not ds else '%d bytes differ from %06x' % (len(ds), SPR[0] + ds[0])))
    print('ALL PASS' if not fails else '%d FAILED' % fails)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
