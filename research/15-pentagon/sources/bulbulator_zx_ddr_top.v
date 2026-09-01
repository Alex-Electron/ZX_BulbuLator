`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// bulbulator_zx_ddr_top.v - Atlas ZX Spectrum on the EBAZ4205, MACHINE SIDE ONLY.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// B0062: the whole machine-agnostic shell (PS7/AXI, HDMI clocks+output, DDR framebuffer chain,
// OSD layers, PS/2 RX+TX, scancode FIFO, ARM music FIFO, master volume, QUIESCE, axi_ctl) moved
// into control_plane.v - ONE instance a top cannot half-carry. Everything left in this file is
// the ZX machine: clock_zx, the Atlas core + mem_zx, HALT/inject CDC, tape/warp/SYNC/ROM-trap
// machinery, the keyboard-gate matrix adapter, the screen mirror, and the ZX leg of the audio
// mix. NemoBus (the expansion connector) belongs HERE when it lands - it is ZX hardware.
//
// Clock domains: fclk100 (shell/aclk), spclk ~56.7 MHz (machine), clk_pixel/clk_audio (shell out).
//-------------------------------------------------------------------------------------------------
module bulbulator_zx_ddr_top
(
    output wire       TMDS_Clk_p,     // F19
    output wire       TMDS_Clk_n,     // F20
    output wire [2:0] TMDS_Data_p,    // D19 / C20 / B19
    output wire [2:0] TMDS_Data_n,    // D20 / B20 / A20

    input  wire [3:0] btn,            // P19 / T19 / U20 / U19, active-low
    input  wire       ear_in,         // J19, tape audio in (LVCMOS33, PULLDOWN)
    inout  wire       ps2_clk,        // G19 (DATA2-07), PS/2 keyboard clock  (Step 15: now bidirectional / open-drain for host TX)
    inout  wire       ps2_data,       // H20 (DATA2-08), PS/2 keyboard data   (Step 15: bidirectional; RX unchanged, TX drives low)

    output wire       led_lock,       // D18: Spectrum MMCM locked
    output wire       led_heart,      // H18: heartbeat (alive indicator)
    // Ethernet PHY на ногах ПЛИС - провода от GEM0 через EMIO (см. control_plane.v)
    output wire [3:0] eth_txd,
    output wire       eth_tx_en,
    input  wire       eth_tx_clk,
    input  wire [3:0] eth_rxd,
    input  wire       eth_rx_dv,
    input  wire       eth_rx_clk,
    output wire       eth_mdc,
    inout  wire       eth_mdio,
    output wire       eth_ref_clk
);

    //=============================================================================================
    // Machine-agnostic shell (control_plane): PS7+AXI, HDMI, framebuffer, OSD, PS/2, audio, QUIESCE.
    // Wires below carry the ORIGINAL net names so every retained ZX block is byte-identical.
    //=============================================================================================
    wire        fclk100, clk_pixel, clk_audio_r, aresetn, core_resetn_unused;
    wire        ctl_halt;
    wire        ctl_ram_we;
    wire [16:0] ctl_ram_waddr;
    wire [7:0]  ctl_ram_data;
    wire [211:0] ctl_dir;
    wire [5:0]  ctl_7ffd;
    wire [2:0]  ctl_border;
    wire        ctl_dir_commit, ctl_port_commit, ctl_reset;
    wire        ctl_osd_enable, ctl_ddr_osd_en;
    wire        ctl_tape_run, ctl_tape_earmux, ctl_tape_mute, ctl_tape_sync, ctl_tape_more, ctl_tape_we;
    wire [1:0]  ctl_tape_fmode;
    wire [31:0] ctl_tape_data;
    wire [8:0]  ctl_kbd_inject;
    wire        ctl_kbd_inject_we, kbd_deadman_kick;
    wire        ctl_pentagon, ctl_model48, ctl_ula_late, ctl_force_atlas, ctl_snow_off;
    // ПЕНТАГОН 1024: полный номер банка приходит ИЗ ЯДРА (там защёлка расширенных бит и порт
    // EFF7), ожидание - из мастера памяти оболочки. У MiSTer-48 (своя ULA, машина 48К без
    // страничности вообще) и у мёртвого гибрида этих портов нет: банк = младшие три бита адреса,
    // ожидания не бывает.
    // ОБЪЯВЛЕНИЕ здесь, ПРИСВОЕНИЕ - ниже, рядом с mem_zx: memA_core объявлен только там, а
    // ссылка на него отсюда молча создала бы однобитный неявный провод (в файле нет
    // `default_nettype none`) и индексация [16:14] упала бы на синтезе.
    wire [5:0]  ram_bank_core;
`ifdef MISTER48_CORE
    wire [7:0]  eff7_core   = 8'd0;
    wire        zx_mem_wait = 1'b0;
    wire        trdos_core  = 1'b0;   // B0071: у чужого ядра трапа TR-DOS нет
    wire [1:0]  rom_page_core = 2'd0;
    wire [31:0] rom_dbg_core  = 32'd0;    // B0147: прибора трапа у чужого ядра тоже нет
    wire        page3_seen_core = 1'b0;
`elsif HYBRID_CORE
    wire [7:0]  eff7_core   = 8'd0;
    wire        zx_mem_wait = 1'b0;
    wire        trdos_core  = 1'b0;
    wire [1:0]  rom_page_core = 2'd0;
    wire [31:0] rom_dbg_core  = 32'd0;    // B0147
    wire        page3_seen_core = 1'b0;
`else
    wire [7:0]  eff7_core;
    wire        zx_mem_wait;
    wire        trdos_core;           // B0071: живая защёлка DOS из memory.v
    wire [1:0]  rom_page_core;        // B0071: живая страница ПЗУ
    wire [31:0] rom_dbg_core;         // B0147: {взводов трапа, снятий, адрес последнего взвода}
    wire        page3_seen_core;      // B0147: липко - слот 3 был в окне
`endif
    wire [19:0] zxddr_addr;  wire [7:0] zxddr_wdata, zxddr_rdata;  wire zxddr_rd, zxddr_wr;
    wire [31:0] zx_mach_dbg;
    wire [31:0] zx_aud_dbg;   // B0088: пики звука из машины -> 0x170
    /* B0071: страничность ПЗУ и способности - ПО ЦЕЛИ. У чужих ядер (mister48, hybrid) своя
       страничность ПЗУ, поэтому им остаётся прежняя пара страниц (индекс memA[14:0], те же 8
       плиток BRAM) и бит4 LOAD_CAPS не поднимается. Мало того, у них страницы 2/3 АЛИАСИЛИСЬ БЫ
       поверх живых 0/1, поэтому заливка там запрещена ЖЕЛЕЗОМ (rom_ld_en), а не советом в
       LOAD_CAPS: совет прошивка может проигнорировать или прочитать из устаревшего кэша. */
`ifdef MISTER48_CORE
    localparam integer  ROM_PAGES_SEL = 2;
    localparam [31:0]   LOAD_CAPS_SEL = 32'h00000009;
`elsif HYBRID_CORE
    localparam integer  ROM_PAGES_SEL = 2;
    localparam [31:0]   LOAD_CAPS_SEL = 32'h00000009;
`else
    localparam integer  ROM_PAGES_SEL = 4;
    localparam [31:0]   LOAD_CAPS_SEL = 32'h000001F9;   // + бит8 = в этом ядре ЕСТЬ карта DivMMC
                                                        //   (0x19C..0x1B8). Кэш возможностей прошивка
                                                        //   ОБЯЗАНА сбрасывать при смене ядра, иначе
                                                        //   покажет владельцу карту там, где её нет.
                                                        // + бит4 = порт заливки ПЗУ (0x154/0x158/0x15C),
                                                        // + бит5 = ядро принимает запись регистров ATA
                                                        //   от ARM (B0115): на ядре без него прошивке
                                                        //   нечем выставить сигнатуру после 0x90,
                                                        // + бит6 = есть мышь Kempston (B0116, порт 0x190).
                                                        //   Без этого бита прошивке пришлось бы ГАДАТЬ,
                                                        //   есть ли в ядре порты мыши, и она показывала бы
                                                        //   владельцу живую опцию на ядре, где её нет.
                                                        // + бит7 = DRQ ведёт ФАБРИКА (B0117): она снимает
                                                        //   его по факту вычерпывания блока и держит BSY
                                                        //   между блоками. Бит нужен прошивке, чтобы
                                                        //   ЗНАТЬ, куда можно класть служебную метку
                                                        //   «блок последний» (бит1 слова состояния): на
                                                        //   старом ядре тот же бит уехал бы прямо в
                                                        //   регистр состояния машины.
                                                        //   Кэш возможностей сбрасывать при смене ядра!
