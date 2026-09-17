#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run one of jotego's vendored unit benches. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_jt_unit.sh k053252_tb
#
# These are NOT this project's benches and they are not run by run_sim.sh.
# They are the upstream regressions that came with the vendored modules, and
# WORKFLOW section 12 makes running them the rule: a vendored block that fails
# its own tests is a porting problem, and finding that out after GX-specific
# edits is how a day is lost.
#
# WHY A SECOND RUNNER
#
# jotego's unit benches are written for Icarus Verilog, not ModelSim. Upstream
# drives them with modules/jtframe/bin/simunit.sh, which was not portable to
# this machine as-is -- it needs $JTROOT/$JTFRAME/$JTBIN set, a Go helper per
# bench, `envsubst`, and `.` on PATH for the binary it builds. Rather than
# reproduce that environment, this script calls iverilog with the same file
# list that bench's gather.f names. The file lists live in sim/<bench>/files.f
# here, one path per line, relative to the repository root.
#
# hwlock is deliberately NOT taken: Icarus is neither Quartus nor ModelSim, so
# it is not a hazard to a JTAG session, for the same reason Verilator is not.
set -euo pipefail

TB="${1:?usage: scripts/run_jt_unit.sh <testbench-dir-name>}"
shift || true

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -d "sim/$TB" ] || { echo "no such testbench: sim/$TB"; exit 1; }
[ -f "sim/$TB/files.f" ] || { echo "sim/$TB/files.f missing"; exit 1; }

IV=""
for _c in "${IVERILOG_BIN:-}" /e/msys64/mingw64/bin /c/msys64/mingw64/bin; do
  [ -n "$_c" ] && [ -x "$_c/iverilog.exe" ] && IV="$_c" && break
done
if [ -z "$IV" ] && command -v iverilog >/dev/null 2>&1; then
  IV="$(dirname "$(command -v iverilog)")"
fi
[ -n "$IV" ] || { echo "Icarus Verilog not found. Set IVERILOG_BIN."; exit 1; }

# Icarus writes a scratch file to TMP and dies if that directory is absent;
# on this box the inherited TMP was C:\TEMP, which does not exist.
OUT="simout/jt_unit/$TB"
mkdir -p "$OUT"
export TMPDIR="$PWD/$OUT"

mapfile -t FILES < <(grep -vE '^\s*(#|$)' "sim/$TB/files.f")

echo "--- iverilog: $TB ---"
"$IV/iverilog.exe" -g2012 -o "$OUT/sim.vvp" -s test \
    -D SIMULATION -D JTFRAME_MCLK=48000000 \
    -I sim/jtframe_ver "$@" "${FILES[@]}"

# Run from the bench directory: these benches open relative files, and the
# upstream runner runs them there.
echo "--- vvp ---"
( cd "sim/$TB" && "$IV/vvp.exe" "../../$OUT/sim.vvp" ) | tee "$OUT/sim.log"

# The bench reports its own verdict; make the script's exit status follow it
# rather than iverilog's, which is 0 for a bench that ran and failed.
if grep -q '^PASS' "$OUT/sim.log"; then
  echo "PASS  ($OUT/sim.log)"
else
  echo "FAIL  ($OUT/sim.log)"
  exit 1
fi
