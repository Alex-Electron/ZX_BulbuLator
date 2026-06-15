# Build from wherever this script lives — no absolute paths.
set root [file normalize [file dirname [info script]]]
read_verilog $root/blink.v
read_xdc $root/blink.xdc
synth_design -top blink -part xc7z010clg400-1
opt_design
place_design
route_design
write_bitstream -force $root/blink_z010.bit
puts ">>> DONE size=[file size $root/blink_z010.bit]"
