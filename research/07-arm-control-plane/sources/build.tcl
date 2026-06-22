# Bulbulator Step 7 - ZX Spectrum 128K + HDMI + ARM AXI control plane, xc7z010clg400-1.
#
# Run from the assembled build/ dir (assemble.sh populates it; see ../README.md):
#   cd build && vivado -mode batch -source build.tcl
#
# Paths are relative to build/: zx/ and hdmi/ are the fetched-core symlinks; the
# board glue, the control-plane RTL and rom128.hex are flat in build/. This step
# carries the unchanged glue from Step 6 (clock/mem/framebuffer/kbd, hdmi_wrap) and
# adds axi_ctl.v + inject_cdc.v; assemble.sh is what gathers them.

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

# EBAZ glue + AXI control plane (axi_ctl + inject_cdc) + the top.
read_verilog [list clock_zx.v mem_zx.v framebuffer.v kbd_buttons.v \
  axi_ctl.v inject_cdc.v bulbulator_zx_top.v]
read_xdc bulbulator_zx.xdc

synth_design -top bulbulator_zx_top -part xc7z010clg400-1
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
opt_design
place_design
route_design
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force bulbulator_zx_z010.bit
puts ">>> DONE size=[file size bulbulator_zx_z010.bit]"
