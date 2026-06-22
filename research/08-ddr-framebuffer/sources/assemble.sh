#!/bin/sh
# assemble.sh - gather everything Step 8's bitstream needs into ./build/.
#
# Step 8 swaps the single-BRAM framebuffer for a DDR triple-buffer. The base glue
# (clock/mem/kbd, hdmi_wrap) is byte-identical to Step 6, so it is pulled from there
# rather than re-shipped; this step's sources/ holds only the delta - the changed
# axi_ctl/inject_cdc, the DDR chain, the new top and constraints.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/08-ddr-framebuffer/sources
REPO=$(cd "$HERE/../../.." && pwd)             # repo root
S6="$REPO/research/06-zx-spectrum-128/sources" # base glue lives here
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# --- carried unchanged from Step 6 (framebuffer.v is intentionally NOT carried) ---
cp "$S6/clock_zx.v" "$S6/mem_zx.v" "$S6/kbd_buttons.v" "$S6/hdmi_wrap.sv" \
   "$S6/get_rom.sh" "$B/"

# --- this step's delta (lives here in sources/) ---
cp "$HERE/axi_ctl.v" "$HERE/inject_cdc.v" \
   "$HERE/async_fifo.v" "$HERE/fb_capture_rr.v" "$HERE/fb_wr_axi.v" \
   "$HERE/fb_bufmgr3.v" "$HERE/fb_loader.v" "$HERE/fb_display.v" \
   "$HERE/bulbulator_zx_ddr_top.v" "$HERE/bulbulator_ddr.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )

echo "Assembled $B  (Step 8 = Step 6 base glue + DDR chain delta + cores + rom128.hex)"
