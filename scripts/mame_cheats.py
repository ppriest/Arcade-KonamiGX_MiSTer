#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) Paul Priest
"""MAME cheats (Pugsy's XML, mamecheat.co.uk) to the .mra's <cheats> codes.

    python scripts/mame_cheats.py daiskiss              # what converts, what does not
    python scripts/mame_cheats.py daiskiss --mra        # the <cheats> block

The cheats come from <set>.xml in MAME's cheat path: a directory, or cheat.7z /
cheat.zip there (MAME_DIR, then `cheatpath` in mame.ini). Each <cheat> whose
scripts only store constants into the main CPU's work RAM becomes codes for
rtl/cheat/cheatengine.sv, which replaces the value as the CPU reads it:

    maincpu.pb@C08123=03                         replace a byte (pw, pd: word, long)
    maincpu.pb@C08123=maincpu.pb@C08123|80       OR   (& for AND)

A cheat with a <parameter> list becomes one cheat per item ("Select Stage" ->
"Select Stage: 3"). A "run" script is what the engine does anyway; an "on"
script, which MAME runs once, becomes the same constant held while the cheat
is on -- for a stage select that holds the stage, which the README says.
Anything else (conditions, temporary variables, arithmetic, other CPUs, ROM
patches) is skipped and listed.

A code is 16 bytes: flags (method << 8 | size << 4 | compare), address,
compare, data, big-endian (rtl/cheat/PROVENANCE.md). The engine matches
aligned codes only, so a long not on a 4-byte boundary is two words and a
word at an odd address two bytes.
"""
import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WRAM = (0xC00000, 0xC20000)
MAX_CODES = 16                  # gx_main's cheatengine MAX_CODES

ACT = re.compile(r"^\s*maincpu\.p([bwd])@([0-9A-Fa-f]+)\s*=\s*(.+?)\s*$")
OP = re.compile(r"^maincpu\.p([bwd])@([0-9A-Fa-f]+)\s*([|&])\s*(?:0x)?([0-9A-Fa-f]+)$")
SIZE = {"b": 1, "w": 2, "d": 4}


def read_7z(arc, member):
    """A member of a .7z: py7zr if installed, else libarchive's tar (Windows' own tar.exe,
    or bsdtar), which reads 7z. None if it is not there."""
    try:
        import py7zr
    except ImportError:
        tar = shutil.which("bsdtar") or Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32" / "tar.exe"
        if not Path(tar).exists():
            sys.exit(f"{arc}: reading a 7z needs `pip install py7zr`, bsdtar, or the archive unpacked")
        r = subprocess.run([str(tar), "-xOf", str(arc), member], capture_output=True)
        return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else None
    with py7zr.SevenZipFile(arc) as z:
        names = [n for n in z.getnames() if Path(n).name == member]
        return z.read(names)[names[0]].read().decode("utf-8", errors="replace") if names else None


def cheat_xml(setname):
    """The set's cheat XML text, from MAME's cheat path."""
    sys.path.insert(0, str(REPO / "scripts"))
    import mame_sta
    mdir = mame_sta.mame_exe().parent
    cp = "cheat"
    ini = mdir / "mame.ini"
    if ini.exists():
        for ln in ini.read_text(errors="replace").splitlines():
            if ln.startswith("cheatpath"):
                cp = ln.split(None, 1)[1].strip()
    base = Path(os.environ.get("MAME_CHEATS") or (mdir / cp))
    for d in (base, base.parent / "cheat"):
        f = d / f"{setname}.xml"
        if f.exists():
            return f.read_text(encoding="utf-8", errors="replace")
    for arc in (base.with_suffix(".zip"), base.with_suffix(".7z"), base / "cheat.zip", base / "cheat.7z",
                mdir / "cheat.zip", mdir / "cheat.7z"):
        if not arc.exists():
            continue
        if arc.suffix == ".zip":
            with zipfile.ZipFile(arc) as z:
                for n in z.namelist():
                    if Path(n).name == f"{setname}.xml":
                        return z.read(n).decode("utf-8", errors="replace")
        else:
            text = read_7z(arc, f"{setname}.xml")
            if text is not None:
                return text
    return None


