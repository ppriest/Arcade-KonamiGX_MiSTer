# jtframe (the tool) provenance

The Go program jotego uses to **generate** register-decode modules, vendored from
<https://github.com/jotego/jtcores> at commit `e7958c86d79d549cf5b14b7bbdb517b109a21691`, path
`modules/jtframe/src/jtframe/`. **Verbatim.** GPL-3.0-or-later; see
[`../../THIRD-PARTY.md`](../../THIRD-PARTY.md).

This is the **tool**, not jotego's HDL framework. The handful of jtframe *HDL* files this project
actually instantiates are in `rtl/jtframe/`, taken one at a time; `sys/` is this project's
framework and there is no intention of adopting another.

## Why it is here

`jt05415x.v` (tilemaps) and `jtk053252.v` (CRTC) instantiate `*_mmr.v` modules that jotego generates
rather than commits. Without this tool those two modules cannot be built at all, and the project
would be reduced to hand-reconstructing generated files from `cfg/mmr.yaml` — which would drift
silently against upstream.

It lived in a scratch directory while the chipset was being vendored. That was fine for one
afternoon and wrong as a dependency: a tool needed to rebuild committed source belongs in the tree.

## Building it

```
tools/jtframe/build.sh          # -> tools/jtframe/jtframe.exe (gitignored)
```

Needs Go. On this machine: `pacman -S mingw-w64-x86_64-go`, and `GOROOT` must be set because MSYS2's
Go binary is trimmed and cannot find its own — `build.sh` defaults it to
`/e/msys64/mingw64/lib/go`.

Dependencies are fetched per `src/go.sum`, which pins them by hash, so the build needs network
access the first time. `go mod vendor` inside `src/` would remove that, at the cost of carrying
around twenty third-party Go modules (pflag, cobra, sprig, yaml.v2 and their transitive set) in this
repository, each with its own licence to record. Not done; reconsider if an offline build is ever
needed.

`jtframe.exe` is a build product and is gitignored.

## Regenerating

```
JTCORES=/path/to/jtcores scripts/regen_mmr.sh --check   # diff against what is committed
JTCORES=/path/to/jtcores scripts/regen_mmr.sh           # rewrite them
```

**A jtcores checkout is still required**, and only the tool is vendored. The generator reads its Go
template from `$JTFRAME/hdl/inc/mmr.v` *and* other data files during start-up
(`hdl/sound/audio_mod.yaml` is the next one it reaches), and the per-chip register maps come from
`cfg/mmr.yaml` in the cores and modules themselves. Vendoring only the template was tried and fails
on the next file; pinning the template against an unpinned yaml would be a split-brain in any case.
So both come from the same snapshot.

A sparse clone is enough:

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/jotego/jtcores.git
git -C jtcores sparse-checkout set modules/jtframe modules/jt05415x cores/rungun cores/moo cores/simson
```

## This project commits generated files, and upstream says not to

The generator's own template opens with:

> `Do not add generated *_mmr.v files to git.`

This project does anyway, for `jtk053252_mmr.v`, `jt054156_mmr.v`, `jt054157_mmr.v` and
`jt053246_mmr.v`. The reason: nothing here is built with jtframe's build system. Quartus reads
`files.qip` and the benches read `sim/<tb>/files.f`, and both need the files to exist. Requiring
every checkout to install Go and clone jtcores before it could compile would be a worse trade.

Note the rule is not absolute upstream either — jotego commits `cores/simson/hdl/jt053246_mmr.v`.

The cost of the choice is drift, and `scripts/regen_mmr.sh --check` is what makes drift detectable.
**Run it after any change to the jtcores snapshot.**

## Verification

The tool was checked against upstream's own output before anything was trusted to it:
`cores/simson/hdl/jt053246_mmr.v` is one jotego commits, and regenerating it with this build
reproduced the committed file byte-for-byte.

With the tool vendored here, all four generated modules in this repository reproduce identically:

```
  same     rtl/video/k055673/jt053246_mmr.v
  same     rtl/video/k053252/jtk053252_mmr.v
  same     rtl/video/k056832/jt054156_mmr.v
  same     rtl/video/k056832/jt054157_mmr.v
```