`endif
    wire rom_ld_en = (ROM_PAGES_SEL == 4);   // константа: у цели с 2 страницами заливки ПЗУ нет вовсе
    // B0071: шина заливки ПЗУ от ARM (живёт в fclk100 - том же домене, что порт B BRAM ПЗУ,
    // поэтому строб записи не нуждается в CDC) + слово MACHINE_CFG, из которого машина берёт
    // бит8 = «трап входа в TR-DOS разрешён».
    // B0075 дисковод: мост подачи секторов между ARM и контроллером внутри ядра
    wire [31:0] fdc_ctl_a;  wire fdc_ctl_we_a;
    wire [31:0] gs_ctl_a;   wire gs_ctl_we_a;   // General Sound: 0x178 W
    wire [31:0] gs_stat_w;                      // General Sound: 0x174 R
    /* B0108/B0118 УПРУГАЯ ОЧЕРЕДЬ ЗАПИСЕЙ #B3. Живёт здесь, потому что здесь есть ОБА
       такта: пишет её машина (spclk 56 МГц), вычерпывает оболочка (fclk100).
       B0119: глубина 64 и резерв 8 мест. Раньше было 128 с резервом 32 - под записи, которые
       гость делает БЕЗ опроса флага. Теперь таких записей не бывает вовсе: шина держит машину
       прямо в цикле записи (gs_flow.v), то есть за порог очередь может уйти ровно на один байт,
       уже принятый. Резерв стал платой ни за что, а место в кристалле у нас кончилось буквально:
       первая сборка B0119 НЕ РАЗМЕСТИЛАСЬ - не хватило 16 слайсов из 4400. Глубина же теперь
       только ПЛАВНОСТЬ: 48 полезных байт по 4.7 мкс = 0.22 мс свободного хода между
       удержаниями. Историческая справка о том, зачем её вообще наращивали:
       корректность теперь держит НЕ глубина, а обратное давление (см. gs_wq_fifo.v и main.v),
       поэтому глубина - это только ПЛАВНОСТЬ (96 полезных байт по 4.7 мкс = 0.45 мс без
       единого ожидания), а за неё можно торговаться. И пришлось: глубина 256 собралась на 91.28 %
       LUT и ПРОВАЛИЛА тайминг ПИКСЕЛЬНОГО домена (WNS -0.081 нс на буферах OSD) - ровно так
       же, как в B0108. Повторять ту же ошибку незачем: байт терялся не из-за мелкой очереди, а
       из-за молчания о занятости. Память - распределённая (LUTRAM): блочной взять негде,
       BRAM заняты все 60 из 60. */
    wire [31:0] nemo_ctl_a;  wire nemo_ctl_we_a;  wire [31:0] nemo_stat_w, nemo_stat2_w;   // B0112 NEMO-IDE
    // DivMMC: карта SD (0x19C..0x1B8). Сама она стоит НИЖЕ, у выводов uSD ядра.
    wire [31:0] dmmc_ctl_a, dmmc_cap_a, dmmc_bufa_a, dmmc_bufw_a;
    wire        dmmc_ctl_we_a, dmmc_bufa_we_a, dmmc_bufw_we_a, dmmc_bufr_re_a;
    wire [31:0] dmmc_bufa_q_w, dmmc_bufr_q_w, dmmc_stat_w, dmmc_lba_w, dmmc_dbg_w;
    wire        sd_cs_n_w, sd_ck_w, sd_mosi_w, sd_miso_w;
    wire [31:0] km_ctl_a;    wire km_ctl_we_a;                                             // B0116 мышь Kempston
    wire [7:0]  gs_wq_din_sp;  wire gs_wq_we_sp, gs_wq_full_sp, gs_wq_afull_sp, gs_wq_drain_sp;
    wire [31:0] gs_stat2_w, gs_stat3_w;          // B0119: прибор обратного давления (0x194/0x198)
    wire [7:0]  gs_rq_dout;    wire gs_rq_empty, gs_rq_rd;
    /* Занятость очереди наружу отдаётся девятью битами (протокол регистра 0x180 не трогаем),
       а сама очередь стала мельче - расширяем ЯВНО. Узкий выход, воткнутый в широкий провод,
       оставил бы старшие разряды неподключёнными, и прошивка читала бы в них мусор. */
    wire [6:0]  gs_rq_cnt_n;   wire [8:0] gs_rq_cnt = {2'd0, gs_rq_cnt_n};
    wire [7:0]  fdc_data_a; wire fdc_data_we_a;
    wire [31:0] fdc_stat_w, fdc_stat2_w;
    wire [15:0] rom_ld_addr_a;
    wire [7:0]  rom_ld_data_a;
    wire        rom_ld_we_a, rom_loading_a;
    wire [31:0] mach_cfg_w;
    wire [31:0] ctl_pent_int;
    wire [31:0] ctl_ula_tune;
    wire [8:0]  ctl_paper_h, ctl_paper_v;
    wire [31:0] ctl_joy;
    wire [31:0] ctl_warp_hold, ctl_sync_hold;
    wire        ps2_strb, ps2_make;
    wire [7:0]  ps2_code;
    wire        ps2tx_busy;
    wire [31:0] cp_ps2_diag;
    wire [31:0] player_pcm;
    wire [8:0]  pgain, mgn;
    wire        halt_ack, ram_busy, reset_busy_aclk;
    //=============================================================================================
    // Spectrum master clock (~56.7 MHz) + clock enables from clock_zx.
    //=============================================================================================
    wire spclk;
    gs_wq_fifo #(.DW(8), .AW(6), .HDR(8), .LO(16)) gs_wq_i (
        .wr_clk(spclk),   .wr_rst_n(aresetn), .wr_en(gs_wq_we_sp), .din(gs_wq_din_sp),
        .full(gs_wq_full_sp), .afull(gs_wq_afull_sp), .wr_count(), .drain_w(gs_wq_drain_sp),
        .rd_clk(fclk100), .rd_rst_n(aresetn), .rd_en(gs_rq_rd),
        .dout(gs_rq_dout), .empty(gs_rq_empty), .rd_count(gs_rq_cnt_n)
    );
    wire sp_lock;
    wire pe7M0, ne7M0, pe3M5, ne3M5;
    wire vid_blank, vid_hsync, vid_vsync, vid_r, vid_g, vid_b, vid_i;
    wire warp_active;                                       // full whole-core 4x warp (WAV AUTO policy; defined below)
    wire warp_safe2_active;                                 // B0047 diagnostic whole-core 2x route for explicit fmode=2
    wire tape_streaming;                                    // лента РЕАЛЬНО движется (присваивается ниже, рядом с tape_advance)
    wire warp_ack;                                          // clock_zx has actually adopted the requested non-native schedule
    clock_zx clock_zx_i (
        .fclk100(fclk100), .warp(warp_active), .warp2(warp_safe2_active), .clock(spclk), .power(sp_lock),
        .warp_ack(warp_ack),
        .ne14M(), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5)
    );
    // Pause key = E1 14 77 (make) / E1 F0 14 F0 77 (break) is ARM-owned (intercepted from the always-
    // tap FIFO). Suppress its whole byte run from the Z80 matrix AND the hotkey latches, so a resume
    // can never leak Symbol-Shift (0x14) into the core or stick a reset-combo flag. Anchor on 0xE1
    // (no other set-2 key emits it); eat up to 4 following bytes (covers make 14 77 + break F0 14 F0 77).
    reg [2:0] pse = 3'd0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~ps2tx_busy) begin
        if (ps2_code == 8'hE1) pse <= 3'd4;
        else if (pse != 3'd0)  pse <= pse - 3'd1;
    end
    wire pause_byte = (ps2_code == 8'hE1) | (pse != 3'd0);

    // Keep the E0 prefix until the following data byte (and across an intervening F0 on break).
    // The old matrix path discarded this information, so the physical cursor keys and NumPad
    // 8/2/4/6 were indistinguishable.  We need the distinction when NumLock gives the keypad to
    // Kempston: suppress the non-extended keypad byte, but keep the real E0 cursor key in the matrix.
    reg ps2_e0 = 1'b0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~ps2tx_busy) begin
        if      (ps2_code == 8'hE0) ps2_e0 <= 1'b1;
        else if (ps2_code != 8'hF0) ps2_e0 <= 1'b0;
    end

    // Held state of the hotkey keys (make=0 => pressed). Qualified by ~pause_byte (Pause never touches
    // a combo flag); belt-and-suspenders: ANY 0xF0 break frame clears ALL latches, so no key can leave
    // ctrl_h/alt_h/del_h permanently stuck and silently arm Ctrl+Alt+Del. Normal press/release still
    // works: a held key sets its latch on make; F0+code clears it (and the per-key make=1 agrees).
    reg ctrl_h = 1'b0, alt_h = 1'b0, del_h = 1'b0, ins_h = 1'b0, f11_h = 1'b0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~pause_byte && ~ps2tx_busy) begin
        if (ps2_code == 8'hF0) begin ctrl_h<=1'b0; alt_h<=1'b0; del_h<=1'b0; ins_h<=1'b0; f11_h<=1'b0; end
        else case (ps2_code)
            8'h14: ctrl_h <= ~ps2_make;   // Ctrl (also Symbol Shift in the matrix)
            8'h11: alt_h  <= ~ps2_make;   // Alt
            8'h71: if (ps2_e0) del_h <= ~ps2_make;   // E0 71 = Delete; bare 71 = NumPad dot
            8'h70: if (ps2_e0) ins_h <= ~ps2_make;   // E0 70 = Insert; bare 70 = NumPad zero
            8'h78: f11_h  <= ~ps2_make;   // F11
            default: ;
        endcase
    end
    wire soft_combo = ctrl_h & alt_h & del_h;        // Ctrl+Alt+Del -> soft reset
    /* B0136 (просьба владельца 14.08): NMI вешается на ПРОСТОЙ Ins, без Ctrl+Alt. Причина простая -
       это главная кнопка при работе с esxDOS, ею открывают NMI-браузер поверх чего угодно, и тянуть
       ради неё аккорд неудобно. Прежний аккорд оставлен: он ничего не стоит и у кого-то в пальцах.
       ⚠ Плата за это: Ins больше не доедет до машины как обычная клавиша. Софта, которому нужен
       именно Ins на Спектруме, не бывает (на ZX-клавиатуре такой клавиши нет вовсе), но если
       понадобится - это станет опцией машины, а не откатом. */
    /* B0139 (просьба владельца 14.08): «клавиша Ins не должна передаваться и в навигатор, и в машину
       при открытом навигаторе, только в навигатор». Верно: NMI собирается ЗДЕСЬ, в фабрике, а
       фабрика про открытую оболочку не знает - клавиатурный гейт подавляет PS/2 только по пути в
       ядро (ps2_to_core), до аккордов он не доходит. Поэтому Ins открывал NMI-браузер esxDOS прямо
       поверх навигатора, где той же клавишей помечают файлы.
       Гейтится ТОЛЬКО голый Ins. Явный аккорд Ctrl+Alt+Ins оставлен работать всегда: случайно его
       в навигаторе не наберёшь, а «магическая кнопка» поверх оболочки иногда нужна намеренно. */
    wire nmi_combo  = (ins_h & ~gate_on) | (ctrl_h & alt_h & ins_h);   // Ins / Ctrl+Alt+Ins -> NMI
    wire hard_combo = f11_h;                          // F11          -> hard / cold reset (RAM wipe)

    // NMI: one short pulse on the Ctrl+Alt+Ins press edge -> the core's nmi input.
    reg       nmi_d   = 1'b0;
    reg [4:0] nmi_cnt = 5'd0;
    always @(posedge spclk) begin
        nmi_d <= nmi_combo;
        if (nmi_combo & ~nmi_d)   nmi_cnt <= 5'd31;
        else if (nmi_cnt != 5'd0) nmi_cnt <= nmi_cnt - 5'd1;
    end
    wire nmi_pulse = (nmi_cnt != 5'd0);
    //=============================================================================================
    // Power-on reset in the Spectrum domain (ACTIVE-LOW).
    //=============================================================================================
    // por_n = power-on reset ONLY (never re-asserts on a hotkey). It resets the video pipeline.
    reg  [1:0]  lock_sync = 2'b00;
    reg  [15:0] por_cnt   = 16'd0;
    reg         por_n     = 1'b0;
    wire        lock_in   = lock_sync[1];
    always @(posedge spclk) begin
        lock_sync <= {lock_sync[0], sp_lock};
        if (!lock_in) begin
            por_cnt <= 16'd0; por_n <= 1'b0;
        end else if (por_cnt != 16'hFFFF) begin
            por_cnt <= por_cnt + 16'd1; por_n <= 1'b0;
        end else begin
            por_n <= 1'b1;
        end
    end

    // B0071: уровни от ARM в такт машины. `rom_loading` ДЕРЖИТ ПРОЦЕССОР В СБРОСЕ на всё время
    // заливки ПЗУ - иначе Z80 исполнял бы полузаписанное ПЗУ. У картриджа NES это закрыто ровно
    // так же (loading входит в core_reset, а строб записи ещё и загейтен по loading), и одного
    // HALT-а здесь НЕДОСТАТОЧНО: он гасит только такты, состояние процессора сохраняется и после
    // снятия HALT он продолжил бы с подменённого под ним ПЗУ.
    (* ASYNC_REG="TRUE" *) reg [1:0] svcnmi_s = 2'b00;   // B0101: магическая кнопка (бит13)
    (* ASYNC_REG="TRUE" *) reg [1:0] romld_s = 2'b00, trdosen_s = 2'b00, svcrom_s = 2'b00,
                                     bdialways_s = 2'b00;
    // B0146: бит25 = под TR-DOS страница ПЗУ выбирается парой {DOS, 7FFD[4]} (вход в файловый
    // менеджер сервисной страницы). Биты 0..6 заняты у NES, 8..24 и 26 - у нас; 25 был единственной
    // дыркой внутри блока страничности/DivMMC, поэтому 27..31 остаются целым диапазоном.
    (* ASYNC_REG="TRUE" *) reg [1:0] dossvc_s = 2'b00;
    // B0087: режим SAA1099 на порте #FF - 2 бита, поэтому свой пара-регистровый конвейер.
    (* ASYNC_REG="TRUE" *) reg [1:0] saamode_s0 = 2'b00, saamode_s1 = 2'b00;
    // B0154: бит27 = ВЕРНУТЬ старую фазу окна контеншена ПОРТОВ (на такт раньше эталона).
    // Умолчание 0 = фаза настоящей машины (CONTP из ulatest3 на живом 48K: занято с 14339).
    // Зачем опция: сдвиг окна портов меняет тайминги ЛЮБОГО софта, который лупит IN/OUT в
    // растре, - если после B0154 какая-то демка поедет, бит27 возвращает поведение B0153
    // без пересборки ядра. Подробности у входа `io_cont_early` в atlas_core/main.v.
    (* ASYNC_REG="TRUE" *) reg [1:0] iocont_s = 2'b00;
    // B0120: маска недостающих старших бит банка - 3 бита, тот же двухступенчатый конвейер.
    (* ASYNC_REG="TRUE" *) reg [2:0] ramnb_s0 = 3'b000, ramnb_s1 = 3'b000;
    always @(posedge spclk) begin
        romld_s   <= {romld_s[0],   rom_loading_a & rom_ld_en};
        svcrom_s  <= {svcrom_s[0],  mach_cfg_w[9]};   // MACHINE_CFG бит9 = сервисная страница ПЗУ
        svcnmi_s  <= {svcnmi_s[0],  mach_cfg_w[13]};  // B0101 бит13 = магическая кнопка (по NMI)
        trdosen_s <= {trdosen_s[0], mach_cfg_w[8]};   // MACHINE_CFG бит8 = разрешить трап TR-DOS.
        bdialways_s <= {bdialways_s[0], mach_cfg_w[10]}; // B0079: временный upstream-like BDI A/B
        dossvc_s  <= {dossvc_s[0],  mach_cfg_w[25]}; // B0146 бит25 = пара {DOS, 7FFD[4]} выбирает страницу
        iocont_s  <= {iocont_s[0],  mach_cfg_w[27]}; // B0154 бит27 = окно контеншена ПОРТОВ как до B0154 (на такт раньше эталона); умолчание 0 = фаза настоящей машины
        saamode_s0  <= mach_cfg_w[12:11];             // B0087: SAA1099 0 AUTO / 1 ON / 2 OFF
        saamode_s1  <= saamode_s0;
        ramnb_s0    <= mach_cfg_w[16:14];             // B0120: 000 = 1024К (по умолчанию), 111 = 128К
        ramnb_s1    <= ramnb_s0;
                                                     // Не бит5: биты 0..6 этого слова у NES заняты
                                                     // (region, palette[5:4], sprlimit), и при отказе
                                                     // смены ядра ZX получил бы чужой бит.
    end
    wire rom_loading_sp = romld_s[1];
    wire trdos_en_sp    = trdosen_s[1];
    wire svcrom_sp      = svcrom_s[1];
    wire svc_nmi_en_sp  = svcnmi_s[1];   // B0101: страница вставляется по NMI, снимается по RETN
    wire dos_svc_en_sp  = dossvc_s[1];   // B0146: под TR-DOS сброс 7FFD[4] вставляет СЕРВИСНУЮ страницу
    // General Sound: бит включения приходит из домена AXI - синхронизируем двумя триггерами.
    // Само слово управления и строб в синхронизации не нуждаются: их защёлкивает ловушка по стробу.
    (* ASYNC_REG="TRUE" *) reg [1:0] gsen_s = 2'b00;
    always @(posedge spclk) gsen_s <= {gsen_s[0], gs_ctl_a[31]};
    wire gs_en_sp = gsen_s[1];
    /* DivMMC включён (MACHINE_CFG бит17). Бит машино-агностичного слова, поэтому синхронизируем
       так же, как остальные: два триггера. Биты 0..6 этого слова у NES заняты - брать их нельзя. */
    (* ASYNC_REG="TRUE" *) reg [1:0] dmen_s = 2'b00;
    always @(posedge spclk) dmen_s <= {dmen_s[0], mach_cfg_w[17]};
    wire divmmc_en_sp = dmen_s[1];
    /* B0138 Z-CONTROLLER - MACHINE_CFG бит19. Отдельный бит, а не режим DivMMC: у Sizif они тоже
       независимы, карта одна и конфликта нет. Автомаппер ПЗУ при этом остаётся ТОЛЬКО у DivMMC -
       у Z-Controller своего ПЗУ нет вовсе, это два голых порта SPI. */
    (* ASYNC_REG="TRUE" *) reg [1:0] zcen_s = 2'b00;
    always @(posedge spclk) zcen_s <= {zcen_s[0], mach_cfg_w[19]};
    wire zc_en_sp = zcen_s[1];
    (* ASYNC_REG="TRUE" *) reg [1:0] zcturbo_s = 2'b00;
    always @(posedge spclk) zcturbo_s <= {zcturbo_s[0], mach_cfg_w[20]};
    wire zc_turbo_sp = zcturbo_s[1];
    /* B0132 ОПЦИИ DivMMC. Таблица - DIVMMC_PLAN.md §3.2. Синхронизируем тем же приёмом, что и бит17:
       слово MACHINE_CFG пишет ARM, машина живёт в своём домене.
       ⚠ Бит 18 и dm_opt[0] ПРОТИВОПОЛОЖНЫ: в слове 1 = «гейт входов включён» (как Sizif/Next),
       а в модуле dm_opt[0]=1 гейт СНИМАЕТ (см. memory.v:270). Отсюда инверсия. */
    (* ASYNC_REG="TRUE" *) reg [1:0] dmgate_s = 2'b00, dmwp_s = 2'b00, dmnmi_s = 2'b00, dmprato_s = 2'b00;
    (* ASYNC_REG="TRUE" *) reg [1:0] dmtap0_s = 2'b00, dmtap1_s = 2'b00;
    always @(posedge spclk) begin
        dmgate_s  <= {dmgate_s[0],  mach_cfg_w[18]};   // 1 = гейт входов по вставленному 48 BASIC
        dmwp_s    <= {dmwp_s[0],    mach_cfg_w[23]};   // 1 = защита записи MAPRAM (спека)
        dmnmi_s   <= {dmnmi_s[0],   mach_cfg_w[24]};   // 1 = вход 0x0066 отдан esxDOS
        dmprato_s <= {dmprato_s[0], mach_cfg_w[26]};   // 1 = выход из MAPRAM по моду Prato
        dmtap0_s  <= {dmtap0_s[0],  mach_cfg_w[21]};   // 22:21 ловушки ленты: 00 авто, 01 esxDOS, 10 наши
        dmtap1_s  <= {dmtap1_s[0],  mach_cfg_w[22]};
    end
    /* 🥇 B0134 ПОРЯДОК РАЗРЯДОВ. В конкатенации {a,b,c,d} слева направо идут [3],[2],[1],[0], а в
       первой редакции комментарии стояли [3],[1],[2],[0] - и два бита физически поменялись местами.
       Цена: `hook_nmi` (вход 0x0066, то есть ВЫЗОВ NMI-БРАУЗЕРА esxDOS) питался от бита защиты
       записи и был ВЫКЛЮЧЕН, а защита записи MAPRAM наоборот снята. Оба дефекта тихие: браузер
       просто не открывался, а защита просто не работала. */
    wire [3:0] dm_opt_sp = { dmprato_s[1],   // [3] мод Prato: %11xxxxxx снимает MAPRAM
                             dmnmi_s[1],     // [2] вход 0x0066 отдан DivMMC (NMI-браузер)
                             ~dmwp_s[1],     // [1] инвертирован: 1 = БЕЗ защиты записи (поведение MiSTer)
                             ~dmgate_s[1] }; // [0] 1 = гейт входов СНЯТ
    /* Ловушки ленты 04C6/0562: наш SMART-загрузчик и .tapein esxDOS живут на одних адресах.
       10 = держим их себе. 00 (авто) и 01 = отдаём esxDOS, потому что в режиме DivMMC лентой
       по решению владельца рулит esxDOS. */
    wire dm_pagein_off_sp = (~dmtap0_s[1]) & dmtap1_s[1];
    wire bdi_always_sp  = bdialways_s[1];
    wire [1:0] saa_mode_sp = saamode_s1;
    wire [2:0] ram_nobit_sp = ramnb_s1;

    // Cold-reset RAM wipe (F11): freeze the Z80, sweep-write 0 to all 128KB RAM (and the
    // screen shadow), then reset the core - a true power-on cold boot. Soft reset (Ctrl+Alt+Del)
    // skips the wipe (keeps RAM, like a warm reset). The video pipeline stays on por_n throughout,
    // so the picture re-aligns and the AXI-HP bus never hangs.
    reg        soft_d = 1'b0, hard_d = 1'b0;
    reg        clr_active = 1'b0;
    reg [16:0] clr_addr   = 17'd0;
    reg        clr_done   = 1'b0;
    always @(posedge spclk) begin
        soft_d   <= soft_combo;
        hard_d   <= hard_combo;
        clr_done <= 1'b0;
        if (!por_n) begin
            clr_active <= 1'b0; clr_addr <= 17'd0;
        end else if (((hard_combo & ~hard_d) | arm_reset_sp) & ~clr_active) begin   // F11 OR ARM AXI-RESET -> RAM wipe + cold reset
            clr_active <= 1'b1; clr_addr <= 17'd0;
        end else if (clr_active) begin
            if (clr_addr == 17'h1FFFF) begin clr_active <= 1'b0; clr_done <= 1'b1; end
            else                             clr_addr   <= clr_addr + 17'd1;
        end
    end

    reg [17:0] rst_cnt = 18'd0;
    reg        core_rst_n = 1'b0;
    always @(posedge spclk) begin
        if (!por_n) begin
            rst_cnt <= 18'd0; core_rst_n <= 1'b0;
        end else if (clr_done) begin                 // cold reset: pulse after the RAM wipe finishes
            rst_cnt <= 18'd200000; core_rst_n <= 1'b0;
        end else if (soft_combo & ~soft_d) begin     // soft reset: short pulse, RAM preserved
            rst_cnt <= 18'd50000;  core_rst_n <= 1'b0;
        end else if (rst_cnt != 18'd0) begin
            rst_cnt <= rst_cnt - 18'd1; core_rst_n <= 1'b0;
        end else begin
            core_rst_n <= 1'b1;
        end
    end
    wire sp_reset_n = por_n & core_rst_n & ~rom_loading_sp;  // power-on / hotkey reset / ЗАЛИВКА ПЗУ
    // B0071: удержание сброса на время заливки ПЗУ ОБЯЗАНО быть видно в STATUS бит2. Иначе
    // machine_reset() из ARM дожидается «сброс завершён», оболочка считает машину живой, а она стоит -
    // ровно та картина «чёрный слой машины при живом OSD», которую нечем объяснить с хоста.
    wire reset_busy_sp = clr_active | (rst_cnt != 18'd0) | rom_loading_sp;   // -> ARM STATUS bit2
    // NemoBus / expansion bus: sp_reset_n IS the master reset. Route it (active-low /RESET) to the
    // expansion-connector pin when that bus is physically wired (one XDC line) so an attached board
    // resets on every load / F11 / AXI-RESET, like a real Spectrum edge-connector /RESET.

    // axi_ctl (в оболочке) <-> inject_cdc <-> Spectrum domain
    wire        cpu_halt_sp;
    wire        arm_memWr;
    wire [18:0] arm_memA;
    wire [7:0]  arm_memQ;
    wire [13:0] arm_vmmA2;
    wire [211:0] cpu_dir_sp, cpu_reg_sp;
    wire [5:0]   port7ffd_sp;
    wire [2:0]   border_sp;
    wire         dir_set_sp, force_7ffd_sp, force_border_sp;
    wire         arm_reset_sp;
    wire         tape_full, tape_playing, tape_ear, tape_playing_a;
    wire         tape_eot_now;       // true final EOT: last descriptor ended and ARM producer is done
    wire         tape_eot_safe;      // B0046 applies local EOT exit only to explicit SAFE4
    reg          tape_seen_playing;  // prevents an empty start-of-run from looking like EOT
    reg          tape_seen_more;     // local EOT is valid only for a producer that explicitly owned MORE
    wire         tape_empty_sp;   // tape pulse-FIFO empty (spclk) -> underrun backpressure
    wire [31:0]  tape_diag_count_sp, tape_diag_hash_sp, tape_diag_gaps_sp, tape_diag_resumes_sp;
    // Diagnostics cross spclk->aclk only for post-run inspection. Two samples are enough because
    // every value is stable before software/JTAG reads it; none feeds functional logic.
    reg [31:0] tape_diag_count_a0=32'd0, tape_diag_count_a1=32'd0;
    reg [31:0] tape_diag_hash_a0=32'd0,  tape_diag_hash_a1=32'd0;
    reg [31:0] tape_diag_gaps_a0=32'd0,  tape_diag_gaps_a1=32'd0;
    reg [31:0] tape_diag_res_a0=32'd0,   tape_diag_res_a1=32'd0;
    always @(posedge fclk100) begin
        tape_diag_count_a0 <= tape_diag_count_sp; tape_diag_count_a1 <= tape_diag_count_a0;
        tape_diag_hash_a0  <= tape_diag_hash_sp;  tape_diag_hash_a1  <= tape_diag_hash_a0;
        tape_diag_gaps_a0  <= tape_diag_gaps_sp;  tape_diag_gaps_a1  <= tape_diag_gaps_a0;
        tape_diag_res_a0   <= tape_diag_resumes_sp; tape_diag_res_a1 <= tape_diag_res_a0;
    end
    // BulbuLator screen-mirror readback nets (MUST precede the axi_ctl instance that connects them)
    wire [10:0] scr_bram_raddr;   // mirror BRAM word address, driven by axi_ctl on a 0x8000+ read
    reg  [31:0] scr_rdata_r;      // mirror BRAM read data -> axi_ctl s_rdata
    reg  [15:0] sync_diag_a = 16'd0; // demand-tape post-mortem diagnostics, synchronized below
    // B0053 trace buses must be declared before axi_ctl uses them; declaring them later would let
    // Verilog create implicit scalar nets at this connection point and silently truncate readback.
    wire [31:0] int_dbg0_core, int_dbg1_core, int_dbg2_core;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg0_a0=32'd0, int_dbg0_a1=32'd0;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg1_a0=32'd0, int_dbg1_a1=32'd0;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg2_a0=32'd0, int_dbg2_a1=32'd0;
    always @(posedge fclk100) begin
        int_dbg0_a0 <= int_dbg0_core; int_dbg0_a1 <= int_dbg0_a0;
        int_dbg1_a0 <= int_dbg1_core; int_dbg1_a1 <= int_dbg1_a0;
        int_dbg2_a0 <= int_dbg2_core; int_dbg2_a1 <= int_dbg2_a0;
    end
    reg [31:0] fe_trace_count_a0=32'd0, fe_trace_count_a1=32'd0;
    reg [31:0] fe_trace_hash_a0=32'd0,  fe_trace_hash_a1=32'd0;
    reg [31:0] fe_trace_last_a0=32'd0,  fe_trace_last_a1=32'd0;
`ifdef HYBRID_CORE
    localparam [31:0] BUILD_VERSION = 32'hB01B0150; // гибрид, сборка 20.08: связи карты убраны
                                                    // под ifndef, ветвь снова синтезируется.
                                                    // Прежде здесь стоял B005B и не поднимался.
