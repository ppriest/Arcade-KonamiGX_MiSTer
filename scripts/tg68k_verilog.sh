#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# TG68KdotC_Kernel (VHDL, rtl/cpu/tg68k) converted to Verilog with GHDL's
# synthesis, for the Verilator benches. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/tg68k_verilog.sh        # -> obj_verilator/tg68k_ghdl/TG68KdotC_Kernel.v
#
# scripts/run_verilator.sh calls this when a bench lists that file and it is
# older than the VHDL. The generics are fixed at conversion to gx_main.sv's
# values; the output module declares them as parameters again, only so the
# instance compiles unchanged, and stops the simulation if an instance asks
# for other values. --latches: GHDL reports latches on exe_condition and
# four ALU signals (combinational processes that do not assign them on every
# path) and refuses without it; Quartus builds the same VHDL.
#
# TOOLS: GHDL 6 (MSYS2 MinGW64, mingw-w64-x86_64-ghdl-mcode).
set -euo pipefail

MSYS="${MSYS2_ROOT:-/e/msys64}"
if ! command -v ghdl >/dev/null 2>&1; then
	[ -x "$MSYS/usr/bin/bash.exe" ] || { echo "MSYS2 not found. Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && exec scripts/tg68k_verilog.sh' _ "$(pwd -W 2>/dev/null || pwd)"
fi

[ -d sys ] || { echo "run me from the repository root"; exit 1; }

GEN="SR_Read=2 VBR_Stackframe=2 extAddr_Mode=2 MUL_Mode=2 DIV_Mode=2 BitField=2 BarrelShifter=0 MUL_Hardware=1"
OUT=obj_verilator/tg68k_ghdl
SRC=rtl/cpu/tg68k
mkdir -p "$OUT"
( cd "$OUT"
  rm -f work-obj08.cf
  ghdl -a --std=08 -fsynopsys ../../$SRC/TG68K_Pack.vhd ../../$SRC/TG68K_ALU.vhd ../../$SRC/TG68KdotC_Kernel.vhd
  ghdl --synth --std=08 -fsynopsys --latches --out=verilog \
	$(for g in $GEN; do printf -- '-g%s ' "$g"; done) TG68KdotC_Kernel \
	> TG68KdotC_Kernel.raw.v 2> synth.log || { cat synth.log; exit 1; } )

# module TG68KdotC_Kernel  ->  module TG68KdotC_Kernel #(parameter ...) + a check
PARAMS=$(for g in $GEN; do printf 'parameter integer %s, ' "${g/=/ = }"; done)
CHECK=$(for g in $GEN; do printf '(%s != %s) || ' "${g%=*}" "${g#*=}"; done)
awk -v p="${PARAMS%, }" -v c="${CHECK% || }" '
	/^module TG68KdotC_Kernel$/ { print "module TG68KdotC_Kernel #(" p ")"; hold = 1; next }
	hold && /\);$/ { print; print "  initial if (" c ") $fatal(1, \"TG68KdotC_Kernel: converted with other generics (scripts/tg68k_verilog.sh)\");"; hold = 0; next }
	{ print }' "$OUT/TG68KdotC_Kernel.raw.v" > "$OUT/TG68KdotC_Kernel.v"
rm "$OUT/TG68KdotC_Kernel.raw.v"
echo "$OUT/TG68KdotC_Kernel.v: $(wc -l < "$OUT/TG68KdotC_Kernel.v") lines"
