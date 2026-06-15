set root [file normalize [file dirname [info script]]]
# hdl-util/hdmi core (all .sv), the Verilog-friendly wrapper, then our top.
read_verilog -sv [glob $root/hdmi_core/*.sv]
read_verilog -sv $root/hdmi_wrap.sv
read_verilog $root/hdmi_beep_top.v
read_xdc $root/hdmi_beep.xdc
synth_design -top hdmi_beep_top -part xc7z010clg400-1
opt_design
place_design
route_design
write_bitstream -force $root/hdmi_beep_z010.bit
puts ">>> DONE size=[file size $root/hdmi_beep_z010.bit]"
