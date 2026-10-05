# SPDX-License-Identifier: GPL-3.0-or-later
"""056734 state for a save state that has none (one converted from MAME, whose ESC is C):
the chip as the game leaves it after start-up -- the kernel running, RESET and the
set's program LOADed under the handle the game's packets use -- in the three
sections of rtl/gx_ss_layout.svh (esch, escl, escr).

The packets are posted in a scratch area the game never sees (SCRATCH). RESET's
reply buffer is put at the program ROM: the kernel writes its reply there in the
model only, and afterwards refreshes it only while the buffer starts with the
magic, which ROM never does on the board.
"""
import struct

import chip as model

MAGIC = 0xFEF724FB
SCRATCH = 0xE80000              # unmapped on the GX bus
HANDLE = 0x00010014             # every title's library uses this one (captures of all nine)
# set -> (the chip whose key it uses, its program image), docs/ESC.md
SETS = {
    'daiskiss': ('daiskiss', 0x2F8AAD), 'crzcross': ('puzldama', 0x203676), 'puzldama': ('puzldama', 0x203676),
    'gokuparo': ('gokuparo', 0x2F89E2), 'fantjour': ('gokuparo', None), 'fantjoura': ('gokuparo', None),
    'mtwinbee': ('tbyahhoo', 0x2FE67B), 'tbyahhoo': ('tbyahhoo', 0x2FE747),
    'sexyparo': ('sexyparo', 0x2FBA11), 'sexyparoa': ('sexyparo', 0x2FB883),
    'tokkae': ('tokkae', 0x2E85C4), 'tkmmpzdm': ('tkmmpzdm', 0x23F9AA),
    'dragoona': ('dragoonj', 0x251C78), 'dragoonj': ('dragoonj', 0x250F02),
    'salmndr2': ('salmndr2', 0x234EB0), 'salmndr2a': ('salmndr2', 0x234E50),
}


def handle_of(wram):
    """The handle in the work RAM's RUN packets (magic, handle, command 1), if any;
    otherwise HANDLE is used."""
    seen = {}
    for o in range(0, len(wram) - 16, 2):
        if struct.unpack_from('>I', wram, o)[0] == MAGIC and wram[o + 8] == 1:
            h = struct.unpack_from('>I', wram, o + 4)[0]
            seen[h] = seen.get(h, 0) + 1
    return max(seen, key=seen.get) if seen else None


def packet(host, at, handle, cmd, a1, a2):
    for i, b in enumerate(struct.pack('>IIBBHII', MAGIC, handle, cmd, 0, 0, a1, a2)):
        dict.__setitem__(host, at + i, b)


def esc_sections(setname, region, wram):
    """region: MAME's maincpu region (BIOS at 0, program at 0x200000); wram: 128 KB.
    Returns (esch, escl, escr) as lists of 16-bit words, or None if the set has no chip."""
    if setname not in SETS:
        return None
    chipset, image = SETS[setname]
    host = model.Host()
    for i, b in enumerate(region[:0x400000]):
        dict.__setitem__(host, i, b)
    for i, b in enumerate(wram):
        dict.__setitem__(host, 0xC00000 + i, b)
    c = model.Chip(chipset, host, bytes(region[0x200000:0x400000]))
    c.run_until_idle()
    handle = handle_of(wram) or HANDLE
    if image is not None:
        packet(host, SCRATCH, 0, 5, 0x200000, 0)                       # RESET
        c.post(SCRATCH)
        assert host.get(SCRATCH + 9) == 2, 'RESET failed'
        packet(host, SCRATCH + 0x40, handle, 2, image, SCRATCH + 0x80)  # LOAD
        c.post(SCRATCH + 0x40)
        assert host.get(SCRATCH + 0x49) == 2, 'LOAD failed'
    lm = [c.local[i] for i in range(0x1000)]
    esch = [w >> 16 for w in lm]
    escl = [w & 0xFFFF for w in lm]
    r = c.r
    regs = []
    for i in range(64):
        regs += [r[i] >> 16, r[i] & 0xFFFF]
    regs += [c.pc & 0xFFFF]
    for n in (32, 33, 38, 40, 39):                                       # s0 s1 s6 s8 mailbox
        regs += [r[n] >> 16, r[n] & 0xFFFF]
    regs += [(c.Z << 3) | (c.N << 2) | (c.C << 1) | c.V, 1]
    return esch, escl, regs
