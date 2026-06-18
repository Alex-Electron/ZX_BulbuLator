# bulbulator_ddr.xdc  -  EBAZ4205 (xc7z010clg400-1), Atlas ZX 128K + AXI inject + DDR double-buffer.
# Contact: lavrinovich.alex@gmail.com
# HDMI / LED / button / ear / voltage block verbatim from the proven bulbulator_zx.xdc.

# ---- HDMI TMDS: "family B" (clock F19/F20). ----
set_property -dict { PACKAGE_PIN F19 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_p]
set_property -dict { PACKAGE_PIN F20 IOSTANDARD TMDS_33 } [get_ports TMDS_Clk_n]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[0]}]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[0]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[1]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[1]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_p[2]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {TMDS_Data_n[2]}]

set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led_lock]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led_heart]

set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[1]}]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[2]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports {btn[3]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN } [get_ports ear_in]

set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports ps2_clk]   ;# DATA2-07
set_property -dict { PACKAGE_PIN H20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports ps2_data]  ;# DATA2-08

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]

# ---- Clock-domain crossings ----
# audio resync (spclk -> clk_audio) + reset/ear synchronisers (verbatim)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *left16_a0*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *right16_a0*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *lock_sync*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ear_sync*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ps2c_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ps2d_s_reg*}]
# DDR-framebuffer CDCs:
#   async_fifo (spclk <-> fclk100) gray-pointer synchronisers + RAM data crossing
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *ddrfifo*rgray_w1_reg*}]
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *ddrfifo*wgray_r1_reg*}]
set_false_path -through [get_pins  -hierarchical -filter {NAME =~ *ddrfifo*mem*/O*}]
#   capture-enable + vblank-kick + HP-reset synchronisers
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *capen_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *vbl_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *hprstn_s_reg*}]
#   display BRAM read crossing (fclk100 write / clk_pixel read)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ddrdisp*rd_q_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ddrdisp*rd_nib_q_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ddrdisp*in_pic_q_reg*}]
