# ps2_test.xdc  -  EBAZ4205 (xc7z010clg400-1)  -  standalone PS/2 keyboard read test.
# Contact: lavrinovich.alex@gmail.com
# Two free DATA2 header pins (verified free against the Step-8 bitstream): both LVCMOS33, with an
# internal pull-up as a backstop to the external 10k PS/2 pull-ups.

set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports ps2_clk]   ;# DATA2-07
set_property -dict { PACKAGE_PIN H20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports ps2_data]  ;# DATA2-08

set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led_lock]   ;# DATA1-14
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led_heart]  ;# DATA1-15

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# The PS/2 pins are asynchronous to fclk100 - false-path the 2-FF input synchronisers.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ck_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *d_s_reg*}]
