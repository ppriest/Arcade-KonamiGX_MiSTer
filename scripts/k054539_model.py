#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's K054539 voices (k054539.cpp), replayed against the bench's +AUDIO log.

    python scripts/k054539_model.py debug/aud/rtl_tbyahhoo.txt --game tbyahhoo

The bench (sim/gx_main_tb, +AUDIO=file) writes every write to either chip
("W chip reg data"), every read of its 0x22d port ("R chip 22d") and, once a sample, both chips' outputs ("S l0 r0 l1 r1
L R", 8 bits of fraction). Here the writes are applied to a port of MAME's
write() and sound_stream_update() -- in doubles, as MAME -- and each chip's
sample is compared with the RTL's. The RTL starts a sample on the clock
after an S line and reads the registers as it goes, so a write that lands
while it is working can be seen by the RTL a sample before the model: a few
such differences are expected, a run of them is not.

The reverb is in, and the RAM it uses with it: the CPU's writes through
0x22d land there as in MAME.
"""
import argparse
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

DPCM = [0, 1, 2, 4, 8, 16, 32, 64, 0, -64, -32, -16, -8, -4, -2, -1]
VOLTAB = [10.0 ** (-36.0 * i / 0x40 / 20.0) / 4.0 for i in range(256)]
PANTAB = [(i ** 0.5) / (14 ** 0.5) for i in range(15)]


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


class Chip:
    def __init__(self, rom, reverb=True):
        self.rom = rom
        self.reverb = reverb
        self.mask = len(rom) - 1           # a power of two: MAME mirrors over it
        self.regs = bytearray(0x800)
        self.latch = [[0, 0, 0] for _ in range(8)]
        self.ch = [dict(pos=0, pfrac=0, val=0, pval=0) for _ in range(8)]
        self.ram = bytearray(0x8000)
        self.rom_addr = self.cur_ptr = self.reverb_pos = 0

    def ram_addr(self):
        return (self.cur_ptr & 0x3fff) | ((self.cur_ptr & 0x10000) >> 2)

    def rw(self, i):                        # rbase[i], int16
        return s16(self.ram[2 * i] | self.ram[2 * i + 1] << 8)

    def ww(self, i, v):
        self.ram[2 * i] = v & 0xff
        self.ram[2 * i + 1] = v >> 8 & 0xff

    def read(self, off):
        if off == 0x22d and self.regs[0x22f] & 0x10:
            self.cur_ptr = (self.cur_ptr + 1) & 0x1ffff

    def rb(self, a):
        return self.rom[a & self.mask]

    def regupdate(self):
        return not self.regs[0x22f] & 0x80

    def keyon(self, c):
        if self.regupdate():
            self.regs[0x22c] |= 1 << c

    def keyoff(self, c):
        if self.regupdate():
            self.regs[0x22c] &= ~(1 << c) & 0xff

    def write(self, off, data):
        latch = bool(self.regs[0x22f] & 1)
        if latch and off < 0x100:
            offs = (off & 0x1f) - 0xc
            if 0 <= offs <= 2:
                self.latch[off >> 5][offs] = data
                return
        elif off == 0x214:
            for c in range(8):
                if data & (1 << c):
                    if latch:
                        self.regs[(c << 5) + 0xc:(c << 5) + 0xf] = bytes(self.latch[c])
                    self.keyon(c)
        elif off == 0x215:
            for c in range(8):
                if data & (1 << c):
                    self.keyoff(c)
        elif off == 0x22d:
            if self.rom_addr == 0x80:
                self.ram[self.ram_addr()] = data
            self.cur_ptr = (self.cur_ptr + 1) & 0x1ffff
        elif off == 0x22e:
            self.rom_addr = data
            self.cur_ptr = 0
        self.regs[off] = data

    def sample(self):
        r = self.regs
        if not r[0x22f] & 1:
            return 0.0, 0.0
        lval = rval = float(self.rw(self.reverb_pos)) if self.reverb else 0.0
        self.ww(self.reverb_pos, 0)
        for c in range(8):
            if not (r[0x22c] >> c) & 1:
                continue
            b1 = 0x20 * c
            b2 = 0x200 + 2 * c
            ch = self.ch[c]
            delta = r[b1] | r[b1 + 1] << 8 | r[b1 + 2] << 16
            vol = r[b1 + 3]
            bval = min(vol + r[b1 + 4], 255)
            pan = r[b1 + 5]
            if 0x81 <= pan <= 0x8f:
                pan -= 0x81
            elif 0x11 <= pan <= 0x1f:
                pan -= 0x11
            else:
                pan = 0x18 - 0x11
            lvol = min(VOLTAB[vol] * PANTAB[pan], 1.8)
            rvol = min(VOLTAB[vol] * PANTAB[0xe - pan], 1.8)
            rbvol = min(VOLTAB[bval] / 2, 1.8)
            rdelta = ((r[b1 + 6] | r[b1 + 7] << 8) >> 3)
            rdelta = (rdelta + self.reverb_pos) & 0x3fff
            cur_pos = r[b1 + 0xc] | r[b1 + 0xd] << 8 | r[b1 + 0xe] << 16
            if r[b2] & 0x20:
                delta, fdelta, pdelta = -delta, 0x10000, -1
            else:
                fdelta, pdelta = -0x10000, 1
            if cur_pos != ch["pos"]:
                ch["pos"] = cur_pos
                pfrac = val = pval = 0
            else:
                pfrac, val, pval = ch["pfrac"], ch["val"], ch["pval"]
            loop = r[b1 + 8] | r[b1 + 9] << 8 | r[b1 + 10] << 16
            lp = r[b2 + 1] & 1
            typ = r[b2] & 0xc
            if typ == 0x0:
                pfrac += delta
                while pfrac & ~0xffff:
                    pfrac += fdelta
                    cur_pos += pdelta
                    pval = val
                    val = s16(self.rb(cur_pos) << 8)
                    if val == -0x8000 and lp:
                        cur_pos = loop
                        val = s16(self.rb(cur_pos) << 8)
                    if val == -0x8000:
                        self.keyoff(c)
                        val = 0
                        break
            elif typ == 0x4:
                pdelta <<= 1
                pfrac += delta
                while pfrac & ~0xffff:
                    pfrac += fdelta
                    cur_pos += pdelta
                    pval = val
                    val = s16(self.rb(cur_pos) | self.rb(cur_pos + 1) << 8)
                    if val == -0x8000 and lp:
                        cur_pos = loop
                        val = s16(self.rb(cur_pos) | self.rb(cur_pos + 1) << 8)
                    if val == -0x8000:
                        self.keyoff(c)
                        val = 0
                        break
            elif typ == 0x8:
                cur_pos <<= 1
                pfrac <<= 1
                if pfrac & 0x10000:
                    pfrac &= 0xffff
                    cur_pos |= 1
                pfrac += delta
                while pfrac & ~0xffff:
                    pfrac += fdelta
                    cur_pos += pdelta
                    pval = val
                    val = self.rb(cur_pos >> 1)
                    if val == 0x88 and lp:
                        cur_pos = loop << 1
                        val = self.rb(cur_pos >> 1)
                    if val == 0x88:
                        self.keyoff(c)
                        val = 0
                        break
                    val = val >> 4 if cur_pos & 1 else val & 15
                    val = max(-32768, min(32767, pval + DPCM[val] * 0x100))
                pfrac >>= 1
                if cur_pos & 1:
                    pfrac |= 0x8000
                cur_pos >>= 1
            lval += val * lvol
            rval += val * rvol
            ri = (rdelta + self.reverb_pos) & 0x1fff
            self.ww(ri, self.rw(ri) + s16(int(val * rbvol)))
            ch.update(pos=cur_pos, pfrac=pfrac, pval=pval, val=val)
            if self.regupdate():
                r[b1 + 0xc] = cur_pos & 0xff
                r[b1 + 0xd] = cur_pos >> 8 & 0xff
                r[b1 + 0xe] = cur_pos >> 16 & 0xff
        self.reverb_pos = (self.reverb_pos + 1) & 0x1fff
        return lval, rval


def load_pcm(game):
    """The "k054539" region, as the bench loads it (scripts/check_gx_main.py)."""
    import build_rom_image as bri
    return bytes(bri.build(game, "k054539"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--rom", help="the k054539 region as a file (default: from the game's zip)")
    ap.add_argument("--game")
    ap.add_argument("--no-reverb", action="store_true", help="for an RTL without it")
    ap.add_argument("--tol", type=float, default=0.1, help="in the chips' 16-bit units")
    a = ap.parse_args()
    if a.rom:
        rom = Path(a.rom).read_bytes()
    else:
        rom = load_pcm(a.game)
    chips = [Chip(rom, not a.no_reverb), Chip(rom, not a.no_reverb)]
    pend = None
    n = bad = heard = 0
    first_bad = []
    for line in open(a.log):
        f = line.split()
        if f[0] == "W":
            chips[int(f[1])].write(int(f[2], 16), int(f[3], 16))
        elif f[0] == "R":
            chips[int(f[1])].read(int(f[2], 16))
        elif f[0] == "S":
            got = [int(v) / 256.0 for v in f[1:5]]
            if pend is not None:
                n += 1
                if any(abs(g) > 1 for g in got):
                    heard += 1
                if any(abs(g - p) > a.tol for g, p in zip(got, pend)):
                    bad += 1
                    if len(first_bad) < 10:
                        first_bad.append((n, got, pend))
            pend = [v for c in chips for v in c.sample()]
    print(f"{n} samples, {heard} with sound, {bad} differing by more than {a.tol}")
    for k, g, p in first_bad:
        print(f"  sample {k}: rtl " + " ".join(f"{v:9.2f}" for v in g) + "  mame " + " ".join(f"{v:9.2f}" for v in p))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
