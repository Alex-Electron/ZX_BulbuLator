# bulbulator_ddr.xdc  -  EBAZ4205 (xc7z010clg400-1), Atlas ZX 128K + AXI inject + DDR double-buffer.
# Step-15 revision: this design previously shipped with NO clock definitions at all (the PS7 is a raw
# primitive, so Vivado creates no automatic clock on FCLKCLK) - every path was UNTIMED and each
# resynthesis was a placement lottery ("timing met" was vacuously true). This file adds the primary
# clock + asynchronous clock groups, and drops two exception patterns that never matched anything
# plus four blanket -to false_paths that would have exempted a same-clock pixel cone from analysis.
# Pin blocks are verbatim from the proven Step-12 file.
# Contact: lavrinovich.alex@gmail.com

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

# ==== CLOCKS (Step 15: the one primary clock the design always lacked) ====
# PS7 FCLK0 = 100 MHz. Everything else derives from it automatically:
#   clock_zx_i/mmcm CLKOUT0 -> spclk ~56.667 MHz (machine core)
#   mmcm         CLKOUT0 -> clk_pixel 74.25 MHz, CLKOUT1 -> clk_ser 371.25 MHz (HDMI)
# control_plane: the shell (PS7, HDMI MMCM, audio divider) lives under the `shell` instance now
create_clock -period 10.000 -name fclk100 [get_pins shell/ps7_stub/FCLKCLK[0]]

# ~48 kHz audio sample clock: a register-divided clock (clk_pixel / 1547) that clocks the HDMI
# audio resync stage. Declared so its domain is analyzed instead of silently untimed.
create_generated_clock -name clk_audio -source [get_pins shell/b0/O] -divide_by 1547 \
    [get_pins shell/clk_audio_r_reg/Q]

# The three domains are architecturally asynchronous (every crossing goes through a gray-pointer
# FIFO, a 2-FF/3-FF synchroniser, a toggle handshake, or a settle-latch - see the audit table in
# the vault spec). clk_pixel + clk_ser + clk_audio stay in ONE group: the OSERDES feed and the
# audio divider are truly synchronous to clk_pixel and MUST be timed against it.
set_clock_groups -asynchronous \
    -group [get_clocks fclk100] \
    -group [get_clocks -of_objects [get_pins clock_zx_i/mmcm/CLKOUT0]] \
    -group [list [get_clocks -of_objects [get_pins shell/mmcm/CLKOUT0]] \
                 [get_clocks -of_objects [get_pins shell/mmcm/CLKOUT1]] \
                 [get_clocks clk_audio]]

# ---- Clock-domain crossings ----
# With the clock groups above, cross-domain paths are already excluded from timing; the -to lines
# below are kept as belt-and-suspenders documentation of the synchroniser first stages (they are
# fed ONLY by cross-domain sources, so they cut nothing same-clock).
# audio resync (spclk -> clk_audio) + reset/ear synchronisers (verbatim)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *left16_a0*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *right16_a0*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *lock_sync*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ear_sync*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ps2c_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ps2d_s_reg*}]
# DDR-framebuffer CDCs: async_fifo (spclk <-> fclk100) gray-pointer synchronisers.
# (The old `-through *ddrfifo*mem*/O*` + `*kbd_fifo_i*mem*/O*` exceptions are GONE: they never
# matched a single pin in any build - distributed RAM synthesizes to RAM32M/RAM64M cell names -
# and produced a CRITICAL WARNING every run. The data crossing is covered by the clock groups.)
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *ddrfifo*rgray_w1_reg*}]
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *ddrfifo*wgray_r1_reg*}]
#   capture-enable + vblank-kick + HP-reset synchronisers
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *capen_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *vbl_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *hprstn_s_reg*}]
# Keyboard-gate CDCs (spclk <-> fclk100): OSD-enable level sync + deadman heartbeat toggle sync
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *osd_en_s_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *kick_sync_reg*}]
#   keyboard scancode async_fifo (kbd_fifo_i) gray-pointer synchronisers
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *kbd_fifo_i*rgray_w1_reg*}]
set_false_path -to      [get_cells -hierarchical -filter {NAME =~ *kbd_fifo_i*wgray_r1_reg*}]
#   display readers' cross-domain sync first stages (fb_line_disp `ddrdisp` + osd_ddr_rd `osddr`).
#   NOTE: the old blanket `-to *ddrdisp*{rd_q,nib_q,in_pic_q,have_q}_reg*` lines are deliberately
#   GONE - they also exempted the SAME-CLOCK clk_pixel cone (cy*STRIDE multiply -> LUTRAM read ->
#   64-bit mux -> rd_q), which must be timed. The genuine CDC leg (fclk100 LUTRAM write -> pixel
#   read) is cut by the clock groups.
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ddrdisp*nr_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *ddrdisp*v_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *osddr*nr_s1_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *osddr*v_s1_reg*}]
# Step 12 AXI-RESET CDC (aclk <-> spclk): reset-request toggle sync + busy level sync (inject_cdc)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *inj_i*rsync_reg*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *inj_i*rb_sync_reg*}]

# ---- Ethernet PHY (IP101GA) через EMIO: провода от GEM0 процессора к ногам ПЛИС ----
# Ноги ВОССТАНОВЛЕНЫ по документации платы: в наших файлах их не было (жили в проекте внутри
# погибшей ВМ), и все 15 у нас были свободны. Банк 34, поэтому LVCMOS33 как у остальных.
# U18 - ОПОРНЫЙ такт для самого PHY: без него микросхема не отвечает даже по MDIO (проверено:
# молчали все 32 адреса). В документации сеть подписана CLK_50M_PHY, но четырёхбитному MII нужны
# 25 МГц, и прежний проект ровно для этого держал синтезатор частоты.
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {eth_txd[0]}]
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports {eth_txd[1]}]
set_property -dict { PACKAGE_PIN V18 IOSTANDARD LVCMOS33 } [get_ports {eth_txd[2]}]
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports {eth_txd[3]}]
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports eth_tx_en]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports eth_tx_clk]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports {eth_rxd[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {eth_rxd[1]}]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {eth_rxd[2]}]
set_property -dict { PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 } [get_ports {eth_rxd[3]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports eth_rx_dv]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports eth_rx_clk]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports eth_mdc]
set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports eth_mdio]
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports eth_ref_clk]

# Такты приёма и передачи приходят ОТ PHY (25 МГц). В фабрике на них ничего не висит - они уходят
# прямо в примитив PS7, - но объявить их надо, иначе домен останется неанализируемым.
create_clock -period 40.000 -name eth_rx_clk [get_ports eth_rx_clk]
create_clock -period 40.000 -name eth_tx_clk [get_ports eth_tx_clk]
set_clock_groups -asynchronous -group [get_clocks {eth_rx_clk eth_tx_clk}]

# U15 (TX_CLK) - это N-сторона дифференциальной тактовой пары (IO_L11N_T1_SRCC_34), и одиночным
# тактовым входом Vivado её использовать НЕ ДАЁТ: ERROR [Place 30-876]. Нога задана разводкой платы,
# выбора у нас нет, поэтому разрешаем недедицированный маршрут до тактового буфера - на 25 МГц это
# безопасно. RX_CLK на U14 - P-сторона той же пары и идёт штатным путём.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins shell/bufg_eth_tx/I]]
