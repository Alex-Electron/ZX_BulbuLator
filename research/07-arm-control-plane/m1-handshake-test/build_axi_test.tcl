# build_axi_test.tcl  -  Milestone 1 AXI GP0 handshake bitstream, xc7z010clg400-1.
# Run on ThinkPad from /home/lavrinovich/axi_test.
set DIR /home/lavrinovich/axi_test

read_verilog [list $DIR/axi_ctl.v $DIR/bulb_axi_test_top.v]
read_xdc     $DIR/bulb_axi_test.xdc

synth_design -top bulb_axi_test_top -part xc7z010clg400-1
puts ">>> ==== UTIL after synth ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|BUFG|PS7} $line]} { puts $line }
}
opt_design
place_design
route_design
write_checkpoint -force $DIR/bulb_axi_test_routed.dcp
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force $DIR/bulb_axi_test.bit
puts ">>> DONE size=[file size $DIR/bulb_axi_test.bit]"
