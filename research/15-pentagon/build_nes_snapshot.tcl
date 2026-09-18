read_verilog -sv [glob hdmi/src/*.sv]
read_verilog -sv hdmi_wrap.sv
read_verilog axi_ctl.v fb_capture_rr.v async_fifo.v fb_wr_axi.v fb_bufmgr3.v fb_line_disp.v
read_verilog nes_core/nes_mem_bram.v nes_core/nes_wrap.v nes_core/nes_video.v bulbulator_nes_top.v
read_verilog -sv nes_core/t65/T65_Pack.v nes_core/t65/T65_MCode.v nes_core/t65/T65_ALU.v nes_core/t65/T65.v
read_verilog -sv [glob nes_core/mappers/*.sv]
read_verilog -sv nes_core/EEPROM_24C0x.sv nes_core/cart.sv nes_core/apu.v nes_core/ppu.v nes_core/dpram.v nes_core/compat.v nes_core/nes.v
read_xdc bulbulator_ddr.xdc
if {[catch {synth_design -top bulbulator_nes_top -part xc7z010clg400-1 -verilog_define NES_CORE} e]} { puts ">>> SYNTH_FAIL: $e"; exit 1 }
puts ">>> SYNTH_OK"
foreach l [split [report_utilization -return_string] "\n"] { if {[regexp {Slice LUTs|Block RAM Tile|DSPs|Slice Registers} $l]} { puts ">>> UTIL: $l" } }
opt_design; place_design; route_design
puts ">>> TIMING:"; foreach l [split [report_timing_summary -return_string] "\n"] { if {[regexp {All user specified|WNS|NOT met} $l]} { puts ">>> $l" } }
write_bitstream -force bulbulator_zx_loader_nes.bit
puts ">>> NES_BUILD_DONE"
exit
