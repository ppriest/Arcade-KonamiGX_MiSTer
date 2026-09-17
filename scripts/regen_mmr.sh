#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate every vendored *_mmr.v with jotego's own generator.
#
#     scripts/regen_mmr.sh            # regenerate in place
#     scripts/regen_mmr.sh --check    # regenerate to a temp dir and diff
#
# jotego GENERATES these register-decode modules from cfg/mmr.yaml rather than
# committing them, and the generator's own template says not to commit the
# output. This project commits them anyway and PROVENANCE.md says why: nothing
# here is built with jtframe's build system, so Quartus and the benches need
# the files present. The cost of that choice is drift, and this script is what
# makes drift detectable -- run it with --check after updating the jtcores
# snapshot.
#
# It needs a jtcores checkout for the cfg/mmr.yaml inputs. Point JTCORES at
# one; the tool itself is vendored in tools/jtframe.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

JTFRAME_TOOL="tools/jtframe/jtframe.exe"
[ -x "$JTFRAME_TOOL" ] || { echo "build it first: tools/jtframe/build.sh"; exit 1; }
: "${JTCORES:?set JTCORES to a jtcores checkout (for cfg/mmr.yaml)}"
[ -d "$JTCORES/cores" ] || { echo "JTCORES=$JTCORES has no cores/"; exit 1; }

# JTFRAME must point at a real jtframe tree: the generator reads its Go
# template from $JTFRAME/hdl/inc/mmr.v and other data files besides (it also
# wants hdl/sound/audio_mod.yaml during start-up). Vendoring just the template
# was tried and fails on the next file it reaches, so take it from the same
# snapshot the cfg/mmr.yaml inputs come from -- pinning the template against an
# unpinned yaml would be a split-brain anyway. Only the TOOL is vendored here.
export JTFRAME="$JTCORES/modules/jtframe"
export JTROOT="$JTCORES" CORES="$JTCORES/cores" MODULES="$JTCORES/modules"
export JTBIN="${JTBIN:-$PWD/build/jtbin}"
mkdir -p "$JTBIN"

TOOL="$PWD/$JTFRAME_TOOL"
declare -A WANT=(
  ["$JTCORES/cores/rungun/hdl/jtk053252_mmr.v"]="rtl/video/k053252/jtk053252_mmr.v"
  ["$JTCORES/modules/jt05415x/hdl/jt054156_mmr.v"]="rtl/video/k056832/jt054156_mmr.v"
  ["$JTCORES/modules/jt05415x/hdl/jt054157_mmr.v"]="rtl/video/k056832/jt054157_mmr.v"
  ["$JTCORES/cores/simson/hdl/jt053246_mmr.v"]="rtl/video/k055673/jt053246_mmr.v"
)

( cd "$JTCORES" && "$TOOL" mmr rungun && "$TOOL" mmr simson && "$TOOL" mmr -m jt05415x )

rc=0
for src in "${!WANT[@]}"; do
  dst="${WANT[$src]}"
  # Existence plus content is the whole check. An mtime test was tried and
  # gives false positives: jtframe leaves a file untouched when the generated
  # content has not changed, so a correct no-op run looks stale.
  [ -f "$src" ] || { echo "MISSING generated file: $src"; rc=1; continue; }
  if [ "$CHECK" = 1 ]; then
    if cmp -s "$src" "$dst"; then
      echo "  same     $dst"
    else
      echo "  DRIFTED  $dst"; rc=1
    fi
  else
    cp "$src" "$dst"
    echo "  wrote    $dst"
  fi
done
exit $rc
