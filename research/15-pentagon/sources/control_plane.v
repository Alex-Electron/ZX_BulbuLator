`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// control_plane.v - THE machine-agnostic BulbuLator shell, in ONE module.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// WHY THIS MODULE EXISTS (owner decision, 2026-07-30). PS/2 physically sits in the FPGA and we ship
// ONE bitstream per machine, so every bitstream must carry the whole shared shell. Until now each
// per-core top wired that shell BY HAND, and the copies drifted. One root cause produced four field
// defects in a single day:
//   * ps2_tx was never carried into the NES top -> keyboard commands (NumLock LED) were impossible;
//   * fb_capture_rr computed its lead-in from a hard-coded ZX raster -> 22 pad rows on the NES;
//   * the joypad bit order diverged between cores -> every wizard label lied, SOCD killed A+B;
//   * the screen scale was a compile-time parameter -> could not be a per-machine setting at all.
// From now on a core top instantiates control_plane ONCE and cannot omit a piece: navigator video,
// OSD, keyboard (RX and TX), joysticks, ARM audio, AXI registers, QUIESCE - all live here.
//
// WHAT IS MACHINE-AGNOSTIC (lives here, owner spec): PS7 + all three AXI ports, HDMI clocks/output,
// the DDR framebuffer chain (capture -> FIFO -> writer/triple-buffer -> line scanout), both OSD
// layers + banner, the ARM music FIFO + volume, PS/2 receive AND transmit, the scancode FIFO,
// JOY_STATE, QUIESCE. Future machine-agnostic hardware belongs here too:
//   * HARDWARE JOYSTICK ports: OR the pad lines into the same JOY_STATE halves (P1 -> [7:0],
//     P2 -> [23:16]; the CE22 platform bit order 0=R 1=L 2=D 3=U 4=A 5=B 6=Sel 7=Start), then raise
//     LOAD_CAPS bits 1/2. The ARM already clamps per-player input sources until those bits appear.
//   * HARDWARE DAC: tap the FINAL post-volume PCM (audio_l_f/audio_r_f below) - it is the same
//     signal HDMI gets, already machine-mixed and volume-scaled.
// WHAT IS MACHINE-SPECIFIC (stays in the core top): the core clock generator, the core itself, its
// reset/wipe policy, RAM injection CDC, tape/warp/ROM-trap machinery, NemoBus (ZX edge connector),
// the machine leg of the audio mix, and the meaning of the repurposable diagnostic registers
// (memwr_cnt / kbd_diag are INPUTS here because each machine feeds its own counters).
//
// KEYBOARD DOMAIN NOTE. The ZX decodes PS/2 on ITS core clock (spclk/pe3M5) because the decoded
// stream feeds the Z80 matrix synchronously; the NES has no such consumer and runs it on fclk100
// with an internal /28 clock enable. Both live behind PS2_INT_CE: 0 = the top supplies kclk_i/kce_i
// (ZX legacy, byte-identical), 1 = internal fclk100 CE (machine-independent; the long-term home).
//-------------------------------------------------------------------------------------------------
module control_plane #(
    parameter [31:0] VERSION       = 32'hB01B0000,
    // ---- power-on reset shape (aclk) ----
    parameter integer POR_BITS       = 4,   // ZX legacy: 4-bit counter; NES: 16-bit
    parameter integer WAIT_HDMI_LOCK = 0,   // 1: hold POR until the HDMI MMCM locks (NES style)
    // ---- capture geometry (core video -> DDR) ----
    parameter integer CAP_W = 384, CAP_H = 302, CAP_BPP = 4,
    parameter integer CAP_LEADIN_AUTO = 0,  // 1 = lead-in from the MEASURED first visible line
    parameter integer WR_WORDS = 7248,      // CAP_W*CAP_H*CAP_BPP/64 - fixed words per frame
    parameter integer KICK_CORE_VSYNC = 0,  // 1: frame_kick from core vsync (NES); 0: HDMI vblank (ZX)
    // ---- scanout geometry (fb_line_disp) ----
    parameter integer SRC_W = 384, STRIDE = 384, CROP_W = 384, CROP_H = 302,
    parameter integer HMARGIN = 256, VMARGIN = 58, SX0 = 0,
    parameter integer SRC_BPP = 4, WSH = 4, LBPP = 2, FBURSTS = 3,
    parameter integer LIVE_CROP = 1,        // 1: CROP_A/B registers trim the window (ZX); 0: fixed
    // ---- audio ----
    parameter integer AUDIO_DC_BLOCK = 1,   // 1: post-volume single-pole HPF before HDMI (ZX)
    // ---- PS/2 ----
    parameter integer PS2_INT_CE    = 0,    // 1: internal fclk100/28 CE; 0: kclk_i/kce_i from top
    parameter integer PS2TX_INHIBIT = 8000, // request-to-send CLK-low, in kclk cycles (>=100 us!)
    parameter integer PS2TX_TIMEOUT = 500000,
    // CE29/B0066: идентичность и способности ЯДРА - параметрами, а не значением по умолчанию.
    // Было: MACHINE_ID жил дефолтом внутри axi_ctl, и ни один топ его не переопределял - NES
    // представлялся как "ZX 128K". Прошивке приходилось опознавать ядро по VERSION, из-за чего
    // номер версии стал идентификатором и его нельзя было поднимать (свежий MiSTer-48 рапортовал
    // "0059" со старой оболочкой внутри). Теперь ядро говорит, КТО оно, а VERSION - это версия.
    parameter [31:0]  MACHINE_ID    = 32'h00805A58,   // {резерв, вариант, 'ZX'} по умолчанию
    parameter [31:0]  LOAD_CAPS_P   = 32'h00000009,
    // CE30/B0067: порт HP2 отдан ПАМЯТИ МАШИНЫ (ddr_mem). Измеритель пути ddr_probe свою работу
    // сделал - цифры получены 31.07 и записаны в волт, прошивка его не запускает, а держал он 343 LUT.
    // Ставь DDR_PROBE=1, если понадобится перемерить: тогда памяти на HP2 не будет.
    parameter integer DDR_PROBE   = 0,
    // Окно памяти машины в PS DDR. ОБЯЗАТЕЛЬНО внутри НЕКЕШИРУЕМОГО окна прошивки
    // (0x0F700000..0x0FFFFFFF, 9 секций помечены NORM_NONCACHE в main()): иначе ARM и JTAG видят
    // устаревшие строки кеша, а PL пишет в физическую память - расхождение поймано приборно на
    // первом же прогоне при базе 0x0F400000. Выбрано 0x0FE00000: выше буфера файловой службы
    // (0x0F900000, ему остаётся 5 МБ) и ниже тройного буфера кадра (0x0FF00000).
    parameter [31:0]  MEM_BASE    = 32'h0FE00000,
    parameter integer MEM_ADDR_W  = 20
)(
    // ================= board pins =================
    output wire        TMDS_Clk_p,  output wire TMDS_Clk_n,
    output wire [2:0]  TMDS_Data_p, output wire [2:0] TMDS_Data_n,
    inout  wire        ps2_clk, inout wire ps2_data,
    output wire        led_heart,
    // ============ Ethernet PHY через EMIO (оболочка: сеть машино-агностична) ============
    // PHY этой платы (IP101GA) висит на ногах ПЛИС, а не на MIO, поэтому сеть процессора
    // ходит наружу проводами через EMIO. Программная сторона уже настроена на EMIO
    // (GEM0_RCLK_CTRL=0x11), менять её не нужно. Разбор: webkvm/WEBKVM_ONBOARD.md.
    output wire [3:0]  eth_txd,        // W18 Y18 V18 Y19
    output wire        eth_tx_en,      // W19
    input  wire        eth_tx_clk,     // U15, 25 МГц ОТ PHY
    input  wire [3:0]  eth_rxd,        // Y16 V16 V17 Y17
    input  wire        eth_rx_dv,      // W16
    input  wire        eth_rx_clk,     // U14, 25 МГц ОТ PHY
    output wire        eth_mdc,        // W15
    inout  wire        eth_mdio,       // Y14, двунаправленный
    output wire        eth_ref_clk,    // U18, опорные 25 МГц ДЛЯ PHY (иначе он мёртв)
    // ================= clocks / resets to the machine =================
    output wire        fclk100_o,      // PS7 FCLK0 through BUFG - source for the core's own PLLs
    output wire        clk_pixel_o,    // 74.25 MHz (HDMI raster)
    output wire        clk_audio_o,    // ~48 kHz sample clock (reg clock)
    output wire        aresetn_o,      // aclk power-on reset (never re-asserts)
    output wire        core_resetn_o,  // aresetn & HP0-slave-out-of-reset (DDR masters' reset)
    input  wire        ext_lock_i,     // machine PLL lock(s); gate POR on it (tie 1'b1 if unused)
    // ================= machine video in (cap_clk domain) =================
    input  wire        cap_clk_i,      // the core's video clock (ZX spclk / NES nesclk)
    input  wire        cap_rstn_i,     // core-domain power-on reset (por_n)
    input  wire        cap_ce_i,       // pixel clock-enable (ZX pe7M0 / NES vid_wr_ce)
    input  wire        cap_hsync_i, cap_vsync_i, cap_blank_i,
    input  wire        scr_sel_i,          // B0198: какой экран машина показывает (ZX: 7FFD[3]); машины без второго экрана - 0
    input  wire        cap_r_i, cap_g_i, cap_b_i, cap_i_i,   // 4bpp RGBI path
    input  wire [7:0]  cap_pix8_i,                           // 8bpp palette-index path
    // ================= machine audio in (clk_audio domain) =================
    input  wire [15:0] aud_src_l_i,    // pre-volume PCM: machine mix (+player crossfade) done in top
    input  wire [15:0] aud_src_r_i,
    // player leg for the top's crossfade (all clk_audio domain)
    output wire [31:0] player_pcm_o,   // held ARM sample {R,L}
    output wire [8:0]  player_gain_o,  // pgain 0..256 (ramped AUDIO_CTRL crossfade)
    output wire [8:0]  machine_gain_o, // 256 - pgain
    // ================= PS/2 stream taps (kclk domain; the ZX matrix adapter consumes these) =====
    input  wire        kclk_i,         // PS2_INT_CE=0: the keyboard clock domain (ZX spclk)
    input  wire        kce_i,          //   and its decode clock-enable (ZX pe3M5)
    output wire        ps2_strb_o, ps2_make_o,
    output wire [7:0]  ps2_code_o,
    output wire        ps2tx_busy_o,
    // ---- память машины в DDR (Пентагон 1024 / картридж NES). Машина даёт свой такт. ----
    input  wire        mem_mclk_i,
    input  wire [19:0] mem_addr_i,
    input  wire [7:0]  mem_wdata_i,
    input  wire        mem_rd_i,
    input  wire        mem_wr_i,
    output wire [7:0]  mem_rdata_o,
    output wire        mem_wait_o,
    // Слот отладки машины -> регистр 0x150. Приходит в такте машины, поэтому синхронизируется
    // здесь двумя триггерами: поля меняются медленно, а софт читает их многократно.
    input  wire [31:0] mach_dbg_i,
    input  wire [31:0] rom_dbg_i,         // B0147: прибор трапа Beta Disk -> 0x1BC
    input  wire [31:0] aud_dbg_i,      // B0088: 0x170 пики звука (машина наполняет, оболочка отдаёт)
    output wire [31:0] ps2_diag_o,     // {resend_cnt, perr_cnt} synced to aclk - feed kbd_diag_i on ZX
    // ================= QUIESCE (machine DDR masters must join!) =================
    output wire        ctl_quiesce_o,
    input  wire        mach_axi_idle_i, // machine's own DDR masters idle (tie 1'b1 if none)
    // ================= diagnostics taps =================
    output wire [15:0] wr_accept_cnt_o, // AXI-HP writes accepted (the classic hpw counter)
    output wire        cap_fifo_ov_o,   // sticky: capture FIFO overflowed (aclk-synced)
    output wire        ld_live_o,       // scanout completed a line fetch (HP path is up)
    // ================= axi_ctl pass-through: MACHINE-side registers =================
`ifdef NES_CORE
    output wire [63:0] ctl_nes_mapper_o,
    output wire [21:0] ctl_nes_ld_addr_o,
    output wire [7:0]  ctl_nes_ld_data_o,
    output wire        ctl_nes_ld_we_o, ctl_nes_ld_sel_o, ctl_nes_loading_o, ctl_nes_reset_o,
