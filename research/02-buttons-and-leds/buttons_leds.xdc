# Shield buttons (active-low, internal pull-up) and the two LEDs — same pins as
# the HDMI demo, on the unchanged expansion board.
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn0]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn1]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn2]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn3]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led0]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led1]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]
