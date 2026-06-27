#!/bin/sh
# assemble.sh - gather everything Step 12's bitstream needs into ./build/.
#
# Step 12 = snapshot loader (.z80 v1/v2/v3 + .sna, 48K/128K) + reset-on-load (AXI-RESET) +
# SD-card hardening. The loader and the SD robustness are entirely ARM-side (arm/loader_main.c).
# The FPGA-side delta vs Step 11 is one thing: the AXI-RESET path - a CONTROL bit that, crossed
# into the Spectrum clock domain, drives the existing F11 cold-reset+wipe FSM, so the ARM can wipe
# and reset the machine before every snapshot inject. The four changed RTL files live here:
#   - axi_ctl.v               control plane + CONTROL bit2 (RESET+wipe) / STATUS bit2 (reset_busy); VERSION 0xB01B0009
#   - inject_cdc.v            aclk<->spclk CDC, now also crosses the reset request + busy back (CHANGED vs Step 8)
#   - bulbulator_zx_ddr_top.v full top: Step 11 design with the reset request OR'd into the F11 wipe FSM
#   - bulbulator_ddr.xdc      constraints + the AXI-RESET CDC false-paths
# Everything else is taken in unchanged: the per-line display + OSD + control-plane base from Step 11,
# async_fifo + the triple-buffer manager from Step 8, the base glue from Step 6 - none re-shipped here.
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)
#   ./assemble.sh && (cd build && vivado -mode batch -source build.tcl -tclargs nosnow)
#
# Prerequisite: run ../../../get_deps.sh once (fetches cores/ and deps/).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)             # research/12-snapshot-loader/sources
REPO=$(cd "$HERE/../../.." && pwd)              # repo root
S6="$REPO/research/06-zx-spectrum-128/sources"  # base glue
S8="$REPO/research/08-ddr-framebuffer/sources"  # async FIFO + triple-buffer manager
S11="$REPO/research/11-file-browser/sources"    # per-line display + OSD compositor (build.tcl is local to Step 12)
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

# --- this step's delta: the AXI-RESET RTL + the loader-named build.tcl (writes bulbulator_zx_loader.bit) ---
cp "$HERE/axi_ctl.v" "$HERE/inject_cdc.v" \
   "$HERE/bulbulator_zx_ddr_top.v" "$HERE/bulbulator_ddr.xdc" "$HERE/build.tcl" "$B/"

( cd "$B" && sh get_rom.sh >/dev/null )
echo "Assembled into $B"
