#!/bin/sh
# Step 13 - assemble the sources and build the music-player bitstream.
# Prerequisite: run ../../get_deps.sh once (cores). Vivado 2023.1 assumed installed.
#   ./build.sh            # faithful (ULA snow on) -> sources/build/bulbulator_zx_loader.bit
#   ./build.sh nosnow     # no-snow variant        -> sources/build/bulbulator_zx_loader_nosnow.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/sources/assemble.sh"
cd "$HERE/sources/build"
if [ "${1:-}" = "nosnow" ]; then
  exec vivado -mode batch -source build.tcl -tclargs nosnow
else
  exec vivado -mode batch -source build.tcl
fi
