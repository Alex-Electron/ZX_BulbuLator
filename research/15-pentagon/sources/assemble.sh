#!/bin/sh
# assemble.sh - gather the complete reproducible Step 15 FPGA build into ./build/.
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

HERE=$(cd "$(dirname "$0")" && pwd)             # research/15-pentagon/sources
REPO=$(cd "$HERE/../../.." && pwd)              # repo root
S6="$REPO/research/06-zx-spectrum-128/sources"  # base glue
S8="$REPO/research/08-ddr-framebuffer/sources"  # async FIFO + triple-buffer manager
S11="$REPO/research/11-file-browser/sources"    # per-line display + OSD compositor
S12="$REPO/research/12-snapshot-loader/sources"  # AXI-RESET CDC + xdc + build.tcl (unchanged here)
B="$HERE/build"

[ -d "$REPO/cores/zx" ] && [ -d "$REPO/cores/hdmi" ] &&
[ -f "$REPO/cores/zx-mister/rtl/ula.sv" ] &&
[ -f "$REPO/cores/zx-mister/rtl/T80/T80pa.vhd" ] || {
  echo "Cores missing. Run: $REPO/get_deps.sh" >&2; exit 1; }

rm -rf "$B"; mkdir -p "$B"
ln -sfn "$REPO/cores/zx"   "$B/zx"
ln -sfn "$REPO/cores/hdmi" "$B/hdmi"
# Optional Step-15 MiSTer A/B targets. The normal Atlas target does not compile
# these links, but keeping them in every assembled tree makes
# `-tclargs mistert80` and `-tclargs mister48` reproducible with no /tmp staging.
ln -sfn "$REPO/cores/zx-mister/rtl"     "$B/mister48"
ln -sfn "$REPO/cores/zx-mister/rtl/T80" "$B/mister_t80"

# Step 15 deliberately modifies the Atlas model, memory, video timing and PS/2 receiver.
# Keep those exact sources beside this step and compile them from build/atlas_core. Never
# depend on (or mutate) a dirty cores/zx checkout during assembly.
cp -R "$HERE/atlas_core" "$B/"

# --- base glue, unchanged since Step 6 ---
cp "$S6/mem_zx.v" "$S6/kbd_buttons.v" "$S6/hdmi_wrap.sv" \
   "$HERE/get_rom.sh" "$B/"

# --- async FIFO + triple-buffer manager, unchanged since Step 8 ---
cp "$S8/async_fifo.v" "$S8/fb_bufmgr3.v" "$B/"

# --- per-line display chain, unchanged since Step 11 (osd_compositor + fb_capture_rr are step-local, below) ---
cp "$S11/fb_wr_axi.v" "$B/"   # fb_line_disp is now step-15-local (live margins) - see $HERE cp below

# --- AXI-RESET CDC, unchanged since Step 12 (build.tcl + the XDC are now step-local, below) ---
cp "$S12/inject_cdc.v" "$B/"

# --- Step 14/15 delta (from $HERE): osd_ddr_rd.v, bulbulator_zx_ddr_top.v, fb_capture_rr.v etc. for
#     colour OSD + step 15 Pentium timing leg (320 lines, paper offsets, floating bus, live tuners).
#     This tree is the continuation for step 15 (multi-machine). 14-color-osd tree is frozen. ---
cp "$HERE/axi_ctl.v" "$HERE/bulbulator_zx_ddr_top.v" "$HERE/mister48_core.sv" "$HERE/hybrid_zx_core.sv" "$HERE/osd_compositor.v" "$HERE/osd_ddr_rd.v" "$HERE/tape_bram_fifo.v" "$HERE/tape_player.v" "$HERE/ps2_tx.v" "$HERE/fb_capture_rr.v" "$HERE/fb_line_disp.v" "$HERE/clock_zx.v" "$HERE/build.tcl" "$HERE/bulbulator_ddr.xdc" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
