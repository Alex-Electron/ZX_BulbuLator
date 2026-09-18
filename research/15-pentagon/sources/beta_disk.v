//-------------------------------------------------------------------------------------------------
// beta_disk.v - Beta Disk (TR-DOS) для BulbuLator: контроллер WD1793 + декодирование портов Beta Disk
//               + мост подачи секторов от ARM. Этап 3 плана «ПЗУ Пентагона, TR-DOS и дисковод».
//-------------------------------------------------------------------------------------------------
// ЗАЧЕМ. Почти весь пентагоновский софт живёт в TRD/SCL. ПЗУ TR-DOS у нас уже грузится с карты и
// страница переключается трапом (ядро B0071+), но читать дискеты было нечем.
//
// ЧТО ВНУТРИ.
//   - `wd1793` из MiSTer (GPL-2.0-or-later, наш патченный экземпляр в sources/): RWMODE=1 -
//     «сектора подаёт хост», EDSK=0 - поддержка .EDSK не нужна и стоит 4 плитки BRAM из 1.5
//     свободных (замер OOC: EDSK=1 -> 834 LUT / 4.5 плитки; EDSK=0 -> 524 LUT / 0.5 плитки).
//   - декодирование портов Beta Disk: #1F/#3F/#5F/#7F = регистры контроллера (A7=0, addr=A6:A5),
//     #FF = СИСТЕМНЫЙ регистр (наш, не контроллера): выбор привода, сторона, сброс, HLT.
//   - мост к ARM: фабрика просит сектор (LBA), ARM читает 512 байт из образа на карте и вдвигает
//     их в буфер контроллера побайтно.
//
// ПОРТЫ ОТВЕЧАЮТ ТОЛЬКО ПРИ ВСТАВЛЕННОЙ СТРАНИЦЕ ПЗУ TR-DOS (`trdos_on`). Иначе #1F..#FF - чужие
// адреса (на них отзываются джойстик Kempston #1F и много чего ещё), и мы бы поломали штатное
// поведение машины. Это ровно то же правило, по которому живёт настоящий Beta Disk.
//
// БЕЗОПАСНО ПО УМОЛЧАНИЮ: без вставленного образа `ready=0` и `wp=1` - TR-DOS честно скажет, что
// дискеты нет, и НЕ повиснет. Запись на образ в этой версии запрещена намеренно (сначала чтение).
//
// CDC (правило, оплаченное битой памятью Пентагона, см. PROJECT_RULES.md): нагрузку ДЕРЖИМ, синхронизируем
// ТОЛЬКО флаг, и флаг отдаём НА ТАКТ ПОЗЖЕ данных. Байт сектора от ARM живёт в его регистре до
// следующей записи, поэтому на стороне машины он берётся напрямую, а через триггеры идёт лишь тоггл.
//-------------------------------------------------------------------------------------------------
`default_nettype none

module beta_disk (
    // ---------------- сторона машины (домен clk = spclk) ----------------
    input  wire        clk,
    input  wire        ce,            // разрешение такта процессора (pe3M5) - `ce at CPU clock rate`
    input  wire        reset_n,
    input  wire        trdos_on,      // 1 = в окне ПЗУ страница TR-DOS -> порты Beta Disk наши
    input  wire        bdi_always,    // B0079 A/B: 1 = BDI виден и вне окна TR-DOS (MACHINE_CFG bit10)
    input  wire [15:0] cpu_pc,        // B0079: PC для пассивной трассы прямых обращений к BDI

    input  wire        iorq_n,        // шина Z80 (активные-низкие, как в ядре)
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire        m1_n,
    input  wire [7:0]  a,             // младший байт адреса
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    output wire        oe,            // 1 = данные на IN отдаём мы

    // ---------------- мост к ARM (домен aclk) ----------------
    input  wire        aclk,
    input  wire [31:0] arm_ctl,       // 0x164 FDC_CTL (защёлкивается по arm_ctl_we)
    input  wire        arm_ctl_we,
    input  wire [7:0]  arm_data,      // 0x168 FDC_DATA: байт сектора
    input  wire        arm_data_we,
    output wire [31:0] fdc_stat,      // 0x160 FDC_STAT (читается ARM-ом)
    output wire [31:0] fdc_stat2,     // 0x16C FDC_STAT2
    // 1 while Beta Disk owns the classic port set (TR-DOS page, sticky session, or bdi_always).
    // Used to keep SAA1099 off port #FF so BDI system register is not dual-claimed.
    output wire        bdi_open,
    // B0087: 1, пока дисковод РЕАЛЬНО работает (контроллер busy/DRQ или подача сектора от ARM)
    // плюс короткий хвост. Нужен для арбитража порта #FF с SAA1099 - см. комментарий в main.v.
    output wire        bdi_busy
);
    //=============================================================================================
    // Декодирование портов Beta Disk. Классика: A7=0 -> регистр контроллера (A6:A5 = номер),
    // A7=1 & A6:A5=11 (#FF) -> системный регистр.
    //=============================================================================================
    // The TR-DOS ROM automap lifetime and the Beta Disk hardware lifetime are
    // different things. A custom loader may leave the 0x0000-0x3FFF ROM window
    // and continue talking to the controller from RAM. Keep the hardware session
    // open after the first TR-DOS entry and close it only on machine reset.
    reg bdi_session = 1'b0;
    always @(posedge clk) begin
        if (!reset_n)
            bdi_session <= 1'b0;
        else if (trdos_on)
            bdi_session <= 1'b1;
    end

    wire io_active = (trdos_on | bdi_session | bdi_always) & ~iorq_n & m1_n;
    assign bdi_open = trdos_on | bdi_session | bdi_always;

    // Decode only the five canonical low-byte addresses. The old partial decode
    // aliased port #FE into the system register when bdi_always was enabled, so
    // border/beeper writes changed drive, side and controller reset state.
    wire fdc_sel   = io_active & ~a[7] & (a[4:0] == 5'h1F); // #1F/#3F/#5F/#7F
    wire sys_sel   = io_active & (a == 8'hFF);              // #FF only
    wire fdc_rd    = fdc_sel & ~rd_n;
    wire fdc_wr    = fdc_sel & ~wr_n;

    // Системный регистр Beta Disk (#FF): бит0-1 привод, бит2 СБРОС контроллера (активный-низкий),
    // бит3 HLT, бит4 СТОРОНА (инвертирована на настоящей плате), бит6 плотность.
    reg [7:0] sysreg = 8'h00;
    always @(posedge clk) if (!reset_n) sysreg <= 8'h00; else if (ce && sys_sel && ~wr_n) sysreg <= din;
    wire side       = ~sysreg[4];
    wire fdc_rst_n  = reset_n & sysreg[2];

    //=============================================================================================
    // Мост ARM -> фабрика. Уровни (образ вставлен, размер, только чтение, геометрия) защёлкиваются
    // в домене aclk и переносятся как КВАЗИСТАТИКА (двумя триггерами), команды - тогглами.
    //=============================================================================================
    reg [19:0] img_size_a = 20'd0;
    reg [2:0]  size_code_a = 3'd1;      // 1 = 16 секторов по 256 Б = раскладка TRD
    reg        layout_a  = 1'b0;        // 0 = дорожка-сторона-сектор (TRD)
    reg        wp_a      = 1'b1;        // по умолчанию защита записи ВКЛЮЧЕНА
    reg        ready_a   = 1'b0;        // дискеты нет, пока ARM не вставил образ
    reg        mount_tog_a = 1'b0, ackb_tog_a = 1'b0, acke_tog_a = 1'b0, data_tog_a = 1'b0;
    reg [7:0]  data_a    = 8'd0;
    reg        data_a_pend = 1'b0;      // объявлено ДО использования: Verilog не терпит обратных ссылок
    // B0083: диагностический выбор одной из 12 записей кольца. Команды FDC_CTL 4..15 раньше были
    // свободны; bit10 тоже свободен. Поэтому JTAG может выбрать slot=(cmd-4), word=bit10, не меняя
    // протокол подачи секторов (1/2/3) и не добавляя новых AXI-регистров.
    reg [3:0]  dbg_sel_a = 4'd0;
    reg        dbg_word_a = 1'b0;
    // B0089 ЗАПИСЬ: свободный бит 11 FDC_CTL = «режим вычитывания буфера». В нём строб FDC_DATA
    // НЕ пишет в буфер, а только шагает адресом, а FDC_STAT2 отдаёт байт буфера вместо
    // отладочного кольца. Новых AXI-регистров не нужно, а кольцо при записи и не используется.
    reg        rd_mode_a = 1'b0;

    always @(posedge aclk) begin
        if (arm_ctl_we) begin
            wp_a        <= arm_ctl[4];
            rd_mode_a   <= arm_ctl[11];              // B0089
            ready_a     <= arm_ctl[5];
            size_code_a <= arm_ctl[8:6];
            layout_a    <= arm_ctl[9];
            img_size_a  <= arm_ctl[31:12];
            if (arm_ctl[3:0] >= 4'd4) begin
                dbg_sel_a  <= arm_ctl[3:0] - 4'd4;
                dbg_word_a <= arm_ctl[10];
            end
            case (arm_ctl[3:0])
                4'd1: ackb_tog_a  <= ~ackb_tog_a;   // начать подачу сектора (поднять sd_ack, адрес в 0)
                4'd2: acke_tog_a  <= ~acke_tog_a;   // сектор подан целиком (снять sd_ack)
                4'd3: mount_tog_a <= ~mount_tog_a;  // образ вставлен/сменён
                default: ;
            endcase
        end
        // Байт сектора: сначала данные, ЗАТЕМ (следующим тактом) тоггл - иначе на стороне машины
        // флаг может обогнать байт ровно так, как это было в мастере памяти (см. PROJECT_RULES.md).
        if (arm_data_we) begin data_a <= arm_data; data_a_pend <= 1'b1; end
        else if (data_a_pend) begin data_tog_a <= ~data_tog_a; data_a_pend <= 1'b0; end
    end

    // ---- в домен машины ----
    (* ASYNC_REG="TRUE" *) reg [2:0] mnt_s = 3'd0, ackb_s = 3'd0, acke_s = 3'd0, dat_s = 3'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] wp_s = 2'b11, rdy_s = 2'd0, lay_s = 2'd0;
    (* ASYNC_REG="TRUE" *) reg [5:0] sz_s = 6'b001001;
    (* ASYNC_REG="TRUE" *) reg [3:0] dbg_sel_s0 = 4'd0, dbg_sel_s1 = 4'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] dbg_word_s = 2'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] rd_mode_s = 2'd0;          // B0089
    always @(posedge clk) begin
        mnt_s  <= {mnt_s[1:0],  mount_tog_a};
        ackb_s <= {ackb_s[1:0], ackb_tog_a};
        acke_s <= {acke_s[1:0], acke_tog_a};
        dat_s  <= {dat_s[1:0],  data_tog_a};
        wp_s   <= {wp_s[0],  wp_a};
        rdy_s  <= {rdy_s[0], ready_a};
        lay_s  <= {lay_s[0], layout_a};
        sz_s   <= {sz_s[2:0], size_code_a};
        dbg_sel_s0 <= dbg_sel_a;
        dbg_sel_s1 <= dbg_sel_s0;
        dbg_word_s <= {dbg_word_s[0], dbg_word_a};
        rd_mode_s  <= {rd_mode_s[0],  rd_mode_a};                // B0089
    end
    wire mnt_pulse  = mnt_s[2]  ^ mnt_s[1];
    wire ackb_pulse = ackb_s[2] ^ ackb_s[1];
    wire acke_pulse = acke_s[2] ^ acke_s[1];
    wire dat_pulse  = dat_s[2]  ^ dat_s[1];

    // img_size пересекает границу как квазистатика: ARM меняет его ТОЛЬКО перед импульсом mount,
    // поэтому к моменту его прихода значение стоит неподвижно уже много тактов.
    (* ASYNC_REG="TRUE" *) reg [19:0] img_size_s0 = 20'd0, img_size_s1 = 20'd0;
    always @(posedge clk) begin img_size_s0 <= img_size_a; img_size_s1 <= img_size_s0; end

    // MiSTer wd1793 expects img_mounted as a stable level and detects its
    // falling edge as "new image is ready". A one-cycle pulse only triggered
    // the edge when it happened to overlap the CPU-rate CE. Keep a stable
    // mounted level and toggle it for two machine clocks on each mount event.
    reg       img_mounted_sp = 1'b1;
    reg [1:0] img_mount_hold = 2'd0;
    always @(posedge clk) begin
        if (!reset_n) begin
            img_mounted_sp <= 1'b1;
            img_mount_hold <= 2'd0;
        end else if (mnt_pulse) begin
            img_mounted_sp <= 1'b0;
            img_mount_hold <= 2'd3;
        end else if (img_mount_hold != 0) begin
            img_mount_hold <= img_mount_hold - 1'b1;
            if (img_mount_hold == 1)
                img_mounted_sp <= 1'b1;
        end
    end

    //=============================================================================================
    // Подача сектора: sd_ack держится, пока ARM вдвигает 512 байт; адрес в буфере считает фабрика.
    //=============================================================================================
    reg        sd_ack_sp = 1'b0;
    reg [8:0]  buf_addr  = 9'd0;
    reg        buf_wr    = 1'b0;
    reg [7:0]  sec_cnt   = 8'd0;        // диагностика: сколько секторов подано
    always @(posedge clk) begin
        buf_wr <= 1'b0;
        if (!reset_n) begin sd_ack_sp <= 1'b0; buf_addr <= 9'd0; end
        else begin
            if (ackb_pulse) begin sd_ack_sp <= 1'b1; buf_addr <= 9'd0; end
            // ВАЖНО (стоило «Disk Error, Trk 0 sec 9» на первом же прогоне): строб записи
            // РЕГИСТРИРУЕТСЯ, то есть попадает в BRAM в СЛЕДУЮЩЕМ такте. Если инкрементировать
            // адрес в одном такте со стробом, байт ляжет по адресу+1 и весь сектор уедет на байт -
            // контроллер увидит мусор вместо заголовка сектора. Инкремент строго ПОСЛЕ записи.
            // B0089: в режиме вычитывания (запись машины на дискету) байт НЕ пишем - иначе
            // затёрли бы ровно те данные, которые собираемся отдать хосту; только шагаем адресом.
            if (dat_pulse && sd_ack_sp && rd_mode_s[1]) buf_addr <= buf_addr + 9'd1;
            else if (dat_pulse && sd_ack_sp)            buf_wr   <= 1'b1;
            else if (buf_wr)                            buf_addr <= buf_addr + 9'd1;
            if (acke_pulse) begin sd_ack_sp <= 1'b0; sec_cnt <= sec_cnt + 8'd1; end
        end
    end
    // Байт берём НАПРЯМУЮ из держащего регистра ARM-а (не с конца своего конвейера) - тот самый
    // приём, которым закрыта гонка в мастере памяти.
    wire [7:0] buf_data = data_a;

    //=============================================================================================
    // Сам контроллер
    //=============================================================================================
    wire [7:0]  wd_dout;
    wire        wd_drq, wd_intrq, wd_busy, wd_prepare;
    wire [31:0] wd_lba;
    wire        wd_sd_rd, wd_sd_wr;
    wire [7:0]  wd_buff_rd;      // B0089: содержимое буфера контроллера (то, что записала машина)

    wire [15:0] wd_dbg;                     // B0090: внутреннее состояние контроллера в кольцо
    wire  [7:0] wd_wrenb;                   // B0092: срабатываний записи процессора в буфер
    wire [12:0] wd_addr;                    // B0093: {sd_block, byte_addr}
    wire        wd_cpu_wr;                  // B0094: настоящая запись процессора в буфер
    wire  [8:0] wd_cpu_wa;
    wire  [7:0] wd_cpu_wd;
    wd1793 #(.RWMODE(1), .EDSK(0)) fdc (
        .clk_sys   (clk),
        .ce        (ce),
        .dbg_io    (wd_dbg),
        .dbg_wrenb (wd_wrenb),
        .dbg_addr  (wd_addr),
        .cpu_wr_b  (wd_cpu_wr),
        .cpu_wr_a  (wd_cpu_wa),
        .cpu_wr_d  (wd_cpu_wd),
        .reset     (~fdc_rst_n),          // у модуля сброс АКТИВНЫЙ-ВЫСОКИЙ
        .io_en     (fdc_sel),
        .rd        (fdc_rd),
        .wr        (fdc_wr),
        .addr      (a[6:5]),
        .din       (din),
        .dout      (wd_dout),
        .drq       (wd_drq),
        .intrq     (wd_intrq),
        .busy      (wd_busy),
        .wp        (wp_s[1]),
        .size_code (sz_s[5:3]),
        .layout    (lay_s[1]),
        .side      (side),
        .hlt       (sysreg[3]),
        .slow_disk (1'b0),      // B0098: быстрый темп байта. «Как настоящий» вернём опцией меню,
                                // если найдётся загрузчик, которому он нужен.
        .ra_trk_to_sec (1'b0),   // B0095: как в эталоне MiSTer. Для Elysium вернём опцией машины,
                                // когда запись в TR-DOS будет проверена.
        .ready     (rdy_s[1]),
        // подача секторов хостом
        .img_mounted (img_mounted_sp),
        .img_size    (img_size_s1),
        .prepare     (wd_prepare),
        .sd_lba      (wd_lba),
        .sd_rd       (wd_sd_rd),
        .sd_wr       (wd_sd_wr),
        .sd_ack      (sd_ack_sp),
        .sd_buff_addr(buf_addr),
        .sd_buff_dout(buf_data),
        .sd_buff_din (wd_buff_rd),
        .sd_buff_wr  (buf_wr),
        // ветка буферного ОЗУ (RWMODE=0) не используется
        .input_active(1'b0), .input_addr(20'd0), .input_data(8'd0), .input_wr(1'b0),
        .buff_addr(), .buff_read(), .buff_din(8'd0)
    );

    // System port #FF readback must mirror real Beta/zx-evo behaviour:
    //   {INTRQ, DRQ, 1, SIDE_raw, HLT, /RESET, DS1, DS0}
    // Custom loaders (Elysium) write #FF then read it back to confirm side/drive/HLT.
    // Returning 6'b111111 made every drive select look like 3 and broke post-load code.
    assign dout = sys_sel
                ? {wd_intrq, wd_drq, 1'b1, sysreg[4], sysreg[3], sysreg[2], sysreg[1:0]}
                : wd_dout;
    assign oe   = (fdc_sel | sys_sel) & ~rd_n;

    //=============================================================================================
    // Перехват ЗАПИСЕЙ в регистры контроллера. Без него нельзя отличить «мы отдали не те данные» от
    // «TR-DOS попросил не то, что мы думаем»: команда, дорожка и сектор видны только здесь.
    //=============================================================================================
    reg [7:0] last_cmd = 8'd0, last_trk = 8'd0, last_sec = 8'd0, last_dat = 8'd0;
    reg [7:0] wr_cnt = 8'd0;
    always @(posedge clk) if (ce && fdc_wr) begin
        wr_cnt <= wr_cnt + 8'd1;
        case (a[6:5])
            2'd0: last_cmd <= din;
            2'd1: last_trk <= din;
            2'd2: last_sec <= din;
            default: last_dat <= din;
        endcase
    end

    // B0079: ELYSTATE делает известное нестандартное обращение к BDI уже после показа лица.
    // Старый декодер в этот момент закрыт trdos_on=0, поэтому сам WD1793 такого цикла не видит и
    // last_cmd выше ничего не доказывает. Ловим ТОЧНЫЕ классические адреса независимо от io_active:
    // #1F/#3F/#5F/#7F и #FF. Один I/O-цикл длится несколько тактов, поэтому считаем его один раз.
    // Трасса пассивна: при bdi_always=0 поведение машины остаётся бит-в-бит прежним.
    wire bdi_exact = ~iorq_n & m1_n &
                     (((a[4:0] == 5'h1F) && ~a[7]) || (a == 8'hFF));
    reg bdi_exact_seen = 1'b0;
    reg [5:0] bdi_trace_count = 6'd0;
    reg       bdi_trace_wr = 1'b0;
    reg [7:0] bdi_trace_port = 8'd0;
    reg [15:0] bdi_trace_pc = 16'd0;
    // B0083: кольцо значимых BDI-транзакций. Повторные status/system polls после одной команды
    // намеренно не пишутся: иначе вечный цикл в TR-DOS за миллисекунды уничтожает саму причину.
    // word0 = {seq[6:0], write, port, PC}; word1 = {data, last_cmd, last_track, last_sector}.
    reg [31:0] bdi_dbg0 [0:11];
    reg [31:0] bdi_dbg1 [0:11];
    reg [3:0]  bdi_dbg_wptr = 4'd0;
    reg [6:0]  bdi_dbg_seq = 7'd0;
    reg        bdi_status_logged = 1'b0;
    reg        bdi_sys_logged = 1'b0;
    // B0090: TR-DOS дёргает системный регистр #FF в ТЕСНОМ ЦИКЛЕ ожидания (наблюдалось девять
    // записей подряд из PC=0x02C0 с чередованием 0x3C/0x34). За микросекунды они вытесняли из
    // 12 слотов всю историю команды - именно это и помешало разобрать отказ записи. Логируем
    // не больше двух таких записей на команду; счётчик сбрасывается новой командой.
    reg [1:0]  bdi_sysw_cnt = 2'd0;
    integer bdi_di;
    wire bdi_cmd_write = ~wr_n && (a == 8'h1F);
    wire bdi_sysw_skip = ~wr_n && (a == 8'hFF) && (bdi_sysw_cnt == 2'd2);   // B0090
    wire bdi_log_event = (~wr_n && !bdi_sysw_skip) ||
                         (~rd_n && (a == 8'h7F)) ||
                         (~rd_n && (a == 8'h1F) && !bdi_status_logged) ||
                         (~rd_n && (a == 8'hFF) && !bdi_sys_logged);
    wire [7:0] bdi_io_data = ~wr_n ? din :
                             ((a == 8'hFF) ? {wd_intrq, wd_drq, 1'b1, sysreg[4], sysreg[3], sysreg[2], sysreg[1:0]}
                                           : wd_dout);
    always @(posedge clk) begin
        if (!reset_n) begin
            bdi_exact_seen  <= 1'b0;
            bdi_trace_count <= 6'd0;
            bdi_trace_wr    <= 1'b0;
            bdi_trace_port  <= 8'd0;
            bdi_trace_pc    <= 16'd0;
            bdi_dbg_wptr     <= 4'd0;
            bdi_dbg_seq      <= 7'd0;
            bdi_status_logged <= 1'b0;
            bdi_sys_logged   <= 1'b0;
            for (bdi_di = 0; bdi_di < 12; bdi_di = bdi_di + 1) begin
                bdi_dbg0[bdi_di] <= 32'd0;
                bdi_dbg1[bdi_di] <= 32'd0;
            end
        end else begin
            if (!bdi_exact)
                bdi_exact_seen <= 1'b0;
            else if (ce && !bdi_exact_seen) begin
                bdi_exact_seen <= 1'b1;
                if (bdi_trace_count != 6'h3F)
                    bdi_trace_count <= bdi_trace_count + 6'd1;
                bdi_trace_wr   <= ~wr_n;
                bdi_trace_port <= a;
                bdi_trace_pc   <= cpu_pc;
                if (bdi_cmd_write) begin
                    bdi_status_logged <= 1'b0;
                    bdi_sys_logged    <= 1'b0;
                    bdi_sysw_cnt      <= 2'd0;      // B0090: новая команда - счётчик #FF заново
                end
                else if (~wr_n && (a == 8'hFF) && (bdi_sysw_cnt != 2'd2))
                    bdi_sysw_cnt <= bdi_sysw_cnt + 2'd1;
                if (bdi_log_event) begin
                    bdi_dbg0[bdi_dbg_wptr] <= {bdi_dbg_seq, ~wr_n, a, cpu_pc};
                    // B0090: word1 = {данные, последняя команда, состояние контроллера}.
                    // Дорожка/сектор оттуда убраны и НЕ потеряны: их записывает сам процессор,
                    // и эти записи попадают в кольцо как события портов #3F/#5F.
                    // B0096: дорожка и сектор ВАЖНЕЕ отладочного слова - по ним видно, о какой
                    // именно записи просил TR-DOS (сектор каталога это дорожка 0 сектор 1).
                    bdi_dbg1[bdi_dbg_wptr] <= {bdi_io_data, last_cmd, last_trk, last_sec};
                    bdi_dbg_seq <= bdi_dbg_seq + 7'd1;
                    bdi_dbg_wptr <= (bdi_dbg_wptr == 4'd11) ? 4'd0 : bdi_dbg_wptr + 4'd1;
                    if (~rd_n && (a == 8'h1F)) bdi_status_logged <= 1'b1;
                    if (~rd_n && (a == 8'hFF)) bdi_sys_logged    <= 1'b1;
                end
            end
        end
    end

    //=============================================================================================
    // Телеметрия для ARM (0x160). Без неё подача секторов не наблюдаема ниоткуда.
    //=============================================================================================
    //=============================================================================================
    // B0087: ЖИВАЯ активность дисковода для арбитража порта #FF с SAA1099.
    // `bdi_open` ЛИПКАЯ: сессия держится до сброса машины - это нужно загрузчикам вроде
    // Элизиума, которые уходят из окна ПЗУ TR-DOS и продолжают говорить с контроллером из ОЗУ.
    // Глушить по ней SAA НЕЛЬЗЯ: пак, загруженный С ДИСКЕТЫ, замолчал бы на весь сеанс.
    // Поэтому наружу идёт отдельный сигнал «сейчас идёт обмен» + хвост ~4.6 мс, чтобы промежутки
    // между секторами одной операции не отпускали порт посреди загрузки.
    // ВНИМАНИЕ: wd_prepare сюда брать НЕЛЬЗЯ - при EDSK=0 в wd1793.sv стоит
    // `assign prepare = img_mounted`, то есть это УРОВЕНЬ на всё время, пока образ вставлен.
    // С ним bdi_busy залип бы в единице и SAA молчал бы ровно как до B0087.
    // Здесь только переходные признаки настоящего обмена.
    wire       bdi_act_raw = wd_busy | wd_drq | wd_sd_rd | wd_sd_wr | sd_ack_sp;
    reg [17:0] bdi_act_hold = 18'd0;
    always @(posedge clk) begin
        if (!reset_n)                bdi_act_hold <= 18'd0;
        else if (bdi_act_raw)        bdi_act_hold <= 18'd262143;  // spclk ~56.7 МГц -> ~4.6 мс
        else if (bdi_act_hold != 0)  bdi_act_hold <= bdi_act_hold - 18'd1;
    end
    assign bdi_busy = bdi_act_raw | (bdi_act_hold != 18'd0);

    (* ASYNC_REG="TRUE" *) reg [31:0] stat_s0 = 32'd0, stat_s1 = 32'd0;
    wire [31:0] stat_sp = {sec_cnt,                                  // [31:24] sectors supplied
                           trdos_on, sd_ack_sp, wd_drq, wd_intrq,    // [23:20]
                           wd_busy, wd_prepare, wd_sd_wr, wd_sd_rd,  // [19:16]
                           bdi_session, 1'b0, wd_lba[10:0], sysreg[2:0]}; // [15] session, [13:3] LBA
    always @(posedge aclk) begin stat_s0 <= stat_sp; stat_s1 <= stat_s0; end
    assign fdc_stat = stat_s1;

    // 0x16C, B0083: выбранное слово кольца. Выбор через FDC_CTL:
    // low nibble 4..15 = physical slot 0..11, bit10 = word0/word1.
    (* ASYNC_REG="TRUE" *) reg [31:0] st2_s0 = 32'd0, st2_s1 = 32'd0;
    // B0089: в режиме вычитывания это байт буфера по текущему адресу, иначе - отладочное кольцо.
    /*------------------------------------------------------------------ B0094 ИСХОДЯЩАЯ ПАМЯТЬ
      Своя копия сектора, собранная НАШЕЙ логикой: пишет и хост (когда подаёт сектор), и
      процессор (когда пишет байты данных). ARM вычитывает сектор отсюда, поэтому запись больше
      не зависит от того, как видит общий буфер контроллера. LUTRAM: BRAM у нас 59 из 60.
      Источники не пересекаются по времени (подача - до данных, данные - после), поэтому одного
      порта записи достаточно. */
    (* ram_style = "distributed" *) reg [7:0] outbox [0:511];
    wire       ob_we = buf_wr | wd_cpu_wr;
    wire [8:0] ob_wa = buf_wr ? buf_addr : wd_cpu_wa;
    wire [7:0] ob_wd = buf_wr ? buf_data : wd_cpu_wd;
    always @(posedge clk) if (ob_we) outbox[ob_wa] <= ob_wd;   /* домен clk: в нём живут buf_wr и запись процессора */
    wire [7:0] ob_q = outbox[buf_addr];

    /*-------------------------------------------------------------- B0097 ДИАПАЗОН ЗАПИСИ
      Какие адреса машина реально записала за текущую команду. ARM по ним собирает сектор из
      файла и накладывает только записанное - тогда чужой хвост в буфере не попадает в образ.
      Сброс - записью КОМАНДЫ в порт #1F (a[6:5]==0), чтобы диапазон относился к этой операции. */
    reg [8:0] cpu_min = 9'h1FF;
    reg [8:0] cpu_max = 9'd0;
    reg       sd_rd_d = 1'b0;      // B0100: фронт начала подачи блока
    always @(posedge clk) begin
        sd_rd_d <= wd_sd_rd;
        if (!reset_n) begin cpu_min <= 9'h1FF; cpu_max <= 9'd0; end
        // B0100: сброс и по НАЧАЛУ ПОДАЧИ блока. Внутри многосекторной команды новой команды
        // нет, и диапазон накапливался - на втором секторе разрешал наложить весь блок, затирая
        // хорошие байты из файла. Подача всегда предшествует записи байтов машиной.
        else if ((ce && fdc_wr && (a[6:5] == 2'd0)) || (wd_sd_rd && !sd_rd_d)) begin
            cpu_min <= 9'h1FF; cpu_max <= 9'd0;
        end else if (wd_cpu_wr) begin
            if (wd_cpu_wa < cpu_min) cpu_min <= wd_cpu_wa;
            if (wd_cpu_wa > cpu_max) cpu_max <= wd_cpu_wa;
        end
    end

    // B0097: в слове вычитывания теперь ДИАПАЗОН записанного машиной (6+9+9+8 = 32).
    wire [31:0] st2_sp = rd_mode_s[1] ? {6'd0, cpu_min, cpu_max, ob_q}
                                      : (dbg_word_s[1] ? bdi_dbg1[dbg_sel_s1] : bdi_dbg0[dbg_sel_s1]);
    always @(posedge aclk) begin st2_s0 <= st2_sp; st2_s1 <= st2_s0; end
    assign fdc_stat2 = st2_s1;
endmodule
`default_nettype wire
