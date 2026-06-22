#!/bin/sh
# Build the Step 3 HDMI colour-bars bitstream (xc7z010clg400-1).
#
# The HDMI block design uses Digilent's rgb2dvi IP. get_deps.sh fetches it into
# ../../deps/vivado-library; this wrapper points Vivado at it and runs the build.
# Vivado 2023.1 is assumed already installed (see research/00-setup).
#   ./build.sh        # -> hdmi_stripes_z010.bit
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
VLIB="$REPO/deps/vivado-library"
[ -d "$VLIB/ip/rgb2dvi" ] || { echo "rgb2dvi missing. Run: $REPO/get_deps.sh" >&2; exit 1; }
export VIVADO_LIBRARY="$VLIB"
exec vivado -mode batch -source "$HERE/build_stripes_z010.tcl"
