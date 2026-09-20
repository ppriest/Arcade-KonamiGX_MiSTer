#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read CPU-visible memory out of the running core, over JTAG.

    python scripts/memdump.py d20000 1000 debug/board/spriteram.bin
    python scripts/memdump.py c00000 200 -          # to stdout, as hex

gx_main carries a third bus master below the ESC and the CPU (ISSP instance
N): its source asks for a word address, it reads the four words there and
holds them on the probe. This drives that, a group at a time, and writes the
bytes in the CPU's order -- so a dump of 0xd20000 is the sprite list as
MAME's capture holds it, and the video benches can be fed the board's own
state instead of MAME's.

READ RAM ONLY. A register read can clear what it reports, and this goes
through the same decode the CPU does. The regions worth taking:

    c00000  work RAM, 128 KB -- the ESC's source list is in it
    d20000  sprite RAM, 4 KB -- the list the object DMA copies
    d00000  tilemap VRAM (banked: what the game last selected)
    d40000  palette

The core keeps running while it is read: four bus cycles a group, far fewer
than the ESC takes every frame.
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import read_issp  # noqa: E402

LINE = re.compile(r"^\s*dump ([0-9A-Fa-f]{6}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) "
                  r"([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4})\s*$")


def dump(addr, nbytes):
    """The bytes at `addr`, read from the board. Raises if the core did not
    answer for a group (the probe reports which address stalled)."""
    words = (nbytes + 1) // 2
    words = (words + 3) // 4 * 4
    r = read_issp.read("N", "dump", f"{addr:x}", str(words), capture=True)
    out, want = bytearray(), addr
    for ln in (r.stdout or "").splitlines():
        m = LINE.match(ln)
        if not m:
            if "stalled" in ln:
                raise RuntimeError(ln.strip())
            continue
        at = int(m.group(1), 16)
        if at != want:
            raise RuntimeError(f"group out of order: got {at:06x}, wanted {want:06x}")
        for w in m.groups()[1:]:
            out += int(w, 16).to_bytes(2, "big")
        want += 8
    if not out:
        raise RuntimeError("no groups read -- is this an instrumented build, and a game running?\n"
                           + (r.stdout or "")[-800:])
    return bytes(out[:nbytes])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addr", help="start, hex, word-aligned (d20000)")
    ap.add_argument("bytes", help="how many, hex (1000)")
    ap.add_argument("out", help="file to write, or - for hex on stdout")
    a = ap.parse_args()
    addr, n = int(a.addr, 16), int(a.bytes, 16)
    if addr & 1:
        sys.exit("start must be word-aligned")
    data = dump(addr, n)
    if a.out == "-":
        for i in range(0, len(data), 16):
            print(f"{addr + i:06x}  " + " ".join(f"{b:02x}" for b in data[i:i + 16]))
    else:
        p = Path(a.out)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        print(f"wrote {len(data)} bytes of {addr:06x} to {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
