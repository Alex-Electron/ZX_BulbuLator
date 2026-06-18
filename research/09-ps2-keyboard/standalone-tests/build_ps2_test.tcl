# build_ps2_test.tcl  -  standalone PS/2 keyboard read test bitstream (xc7z010clg400-1).
# Run on ThinkPad:  vivado -mode batch -source build_ps2_test.tcl
set ATLAS /home/lavrinovich/zxatlas/src
set DIR   /home/lavrinovich/ps2test

read_verilog [list $ATLAS/ps2.v $DIR/ps2_axi.v $DIR/ps2_test_top.v]
read_xdc $DIR/ps2_test.xdc

synth_design -top ps2_test_top -part xc7z010clg400-1
opt_design
place_design
route_design
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 1]
write_bitstream -force $DIR/ps2_test.bit
puts ">>> DONE size=[file size $DIR/ps2_test.bit]"
