#!/bin/sh
# Build the Step 2 buttons-to-LEDs bitstream (xc7z010clg400-1). No external deps.
# Vivado 2023.1 is assumed already installed (see research/00-setup).
#   ./build.sh        # -> buttons_leds_z010.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec vivado -mode batch -source "$HERE/build_buttons_z010.tcl"
