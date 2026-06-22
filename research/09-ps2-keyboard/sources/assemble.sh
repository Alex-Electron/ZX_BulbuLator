#!/bin/sh
# assemble.sh - gather everything Step 9's bitstream needs into ./build/.
#
# Step 9 adds a PS/2 keyboard; the only RTL change vs Step 8 is the top and its
# constraints, which live here in sources/. Everything else is taken in: the base
# glue (clock/mem/kbd, hdmi_wrap) from Step 6, and the DDR-framebuffer chain +
# control plane from Step 8 - none of it re-shipped in git.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/09-ps2-keyboard/sources
REPO=$(cd "$HERE/../../.." && pwd)             # repo root
S6="$REPO/research/06-zx-spectrum-128/sources" # base glue
S8="$REPO/research/08-ddr-framebuffer/sources" # DDR chain + control plane
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# --- base glue, unchanged since Step 6 ---
cp "$S6/clock_zx.v" "$S6/mem_zx.v" "$S6/kbd_buttons.v" "$S6/hdmi_wrap.sv" \
   "$S6/get_rom.sh" "$B/"

# --- DDR chain + control plane, unchanged since Step 8 ---
cp "$S8/axi_ctl.v" "$S8/inject_cdc.v" \
   "$S8/async_fifo.v" "$S8/fb_capture_rr.v" "$S8/fb_wr_axi.v" \
   "$S8/fb_bufmgr3.v" "$S8/fb_loader.v" "$S8/fb_display.v" "$B/"

# --- this step's delta (PS/2 top + constraints) ---
cp "$HERE/bulbulator_zx_ddr_top.v" "$HERE/bulbulator_ddr.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )

echo "Assembled $B  (Step 9 = Step 6 base glue + Step 8 DDR chain + PS/2 top delta + cores + rom)"
