read_verilog -sv [glob hdmi/src/*.sv]
read_verilog -sv hdmi_wrap.sv
read_verilog axi_ctl.v fb_capture_rr.v async_fifo.v fb_wr_axi.v fb_bufmgr5.v fb_line_disp.v atlas_core/ps2.v ps2_tx.v osd_compositor.v osd_ddr_rd.v ddr_probe.v ddr_mem.v control_plane.v bdi_activity_icon.v
read_verilog nes_core/nes_mem_bram.v nes_core/nes_wrap.v nes_core/nes_video.v bulbulator_nes_top.v
read_verilog -sv nes_core/t65/T65_Pack.v nes_core/t65/T65_MCode.v nes_core/t65/T65_ALU.v nes_core/t65/T65.v
read_verilog -sv [glob nes_core/mappers/*.sv]
read_verilog -sv nes_core/EEPROM_24C0x.sv nes_core/cart.sv nes_core/apu.v nes_core/ppu.v nes_core/dpram.v nes_core/compat.v nes_core/nes.v
read_xdc bulbulator_ddr.xdc
if {[catch {synth_design -top bulbulator_nes_top -part xc7z010clg400-1 -verilog_define NES_CORE} e]} { puts ">>> SYNTH_FAIL: $e"; exit 1 }
puts ">>> SYNTH_OK"
puts ">>> CLOCKS: [get_clocks -include_generated_clocks]"
# NES 21.5MHz domain = nesclk_raw (off mmcm_nes/CLKOUT0). Declare async vs all sys clocks
# (fclk100, HDMI pixel/serial, audio). remove_from_collection is NOT available in this batch
# context, so select the sys group directly with get_clocks -filter (exclude nesclk_raw and its
# MMCM feedback nfb).
set nesg [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *mmcm_nes/CLKOUT0}]]
if {[llength $nesg] == 0} { set nesg [get_clocks nesclk_raw] }
set sysg [get_clocks -include_generated_clocks -filter {NAME != nesclk_raw && NAME != nfb}]
puts ">>> nesg = $nesg  |  sysg = $sysg"
if {[llength $nesg] > 0 && [llength $sysg] > 0} {
    set_clock_groups -asynchronous -group $nesg -group $sysg
    puts ">>> CDC async groups set"
} else {
    puts ">>> WARN clock groups not set"
}
foreach l [split [report_utilization -return_string] "\n"] { if {[regexp {Slice LUTs|Block RAM Tile|DSPs|Slice Registers} $l]} { puts ">>> UTIL: $l" } }
opt_design; place_design; route_design
puts ">>> TIMING:"; foreach l [split [report_timing_summary -return_string] "\n"] { if {[regexp {All user specified|WNS|NOT met} $l]} { puts ">>> $l" } }
write_bitstream -force bulbulator_zx_loader_nes.bit
puts ">>> NES_BUILD_DONE"
exit
