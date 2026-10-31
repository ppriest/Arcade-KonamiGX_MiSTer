#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CPU-visible memory read out of the running core over JTAG, as a .bin.

    probe_issp(core="KonamiGX", instance="N", action="dump", value="d20000 2048")
    python scripts/memdump.py --from-log <its log_path> debug/board/spriteram.bin
    python scripts/memdump.py --from-log - -          # log on stdin, hex on stdout

The dump hook's value is the start byte address (hex) and the number of
16-bit words (decimal), read in groups of four.

gx_main carries a third bus master below the ESC and the CPU (ISSP instance
N): its source asks for a word address, it reads the four words there and
holds them on the probe. The dump hook (scripts/issp_hooks.tcl) drives that,
a group at a time; this turns its lines into the bytes in the CPU's order -- so a dump of 0xd20000 is the sprite list as
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

# probe_issp prefixes every line <core>|<build>|<set>|
LINE = re.compile(r"^([^|]*)\|[^|]*\|[^|]*\|\s*dump ([0-9A-Fa-f]{6}) ([0-9A-Fa-f]{4}) "
                  r"([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4})\s*$")


def parse(text):
    """(start address, bytes) from the dump hook's lines. Raises on another
    core's reading, a stalled group or a gap."""
    out, start, want = bytearray(), None, None
    for ln in text.splitlines():
        if "stalled" in ln:
            raise RuntimeError(ln.strip())
        m = LINE.match(ln)
        if not m:
            continue
        if not m.group(1).startswith("KonamiGX"):
            raise RuntimeError(f"reading is from {m.group(1)}, not KonamiGX: {ln.strip()}")
        at = int(m.group(2), 16)
        if start is None:
            start = want = at
        if at != want:
            raise RuntimeError(f"group out of order: got {at:06x}, wanted {want:06x}")
        for w in m.groups()[2:]:
            out += int(w, 16).to_bytes(2, "big")
        want += 8
    if not out:
        raise RuntimeError("no dump lines -- is this an instrumented build, and a game running?")
    return start, bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-log", required=True,
                    help="probe_issp's log_path, or - for stdin")
    ap.add_argument("out", help="file to write, or - for hex on stdout")
    a = ap.parse_args()
    text = sys.stdin.read() if a.from_log == "-" else         Path(a.from_log).read_text(encoding="utf-8", errors="replace")
    addr, data = parse(text)
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
