#!/bin/sh
# assemble.sh - gather everything Step 10's bitstream needs into ./build/.
#
# Step 10 adds the on-screen display (OSD overlay) and the PS/2 -> ARM keyboard gate. The RTL
# deltas vs Step 8/9 all live here in sources/:
#   - bulbulator_zx_ddr_top.v   the gate + the always-tap scancode FIFO + the osd_compositor wiring
#   - axi_ctl.v                 OSD + keyboard-FIFO + MACHINE_ID registers (VERSION 0xB01B0006)
#   - osd_compositor.v          the 1-bpp OSD panel composited over the live HDMI scanout (NEW)
#   - fb_display.v              same DDR upscaler as Step 8, picture re-centred (equal L/R margins)
#   - bulbulator_ddr.xdc        constraints, now with the keyboard-gate CDC false-paths
# Everything else is taken in unchanged: the base glue from Step 6, the DDR chain + the inject CDC
# from Step 8 - none of it re-shipped in git.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)            # research/10-osd-keyboard-gate/sources
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

# --- DDR chain + control-plane CDC, unchanged since Step 8 (axi_ctl + fb_display come from here) ---
cp "$S8/inject_cdc.v" "$S8/async_fifo.v" "$S8/fb_capture_rr.v" \
   "$S8/fb_wr_axi.v" "$S8/fb_bufmgr3.v" "$S8/fb_loader.v" "$B/"

# --- this step's delta (OSD + keyboard gate) ---
cp "$HERE/axi_ctl.v" "$HERE/osd_compositor.v" "$HERE/fb_display.v" \
   "$HERE/bulbulator_zx_ddr_top.v" "$HERE/bulbulator_ddr.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
