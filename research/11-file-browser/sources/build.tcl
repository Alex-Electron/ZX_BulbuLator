# Bulbulator Step 11 - Step 10 design + the SD file browser / options bitstream, xc7z010clg400-1.
#
# Run from the assembled build/ dir (assemble.sh populates it; see ../README.md):
#   cd build && vivado -mode batch -source build.tcl                  ;# faithful (ULA snow on)
#   cd build && vivado -mode batch -source build.tcl -tclargs nosnow  ;# no-snow variant
#
# vs Step 10 the display side changes: fb_loader.v + the whole-frame fb_display.v are replaced by
# fb_line_disp.v (per-line DDR read), fb_capture_rr.v / fb_wr_axi.v are re-cropped, and axi_ctl.v
# gains the OSD position/opacity/bg + cap_geom registers (VERSION 0xB01B0008).

set NOSNOW [expr {[llength $argv] > 0 && [lindex $argv 0] eq "nosnow"}]

# hdl-util/hdmi core + our thin stereo wrapper.
read_verilog -sv [glob hdmi/src/*.sv]
read_verilog -sv hdmi_wrap.sv

# Atlas core: VHDL T80, JT49, the SV SAA, then the Verilog core sources.
read_vhdl    [glob zx/src/T80/*.vhd]
read_verilog [glob zx/src/JT49/*.v]
read_verilog -sv zx/src/saa1099.sv
read_verilog [list \
  zx/src/main.v zx/src/cpu.v zx/src/video.v zx/src/turbosound.v \
  zx/src/specdrum.v zx/src/saa.v zx/src/audio.v zx/src/dprs.v zx/src/dsg.v \
  zx/src/memory.v zx/src/keyboard.v zx/src/ps2.v zx/src/usd.v zx/src/spi.v]

# EBAZ glue + control plane + DDR chain (line-buffer display) + OSD compositor + the top.
read_verilog [list clock_zx.v mem_zx.v kbd_buttons.v \
  axi_ctl.v inject_cdc.v \
  fb_capture_rr.v async_fifo.v fb_wr_axi.v fb_bufmgr3.v fb_line_disp.v osd_compositor.v \
  bulbulator_zx_ddr_top.v]
read_xdc bulbulator_ddr.xdc

if {$NOSNOW} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define NO_SNOW
  set BIT bulbulator_zx_browser_nosnow.bit
} else {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1
  set BIT bulbulator_zx_browser.bit
}
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force $BIT
puts ">>> DONE bit=$BIT size=[file size $BIT]"