`endif
    // B0071: заливка ПЗУ машины (0x154/0x158/0x15C). ВНЕ ifdef - механизм машино-агностичный:
    // оболочка даёт шину, машина решает, что такое «страница ПЗУ». Ядру без ПЗУ порты можно не
    // подключать (LOAD_CAPS бит4 тогда не поднимают, и прошивка не пытается лить).
    // B0075 дисковод: мост подачи секторов (машина решает, что это значит)
    output wire [31:0] ctl_fdc_ctl_o,
    output wire        ctl_fdc_ctl_we_o,
    // General Sound: свой блок регистров, проброс по образцу дисковода
    input  wire [31:0] gs_stat_i,
    input  wire [31:0] gs_stat2_i,     // B0119: {потеряно байт[27:16], удержаний шины[11:0]}
    input  wire [31:0] gs_stat3_i,     // B0119: {сторож[31:30], тактов процессора в ожидании[19:0]}
    // B0108: упругая очередь записей #B3 живёт в топе (там оба такта), сюда приходит её сторона чтения
    output wire [31:0] ctl_nemo_o,          // B0112 NEMO-IDE
    output wire        ctl_nemo_we_o,
    input  wire [31:0] nemo_stat_i, nemo_stat2_i,
    output wire [31:0] ctl_kmouse_o,        // B0116 мышь Kempston (0x190)
    output wire        ctl_kmouse_we_o,
    // DivMMC: карта SD в фабрике, том и запись на ARM (0x19C..0x1B8). Оболочка тут только транзит.
    output wire [31:0] ctl_dmmc_o,
    output wire        ctl_dmmc_we_o,
    output wire [31:0] ctl_dmmc_cap_o,
    output wire [31:0] ctl_dmmc_bufa_o,
    output wire        ctl_dmmc_bufa_we_o,
    output wire [31:0] ctl_dmmc_bufw_o,
    output wire        ctl_dmmc_bufw_we_o,
    output wire        ctl_dmmc_bufr_re_o,
    input  wire [31:0] dmmc_bufa_i, dmmc_bufr_i, dmmc_stat_i, dmmc_lba_i, dmmc_dbg_i,
    input  wire [7:0]  gs_rq_dout_i,
    input  wire        gs_rq_empty_i,
    input  wire [8:0]  gs_rq_cnt_i,
    output wire        gs_rq_rd_o,
    output wire [31:0] ctl_gs_ctl_o,
    output wire        ctl_gs_ctl_we_o,
    output wire [7:0]  ctl_fdc_data_o,
    output wire        ctl_fdc_data_we_o,
    input  wire [31:0] fdc_stat_i,
    input  wire [31:0] fdc_stat2_i,
    output wire [15:0] ctl_rom_ld_addr_o,
    output wire [7:0]  ctl_rom_ld_data_o,
    output wire        ctl_rom_ld_we_o,
    output wire        ctl_rom_loading_o,
    output wire        ctl_halt_o,
    output wire        ctl_ram_we_o,
    output wire [16:0] ctl_ram_addr_o, ctl_ram_waddr_o,
    output wire [7:0]  ctl_ram_data_o,
    output wire [211:0] ctl_dir_o,
    output wire [5:0]  ctl_7ffd_o,
    output wire [2:0]  ctl_border_o,
    output wire        ctl_dir_commit_o, ctl_port_commit_o, ctl_reset_o,
    output wire        ctl_osd_enable_o, ctl_ddr_osd_en_o,   // the ZX keyboard gate wants the OR
    output wire        ctl_tape_run_o, ctl_tape_earmux_o, ctl_tape_mute_o,
    output wire [1:0]  ctl_tape_fmode_o,
    output wire        ctl_tape_sync_o, ctl_tape_more_o, ctl_tape_we_o,
    output wire [31:0] ctl_tape_data_o,
    input  wire        tape_full_i, tape_playing_i,
    input  wire [31:0] tape_diag_count_i, tape_diag_hash_i, tape_diag_gaps_i, tape_diag_resumes_i,
    input  wire [31:0] fe_trace_count_i, fe_trace_hash_i, fe_trace_last_i,
    output wire [8:0]  ctl_kbd_inject_o,
    output wire        ctl_kbd_inject_we_o,
    output wire        kbd_deadman_kick_o,
    output wire        ctl_pentagon_o, ctl_model48_o, ctl_ula_late_o, ctl_force_atlas_o, ctl_snow_off_o,
    output wire [31:0] ctl_mach_cfg_o,
    output wire [31:0] ctl_pent_int_o,
    output wire [31:0] ctl_ula_tune_o, ctl_ula_tune2_o,
    output wire [8:0]  ctl_paper_h_o, ctl_paper_v_o,
    output wire [31:0] ctl_joy_o,
    output wire [31:0] ctl_warp_hold_o, ctl_sync_hold_o,
    output wire        ctl_romtrap_en_o, ctl_romtrap_done_we_o,
    output wire [10:0] ctl_scr_raddr_o,
    input  wire [31:0] scr_rdata_i,
    input  wire        halt_ack_i, ram_busy_i, reset_busy_i,
    input  wire        rt_pending_a_i,
    input  wire [5:0]  p7ffd_s1_i,
    input  wire [211:0] reg_rd1_i,
    input  wire [15:0] sync_diag_i,
    input  wire [31:0] memwr_cnt_i,    // repurposable per machine (ZX: RAM-write counter; NES: {hpw,act})
    input  wire [31:0] kbd_diag_i      // repurposable per machine (ZX: ps2_diag_o looped back; NES: dbg2)
);
    //=============================================================================================
    // PS7: FCLK0 (100 MHz) + M_AXI_GP0 master + S_AXI_HP0 (fb write/read) + S_AXI_HP1 (OSD read).
    //=============================================================================================
    wire [3:0] fclk;
    wire [3:0] FCLKRESETN;

    wire [31:0] gp0_awaddr;  wire [11:0] gp0_awid;  wire [3:0] gp0_awlen;
    wire        gp0_awvalid; wire        gp0_awready;
    wire [31:0] gp0_wdata;   wire [3:0]  gp0_wstrb; wire        gp0_wlast;
    wire        gp0_wvalid;  wire        gp0_wready;
    wire [11:0] gp0_bid;     wire [1:0]  gp0_bresp; wire        gp0_bvalid; wire gp0_bready;
    wire [31:0] gp0_araddr;  wire [11:0] gp0_arid;  wire [3:0] gp0_arlen;
    wire        gp0_arvalid; wire        gp0_arready;
    wire [31:0] gp0_rdata;   wire [11:0] gp0_rid;   wire [1:0] gp0_rresp;
    wire        gp0_rlast;   wire        gp0_rvalid; wire       gp0_rready;

    wire        hp_aresetn;
    wire [31:0] hp_araddr;  wire [5:0] hp_arid; wire [3:0] hp_arlen; wire [2:0] hp_arsize;
    wire [1:0]  hp_arburst; wire [3:0] hp_arcache; wire [2:0] hp_arprot; wire [1:0] hp_arlock; wire [3:0] hp_arqos;
    wire        hp_arvalid, hp_arready;
    wire [63:0] hp_rdata;   wire [5:0] hp_rid; wire [1:0] hp_rresp; wire hp_rlast, hp_rvalid, hp_rready;
    wire [31:0] hp_awaddr;  wire [5:0] hp_awid; wire [3:0] hp_awlen; wire [2:0] hp_awsize;
    wire [1:0]  hp_awburst; wire [3:0] hp_awcache; wire [2:0] hp_awprot; wire [1:0] hp_awlock; wire [3:0] hp_awqos;
    wire        hp_awvalid, hp_awready;
    wire [63:0] hp_wdata;   wire [7:0] hp_wstrb; wire hp_wlast, hp_wvalid, hp_wready;
    wire        hp_bvalid, hp_bready;

    // S_AXI_HP2: свободный порт. Сейчас на нём аппаратный измеритель пути PL->память (ddr_probe),
    // и он же - будущий порт DDR-картриджа: HP0 занят кадром, HP1 - OSD.
    wire        hp2_aresetn;
    wire [31:0] hp2_araddr;  wire [5:0] hp2_arid; wire [3:0] hp2_arlen; wire [2:0] hp2_arsize;
    wire [1:0]  hp2_arburst; wire [3:0] hp2_arcache; wire [2:0] hp2_arprot; wire [1:0] hp2_arlock; wire [3:0] hp2_arqos;
    wire        hp2_arvalid, hp2_arready;
    wire [63:0] hp2_rdata;   wire [5:0] hp2_rid; wire [1:0] hp2_rresp; wire hp2_rlast, hp2_rvalid, hp2_rready;
    // CE30/B0067: у HP2 появляется КАНАЛ ЗАПИСИ. Раньше порт был разведён только на чтение
    // («probe today, DDR cartridge tomorrow»), но памяти машины нужна и запись: расширенные банки
    // Пентагона процессор пишет так же, как читает. Мастер - ddr_mem.v.
    wire [31:0] hp2_awaddr;  wire [3:0] hp2_awlen; wire [2:0] hp2_awsize;
    wire [1:0]  hp2_awburst; wire [3:0] hp2_awcache; wire [2:0] hp2_awprot;
    wire [1:0]  hp2_awlock;  wire [3:0] hp2_awqos;
    wire        hp2_awvalid, hp2_awready;
    wire [63:0] hp2_wdata;   wire [7:0] hp2_wstrb; wire hp2_wlast, hp2_wvalid, hp2_wready;
    wire        hp2_bvalid,  hp2_bready;
    wire        hp1_aresetn;
    wire [31:0] hp1_araddr;  wire [5:0] hp1_arid; wire [3:0] hp1_arlen; wire [2:0] hp1_arsize;
    wire [1:0]  hp1_arburst; wire [3:0] hp1_arcache; wire [2:0] hp1_arprot; wire [1:0] hp1_arlock; wire [3:0] hp1_arqos;
    wire        hp1_arvalid, hp1_arready;
    wire [63:0] hp1_rdata;   wire [5:0] hp1_rid; wire [1:0] hp1_rresp; wire hp1_rlast, hp1_rvalid, hp1_rready;

    wire fclk100;
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));
    assign fclk100_o = fclk100;

    //=========================================================================================
    // Ethernet: проброс EMIO наружу. Ячеек по минимуму - 2 тактовых буфера, 2 триггера
    // делителя и один двунаправленный вывод. MII четырёхбитный, поэтому у восьмибитных шин
    // GMII используются младшие четыре бита.
    //=========================================================================================
    wire       eth_rxclk_g, eth_txclk_g;
    BUFG bufg_eth_rx (.I(eth_rx_clk), .O(eth_rxclk_g));
    BUFG bufg_eth_tx (.I(eth_tx_clk), .O(eth_txclk_g));

    reg [1:0] eth_div = 2'd0;                       /* 100 МГц / 4 = 25 МГц опорных для PHY */
    always @(posedge fclk100) eth_div <= eth_div + 2'd1;
    assign eth_ref_clk = eth_div[1];

    wire [7:0] eth_txd8;
    assign eth_txd = eth_txd8[3:0];
    wire eth_mdio_o, eth_mdio_tn;
    wire eth_mdio_i = eth_mdio;                     /* TN=1 значит отпустить линию */
    assign eth_mdio = eth_mdio_tn ? 1'bz : eth_mdio_o;

    (* DONT_TOUCH = "true" *) PS7 ps7_stub (
        .EMIOENET0GMIITXD   (eth_txd8),      .EMIOENET0GMIITXEN (eth_tx_en),
        .EMIOENET0GMIITXCLK (eth_txclk_g),   .EMIOENET0GMIITXER (),
        .EMIOENET0GMIIRXCLK (eth_rxclk_g),   .EMIOENET0GMIIRXD  ({4'b0, eth_rxd}),
        .EMIOENET0GMIIRXDV  (eth_rx_dv),     .EMIOENET0GMIIRXER (1'b0),
        .EMIOENET0GMIICOL   (1'b0),          .EMIOENET0GMIICRS  (1'b0),
        .EMIOENET0MDIOMDC   (eth_mdc),       .EMIOENET0MDIOO    (eth_mdio_o),
        .EMIOENET0MDIOTN    (eth_mdio_tn),   .EMIOENET0MDIOI    (eth_mdio_i),
        .FCLKCLK        (fclk),
        .FCLKRESETN     (FCLKRESETN),
        .MAXIGP0ACLK    (fclk100),
        .MAXIGP0AWADDR  (gp0_awaddr),  .MAXIGP0AWID   (gp0_awid),    .MAXIGP0AWLEN  (gp0_awlen),
        .MAXIGP0AWVALID (gp0_awvalid), .MAXIGP0AWREADY(gp0_awready),
        .MAXIGP0WDATA   (gp0_wdata),   .MAXIGP0WSTRB  (gp0_wstrb),   .MAXIGP0WLAST  (gp0_wlast),
        .MAXIGP0WVALID  (gp0_wvalid),  .MAXIGP0WREADY (gp0_wready),
        .MAXIGP0BID     (gp0_bid),     .MAXIGP0BRESP  (gp0_bresp),   .MAXIGP0BVALID (gp0_bvalid),
        .MAXIGP0BREADY  (gp0_bready),
        .MAXIGP0ARADDR  (gp0_araddr),  .MAXIGP0ARID   (gp0_arid),    .MAXIGP0ARLEN  (gp0_arlen),
        .MAXIGP0ARVALID (gp0_arvalid), .MAXIGP0ARREADY(gp0_arready),
        .MAXIGP0RDATA   (gp0_rdata),   .MAXIGP0RID    (gp0_rid),     .MAXIGP0RRESP  (gp0_rresp),
        .MAXIGP0RLAST   (gp0_rlast),   .MAXIGP0RVALID (gp0_rvalid),  .MAXIGP0RREADY (gp0_rready),
        .SAXIHP0ACLK(fclk100), .SAXIHP0ARESETN(hp_aresetn),
        .SAXIHP0ARADDR(hp_araddr), .SAXIHP0ARID(hp_arid), .SAXIHP0ARLEN(hp_arlen),
        .SAXIHP0ARSIZE(hp_arsize[1:0]), .SAXIHP0ARBURST(hp_arburst), .SAXIHP0ARCACHE(hp_arcache),
        .SAXIHP0ARPROT(hp_arprot), .SAXIHP0ARLOCK(hp_arlock), .SAXIHP0ARQOS(hp_arqos),
        .SAXIHP0ARVALID(hp_arvalid), .SAXIHP0ARREADY(hp_arready),
        .SAXIHP0RDATA(hp_rdata), .SAXIHP0RID(hp_rid), .SAXIHP0RRESP(hp_rresp),
        .SAXIHP0RLAST(hp_rlast), .SAXIHP0RVALID(hp_rvalid), .SAXIHP0RREADY(hp_rready),
        .SAXIHP0RDISSUECAP1EN(1'b0),
        .SAXIHP0AWADDR(hp_awaddr), .SAXIHP0AWID(hp_awid), .SAXIHP0AWLEN(hp_awlen),
        .SAXIHP0AWSIZE(hp_awsize[1:0]), .SAXIHP0AWBURST(hp_awburst), .SAXIHP0AWCACHE(hp_awcache),
        .SAXIHP0AWPROT(hp_awprot), .SAXIHP0AWLOCK(hp_awlock), .SAXIHP0AWQOS(hp_awqos),
        .SAXIHP0AWVALID(hp_awvalid), .SAXIHP0AWREADY(hp_awready),
        .SAXIHP0WDATA(hp_wdata), .SAXIHP0WID(6'd0), .SAXIHP0WSTRB(hp_wstrb), .SAXIHP0WLAST(hp_wlast),
        .SAXIHP0WVALID(hp_wvalid), .SAXIHP0WREADY(hp_wready), .SAXIHP0WRISSUECAP1EN(1'b0),
        .SAXIHP0BVALID(hp_bvalid), .SAXIHP0BREADY(hp_bready),
        .SAXIHP1ACLK(fclk100), .SAXIHP1ARESETN(hp1_aresetn),
        .SAXIHP1ARADDR(hp1_araddr), .SAXIHP1ARID(hp1_arid), .SAXIHP1ARLEN(hp1_arlen),
        .SAXIHP1ARSIZE(hp1_arsize[1:0]), .SAXIHP1ARBURST(hp1_arburst), .SAXIHP1ARCACHE(hp1_arcache),
        .SAXIHP1ARPROT(hp1_arprot), .SAXIHP1ARLOCK(hp1_arlock), .SAXIHP1ARQOS(hp1_arqos),
        .SAXIHP1ARVALID(hp1_arvalid), .SAXIHP1ARREADY(hp1_arready),
        .SAXIHP1RDATA(hp1_rdata), .SAXIHP1RID(hp1_rid), .SAXIHP1RRESP(hp1_rresp),
        .SAXIHP1RLAST(hp1_rlast), .SAXIHP1RVALID(hp1_rvalid), .SAXIHP1RREADY(hp1_rready),
        .SAXIHP1RDISSUECAP1EN(1'b0),
        .SAXIHP1AWVALID(1'b0), .SAXIHP1WVALID(1'b0), .SAXIHP1BREADY(1'b0),
        .SAXIHP1WRISSUECAP1EN(1'b0),
        // ---- S_AXI_HP2 : read-only (memory-path probe today, DDR cartridge tomorrow) ----
        .SAXIHP2ACLK(fclk100), .SAXIHP2ARESETN(hp2_aresetn),
        .SAXIHP2ARADDR(hp2_araddr), .SAXIHP2ARID(hp2_arid), .SAXIHP2ARLEN(hp2_arlen),
        .SAXIHP2ARSIZE(hp2_arsize[1:0]), .SAXIHP2ARBURST(hp2_arburst), .SAXIHP2ARCACHE(hp2_arcache),
        .SAXIHP2ARPROT(hp2_arprot), .SAXIHP2ARLOCK(hp2_arlock), .SAXIHP2ARQOS(hp2_arqos),
        .SAXIHP2ARVALID(hp2_arvalid), .SAXIHP2ARREADY(hp2_arready),
        .SAXIHP2RDATA(hp2_rdata), .SAXIHP2RID(hp2_rid), .SAXIHP2RRESP(hp2_rresp),
        .SAXIHP2RLAST(hp2_rlast), .SAXIHP2RVALID(hp2_rvalid), .SAXIHP2RREADY(hp2_rready),
        .SAXIHP2RDISSUECAP1EN(1'b0),
        .SAXIHP2AWADDR(hp2_awaddr), .SAXIHP2AWID(6'd0), .SAXIHP2AWLEN(hp2_awlen),
        .SAXIHP2AWSIZE(hp2_awsize[1:0]), .SAXIHP2AWBURST(hp2_awburst), .SAXIHP2AWCACHE(hp2_awcache),
        .SAXIHP2AWPROT(hp2_awprot), .SAXIHP2AWLOCK(hp2_awlock), .SAXIHP2AWQOS(hp2_awqos),
        .SAXIHP2AWVALID(hp2_awvalid), .SAXIHP2AWREADY(hp2_awready),
        .SAXIHP2WDATA(hp2_wdata), .SAXIHP2WID(6'd0), .SAXIHP2WSTRB(hp2_wstrb),
        .SAXIHP2WLAST(hp2_wlast), .SAXIHP2WVALID(hp2_wvalid), .SAXIHP2WREADY(hp2_wready),
        .SAXIHP2BVALID(hp2_bvalid), .SAXIHP2BREADY(hp2_bready),
        .SAXIHP2WRISSUECAP1EN(1'b0)
    );

    //=============================================================================================
    // HDMI clocks: 100 -> 74.25 (pixel) + 371.25 (serial x5). VCO 742.5 (M=37.125, D=5).
    //=============================================================================================
    wire clk_pix_raw, clk_ser_raw, fb, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.000),
        .CLKFBOUT_MULT_F(37.125), .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.000),
        .CLKOUT1_DIVIDE(2)
    ) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fb), .CLKFBOUT(fb),
        .CLKOUT0(clk_pix_raw), .CLKOUT1(clk_ser_raw),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked)
    );
    wire clk_pixel, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pixel));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire hdmi_reset = ~locked;
    assign clk_pixel_o = clk_pixel;

    // 48 kHz audio clock: 74.25 MHz / 1547 = 47996 Hz
    reg [10:0] adiv = 11'd0;
    reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end
    assign clk_audio_o = clk_audio_r;

    //=============================================================================================
    // Power-on reset (aclk). Shape is parameterized to keep each top's PROVEN timing:
    // ZX legacy = a bare 4-bit counter (never waits for any lock); NES = 16-bit counter gated on
    // the machine PLL (ext_lock_i) and, with WAIT_HDMI_LOCK, on the HDMI MMCM.
    //=============================================================================================
    wire por_gate = ext_lock_i & ((WAIT_HDMI_LOCK != 0) ? locked : 1'b1);
    reg [POR_BITS-1:0] axi_por = {POR_BITS{1'b0}};
    reg aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (!por_gate)                          begin axi_por <= {POR_BITS{1'b0}}; aresetn <= 1'b0; end
        else if (axi_por != {POR_BITS{1'b1}})   begin axi_por <= axi_por + 1'b1;   aresetn <= 1'b0; end
        else                                    aresetn <= 1'b1;
    end
    assign aresetn_o = aresetn;

    // DDR masters' reset: aresetn AND the HP0 AXI slave out of reset. Coming out of reset before
    // HP0 hangs the first write forever (no b_valid) - the CE04 lesson, now impossible to re-lose.
    (* ASYNC_REG="TRUE" *) reg [1:0] hprstn_s = 2'b00;
    always @(posedge fclk100) hprstn_s <= {hprstn_s[0], hp_aresetn};
    wire core_resetn = aresetn & hprstn_s[1];
    assign core_resetn_o = core_resetn;

    //=============================================================================================
    // PS/2 keyboard: receiver + always-tap scancode FIFO + HOST TX (LEDs / typematic) + diag.
    // kclk = the decode domain: the top's clock+CE (ZX spclk/pe3M5) or internal fclk100 / 28.
    //=============================================================================================
    wire kclk = (PS2_INT_CE != 0) ? fclk100 : kclk_i;
    wire kce;
    generate if (PS2_INT_CE != 0) begin : g_kce_int
        reg [4:0] ce_div = 5'd0;
        always @(posedge kclk) ce_div <= (ce_div == 5'd27) ? 5'd0 : ce_div + 5'd1;
        assign kce = (ce_div == 5'd0);
    end else begin : g_kce_ext
        assign kce = kce_i;
    end endgenerate

    reg [1:0] ps2c_s = 2'b11, ps2d_s = 2'b11;        // 2-FF sync of the async pins
    always @(posedge kclk) begin ps2c_s <= {ps2c_s[0], ps2_clk}; ps2d_s <= {ps2d_s[0], ps2_data}; end

    wire       ps2_strb, ps2_make, ps2_perr;
    wire [7:0] ps2_code;
    ps2 ps2_i (
        .clock(kclk), .ce(kce),
        .ps2Ck(ps2c_s[1]), .ps2D(ps2d_s[1]),
        .strb(ps2_strb), .make(ps2_make), .code(ps2_code), .perr(ps2_perr)
    );
    assign ps2_strb_o = ps2_strb;
    assign ps2_make_o = ps2_make;
    assign ps2_code_o = ps2_code;

    // HOST TX: the ARM writes KBD_TX (0xB0); the strobe crosses aclk->kclk with the toggle + 3-FF
    // idiom (for kclk == fclk100 this only adds a fixed 3-cycle delay - harmless for LED commands).
    wire [7:0] ctl_kbd_tx_data;   wire ctl_kbd_tx_we;
    reg  ktx_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_kbd_tx_we) ktx_tog_a <= ~ktx_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] ktx_sync = 3'd0;
    always @(posedge kclk) ktx_sync <= {ktx_sync[1:0], ktx_tog_a};
    wire ktx_pulse = ktx_sync[2] ^ ktx_sync[1];
    (* ASYNC_REG="TRUE" *) reg [7:0] ktx_d0 = 8'd0, ktx_d1 = 8'd0;
    always @(posedge kclk) begin ktx_d0 <= ctl_kbd_tx_data; ktx_d1 <= ktx_d0; end

    wire ps2c_low, ps2d_low, ps2tx_busy, ps2tx_done, ps2tx_ack;
    // AUTO-RESEND stays DISABLED (it fired on the keyboard's power-up BAT frames after a reconfig
    // and killed the device until a power cycle); parity errors are still counted below.
    reg  resend_req = 1'b0;
    wire resend_launch = 1'b0;
    always @(posedge kclk or negedge aresetn) begin
        if (!aresetn)                             resend_req <= 1'b0;
        else if (kce && ps2_perr && ~ps2tx_busy)  resend_req <= 1'b1;
        else if (resend_launch)                   resend_req <= 1'b0;
    end
    wire       tx_start = ktx_pulse | resend_launch;
    wire [7:0] tx_byte  = ktx_pulse ? ktx_d1 : 8'hFE;
    ps2_tx #(.INHIBIT(PS2TX_INHIBIT), .TIMEOUT(PS2TX_TIMEOUT)) ps2tx_i (
        .clk(kclk), .rst_n(aresetn),
        .start(tx_start), .tx_data(tx_byte),
        .ps2c_in(ps2c_s[1]), .ps2d_in(ps2d_s[1]),
        .clk_low(ps2c_low), .data_low(ps2d_low),
        .busy(ps2tx_busy), .done(ps2tx_done), .ackok(ps2tx_ack)
    );
    assign ps2tx_busy_o = ps2tx_busy;
    assign ps2_clk  = ps2c_low ? 1'b0 : 1'bz;   // open-drain: pull low or release (board pull-up)
    assign ps2_data = ps2d_low ? 1'b0 : 1'bz;

    // CE28: ПОСЛЕДНИЙ БАЙТ-ОТВЕТ УСТРОЙСТВА в отдельном ящике. Из FIFO скан-кодов ответы теперь
    // выброшены (иначе висят «зажатой клавишей»), но прошивке они нужны: автомат команд клавиатуры
    // синхронизируется именно ими - `ED` -> `FA` -> маска -> `FA`, и без ожидания ответа устройство
    // остаётся ждать аргумент (это была старая рассинхронизация индикатора паузы). Счётчик `resend`
    // мёртв с самого начала (`resend_launch` прибит к нулю, авто-resend отключён после того, как он
    // убивал клавиатуру на BAT-кадрах), поэтому его 16 бит и занимаем - врать в диагностике нечем.
    reg [7:0] resp_last = 8'd0, resp_seq = 8'd0;
    always @(posedge kclk or negedge aresetn) begin
        if (!aresetn) begin resp_last <= 8'd0; resp_seq <= 8'd0; end
        else if (ps2_ev & ps2_rsp) begin resp_last <= ps2_code; resp_seq <= resp_seq + 8'd1; end
    end
    // diagnostics: dropped frames / recoveries, synced to aclk
    reg [15:0] perr_cnt = 16'd0, resend_cnt = 16'd0;
    always @(posedge kclk or negedge aresetn) begin
        if (!aresetn) begin perr_cnt <= 16'd0; resend_cnt <= 16'd0; end
        else begin
            if (kce && ps2_perr && ~ps2tx_busy && perr_cnt != 16'hFFFF) perr_cnt   <= perr_cnt   + 16'd1;
            if (resend_launch                    && resend_cnt != 16'hFFFF) resend_cnt <= resend_cnt + 16'd1;
        end
    end
    (* ASYNC_REG="TRUE" *) reg [31:0] diag_s0 = 32'd0, diag_s1 = 32'd0;
    // 0x13C = {счётчик ответов[31:24], последний ответ[23:16], ошибки чётности[15:0]}
    always @(posedge fclk100) begin diag_s0 <= {resp_seq, resp_last, perr_cnt}; diag_s1 <= diag_s0; end
    assign ps2_diag_o = diag_s1;
    (* ASYNC_REG="TRUE" *) reg [1:0] txbusy_s = 2'd0, txack_s = 2'd0;
    always @(posedge fclk100) begin txbusy_s <= {txbusy_s[0], ps2tx_busy}; txack_s <= {txack_s[0], ps2tx_ack}; end
    wire kbd_tx_busy_aclk = txbusy_s[1];
    wire kbd_tx_ack_aclk  = txack_s[1];

    // Always-tap scancode FIFO: every PS/2 event -> ARM. wr_en = strb & CE & ~tx_busy: exactly one
    // capture per frame, and our own TX bits are never mis-decoded as keys. Both resets = aresetn
    // (power-on only) so the FIFO survives machine resets - the ARM owns the keys.
    //
    // ==== CE28/B0065: КАДР СОБИРАЕТСЯ ЗДЕСЬ, А НЕ В ARM =========================================
    // Почему это переехало в фабрику (оплачено жалобами владельца 31.07-01.08 «клавиши залипают»,
    // «намлок то с первого, то с третьего раза», «нажатия прилетают потом»):
    //   Расширенные клавиши (стрелки!) приходят последовательностью `E0` + код, а при включённом
    //   NumLock клавиатура добавляет вокруг них ещё и «фальшивый Shift» `E0 12` - 4-6 кадров на одно
    //   нажатие. Собирать её в ARM оказалось принципиально ненадёжно: между кадрами главный цикл
    //   может встать (отрисовка, мейлбокс, модальное окно), и тогда нажатие попадает в ОДИН вариант
    //   кода, а отпускание в ДРУГОЙ - клавиша остаётся зажатой НАВСЕГДА. Приборно: 698 разрывов из
    //   1440 (48 %), в таблице зажатых висели 0x75/0xF4/0xFA при отпущенной клавиатуре.
    //   Здесь же, в домене приёмника, кадры идут подряд и разорвать их нечем: тайминги ARM больше
    //   ничего не решают. Наружу отдаём готовый кадр {ext, make, code}, ARM только читает бит.
    //   Второе: байты-ОТВЕТЫ устройства (`FA` ACK на команду лампочек, `AA` BAT, `EE`, `FE`) - это
    //   не клавиши. В set-2 make-коды заканчиваются на 0x83, поэтому ГОЛЫЙ (не после `E0`) код
    //   >= 0x84 в FIFO скан-кодов попадать не должен: раньше он ложился в таблицу зажатых и висел
    //   там вечно (за загрузку таких 11-46 штук). Хост узнаёт про ACK из KBD_TXSTAT бит1.
    //   `E1` пропускаем как раньше - на нём построен матчер клавиши Pause в ARM.
    reg ext_pend = 1'b0;
    wire ps2_ev  = ps2_strb & kce & ~ps2tx_busy;
    wire ps2_e0  = (ps2_code == 8'hE0);
    wire ps2_f0  = (ps2_code == 8'hF0);
    wire ps2_e1  = (ps2_code == 8'hE1);
    wire ps2_rsp = ~ext_pend & (ps2_code >= 8'h84) & ~ps2_e0 & ~ps2_f0 & ~ps2_e1;  // ответ протокола
    always @(posedge kclk or negedge aresetn) begin
        if (!aresetn)          ext_pend <= 1'b0;
        else if (ps2_ev) begin
            if      (ps2_e0)   ext_pend <= 1'b1;      // префикс: следующий КОД - расширенный
            else if (!ps2_f0)  ext_pend <= 1'b0;      // код (или E1) закрывает последовательность
        end                                            // F0 внутри серии флаг не трогает
    end
    // CE29/B0066: палитра пишется из ARM (0x140) - см. fb_line_disp
    wire        ctl_pal_we;  wire [7:0] ctl_pal_addr;  wire [23:0] ctl_pal_rgb;
    wire [31:0] ctl_mem_cmd;  wire ctl_mem_we;   // CE30: доступ ARM к памяти машины (0x148)
    wire [9:0] kbd_fifo_dout;
    wire       kbd_fifo_empty, kbd_fifo_rd;
    async_fifo #(.DW(10), .AW(7)) kbd_fifo_i (
        .wr_clk(kclk),  .wr_rst_n(aresetn),
        .wr_en(ps2_ev & ~ps2_e0 & ~ps2_f0 & ~ps2_rsp),   // префиксы и ответы наружу не идут
        .din({ext_pend, ps2_make, ps2_code}), .full(),
        .rd_clk(fclk100), .rd_rst_n(aresetn), .rd_en(kbd_fifo_rd),
        .dout(kbd_fifo_dout), .empty(kbd_fifo_empty), .rd_count()
    );

    //=============================================================================================
    // Video: capture (cap_clk) -> async FIFO -> AXI-HP0 write (triple buffer) -> line scanout.
    //=============================================================================================
    wire        ld_live; wire [15:0] ld_underrun; wire [15:0] ld_stale;   // B0196: приборы читателя -> 0x1C8
    assign ld_live_o = ld_live;
    (* ASYNC_REG="TRUE" *) reg [1:0] capen_s = 2'b00;
    always @(posedge cap_clk_i or negedge cap_rstn_i) begin
        if (!cap_rstn_i) capen_s <= 2'b00;
        else             capen_s <= {capen_s[0], ld_live};
    end
    wire cap_en = capen_s[1];

    wire cap_wr; wire [63:0] cap_din;
    wire [31:0] cap_geom_sp;
    fb_capture_rr #(.FB_W(CAP_W), .FB_H(CAP_H), .BPP(CAP_BPP), .LEADIN_AUTO(CAP_LEADIN_AUTO)) capz (
        .wr_clk(cap_clk_i), .resetn(cap_rstn_i), .wr_ce(cap_ce_i),
        .hsync(cap_hsync_i), .vsync(cap_vsync_i), .blank(cap_blank_i),
        .r(cap_r_i), .g(cap_g_i), .b(cap_b_i), .i(cap_i_i), .pix8(cap_pix8_i), .enable(cap_en),
        .fifo_wr(cap_wr), .fifo_din(cap_din), .cap_geom(cap_geom_sp)
    );
    // cap_geom is a multi-bit bus crossing cap_clk->aclk; 3-FF + settle-latch (the osd_pos idiom).
    reg [31:0] cap_geom_s1=32'd0, cap_geom_s2=32'd0, cap_geom_s3=32'd0, cap_geom_f=32'd0;
    always @(posedge fclk100) begin
        cap_geom_s1<=cap_geom_sp; cap_geom_s2<=cap_geom_s1; cap_geom_s3<=cap_geom_s2;
        if (cap_geom_s2==cap_geom_s3) cap_geom_f<=cap_geom_s2;
    end

    wire fifo_empty, fifo_full, fifo_rd; wire [63:0] fifo_dout;
    async_fifo #(.DW(64), .AW(6)) ddrfifo (
        .wr_clk(cap_clk_i), .wr_rst_n(cap_rstn_i), .wr_en(cap_wr), .din(cap_din), .full(fifo_full),
        .rd_clk(fclk100), .rd_rst_n(core_resetn), .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .rd_count()
    );
    // sticky diagnostic: capture attempted a write while the FIFO was full (the CE13 class)
    reg fifo_overflow = 1'b0;
    always @(posedge cap_clk_i or negedge cap_rstn_i) begin
        if (!cap_rstn_i)               fifo_overflow <= 1'b0;
        else if (cap_wr && fifo_full)  fifo_overflow <= 1'b1;
    end
    (* ASYNC_REG="TRUE" *) reg [1:0] fifo_ov_s = 2'b00;
    always @(posedge fclk100) fifo_ov_s <= {fifo_ov_s[0], fifo_overflow};
    assign cap_fifo_ov_o = fifo_ov_s[1];

    // frame_kick: the buffer-swap tick. ZX style = HDMI vblank; NES style = the core's own vsync.
    wire [10:0] cx, cy;
    wire frame_kick;
    generate if (KICK_CORE_VSYNC != 0) begin : g_kick_core
        (* ASYNC_REG="TRUE" *) reg [2:0] vbl_s = 3'd0;
        always @(posedge fclk100) vbl_s <= {vbl_s[1:0], cap_vsync_i};
        assign frame_kick = vbl_s[2] ^ vbl_s[1];
    end else begin : g_kick_hdmi
        reg vbl_tog = 1'b0, cy_in_vbl_d = 1'b0;
        wire cy_in_vbl = (cy >= 11'd720);
        always @(posedge clk_pixel) begin
            cy_in_vbl_d <= cy_in_vbl;
            if (cy_in_vbl & ~cy_in_vbl_d) vbl_tog <= ~vbl_tog;
        end
        (* ASYNC_REG="TRUE" *) reg [2:0] vbl_s = 3'b000;
        always @(posedge fclk100) vbl_s <= {vbl_s[1:0], vbl_tog};
        assign frame_kick = vbl_s[2] ^ vbl_s[1];
    end endgenerate
    reg frame_kick_d = 1'b0;
    always @(posedge fclk100) frame_kick_d <= frame_kick;

    wire ctl_quiesce;
    wire wr_idle, disp_idle, osd_idle;
    // ОБЪЯВЛЕНО ЗДЕСЬ, а не у мастера памяти ниже: в этом файле нет `default_nettype none`,
    // и использование до объявления молча создаёт новый однобитный провод.
    wire mem_idle;
    // Мастер памяти машины ОБЯЗАН входить в условие простоя. Пока к нему ходил только стенд ARM
    // (а его QUIESCE и так блокирует), это ничего не стоило; теперь по нему идёт память Пентагона,
    // и сброс PL с полуоткрытым бёрстом лечится только холодным стартом.
    wire axi_idle_all = wr_idle & disp_idle & osd_idle & mem_idle & mach_axi_idle_i;
    assign ctl_quiesce_o = ctl_quiesce;

    wire wr_done; wire [31:0] wr_base, disp_base, prev_base; wire prev_ok;
    // B0198: пять буферов вместо трёх - выводу нужна пара СОСЕДНИХ кадров машины (N, N-1) для смешения.
    // disp_base ведёт себя ровно как у fb_bufmgr3, поэтому без смешения вывод прежний.
    fb_bufmgr5 ddrbuf (
        .clk(fclk100), .resetn(core_resetn),
        .frame_done(wr_done), .frame_kick(frame_kick),
        .wr_base(wr_base), .disp_base(disp_base), .prev_base(prev_base), .prev_ok(prev_ok),
        .wr_buf_o(), .disp_buf_o(), .prev_buf_o()
    );

    /* 🥇 B0198 СМЕШЕНИЕ КАДРОВ: режим и автомат AUTO. Всё на fclk100 = домен читателя строк.
       AUTO включает смешение, когда машина переключает экран через кадр: так рисуются тени и
       gigascreen, которые на ЭЛТ сливаются, а на ЖК мерцают с 25 Гц. Признак один и тот же на оба
       конца: в окне последних 8 кадров не меньше 6 переключений. Отдельных условий «включить» и
       «выключить» нет намеренно (урок SHOCK.TAP: у латча с разными предикатами побеждает грубый). */
    wire [1:0] ctl_blend;
    (* ASYNC_REG="TRUE" *) reg [2:0] bsel_s = 3'd0, bvs_s = 3'd0;
    reg        bsel_last = 1'b0;
    reg [7:0]  bhist = 8'd0;
    always @(posedge fclk100) begin
        bsel_s <= {bsel_s[1:0], scr_sel_i};
        bvs_s  <= {bvs_s[1:0],  cap_vsync_i};
        if (bvs_s[2:1] == 2'b01) begin                  // фронт кадрового синхроимпульса машины
            bhist     <= {bhist[6:0], (bsel_s[2] != bsel_last)};
            bsel_last <= bsel_s[2];
        end
    end
    wire [3:0] bcnt = bhist[0]+bhist[1]+bhist[2]+bhist[3]+bhist[4]+bhist[5]+bhist[6]+bhist[7];
    reg        blend_auto = 1'b0, blend_en = 1'b0;
    always @(posedge fclk100) begin
        blend_auto <= (bcnt >= 4'd6);
        blend_en   <= (ctl_blend == 2'd2) | ((ctl_blend == 2'd1) & blend_auto);
    end
    wire [31:0] blend_stat = {16'd0, bhist, 5'd0, blend_en, ctl_blend};
    fb_wr_axi #(.WORDS(WR_WORDS)) ddrwr (
        .clk(fclk100), .resetn(core_resetn), .base(wr_base),
        .fifo_empty(fifo_empty), .fifo_dout(fifo_dout), .fifo_rd(fifo_rd),
        .aw_addr(hp_awaddr), .aw_id(hp_awid), .aw_len(hp_awlen), .aw_size(hp_awsize),
        .aw_burst(hp_awburst), .aw_cache(hp_awcache), .aw_prot(hp_awprot),
        .aw_lock(hp_awlock), .aw_qos(hp_awqos), .aw_valid(hp_awvalid), .aw_ready(hp_awready),
        .w_data(hp_wdata), .w_strb(hp_wstrb), .w_last(hp_wlast), .w_valid(hp_wvalid), .w_ready(hp_wready),
        .b_valid(hp_bvalid), .b_ready(hp_bready),
        .frame_done(wr_done), .busy_o(), .quiesce_i(ctl_quiesce), .idle_o(wr_idle)
    );
    // the classic hpw liveness counter, for any machine's debug register
    reg [15:0] hpw = 16'd0;
    always @(posedge fclk100) if (hp_awvalid & hp_awready) hpw <= hpw + 16'd1;
    assign wr_accept_cnt_o = hpw;

    // live scanout window: either the CROP registers (ZX) or the fixed full frame
    wire [31:0] ctl_scr_pos, ctl_scr_scale, ctl_crop_a, ctl_crop_b;
    wire [11:0] disp_sx0, disp_sy0, disp_cw, disp_ch;
    generate if (LIVE_CROP != 0) begin : g_crop_live
        assign disp_sx0 = ctl_crop_a[11:0];
        assign disp_sy0 = ctl_crop_a[27:16];
        assign disp_cw  = ctl_crop_b[11:0];
        assign disp_ch  = ctl_crop_b[27:16];
    end else begin : g_crop_fixed
        assign disp_sx0 = 12'd0;
        assign disp_sy0 = 12'd0;
        assign disp_cw  = CROP_W[11:0];
        assign disp_ch  = CROP_H[11:0];
    end endgenerate

    wire [23:0] rgb24;
    fb_line_disp #(
        .SRC_W(SRC_W), .STRIDE(STRIDE), .CROP_W(CROP_W), .HMARGIN(HMARGIN), .SX0(SX0),
        .CROP_H(CROP_H), .VMARGIN(VMARGIN),
        .SRC_BPP(SRC_BPP), .WSH(WSH), .LBPP(LBPP), .FBURSTS(FBURSTS)
    ) ddrdisp (
        .pal_wclk(fclk100), .pal_we(ctl_pal_we), .pal_addr(ctl_pal_addr), .pal_rgb(ctl_pal_rgb),
        .clk(fclk100), .resetn(core_resetn),
        .disp_base(disp_base), .prev_base(prev_base), .prev_ok(prev_ok), .blend_en(blend_en),   // B0198
        .frame_kick(frame_kick_d), .quiesce_i(ctl_quiesce), .idle_o(disp_idle),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .hmargin_a(ctl_scr_pos[11:0]), .vmargin_a(ctl_scr_pos[27:16]),
        .xmul_a(ctl_scr_scale[3:0]), .ymul_a(ctl_scr_scale[7:4]),
        .sx0_a(disp_sx0), .sy0_a(disp_sy0), .cropw_a(disp_cw), .croph_a(disp_ch),
        .rgb(rgb24), .live(ld_live), .underrun_cnt(ld_underrun), .stale_base_cnt(ld_stale)
    );

    //=============================================================================================
    // OSD layers: 1bpp toast -> DDR true-colour canvas (HP1) -> independent banner. Pipelined.
    //=============================================================================================
    wire        ctl_osd_enable, ctl_osd_we, ctl_ddr_osd_en;
    wire [9:0]  ctl_osd_waddr;
    wire [31:0] ctl_osd_wdata;
    wire [23:0] ctl_osd_bg;
    wire [7:0]  ctl_osd_op;
    wire [31:0] ctl_osd_pos, ctl_osd_ddr_base, ctl_ddr_osd_pos;
    wire        ctl_ban_enable, ctl_ban_we;
    wire [8:0]  ctl_ban_waddr;
    wire [31:0] ctl_ban_wdata, ctl_ban_pos;
    assign ctl_osd_enable_o = ctl_osd_enable;
    assign ctl_ddr_osd_en_o = ctl_ddr_osd_en;

    wire [23:0] rgb24_osd;
    osd_compositor osd_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .osd_enable_a(ctl_osd_enable), .osd_we(ctl_osd_we),
        .osd_waddr(ctl_osd_waddr), .osd_wdata(ctl_osd_wdata), .osd_bg_a(ctl_osd_bg), .osd_op_a(ctl_osd_op), .osd_pos_a(ctl_osd_pos),
        .cx(cx), .cy(cy), .rgb_in(rgb24), .rgb_out(rgb24_osd)
    );

    reg [31:0] odpos_s1=32'd0, odpos_s2=32'd0, odpos_s3=32'd0, odpos_q=32'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] oden_s = 2'b00;
    always @(posedge clk_pixel) begin
        odpos_s1<=ctl_ddr_osd_pos; odpos_s2<=odpos_s1; odpos_s3<=odpos_s2;
        if (odpos_s2==odpos_s3) odpos_q<=odpos_s2;
        oden_s <= {oden_s[0], ctl_ddr_osd_en};
    end
    wire [23:0] osd_ddr_rgb; wire [7:0] osd_ddr_a; wire osd_ddr_active;
    osd_ddr_rd #(.CW(640), .CH(400)) osddr (
        .quiesce_i(ctl_quiesce), .idle_o(osd_idle),
        .clk(fclk100), .resetn(core_resetn), .osd_base(ctl_osd_ddr_base), .frame_kick(frame_kick_d),
        .ar_addr(hp1_araddr), .ar_id(hp1_arid), .ar_len(hp1_arlen), .ar_size(hp1_arsize),
        .ar_burst(hp1_arburst), .ar_cache(hp1_arcache), .ar_prot(hp1_arprot),
        .ar_lock(hp1_arlock), .ar_qos(hp1_arqos), .ar_valid(hp1_arvalid), .ar_ready(hp1_arready),
        .r_data(hp1_rdata), .r_last(hp1_rlast), .r_valid(hp1_rvalid), .r_ready(hp1_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .x0(odpos_q[10:0]), .y0(odpos_q[26:16]), .en(oden_s[1]),
        .osd_rgb(osd_ddr_rgb), .osd_a(osd_ddr_a), .osd_active(osd_ddr_active)
    );

    // pipeline stages (the Step-15 timing fix: one combinational cone -> staged blend)
    reg [10:0] cx_d1 = 11'd0, cx_d2 = 11'd0, cy_d1 = 11'd0, cy_d2 = 11'd0;
    always @(posedge clk_pixel) begin cx_d1<=cx; cx_d2<=cx_d1; cy_d1<=cy; cy_d2<=cy_d1; end

    reg [23:0] rgb24_osd_q = 24'd0;
    always @(posedge clk_pixel) rgb24_osd_q <= rgb24_osd;

    reg        od_act_d1 = 1'b0; reg [7:0] od_a_d1 = 8'd0; reg [23:0] od_rgb_d1 = 24'd0;
    always @(posedge clk_pixel) begin
        od_act_d1 <= osd_ddr_active; od_a_d1 <= osd_ddr_a; od_rgb_d1 <= osd_ddr_rgb;
    end

    // 🥇 B0123 то же тождество, что и в osd_compositor: одно умножение на канал вместо двух,
    // результат бит-в-бит прежний (bg*a + video*(255-a) == video*255 + a*(bg-video)).
    wire signed [9:0]  odv_r = $signed({2'b00, od_rgb_d1[23:16]}) - $signed({2'b00, rgb24_osd_q[23:16]});
    wire signed [9:0]  odv_g = $signed({2'b00, od_rgb_d1[15:8] }) - $signed({2'b00, rgb24_osd_q[15:8] });
    wire signed [9:0]  odv_b = $signed({2'b00, od_rgb_d1[7:0]  }) - $signed({2'b00, rgb24_osd_q[7:0]  });
    wire signed [18:0] odp_r = odv_r * $signed({1'b0, od_a_d1});
    wire signed [18:0] odp_g = odv_g * $signed({1'b0, od_a_d1});
    wire signed [18:0] odp_b = odv_b * $signed({1'b0, od_a_d1});
    wire [15:0] od_r = {rgb24_osd_q[23:16], 8'd0} - {8'd0, rgb24_osd_q[23:16]} + odp_r[15:0];
    wire [15:0] od_g = {rgb24_osd_q[15:8],  8'd0} - {8'd0, rgb24_osd_q[15:8] } + odp_g[15:0];
    wire [15:0] od_b = {rgb24_osd_q[7:0],   8'd0} - {8'd0, rgb24_osd_q[7:0]  } + odp_b[15:0];
    reg [23:0] rgb24_ddr_q = 24'd0;
    always @(posedge clk_pixel)
        rgb24_ddr_q <= od_act_d1 ? { od_r[15:8], od_g[15:8], od_b[15:8] } : rgb24_osd_q;

    wire [23:0] rgb24_ovl;
    banner_compositor banner_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .ban_enable_a(ctl_ban_enable), .ban_we(ctl_ban_we),
        .ban_waddr(ctl_ban_waddr), .ban_wdata(ctl_ban_wdata), .ban_pos_a(ctl_ban_pos),
        .cx(cx_d2), .cy(cy_d2), .rgb_in(rgb24_ddr_q), .rgb_out(rgb24_ovl)
    );

    // BDI floppy activity icon: bottom-right of the HDMI frame, outside the machine window.
    // Driven from FDC_STAT (busy/DRQ/sd_rd/sd_wr/sd_ack). NES has fdc_stat=0 → always off.
    wire [23:0] rgb24_bdi;
    bdi_activity_icon bdi_icon_i (
        .clk_pixel(clk_pixel),
        .aclk     (fclk100),
        .fdc_stat_a(fdc_stat_i),
        .cx       (cx_d2),
        .cy       (cy_d2),
        .rgb_in   (rgb24_ovl),
        .rgb_out  (rgb24_bdi)
    );

    //=============================================================================================
    // ARM music player leg + master volume. The MACHINE mix stays in the top (each machine
    // conditions and crossfades its own PCM using player_pcm_o/player_gain_o/machine_gain_o);
    // the pre-volume result comes back on aud_src_l_i/aud_src_r_i.
    //=============================================================================================
    wire        ctl_player_en, ctl_audio_we, ctl_aud_sum;
    wire [31:0] ctl_audio_data;
    wire        aud_full, aud_empty;
    wire [7:0]  aud_rdcount;
    wire [7:0]  ctl_vol;

    (* ASYNC_REG = "TRUE" *) reg [1:0] pen_s = 2'b00;
    always @(posedge clk_audio_r) pen_s <= {pen_s[0], ctl_player_en};
    wire [31:0] aud_dout;
    wire player_live = pen_s[1] & ~aud_empty;
    async_fifo #(.DW(32), .AW(8)) audio_fifo (
        .wr_clk(fclk100),    .wr_rst_n(aresetn), .wr_en(ctl_audio_we), .din(ctl_audio_data), .full(aud_full),
        .rd_clk(clk_audio_r), .rd_rst_n(aresetn), .rd_en(player_live),
        .dout(aud_dout), .empty(aud_empty), .rd_count(aud_rdcount)
    );
    reg [31:0] aud_hold = 32'd0;
    always @(posedge clk_audio_r) if (player_live) aud_hold <= aud_dout;
    wire [31:0] player_pcm = player_live ? aud_dout : aud_hold;
    reg  [8:0] pgain = 9'd0;
    wire [8:0] ptgt = pen_s[1] ? 9'd256 : 9'd0;
    always @(posedge clk_audio_r)
        if (pgain < ptgt) pgain <= pgain + 9'd1; else if (pgain > ptgt) pgain <= pgain - 9'd1;
    /* B0107 СУММИРОВАНИЕ ВМЕСТО СКРЕЩИВАНИЯ. Кроссфейд (mgn = 256 - pgain) сделан под музыкальный
       проигрыватель, который машину ЗАМЕНЯЕТ. General Sound - это довесок К машине (звуковая карта
       в слоте): его выход обязан СКЛАДЫВАТЬСЯ с AY, иначе включение GS глушит машину. Бит режима
       приходит из домена оболочки - синхронизируем, как pen_s (никакого несинхронизированного
       управления в звуковой домен). */
    (* ASYNC_REG = "TRUE" *) reg [1:0] asum_s = 2'b00;
    always @(posedge clk_audio_r) asum_s <= {asum_s[0], ctl_aud_sum};
    wire [8:0] mgn = asum_s[1] ? 9'd256 : (9'd256 - pgain);
    assign player_pcm_o   = player_pcm;
    assign player_gain_o  = pgain;
    assign machine_gain_o = mgn;

    /* B0107 ПИК-МЕТР ARM-НОГИ (0x17C). Пики 0x170 наполняет МАШИНА, а General Sound живёт на ARM и
       ни в один машинный слот не попадает. Правило владельца - «не объявлять музыку рабочей без
       положительного отсчёта» - без своего прибора невыполнимо. Мерим ДВЕ точки: то, что пришло от
       ARM (доказывает, что сэмплы дошли до фабрики), и итоговый предобъёмный микс (виден клиппинг
       после суммирования). Окно ~85 мс, как у 0x170. Берём max(|L|,|R|): у GS каналы 1-2 идут в
       левый, 3-4 в правый, и модуль может звучать только одним. */
/* Прибор МЕРИМ ДЁШЕВО: ЛОГИКА ЗДЕСЬ СТОИТ ТАЙМИНГА. Точное |v| потребовало бы четырёх
       16-битных сумматоров, и B0108 из-за такой мелочи провалил пиксельный домен (WNS -0.223).
       Для пик-метра хватает СТАРШЕГО БАЙТА и обратного кода вместо дополнительного: ошибка в
       один младший разряд старшего байта на слух и на глаз не значит ничего, а цена - восемь
       инверторов вместо сумматора. Отсчёт 0..127 = полная шкала. */
    function [7:0] pk_mag8(input [15:0] v); pk_mag8 = v[15] ? ~v[15:8] : v[15:8]; endfunction
    wire [7:0] pk_pl = pk_mag8(player_pcm[15:0]);
    wire [7:0] pk_pr = pk_mag8(player_pcm[31:16]);
    wire [7:0] pk_ml = pk_mag8(aud_src_l_i);
    wire [7:0] pk_mr = pk_mag8(aud_src_r_i);
    wire [7:0] pk_pmax = (pk_pl > pk_pr) ? pk_pl : pk_pr;
    wire [7:0] pk_mmax = (pk_ml > pk_mr) ? pk_ml : pk_mr;
    reg  [7:0]  pk_run_p = 8'd0, pk_run_m = 8'd0, pk_hold_p = 8'd0, pk_hold_m = 8'd0;
    reg  [11:0] pk_win = 12'd0;
    always @(posedge clk_audio_r) begin
        if (pk_pmax > pk_run_p) pk_run_p <= pk_pmax;
        if (pk_mmax > pk_run_m) pk_run_m <= pk_mmax;
        pk_win <= pk_win + 12'd1;
        if (pk_win == 12'd0) begin
            pk_hold_p <= pk_run_p; pk_run_p <= 8'd0;
            pk_hold_m <= pk_run_m; pk_run_m <= 8'd0;
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [31:0] pk_s0 = 32'd0, pk_s1 = 32'd0;
    always @(posedge fclk100) begin pk_s0 <= {8'd0, pk_hold_p, 8'd0, pk_hold_m}; pk_s1 <= pk_s0; end

    // master volume (F9 menu): slewed gain, full-width product (the truncation lesson)
    reg  [7:0] vol_c0 = 8'd255, vol_c1 = 8'd255;
    reg  [7:0] vgain  = 8'd255;
    always @(posedge clk_audio_r) begin
        vol_c0 <= ctl_vol; vol_c1 <= vol_c0;
        if      (vgain < vol_c1) vgain <= vgain + 8'd1;
        else if (vgain > vol_c1) vgain <= vgain - 8'd1;
    end
    wire signed [24:0] lprod = $signed(aud_src_l_i) * $signed({1'b0, vgain});
    wire signed [24:0] rprod = $signed(aud_src_r_i) * $signed({1'b0, vgain});
    reg signed [15:0] left16_v, right16_v;
    always @(posedge clk_audio_r) begin
        left16_v  <= lprod >>> 8;
        right16_v <= rprod >>> 8;
    end

    // optional post-volume DC blocker (the ZX signed-arithmetic HPF, fc ~30 Hz)
    wire [15:0] audio_left_f, audio_right_f;
    generate if (AUDIO_DC_BLOCK != 0) begin : g_dcb
        reg signed [15:0] dcb_lx = 16'sd0, dcb_rx = 16'sd0;
        reg signed [19:0] dcb_ly = 20'sd0, dcb_ry = 20'sd0;
        wire signed [19:0] dcb_xl  = { {4{left16_v[15]}},  left16_v  };
        wire signed [19:0] dcb_xr  = { {4{right16_v[15]}}, right16_v };
        wire signed [19:0] dcb_xl1 = { {4{dcb_lx[15]}}, dcb_lx };
        wire signed [19:0] dcb_xr1 = { {4{dcb_rx[15]}}, dcb_rx };
        wire signed [19:0] dcb_lyn = dcb_xl - dcb_xl1 + dcb_ly - (dcb_ly >>> 8);
        wire signed [19:0] dcb_ryn = dcb_xr - dcb_xr1 + dcb_ry - (dcb_ry >>> 8);
        always @(posedge clk_audio_r) begin
            dcb_lx <= left16_v;  dcb_ly <= dcb_lyn;
            dcb_rx <= right16_v; dcb_ry <= dcb_ryn;
        end
        wire signed [15:0] dcb_l16 = (dcb_ly > 20'sd32767) ? 16'sd32767 : (dcb_ly < -20'sd32768) ? -16'sd32768 : dcb_ly[15:0];
        wire signed [15:0] dcb_r16 = (dcb_ry > 20'sd32767) ? 16'sd32767 : (dcb_ry < -20'sd32768) ? -16'sd32768 : dcb_ry[15:0];
        assign audio_left_f  = dcb_l16;
        assign audio_right_f = dcb_r16;
    end else begin : g_nodcb
        assign audio_left_f  = left16_v;
        assign audio_right_f = right16_v;
    end endgenerate
    // (a future hardware DAC taps audio_left_f/audio_right_f here - same PCM as HDMI)

    //=============================================================================================
    // HDMI 1.4 (720p50) + OBUFDS.
    //=============================================================================================
    wire [2:0] tmds;
    wire       tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser),
        .clk_pixel   (clk_pixel),
        .clk_audio   (clk_audio_r),
        .reset       (hdmi_reset),
        .rgb         (rgb24_bdi),
        .audio_left  (audio_left_f),
        .audio_right (audio_right_f),
        .tmds        (tmds),
        .tmds_clock  (tmds_clock),
        .cx          (cx),
        .cy          (cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi = 0; gi < 3; gi = gi + 1) begin : tb
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    reg [25:0] hb = 26'd0;
    always @(posedge clk_pixel) hb <= hb + 26'd1;
    assign led_heart = hb[24];

    //=============================================================================================
    // Memory-path probe on HP2 (ddr_probe.v). Measures first-word read latency and sustained throughput
    // for DDR and for the PS OCM over the SAME port, with the video chain running or idle - the numbers
    // that dimension the DDR cartridge instead of guessing them. Machine-agnostic by nature: it is a
    // property of the board's memory path, not of any machine, so it belongs to the shell.
    //=============================================================================================
    wire [31:0] ctl_probe_base, ctl_probe_ctrl;
    wire        ctl_probe_start, probe_busy;
    wire [31:0] probe_lat_min, probe_lat_max, probe_lat_sum, probe_cycles, probe_beats, probe_stat_w;
    // ОБЪЯВЛЕНИЯ ДО ИСПОЛЬЗОВАНИЯ. Стояли ниже generate - Verilog молча создал однобитные неявные
    // провода, и синтез упал на индексации. Дешёвый урок: в этом файле нет `default_nettype none`,
    // поэтому опечатка в имени провода тут не ошибка, а новый однобитный сигнал.
    wire [15:0] mem_wait_cnt, mem_xact_cnt;
    wire [31:0] mem_stat;
    wire [7:0]  mem_arm_rdata;  wire mem_arm_busy;  wire [15:0] mem_arm_drop;
    generate if (DDR_PROBE != 0) begin : g_probe
        ddr_probe probe_i (
            .clk(fclk100), .resetn(core_resetn),
            .cfg_base(ctl_probe_base), .cfg_ctrl(ctl_probe_ctrl), .start(ctl_probe_start), .busy(probe_busy),
            .res_lat_min(probe_lat_min), .res_lat_max(probe_lat_max), .res_lat_sum(probe_lat_sum),
            .res_cycles(probe_cycles), .res_beats(probe_beats), .res_status(probe_stat_w),
            .ar_addr(hp2_araddr), .ar_id(hp2_arid), .ar_len(hp2_arlen), .ar_size(hp2_arsize),
            .ar_burst(hp2_arburst), .ar_cache(hp2_arcache), .ar_prot(hp2_arprot),
            .ar_lock(hp2_arlock), .ar_qos(hp2_arqos), .ar_valid(hp2_arvalid), .ar_ready(hp2_arready),
            .r_data(hp2_rdata), .r_last(hp2_rlast), .r_valid(hp2_rvalid), .r_ready(hp2_rready)
        );
        assign hp2_awvalid = 1'b0; assign hp2_wvalid = 1'b0; assign hp2_bready = 1'b0;
        assign hp2_awaddr = 32'd0; assign hp2_awlen = 4'd0; assign hp2_awsize = 3'd0;
        assign hp2_awburst = 2'd0; assign hp2_awcache = 4'd0; assign hp2_awprot = 3'd0;
        assign hp2_awlock = 2'd0;  assign hp2_awqos = 4'd0;
        assign hp2_wdata = 64'd0;  assign hp2_wstrb = 8'd0; assign hp2_wlast = 1'b0;
        assign mem_rdata_o = 8'd0; assign mem_wait_o = 1'b0; assign mem_stat = 32'd0;
        assign mem_arm_rdata = 8'd0; assign mem_arm_busy = 1'b0; assign mem_arm_drop = 16'd0;
        assign mem_idle = 1'b1;   // мастера нет - он всегда простаивает (иначе QUIESCE ждал бы X)
    end else begin : g_mem
        // ПАМЯТЬ МАШИНЫ. Запрос идёт либо от машины (её такт), либо от ARM через регистр 0x148 -
        // второй путь нужен и как испытательный стенд (доказать целостность данных до того, как
        // трогать память машины), и потом как загрузчик образов прямо в память.
        ddr_mem #(.BASE(MEM_BASE), .ADDR_W(MEM_ADDR_W)) mem_i (
            .aclk(fclk100), .aresetn(aresetn),
            .aw_addr(hp2_awaddr), .aw_len(hp2_awlen), .aw_size(hp2_awsize), .aw_burst(hp2_awburst),
            .aw_cache(hp2_awcache), .aw_prot(hp2_awprot), .aw_lock(hp2_awlock), .aw_qos(hp2_awqos),
            .aw_valid(hp2_awvalid), .aw_ready(hp2_awready),
            .w_data(hp2_wdata), .w_strb(hp2_wstrb), .w_last(hp2_wlast),
            .w_valid(hp2_wvalid), .w_ready(hp2_wready),
            .b_valid(hp2_bvalid), .b_ready(hp2_bready),
            .ar_addr(hp2_araddr), .ar_len(hp2_arlen), .ar_size(hp2_arsize), .ar_burst(hp2_arburst),
            .ar_cache(hp2_arcache), .ar_prot(hp2_arprot), .ar_lock(hp2_arlock), .ar_qos(hp2_arqos),
            .ar_valid(hp2_arvalid), .ar_ready(hp2_arready),
            .r_data(hp2_rdata), .r_last(hp2_rlast), .r_valid(hp2_rvalid), .r_ready(hp2_rready),
            .mclk(mem_mclk_i),
            .maddr(mem_addr_i), .mwdata(mem_wdata_i),
            .mrd(mem_rd_i), .mwr(mem_wr_i),
            .mrdata(mem_rdata_o), .mwait(mem_wait_o),
            // ARM ходит своим портом в домене aclk: однотактовый импульс через границу домена
            // терялся (первое испытание: из 64 запросов дошли 42), а CDC ему и не нужен.
            .arm_req(ctl_mem_we), .arm_iswr(ctl_mem_cmd[31]),
            .arm_addr(ctl_mem_cmd[27:8]), .arm_wdata(ctl_mem_cmd[7:0]),
            .arm_rdata(mem_arm_rdata), .arm_busy(mem_arm_busy), .arm_drop(mem_arm_drop),
            .quiesce_i(ctl_quiesce), .idle_o(mem_idle),
            .wait_cnt(mem_wait_cnt), .xact_cnt(mem_xact_cnt)
        );
        // 0x14C: [31:16] транзакций, [15:8] отброшено ARM-запросов, [9] занято, [8] простой машины,
        //        [7:0] последний байт, прочитанный ARM-ом
        // B0074: было 16+8+1+1+8 = 34 бита в 32-битном проводе - Verilog молча срезал СТАРШИЕ два,
        // и все поля читались со сдвигом на 2 (я сам на этом ошибся при разборе отказа памяти:
        // «38616 транзакций, 0 отброшено» было неверной расшифровкой). Теперь ширина честная:
        // [31:18] транзакций (14 бит, по модулю 16384), [17:10] отброшено ARM-запросов,
        // [9] занято, [8] ожидание процессора, [7:0] последний прочитанный ARM-ом байт.
        assign mem_stat = {mem_xact_cnt[13:0], mem_arm_drop[7:0], mem_arm_busy, mem_wait_o, mem_arm_rdata[7:0]};
    end endgenerate
    wire [31:0] probe_stat = {probe_stat_w[31:16], probe_stat_w[15], probe_busy, probe_stat_w[13:0]};

    //=============================================================================================
    // axi_ctl: the AXI3 register file. Shared subsystems are wired INTERNALLY (they can no longer
    // be tied off by a top); machine registers pass straight through the module's ports.
    //=============================================================================================
    (* ASYNC_REG="TRUE" *) reg [31:0] mach_dbg_s0 = 32'd0, mach_dbg_s1 = 32'd0;
    always @(posedge fclk100) begin mach_dbg_s0 <= mach_dbg_i; mach_dbg_s1 <= mach_dbg_s0; end
    /* B0147: тот же приём для прибора трапа - слово медленное (счётчики и адрес меняются раз в
       тысячи тактов), читается только человеком через JTAG, поэтому двух триггеров достаточно и
       разъехавшиеся байты никого не обманут: правило «синхронизировать только флаг» здесь не нужно,
       флага у этого слова нет вовсе. */
    (* ASYNC_REG="TRUE" *) reg [31:0] rom_dbg_s0 = 32'd0, rom_dbg_s1 = 32'd0;
    always @(posedge fclk100) begin rom_dbg_s0 <= rom_dbg_i; rom_dbg_s1 <= rom_dbg_s0; end
    (* ASYNC_REG="TRUE" *) reg [31:0] aud_dbg_s0 = 32'd0, aud_dbg_s1 = 32'd0;
    always @(posedge fclk100) begin aud_dbg_s0 <= aud_dbg_i; aud_dbg_s1 <= aud_dbg_s0; end

    axi_ctl #(.VERSION(VERSION), .MACHINE_ID(MACHINE_ID), .LOAD_CAPS(LOAD_CAPS_P)) ctl (
        .aclk(fclk100), .aresetn(aresetn),
        .s_awid(gp0_awid), .s_awaddr(gp0_awaddr), .s_awlen(gp0_awlen),
        .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
        .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
        .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
        .s_bid(gp0_bid), .s_bresp(gp0_bresp), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
        .s_arid(gp0_arid), .s_araddr(gp0_araddr), .s_arlen(gp0_arlen),
        .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
        .s_rid(gp0_rid), .s_rdata(gp0_rdata), .s_rresp(gp0_rresp),
        .s_rlast(gp0_rlast), .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
`ifdef NES_CORE
        .ctl_nes_mapper(ctl_nes_mapper_o), .ctl_nes_ld_addr(ctl_nes_ld_addr_o), .ctl_nes_ld_data(ctl_nes_ld_data_o),
        .ctl_nes_ld_we(ctl_nes_ld_we_o), .ctl_nes_ld_sel(ctl_nes_ld_sel_o), .ctl_nes_loading(ctl_nes_loading_o), .ctl_nes_reset(ctl_nes_reset_o),
