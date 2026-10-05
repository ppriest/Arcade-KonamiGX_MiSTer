"""Konami 056734 (ESC) image ciphers, standalone reference.

Transcribed from the boot code (kernel stream cipher, boot.txt words 335-383) and
the kernel (program key, kernel.txt words 875-925; block cipher 1387-1665).
Checked against the header checksum of the kernel and program image of all nine
titles below, and against the Daisu-Kiss plaintext in section 7 of the manual.

usage: esccipher.py <set> <dump>
  <dump> is the 68020 address space from 0x200000 (2 MB), e.g. from the MAME
  debugger: save prog.bin,200000,200000
Prints the kernel and program in canonical encoding (needs escdis.py).
"""
import struct

M32 = 0xFFFFFFFF
MASK = (0x3C96, 0xB9E5, 0x67A5, 0x3616, 0x7D8D, 0x57BB, 0x796C)
MAGIC = 0xFEF724FB


def rol2(x):
    x &= 0xFF
    return ((x << 2) | (x >> 6)) & 0xFF


def S0(a, b): return rol2(a + b)
def S1(a, b): return rol2(a + b + 1)


def bytes4(x): return [(x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF]
def word4(b): return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]


# ---- kernel image: stream cipher (boot code) ------------------------------------------
def kernel_key(s10, s11_nib):
    return ((s11_nib * 0x01010101) ^ 0x36AE2592 ^ ((s10 & 0xFFFF) * 0x00010001)) & M32


def kernel_stream(words, key):
    a, b = key ^ 0x6E8EF8FC, key
    out = []
    for w in words:
        out.append(w ^ a)
        a = (a + b) & M32
        b ^= ((a >> 16) | (a << 16)) & M32
    return out


# ---- program images: FEAL-8 variant (kernel) -------------------------------------------
def fk(a, b):                       # standard FEAL key-schedule function
    a0, a1, a2, a3 = bytes4(a)
    b0, b1, b2, b3 = bytes4(b)
    f1 = S1(a0 ^ a1, a2 ^ a3 ^ b0)
    f2 = S0(a2 ^ a3, f1 ^ b1)
    f0 = S0(a0, f1 ^ b2)
    f3 = S1(a3, f2 ^ b3)
    return word4([f0, f1, f2, f3])


def f_variant(v):                   # four round functions; v = k2 & 3
    def f(a, k):
        a0, a1, a2, a3 = bytes4(a)
        b0, b1 = (k >> 8) & 0xFF, k & 0xFF
        if v == 0:                  # standard FEAL f
            x = a0 ^ a1 ^ b0; y = a2 ^ a3 ^ b1
            f1 = S1(x, y); f2 = S0(y, f1); f0 = S0(a0, f1); f3 = S1(a3, f2)
        elif v == 1:
            x = a2 ^ a0 ^ b0; y = a1 ^ a3 ^ b1
            f2 = S1(x, y); f1 = S0(y, f2); f0 = S0(a0, f2); f3 = S1(a3, f1)
        elif v == 2:
            x = a3 ^ a2 ^ b0; y = a0 ^ a1 ^ b1
            f3 = S1(x, y); f0 = S0(y, f3); f2 = S0(a2, f3); f1 = S1(a1, f0)
        else:
            x = a0 ^ a1 ^ b1; y = a3 ^ a2 ^ b0
            f0 = S1(x, y); f3 = S0(y, f0); f1 = S0(a1, f0); f2 = S1(a2, f3)
        return word4([f0, f1, f2, f3])
    return f


def mutate(v, K, o1, o2):           # subkey update after each block; o1/o2 = output words
    if v == 0:
        K[o1 & 15] ^= K[(o2 >> 16) & 15]
    elif v == 1:
        K[(o1 >> 16) & 15] = (K[(o1 >> 16) & 15] + 1) & 0xFFFF
    elif v == 2:
        j = (o2 >> 16) & 15
        K[j] = (K[j] + K[o1 & 15]) & 0xFFFF
    else:
        i = (o2 >> 16) & 15
        K[i] = (K[i] - 1) & 0xFFFF


def program_key(s10, s11_nib, G, E, salt):
    k0 = (s11_nib << 28) | ((G & 0xFFF) << 16) | (s10 & 0xFFFF)
    k1 = k0 ^ salt
    k2 = (((G >> 13) << 3) | ((E ^ s10) & 3)) & 0xFF
    return k0, k1, k2


