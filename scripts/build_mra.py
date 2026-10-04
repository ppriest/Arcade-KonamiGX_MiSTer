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


_MAME_VERSION = None


def mame_version():
    """<mameversion> of the MAME the ROM definitions are checked against, from
    `mame -version` ("0.289 (mame0289)" -> "0289"). MAME_DIR / MAME_EXE come from the
    environment, then mister.env, then ~/.mister-core.env; never typed by hand."""
    global _MAME_VERSION
    if _MAME_VERSION:
        return _MAME_VERSION
    import os
    import subprocess
    here = Path(__file__).resolve().parent.parent
    env = {}
    for f in (Path(os.environ.get("MISTER_CORE_ENV") or Path.home() / ".mister-core.env"),
              here / "mister.env"):
        if f.exists():
            for ln in f.read_text(encoding="utf-8", errors="replace").splitlines():
                ln = ln.strip()
                if ln and not ln.startswith("#") and "=" in ln:
                    k, v = ln.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    exe = Path(os.environ.get("MAME_DIR") or env.get("MAME_DIR") or ".") / (
        os.environ.get("MAME_EXE") or env.get("MAME_EXE") or "mame.exe")
    try:
        out = subprocess.run([str(exe), "-version"], capture_output=True, text=True,
                             timeout=30).stdout
    except OSError:
        out = ""
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit("cannot read the MAME version from %s: set MAME_DIR / MAME_EXE. The .mra "
                 "<mameversion> is the MAME the ROM definitions are checked against." % exe)
    _MAME_VERSION = "%04d" % int(m.group(1))
    return _MAME_VERSION

REPO = bri.REPO


def cheat_lines(set_name):
    """The set's <cheats> block (scripts/mame_cheats.py), from MAME's cheat files
    if they are installed; none otherwise, and the .mra is as it was."""
    import mame_cheats
    try:
        if mame_cheats.cheat_xml(set_name) is None:
            return []
        good, bad = mame_cheats.cheats(set_name)
    except SystemExit:
        return []
    if not good:
        return []
    return ["", "    <!-- from Pugsy's MAME cheats (mamecheat.co.uk), scripts/mame_cheats.py: replaced",
            "         as the CPU reads them (rtl/cheat/cheatengine.sv) -->",
            *mame_cheats.mra_block(good).rstrip("\n").split("\n")]


# hiscore.v (rtl/hiscore): MAME's hiscore.dat entries as the .mra's <rom index="3">.
# START_WAIT is the delay from reset before the first start/end check: half a second
# before the frame from which the set's own table stays in place in MAME 0.289
# (frames from power-on), so the check never runs during the power-on RAM test,
# which writes the same RAM.
HS_READY_FRAME = {"gokuparo": 661, "fantjour": 661, "fantjoura": 661, "sexyparo": 984,
                  "sexyparoa": 984, "tbyahhoo": 834, "dragoonj": 1069, "salmndr2": 1062,
                  "le2": 745, "le2u": 745}
HS_CLK = 48_000_000                     # clk_vid, hiscore.v's clock
WRAM = (0xC00000, 0xC20000)             # gx_main's work RAM; HS_ADDRESSWIDTH 17
HS_MAX_ENTRIES, HS_MAX_BYTES = 4, 512   # KonamiGX.sv: CFG_ADDRESSWIDTH 2, HS_SCOREWIDTH 9
EEPROM_BYTES = 128                      # the <nvram> file holds the EEPROM first


def hiscore_dat():
    """MAME's plugins/hiscore/hiscore.dat beside the MAME this script runs, or None."""
    import os
    mame_version()                      # resolves MAME_DIR, or stops
    exe_dir = os.environ.get("MAME_DIR")
    if not exe_dir:
        for f in (Path(os.environ.get("MISTER_CORE_ENV") or Path.home() / ".mister-core.env"),
                  REPO / "mister.env"):
            if f.exists():
                for ln in f.read_text(encoding="utf-8", errors="replace").splitlines():
                    if ln.strip().startswith("MAME_DIR="):
                        exe_dir = ln.split("=", 1)[1].strip().strip('"').strip("'")
    f = Path(exe_dir or ".") / "plugins" / "hiscore" / "hiscore.dat"
    return f.read_text(encoding="utf-8", errors="replace") if f.exists() else None


