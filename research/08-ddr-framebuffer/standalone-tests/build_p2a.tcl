# build_p2a.tcl - Phase-2a standalone capture-path test bitstream (xc7z010clg400-1).
#
# Run after ../../../get_deps.sh (needs the fetched HDMI core):
#   cd standalone-tests && vivado -mode batch -source build_p2a.tcl   # -> ddrfb_p2a.bit
#
# Phase 2a = a synthetic raster (spclk) captured through the FIFO/CDC into PS DDR and
# scanned out tear-free. It reuses the Step-8 DDR chain (../sources) + the base clock
# (../../06-.../sources/clock_zx.v) + the hdl-util HDMI core (../../../cores/hdmi).
set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize $HERE/../../..]
set CORES $REPO/cores
set S8 [file normalize $HERE/../sources]
set S6 $REPO/research/06-zx-spectrum-128/sources

read_verilog -sv [glob $CORES/hdmi/src/*.sv]
read_verilog -sv $S6/hdmi_wrap.sv   ;# base glue lives in Step 6's sources (delta model)
read_verilog [list \
  $S6/clock_zx.v \
  $S8/fb_loader.v $S8/fb_display.v $S8/async_fifo.v $S8/fb_wr_axi.v $S8/fb_bufmgr3.v \
  $HERE/zx_raster_gen.v $HERE/fb_capture.v $HERE/ddrfb_p2a_regs.v $HERE/ddrfb_p2a_top.v]
read_xdc $HERE/ddrfb_p2a.xdc

synth_design -top ddrfb_p2a_top -part xc7z010clg400-1
opt_design
place_design
route_design
write_bitstream -force $HERE/ddrfb_p2a.bit
puts ">>> DONE size=[file size $HERE/ddrfb_p2a.bit]"
