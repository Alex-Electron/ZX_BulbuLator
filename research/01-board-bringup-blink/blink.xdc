# Same shield LEDs as the HDMI demo (unchanged expansion board).
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led0]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led1]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]
