#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the vendored jtframe tool. See PROVENANCE.md.
#
#     tools/jtframe/build.sh        # -> tools/jtframe/jtframe.exe
#
# Dependencies are fetched per src/go.sum, which pins them by hash. That needs
# network access the first time; `go mod vendor` in src/ would remove it, at
# the cost of carrying ~20 third-party Go modules in this repository.
set -euo pipefail
cd "$(dirname "$0")"

# MSYS2's Go package ships a trimmed binary that cannot find its own GOROOT.
export GOROOT="${GOROOT:-/e/msys64/mingw64/lib/go}"
export PATH="/e/msys64/mingw64/bin:$PATH"
command -v go >/dev/null || { echo "go not found; pacman -S mingw-w64-x86_64-go"; exit 1; }

( cd src && go build -o ../jtframe.exe . )
./jtframe.exe --version 2>/dev/null || true
echo "built: tools/jtframe/jtframe.exe"
