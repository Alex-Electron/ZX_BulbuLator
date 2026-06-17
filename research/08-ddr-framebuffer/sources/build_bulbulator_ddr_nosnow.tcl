# build_bulbulator_ddr.tcl  -  full bitstream: Atlas ZX 128K + AXI inject + DDR double-buffer FB.
# Run on ThinkPad from /home/lavrinovich/bulbulator (so $readmemh rom128.hex resolves).
set WIRE  /home/lavrinovich/bulbulator
set ATLAS /home/lavrinovich/zxatlas/src
set HDMI  /home/lavrinovich/hdmi_beep_z010/hdmi_core
set DDR   /home/lavrinovich/ddrfb

read_verilog -sv [glob $HDMI/*.sv]
read_verilog -sv $WIRE/hdmi_wrap.sv
read_vhdl    [glob $ATLAS/T80/*.vhd]
read_verilog [glob $ATLAS/JT49/*.v]
read_verilog -sv $ATLAS/saa1099.sv
read_verilog [list \
  $ATLAS/main.v $ATLAS/cpu.v $ATLAS/video.v $ATLAS/turbosound.v \
  $ATLAS/specdrum.v $ATLAS/saa.v $ATLAS/audio.v $ATLAS/dprs.v $ATLAS/dsg.v \
  $ATLAS/memory.v $ATLAS/keyboard.v $ATLAS/ps2.v $ATLAS/usd.v $ATLAS/spi.v]
# EBAZ glue + control plane + DDR-framebuffer chain (framebuffer.v REPLACED by the DDR chain)
read_verilog [list \
  $WIRE/clock_zx.v $WIRE/mem_zx.v $WIRE/kbd_buttons.v \
  $WIRE/axi_ctl.v $WIRE/inject_cdc.v \
  $DDR/fb_capture_rr.v $DDR/async_fifo.v $DDR/fb_wr_axi.v $DDR/fb_bufmgr3.v \
  $DDR/fb_loader.v $DDR/fb_display.v \
  $DDR/bulbulator_zx_ddr_top.v]
read_xdc $DDR/bulbulator_ddr.xdc

synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define NO_SNOW
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force $DDR/bulbulator_zx_ddr_nosnow.bit
puts ">>> DONE size=[file size $DDR/bulbulator_zx_ddr_nosnow.bit]"