def value(expr, param):
    expr = expr.strip()
    if expr.lower() == "param":
        return param
    m = re.fullmatch(r"(?:0x)?([0-9A-Fa-f]+)", expr)
    return int(m.group(1), 16) if m else None


def codes_for(size, addr, method, val):
    """[(flags, addr, compare, data)], split to the engine's alignments."""
    if size == 4 and addr % 4:
        return codes_for(2, addr, method, val >> 16) + codes_for(2, addr + 2, method, val & 0xFFFF)
    if size == 2 and addr % 2:
        return codes_for(1, addr, method, val >> 8) + codes_for(1, addr + 1, method, val & 0xFF)
    return [((method << 8) | (size << 4), addr, 0, val & ((1 << (8 * size)) - 1))]


def convert(cheat, param=None):
    """A <cheat>'s codes, or a reason it does not convert."""
    out = []
    for sc in cheat.findall("script"):
        state = sc.get("state", "run")
        if state == "off":
            continue
        if state not in ("run", "on", "change"):
            return None, f"script state {state}"
        for a in sc.findall("action"):
            if a.get("condition"):
                return None, "a condition"
            for part in (a.text or "").split(","):
                if not part.strip():
                    continue
                m = ACT.match(part)
                if not m:
                    return None, f"not a constant store: {part.strip()}"
                size, addr, rhs = SIZE[m.group(1)], int(m.group(2), 16), m.group(3)
                if not WRAM[0] <= addr < WRAM[1]:
                    return None, f"address {addr:06x} outside work RAM"
                op = OP.match(rhs.replace(" ", ""))
                if op and SIZE[op.group(1)] == size and int(op.group(2), 16) == addr:
                    method, v = (1 if op.group(3) == "|" else 2), int(op.group(4), 16)
                else:
                    method, v = 0, value(rhs, param)
                    if v is None:
                        return None, f"an expression: {rhs}"
                out += codes_for(size, addr, method, v)
    if not out:
        return None, "no stores"
    if len(out) > MAX_CODES:
        return None, f"{len(out)} codes, the core holds {MAX_CODES}"
    return out, None


def cheats(setname):
    """[(name, codes)], [(name, reason)]"""
    text = cheat_xml(setname)
    if text is None:
        sys.exit(f"no cheats for {setname} in MAME's cheat path (MAME_CHEATS, or cheatpath in mame.ini)")
    root = ET.fromstring(text)
    good, bad = [], []
    for c in root.iter("cheat"):
        desc = (c.get("desc") or "").strip()
        if not desc or not c.findall("script"):
            continue                                     # a heading or a note
        par = c.find("parameter")
        if par is not None:
            items = par.findall("item")
            if not items:
                bad.append((desc, "a ranged parameter"))
                continue
            for it in items:
                v = value(it.get("value", ""), None)
                codes, why = convert(c, v)
                name = f"{desc}: {(it.text or '').strip()}"
                (good.append((name, codes)) if codes else bad.append((name, why)))
        else:
            codes, why = convert(c)
            (good.append((desc, codes)) if codes else bad.append((desc, why)))
    return good, bad


def mra_block(good, indent="    "):
    if not good:
        return ""
    w = max(len(n) for n, _ in good) + 2
    lines = [f'{indent}<cheats size="16" max="{MAX_CODES}">']
    for name, codes in good:
        hexs = " ".join(f"{f:08X} {a:08X} {c:08X} {d:08X}" for f, a, c, d in codes)
        nm = name.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")
        lines.append(f'{indent}    <cheat name="{nm}"{" " * (w - len(name) - 2)}>{hexs}</cheat>')
    lines.append(f"{indent}</cheats>")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set")
    ap.add_argument("--mra", action="store_true", help="print the <cheats> block")
    a = ap.parse_args()
    good, bad = cheats(a.set)
    if a.mra:
        sys.stdout.write(mra_block(good))
        return
    print(f"{a.set}: {len(good)} cheats convert, {len(bad)} do not")
    for n, codes in good:
        print(f"  + {n}  ({len(codes)} code{'s' if len(codes) > 1 else ''})")
    for n, why in bad:
        print(f"  - {n}: {why}")


if __name__ == "__main__":
    main()
