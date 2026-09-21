#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""TMS57002 "DASP" model: MAME's tms57002 (BSD-3-Clause, Olivier Galibert),
interpreted one instruction word at a time instead of through MAME's decode
cache. It is the reference for rtl/sound/gx_tms57002.sv.

    python scripts/tms57002.py dis  debug/dasp_fantjour.txt [session]
    python scripts/tms57002.py run  debug/dasp_fantjour.txt [--until-us N]

The log is scripts/mame/dasp_log.lua's: every sound-CPU access to the host
interface, timestamped. `run` replays the writes and checks each data read
and status read against what MAME returned.

Where this differs from MAME's structure, not its results:
  * MAME applies a "f" instruction's st1 change when it decodes a block as
    well as when it executes it. Executing in order gives the same st1 at
    every instruction.
  * Instructions that tmsinstr.lst lists without a body (zacc, zmac, xor, ...)
    are no-ops in MAME. They are no-ops here too, and counted, so a program
    that uses one is visible.
"""
import argparse
import os
import sys
from pathlib import Path

M64 = (1 << 64) - 1
M32 = 0xffffffff

ST0_INCS, ST0_SIM = 0x1, 0x8
ST0_WORD, ST0_SEL, ST0_M = 0x4000, 0x8000, 0x30000
ST1_AOV, ST1_SFAI, ST1_SFAO, ST1_AOVM = 0x1, 0x2, 0x4, 0x8
ST1_MOVM, ST1_MOV = 0x20, 0x40
ST1_SFMA_SH, ST1_SFMO_SH, ST1_RND_SH, ST1_CRM_SH = 7, 11, 15, 18
ST1_SFMA, ST1_SFMO, ST1_RND, ST1_CRM = 0x180, 0x1800, 0x38000, 0xc0000
ST1_DBP = 0x100000


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


ROUNDING = [0, 1 << 15, 1 << 23, 1 << 17, 1 << 31]
RMASK = [M64, M64 - (1 << 16) + 1, M64 - (1 << 24) + 1, M64 - (1 << 18) + 1,
         M64 - (1 << 32) + 1]
# overflow-detect masks for macc_to_output_N / check_macc_overflow_N
OVM = [0xf800000000000, 0xfe00000000000, 0xff80000000000, None]


# ---- mnemonics, from tmsinstr.lst -----------------------------------------
# MAME source tree, for the mnemonics only (dis)
LST = Path(os.environ.get("MAME_SRC", "E:/mame")) / "src/devices/cpu/tms57002/tmsinstr.lst"


def load_names():
    names = {}
    ins = None
    for line in LST.read_text().splitlines():
        if not line.strip():
            ins = None
        elif line[0] in " \t":
            if ins and ins[1] is None:
                ins[1] = line.strip()
                names[ins[0]] = ins[1]
            elif ins:
                ins[2] = True
                names[ins[0] + ("body",)] = True
        else:
            t = line.split()
            ins = [(t[1], int(t[2], 16)), None, False]
    return names


class DASP:
    def __init__(self, xram_size=0x40000):
        self.pmem = [0] * 256
        self.cmem = [0] * 256
        self.dmem0 = [0] * 256
        self.dmem1 = [0] * 32
        self.xram = bytearray(xram_size)
        self.si = [0] * 4
        self.so = [0] * 4
        self.st0 = self.st1 = 0
        self.pload = self.cload = False
        self.su = 0              # 0 st0, 1 st1, 2 program
        self.cval = False
        self.idle = True
        self.rd = self.wr = self.hostf = self.upd = False
        self.in_reset = False
        self.macc = self.macc_read = self.macc_write = 0
        self.aacc = self.xoa = self.xba = self.xwr = self.xrd = 0
        self.txrd = self.creg = 0
        self.pc = self.ca = self.id = self.ba0 = self.ba1 = 0
        self.rptc = self.rptc_next = self.sa = 0
        self.xm_adr = 0
        self.host = [0] * 4
        self.hidx = 0
        self.update = [0] * 16
        self.uh = self.ut = 0
        self.unimpl = {}
        self.cycles = 0

    # ---- host side -------------------------------------------------------
    def reset(self):
        self.su = 0
        self.rd = self.wr = self.hostf = self.upd = False
        self.idle = True
        self.pc = self.ca = self.hidx = self.id = 0
        self.ba0 = self.ba1 = self.sa = 0
        self.rptc = self.rptc_next = 0
        self.uh = self.ut = 0
        self.st0 &= ~0x3fef
        self.st1 &= ~(ST1_AOV | ST1_SFAI | ST1_SFAO | ST1_AOVM | ST1_MOVM |
                      ST1_MOV | ST1_SFMA | ST1_SFMO | ST1_RND | ST1_CRM |
                      ST1_DBP)
        self.xba = self.xoa = 0

    def pload_w(self, state):
        was = self.pload
        self.pload = not state
        if self.pload and not was:
            self.hidx = self.pc = self.ca = 0
            self.su = 0

    def cload_w(self, state):
        was = self.cload
        self.cload = not state
        if self.cload and not was:
            self.hidx = 0

    def control_w(self, v):
        # konamigx.cpp tms57002_control_word_w
        self.pload_w(v & 4)
        self.cload_w(v & 8)
        # MAME resets a CPU when its reset line is released, not when it is
        # asserted (diexec.cpp): asserting only suspends it
        rst = not (v & 0x10)
        if self.in_reset and not rst:
            self.reset()
        self.in_reset = rst

    def data_w(self, d):
        if not self.pload and not self.cload:
            self.hidx = 0
            self.cval = False
        elif self.pload and not self.cload:
            self.host[self.hidx] = d
            self.hidx += 1
            if self.hidx >= 3:
                val = (self.host[0] << 16) | (self.host[1] << 8) | self.host[2]
                self.hidx = 0
                if self.su == 0:
                    self.st0 = val
                    self.su = 1
                elif self.su == 1:
                    self.st1 = val
                    self.su = 2
                else:
                    self.pmem[self.pc] = val
                    self.pc = (self.pc + 1) & 0xff
        elif self.cload and not self.pload:
            if self.cval:
                self.host[self.hidx] = d
                self.hidx += 1
                if self.hidx >= 4:
                    val = ((self.host[0] << 24) | (self.host[1] << 16) |
                           (self.host[2] << 8) | self.host[3])
                    self.cval = False
                    self.update[self.uh] = val
                    self.uh = (self.uh + 1) & 15
                    self.hidx = 1
            else:
                self.sa = d
                self.hidx = 0
                self.cval = True
        else:
            self.host[self.hidx] = d
            self.hidx += 1
            if self.hidx >= 4:
                val = ((self.host[0] << 24) | (self.host[1] << 16) |
                       (self.host[2] << 8) | self.host[3])
                self.hidx = 0
                self.cmem[self.ca] = val
                self.ca = (self.ca + 1) & 0xff

    def data_r(self):
        if not self.hostf:
            return 0xff
        r = self.host[self.hidx]
        self.hidx += 1
        if self.hidx == 4:
            self.hidx = 0
            self.hostf = False
        return r

    def status(self):
        return ((0 if self.hostf else 4) | (2 if self.pc else 0) |
                (1 if self.uh == self.ut else 0))

    def sync(self):
        if self.pload:
            return
        self.pc = self.ca = self.id = 0
        if not (self.st0 & ST0_INCS):
            self.ba0 = (self.ba0 - 1) & 0xff
            self.ba1 = (self.ba1 + 1) & 0xff
        self.xba = (self.xba - 1) & 0x7ffff
        self.st1 &= ~(ST1_AOV | ST1_MOV)
        self.idle = False

    def running(self):
        return not (self.idle or self.pload or self.in_reset)

    # ---- external memory ---------------------------------------------------
    def xm_init(self):
        adr = (self.xoa + self.xba) & M32
        mask = {0: 0xffff, 0x10000: 0x3ffff, 0x20000: 0xfffff}.get(
            self.st0 & ST0_M, 0)
        adr <<= 2 if self.st0 & ST0_WORD else 1
        if not (self.st0 & ST0_SEL):
            adr <<= 1
        self.xm_adr = adr & mask

    def xm_off(self, adr):
        if self.st0 & ST0_WORD:
            if self.st0 & ST0_SEL:
                off = 16 - ((adr & 3) << 3); return off, off == 0, 0xff
            off = 20 - ((adr & 7) << 2); return off, off == 0, 0xf
        if self.st0 & ST0_SEL:
            off = 16 - ((adr & 1) << 3); return off, off == 8, 0xff
        off = 20 - ((adr & 3) << 2); return off, off == 8, 0xf

    def xm_step(self):
        adr = self.xm_adr
        off, done, m = self.xm_off(adr)
        if self.rd:
            v = self.xram[adr % len(self.xram)] & m
            self.txrd = (self.txrd & ~(m << off)) | (v << off)
            if done and not (self.st0 & ST0_WORD):
                self.txrd &= 0xffff00
            if done:
                self.xrd = self.txrd
                self.rd = False
        else:
            self.xram[adr % len(self.xram)] = (self.xwr >> off) & m
            if done:
                self.wr = False
        self.xm_adr = 0 if done else adr + 1

    # ---- operands ------------------------------------------------------------
    def get_cmem(self, a):
        if self.sa == a and self.uh != self.ut:
            self.upd = True
        if self.upd:
            self.cmem[a] = self.update[self.ut]
            self.ut = (self.ut + 1) & 15
            if self.uh == self.ut:
                self.upd = False
            return self.cmem[a]
        crm = (self.st1 & ST1_CRM) >> ST1_CRM_SH
        v = self.cmem[a]
        if crm == 1:
            return v & 0xffff0000
        if crm == 2:
            return (v << 16) & M32
        return v

    def dref(self, mode, param):
        idx = param if mode == 0 else self.id
        if self.st1 & ST1_DBP:
            return 1, (idx + self.ba1) & 0x1f
        return 0, (idx + self.ba0) & 0xff

    def d24(self, mode, param):
        b, i = self.dref(mode, param)
        return (self.dmem1 if b else self.dmem0)[i]

    def d32(self, mode, param):
        return (self.d24(mode, param) << 8) & M32

    def wd(self, mode, param, v):
        b, i = self.dref(mode, param)
        (self.dmem1 if b else self.dmem0)[i] = v & M32

    def a(self):
        return (self.aacc << 7) & M32 if self.st1 & ST1_SFAO else self.aacc

    def wa(self, r):
        if r < -2147483648 or r > 2147483647:
            self.st1 |= ST1_AOV
            if self.st1 & ST1_AOVM:
                r = max(-2147483648, min(2147483647, r))
        self.aacc = r & M32

    def sfai(self, v):
        return (s32(v) >> 1) & M32 if self.st1 & ST1_SFAI else v

    def ml(self):
        sfma = (self.st1 & ST1_SFMA) >> ST1_SFMA_SH
        return s64([self.macc, self.macc << 2, self.macc << 4,
                    self.macc >> 16][sfma])

    def sat(self, m):
        self.st1 |= ST1_MOV
        if self.st1 & ST1_MOVM:
            return s64(0xffff800000000000) if m & 0x8000000000000 else 0x00007fffffffffff
        return m

    def mo(self):
        sfmo = (self.st1 & ST1_SFMO) >> ST1_SFMO_SH
        rnd = (self.st1 & ST1_RND) >> ST1_RND_SH
        if rnd > 4:
            rnd = 0
        m = self.macc_read
        over = False
        if sfmo < 3:
            m1 = m & OVM[sfmo]
            if m1 and m1 != OVM[sfmo]:
                over = True
            m = s64(m << (0, 2, 4)[sfmo])
        else:
            m >>= 8
        m = s64((m + ROUNDING[rnd]) & RMASK[rnd])
        m1 = m & OVM[0]
        if m1 and m1 != OVM[0]:
            over = True
        return self.sat(m) if over else m

    def mv(self):
        sfmo = (self.st1 & ST1_SFMO) >> ST1_SFMO_SH
        m = self.macc_read
        if sfmo == 3:
            return m
        m1 = m & OVM[sfmo]
        if m1 and m1 != OVM[sfmo]:
            return self.sat(m)
        return m

    # ---- decode ---------------------------------------------------------------
    @staticmethod
    def xmode(op, t, inc):
        if (op & 0x400 and t == 'c') or (not op & 0x400 and t == 'd'):
            if op & 0x100:
                return 0
            if op & 0x80:
                inc.add(t)
            return 1
        if op & 0x200:
            inc.add(t)
        return 1

    def step(self):
        """One instruction word, as tms57002_device::execute_run's loop body."""
        op = self.pmem[self.pc]
        if self.rd or self.wr:
            self.xm_step()
        self.macc_read = self.macc_write
        self.macc_write = self.macc
        self.branch = False
        inc = set()
        if op & 0xfc0000 == 0xfc0000:
            self.cat3((op >> 11) & 0x7f, op & 0xff)
        else:
            c2 = (op >> 11) & 0x7f
            # the ca/id post-increments are decided at decode, by every op
            # in the word that takes a c or d operand, whether or not it
            # then executes (lpc, rde, wre can return early)
            for t in USE1.get(op >> 18, "") + USE2.get(c2, ""):
                self.xmode(op, t, inc)
            if c2 in PRE:
                self.cat2(c2, op, inc)
            self.cat1(op >> 18, op, inc)
            if c2 in POST:
                self.cat2(c2, op, inc)
            elif c2 and c2 not in PRE:
                self.unimpl[('2', c2)] = self.unimpl.get(('2', c2), 0) + 1
        if 'c' in inc:
            self.ca = (self.ca + 1) & 0xff
        if 'd' in inc:
            self.id = (self.id + 1) & 0xff
        self.cycles += 1
        if self.rptc:
            self.rptc -= 1
        elif self.branch:
            pass
        else:
            self.pc = (self.pc + 1) & 0xff
        if self.rptc_next:
            self.rptc = self.rptc_next
            self.rptc_next = 0

    def cat3(self, o, i):
        if o == 0x48:
            self.pc = i; self.branch = True
        elif o == 0x50:
            if s32(self.aacc) > 0: self.pc = i; self.branch = True
        elif o == 0x58:
            if s32(self.aacc) < 0: self.pc = i; self.branch = True
        elif o == 0x60:
            if self.aacc: self.pc = i; self.branch = True
        elif o == 0x78:
            if self.st1 & ST1_AOV:
                self.st1 &= ~ST1_AOV; self.pc = i; self.branch = True
        elif o == 0x08:
            self.idle = True
        elif o == 0x40:
            if s32(self.aacc) >= 0: self.ca = i
        elif o == 0x18:
            self.ca = i
        elif o == 0x20:
            self.id = i
        elif o == 0x10:
            self.rptc_next = i
        elif o:
            self.unimpl[('3', o)] = self.unimpl.get(('3', o), 0) + 1

    def cm(self, op, inc):
        return self.xmode(op, 'c', set())

    def dm(self, op, inc):
        return self.xmode(op, 'd', set())

    def C(self, op, inc):
        return self.get_cmem(op & 0xff if self.cm(op, inc) == 0 else self.ca)

    def WC(self, op, inc, v):
        a = op & 0xff if self.cm(op, inc) == 0 else self.ca
        self.cmem[a] = v & M32

    def D(self, op, inc):
        return self.d32(self.dm(op, inc), op & 0xff)

    def D24(self, op, inc):
        return self.d24(self.dm(op, inc), op & 0xff)

    def WD(self, op, inc, v):
        self.wd(self.dm(op, inc), op & 0xff, v)

    def mul_d(self, op, inc, signed):
        d = self.D24(op, inc)
        if signed and d & 0x800000:
            d |= 0xff000000
        return s32(d) if signed else d

    def cat1(self, o, op, inc):
        a = self.a
        if o == 0:
            return
        if o == 0x01:                                   # abs
            self.aacc = a()
            if s32(self.aacc) < 0:
                self.aacc = (-self.aacc) & M32
                if s32(self.aacc) < 0:
                    self.st1 |= ST1_AOV
        elif o == 0x02: self.wa(-a())                  # MAME: -(int64_t)(u32)
        elif o == 0x03: self.wa(s32(self.D(op, inc)) + s32(a()))
        elif o == 0x04: self.wa(s32(self.C(op, inc)) + s32(a()))
        elif o == 0x05:
            d = self.sfai(self.D(op, inc)); self.wa(s32(d) + (self.mo() >> 16))
        elif o == 0x06: self.wa(s32(self.C(op, inc)) + (self.mo() >> 16))
        elif o == 0x07:
            d = self.D(op, inc); self.wa(s32(d) + s32(self.C(op, inc)))
        elif o == 0x09: self.wa(s32(self.D(op, inc)) - s32(a()))
        elif o == 0x0a: self.wa(s32(self.C(op, inc)) - s32(a()))
        elif o == 0x0b:
            d = self.sfai(self.D(op, inc)); self.wa(s32(d) - (self.mo() >> 16))
        elif o == 0x0c: self.wa(s32(self.C(op, inc)) - (self.mo() >> 16))
        elif o == 0x0d:
            d = self.D(op, inc); self.wa(s32(d) - s32(self.C(op, inc)))
        elif o == 0x11: self.aacc = self.sfai(self.D(op, inc))
        elif o == 0x12: self.aacc = self.C(op, inc)
        elif o == 0x14: self.aacc &= self.sfai(self.D(op, inc))
        elif o == 0x15: self.aacc &= self.C(op, inc)
        elif o == 0x16:
            d = self.sfai(self.D(op, inc)); self.aacc = self.C(op, inc) & d
        elif o == 0x17: self.aacc |= self.sfai(self.D(op, inc))
        elif o == 0x18: self.aacc |= self.C(op, inc)
        elif o == 0x19:
            d = self.sfai(self.D(op, inc)); self.aacc = self.C(op, inc) | d
        elif o in (0x21, 0x24):                         # mpy/mac d,c
            d = self.mul_d(op, inc, True)
            self.creg = c = self.C(op, inc)
            r = s32(c) * d
            self.macc = s64((self.ml() if o == 0x24 else 0) + (r >> 7))
        elif o in (0x22, 0x26):                         # mpy/mac c,a
            self.creg = c = self.C(op, inc)
            r = s32(c) * s32(a())
            self.macc = s64((self.ml() if o == 0x26 else 0) + (r >> 15))
        elif o == 0x25:                                 # mac a,d
            d = self.mul_d(op, inc, True)
            self.creg = c = a()
            self.macc = s64(self.ml() + ((s32(c) * d) >> 7))
        elif o == 0x2e:                                 # macs c,a
            self.creg = c = self.C(op, inc)
            self.macc = s64(self.ml() + ((s32(c) * s32(a())) >> 14))
        elif o in (0x28, 0x29):                         # mpyu/macu d,c
            self.creg = c = self.C(op, inc)
            d = self.mul_d(op, inc, False)
            r = s32(c) * d
            self.macc = s64((self.ml() if o == 0x29 else 0) + (r >> 7))
        elif o == 0x2a:                                 # macu a,d
            d = self.mul_d(op, inc, False)
            self.creg = c = a()
            self.macc = s64(self.ml() + ((s32(c) * d) >> 7))
        elif o == 0x31:
            self.macc_write = self.macc = s64(s32(self.D(op, inc)) << 16)
        elif o == 0x32:
            self.macc_write = self.macc = s64(
                (self.macc & ~0xffffff) | self.D24(op, inc))
        elif o == 0x33:
            self.macc_write = self.macc = s64(s32(self.C(op, inc)) << 16)
        elif o == 0x34:
            m = self.macc & M64
            self.macc = s64((m & 0x8000000000000) | ((m << 1) & 0x7ffffffffffff))
        elif o == 0x35:
            m = self.macc & M64
            self.macc = s64((m & 0x8000000000000) | ((m >> 1) & 0x7ffffffffffff))
        elif o == 0x38:                                 # wre d,c
            if self.rd or self.wr:
                return
            self.xwr = self.D24(op, inc)
            self.xoa = self.C(op, inc)
            self.xm_init(); self.wr = True
        elif o == 0x39:                                 # rde c
            if self.rd or self.wr:
                return
            self.xoa = self.C(op, inc)
            self.xm_init(); self.rd = True
        else:
            self.unimpl[('1', o)] = self.unimpl.get(('1', o), 0) + 1

    def cat2(self, o, op, inc):
        if o == 0x01: self.WC(op, inc, self.a())                # sacc
        elif o == 0x02: self.WD(op, inc, self.a() >> 8)         # sacd
        elif o == 0x03: self.WD(op, inc, (self.mo() >> 24) & 0xffffff)
        elif o == 0x05: self.WC(op, inc, self.mo() >> 16)       # smhc
        elif o == 0x06: self.WD(op, inc, (self.mv() >> 24) & 0xffff00)
        elif o == 0x07: self.WD(op, inc, (self.mv() >> 8) & 0xffffff)
        elif o == 0x08: self.ca = (self.a() >> 24) & 0xff       # lcaa
        elif o == 0x09: self.id = (self.a() >> 24) & 0xff       # lira
        elif o == 0x0e: pass                                    # ref
        elif o == 0x0f: self.WD(op, inc, self.xrd)              # srbd
        elif 0x10 <= o <= 0x13: self.WD(op, inc, self.si[o - 0x10])
        elif 0x20 <= o <= 0x23:
            self.so[o - 0x20] = (self.mo() >> 24) & 0xffffff
        elif o == 0x31:                                         # lpc
            if self.hostf:
                return
            c = self.C(op, inc)
            self.host = [(c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff,
                         c & 0xff]
            self.hidx = 0
            self.hostf = True
        elif o == 0x3a: self.st1 &= ~ST1_MOV
        elif o == 0x3c: self.st1 &= ~ST1_AOVM
        elif o == 0x3d: self.st1 |= ST1_AOVM
        elif o == 0x40: self.st1 &= ~ST1_MOVM
        elif o == 0x41: self.st1 |= ST1_MOVM
        elif o == 0x44: self.st1 &= ~ST1_DBP
        elif o == 0x45: self.st1 |= ST1_DBP
        elif 0x48 <= o <= 0x4b:
            self.st1 = (self.st1 & ~ST1_CRM) | ((o - 0x48) << ST1_CRM_SH)
        elif o == 0x50: self.st1 &= ~ST1_SFAO
        elif o == 0x51: self.st1 |= ST1_SFAO
        elif o == 0x54: self.st1 &= ~ST1_SFAI
        elif o == 0x55: self.st1 |= ST1_SFAI
        elif 0x58 <= o <= 0x5b:
            self.st1 = (self.st1 & ~ST1_SFMA) | ((o - 0x58) << ST1_SFMA_SH)
        elif 0x60 <= o <= 0x63:
            self.st1 = (self.st1 & ~ST1_SFMO) | ((o - 0x60) << ST1_SFMO_SH)
        elif 0x68 <= o <= 0x6f:
            self.st1 = (self.st1 & ~ST1_RND) | ((o - 0x68) << ST1_RND_SH)
        else:
            self.unimpl[('2', o)] = self.unimpl.get(('2', o), 0) + 1


# cat2 opcodes executed before the cat1 op of the same word (tmsinstr.lst
# category 2a) and after it (2b). Both sets include the no-body ones so they
# decode (as no-ops) rather than count as unknown.
PRE = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0e, 0x0f,
       0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
       0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x30, 0x31, 0x38, 0x42}