def hiscore_entries(set_name, text):
    """[(addr, length, start, end)] for the set; [] if none, or one this core cannot hold."""
    names, entries, found = [], [], None
    for ln in text.splitlines() + [""]:
        ln = ln.strip()
        if ln.startswith(";"):
            continue
        if ln.endswith(":") and not ln.startswith("@"):
            if entries:
                names, entries = [], []
            names.append(ln[:-1])
        elif ln.startswith("@"):
            f = ln[1:].split(",")
            try:
                entries.append((f[0], f[1], int(f[2], 16), int(f[3], 16), int(f[4], 16), int(f[5], 16)))
            except (IndexError, ValueError):
                entries.append(("?", "?", 0, 0, 0, 0))      # another format: the set is not supported
        elif not ln and names:
            if set_name in names and entries:
                found = entries
                break
            names, entries = [], []
    if not found:
        return []
    out = [(a, n, s, e) for cpu, space, a, n, s, e in found
           if cpu == ":maincpu" and space == "program" and WRAM[0] <= a and a + n <= WRAM[1]]
    if (len(out) != len(found) or len(out) > HS_MAX_ENTRIES
            or sum(n for _, n, _, _ in out) > HS_MAX_BYTES or set_name not in HS_READY_FRAME):
        return []
    return out


def hiscore_lines(set_name):
    """The <rom index="3"> block, and the bytes hiscore.v adds to the <nvram> file."""
    text = hiscore_dat()
    ents = hiscore_entries(set_name, text) if text else []
    if not ents:
        return [], 0
    wait = (HS_READY_FRAME[set_name] - 30) * HS_CLK // 60
    # START_WAIT, CHECK_WAIT, CHECK_HOLD (2: the read is registered), WRITE_HOLD,
    # WRITE_REPEATCOUNT, WRITE_REPEATWAIT, ACCESS_PAUSEPAD, CHANGEMASK
    head = wait.to_bytes(4, "big") + bytes.fromhex("3FFF 0002 0002 0001 000F 20 00")
    rows = [" ".join(f"{b:02X}" for b in head)]
    for a, n, st, en in ents:              # CFG_LENGTHWIDTH 2: address, length, start, end
        rows.append(" ".join(f"{b:02X}" for b in a.to_bytes(4, "big") + n.to_bytes(2, "big") + bytes([st, en])))
    return (["", "    <!-- MAME's hiscore.dat entries for hiscore.v (rtl/hiscore) -->",
             '    <rom index="3">', "        <part>", *("        " + r for r in rows),
             "        </part>", "    </rom>"],
            sum(n for _, n, _, _ in ents))


RTL_CFG = REPO / "rtl" / "gx_board_cfg.sv"
OUT_DIR = REPO / "releases"
MB = 1 << 20

# The sets the core takes today, in mod-byte order (gx_board_cfg's arms).
SETS = ["daiskiss", "crzcross", "puzldama", "fantjour", "fantjoura", "gokuparo",
        "mtwinbee", "tbyahhoo", "sexyparo", "sexyparoa", "tokkae", "tkmmpzdm", "le2",
        "dragoona", "dragoonj", "winspike", "winspikea", "winspikej", "salmndr2", "salmndr2a",
        "le2u", "le2j"]

# K056832 row bytes per set (set_config's depth; render_model.TILE_BPP):
# BPP_5 unless listed. gx_board_cfg's tile_bpp says the same to the core.
TILE_BYTES = {"tokkae": 6, "tkmmpzdm": 6, "le2": 8, "winspike": 8, "winspikea": 8, "winspikej": 8,
              "salmndr2": 6, "salmndr2a": 6, "le2u": 8, "le2j": 8}

