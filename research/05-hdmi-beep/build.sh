#!/bin/sh
# Build the Step 5 HDMI-audio "beep" bitstream (xc7z010clg400-1).
# The hdl-util/hdmi core is vendored in hdmi_core/, so there are no external deps.
# Vivado 2023.1 is assumed already installed (see research/00-setup).
#   ./build.sh        # -> hdmi_beep_z010.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec vivado -mode batch -source "$HERE/build_beep_z010.tcl"
