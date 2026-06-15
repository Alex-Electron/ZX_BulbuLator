# Build from wherever this script lives — no absolute paths.
set root [file normalize [file dirname [info script]]]
read_verilog $root/buttons_leds.v
read_xdc $root/buttons_leds.xdc
synth_design -top buttons_leds -part xc7z010clg400-1
opt_design
place_design
route_design
write_bitstream -force $root/buttons_leds_z010.bit
puts ">>> DONE size=[file size $root/buttons_leds_z010.bit]"
