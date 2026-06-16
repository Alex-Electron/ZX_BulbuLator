# bulb_axi_test.xdc  -  EBAZ4205 (xc7z010clg400-1). Milestone 1: AXI GP0 handshake test.
# Contact: lavrinovich.alex@gmail.com
# Only the two diagnostic LEDs are physical IO; the M_AXI_GP0 slave is internal to the PL.

# ---- Diagnostic LEDs (same pins as the ZX build) ----
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports led_ctrl]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports led_heart]

# ---- PS7 FCLK0 = 100 MHz. Raw-primitive flow: constrain it explicitly so the AXI logic
#      is timed (the ZX build leaned on the MMCM's CLKIN1_PERIOD; here FCLK0 feeds directly). ----
create_clock -period 10.000 -name fclk0 [get_pins ps7_stub/FCLKCLK[0]]

# ---- Global config ----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.STARTUP.LCK_CYCLE NoWait [current_design]
set_property BITSTREAM.STARTUP.MATCH_CYCLE NoWait [current_design]
