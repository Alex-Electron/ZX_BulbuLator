#!/bin/sh
# Build the Step 1 LED-blink bitstream (xc7z010clg400-1). No external deps.
# Vivado 2023.1 is assumed already installed (see research/00-setup).
#   ./build.sh        # -> blink_z010.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec vivado -mode batch -source "$HERE/build_blink_z010.tcl"
