# build_bulbulator_zx.tcl  -  Bulbulator ZX Spectrum 128K + HDMI, xc7z010clg400-1.
#
# Expected layout (clone the two cores next to this sources/ dir, then run get_rom.sh):
#
#   06-zx-spectrum-128/
#     sources/           <- this dir (our board-top) + rom128.hex (from get_rom.sh)
#     zx/                <- git clone -b ebaz4205-vivado https://github.com/Alex-Electron/zx
#     hdmi/              <- git clone https://github.com/hdl-util/hdmi
#
# Then, from sources/:   vivado -mode batch -source build_bulbulator_zx.tcl
# ($readmemh reads rom128.hex relative to the working dir, so run it from sources/.)

set WIRE  [file normalize [file dirname [info script]]]
set ATLAS [file normalize $WIRE/../zx/src]      ;# Atlas core fork (T80 fix on ebaz4205-vivado)
set HDMI  [file normalize $WIRE/../hdmi/src]    ;# hdl-util/hdmi (the same core Steps 3-5 use)

# hdl-util/hdmi core (SystemVerilog) + our thin stereo wrapper.
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

# EBAZ board-top: clock / memory / framebuffer / keyboard glue + the top.
read_verilog [list \
  $WIRE/clock_zx.v $WIRE/mem_zx.v $WIRE/framebuffer.v $WIRE/kbd_buttons.v \
  $WIRE/bulbulator_zx_top.v]

read_xdc $WIRE/bulbulator_zx.xdc

synth_design -top bulbulator_zx_top -part xc7z010clg400-1
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
write_bitstream -force $WIRE/bulbulator_zx_z010.bit
puts ">>> DONE size=[file size $WIRE/bulbulator_zx_z010.bit]"
