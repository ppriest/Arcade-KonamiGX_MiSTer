#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build a region image from a set's ROM_START, and prove it against MAME.

    python scripts/build_rom_image.py daiskiss maincpu
        -> debug/daiskiss-rom/maincpu.bin   (the 8 MB region, as MAME holds it)

    python scripts/build_rom_image.py daiskiss maincpu --verify debug/daiskiss-boot/daiskiss_boot.trace
        -> also scores every read in a MAME boot trace against the image

The image is what the RTL and its benches load. It is built from the driver's
own ROM_START, read straight out of konamigx.cpp, never from a hand-written
table: LESSONS_LEARNED, "Treat the map-digit rule as mechanical and check it,
do not reason about it" -- every interleave Psikyo derived by reasoning was
wrong.

And it is PROVEN, not trusted. --verify compares the image against the data
MAME actually read at each address in a boot trace. That is the rule "Prove
the interleave against MAME's disassembly offline, before building", with a
trace in place of a disassembly. For daiskiss the program ROM scores
1,049,951 of 1,049,951 reads; the three wrong permutations of the same two
files score 12-21%. A wrong interleave cannot hide in that.

LOAD FORMS. Every form the in-scope sets use is in the FORMS table below,
reduced to MAME's own (group, skip, reverse) semantics rather than special-
cased, including konamigx.cpp's TILE_* and _48_WORD macros. GX_BIOS is
ROM_LOAD("300a01.34k", 0, 0x20000) from konamigx.zip, which the merged set
zips do NOT carry. Any other form is an ERROR rather than a silent omission.

WHAT HAS BEEN PROVEN, AND HOW. A form is trusted only once something has
checked it against MAME:

  maincpu (ROM_LOAD, ROM_LOAD32_WORD_SWAP)   --verify against a boot trace
  k056832 (TILE_WORD, TILE_BYTE)             the tile pixels scripts/
                                             render_model.py reproduces --
                                             the CPU never reads this region
                                             during boot, so no trace can
  k055673 (ROM_LOAD32_WORD, ROM_LOAD)        the sprite pixels render_model.py
                                             reproduces (daiskiss, five frames)
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path("E:/mame/src/mame/konami/konamigx.cpp")
BIOS = ("konamigx", "300a01.34k", 0x000000, 0x20000)


def num(s):
    s = s.strip()
    return int(s, 16) if s.lower().startswith("0x") else int(s, 0)


