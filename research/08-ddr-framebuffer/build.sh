#!/bin/sh
# Step 8 - assemble the sources and build the tear-free DDR-framebuffer bitstream.
# Prerequisite: run ../../get_deps.sh once (cores). Vivado 2023.1 assumed installed.
#   ./build.sh            # faithful (ULA snow on) -> sources/build/bulbulator_zx_ddr.bit
#   ./build.sh nosnow     # no-snow variant        -> sources/build/bulbulator_zx_ddr_nosnow.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/sources/assemble.sh"
cd "$HERE/sources/build"
if [ "${1:-}" = "nosnow" ]; then
  exec vivado -mode batch -source build.tcl -tclargs nosnow
else
  exec vivado -mode batch -source build.tcl
fi
