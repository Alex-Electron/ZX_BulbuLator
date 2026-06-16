# build_bulbulator_zx.tcl  -  full bitstream build, Atlas ZX 128K + HDMI, xc7z010clg400-1.
# Run on ThinkPad from /home/lavrinovich/bulbulator (so $readmemh rom128.hex resolves).
set WIRE  /home/lavrinovich/bulbulator
set ATLAS /home/lavrinovich/zxatlas/src
set HDMI  /home/lavrinovich/hdmi_beep_z010/hdmi_core

# hdl-util/hdmi core (proven Step-5 set) + the stereo wrapper.
read_verilog -sv [glob $HDMI/*.sv]
read_verilog -sv $WIRE/hdmi_wrap.sv

# Atlas core: VHDL T80, JT49, the SV SAA, then the Verilog core sources.
read_vhdl    [glob $ATLAS/T80/*.vhd]
read_verilog [glob $ATLAS/JT49/*.v]
read_verilog -sv $ATLAS/saa1099.sv
read_verilog [list \
  $ATLAS/main.v $ATLAS/cpu.v $ATLAS/video.v $ATLAS/turbosound.v \
  $ATLAS/specdrum.v $ATLAS/saa.v $ATLAS/audio.v $ATLAS/dprs.v $ATLAS/dsg.v \
  $ATLAS/memory.v $ATLAS/keyboard.v $ATLAS/ps2.v $ATLAS/usd.v $ATLAS/spi.v]

# EBAZ wiring: clock / memory / framebuffer / keyboard glue + AXI control plane + the top.
read_verilog [list \
  $WIRE/clock_zx.v $WIRE/mem_zx.v $WIRE/framebuffer.v $WIRE/kbd_buttons.v \
  $WIRE/axi_ctl.v $WIRE/inject_cdc.v \
  $WIRE/bulbulator_zx_top.v]

read_xdc $WIRE/bulbulator_zx.xdc

synth_design -top bulbulator_zx_top -part xc7z010clg400-1
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
write_checkpoint -force $WIRE/bulbulator_zx_routed.dcp
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force $WIRE/bulbulator_zx_z010.bit
puts ">>> DONE size=[file size $WIRE/bulbulator_zx_z010.bit]"
