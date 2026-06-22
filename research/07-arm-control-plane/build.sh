#!/bin/sh
# Step 7 - assemble the sources and build the ZX + ARM-control-plane bitstream.
# Prerequisite: run ../../get_deps.sh once (cores). Vivado 2023.1 assumed installed.
#   ./build.sh        # -> sources/build/bulbulator_zx_z010.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/sources/assemble.sh"
cd "$HERE/sources/build"
exec vivado -mode batch -source build.tcl