# Program patches MAME applies at start-up, carried as .mra <patch>es:
# (CPU address, old byte, new byte). tkmmpzdm (init_konamigx, special 2):
# rom[0x810f1] &= ~1 and rom[0x872ea] |= 0xe0000 on the big-endian program --
# or.b #$1,d0 becomes #$0 (the checksum, rebalanced) and move.b #$11,($5a,a2)
# becomes #$1f, re-enabling planes B-D after the copyright screen, which MAME
# says it could not otherwise explain. Applied at the user's request until the
# cause is found.
PATCHES = {"tkmmpzdm": [(0x2043c7, 0x01, 0x00), (0x21cba9, 0x11, 0x1f)]}

# K055673 layout per set (render_model.OBJ_LAYOUT): GX unless listed. RNG and
# LE2 regions go into SDRAM as they are, with obj_size4 half the region.
OBJ_LAYOUT = {"le2": "LE2", "dragoona": "RNG", "dragoonj": "RNG",
              "winspike": "LE2", "winspikea": "LE2", "winspikej": "LE2",
              "salmndr2": "GX6", "salmndr2a": "GX6", "le2u": "LE2", "le2j": "LE2"}

# The game buttons each set's .mra names, in order: KonamiGX.sv reads buttons
# 1-3 at joystick bits 4-6 and 4-6 at bits 7-9. EDIT THE NAMES HERE; the
# <buttons> element, the pad defaults and the count follow from them.
#
# MAME's driver names none of these (konamigx.cpp: every set takes the
# shared "common" port, BUTTON1-3 unnamed; dragoonj adds 4-6). The names
# below are from history.xml and command.dat where they give them, and
# MAME's "Button n" where they do not; a set history.xml gives fewer
# buttons has only those.
BUTTON_NAMES = {
    "daiskiss":  ["1", "2", "3"],  # Daisu-Kiss (ver JAA) -- literally the numbered buttons for quiz answers
    "crzcross":  ["Rotate", "-", "-"],  # Crazy Cross (ver EAA)
    "puzldama":  ["Rotate", "-", "-"],  # Taisen Puzzle-dama (ver JAA)
    "fantjour":  ["Power Up", "Shot", "Missile"],  # Fantastic Journey (ver EAA)
    "fantjoura": ["Power Up", "Shot", "Missile"],  # Fantastic Journey (ver AAA)
    "gokuparo":  ["Power Up", "Shot", "Missile"],  # Gokujou Parodius: Kako no Eikou o Motomete (ver JAD)
    "mtwinbee":  ["Shot", "Bomb", "-"],  # Magical Twin Bee (ver EAA)
    "tbyahhoo":  ["Shot", "Bomb", "-"],  # Twin Bee Yahhoo! (ver JAA)
    "sexyparo":  ["Power Up", "Shot", "Missile"],  # Sexy Parodius (ver JAA)
    "sexyparoa": ["Power Up", "Shot", "Missile"],  # Sexy Parodius (ver AAA)
    "tokkae":    ["Swap Ball", "Line Up"],  # Taisen Tokkae-dama (ver JAA)
    "tkmmpzdm":  ["Rotate Right", "Rotate Left"],  # Tokimeki Memorial Taisen Puzzle-dama (ver JAB)
    # history.xml (command.dat: Weak/Medium/Strong)
    "dragoona":  ["Light Punch", "Medium Punch", "Heavy Punch", "Light Kick", "Medium Kick", "Heavy Kick"],  # Dragoon Might (ver AAB)
    "dragoonj":  ["Light Punch", "Medium Punch", "Heavy Punch", "Light Kick", "Medium Kick", "Heavy Kick"],  # Dragoon Might (ver JAA)
    "winspike":  ["Button A", "Button B", "Button C"],  # Winning Spike (ver EAA) -- Context sensitive
    "winspikea": ["Button A", "Button B", "Button C"],  # Winning Spike (ver AAA) -- Context sensitive
    "winspikej": ["Button A", "Button B", "Button C"],  # Winning Spike (ver JAA) -- Context sensitive
    "salmndr2":  ["Shot", "Option", "-"],  # Salamander 2 (ver JAA)
    "salmndr2a": ["Shot", "Option", "-"],  # Salamander 2 (ver AAB)
    "le2":       ["Trigger", "Reload"],  # Lethal Enforcers II: Gun Fighters (ver EAA)
    "le2u":      ["Trigger", "Reload"],  # Lethal Enforcers II: Gun Fighters (ver UAA)
    "le2j":      ["Trigger", "Reload"],  # Lethal Enforcers II: The Western (ver JAA)
}


