#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""rtl/gx_esc.v's konamigx_esc_alert mode 1 against a capture (sim/gx_esc_tb).

    python scripts/check_gx_esc.py salmndr2-f4800

The capture's work RAM goes in, its sprite RAM is the expectation: MAME ran
the same C on the same work RAM that frame (scripts/esc_sal2.py reproduces
every capture so). Word 7 of each sprite is left as it was, as MAME does.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "obj_verilator" / "gx_esc_run"


def words(b):
    return [int.from_bytes(b[2 * i:2 * i + 2], "big") for i in range(len(b) // 2)]


def main():
    cap = REPO / "debug" / sys.argv[1]
    OUT.mkdir(parents=True, exist_ok=True)
    wram = words((cap / "workram.bin").read_bytes())
    spr = words((cap / "spriteram.bin").read_bytes())
    (OUT / "wram.hex").write_text("".join(f"{w:04x}\n" for w in wram))
    # the sprite RAM before the command: the capture's word 7s, the rest junk,
    # so a word the ESC fails to write shows
    before = [w if i & 7 == 7 else 0xdead for i, w in enumerate(spr)]
    (OUT / "spr.hex").write_text("".join(f"{w:04x}\n" for w in before))
    rel = lambda p: str(p.relative_to(REPO)).replace("\\", "/")
    sys.path.insert(0, str(REPO / "scripts"))
    import check_gx_obj
    r = subprocess.run([check_gx_obj.GIT_BASH, "scripts/run_verilator.sh", "gx_esc_tb", "+SAL2=1",
                        f"+WRAM={rel(OUT / 'wram.hex')}", f"+SPR={rel(OUT / 'spr.hex')}",
                        f"+OUT={rel(OUT / 'out.hex')}"], cwd=REPO, capture_output=True, text=True)
    print((r.stdout + r.stderr).strip().splitlines()[-3:])
    got = [int(x, 16) for x in (OUT / "out.hex").read_text().split()]
    # the words MAME writes: every word but 7 of each sprite built, word 0 of
    # each slot left over (the rest keep an earlier frame's), per esc_sal2.py
    import esc_sal2

    class Rec(list):
        def __setitem__(self, i, v):
            written.add(i)
            super().__setitem__(i, v)
    written = set()
    esc_sal2.esc_mode1((cap / "workram.bin").read_bytes(), Rec(spr[:]))
    diff = [i for i in sorted(written) if got[i] != spr[i]]
    print(f"{sys.argv[1]}: {len(written) - len(diff)} of {len(written)} words MAME writes are the same")
    for i in diff[:16]:
        print(f"  sprite {i // 8} word {i & 7}: RTL {got[i]:04x}, MAME {spr[i]:04x}")
    return 0 if not diff else 1


if __name__ == "__main__":
    sys.exit(main())