`elsif MISTER48_CORE
    localparam [31:0] BUILD_VERSION = 32'hB01B0150; // MiSTer-48, сборка 20.08. Прежде здесь стоял
                                                    // B0059: ядро пересобиралось, а НОМЕР нет, и
                                                    // машина рапортовала шестидесятой сборкой -
                                                    // владелец это и увидел. Каждая ветвь держит
                                                    // СВОЮ константу: поднимать ту, что собираешь.
`elsif MISTER_T80_AB
    localparam [31:0] BUILD_VERSION = 32'hB01B0054; // CPU-only A/B: MiSTer T80pa v0250, Atlas ULA unchanged
`else
//  localparam [31:0] BUILD_VERSION = 32'hB01B0086; // BDI floppy activity icon bottom-right HDMI (outside machine window).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0087; // НАСТОЯЩИЙ SAA1099 (в битстриме была
//  localparam [31:0] BUILD_VERSION = 32'hB01B0088; // SAA1099 получает РОВНО 8 МГц (был 8.0952 =
//  localparam [31:0] BUILD_VERSION = 32'hB01B0089; // ЗАПИСЬ НА ДИСКЕТУ: буфер контроллера стал
    localparam [31:0] BUILD_VERSION = 32'hB01B0156;  // B0155 (01.09): (1) pap_tap=9 для Sinclair 48K/128K (сведение бумаги и бордюра для SHOCK ч.2 без швов, на Пентагоне 0); (2) умолчание I/O-контеншена = vduC (выравнивание верхнего бордюра esh2_48).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0154;  // B0154 (31.08): ФАЗЫ 48K СВЕДЕНЫ С НАСТОЯЩЕЙ МАШИНОЙ. Плавающая шина отдаётся на такт позже (READP из ulatest3 на живом 48K: данные на 14340..14343, у нас были 14339..14342) и окно контеншена ПОРТОВ - тоже на такт позже (CONTP: занято с 14339, у нас с 14338). Порог stime остался 14335, как у машины: у ветви памяти строб падает на T1, у ветви портов IORQ только на T2, поэтому окна у них РАЗНЫЕ. Старая фаза портов возвращается битом27 MACHINE_CFG. Плюс экономия логики в T80: bq 3 бита, MEMPTR прерванной INxR/OTxR через уже имеющийся вычитатель PC-1.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0153;  // B0153 (31.08): флаги ПРЕРВАННОЙ блочной команды (лишний M-цикл повтора на 5 T): YF<-PC.13, XF<-PC.11 у всех, плюс HF/PF от B и MEMPTR=PC+1 у INxR/OTxR (David Banks 2018). Закрывает 089 LDIR->NOP', 090 LDDR->NOP', 102 INIR->NOP', 103 INDR->NOP' в z80full 1.2a (было 4 из 160).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0152;  // B0152 (31.08): Q-флаг доведён по z80ccf - SET/RES больше не ставят Q (флагов не трогают), LDI/LDD/LDIR/LDDR и CPI/CPD - ставят. На плате B0151 z80ccf валил ровно 071..080 (SET/RES) и 081..084 (LDI/LDD/LDIR/LDDR), остальные 134 OK.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0151;  // B0151 (28.08): Q-флаг Zilog для SCF/CCF в форке t80_bulb/T80.vhd (XF/YF = A | (F & ~Q); z80full RAXOFT валил 001 SCF / 002 CCF по CRC, стенд sim/timing/t80 даёт $29/$29/$81/$38). Только Atlas: MiSTer-48 и гибрид читают mister_t80.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0150;  // B0146: под взведённой защёлкой TR-DOS страница ПЗУ выбирается парой {DOS, 7FFD[4]} за битом25 MACHINE_CFG: сброс 7FFD[4] вставляет СЕРВИСНУЮ страницу (вход в файловый менеджер BIOS настоящих пентагонов: FATALL, Proteus). При снятом бите - бит-в-бит B0145.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0145;  // B0145: CMD12 всегда получает R1b (одна точка исполнения), выборка SPI по фронту, стандартный режим 3.5 МГц оживлён. B0139: голый Ins не уходит в машину при открытом навигаторе (см. nmi_combo). Плюс B0138: Z-Controller (#77/#57) на общем движке.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0137;  // B0137: порты карты живут только при включённом DivMMC.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0136;  // B0136: NMI на простой Ins.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0135;  // B0135: карта DivMMC переживает сброс машины.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0134;  // B0134: порядок разрядов dm_opt - вход 0x0066
                                                    // (NMI-браузер esxDOS) был выключен.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0133;  // B0133: состояние автомаппера выведено в DMMC_STAT.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0132;  // B0132: DivMMC ОЖИЛ (был .mapper(1'b0)),
                                                    // rom_trap разведён с автомаппером, мышь сужена
                                                    // до трёх канонических портов, разгрузка
                                                    // fb_capture_rr, videoEnableLoad = h_rel[3].
//  localparam [31:0] BUILD_VERSION = 32'hB01B0130;  // B0130: ТРИ МИНЫ СТРАНИЧНОСТИ (memory.v).
                                                    // 1) OUT (#E3),#80 подменял окно ПЗУ на ЖИВОЙ
                                                    // машине: защёлка #E3 и бит CONMEM действовали
                                                    // в обход mapper, хотя DivMMC у нас нет (топ
                                                    // передаёт .mapper(1'b0)). 0x0000 уезжал на
                                                    // страницу ПЗУ 1, 0x2000 - в мёртвый esx-регион
                                                    // с РАЗРЕШЁННОЙ записью, mapRam липкий.
                                                    // 2) OUT (#E3),#E4 писал ЕЩЁ И в EFF7 (у #E3 и
                                                    // #E7 линия A3 = 0) и выбивал Пентагон из
                                                    // мегабайтного режима - добавлен шестой терм
                                                    // A4, ЗАГЕЙТОВАННЫЙ mapper: при выключенном
                                                    // DivMMC дешифрация прежняя байт-в-байт.
                                                    // 3) !m1 в защёлку #E3 НЕ добавлен: у T80 m1
                                                    // активен НУЛЁМ, терм убил бы порт совсем.
    // (было B0129) // B0121: тонкий бордюр Пентагона (video.v)
    // (было B0120) // ОБЪЁМ ОЗУ опцией (MACHINE_CFG [15:14]):
                                                    // старшие биты 7FFD игнорируются, а НЕ блокируют
                                                    // страничность - иначе софт, пишущий 7FFD=0x20,
                                                    // замораживает окно (Wild Player). // // GS: бит7 порта #BB значит РОВНО «у карты
                                                    // есть байт» (было ИЛИ с «очередь полна» - два
                                                    // смысла на одном бите, и плеер читал наше
                                                    // «занято» как «пришёл ответ»). Обратное
                                                    // давление ушло в ТАКТЫ ОЖИДАНИЯ на шине со
                                                    // сторожем 148 мс; прибор считает потерянные
                                                    // БАЙТЫ и цену удержаний (0x194/0x198).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0118; // GS: ОБРАТНОЕ ДАВЛЕНИЕ на потоке #B3.
                                                    // «Занято» (бит7 в #BB) поднимается по
                                                    // верхнему порогу (96 из 128, резерв 32 под
                                                    // записи без опроса флага), а не по полноте:
                                                    // гость ждёт сам, и байт больше не теряется.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0117; // NEMO-IDE: DRQ снимает ФАБРИКА по факту
                                                    // вычерпывания блока (было - словом состояния
                                                    // от ARM, и в эту щель машина успевала
                                                    // прочитать начало старого буфера: 105 и 87
                                                    // битых байт в двух прогонах). Между блоками
                                                    // машина видит BSY. LOAD_CAPS бит7.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0116; // Мышь Kempston (#FADF/#FBDF/#FFDF):
                                                    // порты в фабрике, координаты считает ARM
                                                    // по цифровой клавиатуре. LOAD_CAPS бит6.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0115; // NEMO-IDE: ARM пишет регистры ATA (сигнатура
                                                    // после 0x90 и геометрия 0x91), в stat2 вместо
                                                    // дубля LBA0 - счётчик секторов.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0114; // NEMO-IDE: поля слова состояния выровнены,
                                                    // наружу полный LBA и признак slave.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0112; // NEMO-IDE: трап портов в машине, регистры
                                                    // 0x184/0x188, «диск» на ARM. Выключен, пока
                                                    // оболочка не поднимет бит разрешения.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0111; // READ TRACK (0xE): дорожка синтезируется
                                                    // пофазно, данные секторов идут штатной
                                                    // выборкой. Без неё быстрый загрузчик
                                                    // Z-Player говорил UNKNOWN DISK FORMAT.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0110; // Извлечение из FIFO гейтится тем же признаком
                                                    // «пусто», который ушёл в данные: байт, пришедший
                                                    // в окно между защёлкиванием и импульсом, пропадал
                                                    // бесследно (71 потеря на 22 КБ потока модуля).
                                                    // Болезнь общая с клавиатурным FIFO.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0109; // GS: упругая очередь записей #B3 (32 байта) -
                                                    // X-Player пишет байт на границе страницы БЕЗ
                                                    // опроса флага (~7 мкс), и каждый 256-й терялся.
                                                    // Плюс всё из B0107 (см. ниже).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0108; // то же, но очередь 256 и точный пик-метр:
                                                    // ПРОВАЛИЛ setup пиксельного домена (-0.223 нс),
                                                    // на плату не ставился.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0107; // GS: флаг ОДИН, хозяин - карта. Фабрика
                                                    // ЗЕРКАЛИТ состояние эмулятора (было: снимала
                                                    // флаг за него, и софт вис на ожидании). Плюс
                                                    // суммирование ARM-ноги с машиной (0x78 бит1)
                                                    // и свой пик-метр 0x17C.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0106; // Подтверждение GS переходит ТОГГЛОМ:
                                                    // импульс терялся между доменами.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0105; // Ловушка портов General Sound: #BB и #B3,
                                                    // свой блок регистров 0x174 / 0x178.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0104; // Полярность make исправлена: гейт подавляет
                                                    // навигатора: зажатая клавиша не действует.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0102; // Гейт OSD больше не блокирует ОТПУСКАНИЯ:
                                                    // клавиша не может залипнуть в машине.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0101; // МАГИЧЕСКАЯ КНОПКА: сервисная страница
                                                    // ПЗУ по NMI, снятие по RETN (бит13).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0100; // Диапазон записи сбрасывается и по
                                                    // началу подачи блока - закрыта
                                                    // многосекторная запись.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0099; // Force Interrupt: бит I3 поднимает
                                                    // INTRQ (TR-DOS 5.03 на повторном CAT).
//  localparam [31:0] BUILD_VERSION = 32'hB01B0098; // БЫСТРЫЙ ДИСКОВОД: оборот 10 мс
                                                    // вместо 200, темп байта 4.6 мкс вместо 32,
                                                    // + снятие фантомных запросов к хосту.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0097; // ЗАПИСЬ: фабрика сообщает ДИАПАЗОН
                                                    // записанных машиной байт - ARM собирает
                                                    // сектор из файла, а не из буфера.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0096; // В кольцо вернулись дорожка и
                                                    // сектор последней команды.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0095; // ЗАПИСЬ: устранено расхождение с
                                                    // эталоном MiSTer - номер сектора для
                                                    // Read Address теперь задаёт процессор.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0094; // ЗАПИСЬ ПО ПОСТРОЕНИЮ: своя
                                                    // исходящая память сектора в обвязке +
                                                    // настоящий провод записи процессора.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0093; // Замер АДРЕСОВ буфера:
                                                    // {sd_block, byte_addr} в слово вычитывания.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0092; // Замер записи: счётчик срабатываний
                                                    // wren_b (запись процессора в буфер) плюс
                                                    // buff_wr в кольце. Факт вместо рассуждения.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0091; // Ethernet процессора НАСКВОЗЬ к ногам PHY:
                                                    // GEM0 через EMIO проводами (MII + MDIO +
                                                    // опорные 25 МГц на U18). Логики почти нет:
                                                    // 2 тактовых буфера и 2 триггера делителя.
//  localparam [31:0] BUILD_VERSION = 32'hB01B0090; // Кольцо BDI инструментировано под разбор
        // ЗАПИСИ: в word1 вместо дорожки/сектора идёт состояние контроллера
        // {data_length[10:0], DRQ, BUSY, lost_data, write_fault, write_data}, а повторные записи
        // в #FF больше не вытесняют историю команды из 12 слотов (не больше двух на команду).
        // читаемым хостом (провод sd_buff_din раньше выбрасывался). FDC_CTL бит11 = режим
        // вычитывания: строб FDC_DATA шагает адресом не записывая, FDC_STAT2 отдаёт
        // {адрес[8:0], байт[7:0]} вместо отладочного кольца.
        // +20.3 цента, замерено в xsim; арифметика чипа при этом верна) + машинно-агностичный
        // слот 0x170 AUD_DBG: пики по источникам {SAA, AY2, AY1, SpecDrum, бипер}.
        // заглушка saa.v, перекрывавшая saa1099.sv) + арбитраж порта #FF между SAA и Beta Disk
        // по ЖИВОЙ активности дисковода, опция машины MACHINE_CFG [12:11] AUTO/ON/OFF
        // + селект чипа TurboSound как в эталоне (#F8..#FF, а не по одному биту d[4]).
`endif

    /* CE29/B0066: ИДЕНТИЧНОСТЬ ЯДРА отдельно от версии сборки. Схема слова:
       [15:0] семейство ASCII ('ZX'=0x5A58, 'NE'=0x4E45, будущий 'C6'=0x4336),
       [23:16] вариант (0x80 = 128K, 0x48 = 48K, 0x4D = MiSTer-48, 0x50 = Пентагон),
       [31:24] резерв. Прошивка спрашивает МАШИНУ, кто она (0x60), а VERSION снова означает версию. */
`ifdef MISTER48_CORE
    localparam [31:0] MACH_ID = 32'h004D5A58;   // 'ZX' + вариант 'M' (MiSTer-48)
`else
    localparam [31:0] MACH_ID = 32'h00805A58;   // 'ZX' + вариант 128K (Atlas; 48K/Пентагон - тот же бит)
