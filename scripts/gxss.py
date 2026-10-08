#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) Paul Priest
"""The core's save states (docs/SAVESTATES.md).

    python scripts/gxss.py info  state.ss            # header, sections, both CPUs
    python scripts/gxss.py diff  a.ss b.ss           # which sections differ, and where

A .ss is what Main_MiSTer writes from a slot: a 64-bit control word (a
counter, then the size in 32-bit words) and the image, 16-bit words
little-endian. The image is rtl/gx_ss_layout.svh's sections in order; that
file is parsed here, so the two cannot disagree.
"""
import argparse
import re
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LAYOUT = REPO / "rtl" / "gx_ss_layout.svh"

CHANNELS = {"SS_HDR": "HDR", "SS_MCPU": "MCPU", "SS_SCPU": "SCPU", "SS_SS": "SS",
            "SS_MB": "MB", "SS_SB": "SB", "SS_SD": "SD"}


# the Type 3/4 build's sections follow the others (GX_T34's SS_NSEC)
T34_FIRST = 21


def version():
    return int(re.search(r"SS_VERSION = 16'd(\d+)", LAYOUT.read_text(encoding="utf-8")).group(1))


def is_t34(setname):
    sys.path.insert(0, str(REPO / "scripts"))
    import build_mra
    return setname in build_mra.T34


def layout(t34=False):
    """[(name, channel, base, words)] from the .svh, in order: the Type 3/4
    build's (t34) or the other's."""
    secs = []
    pat = re.compile(r"(\d+):\s*ss_sec = \{\s*(SS_\w+),\s*24'(?:h([0-9A-Fa-f]+)|d(\d+)),\s*32'd(\d+)\s*\};\s*//\s*(.*)")
    for ln in LAYOUT.read_text(encoding="utf-8").splitlines():
        m = pat.search(ln)
        if m and (t34 or int(m.group(1)) < T34_FIRST):
            base = int(m.group(3), 16) if m.group(3) else int(m.group(4))
            secs.append((m.group(6).split(":")[0].strip(), CHANNELS[m.group(2)], base, int(m.group(5))))
    return secs