POST = {0x0c, 0x0d, 0x1c, 0x1d, 0x1e, 0x1f, 0x3a, 0x3c, 0x3d, 0x40, 0x41,
        0x44, 0x45, 0x48, 0x49, 0x4a, 0x4b, 0x50, 0x51, 0x54, 0x55, 0x58, 0x59,
        0x5a, 0x5b, 0x60, 0x61, 0x62, 0x63, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d,
        0x6e, 0x6f}


# operands each op takes, for the decode-time ca/id increments
USE1 = {0x03: "d", 0x04: "c", 0x05: "d", 0x06: "c", 0x07: "dc", 0x09: "d",
        0x0a: "c", 0x0b: "d", 0x0c: "c", 0x0d: "dc", 0x11: "d", 0x12: "c",
        0x14: "d", 0x15: "c", 0x16: "dc", 0x17: "d", 0x18: "c", 0x19: "dc",
        0x21: "dc", 0x22: "c", 0x24: "dc", 0x25: "d", 0x26: "c", 0x28: "dc",
        0x29: "dc", 0x2a: "d", 0x2e: "c", 0x31: "d", 0x32: "d", 0x33: "c",
        0x38: "dc", 0x39: "c"}
USE2 = {0x01: "c", 0x02: "d", 0x03: "d", 0x05: "c", 0x06: "d", 0x07: "d",
        0x0f: "d", 0x10: "d", 0x11: "d", 0x12: "d", 0x13: "d", 0x31: "c"}