`endif
    control_plane #(
        .VERSION(BUILD_VERSION), .MACHINE_ID(MACH_ID), .LOAD_CAPS_P(LOAD_CAPS_SEL),
        .POR_BITS(4), .WAIT_HDMI_LOCK(0),          // the legacy ZX POR shape, byte-identical
        .CAP_W(384), .CAP_H(302), .CAP_BPP(4), .CAP_LEADIN_AUTO(0),
        .WR_WORDS(7248),                            // 384*302/16 words per frame
        .KICK_CORE_VSYNC(0),                        // buffer swap on the HDMI vblank (proven ZX path)
        .SRC_W(384), .STRIDE(384), .CROP_W(384), .CROP_H(302), .HMARGIN(256), .VMARGIN(58), .SX0(0),
        .SRC_BPP(4), .WSH(4), .LBPP(2), .FBURSTS(3),
        .LIVE_CROP(1),                              // CROP_A/B registers trim the ZX window
        .AUDIO_DC_BLOCK(1),                         // the ZX post-volume HPF
        .PS2_INT_CE(0),                             // keyboard decoded on spclk/pe3M5 (matrix feed)
        .PS2TX_INHIBIT(8000), .PS2TX_TIMEOUT(500000)
    ) shell (
        .eth_txd(eth_txd), .eth_tx_en(eth_tx_en), .eth_tx_clk(eth_tx_clk),
        .eth_rxd(eth_rxd), .eth_rx_dv(eth_rx_dv), .eth_rx_clk(eth_rx_clk),
        .eth_mdc(eth_mdc), .eth_mdio(eth_mdio), .eth_ref_clk(eth_ref_clk),
        .TMDS_Clk_p(TMDS_Clk_p), .TMDS_Clk_n(TMDS_Clk_n),
        .TMDS_Data_p(TMDS_Data_p), .TMDS_Data_n(TMDS_Data_n),
        .ps2_clk(ps2_clk), .ps2_data(ps2_data),
        .led_heart(led_heart),
        .fclk100_o(fclk100), .clk_pixel_o(clk_pixel), .clk_audio_o(clk_audio_r),
        .aresetn_o(aresetn), .core_resetn_o(core_resetn_unused),
        .ext_lock_i(1'b1),
        // machine video (spclk domain)
        .cap_clk_i(spclk), .cap_rstn_i(por_n), .cap_ce_i(pe7M0),
        .cap_hsync_i(vid_hsync), .cap_vsync_i(vid_vsync), .cap_blank_i(vid_blank),
        .cap_r_i(vid_r), .cap_g_i(vid_g), .cap_b_i(vid_b), .cap_i_i(vid_i),
        .cap_pix8_i(8'd0),
        // machine audio (the ZX leg + crossfade + tape click, computed below)
        .aud_src_l_i(src_left), .aud_src_r_i(src_right),
        .player_pcm_o(player_pcm), .player_gain_o(pgain), .machine_gain_o(mgn),
        // PS/2 decoded on the machine clock (feeds the Z80 matrix through the gate below)
        .kclk_i(spclk), .kce_i(pe3M5),
        .ps2_strb_o(ps2_strb), .ps2_make_o(ps2_make), .ps2_code_o(ps2_code),
        // B0070: расширенные банки Пентагона 1024 ходят в PS DDR через этот мастер. Запросы -
        // в такте машины (spclk), ответ возвращается вместе с ожиданием, которое гасит процессор.
        .mem_mclk_i(spclk), .mem_addr_i(zxddr_addr), .mem_wdata_i(zxddr_wdata),
        .mem_rd_i(zxddr_rd), .mem_wr_i(zxddr_wr),
        .mem_rdata_o(zxddr_rdata), .mem_wait_o(zx_mem_wait),
        .mach_dbg_i(zx_mach_dbg),
        .rom_dbg_i (rom_dbg_core),        // B0147 -> 0x1BC ROM_DBG
        .aud_dbg_i (zx_aud_dbg),
        .ps2tx_busy_o(ps2tx_busy), .ps2_diag_o(cp_ps2_diag),
        .ctl_quiesce_o(), .mach_axi_idle_i(1'b1),
        .wr_accept_cnt_o(), .cap_fifo_ov_o(), .ld_live_o(),
        // machine registers
        .ctl_halt_o(ctl_halt), .ctl_ram_we_o(ctl_ram_we),
        .ctl_ram_addr_o(), .ctl_ram_waddr_o(ctl_ram_waddr), .ctl_ram_data_o(ctl_ram_data),
        .ctl_dir_o(ctl_dir), .ctl_7ffd_o(ctl_7ffd), .ctl_border_o(ctl_border),
        .ctl_dir_commit_o(ctl_dir_commit), .ctl_port_commit_o(ctl_port_commit), .ctl_reset_o(ctl_reset),
        .ctl_osd_enable_o(ctl_osd_enable), .ctl_ddr_osd_en_o(ctl_ddr_osd_en),
        .ctl_tape_run_o(ctl_tape_run), .ctl_tape_earmux_o(ctl_tape_earmux), .ctl_tape_mute_o(ctl_tape_mute),
        .ctl_tape_fmode_o(ctl_tape_fmode), .ctl_tape_sync_o(ctl_tape_sync), .ctl_tape_more_o(ctl_tape_more),
        .ctl_tape_we_o(ctl_tape_we), .ctl_tape_data_o(ctl_tape_data),
        .ctl_kbd_inject_o(ctl_kbd_inject), .ctl_kbd_inject_we_o(ctl_kbd_inject_we),
        .kbd_deadman_kick_o(kbd_deadman_kick),
        .ctl_pentagon_o(ctl_pentagon), .ctl_model48_o(ctl_model48), .ctl_ula_late_o(ctl_ula_late),
        .ctl_force_atlas_o(ctl_force_atlas), .ctl_snow_off_o(ctl_snow_off),
        .ctl_mach_cfg_o(mach_cfg_w), .ctl_pent_int_o(ctl_pent_int),   // B0071: бит5 = трап TR-DOS
        // B0071: заливка ПЗУ машины с карты (0x154/0x158/0x15C)
        .ctl_fdc_ctl_o(fdc_ctl_a), .ctl_fdc_ctl_we_o(fdc_ctl_we_a),
        .ctl_fdc_data_o(fdc_data_a), .ctl_fdc_data_we_o(fdc_data_we_a), .fdc_stat_i(fdc_stat_w),
        .ctl_gs_ctl_o(gs_ctl_a), .ctl_gs_ctl_we_o(gs_ctl_we_a), .gs_stat_i(gs_stat_w),   // General Sound
        .gs_stat2_i(gs_stat2_w), .gs_stat3_i(gs_stat3_w),   // B0119: прибор обратного давления
        .ctl_nemo_o(nemo_ctl_a), .ctl_nemo_we_o(nemo_ctl_we_a), .nemo_stat_i(nemo_stat_w), .nemo_stat2_i(nemo_stat2_w),
        .ctl_dmmc_o(dmmc_ctl_a), .ctl_dmmc_we_o(dmmc_ctl_we_a), .ctl_dmmc_cap_o(dmmc_cap_a),
        .ctl_dmmc_bufa_o(dmmc_bufa_a), .ctl_dmmc_bufa_we_o(dmmc_bufa_we_a),
        .ctl_dmmc_bufw_o(dmmc_bufw_a), .ctl_dmmc_bufw_we_o(dmmc_bufw_we_a),
        .ctl_dmmc_bufr_re_o(dmmc_bufr_re_a),
        .dmmc_bufa_i(dmmc_bufa_q_w), .dmmc_bufr_i(dmmc_bufr_q_w), .dmmc_stat_i(dmmc_stat_w),
        .dmmc_lba_i(dmmc_lba_w), .dmmc_dbg_i(dmmc_dbg_w),
        .ctl_kmouse_o(km_ctl_a), .ctl_kmouse_we_o(km_ctl_we_a),   // B0116 мышь Kempston (0x190)
        .gs_rq_dout_i(gs_rq_dout), .gs_rq_empty_i(gs_rq_empty), .gs_rq_cnt_i(gs_rq_cnt),
        .gs_rq_rd_o(gs_rq_rd),                  // B0108: очередь данных GS (0x180)
        .fdc_stat2_i(fdc_stat2_w),
        .ctl_rom_ld_addr_o(rom_ld_addr_a), .ctl_rom_ld_data_o(rom_ld_data_a),
        .ctl_rom_ld_we_o(rom_ld_we_a), .ctl_rom_loading_o(rom_loading_a),
        .ctl_paper_h_o(ctl_paper_h), .ctl_paper_v_o(ctl_paper_v),
        .ctl_joy_o(ctl_joy),
        .ctl_warp_hold_o(ctl_warp_hold), .ctl_sync_hold_o(ctl_sync_hold),
        .ctl_romtrap_en_o(ctl_romtrap_en), .ctl_romtrap_done_we_o(ctl_romtrap_done_we),
        .ctl_scr_raddr_o(scr_bram_raddr),
        // machine status
        .scr_rdata_i(scr_rdata_r),
        .tape_full_i(tape_full), .tape_playing_i(tape_playing_a),
        .tape_diag_count_i(tape_diag_count_a1), .tape_diag_hash_i(tape_diag_hash_a1),
        .tape_diag_gaps_i(tape_diag_gaps_a1), .tape_diag_resumes_i(tape_diag_res_a1),
        // B0053 diagnostic bit: REG4..REG6 are temporarily the 48K INT/ULA sweep trace.
        .fe_trace_count_i(int_dbg0_a1), .fe_trace_hash_i(int_dbg1_a1), .fe_trace_last_i(int_dbg2_a1),
        .halt_ack_i(halt_ack), .ram_busy_i(ram_busy), .reset_busy_i(reset_busy_aclk),
        .rt_pending_a_i(rt_pending_a), .p7ffd_s1_i(p7ffd_s1), .reg_rd1_i(reg_rd1),
        .sync_diag_i(sync_diag_a),
        .memwr_cnt_i(memwr_sync),
        .kbd_diag_i(cp_ps2_diag)                    // the PS/2 {resend,perr} counters, looped back
    );
    inject_cdc inj_i (
        .aclk(fclk100), .aresetn(aresetn), .spclk(spclk),
        .ctl_halt(ctl_halt), .ctl_ram_we(ctl_ram_we),
        .ctl_ram_addr(ctl_ram_waddr), .ctl_ram_data(ctl_ram_data),
        .ctl_dir_commit(ctl_dir_commit), .ctl_port_commit(ctl_port_commit),
        .ctl_dir(ctl_dir), .ctl_7ffd(ctl_7ffd), .ctl_border(ctl_border),
        .halt_ack(halt_ack), .ram_busy(ram_busy),
        .cpu_halt_sp(cpu_halt_sp),
        .arm_memWr(arm_memWr), .arm_memA(arm_memA), .arm_memQ(arm_memQ), .arm_vmmA2(arm_vmmA2),
        .dir_set_sp(dir_set_sp), .cpu_dir_sp(cpu_dir_sp),
        .force_7ffd_sp(force_7ffd_sp), .port7ffd_sp(port7ffd_sp),
        .force_border_sp(force_border_sp), .border_sp(border_sp),
        .ctl_reset(ctl_reset), .arm_reset_sp(arm_reset_sp),
        .reset_busy_sp(reset_busy_sp), .reset_busy(reset_busy_aclk)
    );
    // HALT = gate the two 3.5 MHz CPU clock-enables into the core (no Atlas-core edit).
    // ---- FAST LOAD: two selectable modes (owner), active only while a tape is running (never in-game):
    //   FAST (mode 1) = CPU-only 8x (28.35 MHz, T80pa ceiling CLK/2). Fastest; works for most loaders
    //         incl. many custom (like MiSTer). Video/audio stay normal. Rare timing-critical titles
    //         (border FX, some TZX pauses) can break -> use SAFE or realtime.
    //   SAFE (mode 2) = whole-core 4x via clock_zx.warp (CPU+ULA+contention+tape all 4x in lock-step).
    //         Bulletproof (all ratios preserved); half the speed of FAST; screen flickers during load.
    // The tape (t_en=pe3M5_core) is locked to the CPU enable in BOTH modes, so pulse ratios hold.
    (* ASYNC_REG="TRUE" *) reg [1:0] fm_s0 = 2'd0, fm_s1 = 2'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] tsync_s = 2'b00;
    wire rom_trap_core;     // passive PC=0x056B qualifier; trapping itself still requires ROMTRAP enable
    wire tape_sync_rom;     // stream-aligned descriptor metadata from tape_player
    wire tape_block_start;  // first descriptor of a new logical tape block was loaded
    always @(posedge spclk) begin
        fm_s0 <= ctl_tape_fmode; fm_s1 <= fm_s0;
        tsync_s <= {tsync_s[0], ctl_tape_sync};
    end
    // Core outputs are declared before the load-state machinery below because
    // the sampling detector consumes the core's actual IN-FE signals.
    wire tape_sample;
    wire tape_sample_strobe, tape_di_bit;
    wire cpu_ten_sp;
    // SAMPLING DETECTOR (frequency-based, measured in CPU T-STATES so it is warp-INDEPENDENT):
    // the ROM/turbo loader reads port 0xFE in a TIGHT edge-timing loop (~every 13 T-states). A
    // border/multicolour effect ALSO reads 0xFE (floating-bus raster sync) but only ~once per scanline
    // (~224 T). Counting the interval in T-states (pe3M5_core ticks) cleanly separates them at ANY
    // speed. "sampling_active" = a TIGHT burst of reads = the loader is actively loading. This stops
    // warp from lingering at 8x into the post-load border effect (the bug: FAST broke the timing-exact
    // Pentagon border while 1x/4x passed - the effect's sparse FE reads were mis-counted as loading).
    (* ASYNC_REG="TRUE" *) reg tsmp_s0 = 1'b0, tsmp_s1 = 1'b0, tsmp_s2 = 1'b0;
    always @(posedge spclk) begin tsmp_s0 <= tape_sample; tsmp_s1 <= tsmp_s0; tsmp_s2 <= tsmp_s1; end
    wire smp_edge = tsmp_s1 & ~tsmp_s2;                    // one pulse per port-FE read
    reg [11:0] smp_tgap  = 12'hFFF;                        // CPU T-states since last FE read (saturating)
    reg        smp_tight = 1'b0;                           // last inter-read interval was tight (loader loop, not a per-line border read)
    always @(posedge spclk) begin
        if (smp_edge) begin
            smp_tight <= (smp_tgap < 12'd64);              // < 64 T apart -> a loader edge-loop (~13 T); a border read is ~224 T
            smp_tgap  <= 12'd0;
        end else if (cpu_ten_sp && smp_tgap != 12'hFFF) smp_tgap <= smp_tgap + 12'd1;   // tick in REAL CPU T-states (pc3M5, contention-aware) - warp-independent AND matches the loader's own timing on 128K (contended). Fixes the 128K SYNC distortion (pe3M5 over-counted during contention -> false sampling drops).
    end
    // EDGE-CORRELATED detection: catches once-per-bit / timing-loop custom loaders (e.g. Letris part 2)
    // that read FE only ~once per bit (~1000 T) - the tight-<64T test above misses them, so warp used to
    // drop to 1x after the first (ROM-loaded) part. Insight: while LOADING, every FE read follows a TAPE
    // signal edge (the loader tracks the tape). A post-load border effect reads FE with NO tape edges
    // (the tape has finished) -> not correlated. So: warp when FE reads correlate with recent tape edges,
    // at ANY read rate. Border-safe (tape done -> no edges), countdown-safe (no reads -> decays off).
    reg tear_s0 = 1'b0, tear_s1 = 1'b0;
    always @(posedge spclk) begin tear_s0 <= tape_ear; tear_s1 <= tear_s0; end
    wire tape_edge = tear_s0 ^ tear_s1;                        // a tape signal transition (edge)
    reg [11:0] edge_age = 12'hFFF;                             // CPU T-states since the last tape edge (saturating)
    always @(posedge spclk) begin
        if (tape_edge) edge_age <= 12'd0;
        else if (cpu_ten_sp && edge_age != 12'hFFF) edge_age <= edge_age + 12'd1;
    end
    wire corr_read = smp_edge & (edge_age < 12'd2048);         // this FE read observed a recent tape edge -> the CPU is tracking the tape
    reg [11:0] corr_age = 12'hFFF;                             // T-states since the last correlated read
    always @(posedge spclk) begin
        if (corr_read) corr_age <= 12'd0;
        else if (cpu_ten_sp && corr_age != 12'hFFF) corr_age <= corr_age + 12'd1;
    end
    wire edge_corr_active = (corr_age < 12'd1024);             // correlated reads still flowing
    wire sampling_active = (smp_tight & (smp_tgap < 12'd256)) | edge_corr_active;   // SUPERSET: tight poll OR edge-correlated (once-per-bit) - keeps the proven tight-loop behaviour, adds slow custom loaders
    // WARP_HOLD tuner (0xDC): idle-release timeout in CPU T-states. Multi-bit, changes rarely -> 3-FF +
    // settle-latch (the PENT_INT / osd_pos idiom). 0 = never idle-release (hold until the tape-run bit clears).
    (* ASYNC_REG="TRUE" *) reg [31:0] whold_s1 = 32'd0, whold_s2 = 32'd0, whold_s3 = 32'd0;
    reg [31:0] warp_hold_ts = 32'd0;
    always @(posedge spclk) begin
        whold_s1 <= ctl_warp_hold; whold_s2 <= whold_s1; whold_s3 <= whold_s2;
        if (whold_s2 == whold_s3) warp_hold_ts <= whold_s2;
    end
    // CONTINUOUS / LATCHED WARP (fixes the intra-load 8x jitter). The detector above proves we are inside
    // a loader, but `sampling_active` toggles ON/OFF per FE-read window (~1024T corr decay + the gaps
    // between the loader's reads and between blocks). Gating warp on that instantaneous window makes the
    // CPU speed flap 8x<->1x DURING a load; the timebase jitter occasionally mis-samples one bit -> the
    // loader checksum fails -> hang (~50% at 8x). FIX: once loading is CONFIRMED (detector fires during an
    // active tape run with a warp fmode), LATCH warp ON and hold it CONTINUOUSLY across every read / bit /
    // inter-block gap. Release only at the TRUE end: the ARM clears the tape-run bit (authoritative EOT),
    // OR no tape edge AND no FE read for warp_hold_ts CPU T-states (a generous idle watchdog, re-armed on
    // EVERY edge/read - orders of magnitude longer than the old 1024T, so once-per-bit loaders (Letris)
    // and normal inter-block processing never drop it). Steady 8x = zero toggling jitter; and because the
    // tape advance (tape_advance = pe3M5_core) is locked to the warped CPU enable, the pulse-to-T-state
    // ratio is IDENTICAL to 1x for the whole load. Guarded by trun_s[1] & a warp fmode, so a running game
    // (no tape) is NEVER warped.
    wire warp_fmode     = (fm_s1 == 2'd1) | (fm_s1 == 2'd2) | (fm_s1 == 2'd3); // FAST(1), SAFE(2), WAV AUTO(3)
    wire warp_guard     = trun_s[1] & warp_fmode;                          // tape running AND a warp mode chosen
    // 🥇 ВАРП ОТПУСКАЕТСЯ, КОГДА ЛЕНТА МОЛЧИТ (B0128; жалоба владельца 12.08 на SHOCK.TAP).
    //
    // Симптом: демка с порционной загрузкой просит нажать пробел, чтобы продолжить, и вместо
    // продолжения выходит BREAK - у владельца получалось раз из десяти и только очень быстрым
    // тычком. Виноват был не пробел и не матрица, а варп, который не отпускался ВСЮ демо-часть.
    //
    // Разбор самой демки (SHOCK.TAP, ESI'92, стандартный загрузчик ПЗУ, 20 блоков). Часть отдаёт
    // управление по пробелу мгновенно - `LD A,$7F / IN A,($FE) / RRA / JP C,.. / IM 1 / EI / RET`,
    // ни одного такта на отпускание. Весь запас владельца - это то, что успевает сделать машина
    // между отпусканием и первым чтением BREAK внутри LD-EDGE-1: в shock.0 два раза HALT и два раза
    // полная очистка экрана (LDIR по 6911 байт = ~41 мс каждая), потом BASIC c четырьмя VAL, STR$ и
    // печатью строки. На живой машине это около 120 мс - нормальный человеческий тычок проходит.
    //
    // У нас этот запас складывался ВОСЬМЕРО, потому что процессор всё это время шёл на 8x. Почему
    // варп не отпускался: сторож простоя перевзводился по `smp_edge` - ЛЮБОМУ чтению порта FE. А
    // демо-часть опрашивает пробел раз в кадр (~70000 тактов) при пороге отпускания 0x200000
    // (~2.1 млн тактов, 0xDC WARP_HOLD), то есть перевзводила сторож вечно. Детектор ЗАХВАТА при
    // этом давно поумнел (плотный цикл ИЛИ корреляция с краями ленты), а сторож ОТПУСКАНИЯ остался
    // грубым - и умный детектор решал только, когда варп включить, а выключить не давал никогда.
    //
    // Правило теперь одно на оба конца: чтение FE считается признаком загрузки, только если оно
    // идёт следом за краем ленты (`corr_read`, тот же критерий, что уже у захвата). Во время
    // загрузки каждое чтение таково по построению - для лент не меняется НИЧЕГО; при замершей
    // ленте (SYNC держит поток между блоками) краёв нет вовсе, и варп честно уходит по сторожу.
    //
    // И захват тоже требует живой ленты: `smp_tight` сам по себе ловил бы демку, которая крутит
    // пробел в плотном цикле, - тогда варп включился бы вообще без ленты. `tape_alive` = край был
    // не дальше 4095 тактов назад (~1.2 мс); на любой настоящей ленте это всегда правда.
    wire tape_alive     = (edge_age < 12'hFFF);                            // край ленты был недавно (12'hFFF = счётчик насыщен = краёв нет)
    wire load_confirmed = warp_guard & sampling_active & tape_alive;       // detector fired -> we are inside a loader
    wire load_activity  = tape_edge | corr_read;                           // край ленты ИЛИ чтение FE ВСЛЕД за краем = всё ещё грузимся
    // FAST is CPU-only: ULA/INT remain at their native clock.  Standard ROM
    // blocks can be separated by a 0/1-ms recorded pause, which is eight times
    // shorter in wall time while FAST is active.  Critical Mass then consumes an
    // exact stream but returns to BASIC at EOT.  The proven safe contract is the
    // existing PC=056B demand gate.  FAST therefore enables that gate
    // automatically for *marked standard-ROM blocks*.  Raw SYNC still controls
    // the same gate at 1x/SAFE; turbo/custom descriptors, WAV and MP3 are
    // unmarked and remain continuous at their requested speed.
    wire sync_effective = tsync_s[1] | (fm_s1 == 2'd1);
    // B0045 WAV-AUTO, selected only by the otherwise-unused fmode=3 via JTAG.
    // B0044's ROM->RAM handoff worked for EXOLON/ARKANOID2 but IK+'s animated
    // ROM phase already depends on native ULA/INT timing.  Therefore mode3 is
    // whole-core SAFE4 from the START of a WAV tape.  This is deliberately the
    // reliable policy, not a false claim of CPU-only 8x; modes 1/2 and all
    // existing TAP/TZX/MP3 semantics remain unchanged.
    reg cpuw_active = 1'b0;
    reg wav_auto_pending = 1'b0, wav_auto_safe = 1'b0;
    wire wav_auto_ram_pc = (cpu_reg_sp[79:64] >= 16'h4000);
    always @(posedge spclk) begin
        if (!trun_s[1] || (fm_s1 != 2'd3)) begin
            wav_auto_pending <= 1'b0;
            wav_auto_safe <= 1'b0;
        end else begin
            if (!wav_auto_pending && !wav_auto_safe)
                wav_auto_pending <= 1'b1;
            if (wav_auto_pending && !cpuw_active) begin
                wav_auto_pending <= 1'b0;
                wav_auto_safe <= 1'b1;
            end
        end
    end
    reg  [23:0] warp_idle  = 24'hFFFFFF;                                   // CPU T-states since the last load activity (saturating)
    reg         warp_latch = 1'b0;
    reg         warp_eot_done = 1'b0;                                      // B0046: ARM RUN cleanup must not re-arm SAFE4 after genuine player EOT
    wire        warp_idle_to = (warp_hold_ts != 32'd0) & ({8'd0, warp_idle} >= warp_hold_ts);  // idle watchdog fired (0 = never)
    always @(posedge spclk) begin
        if (!warp_guard) begin
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
            warp_eot_done <= 1'b0;
        end else if (tape_eot_safe) begin                                  // B0046: explicit SAFE4 returns to native time at local player EOT
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
            warp_eot_done <= 1'b1;
        end else if (warp_eot_done) begin                                  // ARM still owns RUN for CDC/polling, but may never re-arm post-EOT warp
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
        end else begin
            if (load_activity) warp_idle <= 24'd0;                         // re-arm the idle watchdog on every edge / FE read
            else if (cpu_ten_sp && warp_idle != 24'hFFFFFF) warp_idle <= warp_idle + 24'd1;
            /* B0046 A/B: explicit SAFE4 starts before the first descriptor,
               not halfway through the pilot when FE sampling is first seen.
               Keep FAST and WAV-AUTO policies untouched; this isolates the
               whole-core clock-transition hypothesis without changing any
               tape word or EAR level. */
            if      (fm_s1 == 2'd2) warp_latch <= 1'b1;
            else if (load_confirmed) warp_latch <= 1'b1;                   // confirmed loading -> hold warp ON
            else if (warp_idle_to)   warp_latch <= 1'b0;                   // long idle -> the load really ended
        end
    end
    // Gate the warp clock-enables on the HELD latch (not the instantaneous sampling window). warp_latch
    // already implies trun_s[1] & a warp fmode (set only under warp_guard, forced 0 the cycle it drops).
    // B0048 restores the original whole-core 4x fmode=2 path and adds a
    // passive IN-FE trace.  B0047's whole2 PASS is retained as evidence;
    // this build compares 1x and 4x guest-observed reads without touching
    // descriptors or EAR routing.
    assign warp_safe2_active = 1'b0;
    assign warp_active = ((fm_s1 == 2'd2) | ((fm_s1 == 2'd3) & wav_auto_safe)) & warp_latch;
    // 🥇 ПОКА ЖДЁМ СЛЕДУЮЩИЙ БЛОК - МАШИНА ИДЁТ В РОДНОМ ТЕМПЕ (B0129, идея владельца).
    //
    // `warp_latch` отвечает на вопрос «мы внутри загрузки» и обязан держаться ЧЕРЕЗ паузы: гейт по
    // мгновенному окну детектора когда-то давал дребезг 8x<->1x ПОСРЕДИ блока, один бит читался мимо,
    // и загрузка вешалась примерно в половине попыток. Поэтому латч не трогаем.
    //
    // Но у нас есть точный ответ на ДРУГОЙ вопрос - «лента прямо сейчас движется»: это тот самый
    // предикат, которым гейтится `tape_advance`. При демандовой ленте (SYNC) между блоками поток
    // заморожен: `sync_state` стоит в SYNC_WAIT с уже взведённым дескриптором пилота, `sync_hold`
    // снят - и машина в это время не грузится, а работает своим кодом. Разгонять её там незачем.
    //
    // Что это чинит: у демок с порционной загрузкой окно на ОТПУСКАНИЕ пробела перестаёт сжиматься.
    // На SHOCK.TAP между частями лежит ~120 мс (два HALT и две очистки экрана LDIR по 6911 байт в
    // shock.0 плюс BASIC); под 8x оставалось ~30 мс, и пробел, которым владелец продолжал демку,
    // ещё был нажат, когда ПЗУ начинало читать BREAK тем же полурядом. Сторож простоя (правка ниже
    // по `corr_read`) отпускал варп только через 600 мс тишины - здесь же отпускание МГНОВЕННОЕ и
    // детерминированное, потому что момент конца блока мы ЗНАЕМ, а не угадываем.
    //
    // Почему это безопасно: `sync_hold` меняется ТОЛЬКО на границе блока (`tape_block_start`), внутри
    // блока SYNC_ACTIVE держит его поднятым - «never truncate a started block». То есть скорость
    // меняется ровно тогда, когда лента заведомо стоит, а не между двумя чтениями бита. Плюс сама
    // смена уже защёлкивается на границе такта (`if (ne_sel) cpuw_active <= cpuwarp_req`).
    //
    // Область действия узкая и намеренно: только процессорный FAST (fmode=1) на ПОМЕЧЕННЫХ
    // стандартных блоках ПЗУ. Турбо и кастомные загрузчики идут с `tape_sync_rom`=0 или в
    // SYNC_CUSTOM - у них `tape_streaming` всегда 1, поведение не меняется. Целоядерные режимы
    // (fmode 2/3, только через JTAG) НЕ трогаем: у них смена темпа тянет за собой ULA и видеотакт,
    // там есть рукопожатие `warp_ack`, и дёргать его на каждой границе блока незачем.
    wire cpuwarp_req   = ((fm_s1 == 2'd1) | ((fm_s1 == 2'd3) & ~wav_auto_pending & ~wav_auto_safe)) & warp_latch
                         & tape_streaming;
    // DEMAND TAPE (option SYNC LOADER): the ARM marks standard-ROM pulses with descriptor bit30.
    // Recorded pauses and all turbo/custom pulses are unmarked and always replay continuously.  At the
    // first marked pilot pulse we wait for the core's exact passive PC=0x056B fetch; arbitrary port-FE
    // reads made by a loading animation can therefore never creep the tape forward.
    // Keep the legacy SYNC_HOLD register synchronized for ABI/readback compatibility.  The old
    // heuristic used it to stop a block after a quiet interval; that could cut the final 1710-T
    // pulse in half.  Stream-aligned SYNC below deliberately runs a started block to its boundary.
    (* ASYNC_REG="TRUE" *) reg [31:0] shold_s1 = 32'd0, shold_s2 = 32'd0, shold_s3 = 32'd0;
    reg [31:0] sync_hold_ts = 32'd0;
    always @(posedge spclk) begin
        shold_s1 <= ctl_sync_hold; shold_s2 <= shold_s1; shold_s3 <= shold_s2;
        if (shold_s2 == shold_s3) sync_hold_ts <= shold_s2;
    end
    // Exact demand replay.  PC=056B is the ROM's LD-BYTES entry and is a much stronger request than
    // port-FE traffic: loading animations scan FE too, which made the former heuristic creep through
    // BigThings one fragment at a time.  Latch the request even BEFORE RUN (autostart reaches 056B
    // before the ARM starts the tape), consume it only at a marked standard block boundary, then run
    // the WHOLE block continuously.  Untagged recorded pauses and turbo/custom TZX always bypass SYNC.
    // A custom loader fed from a .TAP cannot be distinguished structurally on the ARM side, so a
    // conservative fallback recognizes a dense FE polling loop executing in RAM and makes the rest
    // of that tape continuous.  BigThings' animation is in ROM (PC 0x25xx), so it cannot trip this.
    localparam SYNC_WAIT=2'd0, SYNC_ACTIVE=2'd1, SYNC_CUSTOM=2'd2;
    reg  [1:0] sync_state = SYNC_WAIT;
    reg        sync_hold = 1'b0;
    reg        sync_rt_prev = 1'b0;
    reg        rom_pending = 1'b0;
    reg        consume_rom_pending = 1'b0;
    reg        sync_wait_popped = 1'b0;  // WAIT is holding an already-popped first pilot descriptor
    reg        sync_run_d = 1'b0;
    reg  [6:0] sync_fe_run = 7'd0;
    wire       sync_rt_rise = rom_trap_core & ~sync_rt_prev;
    wire       sync_guard = trun_s[1] & sync_effective;        // tape running AND explicit/FAST auto-SYNC selected
    wire       sync_ram_pc = (cpu_reg_sp[79:64] >= 16'h4000);   // T80 DIR word2 low half = live PC
    // LD-EDGE can retry PC=056B while a standard block is already playing.  Such a retry belongs to
    // the CURRENT LOAD and must never arm the following block (BigThings has a long animation between
    // BT.1 and BT.2, so a stale retry otherwise releases BT.2's header during the animation).
    wire       sync_req_eligible = !(sync_guard && (sync_state == SYNC_ACTIVE) && tape_sync_rom);

    // Request storage is deliberately independent of sync_guard.  A completed run clears stale
    // requests, but an as-yet-unstarted run keeps the request produced by zx_tape_autostart().
    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_rt_prev <= 1'b0; rom_pending <= 1'b0; sync_run_d <= 1'b0;
        end else begin
            sync_rt_prev <= rom_trap_core;
            sync_run_d <= trun_s[1];
            if (sync_run_d && !trun_s[1]) rom_pending <= 1'b0;
            else if (consume_rom_pending) rom_pending <= sync_rt_rise && sync_req_eligible;
            else if (sync_rt_rise && sync_req_eligible) rom_pending <= 1'b1;
        end
    end

    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_state <= SYNC_WAIT; sync_hold <= 1'b0;
            consume_rom_pending <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
        end else begin
            consume_rom_pending <= 1'b0;
            if (!sync_guard) begin
                sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
            end else if (sync_state == SYNC_CUSTOM) begin
                sync_hold <= 1'b1; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0; // continuous until RUN ends
            end else if (tape_block_start && tape_sync_rom) begin
                // The first descriptor has just been loaded but has not spent a T-state yet.  This
                // is therefore an exact, lossless place to stop before a following pause=0 block.
                if (rom_pending || (sync_rt_rise && sync_req_eligible)) begin
                    sync_state <= SYNC_ACTIVE; sync_hold <= 1'b1;
                    consume_rom_pending <= 1'b1; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
                end else begin
                    sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b1; sync_fe_run <= 7'd0;
                end
            end else if (!tape_sync_rom) begin
                sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0; // pause/custom bypasses below
            end else if (sync_state == SYNC_ACTIVE) begin
                sync_hold <= 1'b1; sync_fe_run <= 7'd0;       // never truncate a started block
            end else if (rom_pending || (sync_rt_rise && sync_req_eligible)) begin
                // If block_start already happened, the first pilot descriptor is busy/frozen and this
                // is a LATE grant: consume the request now.  Otherwise the descriptor is still at the
                // FWFT head; keep the request until its bit29 pulse confirms the pop next cycle.
                sync_state <= SYNC_ACTIVE; sync_hold <= 1'b1; sync_fe_run <= 7'd0;
                if (sync_wait_popped) begin consume_rom_pending <= 1'b1; sync_wait_popped <= 1'b0; end
            end else begin
                sync_hold <= 1'b0;
                if (smp_edge) begin
                    if (smp_tgap < 12'd2048) begin
                        // A keyboard/animation scan normally contains only 8..16 clustered reads.
                        // Requiring 64 consecutive reads preserves custom-TAP liveness (well within
                        // one 2168-T pilot pulse for a ~13-T polling loop) without permanently
                        // switching BigThings to continuous mode on a matrix-scan burst.
                        if (sync_fe_run != 7'h7F) sync_fe_run <= sync_fe_run + 7'd1;
                        if (sync_fe_run >= 7'd63 && sync_ram_pc) begin
                            sync_state <= SYNC_CUSTOM; sync_hold <= 1'b1;
                        end
                    end else sync_fe_run <= 7'd1;
                end
            end
        end
    end
    // Post-mortem SYNC diagnostics (retained after EOT): upper ROMTRAP readback bits expose whether
    // the custom fallback fired, the longest dense FE run, late-preloaded grants and block starts.
    reg sync_diag_run_d = 1'b0, sync_diag_custom = 1'b0;
    reg [6:0] sync_diag_fe_max = 7'd0;
    reg [3:0] sync_diag_late_grants = 4'd0, sync_diag_blocks = 4'd0;
    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_diag_run_d<=1'b0; sync_diag_custom<=1'b0; sync_diag_fe_max<=7'd0;
            sync_diag_late_grants<=4'd0; sync_diag_blocks<=4'd0;
        end else begin
            sync_diag_run_d <= trun_s[1];
            if (trun_s[1] && !sync_diag_run_d) begin
                sync_diag_custom<=1'b0; sync_diag_fe_max<=7'd0;
                sync_diag_late_grants<=4'd0; sync_diag_blocks<=4'd0;
            end else begin
                if (sync_wait_popped && (sync_state == SYNC_WAIT) &&
                    (rom_pending || (sync_rt_rise && sync_req_eligible)) && sync_diag_late_grants != 4'hF)
                    sync_diag_late_grants <= sync_diag_late_grants + 4'd1;
                if (tape_block_start && tape_sync_rom && sync_diag_blocks != 4'hF) sync_diag_blocks <= sync_diag_blocks + 4'd1;
                if (sync_fe_run > sync_diag_fe_max) sync_diag_fe_max <= sync_fe_run;
                if (sync_state == SYNC_CUSTOM) sync_diag_custom <= 1'b1;
            end
        end
    end
    wire [15:0] sync_diag_sp = {sync_diag_custom, sync_diag_fe_max,
                                sync_diag_late_grants, sync_diag_blocks};
    (* ASYNC_REG="TRUE" *) reg [15:0] sync_diag_s0 = 16'd0;
    always @(posedge fclk100) begin sync_diag_s0 <= sync_diag_sp; sync_diag_a <= sync_diag_s0; end
    /* B0046: mode2 cannot spend any initial descriptor ticks at the native
       rate while clock_zx is adopting /4.  FAST and WAV-AUTO retain their
       established paths; this is solely the whole-core SAFE4 A/B. */
    wire tape_warp_ready = (fm_s1 != 2'd2) | warp_ack;
    // UNDERRUN BACKPRESSURE: while the loader is actively sampling and the pulse FIFO has run dry,
    // FREEZE the CPU until the ARM (ISR, independent of this freeze) refills it. The loader counts in
    // T-states which are frozen too, so the next pulse lands on time in its own timebase -> no misread,
    // no gap reaches the machine. Fixes marginal MP3 8x underruns (and any format/rate). No deadlock:
    // the ISR pushes into the FIFO regardless of the CPU freeze.
    // TAIL FIX: sampling_active decays OFF exactly at the last-block boundary, so on its own it stops
    // protecting the very tail - a FIFO underrun there used to leak a stale edge into a still-running
    // turbo loader (deterministic ~95.5% hang at 8x). tmore_s[1] (TAPE_CTRL bit6, ARM-held "still
    // delivering the tape") keeps the freeze armed through the tail; the ARM drops it only once the
    // software ring is empty (nothing left to refill), so the final FIFO underrun = true EOT releases
    // the CPU into the running game. No deadlock: run/bit0 clears at EOT anyway, tmore is a superset.
    // PL3F isolation/fix: raw FIFO `empty` does NOT mean that the player needs data.  It asserts as
    // soon as the LAST descriptor is popped, while `busy` is still replaying that descriptor.  The
    // old expression froze pe/ne and tape_advance at that instant; COUNT/HASH were already complete,
    // but the last pulse never finished and the ARM's 3 s stuck backstop eventually cut it short ->
    // deterministic BigThings checksum 0:9 in both FAST8x and SAFE4x.  Step 14 had no starvation and
    // the 1024-entry FIFO showed zero real gaps in the hardware traces, so disable the broken path for
    // this A/B.  A future WAV/MP3 underrun guard must use an explicit player `need_data` handshake,
    // never raw `empty`, and must preserve the pe/ne phase while stopped.
    wire cpu_starve = 1'b0;
    // CPU-only 8x generator (FAST): pe on even master cycles, ne on odd (pe first) -> T-state per 2
    // cycles, t_en(=pe) once per T-state. Switch state ONLY right after an `ne` (T80pa CEN_pol=0,
    // between T-states) so the enable-source flip never leaves the handshake half-done.
    reg cpuw_tog = 1'b0;
    wire cw_pe = cpuw_active & ~cpuw_tog;
    wire cw_ne = cpuw_active &  cpuw_tog;
    wire pe_sel = cpuw_active ? cw_pe : pe3M5;              // pe3M5 = clock_zx output (normal in FAST, 4x in SAFE - but SAFE never sets cpuw_active)
    wire ne_sel = cpuw_active ? cw_ne : ne3M5;
    always @(posedge spclk) begin
        cpuw_tog <= cpuw_active ? ~cpuw_tog : 1'b0;
        if (ne_sel) cpuw_active <= cpuwarp_req;             // change at a T-state boundary only
    end

    //=============================================================================================
    // Step 15: ROM-trap (machine-intercept). The core raises rom_trap_core on a trapped M1 opcode
    // fetch; we freeze the CPU AT that fetch (rt_halt gates the SAME enables as HALT) and raise
    // rt_pending for the ARM to poll (ROMTRAP 0xE0 bit0). The ARM services the block, then writes
    // "done" (0xE0 bit1) which clears the latch and lets the CPU resume. Enable + done cross
    // aclk<->spclk with the file's toggle/edge + ASYNC_REG idioms (as kbd_inject / the deadman kick).
    //=============================================================================================
    wire ctl_romtrap_en, ctl_romtrap_done_we;              // from axi_ctl (aclk)
    // enable synced to spclk
    (* ASYNC_REG="TRUE" *) reg [1:0] rten_s = 2'b0;
    always @(posedge spclk) rten_s <= {rten_s[0], ctl_romtrap_en};
    // ARM "done" pulse: aclk toggle -> spclk edge
    reg rtdone_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_romtrap_done_we) rtdone_tog_a <= ~rtdone_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] rtdone_s = 3'b0;
    always @(posedge spclk) rtdone_s <= {rtdone_s[1:0], rtdone_tog_a};
    wire rtdone_pulse = rtdone_s[2] ^ rtdone_s[1];
    // trap latch + CPU freeze
    reg rt_prev = 1'b0, rt_pending = 1'b0, rt_halt = 1'b0;
    always @(posedge spclk) begin
        rt_prev <= rom_trap_core;
        if (rtdone_pulse) begin rt_pending <= 1'b0; rt_halt <= 1'b0; end
        else if (rom_trap_core & ~rt_prev & rten_s[1] & ~rt_pending) begin   // rten_s only (ROM-trap is enabled only during an armed trap-only load; no tape-run in trap-only)
            rt_pending <= 1'b1;   // ARM will read this and handle the block
            rt_halt    <= 1'b1;   // freeze the CPU AT the trapped M1 fetch
        end
    end
    // pending -> aclk for the ARM to poll
    (* ASYNC_REG="TRUE" *) reg [2:0] rtp_s = 3'b0;
    always @(posedge fclk100) rtp_s <= {rtp_s[1:0], rt_pending};
    wire rt_pending_a = rtp_s[2];
    // Register readback: cpu_reg_sp (212b, spclk) is STABLE while the CPU is halted (rt_halt), which
    // is exactly when the ARM reads it -> a plain 2-FF sync is safe. Live 7FFD synced the same way.
    (* ASYNC_REG="TRUE" *) reg [211:0] reg_rd0 = 212'd0, reg_rd1 = 212'd0;
    always @(posedge fclk100) begin reg_rd0 <= cpu_reg_sp; reg_rd1 <= reg_rd0; end
    (* ASYNC_REG="TRUE" *) reg [5:0] p7ffd_s0 = 6'd0, p7ffd_s1 = 6'd0;
    always @(posedge fclk100) begin p7ffd_s0 <= p7ffd_live_core; p7ffd_s1 <= p7ffd_s0; end

    wire pe3M5_core = pe_sel & ~cpu_halt_sp & ~rt_halt & ~cpu_starve & ~clr_active;
    wire ne3M5_core = ne_sel & ~cpu_halt_sp & ~rt_halt & ~cpu_starve & ~clr_active;
    //=============================================================================================
    // Keyboard gate (control-plane scancode tap -> ARM).
    // Lines (a)-(d) below are MACHINE-AGNOSTIC: the ARM always sees every scancode through this FIFO
    // and owns ALL hotkey / OSD policy, and the fabric decodes no function key, so this block ports
    // unchanged to a NES/C64/Atari core. (Only the kb_* suppression mux further down — among the
    // ear sync / 4-button decode / Alt-chord / ZX 8x5 matrix merge — is this machine's adapter.)
    // Two roles:
    //   * always-tap FIFO: every PS/2 event -> async_fifo -> ARM (so F12 can OPEN the OSD even
    //     while it is closed; the FIFO never depends on the gate state).
    //   * gate_on (OSD open, OSD_ENABLE synced to spclk): only SUPPRESSES PS/2 into the core's
    //     matrix. A deadman drops the gate if the ARM stalls, so a dead ARM can't lock the user out.
    //=============================================================================================
    // (a) OSD gate: engage when EITHER the 1bpp OSD (bit0) OR the DDR player window (bit1) is shown,
    //     so a visible player window takes keyboard focus (the machine gets no keys until it is hidden -
    //     even if it is not paused). Both are aclk level signals; OR then 2-FF level-sync to spclk.
    (* ASYNC_REG = "TRUE" *) reg [1:0] osd_en_s = 2'b00;
    always @(posedge spclk) osd_en_s <= {osd_en_s[0], (ctl_osd_enable | ctl_ddr_osd_en)};
    wire osd_en_sp = osd_en_s[1];

    // (b) Deadman heartbeat: aclk KBD_HB pulse -> spclk via toggle + 3-FF + edge (inject_cdc idiom).
    //     CONSTRAINT: the ARM must kick at most once per main-loop pass (never a tight burst). aclk
    //     (100 MHz) toggles ~1.76x faster than spclk samples, so two kicks inside one spclk period
    //     would cancel as a missed edge. Safe today (osd.c kicks once per for(;;) pass, hundreds of
    //     aclk cycles apart; missed kick is self-healing and bounded by the 1.18 s timeout). If a
    //     timer-ISR / DMA heartbeat is ever added, stretch the kick on aclk to >=2 spclk periods first.
    reg kick_tog_a = 1'b0;
    always @(posedge fclk100) if (kbd_deadman_kick) kick_tog_a <= ~kick_tog_a;
    (* ASYNC_REG = "TRUE" *) reg [2:0] kick_sync = 3'd0;
    always @(posedge spclk) kick_sync <= {kick_sync[1:0], kick_tog_a};
    wire kick_sp = kick_sync[2] ^ kick_sync[1];

    // (c) Deadman counter (free-running spclk, NOT pe3M5_core which freezes on HALT). ~1.18 s at
    //     56.7 MHz; expiry forces the gate off until the ARM kicks again or closes the OSD.
    reg [25:0] deadman = 26'd0;
    reg        deadman_expired = 1'b0;
    always @(posedge spclk) begin
        if (!osd_en_sp)      begin deadman <= 26'd0; deadman_expired <= 1'b0; end
        else if (kick_sp)    begin deadman <= 26'd0; deadman_expired <= 1'b0; end
        else if (&deadman)   deadman_expired <= 1'b1;
        else                 deadman <= deadman + 26'd1;
    end
    wire gate_on = osd_en_sp & ~deadman_expired;

    // (d) The always-tap scancode FIFO lives in control_plane (write side = this machine's kclk/kce,
    //     read side = the ARM). Here only the MATRIX SUPPRESSION below remains - the ZX adapter.
    //=============================================================================================
    // Tape input: synchronise the async ear_in pin into the Spectrum domain (2 FF).
    //=============================================================================================
    reg [1:0] ear_sync = 2'b00;
    always @(posedge spclk) ear_sync <= {ear_sync[0], ear_in};
    wire sp_ear = ear_sync[1];

    // ---- Step 14.2 tape station: replay ARM {level,dur} pulses into the ear (machine adapter here:
    //      tick = the CPU's own pe3M5_core T-state enable, mux = the ZX ear; the module is agnostic). ----
    (* ASYNC_REG="TRUE" *) reg [1:0] trun_s = 2'b00, tem_s = 2'b00, tmore_s = 2'b00;  // run/earmux/more-data aclk -> spclk
    always @(posedge spclk) begin trun_s <= {trun_s[0], ctl_tape_run}; tem_s <= {tem_s[0], ctl_tape_earmux}; tmore_s <= {tmore_s[0], ctl_tape_more}; end
    wire tape_earmux_sp = tem_s[1];
`ifdef HYBRID_CORE
    // The selected backend exposes the exact CE presented to its active T80.
    wire tape_cpu_tick = cpu_ten_sp;
