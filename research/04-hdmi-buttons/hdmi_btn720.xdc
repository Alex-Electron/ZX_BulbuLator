# HDMI TMDS — проверенная распайка адаптера (семейство B): clock F19/F20. Банк 35.
set_property -dict { PACKAGE_PIN F19 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_p]
set_property -dict { PACKAGE_PIN F20 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_n]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[0]}]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[0]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[1]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[1]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[2]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[2]}]
# Кнопки (DATA3): active-low, кнопка между пином и GND, внутренний PULLUP
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn0]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn1]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn2]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports btn3]
# Диагностика: D18 = MMCM locked, H18 = сердцебиение пиксель-клока (~1 Гц)
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led_lock]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led_heart]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# Несжатый битстрим (сжатые флачат по XVC-JTAG) + стартап без ожиданий
set_property BITSTREAM.GENERAL.COMPRESS FALSE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]
