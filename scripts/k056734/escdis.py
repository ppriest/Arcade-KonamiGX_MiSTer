"""ESC 056734 disassembler, canonical encoding (konami_056734_manual.md sections 3-4)."""
L = lambda w, k: (w >> (2*k)) & 3
def lanes(w, ks):
    v = 0
    for k in ks: v = (v << 2) | L(w, k)
    return v
def sx(v, b): return v - (1 << b) if v & (1 << (b - 1)) else v
def reg(n): return ('r%d' % n) if n < 32 else ('s%d' % (n - 32))
SZ = {0: '', 1: '.b', 2: '.h', 3: '.?'}
ALU = {'1203': 'add', '1213': 'sub', '1223': 'and', '1233': 'xor', '3213': 'or', '3233': 'nor'}
IMM = {'1303': 'addi', '1313': 'subi', '1323': 'andi', '1333': 'xori', '3313': 'ori'}
MEM = {'2033': 'ld', '3033': 'st', '2133': 'ld(l)', '3133': 'st(l)'}
MOP = {'0103': 'add(m)', '0113': 'cmp(m)', '0123': 'and(m)', '0133': 'xor(m)', '2113': 'or(m)',
       '1103': '(m)add', '1113': '(m)sub', '1123': '(m)and', '1133': '(m)xor', '0013': 'cmp.m', '1013': 'cmpm'}
C2 = {'11002': 'push', '31002': 'pop', '11012': 'ret', '31012': 'ret*', '10032': 'lih', '30012': 'swap16',
      '10212': 'ext.h', '10112': 'ext.b', '10022': 'mul', '10222': 'mul.h', '30222': 'div.h', '30002': 'neg?'}
SH = {'1202': 'shl', '1212': 'asl', '1222': 'rol', '3202': 'shr', '3212': 'asr', '3222': 'ror'}
COND = {'100': 'jmp', '110': 'call', '200': 'beq', '300': 'bne', '001': 'bmi', '101': 'bpl',
        '201': 'bcs', '301': 'bcc', '102': 'bgt', '302': 'bhi', '003': 'blt'}
def dis(w, i=0):
    if w == 0: return 'nop'
    cls = L(w, 0); sz = L(w, 7)
    rA = lanes(w, (5, 15, 9)); rB = lanes(w, (2, 1, 4))
    off = sx(lanes(w, (6, 14, 13, 12, 11)), 10); imm = lanes(w, (2, 1, 4, 6, 14, 13, 12, 11))
    op = '%d%d%d' % (L(w, 10), L(w, 8), L(w, 3)); pat = '%d%d%d%d%d' % (L(w, 10), L(w, 8), sz, L(w, 3), cls)
    key4 = op[:2] + op[2] + str(cls)    # lanes 10,8,3,0 (size wildcard)
    rC = reg((off >> 3) & 63) if True else ''
    m = lambda d: ('[%s%+d]' % (reg(rB), d)) if d else ('[%s]' % reg(rB))
    if cls == 0:
        if (L(w, 5), L(w, 7), L(w, 9), L(w, 15)) == (2, 2, 2, 0):
            return '%-6s %d' % (COND.get(op, 'b?' + op), i + 1 + sx(imm, 16))
        if pat in ('10200', '11200'):
            return ('jr %s%s' % (reg(rA), ('%+d' % off) if off else '')) if pat == '10200' else 'jsr ' + reg(rA)
        rD = (L(w, 8) & 1) << 4 | L(w, 3) << 2 | (L(w, 10) >> 1) << 1 | (1 - (L(w, 10) & 1))
        return 'li %s, #0x%X' % (reg(rD), L(w, 7) << 22 | rA << 16 | imm)
    if cls == 1:
        rD = (L(w, 8) & 1) << 4 | L(w, 3) << 2 | (L(w, 10) >> 1) << 1 | (1 - (L(w, 10) & 1))
        a = L(w, 7) << 22 | rA << 16 | imm
        return '%s %s, [0x%06X]' % ('st.abs' if L(w, 8) & 2 else 'ld.abs', reg(rD), a)
    s = SZ[sz]
    if cls == 3:
        if key4 in ALU:
            n = ALU[key4]
            if n == 'or' and (off >> 3) & 63 == 0: return 'mov%s %s, %s' % (s, reg(rA), reg(rB))
            return '%s%s %s, %s, %s' % (n, s, reg(rA), reg(rB), reg((off >> 3) & 63))
        if key4 in IMM: return '%s%s %s, #0x%X' % (IMM[key4], s, reg(rA), imm)
        if key4 in MEM: return '%s%s %s, %s' % (MEM[key4], s, reg(rA), m(off))
        if key4 in MOP: return '%s%s %s, %s' % (MOP[key4], s, reg(rA), m(off))
    if cls == 2:
        if pat in C2:
            n = C2[pat]
            if n in ('push', 'pop', 'ret', 'ret*'): return '%s %s' % (n, reg(rA))
            if n == 'lih': return 'lih %s, #0x%X' % (reg(rA), imm)
            return '%s %s, %s' % (n, reg(rA), reg(rB))
        if key4 in SH: return '%s%s %s, %s' % (SH[key4], s, reg(rA), reg(rB))
    return '??? %s' % pat