`elsif MISTER48_CORE
    // MiSTer native48 owns native contention CEs internally and owns the
    // phase-safe FAST8 handoff in mister48_core.  Count pulses from the CE
    // actually presented to T80, never from the legacy Atlas top generator.
    wire tape_cpu_tick = cpu_ten_sp;
`else
    wire tape_cpu_tick = pe3M5_core;
`endif
    // Один предикат «лента движется» на два потребителя: собственно продвижение ленты и разрешение
    // варпа (см. комментарий у cpuwarp_req). Раньше он был здесь выражением на месте - вынесен в
    // именованный провод, чтобы у ленты и у скорости процессора не могло разъехаться понимание того,
    // идёт загрузка или нет. Именно такое расхождение и стоило нам SHOCK.TAP.
    assign tape_streaming = (~sync_effective | ~tape_sync_rom | sync_hold | (sync_state == SYNC_CUSTOM));
    wire tape_advance = tape_cpu_tick & tape_warp_ready & tape_streaming;
    /* B0046 A/B uses the player's genuine idle transition only to return the
       SAFE4 clock policy to native time without waiting for ARM CDC/polling.
       It deliberately DOES NOT alter EAR: descriptor parity makes Aliens'
       last recorded level LOW, so an EAR-tail theory cannot explain it.  The
       seen latch prevents an empty start-of-run from qualifying as EOT. */
    assign tape_eot_now = trun_s[1] & tape_seen_playing & tape_seen_more & ~tape_playing & ~tmore_s[1];
    assign tape_eot_safe = tape_eot_now & (fm_s1 == 2'd2);
    always @(posedge spclk or negedge sp_reset_n) begin
        if(!sp_reset_n) begin
            tape_seen_playing <= 1'b0;
            tape_seen_more    <= 1'b0;
        end
        else if(!trun_s[1]) begin
            tape_seen_playing <= 1'b0;
            tape_seen_more    <= 1'b0;
        end
        else begin
            if(tape_playing) tape_seen_playing <= 1'b1;
            if(tmore_s[1])   tape_seen_more    <= 1'b1;
        end
    end
    // B0123: AW 12->11. Глубина 2048 дескрипторов вместо 4096 - две плитки BRAM вместо четырёх.
    // Здесь НАСТОЯЩЕЕ место: дефолт в самом tape_bram_fifo.v ни на что не влияет, параметр
    // задаётся тут и прокидывается через tape_player. Освобождённые плитки нужны, чтобы снять
    // перебор блочной памяти (Used=121, Available=120), из-за которого синтезатор выдавливает
    // буферы оболочки в распределённую память - 2526 LUT, каждый шестой на кристалле.
    tape_player #(.DUR_W(24), .AW(11)) tape_i (
        .wr_clk(fclk100), .wr_rst_n(aresetn), .push(ctl_tape_we), .push_data(ctl_tape_data), .full(tape_full),
        .rd_clk(spclk), .rd_rst_n(sp_reset_n), .fifo_rd_rst_n(aresetn), .t_en(tape_advance), .run(trun_s[1]),
        .tape_ear(tape_ear), .playing(tape_playing), .empty(tape_empty_sp),
        .sync_rom(tape_sync_rom), .block_start(tape_block_start),
        .diag_pop_count(tape_diag_count_sp), .diag_pop_hash(tape_diag_hash_sp),
        .diag_gap_count(tape_diag_gaps_sp), .diag_resume_count(tape_diag_resumes_sp)
    );
    (* ASYNC_REG="TRUE" *) reg [1:0] tpl_a = 2'b00;                      // playing spclk -> aclk (status)
    always @(posedge fclk100) tpl_a <= {tpl_a[0], tape_playing};
    assign tape_playing_a = tpl_a[1];

    //=============================================================================================
    // Keyboard: 4 buttons -> PS/2-set-2 scan-code strobes (NOT gated by halt).
    //=============================================================================================
    wire       kbd_strb, kbd_make;
    wire [7:0] kbd_code;
    kbd_buttons kbd_i (
        .clock(spclk), .ce(pe3M5), .btn(btn),
        .strb(kbd_strb), .make(kbd_make), .code(kbd_code)
    );

    //=============================================================================================
    // Alt = ZX Extended mode (the red lower-row token). On the Alt press edge, inject a short
    // Caps+Symbol Shift chord (this arms the ROM's "E" mode), then hold Symbol Shift while Alt
    // stays down - so the next key, pressed with Alt held, prints the red extended token. A quick
    // Alt tap (released before any key) leaves E-mode armed with no shift held -> the next key
    // gives the green top token instead. Done as synthetic scan-code events fed into the keyboard
    // stream (no Atlas-core edit): CS = 0x12, SS = 0x14, make = 0 press / make = 1 release.
    //=============================================================================================
    localparam [17:0] ALT_PULSE = 18'd210000;   // ~60 ms @ 3.5 MHz pe3M5: spans >=2 of the ROM's 50 Hz key scans
    reg        alt_d2   = 1'b0;
    reg [2:0]  alt_st   = 3'd0;                  // 0 idle / 1 SS-down / 3 chord-hold then CS-up / 5 held while Alt
    reg [17:0] alt_tmr  = 18'd0;
    reg        syn_strb = 1'b0, syn_make = 1'b1;
    reg [7:0]  syn_code = 8'h00;
    always @(posedge spclk) if (pe3M5) begin
        alt_d2   <= alt_h;
        syn_strb <= 1'b0;                         // default: emit nothing on this enable tick
        case (alt_st)
            3'd0: if (alt_h & ~alt_d2) begin                                  // Alt just pressed
                      syn_strb <= 1'b1; syn_make <= 1'b0; syn_code <= 8'h12;  //   -> Caps Shift down
                      alt_st   <= 3'd1;
                  end
            3'd1: begin                                                       //   -> Symbol Shift down
                      syn_strb <= 1'b1; syn_make <= 1'b0; syn_code <= 8'h14;
                      alt_tmr  <= ALT_PULSE; alt_st <= 3'd3;
                  end
            3'd3: if (alt_tmr == 18'd0) begin                                 // chord held long enough
                      syn_strb <= 1'b1; syn_make <= 1'b1; syn_code <= 8'h12;  //   -> Caps Shift up (SS stays down)
                      alt_st   <= 3'd5;
                  end else alt_tmr <= alt_tmr - 18'd1;
            3'd5: if (~alt_h) begin                                           // Alt released
                      syn_strb <= 1'b1; syn_make <= 1'b1; syn_code <= 8'h14;  //   -> Symbol Shift up
                      alt_st   <= 3'd0;
                  end
            default: alt_st <= 3'd0;
        endcase
    end

    // B0103: ОЧИСТКА МАТРИЦЫ ПО ФРОНТУ ЗАКРЫТИЯ ГЕЙТА.
    // Требование владельца: если в момент открытия навигатора клавиша зажата, машина не должна её
    // видеть. B0102 научил гейт пропускать ОТПУСКАНИЯ, но пока палец на клавише, отпускания нет
    // вовсе - поэтому нужен отдельный проход. По фронту gate_on прогоняем счётчик по всем 256 кодам
    // и выдаём отпускание для каждого: 256 тактов pe3M5 = ~73 мкс, то есть заведомо раньше, чем ПЗУ
    // успеет сделать следующий скан клавиатуры на 50 Гц.
    // Обратный переход трогать не нужно: матрица уже чиста, и зажатая клавиша не «нажмётся» задним
    // числом - в машину пойдёт только следующее НАСТОЯЩЕЕ событие.
    reg        gate_d  = 1'b0;
    reg        clr_run = 1'b0;
    reg [7:0]  clr_cnt = 8'd0;
    always @(posedge spclk) if (pe3M5) begin
        gate_d <= gate_on;
        if (gate_on & ~gate_d) begin clr_run <= 1'b1; clr_cnt <= 8'd0; end
        else if (clr_run) begin
            if (clr_cnt == 8'hFF) clr_run <= 1'b0;
            else                  clr_cnt <= clr_cnt + 8'd1;
        end
    end
    wire       clr_strb = clr_run;
    wire [7:0] clr_code = clr_cnt;

    // ---- ARM keyboard inject (0xA8): a synthetic scancode fed into the core's key stream, the same
    //      path as the Alt-chord (syn_*), but it BYPASSES the OSD gate so the ARM can drive the machine's
    //      keyboard even with the player window up (autonomous tape-loader start + self-test). aclk write
    //      -> toggle CDC -> spclk; the data word (held stable in aclk) is sampled at the synchronised
    //      pulse. Convention (as syn_*): make=0 press, make=1 release. Injects are spaced milliseconds
    //      apart, so the single-entry pending latch never collides.
    reg kinj_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_kbd_inject_we) kinj_tog_a <= ~kinj_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] kinj_sync = 3'd0;
    always @(posedge spclk) kinj_sync <= {kinj_sync[1:0], kinj_tog_a};
    wire kinj_pulse = kinj_sync[2] ^ kinj_sync[1];
    (* ASYNC_REG="TRUE" *) reg [8:0] kinj_d0 = 9'd0, kinj_d1 = 9'd0;
    always @(posedge spclk) begin kinj_d0 <= ctl_kbd_inject; kinj_d1 <= kinj_d0; end

    reg       arm_strb = 1'b0, arm_make = 1'b1;
    reg [7:0] arm_code = 8'h00;
    reg       arm_pending = 1'b0;
    reg [8:0] arm_lat = 9'd0;
    always @(posedge spclk) begin
        if (kinj_pulse) begin arm_pending <= 1'b1; arm_lat <= kinj_d1; end
        if (pe3M5) begin
            arm_strb <= 1'b0;                        // default: emit nothing this enable tick (mirror syn_strb)
            if (arm_pending) begin
                arm_strb <= 1'b1;
                arm_make <= arm_lat[8];
                arm_code <= arm_lat[7:0];
                arm_pending <= 1'b0;
            end
        end
    end

    // NumLock/Kempston ownership comes from JOY_STATE bit31.  It is a slow ARM level; synchronise it
    // independently because the full joy_sp bus is declared below this adapter.  Bits [7:0]/[23:16]
    // remain the two platform joystick bytes, so no game-visible Kempston bit is consumed.
    (* ASYNC_REG="TRUE" *) reg [1:0] numjoy_s = 2'b00;
    always @(posedge spclk) numjoy_s <= {numjoy_s[0], ctl_joy[31]};
    wire numjoy_sp = numjoy_s[1];

    // Physical NumPad data bytes in set-2.  Main Enter and "/" are bare 5A/4A; their keypad twins
    // are E0 5A/E0 4A, hence the split.  Real cursor/Insert/Delete keys are E0-prefixed and stay live.
    wire ps2_numpad_byte =
        (!ps2_e0 && ((ps2_code == 8'h70) || (ps2_code == 8'h69) || (ps2_code == 8'h72) ||
                     (ps2_code == 8'h7A) || (ps2_code == 8'h6B) || (ps2_code == 8'h73) ||
                     (ps2_code == 8'h74) || (ps2_code == 8'h6C) || (ps2_code == 8'h75) ||
                     (ps2_code == 8'h7D) || (ps2_code == 8'h71) || (ps2_code == 8'h79) ||
                     (ps2_code == 8'h7B) || (ps2_code == 8'h7C))) ||
        ( ps2_e0 && ((ps2_code == 8'h4A) || (ps2_code == 8'h5A)));

    // Merge synthetic Alt chord + real PS/2 keyboard + the 4 buttons (synthetic wins, then PS/2).
    // ZX matrix adapter for the gates: OSD owns the whole keyboard; NumLock/Kempston owns only the
    // physical keypad.  ARM injection and the board buttons deliberately bypass both gates.
    // Always pass BREAK data to the matrix.  A keypad key that was pressed just before the owner
    // toggled NumLock must still be released; a release for a make we suppressed is idempotent.
    // B0102: гейт OSD подавляет только НАЖАТИЯ. Отпускания идут в матрицу всегда - иначе
    // нажатие, успевшее пройти до закрытия гейта, остаётся в машине навсегда (у владельца так
    // само листалось меню при работе в навигаторе). Ровно то же ограничение уже стоит у гейта
    // NumLock ниже в этой строке, и комментарий выше прямо требует «Always pass BREAK data to
    // the matrix»; у гейта OSD его просто не применили. Отпускание для подавленного нажатия
    // идемпотентно, поэтому лишним оно быть не может.
    // 🥇 B0103a: ВНИМАНИЕ, make здесь ИНВЕРТИРОВАН - 0 значит НАЖАТА, 1 значит ОТПУЩЕНА (видно по
    // эмиттеру аккорда Alt: syn_make=0 это down, =1 это up, и по гейту NumLock, где подавление стоит
    // при ~ps2_make). В B0102 я написал ~ps2_make и получил обратное: гейт пропускал НАЖАТИЯ и
    // блокировал отпускания, из-за чего стрелки навигатора залипали в машине.
    wire       ps2_to_core = ps2_strb & (~gate_on | ps2_make)
                           & ~(numjoy_sp & ps2_numpad_byte & ~ps2_make)
                           & ~pause_byte & ~ps2tx_busy;
    // B0103: проход очистки стоит приоритетом ниже инжекта ARM и выше остальных источников -
    // он должен успеть снять матрицу до того, как в неё попадёт что-то ещё.
    wire       kb_strb = arm_strb | clr_strb | syn_strb | ps2_to_core | kbd_strb;                          // ARM inject wins (bypasses the gate)
    wire       kb_make = arm_strb ? arm_make : clr_strb ? 1'b1     : (syn_strb ? syn_make : (ps2_to_core ? ps2_make : kbd_make));
    wire [7:0] kb_code = arm_strb ? arm_code : clr_strb ? clr_code : (syn_strb ? syn_code : (ps2_to_core ? ps2_code : kbd_code));
    //=============================================================================================
    // Atlas ZX Spectrum core (main). CPU enables gated by halt; video enables free-running.
    //=============================================================================================
    wire [10:0] laudio, raudio;
    wire        vmmCe;
    wire [13:0] vmmA1, vmmA2_core;
    wire [7:0]  vmmD;
    wire        memRf, memRd, memWr_core;
    wire [18:0] memA_core;
    wire [7:0]  memD, memQ_core;
    wire [5:0]  p7ffd_live_core;                          // Step 15: live 128K paging port (7FFD) from the core
    wire [7:0]  map_diag_core;                            // B0048: passive Atlas automapper/MMU observer state
    wire [26:0] ula_diag_core;                            // B0048: passive ULA/IRQ/contention snapshot
    // Machine select - CDC control bits (aclk) -> spclk (2-FF).  The Atlas core has native 48K
    // support; keeping this separate from Pentagon timing lets tape images select their real ROM.
    // v0x4A JOYMAP: joystick mask aclk->spclk, plain 2-FF per bit (level-type quasi-static signal;
    // 1-clk bit skew == real stick chatter). deadman gate: if the ARM dies holding FIRE, the pad is
    // released when the keyboard-gate deadman expires - reuse gate_deadman state via kbd path? The
    // Step-10 deadman lives inside the gate logic; simplest equivalent here: zero the pad whenever
    // the keyboard gate itself has been forced open by the deadman (same aliveness signal).
    (* ASYNC_REG="TRUE" *) reg [31:0] joy_m = 32'd0, joy_sp = 32'd0;
    always @(posedge spclk) begin joy_m <= ctl_joy; joy_sp <= joy_m; end
    (* ASYNC_REG="TRUE" *) reg [1:0] pentagon_s = 2'b00, model48_s = 2'b00, ula_late_s = 2'b00, force_atlas_s = 2'b00, snow_off_s = 2'b00;
    always @(posedge spclk) begin
        pentagon_s <= {pentagon_s[0], ctl_pentagon};
        model48_s  <= {model48_s[0],  ctl_model48};
        force_atlas_s <= {force_atlas_s[0], ctl_force_atlas};
        ula_late_s <= {ula_late_s[0], ctl_ula_late};
        snow_off_s <= {snow_off_s[0], ctl_snow_off};
    end
    wire pentagon_sp = pentagon_s[1];
    wire core_model_sp = ~model48_s[1];              // Atlas: 0 = 48K, 1 = 128K
    wire ula_late_sp = ~pentagon_s[1] & ula_late_s[1]; // Ferranti ULA variation: valid on Sinclair 48K and 128K, never Pentagon

    // Step 15: live paper offsets CDC aclk -> spclk (slow controls, simple 2FF sufficient)
    (* ASYNC_REG="TRUE" *) reg [8:0] paper_h_s1=9'd64, paper_h_s2=9'd64;
    (* ASYNC_REG="TRUE" *) reg [8:0] paper_v_s1=9'd24, paper_v_s2=9'd24;
    always @(posedge spclk) begin
        paper_h_s1 <= ctl_paper_h; paper_h_s2 <= paper_h_s1;
        paper_v_s1 <= ctl_paper_v; paper_v_s2 <= paper_v_s1;
    end
    wire [8:0] paper_h_sp = paper_h_s2;
    wire [8:0] paper_v_sp = paper_v_s2;
    // PENT_INT / B0053 tuner bus: multi-bit, changes rarely -> 3-FF + settle-latch. The diagnostic
    // native-48 config is then committed only on a VSYNC edge, so a JTAG write can never move ULA
    // timing or /INT halfway through a frame. Ordinary Pentagon tuning inherits the same safe delay.
    (* ASYNC_REG="TRUE" *) reg [31:0] pint_s1 = 32'h00EF0146, pint_s2 = 32'h00EF0146, pint_s3 = 32'h00EF0146;
    reg [31:0] pint_q = 32'h00EF0146;
    reg [31:0] pint_active = 32'h00EF0146;
    reg pint_vsync_d = 1'b0;
    always @(posedge spclk) begin
        pint_s1 <= ctl_pent_int; pint_s2 <= pint_s1; pint_s3 <= pint_s2;
        if (pint_s2 == pint_s3) pint_q <= pint_s2;
        pint_vsync_d <= vid_vsync;
        if (vid_vsync && !pint_vsync_d) pint_active <= pint_q;
    end

    // ---- BulbuLator screen mirror: raw ZX screen tapped off the ULA fetch (main.v scr_cap*) ----
    wire [12:0] scr_capA_w;
    wire [7:0]  scr_capD_w;
    wire        scr_capWe_w;
    wire [2:0]  border_w;                       // live ULA border colour (per-scanline capture below)

`ifdef HYBRID_CORE
    hybrid_zx_core core_i (
        .cpu_halt(cpu_halt_sp),
`elsif MISTER48_CORE
    mister48_core core_i (
        .cpu_halt(cpu_halt_sp),
`else
    main core_i (
`endif
        .model  (core_model_sp),
        .snow_off(snow_off_s[1]),         // v145 переключатель снега. Порт есть у ВСЕХ трёх ядер:
                                          // Atlas main, hybrid и (с 13.08) mister48_core. Раньше
                                          // здесь стоял `ifndef MISTER48_CORE` - и на машине MiSTer
                                          // пункт меню молча ничего не делал.
`ifdef HYBRID_CORE
        .force_atlas(force_atlas_s[1]),   // co-resident Atlas/mister48 select - only hybrid_zx_core has this port; standalone Atlas (main) / mister48_core do not
`endif
        .pentagon(pentagon_sp),
`ifndef MISTER48_CORE
`ifndef HYBRID_CORE
        .pent1024(pentagon_sp),   // Пентагон = 1024: это и есть машина, о которой речь
        // B0154: фаза окна контеншена ПОРТОВ (MACHINE_CFG бит27). ЭТА СВЯЗЬ ОБЯЗАНА ЖИТЬ ПОД `ifndef`:
        // порт есть только у Atlas (`atlas_core/main.v`), у mister48_core и hybrid_zx_core его нет,
        // и связь вне `ifndef` уронила бы обе ветви на синтезе МОЛЧА (эта мина уже стоила шести дней,
        // см. B0148 ниже про четыре связи карты).
        .io_cont_early(iocont_s[1]),
        .ram_nobit(ram_nobit_sp), // B0120: каких старших бит банка у машины НЕТ (MACHINE_CFG [16:14])
        .mem_wait(zx_mem_wait),
        .ram_bank(ram_bank_core),
        .eff7_o  (eff7_core),
        .trdos_en  (trdos_en_sp),     // B0071: трап входа в TR-DOS (MACHINE_CFG бит8, по умолчанию 0)
        .service_en(svcrom_sp),       //        сервисная страница ПЗУ  (MACHINE_CFG бит9)
        .svc_nmi_en(svc_nmi_en_sp),   // B0101:  магическая кнопка       (MACHINE_CFG бит13)
        .dos_svc_en(dos_svc_en_sp),   // B0146:  под TR-DOS страница = {DOS, 7FFD[4]} (MACHINE_CFG бит25)
        .trdos_o   (trdos_core),      //        живая защёлка DOS   -> MACH_DBG бит13
        .rom_page_o(rom_page_core),   //        живая страница ПЗУ  -> MACH_DBG [23:22]
        .rom_dbg_o (rom_dbg_core),    // B0147  прибор трапа       -> 0x1BC ROM_DBG
        .page3_seen_o(page3_seen_core),// B0147 липко: слот 3 был   -> MACH_DBG бит12
        .aud_dbg_o (zx_aud_dbg),      // B0088:  пики звука по источникам -> 0x170
        .fdc_aclk  (fclk100),         // B0075: мост дисковода (сектора подаёт ARM)
        .gs_en     (gs_en_sp),                  // General Sound: карта включена (бит31 слова 0x178)
        .gs_ctl    (gs_ctl_a), .gs_ctl_we (gs_ctl_we_a),
        .gs_stat   (gs_stat_w),
        .gs_wq_din (gs_wq_din_sp), .gs_wq_we (gs_wq_we_sp), .gs_wq_full (gs_wq_full_sp),
        .gs_wq_afull(gs_wq_afull_sp),            // B0119: верхний порог = условие ТАКТОВ ОЖИДАНИЯ
        .gs_wq_drain(gs_wq_drain_sp),            //         вынутый оболочкой байт = признак её жизни
        .gs_stat2 (gs_stat2_w), .gs_stat3 (gs_stat3_w),
        .nemo_en (nemo_ctl_a[4]), .nemo_ctl (nemo_ctl_a), .nemo_ctl_we (nemo_ctl_we_a),
        .nemo_stat (nemo_stat_w), .nemo_stat2 (nemo_stat2_w),
        .km_en (km_ctl_a[31]), .km_ctl (km_ctl_a), .km_ctl_we (km_ctl_we_a),   // B0116 мышь Kempston
        .fdc_ctl   (fdc_ctl_a), .fdc_ctl_we (fdc_ctl_we_a),
        .fdc_data  (fdc_data_a), .fdc_data_we(fdc_data_we_a),
        .fdc_stat  (fdc_stat_w), .fdc_stat2 (fdc_stat2_w),
        .bdi_always(bdi_always_sp),
        .saa_mode  (saa_mode_sp),   // B0087: SAA1099 на #FF - AUTO/ON/OFF
`endif
`endif
        .ula_late(ula_late_sp),
        .ula_tune(pint_active),        // B0053: PENT_INT is free on native48 and becomes a frame-atomic JTAG timing tuner
        .pent_int_v(pint_active[24:16]),
        .pent_int_h(pint_active[8:0]),
        .paper_h(paper_h_sp),
        .paper_v(paper_v_sp),
        .mapper (divmmc_en_sp),          // B0132: было 1'b0 - весь конус автомаппера выбрасывался
/* 🥇 B0148 ЭТИ ЧЕТЫРЕ СВЯЗИ ОБЯЗАНЫ ЖИТЬ ПОД `ifndef`, КАК И ВСЁ ОСТАЛЬНОЕ ПРО КАРТУ.
   Их добавили ВНЕ условной компиляции работами по Z-Controller/DivMMC (B0132/B0138/B0143), а
   портов `zc_en`, `zc_turbo`, `dm_opt`, `dm_pagein_off` у `mister48_core`/`hybrid_zx_core` нет -
   и обе ветви ПЕРЕСТАЛИ СИНТЕЗИРОВАТЬСЯ (`ERROR: [Synth 8-11365] named port connection does not
   exist`), причём молча: собирали только Atlas, а на карте лежало ядро MiSTer-48, отставшее на
   девять сборок. Ровно та мина из CLAUDE.md про общий верхний модуль, только бьёт по СБОРКЕ, а
   не по поведению: правку общего топа проверять сборкой ВСЕХ ветвей, а не той, что тестируешь. */
`ifndef MISTER48_CORE
`ifndef HYBRID_CORE
        .zc_en  (zc_en_sp),              // B0138: Z-Controller
        .zc_turbo(zc_turbo_sp),          // B0143: 1=Turbo 28MHz, 0=Standard 3.5MHz
        .dm_opt (dm_opt_sp),
        .dm_pagein_off(dm_pagein_off_sp),
`endif
`endif
        .reset  (sp_reset_n),
        .nmi    (nmi_pulse),

        .clock  (spclk),
        .pe7M0  (pe7M0),
        .ne7M0  (ne7M0),
        .pe3M5  (pe3M5_core),     // gated for HALT
        .ne3M5  (ne3M5_core),     // gated for HALT

        .blank  (vid_blank), .hsync(vid_hsync), .vsync(vid_vsync),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i),

        .ear    (tape_earmux_sp ? tape_ear : sp_ear),   // tape replay overrides the physical ear while loading
        .laudio (laudio),
        .raudio (raudio),
        .midi   (),

        .strb   (kb_strb), .make(kb_make), .code(kb_code),
        .joy1   (joy_sp[7:0]), .joy2(joy_sp[23:16]),   // v0x4A: Kempston fed from JOY_STATE (bits FUDLR match 1:1)
        /* Выводы uSD ядра до сих пор висели в воздухе. Теперь на них стоит наша карта: `usd.v` и
           `spi.v` остаются нетронутыми (в них и есть выбранная схема - выравнивание байта делает
           железо), а протокол SD разбирает divmmc_card ниже. Второго декодера #E7/#EB не
           появляется: мы висим на проводах, а не на шине портов. */
        .cs(sd_cs_n_w), .ck(sd_ck_w), .miso(sd_miso_w), .mosi(sd_mosi_w),

        .vmmCe  (vmmCe),
        .vmmA1  (vmmA1),
        .vmmA2  (vmmA2_core),
        .vmmD   (vmmD),

        .memCe  (),
        .memRf  (memRf),
        .memRd  (memRd),
        .memWr  (memWr_core),
        .memA   (memA_core),
        .memD   (memD),
        .memQ   (memQ_core),

        .dirset      (dir_set_sp),
        .dir         (cpu_dir_sp),
        .reg_out     (cpu_reg_sp),
        .force_7ffd  (force_7ffd_sp),
        .port7ffd_in (port7ffd_sp),
        .force_border(force_border_sp),
        .border_in   (border_sp),
        .tape_sample (tape_sample),
        .tape_sample_strobe(tape_sample_strobe),
        .tape_di_bit(tape_di_bit),
        .cpu_ten     (cpu_ten_sp),
        .warp_nc     (cpuw_active),                // suppress 128K contention ONLY for CPU-only 8x. At 1x and SAFE4x retain the real ZX128 ULA contention: a physical tape is independent of CPU wait-states, and disabling contention for every tape run corrupts long ROM loads such as BigThings BT.2.
        .rom_trap    (rom_trap_core),  // Step 15: trapped M1 opcode fetch
        .p7ffd_live  (p7ffd_live_core), // Step 15: live 128K paging port (7FFD)
        .map_diag_o  (map_diag_core),
        .ula_diag_o  (ula_diag_core),
        .int_dbg0_o  (int_dbg0_core),
        .int_dbg1_o  (int_dbg1_core),
        .int_dbg2_o  (int_dbg2_core),
        .scr_capA    (scr_capA_w),      // BulbuLator screen-mirror tap: ULA fetch address
        .scr_capD    (scr_capD_w),      //   fetched screen byte (displayed bank -> shadow-aware)
        .scr_capWe   (scr_capWe_w),     //   strobe (gated with ne7M0 at the mirror BRAM below)
        .border_o    (border_w)         //   live ULA border colour (per-scanline capture)
    );

    /* ===== DivMMC: карта SD ==================================================================
       Стоит на выводах uSD ядра, за уже синтезированным сдвигателем `spi.v`, и работает БАЙТАМИ.
       Вход `ce` карте больше не нужен (B0145): она берёт биты по ФРОНТУ `sck` и потому одинаково
       работает на обеих скоростях движка - и на 28.33 МГц, и на стандартных 3.5 МГц. До B0145 здесь
       требовался тот же `ne7M0`, что и у движка, а `.ce(1'b1)`, поставленное в B0142, убивало
       стандартный режим: уровень `sck` жил восемь тактов, и принятый байт вырождался.
       ⚠ От карты НЕ ИДЁТ НИ ОДНОГО такта ожидания в процессор: обратное давление у неё - байт 0xFF
       («карта не готова»), и esxDOS его держит по построению (L1DD2/L1DC4). Заводить сюда
       `cpu_hold` НЕЛЬЗЯ: мёртвая оболочка не имеет права заморозить Z80.
       `map_dbg` пока ноль - его наполнит шаг автомаппера (S4), когда в memory.v появятся automap /
       conmem / mapram / страница. */
    divmmc_card dmmc_i (
        .clk(spclk), .ce(1'b1), .rst_n(sp_reset_n), .en(divmmc_en_sp | zc_en_sp),   // B0138: карта одна на оба транспорта
        .cs_n(sd_cs_n_w), .sck(sd_ck_w), .mosi(sd_mosi_w), .miso(sd_miso_w),
        /* B0133: было 9'd0 - состояние автомаппера наружу не выходило вовсе, и отладка
           «esxDOS не стартует» упиралась в отсутствие прибора. Теперь оно видно в
           DMMC_STAT[13:6] = {mapForce, mapAuto, mapOnM1, mapRam, mapPage[3:0]}. */
        .map_dbg({1'b0, map_diag_core}),
        .aclk(fclk100), .arst_n(aresetn),
        .ctl(dmmc_ctl_a), .ctl_we(dmmc_ctl_we_a), .cap_in(dmmc_cap_a),
        .bufa_in(dmmc_bufa_a), .bufa_we(dmmc_bufa_we_a),
        .bufw_in(dmmc_bufw_a), .bufw_we(dmmc_bufw_we_a), .bufr_re(dmmc_bufr_re_a),
        .bufa_q(dmmc_bufa_q_w), .bufr_q(dmmc_bufr_q_w),
        .stat(dmmc_stat_w), .lba_q(dmmc_lba_w), .dbg(dmmc_dbg_w)
    );
    // B0048 passive guest-observation trace.  T80 accepts DI on CEN_n, so
    // retain the LAST nc3M5-qualified sample of each IN-FE window and commit
    // once that window falls.  This fingerprints what the CPU actually saw,
    // unlike the pulse-FIFO hash which stops before the guest input mux.
    // Results reset on each RUN rising edge (not RUN-low), so EOT leaves a
    // retained snapshot for AXI/JTAG post-mortem inspection.
    reg        fe_trace_d = 1'b0, fe_trace_seen = 1'b0, fe_trace_run_d = 1'b0;
    reg [31:0] fe_trace_count_sp = 32'd0, fe_trace_hash_sp = 32'h811C_9DC5, fe_trace_last_sp = 32'h811C_9DC5;
    reg [31:0] fe_trace_cpu_candidate = 32'd0, fe_trace_ula_candidate = 32'd0;
    wire [31:0] fe_trace_cpu_word = {p7ffd_live_core, tape_di_bit, tape_earmux_sp,
                                     cpu_reg_sp[79:64], memA_core[7:0]};
    wire [31:0] fe_trace_ula_word = {5'd0, ula_diag_core};
    always @(posedge spclk) begin
        fe_trace_d <= tape_sample;
        fe_trace_run_d <= trun_s[1];
        if (trun_s[1] && !fe_trace_run_d) begin
            fe_trace_count_sp <= 32'd0;
            fe_trace_hash_sp  <= 32'h811C_9DC5;
            fe_trace_last_sp  <= 32'h811C_9DC5;
            fe_trace_cpu_candidate <= 32'd0;
            fe_trace_ula_candidate <= 32'd0;
            fe_trace_seen <= 1'b0;
        end else if (trun_s[1]) begin
            if (tape_sample_strobe) begin
                fe_trace_cpu_candidate <= fe_trace_cpu_word;
                fe_trace_ula_candidate <= fe_trace_ula_word;
                fe_trace_seen <= 1'b1;
            end
            if (!tape_sample && fe_trace_d && fe_trace_seen) begin
                // Falling after the final CEN_n of this IN-FE: candidate is
                // the same DI[6]/PC/paging state that T80 latched at T3.
                fe_trace_seen <= 1'b0;
                fe_trace_count_sp <= fe_trace_count_sp + 32'd1;
                fe_trace_hash_sp  <= {fe_trace_hash_sp[30:0], fe_trace_hash_sp[31]} ^ fe_trace_cpu_candidate ^
                                     {fe_trace_count_sp[7:0], fe_trace_count_sp[15:8], fe_trace_count_sp[23:16], fe_trace_count_sp[31:24]};
                fe_trace_last_sp  <= {fe_trace_last_sp[30:0], fe_trace_last_sp[31]} ^ fe_trace_ula_candidate ^
                                     {fe_trace_count_sp[7:0], fe_trace_count_sp[15:8], fe_trace_count_sp[23:16], fe_trace_count_sp[31:24]};
            end
        end
    end
    always @(posedge fclk100) begin
        fe_trace_count_a0 <= fe_trace_count_sp; fe_trace_count_a1 <= fe_trace_count_a0;
        fe_trace_hash_a0  <= fe_trace_hash_sp;  fe_trace_hash_a1  <= fe_trace_hash_a0;
        fe_trace_last_a0  <= fe_trace_last_sp;  fe_trace_last_a1  <= fe_trace_last_a0;
    end

    //=============================================================================================
    // Memory-bus mux: while the ARM holds the Z80 halted, it drives the write side of the bus.
    // The video read side (vmmA1 / vmmCe) always comes from the core, so the picture stays live.
    //=============================================================================================
    wire        memWr_eff = clr_active ? 1'b1                         : (cpu_halt_sp ? arm_memWr : memWr_core);
    wire [18:0] memA_eff   = clr_active ? {2'b01, clr_addr}            : (cpu_halt_sp ? arm_memA  : memA_core);
    wire [7:0]  memQ_eff   = clr_active ? 8'h00                        : (cpu_halt_sp ? arm_memQ  : memQ_core);
    wire [13:0] vmmA2_eff  = clr_active ? {clr_addr[15], clr_addr[12:0]} : (cpu_halt_sp ? arm_vmmA2 : vmmA2_core);

    // ---- Load-verification probe: count core RAM writes (spclk). A successful tape load stores
    //      thousands of bytes; a failed pilot-lock stores ~none. The ARM reads MEMWR_CNT (0xAC) before
    //      and after a load window and checks the delta. Coarse 32-bit 2-FF CDC to aclk is fine: the
    //      verdict is a >1000x delta (harness reads a few times, takes the max). Counts memWr_core only -
    //      the cold-reset RAM wipe freezes the core (clr_active gates ne3M5_core), so it never inflates.
    reg        memwr_d_sp   = 1'b0;
    reg [31:0] memwr_cnt_sp = 32'd0;
    always @(posedge spclk) begin
        memwr_d_sp <= memWr_core;
        if (memWr_core & ~memwr_d_sp) memwr_cnt_sp <= memwr_cnt_sp + 32'd1;   // one count per write (rising edge)
    end
    (* ASYNC_REG="TRUE" *) reg [31:0] memwr_s0 = 32'd0, memwr_sync = 32'd0;
    always @(posedge fclk100) begin memwr_s0 <= memwr_cnt_sp; memwr_sync <= memwr_s0; end

    // ============================================================================================
    // SCREEN MIRROR (async, non-intrusive): the ULA screen fetch (scr_cap* from the core) is written
    // into a 2048x32 fabric BRAM in the spclk domain, "as it lands" (shadow-aware: scr_capD is the
    // byte from the DISPLAYED bank). The ARM/JTAG reads it over M_AXI_GP0 (window 0x40008000) which
    // is a SEPARATE path from the DDR controller the core/video/ARM use -> reading it NEVER steals
    // DDR bandwidth -> zero effect on the running machine. 6912 raw ZX bytes = words 0..1727:
    // bitmap 0x0000..0x17FF (interleaved) + attributes 0x1800..0x1AFF. Byte B -> word B[12:2], lane B[1:0].
    // ============================================================================================
    (* ram_style="block" *) reg [31:0] scrmir [0:2047];
    // per-scanline BORDER capture: sample border_w at each hsync into mirror words 1728.. (byte 0).
    // The host renders the loading stripes from these; screen (words 0..1727) + border share one BRAM.
    reg vhs_d = 1'b0, vvs_d = 1'b0;
    reg [8:0] bl_line = 9'd0;
    wire hs_edge = vid_hsync & ~vhs_d;
    wire vs_edge = vid_vsync & ~vvs_d;
    always @(posedge spclk) begin
        vhs_d <= vid_hsync; vvs_d <= vid_vsync;
        if (vs_edge)                          bl_line <= 9'd0;
        else if (hs_edge && bl_line < 9'd319) bl_line <= bl_line + 9'd1;
    end
    // ONE write port, muxed between screen (words 0..1727, all lanes) and border (words 1728.., lane 0).
    // Canonical single-statement byte-write template -> infers as a byte-enabled BRAM (two write
    // statements to the same array flip it to LUTRAM and blow the LUT-as-memory budget).
    wire        mir_scr  = ne7M0 & scr_capWe_w;                 // screen write wins over border
    wire        mir_we   = mir_scr | hs_edge;
    wire [10:0] mir_addr = mir_scr ? scr_capA_w[12:2] : (11'd1728 + {2'b00, bl_line});
    wire [1:0]  mir_lane = mir_scr ? scr_capA_w[1:0]  : 2'd0;
    wire [7:0]  mir_byte = mir_scr ? scr_capD_w       : {5'b0, border_w};
    always @(posedge spclk) if (mir_we) begin
        case (mir_lane)
            2'd0: scrmir[mir_addr][ 7: 0] <= mir_byte;
            2'd1: scrmir[mir_addr][15: 8] <= mir_byte;
            2'd2: scrmir[mir_addr][23:16] <= mir_byte;
            2'd3: scrmir[mir_addr][31:24] <= mir_byte;
        endcase
    end
    // scr_bram_raddr / scr_rdata_r are DECLARED above (before the axi_ctl instance that uses them).
    always @(posedge fclk100) scr_rdata_r <= scrmir[scr_bram_raddr];

    // Банк для ПУТЕЙ ARM (инжект образа и очистка ОЗУ) берётся из самого адреса: они всегда
    // работают в младших 128 КБ по соглашению 128К, то есть в BRAM, и в DDR не уходят никогда.
    wire [5:0] ram_bank_eff = (clr_active || cpu_halt_sp) ? {3'd0, memA_eff[16:14]} : ram_bank_core;
    // Ядра без расширенной страничности (MiSTer-48 - машина 48К, страниц нет вообще; гибрид мёртв):
    // банк равен младшим трём битам адреса ОЗУ, как было до Пентагона 1024.
`ifdef MISTER48_CORE
    assign ram_bank_core = {3'd0, memA_core[16:14]};
`elsif HYBRID_CORE
    assign ram_bank_core = {3'd0, memA_core[16:14]};
`endif

    // 0x150 MACH_DBG для ZX/Пентагона. Счётчик запросов в DDR ОТ МАШИНЫ нужен отдельно от
    // xact_cnt в 0x14C: тот считает и транзакции стенда ARM, и по нему не отличить, ходила ли
    // в расширенный банк сама машина.
    reg [7:0] zxddr_req_cnt = 8'd0;
    always @(posedge spclk) if ((zxddr_rd | zxddr_wr) && zxddr_req_cnt != 8'hFF)
        zxddr_req_cnt <= zxddr_req_cnt + 8'd1;
    // B0071: в свободные биты слота легли страница ПЗУ [23:22] и защёлка DOS [13] - без них
    // «какое ПЗУ сейчас в окне» не наблюдаемо ниоткуда (регистры дисплея и так только на запись).
    assign zx_mach_dbg = {zxddr_req_cnt, rom_page_core, eff7_core, trdos_core, page3_seen_core,
                          p7ffd_live_core, ram_bank_eff};

    mem_zx #(.ROM_PAGES(ROM_PAGES_SEL)) mem_i (
        .clock (spclk),
        .memRf (memRf),
        .memRd (memRd),
        .memWr (memWr_eff),
        .memA  (memA_eff),
        .ram_bank(ram_bank_eff),
        .memQ  (memQ_eff),
        .memD  (memD),
        .ddr_addr(zxddr_addr), .ddr_wdata(zxddr_wdata),
        .ddr_rd(zxddr_rd), .ddr_wr(zxddr_wr), .ddr_rdata(zxddr_rdata),
        .vmmCe (vmmCe),
        .vmmA1 (vmmA1),
        .vmmA2 (vmmA2_eff),
        .vmmD  (vmmD),
        // B0071: порт B ПЗУ - заливка набора ARM-ом. Строб гейтится по loading (как ld_we & loading
        // у картриджа NES): случайная запись в 0x154 при работающей машине не должна портить ПЗУ.
        .rom_ld_clk (fclk100),
        .rom_ld_we  (rom_ld_we_a & rom_loading_a & rom_ld_en),
        .rom_ld_addr(rom_ld_addr_a),
        .rom_ld_data(rom_ld_data_a)
    );

    //=============================================================================================
    // ZX audio leg -> pre-volume mix. Master volume, the post-volume DC blocker and HDMI live in
    // control_plane; player_pcm/pgain/mgn come from its ARM-music FIFO.
    //=============================================================================================
    //=============================================================================================
    // Step 13.1 "full pause" mute: while the Z80 is HALTed (Pause), the AY/beeper clock-enables are
    // gated (pe3M5_core = pe3M5 & ~cpu_halt_sp), so the sound chips freeze mid-sample and their last
    // value would hold as a DC level. Force the PCM to silence (0x400 = signed-16 zero after the
    // ~MSB offset->two's-complement conversion below) so a paused machine is genuinely quiet. On
    // resume (HALT deasserted) the frozen AY continues bit-exact - registers, envelope phase and the
    // noise LFSR all survive the freeze, so there is no save/restore and no resume click.
    wire [15:0] left16_raw  = { ~laudio[10], laudio[9:0], 5'b0 };   // signed PCM (NO hard mute)
    wire [15:0] right16_raw = { ~raudio[10], raudio[9:0], 5'b0 };
    // Pause FADE (anti-click): slew a gain 256<->0 over ~1.3 ms on HALT/resume instead of an instant
    // step to silence. Multiplying the SIGNED waveform toward zero ramps the real audio down to true
    // silence and back - no DC step, no click. The Z80/AY still freeze the instant HALT asserts
    // (pe3M5_core gating unchanged); only the audible envelope is smoothed, so resume is bit-exact.
    reg  [8:0] mgain = 9'd256;
    // cpu_halt_sp is spclk-domain; 2-FF sync it into clk_audio_r before it steers the fade target
    // (mirrors the vol_c0/osd_en_s discipline in this file - no unsynced control into the audio domain).
    (* ASYNC_REG = "TRUE" *) reg [1:0] halt_aud_s = 2'b00;
    always @(posedge clk_audio_r) halt_aud_s <= {halt_aud_s[0], cpu_halt_sp};
    wire [8:0] mtgt  = halt_aud_s[1] ? 9'd0 : 9'd256;
    always @(posedge clk_audio_r)
        if (mgain < mtgt) mgain <= mgain + 9'd4; else if (mgain > mtgt) mgain <= mgain - 9'd4;
    wire signed [24:0] lfp = $signed(left16_raw)  * $signed({1'b0, mgain});
    wire signed [24:0] rfp = $signed(right16_raw) * $signed({1'b0, mgain});
    wire [15:0] left16_sp  = lfp >>> 8;
    wire [15:0] right16_sp = rfp >>> 8;

    reg [15:0] left16_a0, left16_a1;
    reg [15:0] right16_a0, right16_a1;
    always @(posedge clk_audio_r) begin
        left16_a0  <= left16_sp;   left16_a1  <= left16_a0;
        right16_a0 <= right16_sp;  right16_a1 <= right16_a0;
    end

    // ANTI-POP 4b: DC-block the FABRIC leg BEFORE the machine<->player crossfade. Otherwise the machine's
    // idle DC level F crossfades through the FINAL blocker on every mux engage/release -> the residual
    // low-freq thump after 4a. Same single-pole HPF (fc~30 Hz); the machine loses only sub-40 Hz content
    // it never produces. Both crossfade legs now DC-free -> crossfade output ~0 DC throughout -> no step.
    reg signed [15:0] fdc_lx = 16'sd0, fdc_rx = 16'sd0;
    reg signed [19:0] fdc_ly = 20'sd0, fdc_ry = 20'sd0;
    wire signed [19:0] fdc_xl  = { {4{left16_a1[15]}},  left16_a1  };
    wire signed [19:0] fdc_xr  = { {4{right16_a1[15]}}, right16_a1 };
    wire signed [19:0] fdc_xl1 = { {4{fdc_lx[15]}}, fdc_lx };
    wire signed [19:0] fdc_xr1 = { {4{fdc_rx[15]}}, fdc_rx };
    wire signed [19:0] fdc_lyn = fdc_xl - fdc_xl1 + fdc_ly - (fdc_ly >>> 8);
    wire signed [19:0] fdc_ryn = fdc_xr - fdc_xr1 + fdc_ry - (fdc_ry >>> 8);
    always @(posedge clk_audio_r) begin
        fdc_lx <= left16_a1;  fdc_ly <= fdc_lyn;
        fdc_rx <= right16_a1; fdc_ry <= fdc_ryn;
    end
    wire signed [15:0] fdc_l16 = (fdc_ly > 20'sd32767) ? 16'sd32767 : (fdc_ly < -20'sd32768) ? -16'sd32768 : fdc_ly[15:0];
    wire signed [15:0] fdc_r16 = (fdc_ry > 20'sd32767) ? 16'sd32767 : (fdc_ry < -20'sd32768) ? -16'sd32768 : fdc_ry[15:0];
    // blend in full-width products (lesson: a narrow assignment context truncates the multiply)
    wire signed [25:0] lmix_p = $signed(fdc_l16) * $signed({1'b0, mgn}) + $signed(player_pcm[15:0])  * $signed({1'b0, pgain});
    wire signed [25:0] rmix_p = $signed(fdc_r16) * $signed({1'b0, mgn}) + $signed(player_pcm[31:16]) * $signed({1'b0, pgain});
    wire signed [16:0] lmix_s = lmix_p >>> 8;
    wire signed [16:0] rmix_s = rmix_p >>> 8;
    wire signed [15:0] lmix16 = (lmix_s > 17'sd32767) ? 16'sd32767 : (lmix_s < -17'sd32768) ? -16'sd32768 : lmix_s[15:0];
    wire signed [15:0] rmix16 = (rmix_s > 17'sd32767) ? 16'sd32767 : (rmix_s < -17'sd32768) ? -16'sd32768 : rmix_s[15:0];

    // Select/blend the audio source BEFORE applying the volume scaling, so that the player
    // obeys the OSD F9 volume level (ctl_vol) just like the fabric machine's audio.
    // Step 14.2: mix the tape loading sound (1-bit ear -> +/-A square, gated by "playing", muteable)
    // into the pre-volume PCM so it obeys the F9 volume (ctl_vol) + the pause mute. Saturating add.
    (* ASYNC_REG="TRUE" *) reg [1:0] tear_aud = 2'b00, tmute_aud = 2'b00, tplay_aud = 2'b00;
    always @(posedge clk_audio_r) begin
        tear_aud  <= {tear_aud[0],  tape_ear};
        tmute_aud <= {tmute_aud[0], ctl_tape_mute};
        tplay_aud <= {tplay_aud[0], tape_playing};
    end
    wire signed [15:0] tape_pcm = (tmute_aud[1] | ~tplay_aud[1]) ? 16'sd0
                                 : (tear_aud[1] ? 16'sd6000 : -16'sd6000);
    wire signed [16:0] lsum = lmix16 + tape_pcm;
    wire signed [16:0] rsum = rmix16 + tape_pcm;
    wire [15:0] src_left  = (lsum > 17'sd32767) ? 16'h7FFF : (lsum < -17'sd32768) ? 16'h8000 : lsum[15:0];
    wire [15:0] src_right = (rsum > 17'sd32767) ? 16'h7FFF : (rsum < -17'sd32768) ? 16'h8000 : rsum[15:0];

    //=============================================================================================
    // Indicators. (led_heart is driven by the shell.)
    //=============================================================================================
    assign led_lock = sp_lock;
endmodule
//-------------------------------------------------------------------------------------------------
