#!/bin/sh
# assemble.sh - gather everything Step 11's bitstream needs into ./build/.
#
# Step 11 adds the SD file browser + options menu (ARM side) and, on the FPGA side, swaps the display
# path and grows the control plane. The RTL deltas vs Step 10 all live here in sources/:
#   - fb_line_disp.v          per-line DDR display - REPLACES fb_loader.v + the whole-frame fb_display.v
#   - fb_capture_rr.v         frame capture, crop re-tuned against ZEsarUX (CHANGED vs Step 8)
#   - fb_wr_axi.v             DDR frame writer, partial final burst for the new crop height (CHANGED)
#   - osd_compositor.v        the 1-bpp OSD panel + live position/opacity blend (CHANGED vs Step 10)
#   - axi_ctl.v               control plane + OSD position/opacity/bg + cap_geom (VERSION 0xB01B0008)
#   - bulbulator_zx_ddr_top.v full top: the Step 10 design with fb_line_disp + the new registers
#   - bulbulator_ddr.xdc      constraints, with the line-disp + position-CDC false-paths
# Everything else is taken in unchanged: the base glue from Step 6, and inject_cdc + async_fifo +
# the triple-buffer manager from Step 8 - none of it re-shipped in git. (fb_loader.v and fb_display.v
# are gone: fb_line_disp replaces both, and the top no longer instantiates them.)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/11-file-browser/sources
REPO=$(cd "$HERE/../../.." && pwd)             # repo root
S6="$REPO/research/06-zx-spectrum-128/sources" # base glue
S8="$REPO/research/08-ddr-framebuffer/sources" # DDR chain + inject CDC
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# --- base glue, unchanged since Step 6 ---
cp "$S6/clock_zx.v" "$S6/mem_zx.v" "$S6/kbd_buttons.v" "$S6/hdmi_wrap.sv" \
   "$S6/get_rom.sh" "$B/"

# --- inject CDC + the async FIFO + the triple-buffer manager, unchanged since Step 8 ---
cp "$S8/inject_cdc.v" "$S8/async_fifo.v" "$S8/fb_bufmgr3.v" "$B/"

# --- this step's delta (line-buffer display + re-crop + OSD position/opacity + new registers) ---
cp "$HERE/fb_line_disp.v" "$HERE/fb_capture_rr.v" "$HERE/fb_wr_axi.v" \
   "$HERE/osd_compositor.v" "$HERE/axi_ctl.v" \
   "$HERE/bulbulator_zx_ddr_top.v" "$HERE/bulbulator_ddr.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
