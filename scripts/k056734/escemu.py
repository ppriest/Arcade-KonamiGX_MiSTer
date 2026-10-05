"""ESC 056734 emulator (semantics from konami_056734_manual.md sections 2-4). Canonical fetch."""
from escdis import L, lanes, sx
M32 = 0xFFFFFFFF
SZM = {0: (M32, 32), 1: (0xFF, 8), 2: (0xFFFF, 16), 3: (M32, 32)}
TAKE = {
    (1, 0, 0): lambda Z, N, C, V: True,
    (1, 1, 0): lambda Z, N, C, V: True,
    (2, 0, 0): lambda Z, N, C, V: Z,
    (3, 0, 0): lambda Z, N, C, V: not Z,
    (0, 0, 1): lambda Z, N, C, V: N,
    (1, 0, 1): lambda Z, N, C, V: not N,
    (2, 0, 1): lambda Z, N, C, V: C,
    (3, 0, 1): lambda Z, N, C, V: not C,
    (1, 0, 2): lambda Z, N, C, V: (not Z) and N == V,
    (3, 0, 2): lambda Z, N, C, V: (not C) and not Z,
    (0, 0, 3): lambda Z, N, C, V: N != V,
}


class ESC:
    def __init__(self, host, fetch_xform, s10=0, s11=0x200100):
        self.host = host                    # dict: 24-bit byte address -> byte
        self.local = [0] * 0x10000
        self.r = [0] * 64
        self.r[42] = s10
        self.r[43] = s11
        self.xf = fetch_xform               # stored word -> canonical word
        self.Z = self.N = self.C = self.V = 0
        self.steps = 0
        self.hreads = self.hwrites = 0

    def hr(self, a, n):
        self.hreads += 1
        v = 0
        for i in range(n):
            v = (v << 8) | self.host.get((a + i) & 0xFFFFFF, 0)
        return v

    def hw(self, a, n, v):
        self.hwrites += 1
        for i in range(n):
            self.host[(a + i) & 0xFFFFFF] = (v >> (8 * (n - 1 - i))) & 0xFF

    def get(self, n, pc):
        if n == 0:
            return 0
        if n == 34:                         # s2 reads as pc + 2
            return (pc + 2) & M32
        return self.r[n]

    def put(self, n, v):
        if n:
            self.r[n] = v & M32

    def flags(self, res, msk, bits, a=None, b=None, sub=False, arith=False):
        res &= msk
        self.Z = int(res == 0)
        self.N = (res >> (bits - 1)) & 1
        if arith:
            a &= msk
            b &= msk
            sa, sb = a >> (bits - 1), b >> (bits - 1)
            if sub:
                self.C = int(a < b)
                self.V = int(sa != sb and self.N != sa)
            else:
                self.C = int(a + b > msk)
                self.V = int(sa == sb and self.N != sa)

    def push(self, v):
        self.r[33] = (self.r[33] - 1) & M32
        self.local[self.r[33] & 0xFFFF] = v & M32

    def pop(self):
        v = self.local[self.r[33] & 0xFFFF]
        self.r[33] = (self.r[33] + 1) & M32
        return v

    def call(self, entry, sentinel=0xFFFF, maxsteps=50_000_000):
        self.push(sentinel)
        self.pc = entry
        while self.pc != sentinel:
            self.step()
            self.steps += 1
            if self.steps > maxsteps:
                raise RuntimeError('runaway at %d' % self.pc)
        return self.r[31]

    def step(self):
        pc = self.pc
        w = self.xf(self.local[pc & 0xFFFF])
        npc = pc + 1
        self.pc = npc
        if w == 0:
            return
        cls = L(w, 0)
        sz = L(w, 7)
        rA = lanes(w, (5, 15, 9))
        rB = lanes(w, (2, 1, 4))
        off = sx(lanes(w, (6, 14, 13, 12, 11)), 10)
        imm = lanes(w, (2, 1, 4, 6, 14, 13, 12, 11))
        rC = (off >> 3) & 63
        o10, o8, o3 = L(w, 10), L(w, 8), L(w, 3)
        g = lambda n: self.get(n, pc)

        if cls == 0:
            if (L(w, 5), L(w, 7), L(w, 9), L(w, 15)) == (2, 2, 2, 0):
                cond = (o10, o8, o3)
                if TAKE[cond](self.Z, self.N, self.C, self.V):
                    if cond == (1, 1, 0):
                        self.push(npc)
                    self.pc = npc + sx(imm, 16)
                return
            if (o10, o8, sz, o3) == (1, 0, 2, 0):
                self.pc = (g(rA) + off) & M32
                return
            if (o10, o8, sz, o3) == (1, 1, 2, 0):
                self.push(npc)
                self.pc = g(rA)
                return
            rD = (o8 & 1) << 4 | o3 << 2 | (o10 >> 1) << 1 | (1 - (o10 & 1))
            self.put(rD, sz << 22 | rA << 16 | imm)
            return

        if cls == 1:
            rD = (o8 & 1) << 4 | o3 << 2 | (o10 >> 1) << 1 | (1 - (o10 & 1))
            a = sz << 22 | rA << 16 | imm
            if o8 & 2:
                self.hw(a, 4, g(rD))
            else:
                self.put(rD, self.hr(a, 4))
            return

        msk, bits = SZM[sz]
        nb = bits // 8
        k = (o10, o8, o3)

        if cls == 3:
            if k in ((1, 2, 0), (1, 2, 1), (1, 2, 2), (1, 2, 3), (3, 2, 1), (3, 2, 3)):
                a, b = g(rB), g(rC)
                if k == (1, 2, 0):
                    res = a + b; self.flags(res, msk, bits, a, b, False, True)
                elif k == (1, 2, 1):
                    res = a - b; self.flags(res, msk, bits, a, b, True, True)
                elif k == (1, 2, 2):
                    res = a & b; self.flags(res, msk, bits)
                elif k == (1, 2, 3):
                    res = a ^ b; self.flags(res, msk, bits)
                elif k == (3, 2, 1):
                    res = a | b; self.flags(res, msk, bits)
                else:
                    res = ~(a | b); self.flags(res, msk, bits)
                self.put(rA, (a & ~msk) | (res & msk))
                return
            if k in ((1, 3, 0), (1, 3, 1), (1, 3, 2), (1, 3, 3), (3, 3, 1)):
                a, b = g(rA), imm
                if k == (1, 3, 0):
                    res = a + b; self.flags(res, msk, bits, a, b, False, True)
                elif k == (1, 3, 1):
                    res = a - b; self.flags(res, msk, bits, a, b, True, True)
                elif k == (1, 3, 2):
                    res = a & b; self.flags(res, msk, bits)
                elif k == (1, 3, 3):
                    res = a ^ b; self.flags(res, msk, bits)
                else:
                    res = a | b; self.flags(res, msk, bits)
                self.put(rA, (a & ~msk) | (res & msk))
                return
            ea_h = (g(rB) + off) & 0xFFFFFF
            ea_l = (g(rB) + off) & 0xFFFF
            if k == (2, 0, 3):
                self.put(rA, self.hr(ea_h, nb)); return
            if k == (3, 0, 3):
                self.hw(ea_h, nb, g(rA) & msk); return
            if k == (2, 1, 3):
                self.put(rA, self.local[ea_l] & msk); return
            if k == (3, 1, 3):
                self.local[ea_l] = (self.local[ea_l] & ~msk & M32) | (g(rA) & msk); return
            lv = self.local[ea_l]
            if k in ((0, 1, 0), (0, 1, 1), (0, 1, 2), (0, 1, 3), (2, 1, 1)):
                a = g(rA)
                if k == (0, 1, 1):
                    self.flags(a - lv, msk, bits, a, lv, True, True); return
                if k == (0, 1, 0):
                    res = a + lv; self.flags(res, msk, bits, a, lv, False, True)
                elif k == (0, 1, 2):
                    res = a & lv; self.flags(res, msk, bits)
                elif k == (0, 1, 3):
                    res = a ^ lv; self.flags(res, msk, bits)
                else:
                    res = a | lv; self.flags(res, msk, bits)
                self.put(rA, (a & ~msk) | (res & msk))
                return
            if k in ((1, 1, 0), (1, 1, 1), (1, 1, 2), (1, 1, 3)):
                a = g(rA)
                if k == (1, 1, 0):
                    res = lv + a; self.flags(res, msk, bits, lv, a, False, True)
                elif k == (1, 1, 1):
                    res = lv - a; self.flags(res, msk, bits, lv, a, True, True)
                elif k == (1, 1, 2):
                    res = lv & a; self.flags(res, msk, bits)
                else:
                    res = lv ^ a; self.flags(res, msk, bits)
                self.local[ea_l] = (lv & ~msk & M32) | (res & msk)
                return
            if k == (0, 0, 1):
                b = self.hr(ea_h, nb); self.flags(g(rA) - b, msk, bits, g(rA), b, True, True); return
            if k == (1, 0, 1):
                b = self.hr(ea_h, nb); self.flags(b - g(rA), msk, bits, b, g(rA), True, True); return

        if cls == 2:
            p = (o10, o8, sz, o3)
            if p == (1, 1, 0, 0):
                self.push(g(rA)); return
            if p == (3, 1, 0, 0):
                self.put(rA, self.pop()); return
            if p in ((1, 1, 0, 1), (3, 1, 0, 1)):
                self.pc = self.pop(); return
            if p == (1, 0, 0, 3):
                self.put(rA, (g(rA) & 0xFFFF) | imm << 16); return
            if p == (3, 0, 0, 1):
                v = g(rB); self.put(rA, ((v << 16) | (v >> 16)) & M32); return
            if p == (3, 0, 0, 0):               # 30002: unknown unary; only in the boot RAM test, taken as neg
                self.put(rA, -g(rB)); return
            if p == (1, 0, 2, 1):
                v = g(rB) & 0xFFFF; self.put(rA, v - 0x10000 if v & 0x8000 else v); return
            if p == (1, 0, 1, 1):
                v = g(rB) & 0xFF; self.put(rA, v - 0x100 if v & 0x80 else v); return
            if p == (1, 0, 0, 2):
                self.r[40] = (g(rA) * g(rB)) & M32; return
            if p == (1, 0, 2, 2):
                self.r[40] = (sx(g(rA) & 0xFFFF, 16) * sx(g(rB) & 0xFFFF, 16)) & M32; return
            if p == (3, 0, 2, 2):
                d = g(rB) & 0xFFFF
                self.r[40] = ((g(rA) & 0xFFFF) // d) if d else 0xFFFF
                return
            if k in ((1, 2, 0), (1, 2, 1), (1, 2, 2), (3, 2, 0), (3, 2, 1), (3, 2, 2)):
                v = g(rB)
                x = v & msk
                if o10 == 1 and o3 in (0, 1):
                    res = x << 1
                elif o10 == 1:
                    res = (x << 1) | (x >> (bits - 1))
                elif o3 == 0:
                    res = x >> 1
                elif o3 == 1:
                    res = (x >> 1) | (x & (1 << (bits - 1)))
                else:
                    res = (x >> 1) | ((x & 1) << (bits - 1))
                self.flags(res, msk, bits)
                self.put(rA, (v & ~msk) | (res & msk))
                return
        raise RuntimeError('unimplemented %08X at %d' % (w, pc))