def program_decrypt(words, k0, k1, k2):
    rounds = (k2 >> 2) & 6 or 8
    f = f_variant(k2 & 3)
    m1 = ((k2 & 3) ^ k0) & 3
    m2 = ((k1 & 3) | 2) ^ m1
    # key schedule: 8 x fk -> 16 halfword subkeys
    K = []
    A, B, D = k0, k1, 0
    for _ in range(8):
        nb = fk(A, B ^ D)
        K += [nb >> 16, nb & 0xFFFF]
        D, A, B = A, B, nb
    out = []
    if len(words) & 1:
        words = list(words) + [0]
    for i in range(0, len(words), 2):
        L, R = words[i], words[i + 1]
        R ^= (K[1] << 16) | K[0]
        L ^= (K[3] << 16) | K[2]
        R ^= L
        for r in range(rounds):
            L, R = R, L ^ f(R, K[4 + r])
        L ^= R
        L ^= (K[4 + rounds + 1] << 16) | K[4 + rounds]
        R ^= (K[4 + rounds + 3] << 16) | K[4 + rounds + 2]
        o1, o2 = R, L
        out += [o1, o2]
        mutate(m1, K, o1, o2)
        mutate(m2, K, o1, o2)
    return out


def checksum(words):
    return sum((w >> 16) + (w & 0xFFFF) for w in words) & 0xFFFF


def parse(img):
    assert struct.unpack('>I', img[:4])[0] == MAGIC
    A, B, C, D, E, F, G = [x ^ m for x, m in zip(struct.unpack('>7H', img[4:18]), MASK)]
    ck, salt = struct.unpack('>HI', img[18:24])
    return dict(A=A, B=B, C=C, D=D, E=E, F=F, G=G, ck=ck, salt=salt)


def decrypt_image(img, s10, s11_nib, kernel=False):
    h = parse(img)
    n = h['A'] + h['B']
    body = list(struct.unpack('>%dI' % n, img[24:24 + 4 * n]))
    code, data = body[:h['A']], body[h['A']:]
    if kernel:
        k = kernel_key(s10, s11_nib)
        code, data = kernel_stream(code, k), kernel_stream(data, k)
    elif not h['G'] & 0x1000:
        k = program_key(s10, s11_nib, h['G'], h['E'], h['salt'])
        code = program_decrypt(code, *k)[:h['A']]
        data = program_decrypt(data, *k)[:h['B']]
    return h, code, data, checksum(code + data) == h['ck']



# Per-chip constants: s10[15:0], s11[27:24], descrambler XOR constant and lane map
# (canonical lane k = lane LANES[k] of (stored word ^ XOR)), program image address.
CHIPS = {
    'puzldama': (0x5D32, 0x3, 0x91C2C6FB, (11, 8, 12, 9, 4, 2, 5, 6, 10, 3, 7, 13, 14, 0, 1, 15), 0x203676),
    'tokkae':   (0x9E8E, 0xB, 0x6BFBB5B9, (12, 2, 6, 9, 13, 0, 5, 10, 8, 11, 3, 4, 14, 15, 7, 1), 0x2E85C4),
    'tkmmpzdm': (0x4924, 0xC, 0x88600EF4, (9, 14, 5, 1, 13, 2, 0, 6, 11, 15, 3, 7, 8, 10, 12, 4), 0x23F9AA),
    'daiskiss': (0x89EE, 0xD, 0x39556CC0, (9, 12, 1, 0, 6, 10, 3, 15, 7, 14, 2, 13, 4, 5, 8, 11), 0x2F8AAD),
    'tbyahhoo': (0x0424, 0xA, 0xDE78B8AE, (15, 4, 12, 2, 3, 13, 11, 1, 5, 8, 10, 0, 6, 14, 7, 9), 0x2FE747),
    'gokuparo': (0x8D8C, 0x3, 0x2C3EA1C4, (15, 11, 13, 14, 9, 3, 0, 7, 6, 1, 8, 5, 12, 10, 4, 2), 0x2F89E2),
    'dragoonj': (0x5963, 0xB, 0x049DB8E5, (4, 7, 9, 3, 14, 8, 6, 13, 5, 0, 15, 1, 11, 12, 2, 10), 0x250F02),
    'salmndr2': (0x1EC6, 0xA, 0xB3F135B3, (7, 8, 2, 4, 10, 14, 15, 6, 9, 1, 0, 12, 3, 5, 13, 11), 0x234EB0),
    'sexyparo': (0x896A, 0xE, 0x1886AE1D, tuple(range(16)), 0x2FBA11),
}


def descramble(w, xor, lanes):
    w ^= xor
    return sum(((w >> (2 * lanes[k])) & 3) << (2 * k) for k in range(16))


if __name__ == '__main__':
    import sys
    from escdis import dis
    s = sys.argv[1]
    s10, nib, xor, lanes, addr = CHIPS[s]
    rom = open(sys.argv[2], 'rb').read()
    for name, off, kern in (('kernel', 0xA6C, True), ('program', addr - 0x200000, False)):
        h, code, data, ok = decrypt_image(rom[off:], s10, nib, kernel=kern)
        print('; %s %s: checksum %s' % (s, name, 'ok' if ok else 'FAILED'))
        for i, w in enumerate(code):
            c = descramble(w, xor, lanes)
            print('%4d %08x  %s' % (i, c, dis(c, i)))
        for i, w in enumerate(data):
            print('D%-4d %08x' % (i, w))
