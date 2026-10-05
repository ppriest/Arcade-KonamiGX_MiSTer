#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) Paul Priest
"""MAME .sta save states, read and written without MAME, for one MAME version.

    python scripts/mame_sta.py table daiskiss            # MAME's item table for a set
    python scripts/mame_sta.py info  path/to/1.sta       # header, checks, CPU summary
    python scripts/mame_sta.py dump  path/to/1.sta out/  # every item to out/<name>.bin

A .sta (src/emu/save.cpp, SAVE_VERSION 2) is a 32-byte header -- "MAMESAVE",
version, endian flag, set name, signature -- then one zlib stream holding every
registered save item, sorted by name, back to back. Nothing in the file says
where an item starts: the order and sizes are the running MAME's registry, and
the signature is a CRC32 over each item's name and sizes. So a file can only
be read with the registry of the MAME build that wrote it.

`table` gets that registry from MAME itself (scripts/mame/ss_items.lua) and
keeps it in scripts/mame/sta_items/<version>/<set>.tsv with the signature of a state
saved in the same run. A file whose signature differs is refused.

Lua names only the items registered under a device tag. Scheduler timers,
sound-stream buffers and "global" items have no device; they are kept as
"#<index>" and carried through unchanged.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TABLES = REPO / "scripts" / "mame" / "sta_items"
LUA = REPO / "scripts" / "mame" / "ss_items.lua"
HEADER = 32


def load_env():
    env = {}
    for f in (Path(os.environ.get("MISTER_CORE_ENV") or Path.home() / ".mister-core.env"),
              REPO / "mister.env"):
        if f.exists():
            for ln in f.read_text(encoding="utf-8", errors="replace").splitlines():
                ln = ln.strip()
                if ln and not ln.startswith("#") and "=" in ln:
                    k, v = ln.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def mame_exe():
    env = load_env()
    d = Path(os.environ.get("MAME_DIR") or env.get("MAME_DIR") or ".")
    return d / (os.environ.get("MAME_EXE") or env.get("MAME_EXE") or "mame.exe")


def mame_version(exe):
    out = subprocess.run([str(exe), "-version"], capture_output=True, text=True).stdout
    v = "%04d" % int(out.split()[0].split(".")[1])
    # a build from git between releases, "0.289 (mame0289-1340-g352a5fbb8bb)", has its own registry
    tag = out.split("(")[1].split(")")[0] if "(" in out else ""
    return v + "-" + tag.split("-", 1)[1] if "-" in tag else v


class Table:
    """One set's registry: items in file order, each (name, size, count)."""

    def __init__(self, path):
        self.path = Path(path)
        self.items = []
        self.signature = None
        for ln in self.path.read_text(encoding="utf-8").splitlines():
            if ln.startswith("# signature"):
                self.signature = int(ln.split()[2], 16)
            elif ln and not ln.startswith("#"):
                i, size, count, tag, name = ln.split("\t")
                full = f"#{i}" if tag == "?" else f"{tag}/{name}"
                self.items.append((full, int(size), int(count)))
        self.index = {n: k for k, (n, _, _) in enumerate(self.items)}
        self.total = sum(s * c for _, s, c in self.items)

    @staticmethod
    def find(version, setname):
        p = TABLES / version / f"{setname}.tsv"
        if not p.exists():
            sys.exit(f"no item table {p}: run `python scripts/mame_sta.py table {setname}`")
        return Table(p)


class State:
    """A decoded .sta: the header fields and every item's bytes, by name."""

    def __init__(self, setname, signature, items, flags=0):
        self.setname, self.signature, self.items, self.flags = setname, signature, items, flags

    @staticmethod
    def read(path, table=None, version=None):
        raw = Path(path).read_bytes()
        if raw[:8] != b"MAMESAVE":
            sys.exit(f"{path}: not a MAME save state")
        if raw[8] != 2:
            sys.exit(f"{path}: save version {raw[8]}, this reads version 2")
        if raw[9] & 1:
            sys.exit(f"{path}: big-endian state, not handled")
        setname = raw[10:28].split(b"\0")[0].decode()
        sig = struct.unpack_from("<I", raw, 28)[0]
        if table is None:
            table = Table.find(version or mame_version(mame_exe()), setname)
        if sig != table.signature:
            sys.exit(f"{path}: signature {sig:08x}, table {table.path.name} has "
                     f"{table.signature:08x}: saved by a different MAME build or set")
        data = zlib.decompress(raw[HEADER:])
        if len(data) != table.total:
            sys.exit(f"{path}: {len(data)} bytes of items, table says {table.total}")
        items, off = {}, 0
        for name, size, count in table.items:
            items[name] = data[off:off + size * count]
            off += size * count
        return State(setname, sig, items, raw[9])

    def write(self, path, table):
        if self.signature != table.signature:
            sys.exit("state and table signatures differ")
        hdr = bytearray(HEADER)
        hdr[0:8] = b"MAMESAVE"
        hdr[8] = 2
        hdr[9] = self.flags
        hdr[10:10 + len(self.setname)] = self.setname.encode()
        struct.pack_into("<I", hdr, 28, self.signature)
        body = bytearray()
        for name, size, count in table.items:
            b = self.items[name]
            if len(b) != size * count:
                sys.exit(f"{name}: {len(b)} bytes, table says {size * count}")
            body += b
        Path(path).write_bytes(bytes(hdr) + zlib.compress(bytes(body), 6))

    # little-endian accessors: MAME on x86 writes native order
    def u(self, name, i=0, size=None):
        b = self.items[name]
        size = size or (len(b) if len(b) <= 8 else 4)
        return int.from_bytes(b[i * size:(i + 1) * size], "little")

    def set_u(self, name, value, i=0, size=None):
        b = bytearray(self.items[name])
        size = size or (len(b) if len(b) <= 8 else 4)
        b[i * size:(i + 1) * size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, "little")
        self.items[name] = bytes(b)