# ---- disassembly ------------------------------------------------------------
def dis(names, op):
    def ops(fmt):
        p = op & 0xff
        return (fmt.replace("%c", "c[%02x]" % p if op & 0x400 and op & 0x100
                            else "c[ca%s]" % ("++" if (op & 0x400 and op & 0x80) or
                                               (not op & 0x400 and op & 0x200) else ""))
                .replace("%d", "d[%02x]" % p if not op & 0x400 and op & 0x100
                         else "d[id%s]" % ("++" if (not op & 0x400 and op & 0x80) or
                                            (op & 0x400 and op & 0x200) else ""))
                .replace("%i", "%02x" % p))
    if op & 0xfc0000 == 0xfc0000:
        o = (op >> 11) & 0x7f
        return ops(names.get(("3", o), "?3:%02x" % o)) if o else "nop"
    parts = []
    c2 = (op >> 11) & 0x7f
    if c2 in PRE:
        parts.append(ops(names.get(("2a", c2), "?2a:%02x" % c2)))
    if op >> 18:
        parts.append(ops(names.get(("1", op >> 18), "?1:%02x" % (op >> 18))))
    if c2 in POST:
        parts.append(ops(names.get(("2b", c2), "?2b:%02x" % c2)))
    elif c2 and c2 not in PRE:
        parts.append("?2:%02x" % c2)
    return " ; ".join(parts) or "nop"