class GxState:
    def __init__(self, words, t34=None):
        self.words = list(words)
        if t34 is None:                     # from the header's set
            sets = mame_sets()
            t34 = len(self.words) > 3 and self.words[3] < len(sets) and is_t34(sets[self.words[3]])
        self.t34 = t34
        self.secs = {}
        off = 0
        for name, ch, base, n in layout(t34):
            self.secs[name] = (off, n, ch, base)
            off += n
        self.total = off
        if len(self.words) < off:
            sys.exit(f"image has {len(self.words)} words, the layout {off}")

    @staticmethod
    def read(path):
        raw = Path(path).read_bytes()
        cnt, size = struct.unpack_from("<II", raw, 0)
        n = size * 2
        return GxState(struct.unpack_from(f"<{n}H", raw, 8))

    def write(self, path, counter=1):
        w = self.words + [0] * (len(self.words) & 1)
        Path(path).write_bytes(struct.pack("<II", counter, len(w) // 2) + struct.pack(f"<{len(w)}H", *w))

    def sec(self, name):
        off, n, _, _ = self.secs[name]
        return self.words[off:off + n]

    def set_sec(self, name, vals):
        off, n, _, _ = self.secs[name]
        if len(vals) != n:
            sys.exit(f"{name}: {len(vals)} words, the layout has {n}")
        self.words[off:off + n] = list(vals)

    def bank(self, name):
        """A CPU's register bank (gx_ss_m68k): 23 longs, high word first."""
        w = self.sec(name)
        return [(w[2 * i] << 16) | w[2 * i + 1] for i in range(23)]


def cpu_line(b, m020):
    s = (f"PC {b[20]:08x} SR {b[19]:04x} {'stopped ' if b[22] & 1 else ''}"
         f"USP {b[15]:08x} A7' {b[18]:08x}")
    if m020:
        s += f" VBR {b[16]:08x} CACR {b[17]:x} fmt {b[21]:04x}"
    return (s + "\n    D " + " ".join(f"{v:08x}" for v in b[0:8])
              + "\n    A " + " ".join(f"{v:08x}" for v in b[8:15]))


def cmd_info(a):
    st = GxState.read(a.ss)
    h = st.sec("hdr")
    magic = "".join(chr(c >> 8) + chr(c & 0xFF) for c in h[0:2])
    print(f"{a.ss}: {magic} version {h[2]} set {h[3]} raster line {h[4]} pixel {h[5]}, "
          f"{st.total} words")
    for name, (off, n, ch, base) in st.secs.items():
        w = st.words[off:off + n]
        nz = sum(1 for v in w if v)
        print(f"  {off:7d} {n:7d} {ch:4s} {base:6x}  {name}  ({nz} nonzero)")
    print("68020 " + cpu_line(st.bank("mcpu"), True))
    print("68000 " + cpu_line(st.bank("scpu"), False))


def cmd_diff(a):
    x, y = GxState.read(a.a), GxState.read(a.b)
    for name, (off, n, ch, base) in x.secs.items():
        d = [i for i in range(n) if x.words[off + i] != y.words[off + i]]
        if d:
            print(f"{name}: {len(d)} of {n} words differ, first at {d[0]} "
                  f"({x.words[off + d[0]]:04x} / {y.words[off + d[0]]:04x})")


# ---------------------------------------------------------------- MAME
# What the core holds that MAME 0.289's state does not, a converted state
# takes as follows (docs/SAVESTATES.md, "From MAME"):
#   K053252 registers   the set's boot values (--k053252, or a capture)
#   K054539 voices      fraction and last values 0, positions where saved
#   timers' phases      the sample counter, the K054539 timer, the DMA-end
#                       timer: 0 / not running
#   the 68000           mid-instruction (m_inst_substate != 0): restarted at m_ipc

def pack(fields, width):
    """[(value, bits)] most significant first -> 16-bit words, word 0 = bits 15:0."""
    v, n = 0, 0
    for val, bits in fields:
        v = (v << bits) | (val & ((1 << bits) - 1))
        n += bits
    assert n == width, (n, width)
    return [(v >> (16 * i)) & 0xFFFF for i in range((width + 15) // 16)]


def mame_sets():
    sys.path.insert(0, str(REPO / "scripts"))
    src = (REPO / "scripts" / "build_mra.py").read_text(encoding="utf-8")
    return re.findall(r'"(\w+)"', re.search(r"SETS = \[(.*?)\]", src, re.S).group(1))


def k053252_regs(setname, path=None):
    """The 16 registers the game writes at boot: one hex byte a line."""
    cands = [Path(path)] if path else [REPO / "sim" / "gx_crt_chain_tb" / f"{setname}.hex"]
    if not path:
        cands += sorted((REPO / "debug").glob(f"{setname}-*/reg_k053252.bin"))
    for p in cands:
        if p.exists():
            if p.suffix == ".bin":
                b = p.read_bytes()
                return [b[2 * i] for i in range(16)]
            return [int(t, 16) for t in p.read_text().split()][:16]
    sys.exit(f"no K053252 registers for {setname}: give --k053252 (16 hex bytes, a line each)")


def from_mame(sta_path, out_path, k053252=None, side=None):
    sys.path.insert(0, str(REPO / "scripts"))
    import mame_sta
    st = mame_sta.State.read(sta_path)
    sets = mame_sets()
    if st.setname not in sets:
        sys.exit(f"{st.setname}: not a set this core takes")
    it = st.items

    def u(name, i=0, size=None):
        return st.u(name, i, size)

    def arr(name, size):
        b = it[name]
        return [int.from_bytes(b[k:k + size], "little") for k in range(0, len(b), size)]

    t34 = is_t34(st.setname)
    g = GxState([0] * sum(n for _, _, _, n in layout(t34)), t34)
    notes = []
    # what MAME does not save, from scripts/mame/save_at.lua's JSON beside the state
    import json
    sp = Path(side) if side else Path(str(sta_path) + ".json")
    sd = json.loads(sp.read_text()) if sp.exists() else {}
    if t34 and "t3_bank" not in sd:
        sys.exit(f"{st.setname}: the Type 3 bank and frame flag are not in MAME's state: "
                 f"save with scripts/mame/save_at.lua, which writes {sp.name}")

    # ---- the raster: lines and dots since vblank began, from the main CPU's time
    def t(name):
        return u(name + ".seconds") * 10**18 + u(name + ".attoseconds")
    now = t(":maincpu/0/m_localtime")
    vbs = t(":screen/0/m_vblank_start_time")
    scan, pix = u(":screen/0/m_scantime"), u(":screen/0/m_pixeltime")
    height = u(":screen/0/m_height")
    vis_y = u(":screen/0/m_visarea.max_y") - u(":screen/0/m_visarea.min_y") + 1
    min_x, width = u(":screen/0/m_visarea.min_x"), u(":screen/0/m_width")
    d = (now - vbs) % (scan * height)
    line, dot = d // scan, (d % scan) // pix
    vbl = height - vis_y
    # gx_video's vdump: 0x110 at the first active line, up to 0x1FF, on to 0x0F8
    v = 0x110 + vis_y + line if line < vbl else 0x110 + (line - vbl)
    if v > 0x1FF:
        v = 0x0F8 + (v - 0x200)
    hpix = (dot - min_x) % width
    g.set_sec("hdr", [0x4758, 0x5353, version(), sets.index(st.setname), v, hpix, 0, 0])

    # ---- the 68020 (Musashi): the active A7 is REG_D()[15]
    m = ":maincpu/0/"
    dar = arr(m + "REG_D()", 4)
    sr = u(m + "m_save_sr")
    isp = dar[15] if sr & 0x2000 else u(m + "REG_ISP()")
    usp = u(m + "REG_USP()") if sr & 0x2000 else dar[15]
    bank = dar[0:15] + [usp, u(m + "m_vbr"), u(m + "m_cacr"), (isp - 8) & 0xFFFFFFFF,
                        sr, u(m + "m_pc"), 0x007C, 1 if u(m + "m_save_stopped") & 1 else 0]
    g.set_sec("mcpu", [w for v32 in bank for w in (v32 >> 16, v32 & 0xFFFF)])

    # ---- the 68000 (MAME's microcoded one): m_da 15 is USP, 16 SSP
    s = ":soundcpu/0/"
    da = arr(s + "m_da", 4)
    ird, sub, ist = u(s + "m_ird"), u(s + "m_inst_substate"), u(s + "m_inst_state")
    if ird == 0x4E72:
        pc, stopped = u(s + "m_ipc") + 4, 1             # waiting in STOP: past it
    elif sub:
        pc, stopped = u(s + "m_ipc"), 0
        notes.append(f"the 68000 was mid-instruction (state {ist}, substate {sub}): restarted at {pc:06x}")
    else:
        pc, stopped = u(s + "m_pc") - 2, 0
    sbank = da[0:15] + [da[15], 0, 0, (da[16] - 6) & 0xFFFFFFFF, u(s + "m_sr"), pc & 0xFFFFFF, 0, stopped]
    g.set_sec("scpu", [w for v32 in sbank for w in (v32 >> 16, v32 & 0xFFFF)])

    # ---- gx_main's latches (gx_main.sv u_ss_board)
    mcur = arr(m + "m_input.m_curstate", 1)
    k56r = arr(":k056832/0/m_regs", 2)
    hs_cnt = min(line, 3) if line < vbl else 3
    # MAME's syncen bits 5 and 6 are set by the K053252's acknowledges and
    # cleared when the vblank / INT2 interrupt fires: the K053252's INT1 and
    # INT2 lines, which hold until acknowledged, are their inverse
    syncen = u(":/0/m_gx_syncen")
    t3 = [(sd["t3_bank"], 8), (sd["t3_frame"], 1)] if t34 else []
    g.set_sec("board", pack(t3 + [
        (0 if syncen & 0x20 else 1, 1), (0 if syncen & 0x40 else 1, 1),    # the K053252's INT1 INT2
        (0, 1), (hs_cnt, 2), (0, 1), (0, 1),                               # dma_pend hs_cnt lvbl_dt hs_dt
        (u(":/0/m_gx_rdport1_3") & 0xFF, 8), (syncen & 0x1F, 8),
        (1 if mcur[3] else 0, 1), (1 if mcur[4] else 0, 1), (0, 1),        # irq3 irq4 dma_run
        (0, 1), (0, 1), (1 if mcur[1] else 0, 1), (1 if mcur[2] else 0, 1),  # int1_l int2_l pend1 pend2
        (1 if line >= vbl else 0, 1), (0, 24),                             # lvbl_l dma_t
        (u(":/0/m_gx_wrport1_0"), 8), (u(":/0/m_gx_wrport1_1"), 8), (u(":/0/m_gx_wrport2") & 0xFF, 8),
        (k56r[0x19] & 0xFF, 8), (0, 16), (0, 16), (0, 1), (0, 1),          # vram_bank esc_hi p4_op p4_op_v p4_clk
        (u(":k056832/0/m_rom_half") & 1, 1)], 131 if t34 else 122) + [0] * (7 if t34 else 8))

    # ---- gx_sound's latches (gx_sound.sv u_ss_glue)
    scur = arr(s + "m_input.m_curstate", 1)
    si = arr(":dasp/0/si", 4)
    t0 = u(":k054539_1/0/m_timer_state") & 1
    g.set_sec("snd", pack([
        (u(":/0/m_sound_ctrl"), 8), (1 if scur[2] else 0, 1), (t0, 1), (0, 1),   # sctrl irq2 tim_l kp_own
        (0, 26), (0, 26), (0, 26), (0, 26),                                # kl0 kr0 kl1 kr1
        (si[3], 24), (si[2], 24), (si[1], 24), (si[0], 24),                # d_si
        (0, 16), (0, 16), (0, 10)], 253))                                  # aud_l aud_r smp_cnt

    # ---- K056800
    k8 = ":k056800/0/"
    h2s, s2h = list(it[k8 + "m_host_to_snd_regs"]), list(it[k8 + "m_snd_to_host_regs"])
    g.set_sec("k056800", pack([(h2s[0], 8), (h2s[1], 8), (h2s[2], 8), (h2s[3], 8), (s2h[0], 8), (s2h[1], 8),
                               (u(k8 + "m_int_enabled"), 1), (u(k8 + "m_int_pending"), 1),
                               (1 if scur[1] else 0, 1)], 51))

    # ---- 93C46: the cells (MAME: little-endian), then the serial state
    e = ":eeprom/0/"
    ed = it[e + "m_data"]
    cells = [ed[2 * i] | (ed[2 * i + 1] << 8) for i in range(64)]
    g.set_sec("eeprom", cells + pack([
        (u(e + "m_state"), 3), (u(e + "m_cs_state"), 1), (u(e + "m_clk_state"), 1), (u(e + "m_locked"), 1),
        (u(e + "m_command"), 8), (u(e + "m_bits_accum") & 31, 5), (u(e + "m_shift_register"), 32),
        (u(e + "m_address") & 63, 6), (0, 2), (0, 20)], 79))

    # ---- the K054539s
    for key, tag in (("k539a", ":k054539_1/0/"), ("k539b", ":k054539_2/0/")):
        r = list(it[tag + "m_regs"]) + [0] * (0x500 - 0x230)
        pl = list(it[tag + "m_posreg_latch"])
        # gx_k054539's vector, most significant first: the scalars, the voices
        # 7..0 { vpos, vpf, vval, vpval }, the channels' registers 7..0
        # { delta, vol, pan, rvl, rdl, lpos, cpos, hpos, ctype }
        chans, voices = [], []
        for c in range(7, -1, -1):
            b = r[0x20 * c:0x20 * c + 0x20]
            le = lambda k, n: sum(b[k + j] << (8 * j) for j in range(n))
            chans += [(le(0, 3), 24), (b[3], 8), (b[5], 8), (b[4], 8), (le(6, 2), 16), (le(8, 3), 24),
                      (le(0xC, 3), 24), (pl[3 * c] | (pl[3 * c + 1] << 8) | (pl[3 * c + 2] << 16), 24),
                      (r[0x200 + 2 * c], 8)]
            voices += [(le(0xC, 3), 24), (0, 16), (0, 16), (0, 16)]
        lflag = sum((r[0x201 + 2 * c] & 1) << c for c in range(8))
        scal = [(lflag, 8), (r[0x22C], 8), (r[0x22F], 8), (u(tag + "m_rom_addr") & 0xFF, 8),
                (u(tag + "m_cur_ptr") & 0x1FFFF, 17), (38 + r[0x227], 9), (0, 24), (1, 1),
                (u(tag + "m_timer_state") & 1, 1), (u(tag + "m_reverb_pos") & 0x1FFF, 13), (0, 26), (0, 26)]
        g.set_sec(key, r[:0x500] + pack(scal + voices + chans, 1877))

    # ---- the TMS57002
    dp = ":dasp/0/"
    sti = u(dp + "sti")
    prog, cmem = arr(dp + "0-ff", 4), arr(dp + "cmem", 4)
    dmem = arr(dp + "dmem0", 4) + arr(dp + "dmem1", 4) + [0] * (512 - 288)
    mem = []
    for v32 in prog:
        mem += [(v32 >> 16) & 0xFF, v32 & 0xFFFF]
    for v32 in cmem:
        mem += [v32 >> 16, v32 & 0xFFFF]
    for v32 in dmem:
        mem += [(v32 >> 16) & 0xFF, v32 & 0xFFFF]
    upd = arr(dp + "update", 4)
    host, so = list(it[dp + "host"]), arr(dp + "so", 4)
    regs = [(sti & 1, 1), (sti >> 1 & 1, 1), (0 if u(":/0/m_sound_ctrl") & 0x10 else 1, 1),
            (sti >> 5 & 1, 1), (sti >> 9 & 1, 1), (sti >> 10 & 1, 1), (sti >> 6 & 1, 1), (sti >> 7 & 1, 1),
            (sti >> 2 & 1, 1), ((sti >> 3) & 3, 2), (u(dp + "st0"), 24), (u(dp + "st1"), 22)]
    regs += [(u(dp + n), 8) for n in ("pc", "ca", "id", "ba0", "ba1", "rptc", "rptc_next", "sa")]
    regs += [(u(dp + "aacc"), 32), (u(dp + "macc"), 64), (u(dp + "macc_write"), 64), (u(dp + "xoa"), 32),
             (u(dp + "xba"), 19), (u(dp + "xwr"), 24), (u(dp + "xrd"), 24), (u(dp + "hidx"), 3),
             (u(dp + "update_counter_head"), 4), (u(dp + "update_counter_tail"), 4),
             (0, 3), (0, 3), (0, 64), (0, 1), (0, 1), (0, 1)]
    vec = pack([(upd[i], 32) for i in range(15, -1, -1)]
               + [(so[i], 24) for i in range(3, -1, -1)] + [(host[i], 8) for i in range(3, -1, -1)]
               + regs, 1104)
    g.set_sec("dsp", mem + vec)

    # ---- the register copy (gx_main's capture layout)
    rg = [0] * 216
    rg[0x00:0x20] = k56r
    tb = arr(":/0/m_gx_tilebanks", 4)
    for k in range(4):
        rg[0x20 + k] = ((tb[2 * k] & 0xFF) << 8) | (tb[2 * k + 1] & 0xFF)
    kx46 = list(it[":k055673/0/m_kx46_regs"])
    for k in range(4):
        rg[0x28 + k] = (kx46[2 * k] << 8) | kx46[2 * k + 1]
    rg[0x2C:0x34] = arr(":k055673/0/m_kx47_regs", 2)[0:8]
    crt = sd.get("k053252") if not k053252 else None
    rg[0x34:0x44] = [b << 8 for b in (crt or k053252_regs(st.setname, k053252))]
    k55 = list(it[":k055555/0/m_regs"])
    rg[0x44:0x84] = [k55[k] << 8 for k in range(64)]
    rg[0xC4:0xD4] = arr(":k054338/0/m_regs", 2)[0:16]
    rg[0xD4] = (u(":/0/m_gx_wrport1_0") << 8) | u(":/0/m_gx_wrport1_1")
    rg[0xD6] = u(":/0/m_gx_wrport2") & 0xFF
    g.set_sec("regs", rg)

    # ---- the RAMs
    def be32(name):
        return [w for v32 in arr(name, 4) for w in (v32 >> 16, v32 & 0xFFFF)]

    def bytes16(b):
        return [(b[2 * k] << 8) | b[2 * k + 1] for k in range(len(b) // 2)]
    g.set_sec("wram", be32(m + ":workram"))
    # 0xd90000: the palette, or (Type 3/4) plain RAM
    g.set_sec("pal", be32(m + (":palette" if m + ":palette" in it else "d90000-d97fff")))
    if t34:
        g.set_sec("psreg", be32(m + ":k053936_0_ctrl"))
        g.set_sec("psline", be32(m + ":k053936_0_line"))
        g.set_sec("mpal", be32(m + ":paletteram"))
        g.set_sec("spal", be32(m + ":subpaletteram"))
    g.set_sec("spr", arr(":k055673/0/m_ram", 2))
    g.set_sec("vram", arr(":k056832/0/m_videoram", 2)[:65536])
    g.set_sec("sram", arr(s + "100000-10ffff", 2))
    g.set_sec("kram", bytes16(it[":k054539_1/0/m_ram"]) + bytes16(it[":k054539_2/0/m_ram"]))
    g.set_sec("dram", bytes16(it[":dasp/1/0-3ffff"]))
    # MAME's ESC is C and saves nothing: the 056734 as the game leaves it after
    # start-up, its program loaded (scripts/k056734/synth.py)
    sys.path.insert(0, str(REPO / "scripts" / "k056734"))
    import synth
    if st.setname in synth.SETS:
        import build_rom_image
        region = build_rom_image.build(st.setname, "maincpu")
        wram = b"".join(struct.pack(">H", w) for w in g.sec("wram"))
        esch, escl, escr = synth.esc_sections(st.setname, region, wram)
        g.set_sec("esch", esch)
        g.set_sec("escl", escl)
        g.set_sec("escr", escr)
        notes.append("056734: kernel and program loaded fresh (MAME saves no ESC state)")
    g.write(out_path)
    print(f"{sta_path} ({st.setname}) -> {out_path}: raster line {v:#x} pixel {hpix}, "
          f"68020 PC {bank[20]:08x}, 68000 PC {pc:06x}")
    for n in notes:
        print("  " + n)


def cmd_from_mame(a):
    return from_mame(a.sta, a.out, a.k053252, a.side)


def unpack(words, width):
    """16-bit words, word 0 = bits 15:0 -> one integer of `width` bits."""
    v = 0
    for i, w in enumerate(words):
        v |= w << (16 * i)
    return v & ((1 << width) - 1)


def fields(v, spec):
    """Split v by [(name, bits)] most significant first."""
    out, pos = {}, sum(b for _, b in spec)
    for name, bits in spec:
        pos -= bits
        out[name] = (v >> pos) & ((1 << bits) - 1)
    return out


def template(setname, version):
    """A MAME state of the set, saved by this MAME at frame 600: the items
    the core does not hold (timers, streams, the screen) come from it."""
    sys.path.insert(0, str(REPO / "scripts"))
    import mame_sta
    p = REPO / "debug" / "sta_templates" / version / f"{setname}.sta"
    if not p.exists():
        import os
        import subprocess
        import tempfile
        exe = mame_sta.mame_exe()
        p.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as td:
            env = dict(os.environ, GX_SS_OUT=str(Path(td) / "items.tsv").replace("\\", "/"),
                       GX_SS_FRAME="600", GX_SS_STATE="t")
            subprocess.run([str(exe), setname, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
                            "-skip_gameinfo", "-nothrottle", "-seconds_to_run", "40",
                            "-autoboot_script", str(mame_sta.LUA),
                            "-rompath", f"{REPO / 'roms'};{exe.parent / 'roms'}",
                            "-state_directory", str(Path(td) / "sta"), "-nvram_directory", str(Path(td) / "nv"),
                            "-cfg_directory", str(Path(td) / "cfg")], cwd=exe.parent, env=env,
                           capture_output=True)
            src = Path(td) / "sta" / setname / "t.sta"
            if not src.exists():
                sys.exit(f"MAME did not save a template state for {setname}")
            p.write_bytes(src.read_bytes())
    return p


def to_mame(ss_path, out_path):
    sys.path.insert(0, str(REPO / "scripts"))
    import os
    import subprocess
    import tempfile
    import mame_sta
    g = GxState.read(ss_path)
    sets = mame_sets()
    h = g.sec("hdr")
    if h[0:2] != [0x4758, 0x5353] or h[2] != version():
        sys.exit(f"{ss_path}: not a version {version()} save state")
    setname = sets[h[3]]
    exe = mame_sta.mame_exe()
    ver = mame_sta.mame_version(exe)
    table = mame_sta.Table.find(ver, setname)
    st = mame_sta.State.read(template(setname, ver), table)
    it = st.items
    fix = []

    def put(name, vals, size):
        b = b"".join((v & ((1 << (8 * size)) - 1)).to_bytes(size, "little") for v in vals)
        if len(b) != len(it[name]):
            sys.exit(f"{name}: {len(b)} bytes for {len(it[name])}")
        it[name] = b

    def put1(name, v):
        put(name, [v], len(it[name]))

    def be32(words):
        return [(words[2 * i] << 16) | words[2 * i + 1] for i in range(len(words) // 2)]

    # ---- the 68020: STOP is re-entered by running it again (PC on the STOP)
    m = ":maincpu/0/"
    b = g.bank("mcpu")
    sr, isp, usp = b[19], (b[18] + 8) & 0xFFFFFFFF, b[15]
    pc = (b[20] - 4) if b[22] & 1 else b[20]
    put(m + "REG_D()", b[0:15] + [isp if sr & 0x2000 else usp], 4)
    put1(m + "REG_ISP()", isp)
    put1(m + "REG_USP()", usp)
    put1(m + "m_save_sr", sr)
    put1(m + "m_save_stopped", 0)
    put1(m + "m_vbr", b[16])
    put1(m + "m_cacr", b[17])
    fix.append(f"pc :maincpu {pc:x}")

    # ---- the 68000
    s = ":soundcpu/0/"
    sb = g.bank("scpu")
    da = sb[0:15] + [sb[15], (sb[18] + 6) & 0xFFFFFFFF]
    put(s + "m_da", da, 4)
    put1(s + "m_sr", sb[19])
    put1(s + "m_inst_substate", 0)
    spc = (sb[20] - 4) if sb[22] & 1 else sb[20]
    fix.append(f"pc :soundcpu {spc:x}")

    # ---- gx_main's latches
    bd = fields(unpack(g.sec("board"), 131 if g.t34 else 122), ([("t3_bank", 8), ("t3_frame", 1)] if g.t34 else []) + [
        ("int1", 1), ("int2", 1), ("dma_pend", 1), ("hs_cnt", 2), ("lvbl_dt", 1), ("hs_dt", 1), ("rdport1_3", 8), ("syncen", 8),
        ("irq3", 1), ("irq4", 1), ("dma_run", 1), ("int1_l", 1), ("int2_l", 1), ("pend1", 1), ("pend2", 1),
        ("lvbl_l", 1), ("dma_t", 24), ("wrport1_0", 8), ("wrport1_1", 8), ("wrport2", 8), ("vram_bank", 8),
        ("esc_hi", 16), ("p4_op", 16), ("p4_op_v", 1), ("p4_clk", 1), ("rom_half", 1)])
    put1(":/0/m_gx_wrport1_0", bd["wrport1_0"])
    put1(":/0/m_gx_wrport1_1", bd["wrport1_1"])
    put1(":/0/m_gx_wrport2", bd["wrport2"])
    put1(":/0/m_gx_rdport1_3", bd["rdport1_3"])
    put1(":/0/m_gx_syncen", bd["syncen"] | (0 if bd["int1"] else 0x20) | (0 if bd["int2"] else 0x40))

    # ---- gx_sound's latches
    sg = fields(unpack(g.sec("snd"), 253), [
        ("sctrl", 8), ("irq2", 1), ("tim_l", 1), ("kp_own", 1), ("kl0", 26), ("kr0", 26), ("kl1", 26),
        ("kr1", 26), ("si3", 24), ("si2", 24), ("si1", 24), ("si0", 24), ("aud_l", 16), ("aud_r", 16),
        ("smp_cnt", 10)])
    put1(":/0/m_sound_ctrl", sg["sctrl"])

    # ---- K056800
    k8 = fields(unpack(g.sec("k056800"), 51), [("h0", 8), ("h1", 8), ("h2", 8), ("h3", 8), ("s0", 8),
                                               ("s1", 8), ("en", 1), ("pend", 1), ("irq", 1)])
    put(":k056800/0/m_host_to_snd_regs", [k8["h0"], k8["h1"], k8["h2"], k8["h3"]], 1)
    put(":k056800/0/m_snd_to_host_regs", [k8["s0"], k8["s1"]], 1)
    put1(":k056800/0/m_int_enabled", k8["en"])
    put1(":k056800/0/m_int_pending", k8["pend"])

    # ---- 93C46
    ee = g.sec("eeprom")
    put(":eeprom/0/m_data", [c for w in ee[0:64] for c in (w & 0xFF, w >> 8)], 1)
    es = fields(unpack(ee[64:69], 79), [("st", 3), ("cs", 1), ("sk", 1), ("locked", 1), ("cmd", 8),
                                        ("nbits", 5), ("sh", 32), ("addr", 6), ("op", 2), ("busy", 20)])
    for k, n in (("st", "m_state"), ("cs", "m_cs_state"), ("sk", "m_clk_state"), ("locked", "m_locked"),
                 ("cmd", "m_command"), ("sh", "m_shift_register"), ("addr", "m_address")):
        put1(":eeprom/0/" + n, es[k])

    # ---- the K054539s: registers, position latches, the 0x22d pointer, reverb
    spec = [("lflag", 8), ("act", 8), ("r22f", 8), ("rom_addr", 8), ("cur_ptr", 17), ("tstep", 9),
            ("tacc", 24), ("t_run", 1), ("timer_out", 1), ("rpos", 13), ("out_l", 26), ("out_r", 26)]
    for c in range(7, -1, -1):
        spec += [(f"vpos{c}", 24), (f"vpf{c}", 16), (f"vval{c}", 16), (f"vpval{c}", 16)]
    for c in range(7, -1, -1):
        spec += [(f"{n}{c}", w) for n, w in (("delta", 24), ("vol", 8), ("pan", 8), ("rvl", 8), ("rdl", 16),
                                             ("lpos", 24), ("cpos", 24), ("hpos", 24), ("ctype", 8))]
    for key, tag in (("k539a", ":k054539_1/0/"), ("k539b", ":k054539_2/0/")):
        w = g.sec(key)
        f = fields(unpack(w[0x500:], 1877), spec)
        put(tag + "m_regs", [x & 0xFF for x in w[0:0x230]], 1)
        put(tag + "m_posreg_latch", [(f[f"hpos{c}"] >> (8 * j)) & 0xFF for c in range(8) for j in range(3)], 1)
        put1(tag + "m_cur_ptr", f["cur_ptr"])
        put1(tag + "m_rom_addr", f["rom_addr"])
        put1(tag + "m_reverb_pos", f["rpos"])
        put1(tag + "m_timer_state", f["timer_out"])

    # ---- the TMS57002
    dp = ":dasp/0/"
    dw = g.sec("dsp")
    put(dp + "0-ff", [(dw[2 * i] << 16) | dw[2 * i + 1] for i in range(256)], 4)
    put(dp + "cmem", [(dw[0x200 + 2 * i] << 16) | dw[0x201 + 2 * i] for i in range(256)], 4)
    dmem = [(dw[0x400 + 2 * i] << 16) | dw[0x401 + 2 * i] for i in range(512)]
    put(dp + "dmem0", dmem[0:256], 4)
    put(dp + "dmem1", dmem[256:288], 4)
    dspec = [(f"upd{i}", 32) for i in range(15, -1, -1)] \
        + [(f"so{i}", 24) for i in range(3, -1, -1)] + [(f"host{i}", 8) for i in range(3, -1, -1)] \
        + [("pload", 1), ("cload", 1), ("in_rst", 1), ("idle", 1), ("hostf", 1), ("upd", 1), ("rd", 1),
           ("wr", 1), ("cval", 1), ("su", 2), ("st0", 24), ("st1", 22), ("pc", 8), ("ca", 8), ("id", 8),
           ("ba0", 8), ("ba1", 8), ("rptc", 8), ("rptc_next", 8), ("sa", 8), ("aacc", 32), ("macc", 64),
           ("mw", 64), ("xoa", 32), ("xba", 19), ("xwr", 24), ("xrd", 24), ("hidx", 3), ("uh", 4), ("ut", 4),
           ("xcnt", 3), ("xlo", 3), ("xg", 64), ("xg_ok", 1), ("xlate", 1), ("sync_pend", 1)]
    d = fields(unpack(dw[0x800:], 1104), dspec)
    sti = (d["pload"] | d["cload"] << 1 | d["cval"] << 2 | d["su"] << 3 | d["idle"] << 5 | d["rd"] << 6
           | d["wr"] << 7 | d["hostf"] << 9 | d["upd"] << 10)
    put1(dp + "sti", sti)
    for n in ("pc", "ca", "id", "ba0", "ba1", "rptc", "rptc_next", "sa", "st0", "st1", "aacc", "macc",
              "xoa", "xba", "xwr", "xrd", "hidx"):
        put1(dp + n, d[n])
    put1(dp + "macc_write", d["mw"])
    put1(dp + "update_counter_head", d["uh"])
    put1(dp + "update_counter_tail", d["ut"])
    put(dp + "host", [d[f"host{i}"] for i in range(4)], 1)
    put(dp + "update", [d[f"upd{i}"] for i in range(16)], 4)
    put(dp + "so", [d[f"so{i}"] for i in range(4)], 4)
    put(dp + "si", [sg["si0"], sg["si1"], sg["si2"], sg["si3"]], 4)

    # ---- the RAMs
    def bytes_of(words):
        return [x for w in words for x in (w >> 8, w & 0xFF)]
    put(m + ":workram", be32(g.sec("wram")), 4)
    put(":k055673/0/m_ram", g.sec("spr"), 2)
    vr = g.sec("vram")
    # MAME's 17th page (k056832 allocates one past the 16) stays the template's
    tail = it[":k056832/0/m_videoram"][2 * 65536:]
    put(":k056832/0/m_videoram", vr + [int.from_bytes(tail[k:k + 2], "little") for k in range(0, len(tail), 2)], 2)
    put(":k056832/0/m_all_lines_dirty", [1] * 16, 1)
    put(s + "100000-10ffff", g.sec("sram"), 2)
    kr = bytes_of(g.sec("kram"))
    put(":k054539_1/0/m_ram", kr[0:32768], 1)
    put(":k054539_2/0/m_ram", kr[32768:65536], 1)
    put(":dasp/1/0-3ffff", bytes_of(g.sec("dram")), 1)

    # ---- through MAME's handlers: the palette and the chips' registers
    pal = be32(g.sec("pal"))
    if g.t34:
        # plain RAM at 0xd90000; the rest is RAM too, but for the bank register
        put(m + "d90000-d97fff", pal, 4)
        put(m + ":k053936_0_ctrl", be32(g.sec("psreg")), 4)
        put(m + ":k053936_0_line", be32(g.sec("psline")), 4)
        put(m + ":paletteram", be32(g.sec("mpal")), 4)
        put(m + ":subpaletteram", be32(g.sec("spal")), 4)
        fix.append(f"w32 e40000 {bd['t3_bank'] << 24:x}")
    else:
        fix += [f"w32 {0xD90000 + 4 * i:x} {v:x}" for i, v in enumerate(pal)]
    rg = g.sec("regs")
    fix += [f"w16 {0xD40000 + 2 * k:x} {rg[k]:x}" for k in range(0x20)]
    fix += [f"w16 {0xD44000 + 2 * k:x} {rg[0x20 + k]:x}" for k in range(4)]
    fix += [f"w16 {0xD48000 + 2 * k:x} {rg[0x28 + k]:x}" for k in range(4)]
    fix += [f"w16 {0xD4A010 + 2 * k:x} {rg[0x2C + k]:x}" for k in range(8)]
    fix += [f"w16 {0xD50000 + 2 * k:x} {rg[0x44 + k]:x}" for k in range(64)]
    fix += [f"w16 {0xD80000 + 2 * k:x} {rg[0xC4 + k]:x}" for k in range(16)]

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        (td / "sta" / setname).mkdir(parents=True)
        st.write(td / "sta" / setname / "in.sta", table)
        (td / "fix.txt").write_text("\n".join(fix) + "\n")
        env = dict(os.environ, GX_SS_FIXUP=str(td / "fix.txt").replace("\\", "/"), GX_SS_OUT="out")
        p = subprocess.run([str(exe), setname, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
                            "-skip_gameinfo", "-nothrottle", "-seconds_to_run", "3600", "-state", "in",
                            "-autoboot_script", str(REPO / "scripts" / "mame" / "ss_fixup.lua"),
                            "-rompath", f"{REPO / 'roms'};{exe.parent / 'roms'}",
                            "-state_directory", str(td / "sta"), "-nvram_directory", str(td / "nv"),
                            "-cfg_directory", str(td / "cfg")], cwd=exe.parent, env=env,
                           capture_output=True, text=True)
        res = td / "sta" / setname / "out.sta"
        if "GX_FIXUP_OK" not in p.stdout + p.stderr or not res.exists():
            Path(str(out_path) + ".in.sta").write_bytes((td / "sta" / setname / "in.sta").read_bytes())
            sys.exit(f"MAME's fixup pass failed (the state it was given: {out_path}.in.sta):\n"
                     + "\n".join((p.stdout + p.stderr).splitlines()[-15:]))
        Path(out_path).write_bytes(res.read_bytes())
    print(f"{ss_path} ({setname}) -> {out_path}: 68020 PC {pc:08x}, 68000 PC {spc:06x}; "
          f"load it with: mame {setname} -state <name>, the file in sta/{setname}/")


def cmd_to_mame(a):
    to_mame(a.ss, a.out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info")
    p.add_argument("ss")
    p.set_defaults(fn=cmd_info)
    p = sub.add_parser("diff")
    p.add_argument("a")
    p.add_argument("b")
    p.set_defaults(fn=cmd_diff)
    p = sub.add_parser("from-mame", help="a MAME 0.289 .sta to a .ss")
    p.add_argument("sta")
    p.add_argument("out")
    p.add_argument("--k053252", help="the set's K053252 registers, 16 hex bytes (MAME has no K053252)")
    p.add_argument("--side", help="save_at.lua's JSON (default: <sta>.json)")
    p.set_defaults(fn=cmd_from_mame)
    p = sub.add_parser("to-mame", help="a .ss to a MAME 0.289 .sta (runs MAME once)")
    p.add_argument("ss")
    p.add_argument("out")
    p.set_defaults(fn=cmd_to_mame)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
