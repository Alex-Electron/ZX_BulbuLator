#!/bin/sh
# assemble.sh - gather everything Step 13's bitstream needs into ./build/.
#
# Step 13 = "Player": a machine-agnostic ARM->HDMI audio path plus a full-pause + independent status
# banner. The FPGA-side delta vs Step 12 (VERSION 0xB01B0009 -> 0xB01B0013):
#   - axi_ctl.v                + audio FIFO push/status regs (0x74 VOL, 0x78 AUDIO_CTRL, 0x7C
#                                AUDIO_FIFO, 0x80 AUDIO_STAT) + independent banner regs (0x84 CTRL /
#                                0x88 ADDR / 0x8C DATA / 0x90 POS); VERSION 0xB01B0013.
#   - bulbulator_zx_ddr_top.v  + an async audio FIFO (ARM PCM -> clk_audio) muxed onto HDMI when the
#                                player is active; the pause fade-to-silence (anti-click); the
#                                banner_compositor instance; CDC syncs on the new audio-domain controls.
#   - osd_compositor.v         step-local (adds banner_compositor + an osd_bg/op settle-latch CDC
#                                fix); copied from $HERE so Step 11's own copy stays exactly as published.
# Everything else is taken in unchanged from the earlier steps - nothing re-shipped here:
#   inject_cdc.v + bulbulator_ddr.xdc + build.tcl come from Step 12 verbatim.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)             # research/13-music-player/sources
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

# --- per-line display chain, unchanged since Step 11 (osd_compositor is now step-local, below) ---
cp "$S11/fb_line_disp.v" "$S11/fb_capture_rr.v" "$S11/fb_wr_axi.v" "$B/"

# --- AXI-RESET CDC + constraints + the loader-named build.tcl, unchanged since Step 12 ---
cp "$S12/inject_cdc.v" "$S12/bulbulator_ddr.xdc" "$S12/build.tcl" "$B/"

# --- this step's delta (from $HERE): audio FIFO + HDMI PCM mux + independent status banner in
#     bulbulator_zx_ddr_top.v; the audio/banner AXI regs + VERSION 0xB01B0013 in axi_ctl.v; and a
#     step-local osd_compositor.v (banner_compositor + the osd_bg/op settle-latch CDC fix). ---
cp "$HERE/axi_ctl.v" "$HERE/bulbulator_zx_ddr_top.v" "$HERE/osd_compositor.v" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
