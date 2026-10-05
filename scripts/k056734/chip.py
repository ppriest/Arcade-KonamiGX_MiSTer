# SPDX-License-Identifier: GPL-3.0-or-later
"""The 056734 (ESC) as rtl/esc/k056734.sv runs it: the kernel loaded and entered
directly (no boot code), then mailbox packets. The reference for
sim/k056734_tb (scripts/esc_chip_check.py).

The host is a dict of bytes; a store to 0xCC0000 clears the mailbox instead.
"""
from escemu import ESC
from esccipher import CHIPS, decrypt_image, descramble

KERNEL = 0x200A6C
WAIT = 0x00120367            # sub r0, s7, r0: the kernel's mailbox test


class Host(dict):
    chip = None

    def __setitem__(self, a, v):
        if 0xCC0000 <= a <= 0xCC0003 and self.chip is not None:
            self.chip.r[39] = 0
            return
        dict.__setitem__(self, a, v)

    def get(self, a, d=0):
        return dict.get(self, a, d)


class Alias(list):
    """Local memory of 4K words, as the RTL builds it: 0x1000-0x1FFF (and up) alias it."""
    def __getitem__(self, i):
        return list.__getitem__(self, i & 0xFFF if isinstance(i, int) else i)

    def __setitem__(self, i, v):
        list.__setitem__(self, i & 0xFFF if isinstance(i, int) else i, v)


class Chip(ESC):
    def __init__(self, setname, host, rom, alias=True):
        s10, nib, xor, lanes, _ = CHIPS[setname]
        ESC.__init__(self, host, lambda w: descramble(w, xor, lanes),
                     s10=s10, s11=(nib << 24) | 0x200100)
        if alias:
            self.local = Alias([0] * 0x1000)
        host.chip = self
        h, code, data, ok = decrypt_image(rom[KERNEL - 0x200000:], s10, nib, kernel=True)
        assert ok, 'kernel checksum'
        for i, w in enumerate(code + data):
            self.local[i] = w
        self.r[3] = h['A']
        self.r[2] = h['A'] + h['B']
        self.r[24] = (h['A'] + h['B'] + h['C'] + 4) & ~3
        self.r[25] = self.r[33] = 0x2000
        self.pc = 0

    def waiting(self):
        return self.r[39] == 0 and self.xf(self.local[self.pc & 0xFFFF]) == WAIT

    def run_until_idle(self, limit=30_000_000):
        n0, idle = self.steps, 0
        while self.steps - n0 < limit:
            w = self.waiting() or self.xf(self.local[(self.pc - 1) & 0xFFFF]) == WAIT and self.r[39] == 0
            self.step()
            self.steps += 1
            idle = idle + 1 if w else 0
            if idle > 200:
                return self.steps - n0
        raise RuntimeError('not idle after %d steps, pc %d' % (limit, self.pc))

    def post(self, ptr):
        self.r[39] = ptr
        return self.run_until_idle()
