#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""konamigx.cpp's generate_sprites, in Python, over a capture.

    python scripts/esc_model.py daiskiss-f2400

MAME builds the sprite list in C on the CPU's write to 0xcc0000; rtl/gx_esc.v
reproduces that C in RTL. This is the same C again, so the two can be checked
against a third thing: the list MAME's capture holds is what its own
generate_sprites wrote, so the model is right when it reproduces it.

It reads the entries from the capture's work RAM and the piece lists from the
ROM image, and reports how many pieces each entry walks -- which is what the
board's probe says has run away (docs/ROADMAP.md).
"""
import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

SRC, DST, COUNT = 0xc00000, 0xd20000, 0x100


# what the packed SDRAM image backs: the BIOS, then 0x200000 up to its length
BACKED = ((0, 0x20000), (0x200000, 0x3e0000))


class Mem:
    """The CPU's space, as far as generate_sprites reads it: work RAM from the
    capture, ROM from the image, everything else zero.

    With `img`, the .mra's SDRAM image, a read the packed image does not back
    answers with what lies at that offset in SDRAM -- the tile ROM, which
    follows the CPU image -- which is what the board did before gx_main
    answered those reads with zero. It is the difference between an entry
    walking eight sprite pieces and walking sixty-five thousand."""

    def __init__(self, cap, rom, img=None):
        self.wram = (cap / "workram.bin").read_bytes()
        self.rom = rom
        self.img = img

    def w(self, a):
        if 0xc00000 <= a < 0xc00000 + len(self.wram):
            return struct.unpack_from(">H", self.wram, a - 0xc00000)[0]
        if self.img is not None and a < 0x800000                 and not any(lo <= a < hi for lo, hi in BACKED):
            p = a - 0x1e0000 if a >= 0x200000 else a
            return struct.unpack_from(">H", self.img, p)[0] if p + 2 <= len(self.img) else 0
        if a < len(self.rom):
            return struct.unpack_from(">H", self.rom, a)[0]
        return 0


def generate(mem, src=SRC, count=COUNT, report=None):
    out = {}                      # sprite slot -> the seven words
    ents = []
    for i in range(count):
        adr = src + 0x100 * i
        if not mem.w(adr + 2):
            continue
        pri = mem.w(adr + 28)
        if pri < 256:
            ents.append((pri, adr, i))

    scount, spr = 0, DST
    for pri, adr, i in ents:
        s = (mem.w(adr) << 16) | mem.w(adr + 2)
        glob_x, glob_y = mem.w(adr + 4), mem.w(adr + 8)
        flip_x = 0x1000 if mem.w(adr + 12) else 0
        flip_y = 0x2000 if mem.w(adr + 14) else 0
        glob_f = flip_x | (flip_y ^ 0x2000)
        zoom_x, zoom_y = mem.w(adr + 20) or 0x40, mem.w(adr + 22) or 0x40
        cval, cmask, cset, crot = 0, 0xffff, 0, 0
        v = mem.w(adr + 24)
        if v & 0x8000:
            cmask, cval = 0xf3ff, cval | (v & 3) << 10
        v = mem.w(adr + 26)
        if v & 0x8000:
            cmask &= 0xfcff; cval |= (v & 3) << 8
        v = mem.w(adr + 18)
        if v & 0x8000:
            cmask &= 0xff1f; cval |= v & 0xe0
        v = mem.w(adr + 16)
        if v & 0x8000:
            cset = v & 0x1f
        if v & 0x4000:
            crot = v & 0x1f
        if not (0x200000 <= s < 0xd00000):
            continue
        count2 = mem.w(s)
        if report is not None:
            report.append((i, s, count2))
        s += 2
        walked = 0
        while count2:
            idx, flip, col = mem.w(s), mem.w(s + 2), mem.w(s + 4)
            y, x = mem.w(s + 6), mem.w(s + 8)
            y = y - 0x10000 if y & 0x8000 else y
            x = x - 0x10000 if x & 0x8000 else x
            walked += 1
            if idx == 0xffff:
                s = (flip << 16) | col
                if 0x200000 <= s < 0xd00000:
                    continue
                break
            if zoom_y != 0x40:
                y = int(y * 0x40 / zoom_y)
            if zoom_x != 0x40:
                x = int(x * 0x40 / zoom_x)
            x = glob_x - x if flip_x else glob_x + x
            x = x - 0x10000 if x & 0x8000 else x
            if -256 <= x <= 512 + 32:
                y = glob_y - y if flip_y else glob_y + y
                y = y - 0x10000 if y & 0x8000 else y
                if -256 <= y <= 512:
                    c = (col & cmask) | cval
                    if cset:
                        c = (c & 0xffe0) | cset
                    if crot:
                        c = (c & 0xffe0) | ((c + crot) & 0x1f)
                    out[spr] = ((flip ^ glob_f) | pri, idx, y & 0xffff, x & 0xffff,
                                zoom_y, zoom_x, c)
                    spr += 16
                    scount += 1
                    if scount == 256:
                        return out, scount, ents
            count2 -= 1
            s += 10
    while scount < 256:
        out[spr] = (scount,)
        scount += 1
        spr += 16
    return out, scount, ents


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--board", action="store_true",
                    help="read unbacked ROM space from the .mra image, as the board did")
    a = ap.parse_args()
    cap = REPO / "debug" / a.capture
    game = (cap / "manifest.txt").read_text().split()[1]
    rom = (REPO / "debug" / f"{game}-rom" / "maincpu.bin").read_bytes()
    img = None
    if a.board:
        import xml.etree.ElementTree as ET
        import mra as mra_lib
        m = None
        for q in (REPO / "releases").rglob("*.mra"):
            r0 = next((r for r in ET.parse(q).getroot().findall("rom")
                       if r.get("index") == "0"), None)
            if r0 is not None and r0.get("zip", "").split("|")[0] == f"{game}.zip":
                m = q
                break
        if m is None:
            sys.exit(f"no .mra whose first zip is {game}.zip -- run scripts/build_mra.py")
        r0 = next(r for r in ET.parse(m).getroot().findall("rom") if r.get("index") == "0")
        img = mra_lib.build_image(m, [REPO / "roms" / z for z in r0.get("zip").split("|")])
    mem = Mem(cap, rom, img)
    report = []
    out, scount, ents = generate(mem, report=report)
    print(f"{len(ents)} entries with a piece list, {scount} sprite slots written"
          + ("  (unbacked ROM read from the SDRAM image)" if a.board else ""))
    print(f"worst piece count {max((c for _, _, c in report), default=0)}, "
          f"{sum(c for _, _, c in report)} pieces in all")
    for i, s, c in report:
        flag = "  <-- runaway" if c > 512 else ""
        print(f"  entry {i:3d}  set {s:06x}  pieces {c:5d}{flag}")

    # the list MAME's own generate_sprites left in the capture
    ref = (cap / "spriteram.bin").read_bytes()
    same = bad = 0
    for slot, words in sorted(out.items()):
        off = slot - DST
        got = struct.unpack_from(">8H", ref, off)
        if len(words) == 1:
            ok = got[0] == words[0]
        else:
            ok = got[:7] == words
        same += ok
        if not ok and bad < 6:
            print(f"  slot {off // 16:3d}: model {words}, capture {got[:7]}")
            bad += 1
    print(f"{same} of {len(out)} slots match MAME's own list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
