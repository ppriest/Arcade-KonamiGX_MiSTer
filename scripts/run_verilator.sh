#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build and run one testbench with Verilator. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_verilator.sh gx_obj_tb [-GNAME=value ...] [+plusargs ...]
#
# Ported from Arcade-Seta_MiSTer. The fast second simulator (WORKFLOW
# section 10): two-state, no VHDL -- the TG68K.C benches stay on ModelSim --
# and a disagreement with ModelSim is a finding, not a nuisance.
#
# The bench's sources are listed in sim/<tb>/verilator.files: unlike
# scripts/run_sim.sh this does not compile all of rtl/, because Verilator
# parses every file it is given and not all vendored code is clean for it.
# -G arguments are top-level parameter overrides and go to the build; the
# rest go to the run. Output is in obj_verilator/<tb>/ (git-ignored), not
# build/, which is scripts/build_staged.py's Quartus worktree.
#
# TOOLS: the MSYS2 MinGW64 install (verilator, g++, make, perl). The script
# re-executes itself under that environment when started from Git bash,
# whose PATH has none of them. hwlock does not apply: Verilator never
# touches JTAG and is not a Quartus/ModelSim process.
set -euo pipefail

TB="${1:?usage: scripts/run_verilator.sh <testbench-dir-name> [-Gparam=v] [plusargs...]}"
shift

MSYS="${MSYS2_ROOT:-/e/msys64}"
if ! command -v verilator >/dev/null 2>&1; then
	[ -x "$MSYS/usr/bin/bash.exe" ] || { echo "MSYS2 not found. Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && shift && exec scripts/run_verilator.sh "$@"' _ "$(pwd -W 2>/dev/null || pwd)" "$TB" "$@"
fi

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -f "sim/$TB/verilator.files" ] || { echo "no sim/$TB/verilator.files"; exit 1; }

GEN=(); RUN=()
for a in "$@"; do
	case "$a" in -G*) GEN+=("$a") ;; *) RUN+=("$a") ;; esac
done

# A parameter override changes the model, so it gets its own build directory
OUT="obj_verilator/$TB$(printf '%s' "${GEN[@]+"${GEN[@]}"}" | tr -c 'A-Za-z0-9_' '_')"
mkdir -p "$OUT"
verilator --binary --timing -j 0 -O3 -DSIMULATION \
	-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	"${GEN[@]+"${GEN[@]}"}" \
	--top-module "tb_${TB%_tb}" --Mdir "$OUT" -f "sim/$TB/verilator.files" \
	> "$OUT/build.log" 2>&1 || { grep -E "%Error|error:" "$OUT/build.log" | head -30; exit 1; }

"$OUT/Vtb_${TB%_tb}" "${RUN[@]+"${RUN[@]}"}"