def buttons_attr(set_name):
    """The .mra's <buttons> attributes. `names` is positional -- the six game
    buttons ("-" keeps a bit unused), then Start, Coin, Pause, Service as
    the core's J1 line has them. Main_MiSTer applies `default` to the NAMED
    buttons only, in order, so it has one pad button per name and none for
    a "-": a default with ten entries once put the pad's Start on Service
    (Twin Bee entered service mode on Start). Game buttons take A, B, X, Y,
    L, R in turn; Pause and Service get L and R when the game leaves them."""
    game = BUTTON_NAMES.get(set_name, ["Button 1", "Button 2", "Button 3"])
    assert 1 <= len(game) <= 6, set_name
    named = [n for n in game if n != "-"]       # a "-" in the list is a button left unused
    names = game + ["-"] * (6 - len(game)) + ["Start", "Coin", "Pause", "Service"]
    pads = ["A", "B", "X", "Y", "L", "R"][:len(named)] + ["Start", "Select"]
    pads += [b for b in ("L", "R") if b not in pads]
    return f'names="{",".join(names)}" default="{",".join(pads)}" count="{len(named)}"'


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
    for m in re.finditer(r'^GAME\(\s*(\d+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),[^,]*,[^,]*,\s*(?:ROT\d+|ORIENTATION_FLIP_[XY]),\s*"([^"]*)",\s*"([^"]*)"',
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
    ps, _ = bri.region_loads(blocks[set_name], "k054539")
    ts, _ = bri.region_loads(blocks[set_name], "k056832")
    os_, _ = bri.region_loads(blocks[set_name], "k055673")
    ext = 0
    for form, f, off, ln in ml:
        g, sk, _ = bri.FORMS[form]
        ext = max(ext, off + ln * (g + sk) // g)
    if any(0x20000 <= l[2] < 0x200000 for l in ml):
        raise SystemExit(f"{set_name}: a maincpu load between 0x20000 and 0x200000")
    packed = 0x20000 + max(0, ext - 0x200000)
    # k056832: 5- or 6-byte rows through the region (TILE_BYTES). k055673:
    # the four-byte part is (MB / 5) * 4 MB and the fifth bytes follow,
    # MAME's k055673.cpp split (a 6 MB region is 4 MB + 1 MB used, the rest
    # unread)
    tr = ts // TILE_BYTES.get(set_name, 5)
    if OBJ_LAYOUT.get(set_name, "GX") in ("RNG", "LE2"):
        orow = os_ // 8                          # as it comes: 2 * obj_size4 = the region
    else:
        orow = ((os_ >> 20) // 5) << 20
    up = lambda x: (x + MB - 1) // MB * MB
    tb = up(packed)
    ob = tb + up(tr * 8)
    end = ob + up(orow * 8)
    if end > 32 * MB:
        raise SystemExit(f"{set_name}: {end / MB:.1f} MB does not fit the 32 MB module")
    # the K054539 sample area: the region, to 1 MB (dragoonj's 2 MB is what
    # lets its 16 MB of sprites fit; the rest have 4 MB)
    return dict(tile_base=tb, obj_base=ob, tile_size4=tr * 4, obj_size4=orow * 4, end=end,
                snd_pcm=up(ps))


def cfg_arm(mod, set_name, lo):
    return (f"        8'd{mod}:{' ' * (3 - len(str(mod)))}begin tile_base = 26'h{lo['tile_base']:07x}; "
            f"obj_base = 26'h{lo['obj_base']:07x}; tile_size4 = 24'h{lo['tile_size4']:06x}; "
            f"obj_size4 = 24'h{lo['obj_size4']:06x}; snd_pcm = 24'h{lo['snd_pcm']:06x}; end  // {set_name}")


# The sound board's ROMs, after the graphics (gx_sdram_top's snd_base): the
# sound CPU's program space, then the K054539 samples, each at its largest.
SND_CPU = 0x40000


def snd_base(lo):
    """Where the sprite region's spread ends: gx_sdram_top's snd_base."""
    return lo["obj_base"] + 2 * lo["obj_size4"]


def rtl_arm(mod):
    """gx_board_cfg.sv's arm for a mod byte, as a dict, or None."""
    src = RTL_CFG.read_text(encoding="utf8")
    m = re.search(rf"8'd{mod}:\s*begin\s*tile_base = 26'h([0-9a-f]+); obj_base = 26'h([0-9a-f]+); "
                  rf"tile_size4 = 24'h([0-9a-f]+); obj_size4 = 24'h([0-9a-f]+); "
                  rf"snd_pcm = 24'h([0-9a-f]+); end", src)
    if not m:
        return None
    return dict(tile_base=int(m.group(1), 16), obj_base=int(m.group(2), 16),
                tile_size4=int(m.group(3), 16), obj_size4=int(m.group(4), 16),
                snd_pcm=int(m.group(5), 16))


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
    # screened on the first 4096 words, then proven on all of it: the whole
    # region per candidate took minutes for four ROM_LOAD64_WORD files
    n = 4096 * group
    head = [d[:n] for d in datas]
    for maps in itertools.product(cands, repeat=len(datas)):
        used = [set(i for i, c in enumerate(m) if c != "0") for m in maps]
        if any(a & b for a, b in itertools.combinations(used, 2)):
            continue
        if mra_lib.interleave(list(zip(head, maps)), bits) != truth[:n * len(datas)]:
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
    tbw = TILE_BYTES.get(set_name, 5)            # row bytes: 4, then 1 (5 bpp) or 2 (6 bpp)
    if tbw == 8:
        # 8 bpp: eight-byte rows, a granule each, so MAME's region as it is
        st.lines.append("        <!-- k056832: MAME's region as it is (8-byte rows, a granule each) -->")
        emit_loads(st, zips, set_name, loads, truth, 0, lo["tile_base"], size)
        st.fill_to(lo["tile_base"] + size)
        loads = []
    w1 = tbw - 4
    rows = size // tbw
    st.lines.append(f"        <!-- k056832: the four-byte part of each {tbw}-byte row, then the last "
                    f"{w1} byte{'s' if w1 > 1 else ''} of each (the core spreads rows to 8) -->")
    base = lo["tile_base"]

    def dest(load):
        """where a load lands in the stream: the four-byte parts first"""
        form, _, off, _ = load
        if form in ("TILE_WORD_ROM_LOAD", "TILE_WORDS2_ROM_LOAD"):
            return off // tbw * 4
        return rows * 4 + (off - 4) // tbw * w1
    for form, fname, off, length in sorted(loads, key=dest):
        data = bri.read_file(zips, fname, length, set_name)
        if form in ("TILE_WORD_ROM_LOAD", "TILE_WORDS2_ROM_LOAD"):
            if (form == "TILE_WORDS2_ROM_LOAD") != (tbw == 6):
                raise SystemExit(f"{fname}: {form} in a {tbw}-byte-row region")
            r0 = off // tbw
            four = bytes(b for r in range(r0, r0 + length // 4) for b in truth[tbw * r:tbw * r + 4])
            if four != data:
                raise SystemExit(f"{fname}: {form} is not verbatim in the four-byte part?")
            st.part(base + r0 * 4, fname, data, "four-byte part")
        elif form in ("TILE_BYTE_ROM_LOAD", "TILE_BYTES2_ROM_LOAD"):
            if (form == "TILE_BYTES2_ROM_LOAD") != (tbw == 6):
                raise SystemExit(f"{fname}: {form} in a {tbw}-byte-row region")
            r0 = (off - 4) // tbw
            rest = bytes(b for r in range(r0, r0 + length // w1) for b in truth[tbw * r + 4:tbw * r + tbw])
            if rest != data:
                raise SystemExit(f"{fname}: {form} is not verbatim in the second part?")
            st.part(base + rows * 4 + r0 * w1, fname, data, "second part")
        else:
            raise SystemExit(f"k056832 load form {form}: not handled yet -- add it and prove it")
    if tbw != 8:
        st.fill_to(base + rows * tbw)

    size, loads = bri.region_loads(blocks[set_name], "k055673")
    truth = bri.build(set_name, "k055673")
    if OBJ_LAYOUT.get(set_name, "GX") in ("RNG", "LE2"):
        st.lines.append("        <!-- k055673: MAME's region as it is -->")
        emit_loads(st, zips, set_name, loads, truth, 0, lo["obj_base"], size)
        st.fill_to(lo["obj_base"] + 2 * lo["obj_size4"])
        loads = []
    elif OBJ_LAYOUT.get(set_name, "GX") == "GX6":
        # _48_WORD: three ROMs give bytes 0-1, 2-3 and 4-5 of each six-byte
        # half-row; the core wants the four-byte part (the first two ROMs
        # interleaved) and then the two-byte part (the third as it is)
        st.lines.append("        <!-- k055673: GX6, bytes 0-3 of each half-row, then bytes 4-5 -->")
        g6 = sorted(loads, key=lambda l: l[2])
        if [l[0] for l in g6] != ["_48_WORD_ROM_LOAD"] * 3 or [l[2] for l in g6] != [0, 2, 4]:
            raise SystemExit(f"{set_name}: GX6 expects three _48_WORD loads at 0, 2, 4")
        n = g6[0][3]
        if any(l[3] != n for l in g6) or 3 * n != lo["obj_size4"] // 4 * 6:
            raise SystemExit(f"{set_name}: GX6 loads do not fill the region")
        datas = [bri.read_file(zips, f, ln, set_name) for _, f, _, ln in g6]
        rows = [truth[6 * r:6 * r + 6] for r in range(n // 2)]
        four = bytes(b for r in rows for b in r[:4])
        two = bytes(b for r in rows for b in r[4:])
        maps = pick_maps(datas[:2], 32, four)
        st.interleave(lo["obj_base"], 32, [(g6[0][1], maps[0], datas[0]), (g6[1][1], maps[1], datas[1])], four)
        if two != datas[2]:
            raise SystemExit(f"{g6[2][1]}: not bytes 4-5 of the half-rows?")
        st.part(lo["obj_base"] + len(four), g6[2][1], datas[2], "two-byte part")
        loads = []
    else:
        st.lines.append("        <!-- k055673: MAME's region, a four-byte part then the fifth bytes -->")
    used = lo["obj_size4"] // 4 * 5 if loads else 0  # what the chip reads of the region (GX)
    whole, clipped = [], []
    for form, fname, off, length in loads:
        gr, sk, _ = bri.FORMS[form]
        if off + length * (gr + sk) // gr > used:
            if sk:
                raise SystemExit(f"{fname}: an interleaved load past the used part of k055673")
            clipped.append((fname, off, used - off, length))
        else:
            whole.append((form, fname, off, length))
    if whole:
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
    if used:
        st.fill_to(lo["obj_base"] + used)

    # the sound board: the sound 68000's program, then the K054539 samples,
    # stored as they come from where the sprite region's spread ends
    # (gx_sdram_top's snd_base). The samples are padded to the set's sample
    # area (layout()'s snd_pcm, gx_board_cfg's), after which gx_sound puts the
    # K054539s' and the DSP's RAMs; the stream ends there, which is the length
    # the DDR3 loader copies.
    snd = snd_base(lo)
    # then the RAMs written at runtime: the K054539s' (2 x 32 KB) and the
    # TMS57002's (256 KB), gx_sound's RAM_OFF and DSP_OFF
    if snd + SND_CPU + lo["snd_pcm"] + 0x10000 + 0x40000 > 32 * MB:
        raise SystemExit(f"{set_name}: the sound board's RAMs end past the 32 MB module")
    for region, at, pad in (("soundcpu", snd, SND_CPU), ("k054539", snd + SND_CPU, lo["snd_pcm"])):
        size, loads = bri.region_loads(blocks[set_name], region)
        if size > pad:
            raise SystemExit(f"{set_name}: {region} is {size:#x}, more than the {pad:#x} reserved")
        truth = bri.build(set_name, region)
        st.lines.append(f"        <!-- {region}: MAME's region as it is -->")
        emit_loads(st, zips, set_name, loads, truth, 0, at, size)
        st.fill_to(at + pad)

    # the default EEPROM image, MAME's "eeprom" region (most sets: "to prevent
    # game booting with error"); the core loads ioctl index 2 into the 93C46
    ee_lines = []
    m = re.search(r'ROM_REGION16_BE\(\s*0x80,\s*"eeprom"[^)]*\)\s*.*?ROM_LOAD\(\s*"([^"]+)"[^)]*?CRC\(([0-9a-fA-F]{8})\)', blocks[set_name], re.S)
    if m:
        bri.read_file(zips, m.group(1), 0x80, set_name)          # it must exist in the zip
        # with its CRC: a clone's image is in a subfolder of a merged set's
        # zip (salmndr2.zip: salmndr2a/salmndr2a.nv), which MiSTer finds by
        # CRC and not by name -- without it salmndr2a booted with no EEPROM
        # and failed its self-test
        ee_lines = ['', '    <!-- the default EEPROM image (the ROM_START eeprom region); the core loads it into the 93C46 -->',
                    '    <rom index="2" zip="' + game_zips + '" md5="none">',
                    f'        <part name="{m.group(1)}" crc="{m.group(2).lower()}"/>', '    </rom>']
    dip_lines, dflt = dips_of(g["inputs"])
    title = g["title"]
    # the program patches, at their place in the stream (the CPU window from
    # 0x200000 is moved down by 0x1e0000)
    patch_lines = []
    for addr, old, new in PATCHES.get(set_name, []):
        off = addr - 0x1e0000 if addr >= 0x200000 else addr
        if st.data[off] != old:
            raise SystemExit(f"{set_name}: patch at {addr:#x}: {st.data[off]:#04x}, expected {old:#04x}")
        st.data[off] = new
        patch_lines.append(f'        <patch offset="{off:#x}">{new:02X}</patch>'
                           f'  <!-- CPU {addr:#x}: {old:02X} -> {new:02X}, MAME init_konamigx -->')
    hs_lines, hs_bytes = hiscore_lines(set_name)
    text = "\n".join([
        '<misterromdescription>',
        f'    <name>{esc(title)}</name>',
        f'    <setname>{set_name}</setname>',
        # the core without the "Arcade-" prefix, as the contribution guidelines
        # and the sibling cores have it: the released bitstream keeps the prefix
        # and is renamed when it is copied to the device
        '    <rbf>KonamiGX</rbf>',
        f'    <mameversion>{mame_version()}</mameversion>',
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
        *patch_lines,
        '    </rom>',
        *ee_lines,
        '',
        *hs_lines,
        *([''] if hs_lines else []),
        '    <!-- the EEPROM saved: loaded after the ROM (ioctl index 4, over the default),',
        '         saved when the OSD opens after the game has written it'
        + ('; then hiscore.v\'s tables -->' if hs_bytes else ' -->'),
        f'    <nvram index="4" size="{EEPROM_BYTES + hs_bytes}"/>',
        '',
        f'    <switches default="{dflt[0]:02X},{dflt[1]:02X}">',
        *dip_lines,
        '    </switches>',
        '',
        f'    <buttons {buttons_attr(set_name)}/>',
        *cheat_lines(set_name),
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