def cmd_table(a):
    exe = mame_exe()
    ver = mame_version(exe)
    out = TABLES / ver / f"{a.set}.tsv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        env = dict(os.environ, GX_SS_OUT=str(td / "items.tsv").replace("\\", "/"),
                   GX_SS_FRAME=str(a.frame), GX_SS_STATE="t")
        cmd = [str(exe), a.set, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
               "-skip_gameinfo", "-nothrottle", "-seconds_to_run", str(a.frame // 50 + 10),
               "-autoboot_script", str(LUA),
               "-rompath", f"{REPO / 'roms'};{exe.parent / 'roms'}",
               "-state_directory", str(td / "sta"), "-nvram_directory", str(td / "nv"),
               "-cfg_directory", str(td / "cfg")]
        subprocess.run(cmd, cwd=exe.parent, env=env, capture_output=True)
        sta = td / "sta" / a.set / "t.sta"
        if not sta.exists() or not (td / "items.tsv").exists():
            sys.exit("MAME did not write the table and state")
        raw = sta.read_bytes()
        sig = struct.unpack_from("<I", raw, 28)[0]
        rows = (td / "items.tsv").read_text(encoding="utf-8")
        out.write_text(f"# MAME 0.{int(ver[:4])}{ver[4:]} {a.set}: save-state registry, file order\n"
                       f"# signature {sig:08x}\n"
                       f"# index\tsize\tcount\tdevice\tname  (? = no device: timer, stream, global)\n"
                       + rows, encoding="utf-8", newline="\n")
        t = Table(out)
        n = len(zlib.decompress(raw[HEADER:]))
        if n != t.total:
            sys.exit(f"table sums to {t.total} bytes, MAME's state holds {n}")
        named = sum(1 for nm, _, _ in t.items if not nm.startswith("#"))
        print(f"{out}: {len(t.items)} items ({named} named), {t.total} bytes, signature {sig:08x}")


def cmd_info(a):
    st = State.read(a.sta)
    print(f"{a.sta}: {st.setname}, signature {st.signature:08x}, {len(st.items)} items")
    m, s = ":maincpu/0/", ":soundcpu/0/"
    d = [st.u(m + "REG_D()", i) for i in range(16)]
    print(f"maincpu  PC {st.u(m + 'm_pc'):08x} SR {st.u(m + 'm_save_sr'):04x} "
          f"stopped {st.u(m + 'm_save_stopped')} USP {st.u(m + 'REG_USP()'):08x} "
          f"ISP {st.u(m + 'REG_ISP()'):08x} VBR {st.u(m + 'm_vbr'):08x}")
    print("         D " + " ".join(f"{v:08x}" for v in d[:8]))
    print("         A " + " ".join(f"{v:08x}" for v in d[8:]))
    da = [st.u(s + "m_da", i) for i in range(17)]
    sub = st.u(s + "m_inst_substate")
    print(f"soundcpu IPC {st.u(s + 'm_ipc'):06x} PC {st.u(s + 'm_pc'):06x} "
          f"SR {st.u(s + 'm_sr'):04x} state {st.u(s + 'm_inst_state')} substate {sub}"
          + ("  (mid-instruction)" if sub else ""))
    print("         D " + " ".join(f"{v:08x}" for v in da[:8]))
    print("         A " + " ".join(f"{v:08x}" for v in da[8:16]) + f"  SP' {da[16]:08x}")


def cmd_dump(a):
    st = State.read(a.sta)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, b in st.items.items():
        fn = name.replace(":", "").replace("/", "_").replace("()", "").strip("_") or "root"
        (out / f"{fn}.bin").write_bytes(b)
    print(f"{len(st.items)} items -> {out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("table")
    p.add_argument("set")
    p.add_argument("--frame", type=int, default=600)
    p.set_defaults(fn=cmd_table)
    p = sub.add_parser("info")
    p.add_argument("sta")
    p.set_defaults(fn=cmd_info)
    p = sub.add_parser("dump")
    p.add_argument("sta")
    p.add_argument("out")
    p.set_defaults(fn=cmd_dump)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