def read_log(path):
    ev = []
    for line in Path(path).read_text().splitlines():
        t, f, k, v = line.split()
        ev.append((int(t), int(f), k, int(v, 16)))
    return ev


def sessions(ev):
    """Program loads: (index of first event, st0, st1, words)."""
    out = []
    ctrl = 0xff
    cur = None
    for n, (t, f, k, v) in enumerate(ev):
        if k == "C":
            now = not (v & 4) and (v & 8)
            if now and cur is None:
                cur = (n, t, f, [])
            elif not now and cur is not None:
                out.append(cur); cur = None
            ctrl = v
        elif k == "W" and cur is not None:
            cur[3].append(v)
    return out


def cmd_dis(a):
    names = load_names()
    ev = read_log(a.log)
    ss = sessions(ev)
    n, t, f, b = ss[a.session]
    w = [(b[i] << 16) | (b[i + 1] << 8) | b[i + 2] for i in range(0, len(b) - 2, 3)]
    print("; session %d at %d us frame %d: st0=%06x st1=%06x, %d words"
          % (a.session, t, f, w[0], w[1], len(w) - 2))
    for pc, op in enumerate(w[2:]):
        print("%02x  %06x  %s" % (pc & 0xff, op, dis(names, op)))


def cmd_run(a):
    ev = read_log(a.log)
    d = DASP()
    # MAME: the DSP runs at MASTER_CLOCK/2 = 12 MHz and is synced once per
    # K054539 sample, 18.432 MHz / 384 = 48 kHz: at most 250 words a sample.
    per = 1e6 / 48000.0
    nxt = 0.0
    bad = 0
    stat_last = None
    for n, (t, f, k, v) in enumerate(ev):
        if a.until_us and t > a.until_us:
            break
        while nxt <= t:
            d.sync()
            budget = 250
            while budget and d.running():
                d.step(); budget -= 1
            nxt += per
        if k == "C":
            d.control_w(v)
        elif k == "W":
            d.data_w(v)
        elif k == "R":
            r = d.data_r()
            if r != v:
                bad += 1
                if bad <= 20:
                    print("line %d t=%d f=%d: data read model %02x MAME %02x" % (n + 1, t, f, r, v))
        elif k == "S":
            # pc0 (bit 1) says whether the DSP is part way through its
            # program when polled: a matter of MAME's time slicing, not state
            s = d.status() & ~2 | v & 2
            if s != v and (s, v) != stat_last:
                bad += 1
                if bad <= 20:
                    print("line %d t=%d f=%d: status model %02x MAME %02x" % (n + 1, t, f, s, v))
            stat_last = (s, v) if s != v else None
    print("events %d, mismatches %d, DSP words executed %d" % (n + 1, bad, d.cycles))
    if d.unimpl:
        print("no-op (bodyless or unknown) opcodes executed:",
              ", ".join("%s:%02x x%d" % (c, o, k) for (c, o), k in sorted(d.unimpl.items())))


