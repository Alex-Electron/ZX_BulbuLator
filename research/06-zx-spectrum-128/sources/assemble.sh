#!/bin/sh
# assemble.sh - gather everything Step 6's bitstream needs into ./build/.
#
# Step 6 is the base ZX step, so all of its board glue lives right here in sources/.
# This script links in the fetched cores, fetches the ROM, and drops in the build
# script, leaving a self-contained build/ you run Vivado from:
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/06-zx-spectrum-128/sources
REPO=$(cd "$HERE/../../.." && pwd)             # repo root
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"

# Cores (read-only) come in as symlinks; the build.tcl reads zx/src and hdmi/src.
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# This step's own glue + constraints + build script.
cp "$HERE/clock_zx.v" "$HERE/mem_zx.v" "$HERE/framebuffer.v" "$HERE/kbd_buttons.v" \
   "$HERE/hdmi_wrap.sv" "$HERE/bulbulator_zx_top.v" "$HERE/bulbulator_zx.xdc" \
   "$HERE/get_rom.sh" "$HERE/build.tcl" "$B/"

# Fetch + convert the ROM into build/ (rom128.hex, resolved by $readmemh at run time).
( cd "$B" && sh get_rom.sh >/dev/null )

echo "Assembled $B  (Step 6 base: own glue + cores + rom128.hex)"
