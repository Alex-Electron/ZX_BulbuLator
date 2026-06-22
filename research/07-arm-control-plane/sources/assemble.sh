#!/bin/sh
# assemble.sh - gather everything Step 7's bitstream needs into ./build/.
#
# Step 7 extends Step 6 with the ARM AXI control plane. It does NOT re-ship the glue
# that is byte-identical to Step 6 - this script pulls those files straight from
# Step 6's sources/, then layers this step's delta (the changed top + constraints,
# and the new axi_ctl.v + inject_cdc.v) on top.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/07-arm-control-plane/sources
REPO=$(cd "$HERE/../../.." && pwd)             # repo root
S6="$REPO/research/06-zx-spectrum-128/sources" # the step we extend
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# --- carried unchanged from Step 6 (identical bytes; not duplicated in git) ---
cp "$S6/clock_zx.v" "$S6/mem_zx.v" "$S6/framebuffer.v" "$S6/kbd_buttons.v" \
   "$S6/hdmi_wrap.sv" "$S6/get_rom.sh" "$B/"

# --- this step's delta (lives here in sources/) ---
cp "$HERE/axi_ctl.v" "$HERE/inject_cdc.v" \
   "$HERE/bulbulator_zx_top.v" "$HERE/bulbulator_zx.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )

echo "Assembled $B  (Step 7 = Step 6 glue + axi_ctl/inject_cdc + cores + rom128.hex)"