def parse(driver):
    src = driver.read_text(encoding="utf8", errors="replace")
    games = {}
    for m in re.finditer(r"^GAME\(\s*\d+,\s*(\w+),\s*(\w+),", src, re.M):
        games[m.group(1)] = m.group(2)
    blocks = dict(re.findall(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", src, re.S))
    return games, blocks


def region_loads(block, tag):
    """[(form, file, offset, length)] for one ROM_REGION of one ROM_START."""
    parts = re.split(r'ROM_REGION(?:16_BE|32_BE|64_BE|16_LE|32_LE)?\(\s*'
                     r'(0x[0-9a-fA-F]+|\d+)\s*,\s*"([^"]+)"[^)]*\)', block)
    for i in range(1, len(parts), 3):
        if parts[i + 1] != tag:
            continue
        size = num(parts[i])
        loads = []
        for line in parts[i + 2].splitlines():
            line = line.strip()
            if line.startswith("GX_BIOS"):
                loads.append(("BIOS",) + BIOS[1:])
                continue
            m = re.match(r'(\w+)\s*\(\s*"([^"]+)"\s*,\s*([^,]+),\s*([^,]+),', line)
            if m:
                loads.append((m.group(1), m.group(2), num(m.group(3)), num(m.group(4))))
        return size, loads
    raise SystemExit(f"no region {tag!r} in this ROM_START")


def zip_for(games, s):
    """The merged zip holding set `s`: its topmost non-BIOS ancestor."""
    while games.get(s) not in (None, "0", "konamigx"):
        s = games[s]
    return s


def stored_name(zips, fname, set_name):
    """The name a file has inside the merged zip: a clone's own files live
    under '<set>/', and an .mra part has to ask for it by that path."""
    for z in zips:
        names = {n.lower(): n for n in z.namelist()}
        for key in (f"{set_name}/{fname}".lower(), fname.lower()):
            if key in names:
                return names[key]
    return None


def read_file(zips, fname, want_len, set_name):
    """A file from the merged zip: a clone's own files live under '<set>/'."""
    name = stored_name(zips, fname, set_name)
    if name is not None:
        for z in zips:
            if name in z.namelist():
                data = z.read(name)
                if len(data) != want_len:
                    raise SystemExit(f"{fname}: {len(data)} bytes, ROM_START says {want_len}")
                return data
    raise SystemExit(f"{fname} not found in {[z.filename for z in zips]}")


# Every load form in the in-scope sets, as MAME's ROMX_LOAD flags reduce it:
# (group bytes, skip bytes, reverse). romload.cpp copies the file GROUP bytes
# at a time -- byte-reversed within the group if REVERSE -- then advances the
# destination by GROUP + SKIP. The konamigx.cpp macros are defined at the top
# of its ROM section; the standard ones are in emu/romentry.h.
FORMS = {
    "ROM_LOAD":             (1, 0, False),
    "BIOS":                 (1, 0, False),
    "ROM_LOAD16_BYTE":      (1, 1, False),   # ROM_SKIP(1)
    "ROM_LOAD32_BYTE":      (1, 3, False),   # ROM_SKIP(3)
    "ROM_LOAD32_WORD":      (2, 2, False),   # ROM_GROUPWORD | ROM_SKIP(2)
    "ROM_LOAD32_WORD_SWAP": (2, 2, True),    # ROM_GROUPWORD | ROM_REVERSE | ROM_SKIP(2)
    "ROM_LOAD64_WORD":      (2, 6, False),   # ROM_GROUPWORD | ROM_SKIP(6)
    # konamigx.cpp's own ROMX_LOAD macros
    "TILE_WORD_ROM_LOAD":   (4, 1, False),   # ROM_GROUPDWORD | ROM_SKIP(1)
    "TILE_BYTE_ROM_LOAD":   (1, 4, False),   # ROM_GROUPBYTE  | ROM_SKIP(4)
    "TILE_WORDS2_ROM_LOAD": (4, 2, False),   # ROM_GROUPDWORD | ROM_SKIP(2)
    "TILE_BYTES2_ROM_LOAD": (2, 4, False),   # ROM_GROUPWORD  | ROM_SKIP(4)
    "_48_WORD_ROM_LOAD":    (2, 4, False),   # ROM_GROUPWORD  | ROM_SKIP(4)
    "T1_PSAC6_ROM_LOAD":    (1, 2, False),   # ROM_GROUPBYTE  | ROM_SKIP(2): Type 1's CROM/HROM, 3 lanes
    "T1_PSAC8_ROM_LOAD":    (1, 3, False),   # ROM_GROUPBYTE  | ROM_SKIP(3): 4 lanes
}


def load_into(img, data, off, group, skip, reverse):
    """romload.cpp's copy loop: GROUP bytes at a time, then skip SKIP."""
    dst = off
    for k in range(0, len(data), group):
        chunk = data[k:k + group]
        if reverse:
            chunk = chunk[::-1]
        img[dst:dst + len(chunk)] = chunk
        dst += group + skip


def build(set_name, tag):
    games, blocks = parse(DRIVER)
    if set_name not in blocks:
        raise SystemExit(f"no ROM_START for {set_name}")
    size, loads = region_loads(blocks[set_name], tag)
    zips = [zipfile.ZipFile(REPO / "roms" / f"{zip_for(games, set_name)}.zip"),
            zipfile.ZipFile(REPO / "roms" / f"{BIOS[0]}.zip")]
    img = bytearray(size)
    for form, fname, off, length in loads:
        if form not in FORMS:
            raise SystemExit(f"{fname}: load form {form} is not handled -- add it to "
                             f"FORMS, and prove it before trusting it")
        data = read_file(zips, fname, length, set_name)
        load_into(img, data, off, *FORMS[form])
        print(f"  {form:<22} {fname:<16} @ {off:06X}  {length:#x}")
    return img


def verify(img, trace, lo, hi):
    """Score every read in [lo, hi) of a MAME boot trace against the image."""
    seen = {}
    for ln in open(trace, encoding="utf8"):
        if ln.startswith("#"):
            continue
        _, rw, addr, mask, data = ln.rstrip("\n").split("\t")
        a = int(addr, 16)
        if rw == "r" and lo <= a < hi:
            seen[(a & ~3, int(mask, 16))] = int(data, 16)
    ok = bad = 0
    first_bad = None
    for (a, m), d in sorted(seen.items()):
        v = int.from_bytes(img[a:a + 4], "big")
        if (v & m) == (d & m):
            ok += 1
        else:
            bad += 1
            first_bad = first_bad or (a, m, d, v)
    return ok, bad, first_bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("region", choices=["maincpu", "k056832", "k055673", "k054539", "soundcpu"])
    ap.add_argument("--verify", metavar="TRACE",
                    help="score this MAME boot trace's ROM reads against the image")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    img = build(a.set, a.region)
    out = Path(a.out) if a.out else REPO / "debug" / f"{a.set}-rom" / f"{a.region}.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(img)
    print(f"-> {out}  ({len(img):#x} bytes)")

    if a.verify:
        rc = 0
        for name, lo, hi in (("BIOS", 0x000000, 0x020000),
                             ("program", 0x200000, 0x400000),
                             ("data", 0x400000, 0x800000)):
            ok, bad, fb = verify(img, a.verify, lo, hi)
            if ok + bad == 0:
                print(f"  {name:<8} no reads in the trace")
                continue
            print(f"  {name:<8} {ok:>8} / {ok + bad:<8} reads agree"
                  + ("" if not bad else f"   FIRST MISMATCH at {fb[0]:06X} "
                     f"mask {fb[1]:08X}: MAME {fb[2]:08X}, image {fb[3]:08X}"))
            rc |= bool(bad)
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
