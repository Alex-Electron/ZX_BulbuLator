# Bulbulator Step 14 (14.0 colour OSD) - Step 13 player design + a DDR-backed TRUE-COLOUR OSD layer.
#   cd build && vivado -mode batch -source build.tcl                  ;# faithful (ULA snow on)
#   cd build && vivado -mode batch -source build.tcl -tclargs nosnow  ;# no-snow variant
#
# vs Step 13 the delta: a new osd_ddr_rd.v reads an ARGB8888 OSD canvas from DDR over its OWN AXI-HP1
# port (a simplified fb_line_disp clone) and the top alpha-blends it over the 1bpp OSD output for a
# full per-pixel true-colour OSD (Winamp-style skins). axi_ctl gains OSD_DDR_BASE (0x94) + OSD_CTRL
# bit1 DDR_OSD_EN + LOAD_CAPS (0xC0, reserved). VERSION 0xB01B0019.

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

# EBAZ glue + control plane + DDR chain (line-buffer display) + OSD compositor + DDR-RGB OSD + the top.
read_verilog [list clock_zx.v mem_zx.v kbd_buttons.v \
  axi_ctl.v inject_cdc.v \
  fb_capture_rr.v async_fifo.v fb_wr_axi.v fb_bufmgr3.v fb_line_disp.v osd_compositor.v \
  osd_ddr_rd.v tape_bram_fifo.v tape_player.v ps2_tx.v \
  bulbulator_zx_ddr_top.v]
read_xdc bulbulator_ddr.xdc

if {$NOSNOW} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define NO_SNOW
  set BIT bulbulator_zx_loader_nosnow.bit
} else {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1
  set BIT bulbulator_zx_loader.bit
}
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
puts ">>> ==== CLOCKS (must list fclk100 + 3 derived + clk_audio; empty = the old unconstrained lottery) ===="
puts [report_clocks -return_string]
puts ">>> ==== CHECK_TIMING no_clock (must be 0 unconstrained endpoints) ===="
puts [check_timing -override_defaults no_clock -return_string]
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 4]
write_bitstream -force $BIT
puts ">>> DONE bit=$BIT size=[file size $BIT]"