def si_of(n):
    """The synthetic inputs for sample n, shared with sim/gx_tms57002_tb:
    24-bit, full scale, different on each channel."""
    out = []
    for k in range(4):
        x = (n * 0x9E3779B1 + k * 0x7F4A7C15) & 0xffffffff
        x ^= x >> 15
        x = (x * 0x2C1B3C6D) & 0xffffffff
        x ^= x >> 12
        out.append(x & 0xffffff)
    return out


def lockstep_events(ev, t0):
    """Events by sample: each applied before that sample's sync."""
    per = 1e6 / 48000.0
    for t, f, k, v in ev:
        yield int((t - t0) / per), k, v


def cmd_lock(a):
    """Lockstep: sample n's host writes (and reads) happen with the DSP idle,
    before sync n; one line per sample of outputs and accumulators."""
    ev = read_log(a.log)
    t0 = ev[0][0] - 100
    d = DASP()
    ls = list(lockstep_events(ev, t0))
    nmax = ls[-1][0] + 1 if a.samples is None else a.samples
    i = 0
    over = 0
    with open(a.out, "w") as o:
        for n in range(nmax):
            while i < len(ls) and ls[i][0] <= n:
                _, k, v = ls[i]
                if k == "C": d.control_w(v)
                elif k == "W": d.data_w(v)
                elif k == "R": d.data_r()
                i += 1
            d.si = si_of(n)
            d.sync()
            steps = 0
            while d.running():
                d.step(); steps += 1
            if steps > 250:
                over += 1
            o.write("%d %06x %06x %06x %06x %08x %016x\n" % (
                n, d.so[0], d.so[1], d.so[2], d.so[3], d.aacc, d.macc & M64))
    print("samples %d, over 250 words: %d" % (nmax, over))
    if d.unimpl:
        print("no-op (bodyless or unknown) opcodes executed:",
              ", ".join("%s:%02x x%d" % (c, o, k) for (c, o), k in sorted(d.unimpl.items())))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("dis"); p.add_argument("log"); p.add_argument("session", type=int, nargs="?", default=0)
    p = sub.add_parser("run"); p.add_argument("log"); p.add_argument("--until-us", type=int)
    p = sub.add_parser("lock"); p.add_argument("log"); p.add_argument("out"); p.add_argument("--samples", type=int)
    a = ap.parse_args()
    {"dis": cmd_dis, "run": cmd_run, "lock": cmd_lock}[a.cmd](a)


if __name__ == "__main__":
    main()
