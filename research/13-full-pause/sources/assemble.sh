#!/bin/sh
# assemble.sh - gather everything Step 13.1's bitstream needs into ./build/.
#
# Step 13.1 = "full pause": a Pause-key toggle that HALTs the Z80 (the existing Step-7 control
# plane) and mutes the audio while frozen. Because HALT already gates the sound-chip clock-enables
# (pe3M5_core = pe3M5 & ~cpu_halt_sp), the AY/TurboSound freeze mid-sample - registers, envelope
# phase and noise LFSR all survive - so resume is bit-exact with no save/restore. The whole pause
# mechanism is ARM-side (arm/loader_main.c, Pause-key matcher + HALT toggle). The FPGA-side delta vs
# Step 12 is tiny:
#   - bulbulator_zx_ddr_top.v  forces the PCM to silence (0x400) while cpu_halt_sp is high
#   - axi_ctl.v                VERSION bumped 0xB01B0009 -> 0xB01B000A
# Everything else is taken in unchanged from the earlier steps - nothing re-shipped here:
#   inject_cdc.v + bulbulator_ddr.xdc + build.tcl come from Step 12 verbatim.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)             # research/13-full-pause/sources
REPO=$(cd "$HERE/../../.." && pwd)              # repo root
S6="$REPO/research/06-zx-spectrum-128/sources"  # base glue
S8="$REPO/research/08-ddr-framebuffer/sources"  # async FIFO + triple-buffer manager
S11="$REPO/research/11-file-browser/sources"    # per-line display + OSD compositor
S12="$REPO/research/12-snapshot-loader/sources"  # AXI-RESET CDC + xdc + build.tcl (unchanged here)
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"

# --- base glue, unchanged since Step 6 ---
cp "$S6/clock_zx.v" "$S6/mem_zx.v" "$S6/kbd_buttons.v" "$S6/hdmi_wrap.sv" \
   "$S6/get_rom.sh" "$B/"

# --- async FIFO + triple-buffer manager, unchanged since Step 8 ---
cp "$S8/async_fifo.v" "$S8/fb_bufmgr3.v" "$B/"

# --- per-line display chain + OSD compositor, unchanged since Step 11 ---
cp "$S11/fb_line_disp.v" "$S11/fb_capture_rr.v" "$S11/fb_wr_axi.v" \
   "$S11/osd_compositor.v" "$B/"

# --- AXI-RESET CDC + constraints + the loader-named build.tcl, unchanged since Step 12 ---
cp "$S12/inject_cdc.v" "$S12/bulbulator_ddr.xdc" "$S12/build.tcl" "$B/"

# --- this step's delta: the pause mute (top) + the VERSION bump (axi_ctl) ---
cp "$HERE/axi_ctl.v" "$HERE/bulbulator_zx_ddr_top.v" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
