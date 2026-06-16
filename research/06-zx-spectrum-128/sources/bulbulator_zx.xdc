# bulbulator_zx.xdc  -  EBAZ4205 (xc7z010clg400-1), Atlas ZX Spectrum 128K + HDMI.
# Contact: lavrinovich.alex@gmail.com
# HDMI / LED / voltage block kept verbatim from the proven Step-5 (hdmi-beep) build.

# ---- HDMI TMDS: "family B" pinout (clock F19/F20). Bank 35. Driven by OBUFDS. ----
set_property -dict { PACKAGE_PIN F19 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_p]
set_property -dict { PACKAGE_PIN F20 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_n]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[0]}]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[0]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[1]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[1]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[2]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[2]}]

# ---- Diagnostic LEDs ----
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led_lock]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led_heart]

# ---- Expansion-board push-buttons (active-low). ----
#   btn[0]=P19 DOWN, btn[1]=T19 UP, btn[2]=U20 ENTER, btn[3]=U19 BREAK/RESET
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[1]}]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[2]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[3]}]

# ---- Tape audio input (external player). J19, LVCMOS33 with internal pull-down. ----
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN } [get_ports ear_in]

# ---- Global config ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]

# ---- Clocks ----
# No explicit create_clock: matching the proven Step-5 flow. The PS7 stub FCLK0 is a
# recognised clock source and the MMCMs carry CLKIN1_PERIOD(10.0), so Vivado auto-creates
# the pixel/serial/Spectrum generated clocks. (Step-5 built and ran on hardware this way.)

# ---- Clock-domain crossings ----
# 1) Framebuffer async dual-clock BRAM: write side (spclk) -> read side (clk_pixel).
#    The BRAM IS the synchroniser; cut timing on the captured read data.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *fb_i*rd_q*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *fb_i*in_pic_q*}]
# 2) Audio resync (spclk -> clk_audio): 2-FF synchroniser on the slow-changing word.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *left16_a0*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *right16_a0*}]
# 3) sp_lock into the spclk domain (reset generator synchroniser).
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *lock_sync*}]
# 4) ear_in async input into the spclk domain (2-FF synchroniser).
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ear_sync*}]
