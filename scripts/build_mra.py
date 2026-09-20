#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files, and prove each one byte for byte.

    python scripts/build_mra.py                # every set -> releases/
    python scripts/build_mra.py daiskiss       # one set
    python scripts/build_mra.py --check        # verify only, write nothing
    python scripts/build_mra.py --cfg          # print rtl/gx_board_cfg.sv's table

WHAT AN .mra CARRIES, AND WHERE EACH PART IS PROVEN

The ROM image is the SDRAM download stream rtl/memory/gx_sdram_top.sv
expects, laid out by rtl/gx_board_cfg.sv's arm for the set's mod byte (the
table this script prints with --cfg; building an .mra checks the arm in the
file against the ROM_START, so the RTL and the .mra cannot drift apart
silently). Per region:

  maincpu   the CPU's window packed: the BIOS at 0, then the loads at
            0x200000 and up moved down by 0x1e0000
  k056832   MAME's 5-byte rows as a four-byte part then a one-byte part
            (each the region's rows * 4 and * 1): the RTL spreads the rows
            to 8 bytes on the way in, so a row is one SDRAM granule
  k055673   MAME's region as it is: already a four-byte part then a one-byte
            part
  sound     not yet (Phase 3)

Nothing here reasons about interleave map digits (docs/LESSONS_LEARNED.md):
each group of loads is tried against the region image scripts/
build_rom_image.py builds from the driver's ROM_START -- proven against
MAME's own reads -- and the map that reproduces it is the one written. The
finished .mra is then re-read with scripts/mra.py (mra-tools-c's semantics)
and the whole image compared with the expected stream.

The DIP switches come from the driver's INPUT_PORTS (scripts/extract_dips.py,
from Arcade-Seta_MiSTer) with that core's rules, each one learned on
hardware: a <dip>'s bits is a range "first,last"; a comma in a name or a
setting splits the OSD list; the OSD line is 28 columns; PORT_DIPUNUSED
still sets its default bit; and the <buttons> names are POSITIONAL, bit 4+i,
so Start and Coin sit where KonamiGX.sv reads them whatever the button
count. Titles become filenames with the characters a filesystem refuses
replaced, not dropped.
"""
import argparse
import itertools
import re
import sys
import zipfile
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_rom_image as bri     # noqa: E402
import extract_dips as ed         # noqa: E402
import mra as mra_lib             # noqa: E402

REPO = bri.REPO
RTL_CFG = REPO / "rtl" / "gx_board_cfg.sv"
OUT_DIR = REPO / "releases"
MB = 1 << 20

# The sets the core takes today (5 bpp tiles as TILE_WORD + TILE_BYTE, 5 bpp
# sprites as two ROM_LOAD32_WORD and a ROM_LOAD), in mod-byte order. The
# other Type 2 sets (dragoonj: 4 bpp sprites; tokkae, tkmmpzdm, salmndr2:
# 6 bpp; le2, winspike: 8 bpp) wait for their video paths, and their .mra
# layouts with them.
SETS = ["daiskiss", "crzcross", "puzldama", "fantjour", "fantjoura", "gokuparo",
        "mtwinbee", "tbyahhoo", "sexyparo", "sexyparoa"]

# KonamiGX.sv reads B1-B3 at joystick bits 4-6, Start 10, Coin 11, Pause 12,
# Service 13; every set here has three buttons. `names` is positional ("-"
# keeps a bit unused); Main_MiSTer applies `default` to the NAMED buttons
# only, in order, so it has one pad button per name and none for a "-". A
# default with ten entries put the pad's Start on Service (Twin Bee entered
# service mode on Start) -- the Seta .mra files have it right.
BUTTONS = 'names="Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause,Service" default="A,B,X,Start,Select,L,R" count="3"'

OSD_COLS = 28      # MiSTer draws " name:" padded to 28 columns, the value right-aligned


def esc(s):
    return escape(str(s), {'"': "&quot;"})


def mra_filename(title):
    """Characters a filesystem will not take are replaced, not dropped."""
    out = title.replace(" / ", " - ").replace("/", "-")
    for c in '<>:"\\|?*':
        out = out.replace(c, "")
    return " ".join(out.split()) + ".mra"


def game_lines():
    """setname -> (year, parent, input block, title, manufacturer) from GAME()."""
    src = bri.DRIVER.read_text(encoding="utf8", errors="replace")
    out = {}
    for m in re.finditer(r'^GAME\(\s*(\d+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),[^,]*,[^,]*,\s*ROT\d+,\s*"([^"]*)",\s*"([^"]*)"',
                         src, re.M):
        out[m.group(2)] = dict(year=m.group(1), parent=m.group(3), machine=m.group(4),
                               inputs=m.group(5), manufacturer=m.group(6), title=m.group(7))
    return out


# ---------------------------------------------------------------- layout
def layout(set_name, blocks):
    """The set's arm of gx_board_cfg.sv: bases at 1 MB, each region after the
    previous one's spread size. Sizes are the DECLARED region sizes: the
    game may address the whole region."""
    ms, ml = bri.region_loads(blocks[set_name], "maincpu")
    ts, _ = bri.region_loads(blocks[set_name], "k056832")
    os_, _ = bri.region_loads(blocks[set_name], "k055673")
    ext = 0
    for form, f, off, ln in ml:
        g, sk, _ = bri.FORMS[form]
        ext = max(ext, off + ln * (g + sk) // g)
    if any(0x20000 <= l[2] < 0x200000 for l in ml):
        raise SystemExit(f"{set_name}: a maincpu load between 0x20000 and 0x200000")
    packed = 0x20000 + max(0, ext - 0x200000)
    # k056832: 5-byte rows through the region. k055673: the four-byte part
    # is (MB / 5) * 4 MB and the fifth bytes follow, MAME's k055673.cpp
    # split (a 6 MB region is 4 MB + 1 MB used, the rest unread)
    tr = ts // 5
    orow = ((os_ >> 20) // 5) << 20
    up = lambda x: (x + MB - 1) // MB * MB
    tb = up(packed)
    ob = tb + up(tr * 8)
    end = ob + up(orow * 8)
    if end > 32 * MB:
        raise SystemExit(f"{set_name}: {end / MB:.1f} MB does not fit the 32 MB module")
    return dict(tile_base=tb, obj_base=ob, tile_size4=tr * 4, obj_size4=orow * 4, end=end)


def cfg_arm(mod, set_name, lo):
    return (f"        8'd{mod}:{' ' * (3 - len(str(mod)))}begin tile_base = 26'h{lo['tile_base']:07x}; "
            f"obj_base = 26'h{lo['obj_base']:07x}; tile_size4 = 24'h{lo['tile_size4']:06x}; "
            f"obj_size4 = 24'h{lo['obj_size4']:06x}; end  // {set_name}")


def rtl_arm(mod):
    """gx_board_cfg.sv's arm for a mod byte, as a dict, or None."""
    src = RTL_CFG.read_text(encoding="utf8")
    m = re.search(rf"8'd{mod}:\s*begin\s*tile_base = 26'h([0-9a-f]+); obj_base = 26'h([0-9a-f]+); "
                  rf"tile_size4 = 24'h([0-9a-f]+); obj_size4 = 24'h([0-9a-f]+); end", src)
    if not m:
        return None
    return dict(tile_base=int(m.group(1), 16), obj_base=int(m.group(2), 16),
                tile_size4=int(m.group(3), 16), obj_size4=int(m.group(4), 16))


# ---------------------------------------------------------------- the stream
class Stream:
    """The .mra's <rom index="0"> body and the bytes it should produce."""

    def __init__(self):
        self.lines, self.data, self.pos = [], bytearray(), 0

    def fill_to(self, at):
        if at < self.pos:
            raise SystemExit(f"stream overlap at {at:#x} (pos {self.pos:#x})")
        if at > self.pos:
            n = at - self.pos
            self.lines.append(f'        <part repeat="{n}">00</part>')
            self.data += bytes(n)
            self.pos = at

    @staticmethod
    def crc(data):
        return f"{zlib.crc32(data) & 0xffffffff:08x}"

    def part(self, at, fname, data, comment=None):
        # fname is the name INSIDE the zip: a clone's own files live under
        # '<set>/' in a merged set, and Main_MiSTer looks for exactly this
        self.fill_to(at)
        self.lines.append(f'        <part name="{fname}" crc="{self.crc(data)}"/>'
                          + (f"  <!-- {comment} -->" if comment else ""))
        self.data += data
        self.pos += len(data)

    def interleave(self, at, bits, parts, data):
        """parts: (name, map, the part's own bytes) -- the bytes are for the crc"""
        self.fill_to(at)
        self.lines.append(f'        <interleave output="{bits}">')
        for fname, m, d in parts:
            self.lines.append(f'            <part name="{fname}" crc="{self.crc(d)}" map="{m}"/>')
        self.lines.append('        </interleave>')
        self.data += data
        self.pos += len(data)


def candidate_maps(width, group):
    """Every map string of `width` digits with `group` non-zero digits in one
    contiguous block, the digits 1..group in any order."""
    out = []
    for start in range(0, width - group + 1):
        for perm in itertools.permutations(range(1, group + 1)):
            m = ["0"] * width
            for k, d in enumerate(perm):
                m[start + k] = str(d)
            out.append("".join(m))
    return out


def pick_maps(datas, bits, truth):
    """The maps that make mra-tools-c's interleave of `datas` equal `truth`."""
    width = bits // 8
    group = width // len(datas)
    cands = candidate_maps(width, group)
    for maps in itertools.product(cands, repeat=len(datas)):
        used = [set(i for i, c in enumerate(m) if c != "0") for m in maps]
        if any(a & b for a, b in itertools.combinations(used, 2)):
            continue
        if mra_lib.interleave(list(zip(datas, maps)), bits) == truth:
            return list(maps)
    raise SystemExit("no candidate map reproduces this group -- add the form and prove it")


def groups_of(loads):
    """Loads that interleave into one word, keyed by word base."""
    by_base = {}
    for form, fname, off, length in loads:
        group, skip, _ = bri.FORMS[form]
        word = group + skip
        base = off - off % word if skip else off
        by_base.setdefault((base, form, length), []).append((form, fname, off, length))
    return sorted(by_base.items())


def emit_loads(st, zips, set_name, loads, truth, region_off, stream_base, region_end):
    """Emit `loads` (offsets within MAME's region) at stream_base + (off -
    region_off), grouping the interleaved ones, each proven against `truth`."""
    for (base, form, length), grp in groups_of(loads):
        group, skip, _ = bri.FORMS[form]
        word = group + skip
        span = length * word // group
        at = stream_base + (base - region_off)
        grp = sorted(grp, key=lambda g: g[2])
        datas = [bri.read_file(zips, f, ln, set_name) for _, f, _, ln in grp]
        names = [f for _, f, _, _ in grp]
        want = bytes(truth[base:base + span])
        if len(grp) == 1 and skip == 0:
            if datas[0] != want:
                raise SystemExit(f"{names[0]}: not verbatim in the region?")
            st.part(at, names[0], datas[0])
        else:
            maps = pick_maps(datas, word * 8, want)
            st.interleave(at, word * 8, list(zip(names, maps, datas)), want)
    st.fill_to(stream_base + (region_end - region_off))


# ---------------------------------------------------------------- DIPs
def resolve_fields(fields):
    """ioport's field_alloc: a later field replaces the earlier ones whose
    mask it overlaps (PORT_MODIFY re-declaring a switch, or marking one
    unused)."""
    out = []
    for f in fields:
        out = [g for g in out if not (g[1] & f[1])]
        out.append(f)
    return out


def dips_of(inputs_block):
    """The SYSTEM_DSW port's switches as <dip> lines and the two default
    bytes: byte 0 = SW1 (MAME bits 31:24, the byte at 0xd5a000), byte 1 = SW2
    (bits 23:16, 0xd5a001), which is how KonamiGX.sv takes index 254."""
    text = bri.DRIVER.read_text(encoding="utf8", errors="replace")
    blocks = ed.blocks(text)
    missing = set()
    ports = ed.parse_ports(blocks[inputs_block], blocks, missing)
    if missing:
        raise SystemExit(f"DEF_STR tokens missing: {missing}")
    fields = resolve_fields(ports["SYSTEM_DSW"])
    lines, default = [], [0xff, 0xff]
    for name, mask, dflt, settings in fields:
        if mask & 0xffff:
            continue                                   # inputs, the EEPROM bit, the status bits
        for byte_index, shift in ((0, 24), (1, 16)):
            bm = (mask >> shift) & 0xff
            if not bm:
                continue
            default[byte_index] = (default[byte_index] & ~bm) | ((dflt >> shift) & bm)
            if settings is None:
                continue
            bits = [i for i in range(8) if bm & (1 << i)]
            if bits != list(range(bits[0], bits[-1] + 1)):
                raise SystemExit(f"dip '{name}': mask {mask:#x} is not contiguous")
            ids = []
            for idx in range(1 << len(bits)):
                v = 0
                for j, bp in enumerate(bits):
                    if idx & (1 << j):
                        v |= 1 << (bp + shift)
                ids.append(settings.get(v, "-"))
            if any("," in i for i in ids) or "," in name:
                raise SystemExit(f"dip '{name}': a comma splits the OSD list")
            if 2 + len(name) + max(len(i) for i in ids) > OSD_COLS:
                raise SystemExit(f"dip '{name}': does not fit {OSD_COLS} columns -- shorten it")
            lo = 8 * byte_index + bits[0]
            hi = 8 * byte_index + bits[-1]
            lines.append(f'        <dip name="{esc(name)}" bits="{lo if lo == hi else f"{lo},{hi}"}" '
                         f'ids="{esc(",".join(ids))}"/>')
    return lines, default


# ---------------------------------------------------------------- one set
def build(set_name, mod, gl, games, blocks, check_only):
    g = gl[set_name]
    lo = layout(set_name, blocks)
    arm = rtl_arm(mod)
    if arm != {k: lo[k] for k in arm or {}} or arm is None:
        raise SystemExit(f"{set_name}: rtl/gx_board_cfg.sv's arm 8'd{mod} is {arm}, the ROM_START "
                         f"gives {cfg_arm(mod, set_name, lo).strip()} -- paste --cfg's table in")
    # the set's own zip, then the parent's, then the BIOS's: Main_MiSTer
    # searches them in turn and matches a part by its crc, so a split set, a
    # merged one (where a clone's files live under "<set>/") and a renamed
    # file all resolve.
    parent = bri.zip_for(games, set_name)
    # the game's zips; the BIOS's is added only where a BIOS file is used
    game_zips = "|".join(dict.fromkeys([f"{set_name}.zip", f"{parent}.zip"]))
    zip_names = f"{game_zips}|{bri.BIOS[0]}.zip"
    zips = [zipfile.ZipFile(REPO / "roms" / z)
            for z in zip_names.split("|") if (REPO / "roms" / z).exists()]
    st = Stream()

    size, loads = bri.region_loads(blocks[set_name], "maincpu")
    truth = bri.build(set_name, "maincpu")
    st.lines.append("        <!-- maincpu, the CPU's window packed: BIOS, then 0x200000.. moved down by 0x1e0000 -->")
    emit_loads(st, zips, set_name, [l for l in loads if l[2] < 0x20000], truth, 0, 0, 0x20000)
    ext = max(off + ln * (bri.FORMS[f][0] + bri.FORMS[f][1]) // bri.FORMS[f][0] for f, _, off, ln in loads)
    emit_loads(st, zips, set_name, [l for l in loads if l[2] >= 0x200000], truth, 0x200000, 0x20000, ext)

    size, loads = bri.region_loads(blocks[set_name], "k056832")
    truth = bri.build(set_name, "k056832")
    rows = size // 5
    st.lines.append("        <!-- k056832: the four-byte part of each 5-byte row, then the fifth bytes (the core spreads rows to 8) -->")
    base = lo["tile_base"]
    for form, fname, off, length in sorted(loads, key=lambda l: l[2]):
        data = bri.read_file(zips, fname, length, set_name)
        if form == "TILE_WORD_ROM_LOAD":
            r0 = off // 5
            four = bytes(b for r in range(r0, r0 + length // 4) for b in truth[5 * r:5 * r + 4])
            if four != data:
                raise SystemExit(f"{fname}: TILE_WORD is not verbatim in the four-byte part?")
            st.part(base + r0 * 4, fname, data, "four-byte part")
        elif form == "TILE_BYTE_ROM_LOAD":
            r0 = (off - 4) // 5
            one = bytes(truth[5 * r + 4] for r in range(r0, r0 + length))
            if one != data:
                raise SystemExit(f"{fname}: TILE_BYTE is not verbatim in the one-byte part?")
            st.part(base + rows * 4 + r0, fname, data, "fifth bytes")
        else:
            raise SystemExit(f"k056832 load form {form}: not handled yet -- add it and prove it")
    st.fill_to(base + rows * 5)

    size, loads = bri.region_loads(blocks[set_name], "k055673")
    truth = bri.build(set_name, "k055673")
    st.lines.append("        <!-- k055673: MAME's region, a four-byte part then the fifth bytes -->")
    used = lo["obj_size4"] // 4 * 5                  # what the chip reads of the region
    whole, clipped = [], []
    for form, fname, off, length in loads:
        gr, sk, _ = bri.FORMS[form]
        if off + length * (gr + sk) // gr > used:
            if sk:
                raise SystemExit(f"{fname}: an interleaved load past the used part of k055673")
            clipped.append((fname, off, used - off, length))
        else:
            whole.append((form, fname, off, length))
    end_whole = max(base + length * (bri.FORMS[form][0] + bri.FORMS[form][1]) // bri.FORMS[form][0]
                    for (base, form, length), _ in groups_of(whole))
    emit_loads(st, zips, set_name, whole, truth, 0, lo["obj_base"], end_whole)
    for fname, off, length, full in sorted(clipped, key=lambda c: c[1]):
        data = bri.read_file(zips, fname, full, set_name)[:length]
        if bytes(truth[off:off + length]) != data:
            raise SystemExit(f"{fname}: not verbatim in the region?")
        st.fill_to(lo["obj_base"] + off)
        st.lines.append(f'        <part name="{fname}" '
                        f'length="{length:#x}"/>  <!-- the chip reads this much -->')
        st.data += data
        st.pos += length
    st.fill_to(lo["obj_base"] + used)

    # the default EEPROM image, MAME's "eeprom" region (most sets: "to prevent
    # game booting with error"); the core loads ioctl index 2 into the 93C46
    ee_lines = []
    m = re.search(r'ROM_REGION16_BE\(\s*0x80,\s*"eeprom"[^)]*\)\s*.*?ROM_LOAD\(\s*"([^"]+)"', blocks[set_name], re.S)
    if m:
        bri.read_file(zips, m.group(1), 0x80, set_name)          # it must exist in the zip
        ee_lines = ['', '    <!-- the default EEPROM image (the ROM_START eeprom region); the core loads it into the 93C46 -->',
                    '    <rom index="2" zip="' + game_zips + '" md5="none">',
                    f'        <part name="{m.group(1)}"/>', '    </rom>']
    dip_lines, dflt = dips_of(g["inputs"])
    title = g["title"]
    text = "\n".join([
        '<misterromdescription>',
        f'    <name>{esc(title)}</name>',
        f'    <setname>{set_name}</setname>',
        # the core without the "Arcade-" prefix, as the contribution guidelines
        # and the sibling cores have it: the released bitstream keeps the prefix
        # and is renamed when it is copied to the device
        '    <rbf>KonamiGX</rbf>',
        f'    <year>{g["year"]}</year>',
        f'    <manufacturer>{esc(g["manufacturer"])}</manufacturer>',
        '    <category>Arcade</category>',
        '    <rotation>horizontal</rotation>',
        '',
        f'    <rom index="1"><part>{mod:02X}</part></rom>',
        '',
        '    <!-- the SDRAM image rtl/memory/gx_sdram_top.sv expects for this set',
        f'         (rtl/gx_board_cfg.sv arm {mod}); written and proven by',
        '         scripts/build_mra.py, not by hand -->',
        # address=: Main_MiSTer loads the image into DDR3 at 0x30000000 and the core
        # copies it to SDRAM (rtl/memory/gx_rom_loader.sv), as the sibling cores do
        f'    <rom index="0" zip="{zip_names}" md5="none" address="0x30000000">',
        *st.lines,
        '    </rom>',
        *ee_lines,
        '',
        f'    <switches default="{dflt[0]:02X},{dflt[1]:02X}">',
        *dip_lines,
        '    </switches>',
        '',
        f'    <buttons {BUTTONS}/>',
        '</misterromdescription>',
        '',
    ])
    parent = games.get(set_name)
    folder = (OUT_DIR if parent in (None, "0", "konamigx")
              else OUT_DIR / "_alternatives" / ("_" + mra_filename(gl[parent]["title"])[:-4]))
    out = folder / mra_filename(title)
    folder.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".mra.tmp")
    tmp.write_text(text, encoding="utf8")
    try:
        got = mra_lib.build_image(tmp, [REPO / "roms" / z for z in zip_names.split("|")
                                        if (REPO / "roms" / z).exists()])
        if got != bytes(st.data):
            n = next((i for i in range(min(len(got), len(st.data))) if got[i] != st.data[i]),
                     min(len(got), len(st.data)))
            raise SystemExit(f"{set_name}: the .mra re-read differs from the expected stream at {n:#x}")
        print(f"{set_name:10} {len(st.data) / MB:5.1f} MB, ends at {lo['end'] / MB:4.0f} MB; the .mra "
              f"reproduces the expected stream; DSW default {dflt[0]:02X},{dflt[1]:02X}, {len(dip_lines)} switches"
              + (", default EEPROM" if ee_lines else ", no default EEPROM"))
    finally:
        if check_only or not tmp.exists():
            tmp.unlink(missing_ok=True)
    if not check_only:
        tmp.replace(out)
        print(f"           -> {out.relative_to(REPO)}")
    for z in zips:
        z.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", help="default: every set in SETS")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--cfg", action="store_true", help="print gx_board_cfg.sv's generated arms")
    a = ap.parse_args()
    games, blocks = bri.parse(bri.DRIVER)
    gl = game_lines()
    if a.cfg:
        for mod, s in enumerate(SETS):
            print(cfg_arm(mod, s, layout(s, blocks)))
        return
    for s in a.sets or SETS:
        if s not in SETS:
            raise SystemExit(f"{s}: not in SETS (the core does not take its ROM formats yet)")
        build(s, SETS.index(s), gl, games, blocks, a.check)


if __name__ == "__main__":
    main()