`endif
        .ctl_fdc_ctl(ctl_fdc_ctl_o), .ctl_fdc_ctl_we(ctl_fdc_ctl_we_o),             // B0075: дисковод
        .ctl_fdc_data(ctl_fdc_data_o), .ctl_fdc_data_we(ctl_fdc_data_we_o), .fdc_stat_in(fdc_stat_i),
        .gs_stat_in(gs_stat_i), .ctl_gs_ctl(ctl_gs_ctl_o), .ctl_gs_ctl_we(ctl_gs_ctl_we_o),   // General Sound
        .gs_stat2_in(gs_stat2_i), .gs_stat3_in(gs_stat3_i),   // B0119: прибор обратного давления
        .fdc_stat2_in(fdc_stat2_i),
        .ctl_rom_ld_addr(ctl_rom_ld_addr_o), .ctl_rom_ld_data(ctl_rom_ld_data_o),   // B0071: заливка ПЗУ
        .ctl_rom_ld_we(ctl_rom_ld_we_o), .ctl_rom_loading(ctl_rom_loading_o),
        .ctl_halt(ctl_halt_o), .ctl_ram_we(ctl_ram_we_o),
        .ctl_ram_addr(ctl_ram_addr_o), .ctl_ram_waddr(ctl_ram_waddr_o), .ctl_ram_data(ctl_ram_data_o),
        .ctl_dir(ctl_dir_o), .ctl_7ffd(ctl_7ffd_o), .ctl_border(ctl_border_o),
        .ctl_dir_commit(ctl_dir_commit_o), .ctl_port_commit(ctl_port_commit_o),
        .ctl_osd_enable(ctl_osd_enable), .ctl_osd_we(ctl_osd_we),
        .ctl_osd_waddr(ctl_osd_waddr), .ctl_osd_wdata(ctl_osd_wdata), .ctl_osd_bg(ctl_osd_bg), .ctl_osd_op(ctl_osd_op), .ctl_osd_pos(ctl_osd_pos), .ctl_vol(ctl_vol),
        .ctl_osd_ddr_base(ctl_osd_ddr_base), .ctl_ddr_osd_en(ctl_ddr_osd_en), .ctl_ddr_osd_pos(ctl_ddr_osd_pos),
        .ctl_tape_run(ctl_tape_run_o), .ctl_tape_earmux(ctl_tape_earmux_o), .ctl_tape_mute(ctl_tape_mute_o), .ctl_tape_fmode(ctl_tape_fmode_o),
        .ctl_tape_sync(ctl_tape_sync_o), .ctl_tape_more(ctl_tape_more_o),
        .ctl_tape_we(ctl_tape_we_o), .ctl_tape_data(ctl_tape_data_o), .tape_full(tape_full_i), .tape_playing(tape_playing_i),
        .tape_diag_count(tape_diag_count_i), .tape_diag_hash(tape_diag_hash_i),
        .tape_diag_gaps(tape_diag_gaps_i), .tape_diag_resumes(tape_diag_resumes_i),
        .fe_trace_count(fe_trace_count_i), .fe_trace_hash(fe_trace_hash_i), .fe_trace_last(fe_trace_last_i),
        .ctl_ban_enable(ctl_ban_enable), .ctl_ban_we(ctl_ban_we),
        .ctl_ban_waddr(ctl_ban_waddr), .ctl_ban_wdata(ctl_ban_wdata), .ctl_ban_pos(ctl_ban_pos),
        .ctl_player_en(ctl_player_en), .ctl_aud_sum(ctl_aud_sum), .ctl_audio_we(ctl_audio_we), .ctl_audio_data(ctl_audio_data),
        .aud_pk_in(pk_s1),              // B0107: 0x17C пики ARM-ноги и итогового микса
        .ctl_nemo(ctl_nemo_o), .ctl_nemo_we(ctl_nemo_we_o), .nemo_stat_in(nemo_stat_i), .nemo_stat2_in(nemo_stat2_i),
        .ctl_kmouse(ctl_kmouse_o), .ctl_kmouse_we(ctl_kmouse_we_o),   // B0116 мышь Kempston
        .ctl_dmmc(ctl_dmmc_o), .ctl_dmmc_we(ctl_dmmc_we_o), .ctl_dmmc_cap(ctl_dmmc_cap_o),
        .ctl_dmmc_bufa(ctl_dmmc_bufa_o), .ctl_dmmc_bufa_we(ctl_dmmc_bufa_we_o),
        .ctl_dmmc_bufw(ctl_dmmc_bufw_o), .ctl_dmmc_bufw_we(ctl_dmmc_bufw_we_o),
        .ctl_dmmc_bufr_re(ctl_dmmc_bufr_re_o),
        .dmmc_bufa_in(dmmc_bufa_i), .dmmc_bufr_in(dmmc_bufr_i), .dmmc_stat_in(dmmc_stat_i),
        .dmmc_lba_in(dmmc_lba_i), .dmmc_dbg_in(dmmc_dbg_i),
        .gs_rq_dout(gs_rq_dout_i), .gs_rq_empty(gs_rq_empty_i), .gs_rq_cnt(gs_rq_cnt_i),
        .gs_rq_rd(gs_rq_rd_o),          // B0108: 0x180 очередь данных General Sound
        .aud_full(aud_full), .aud_empty(aud_empty), .aud_rdcount(aud_rdcount),
        .kbd_fifo_dout(kbd_fifo_dout), .kbd_fifo_empty(kbd_fifo_empty),
        .ps2_diag_in(diag_s1),          // CE28: СВОЙ регистр диагностики PS/2 у оболочки (0x13C)
        .kbd_fifo_rd(kbd_fifo_rd), .kbd_deadman_kick(kbd_deadman_kick_o),
        .halt_ack(halt_ack_i), .ram_busy(ram_busy_i), .reset_busy(reset_busy_i),
        .ctl_reset(ctl_reset_o),
        .ctl_kbd_inject(ctl_kbd_inject_o), .ctl_kbd_inject_we(ctl_kbd_inject_we_o), .memwr_cnt(memwr_cnt_i),
        .disp_diag({ld_stale, ld_underrun}),   // B0196: 0x1C8 приборы читателя строк
        .ctl_blend(ctl_blend), .blend_stat(blend_stat),   // B0198: 0x1CC смешение кадров
        .ctl_kbd_tx_data(ctl_kbd_tx_data), .ctl_kbd_tx_we(ctl_kbd_tx_we),
        .kbd_tx_busy(kbd_tx_busy_aclk), .kbd_tx_ack(kbd_tx_ack_aclk), .kbd_diag(kbd_diag_i),
        .ctl_pentagon(ctl_pentagon_o), .ctl_model48(ctl_model48_o), .ctl_ula_late(ctl_ula_late_o), .ctl_force_atlas(ctl_force_atlas_o), .ctl_snow_off(ctl_snow_off_o), .ctl_pent_int(ctl_pent_int_o),
        .ctl_ula_tune(ctl_ula_tune_o), .ctl_ula_tune2(ctl_ula_tune2_o),
        .ctl_mach_cfg(ctl_mach_cfg_o),
        .ctl_pal_we(ctl_pal_we), .ctl_pal_addr(ctl_pal_addr), .ctl_pal_rgb(ctl_pal_rgb),
        .ctl_mem_cmd(ctl_mem_cmd), .ctl_mem_we(ctl_mem_we), .mem_stat_in(mem_stat), .mach_dbg_in(mach_dbg_s1), .rom_dbg_in(rom_dbg_s1), .aud_dbg_in(aud_dbg_s1),
        .ctl_joy(ctl_joy_o),
        .ctl_paper_h(ctl_paper_h_o), .ctl_paper_v(ctl_paper_v_o), .ctl_scr_pos(ctl_scr_pos), .ctl_scr_scale(ctl_scr_scale),
        .ctl_probe_base(ctl_probe_base), .ctl_probe_ctrl(ctl_probe_ctrl), .ctl_probe_start(ctl_probe_start),
        .probe_stat(probe_stat), .probe_lat_min(probe_lat_min), .probe_lat_max(probe_lat_max),
        .probe_lat_sum(probe_lat_sum), .probe_cycles(probe_cycles), .probe_beats(probe_beats),
        .ctl_crop_a(ctl_crop_a), .ctl_crop_b(ctl_crop_b),
        .ctl_warp_hold(ctl_warp_hold_o),
        .ctl_sync_hold(ctl_sync_hold_o),
        .cap_geom(cap_geom_f),
        .ctl_romtrap_en(ctl_romtrap_en_o), .ctl_romtrap_done_we(ctl_romtrap_done_we_o),
        .ctl_quiesce(ctl_quiesce), .axi_idle(axi_idle_all),
        .rt_pending_a_in(rt_pending_a_i), .p7ffd_s1_in(p7ffd_s1_i), .reg_rd1_in(reg_rd1_i),
        .sync_diag_in(sync_diag_i),
        .ctl_scr_raddr(ctl_scr_raddr_o), .scr_rdata(scr_rdata_i)
    );
endmodule
//-------------------------------------------------------------------------------------------------
