`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_divmmc_card.sv - стенд карты SD. Доказывает ОДНО утверждение, и доказывает его буквально:
//
//     последовательность байт, которую получает МАШИНА, байт-в-байт равна той, которую на тех же
//     входах намеревает эталон `arm/divmmc_card.c`.
//
// Как именно. Эталон не переписан на SystemVerilog - он ПОДКЛЮЧЁН ЧЕРЕЗ DPI-C тем же исходником,
// который прошёл 10 000 секторов на хосте и поднял настоящую esxDOS 0.8.9 в ZEsarUX (мост -
// `tb_divmmc_dpi.c`). Переписанная модель была бы ВТОРОЙ реализацией и расходилась бы с первой
// молча; сверять надо с тем самым кодом.
//
// Через что. В стенде стоят НАСТОЯЩИЕ `usd.v` и `spi.v` из `cores/zx/src/`, а «процессор» стенда
// делает ровно то же, что Z80: `OUT (#E7),n` для выбора карты и `OUT (#EB),n` / `IN A,(#EB)` для
// обмена. Поэтому проверяется вся цепь целиком, включая отставание байта на один обмен
// (`spi.v:30`, `md <= sd` в момент СТАРТА следующей передачи) - то самое место, где ошибка не
// выглядела бы ошибкой.
//
// Что проверяется, кроме потока:
//   1. кадрирование по старт-биту не срывается на полезной нагрузке CMD24 со старшими битами `01`
//      (сектор набит байтами 0x40..0x7F - каждый из них выглядит как начало команды);
//   2. снятие CS посреди передачи не ломает состояние, а защёлка APP_CMD переживает его (esxDOS
//      снимает выбор между CMD55 и ACMD41 - L1D67 -> L1D71 -> L1D5E);
//   3. на КАЖДУЮ передачу приходится ровно восемь фронтов `ck` - выравнивание байта физическое;
//   4. 🥇 от карты НЕ ПОДНИМАЕТСЯ НИ ОДНОГО ТАКТА ОЖИДАНИЯ: у модуля нет выхода в `cpu_hold`
//      вовсе, и темп обменов при включённой карте измеренно равен темпу при выключенной.
//
// Запуск (ThinkPad):
//   xsc tb_divmmc_dpi.c
//   xvlog -sv tb_divmmc_card.sv && xvlog divmmc_card.v ../../../cores/zx/src/usd.v ../../../cores/zx/src/spi.v
//   xelab -svlog ... -sv_lib dpi tb_divmmc_card -R -testplusarg NSEC=10000
//-------------------------------------------------------------------------------------------------
module tb_divmmc_card;

    import "DPI-C" function void dm_attach(input int vol_sectors);
    import "DPI-C" function void dm_cs(input int selected);
    import "DPI-C" function void dm_fast_ack(input int on);          // B0150
    import "DPI-C" function int  dm_xfer(input int mosi);
    import "DPI-C" function int  dm_sectors();
    import "DPI-C" function int  dm_state();
    import "DPI-C" function int  dm_csd(input int i);
    import "DPI-C" function int  dm_cid(input int i);
    import "DPI-C" function int  dm_sector_byte(input int lba, input int i);
    import "DPI-C" function int  dm_wr_count();
    import "DPI-C" function int  dm_wr_lba();
    import "DPI-C" function int  dm_wr_byte(input int i);

    //---------------------------------------------------------------------------------------------
    // Такты. Машина - 56.667 МГц (17.647 нс). Разрешения 7 МГц у нас поджаты до /2 вместо /8: это
    // РЕЖИМ ВАРПА 4x, самый быстрый из настоящих (clock_zx.v:57-58), и он же худший для конвейера
    // выборки байта. Прогонять стенд на /8 смысла нет - там втрое больше запаса и втрое дольше.
    //---------------------------------------------------------------------------------------------
    localparam real TCLK = 17.647;
    reg clk = 0;   always #(TCLK/2.0) clk = ~clk;
    reg aclk = 0;  always #5.0        aclk = ~aclk;      // 100 МГц, домен оболочки

    reg [1:0] cediv = 2'd0;
    reg cep = 0, cen = 0;
    always @(posedge clk) begin
        cediv <= cediv + 2'd1;
        cep <= (cediv[0] == 1'b1);
        cen <= (cediv[0] == 1'b0);
    end

    integer ce_ticks = 0;
    always @(posedge clk) if (cen) ce_ticks = ce_ticks + 1;

    //---------------------------------------------------------------------------------------------
    // Шина «процессора» и настоящие usd/spi
    //---------------------------------------------------------------------------------------------
    reg        iorq_n = 1, wr_n = 1, rd_n = 1;
    reg  [7:0] abus = 8'h00, dbus = 8'h00;
    wire [7:0] usdQ;
    wire       sd_cs_n, sd_ck, sd_mosi, sd_miso;

    usd uSD (
        .clock(clk), .cep(cep), .cen(cen),
        .iorq(iorq_n), .wr(wr_n), .rd(rd_n),
        .d(dbus), .q(usdQ), .a(abus),
        .cs(sd_cs_n), .ck(sd_ck), .miso(sd_miso), .mosi(sd_mosi)
    );

    reg         card_en = 1'b1;
    reg         rst_n   = 1'b0;
    reg         arst_n  = 1'b0;
    reg  [31:0] dut_ctl = 32'd0, dut_cap = 32'd0, dut_bufa = 32'd0, dut_bufw = 32'd0;
    reg         dut_ctl_we = 1'b0, dut_bufa_we = 1'b0, dut_bufw_we = 1'b0, dut_bufr_re = 1'b0;
    wire [31:0] dut_bufa_q, dut_bufr_q, dut_stat, dut_lba, dut_dbg;

    divmmc_card dut (
        .clk(clk), .ce(cen), .rst_n(rst_n), .en(card_en),
        .cs_n(sd_cs_n), .sck(sd_ck), .mosi(sd_mosi), .miso(sd_miso),
        .map_dbg(9'd0),
        .aclk(aclk), .arst_n(arst_n),
        .ctl(dut_ctl), .ctl_we(dut_ctl_we), .cap_in(dut_cap),
        .bufa_in(dut_bufa), .bufa_we(dut_bufa_we),
        .bufw_in(dut_bufw), .bufw_we(dut_bufw_we), .bufr_re(dut_bufr_re),
        .bufa_q(dut_bufa_q), .bufr_q(dut_bufr_q),
        .stat(dut_stat), .lba_q(dut_lba), .dbg(dut_dbg)
    );

    //---------------------------------------------------------------------------------------------
    // 🥇 ГЛАВНЫЙ АССЕРТ ЗАДАНИЯ. Такта ожидания от карты быть не может ПО ПОСТРОЕНИЮ: у модуля один
    // выход в домен машины - `miso`, и ни одного провода в `cpu_hold`. Держим это утверждение
    // проверяемым, а не декларативным: сигнал заведён и сторожится, и если кто-то однажды заведёт
    // сюда настоящий провод, стенд отвалится в ту же секунду. Плюс ниже мерится ТЕМП обменов.
    //---------------------------------------------------------------------------------------------
    wire cpu_hold = 1'b0;
    integer hold_seen = 0;
    always @(posedge clk) if (cpu_hold !== 1'b0) hold_seen = hold_seen + 1;

    // Счётчик фронтов ck - им доказывается физическое кадрирование байта.
    integer ck_edges = 0;
    reg ck_d = 1'b0;
    always @(posedge clk) begin
        if (sd_ck & ~ck_d) ck_edges = ck_edges + 1;
        ck_d <= sd_ck;
    end

    //---------------------------------------------------------------------------------------------
    integer errors = 0, checks = 0;
    integer got_r1 = 0;    // пришёл ли R1b на стоп-команду (сценарий 7)
    integer exp_pipe = -1;              // байт карты из ПРЕДЫДУЩЕГО обмена (то, что отдаст spi.v)
    integer xfers = 0;
    string  phase = "init";

    /* xsim не позволяет брать разряды у результата функции DPI - оборачиваем через переменную.
       🥇 И ЕЩЁ ОДНО, дороже: НЕСКОЛЬКО вызовов DPI в ОДНОМ выражении xsim считает неверно. Из
       `{f(3),f(2),f(1),f(0)}` верным приходит только старший разряд, в остальные попадает значение
       ПОСЛЕДНЕГО вызова. Стенд из-за этого сначала «доказал» отказ модуля: буфер наполнялся мусором
       (0x32404040 вместо 0x32000E40), а виноват был стенд. Правило: один вызов DPI - одно
       присваивание. */
    function automatic logic [7:0] sb(input int lba, input int i);
        int v; begin v = dm_sector_byte(lba, i); sb = v[7:0]; end
    endfunction
    function automatic logic [7:0] scsd(input int i);
        int v; begin v = dm_csd(i); scsd = v[7:0]; end
    endfunction
    function automatic logic [7:0] scid(input int i);
        int v; begin v = dm_cid(i); scid = v[7:0]; end
    endfunction
    function automatic logic [7:0] swb(input int i);
        int v; begin v = dm_wr_byte(i); swb = v[7:0]; end
    endfunction

    task automatic fail(input string what, input int got, input int want);
        errors = errors + 1;
        if (errors <= 25)
            $display("ОТКАЗ [%0s] обмен %0d: получено %02h, эталон %02h", what, xfers, got, want);
    endtask

    task automatic ce_wait(input int n);
        int target;
        begin target = ce_ticks + n; wait (ce_ticks >= target); end
    endtask

    //---- порт машины ----------------------------------------------------------------------------
    task automatic port_out(input [7:0] p, input [7:0] v);
        begin
            @(posedge clk); #1; abus = p; dbus = v; iorq_n = 0; wr_n = 0;
            ce_wait(3);
            @(posedge clk); #1; iorq_n = 1; wr_n = 1;
        end
    endtask

    task automatic port_in(output [7:0] v);
        begin
            @(posedge clk); #1; abus = 8'hEB; iorq_n = 0; rd_n = 0;
            ce_wait(4);                       // Z80 забирает байт в конце цикла - к этому моменту
            v = usdQ;                         // `md` уже загружен байтом предыдущего обмена
            @(posedge clk); #1; iorq_n = 1; rd_n = 1;
        end
    endtask

    //---- один обмен: и по железу, и по эталону ---------------------------------------------------
    task automatic xfer_wr(input [7:0] v);
        int ck0;
        begin
            ck0 = ck_edges;
            port_out(8'hEB, v);
            ce_wait(17);
            xfers = xfers + 1;
            if (ck_edges - ck0 != 8) begin
                errors = errors + 1;
                $display("ОТКАЗ кадрирования: на обмен %0d пришлось %0d фронтов ck вместо 8",
                         xfers, ck_edges - ck0);
            end
            exp_pipe = dm_xfer(int'(v));
        end
    endtask

    task automatic xfer_rd(output [7:0] got);
        int ck0;
        begin
            ck0 = ck_edges;
            port_in(got);
            ce_wait(17);
            xfers = xfers + 1;
            if (ck_edges - ck0 != 8) begin
                errors = errors + 1;
                $display("ОТКАЗ кадрирования: на обмен %0d пришлось %0d фронтов ck вместо 8",
                         xfers, ck_edges - ck0);
            end
            if (exp_pipe >= 0) begin
                checks = checks + 1;
                if (int'(got) !== exp_pipe) fail(phase, int'(got), exp_pipe);
            end
            exp_pipe = dm_xfer(8'hFF);
        end
    endtask

    task automatic card_sel(input bit on);   // OUT (#E7): 0xF6 = выбрана карта 0, 0xFF = ни одной
        begin
            port_out(8'hE7, on ? 8'hF6 : 8'hFF);
            ce_wait(2);
            dm_cs(on ? 1 : 0);
        end
    endtask

    //---- сторона оболочки -------------------------------------------------------------------------
    task automatic arm_ctl(input [31:0] w);
        begin
            @(posedge aclk); #1; dut_ctl = w;
            repeat (3) @(posedge aclk);      // флаг ПОЗЖЕ данных - правило CDC, как в axi_ctl
            #1; dut_ctl_we = ~dut_ctl_we;
            repeat (2) @(posedge aclk);
        end
    endtask

    task automatic arm_bufa(input [10:0] adr);
        begin
            @(posedge aclk); #1; dut_bufa = {21'd0, adr}; dut_bufa_we = 1'b1;
            @(posedge aclk); #1; dut_bufa_we = 1'b0;
            repeat (8) @(posedge aclk);
        end
    endtask

    task automatic arm_bufw(input [31:0] w);
        begin
            @(posedge aclk); #1; dut_bufw = w; dut_bufw_we = 1'b1;
            @(posedge aclk); #1; dut_bufw_we = 1'b0;
            repeat (8) @(posedge aclk);      // пачка из четырёх байт в 9-битный порт
        end
    endtask

    task automatic arm_bufr(output [31:0] w);
        begin
            @(posedge aclk); #1; w = dut_bufr_q; dut_bufr_re = 1'b1;
            @(posedge aclk); #1; dut_bufr_re = 1'b0;
            repeat (8) @(posedge aclk);
        end
    endtask

    // Наполнить буфер сектором ЗАРАНЕЕ. Так делает и настоящая прошивка (упреждающее чтение), и
    // только так поток совпадает с эталоном байт-в-байт: у модели носитель мгновенный.
    task automatic arm_fill(input int lba, input [10:0] base, input bit zeros);
        int i; logic [31:0] w; logic [7:0] q0, q1, q2, q3;
        begin
            arm_bufa(base);
            for (i = 0; i < 512; i = i + 4) begin
                if (zeros) w = 32'd0;
                else begin
                    // ⚠ по одному вызову DPI на присваивание - см. пояснение у объявления sb()
                    q0 = sb(lba, i+0); q1 = sb(lba, i+1);
                    q2 = sb(lba, i+2); q3 = sb(lba, i+3);
                    w  = {q3, q2, q1, q0};
                end
                arm_bufw(w);
            end
        end
    endtask

    reg [31:0] CTL_BASE = 32'h00000005;           // EN | CCS; B0150: | (1<<15) в режиме FAST

    // Автоответчик оболочки: подтверждает запрос, эхом возвращая его номер. Буфер к этому моменту
    // уже наполнен - см. arm_fill выше.
    integer acks_rd = 0, acks_wr = 0;
    bit     mb_mode = 1'b0;      // мультиблок: второй блок лежит в буфере B
    bit     mb_buf  = 1'b0;
    initial forever begin
        @(posedge aclk);
        if (dut_stat[0]) begin
            arm_ctl(CTL_BASE | (32'(dut_stat[3:2]) << 6) | (32'd1 << 8) |
                    ((mb_mode & mb_buf) ? (32'd1 << 14) : 32'd0));
            if (mb_mode) mb_buf = ~mb_buf;
            acks_rd = acks_rd + 1;
            wait (!dut_stat[0]);
        end else if (dut_stat[1]) begin
            arm_ctl(CTL_BASE | (32'(dut_stat[3:2]) << 10) | (32'd1 << 12));
            acks_wr = acks_wr + 1;
            wait (!dut_stat[1]);
        end
    end

    //---- команды SD -------------------------------------------------------------------------------
    task automatic sd_cmd(input [7:0] cmd, input [31:0] arg, input [7:0] crc);
        logic [7:0] dummy;
        begin
            xfer_rd(dummy);                       // холостое чтение перед командой - L1DE0
            port_out(8'hE7, 8'hF6); ce_wait(2);   // esxDOS ПЕРЕЗАПИСЫВАЕТ выбор, а не снимает его
            xfer_wr(cmd);
            xfer_wr(arg[31:24]); xfer_wr(arg[23:16]); xfer_wr(arg[15:8]); xfer_wr(arg[7:0]);
            xfer_wr(crc);
        end
    endtask

    // Опрос «читать, пока 0xFF» - подпрограмма L1DD2 esxDOS.
    task automatic poll_nonff(output [7:0] v, input int limit);
        int k;
        begin
            v = 8'hFF;
            for (k = 0; (k < limit) && (v === 8'hFF); k = k + 1) xfer_rd(v);
        end
    endtask

    //=============================================================================================
    integer NSEC = 64;
    integer i, k, lba, vol, cap;
    logic [7:0] b, r1, tail0, tail1, tail2, tail3, p0, p1, p2, p3;
    logic [31:0] w;
    integer rate_on, rate_off, t0;

    initial begin
        if (!$value$plusargs("NSEC=%d", NSEC)) NSEC = 64;

        vol = 32'h0003F000;                 // ~127 МБ - порядок настоящего синтезированного тома
        dm_attach(vol);
        cap = dm_sectors();

        repeat (20) @(posedge aclk); arst_n = 1'b1;
        repeat (20) @(posedge clk);  rst_n  = 1'b1;

        //---- оболочка подкладывает CSD/CID и ёмкость --------------------------------------------
        @(posedge aclk); #1; dut_cap = cap;
        arm_bufa(11'h600);
        for (i = 0; i < 16; i = i + 4) begin
            p0 = scsd(i+0); p1 = scsd(i+1); p2 = scsd(i+2); p3 = scsd(i+3);
            arm_bufw({p3, p2, p1, p0});
        end
        arm_bufa(11'h610);
        for (i = 0; i < 16; i = i + 4) begin
            p0 = scid(i+0); p1 = scid(i+1); p2 = scid(i+2); p3 = scid(i+3);
            arm_bufw({p3, p2, p1, p0});
        end
        arm_ctl(CTL_BASE);
        $display("=== том %0d секторов, карта объявляет %0d (кратно 1024) ===", vol, cap);

        //=========================================================================================
        $display("=== 1. Включение по esxDOS: L1D40 - десять холостых байт при снятом выборе ===");
        phase = "power-up";
        card_sel(0);
        for (i = 0; i < 10; i = i + 1) xfer_wr(8'hFF);
        card_sel(1);

        phase = "CMD0";
        sd_cmd(8'h40, 32'h00000000, 8'h95);
        poll_nonff(r1, 12);
        if (r1 !== 8'h01) begin errors=errors+1; $display("ОТКАЗ CMD0: R1=%02h, ждали 01", r1); end

        phase = "CMD8";
        sd_cmd(8'h48, 32'h000001AA, 8'h87);
        poll_nonff(r1, 12);
        poll_nonff(tail0, 12); poll_nonff(tail1, 12); poll_nonff(tail2, 12); poll_nonff(tail3, 12);
        if ({tail2, tail3} !== 16'h01AA) begin
            errors = errors + 1; $display("ОТКАЗ CMD8: эхо %02h%02h, ждали 01AA", tail2, tail3);
        end

        phase = "ACMD41";
        for (k = 0; k < 4; k = k + 1) begin
            sd_cmd(8'h77, 32'h00000000, 8'hFF);        // CMD55, ответ esxDOS не проверяет
            poll_nonff(r1, 12);
            // 🥇 И СНИМАЕТ ВЫБОР КАРТЫ: L1D67 -> L1D71 -> L1D5E. Защёлка APP_CMD обязана это
            // пережить, иначе ACMD41 разберётся как обычная CMD41 и объём поедет по другой ветке.
            card_sel(0); card_sel(1);
            sd_cmd(8'h69, 32'h40000000, 8'hFF);
            poll_nonff(r1, 12);
            if (r1 === 8'h00) k = 99;
        end
        if (r1 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ ACMD41: карта не вышла из idle"); end

        phase = "CMD58";
        sd_cmd(8'h7A, 32'h00000000, 8'hFF);
        poll_nonff(r1, 12); poll_nonff(tail0, 12);
        if (tail0[6] !== 1'b1) begin
            errors = errors + 1; $display("ОТКАЗ CMD58: бит CCS снят, esxDOS сочтёт карту мелкой");
        end
        // Хвост OCR дочитываем БЕЗ пропуска 0xFF - иначе поедет сверка потока (esxDOS его как раз
        // пропускает, и это стоит ей одного полного выхода опроса; см. отчёт).
        xfer_rd(tail1); xfer_rd(tail2); xfer_rd(tail3);

        phase = "CMD9";
        sd_cmd(8'h49, 32'h00000000, 8'hFF);
        poll_nonff(r1, 12);
        poll_nonff(b, 12);
        if (b !== 8'hFE) begin
            errors = errors + 1;
            $display("ОТКАЗ CMD9: пришло %02h вместо токена FE - это и есть «Disk error» на 1.3 с", b);
        end
        for (i = 0; i < 18; i = i + 1) xfer_rd(b);      // 16 байт CSD + 2 CRC

        phase = "CMD10";
        sd_cmd(8'h4A, 32'h00000000, 8'hFF);
        poll_nonff(r1, 12);
        poll_nonff(b, 12);
        if (b !== 8'hFE) begin errors=errors+1; $display("ОТКАЗ CMD10: нет токена блока"); end
        for (i = 0; i < 18; i = i + 1) xfer_rd(b);

        $display("    инициализация пройдена, обменов %0d, расхождений %0d", xfers, errors);

        //=========================================================================================
        $display("=== 2. %0d случайных секторов: CMD17, 512 байт и два байта CRC ===", NSEC);
        phase = "CMD17";
        for (k = 0; k < NSEC; k = k + 1) begin
            lba = $urandom_range(vol - 1, 0);
            arm_fill(lba, 11'h000, 1'b0);              // упреждающее чтение оболочки
            sd_cmd(8'h51, lba, 8'hFF);
            poll_nonff(r1, 12);
            if (r1 !== 8'h00) begin
                errors = errors + 1;
                $display("ОТКАЗ CMD17 сектор %0d: R1=%02h", lba, r1);
            end
            poll_nonff(b, 12);
            if (b !== 8'hFE) begin
                errors = errors + 1;
                $display("ОТКАЗ CMD17 сектор %0d: нет токена (%02h)", lba, b);
            end
            for (i = 0; i < 514; i = i + 1) xfer_rd(b);
            if ((k % 500) == 499)
                $display("    ... %0d секторов, обменов %0d, расхождений %0d", k+1, xfers, errors);
        end

        //=========================================================================================
        $display("=== 3. CMD24: нагрузка 0x40..0x7F - каждый её байт выглядит как начало команды ===");
        phase = "CMD24";
        lba = 32'h00001234;
        sd_cmd(8'h58, lba, 8'hFF);
        poll_nonff(r1, 12);
        if (r1 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD24: R1=%02h", r1); end
        xfer_wr(8'hFE);
        for (i = 0; i < 512; i = i + 1) xfer_wr(8'h40 | 8'(i & 63));
        xfer_wr(8'hFF); xfer_wr(8'hFF);                 // CRC, который никто не считает
        poll_nonff(b, 24);
        if ((b & 8'h1F) !== 8'h05) begin
            errors = errors + 1;
            $display("ОТКАЗ CMD24: data-response %02h, ждали xxx00101", b);
        end
        // B0150: хвост занятости ПОБАЙТНО. SPEC: 00 00 00 00 FF. FAST: 00 00 00 01 FF (байт 0x01 -
        // тот, на котором esxDOS выходит из цикла ожидания вместо таймаута в 12 800 чтений).
        begin : busy_tail
            reg [7:0] t0, t1, t2, t3, t4;
            xfer_rd(t0); xfer_rd(t1); xfer_rd(t2); xfer_rd(t3); xfer_rd(t4);
            if (t0 !== 8'h00 || t1 !== 8'h00 || t2 !== 8'h00) begin
                errors = errors + 1; $display("ОТКАЗ занятости: первые байты %02h %02h %02h, ждали 00 00 00", t0, t1, t2);
            end
            if (CTL_BASE[15]) begin
                if (t3 !== 8'h01) begin errors=errors+1; $display("ОТКАЗ FAST: 4-й байт занятости %02h, ждали 01", t3); end
            end else begin
                if (t3 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ SPEC: 4-й байт занятости %02h, ждали 00", t3); end
            end
            if (t4 !== 8'hFF) begin errors=errors+1; $display("ОТКАЗ: после занятости %02h, ждали FF", t4); end
            $display("   занятость: %02h %02h %02h %02h %02h  (режим %s)", t0, t1, t2, t3, t4, CTL_BASE[15] ? "FAST" : "SPEC");
        end
        b = 8'hFF;

        // Сверяем то, что легло в буфер записи, с тем, что записала модель.
        arm_bufa(11'h400);   // установка указателя сама подкачивает первое слово
        for (i = 0; i < 512; i = i + 4) begin
            arm_bufr(w);
            p0 = swb(i+0); p1 = swb(i+1); p2 = swb(i+2); p3 = swb(i+3);
            if (w[7:0] !== p0 || w[15:8] !== p1 || w[23:16] !== p2 || w[31:24] !== p3) begin
                errors = errors + 1;
                if (errors < 20) $display("ОТКАЗ буфера записи по смещению %0d: %08h", i, w);
            end
        end
        if (dm_wr_lba() !== lba) begin
            errors = errors + 1; $display("ОТКАЗ: модель записала сектор %0d вместо %0d", dm_wr_lba(), lba);
        end
        if (acks_wr == 0) begin errors=errors+1; $display("ОТКАЗ: оболочку о записи не спросили"); end

        // B0150: тот же сектор в режиме FAST - RTL и эталон переключаются одним битом/вызовом,
        // стенд ловит расхождение между ними, а не только «есть ли байт».
        $display("=== 3b. CMD24 в режиме FAST: последний байт занятости 0x01 ===");
        phase = "CMD24-fast";
        CTL_BASE = CTL_BASE | (32'd1 << 15);
        dm_fast_ack(1);
        arm_ctl(CTL_BASE);
        lba = 32'h00001235;
        sd_cmd(8'h58, lba, 8'hFF);
        poll_nonff(r1, 12);
        if (r1 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD24/FAST: R1=%02h", r1); end
        xfer_wr(8'hFE);
        for (i = 0; i < 512; i = i + 1) xfer_wr(8'(i & 255));
        xfer_wr(8'hFF); xfer_wr(8'hFF);
        poll_nonff(b, 24);
        if ((b & 8'h1F) !== 8'h05) begin errors=errors+1; $display("ОТКАЗ CMD24/FAST: data-response %02h", b); end
        begin : busy_tail_fast
            reg [7:0] t0, t1, t2, t3, t4;
            xfer_rd(t0); xfer_rd(t1); xfer_rd(t2); xfer_rd(t3); xfer_rd(t4);
            if (t0 !== 8'h00 || t1 !== 8'h00 || t2 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ FAST занятость: %02h %02h %02h", t0, t1, t2); end
            if (t3 !== 8'h01) begin errors=errors+1; $display("ОТКАЗ FAST: 4-й байт %02h, ждали 01", t3); end
            if (t4 !== 8'hFF) begin errors=errors+1; $display("ОТКАЗ FAST: после занятости %02h, ждали FF", t4); end
            $display("   занятость FAST: %02h %02h %02h %02h %02h", t0, t1, t2, t3, t4);
        end
        if (dm_wr_lba() !== lba) begin errors=errors+1; $display("ОТКАЗ FAST: модель записала %0d вместо %0d", dm_wr_lba(), lba); end
        CTL_BASE = CTL_BASE & ~(32'd1 << 15);           // дальше стенд идёт в SPEC, как раньше
        dm_fast_ack(0);
        arm_ctl(CTL_BASE);
        // B0150: CMD25 - два сектора и стоп-токен, в SPEC и FAST. Покрывает путь S_BUSY -> S_RXWAIT.
        for (int md = 0; md < 2; md = md + 1) begin : cmd25_modes
            reg [7:0] u0, u1, u2, u3, u4;
            if (md) begin CTL_BASE = CTL_BASE | (32'd1 << 15); dm_fast_ack(1); end
            else    begin CTL_BASE = CTL_BASE & ~(32'd1 << 15); dm_fast_ack(0); end
            arm_ctl(CTL_BASE);
            $display("=== 3c. CMD25: два сектора + стоп-токен, режим %s ===", md ? "FAST" : "SPEC");
            phase = md ? "CMD25-fast" : "CMD25-spec";
            lba = 32'h00002000 + md * 4;
            sd_cmd(8'h59, lba, 8'hFF);
            poll_nonff(r1, 12);
            if (r1 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD25: R1=%02h", r1); end
            for (int blk = 0; blk < 2; blk = blk + 1) begin
                xfer_wr(8'hFC);
                for (i = 0; i < 512; i = i + 1) xfer_wr(8'(i ^ blk));
                xfer_wr(8'hFF); xfer_wr(8'hFF);
                poll_nonff(b, 24);
                if ((b & 8'h1F) !== 8'h05) begin errors=errors+1; $display("ОТКАЗ CMD25 блок %0d: data-response %02h", blk, b); end
                xfer_rd(u0); xfer_rd(u1); xfer_rd(u2); xfer_rd(u3); xfer_rd(u4);
                if (u0 !== 8'h00 || u1 !== 8'h00 || u2 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD25 блок %0d занятость: %02h %02h %02h", blk, u0, u1, u2); end
                if (u3 !== (md ? 8'h01 : 8'h00)) begin errors=errors+1; $display("ОТКАЗ CMD25 блок %0d: 4-й байт %02h", blk, u3); end
                if (u4 !== 8'hFF) begin errors=errors+1; $display("ОТКАЗ CMD25 блок %0d: после занятости %02h", blk, u4); end
                $display("   блок %0d занятость: %02h %02h %02h %02h %02h", blk, u0, u1, u2, u3, u4);
                if (dm_wr_lba() !== lba + blk) begin errors=errors+1; $display("ОТКАЗ CMD25: модель записала %0d вместо %0d", dm_wr_lba(), lba + blk); end
            end
            xfer_wr(8'hFD);                                   // стоп-токен
            // После стоп-токена первым приходит ещё один 0xFF из конвейера (карта решает по байту,
            // а `nxt_byte` уже был выдан), и только потом занятость. NedoOS ждёт «не-FF» до busy -
            // для него этот байт штатен. Так вели себя и RTL, и эталон ДО B0150; стенд прежде этот
            // путь не проверял вовсе, поэтому фиксируем поведение явно.
            xfer_rd(u0);
            if (u0 !== 8'hFF) begin errors=errors+1; $display("ОТКАЗ CMD25 стоп: первый байт %02h, ждали FF (конвейер)", u0); end
            xfer_rd(u0); xfer_rd(u1); xfer_rd(u2); xfer_rd(u3); xfer_rd(u4);
            if (u0 !== 8'h00 || u1 !== 8'h00 || u2 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD25 стоп занятость: %02h %02h %02h", u0, u1, u2); end
            if (u3 !== (md ? 8'h01 : 8'h00)) begin errors=errors+1; $display("ОТКАЗ CMD25 стоп: 4-й байт %02h", u3); end
            if (u4 !== 8'hFF) begin errors=errors+1; $display("ОТКАЗ CMD25 стоп: после занятости %02h", u4); end
            $display("   стоп занятость: %02h %02h %02h %02h %02h", u0, u1, u2, u3, u4);
        end
        CTL_BASE = CTL_BASE & ~(32'd1 << 15); dm_fast_ack(0); arm_ctl(CTL_BASE);
        $display("=== 4. Кадрирование не сорвано: следующая команда разбирается штатно ===");
        phase = "after-CMD24";
        arm_fill(32'h00000000, 11'h000, 1'b0);
        sd_cmd(8'h51, 32'h00000000, 8'hFF);
        poll_nonff(r1, 12);
        if (r1 !== 8'h00) begin
            errors = errors + 1;
            $display("ОТКАЗ: после записи команда не разобрана (R1=%02h) - кадр уехал", r1);
        end
        poll_nonff(b, 12);
        if (b !== 8'hFE) begin errors=errors+1; $display("ОТКАЗ: после записи нет токена блока"); end
        for (i = 0; i < 514; i = i + 1) xfer_rd(b);

        $display("=== 5. Снятие CS посреди кадра команды ===");
        phase = "cs-drop";
        xfer_rd(b);
        port_out(8'hE7, 8'hF6); ce_wait(2);
        xfer_wr(8'h51); xfer_wr(8'h00); xfer_wr(8'h00);   // недобранный кадр
        card_sel(0);                                       // ... и выбор снят
        card_sel(1);
        arm_fill(32'h00000010, 11'h000, 1'b0);
        sd_cmd(8'h51, 32'h00000010, 8'hFF);                // целая команда сразу после
        poll_nonff(r1, 12);
        if (r1 !== 8'h00) begin
            errors = errors + 1;
            $display("ОТКАЗ: после снятия CS кадр не восстановился (R1=%02h)", r1);
        end
        poll_nonff(b, 12);
        if (b !== 8'hFE) begin errors=errors+1; $display("ОТКАЗ: после снятия CS нет токена"); end
        for (i = 0; i < 514; i = i + 1) xfer_rd(b);

        $display("=== 7. Мультиблок CMD18 и остановка CMD12 посреди потока ===");
        // esxDOS их не шлёт вовсе (в её коде нет ни CMD12, ни CMD18, ни CMD25), но UnoDOS и
        // самописные драйверы шлют, а непроверенный код - это обещание, а не свойство.
        phase = "CMD18";
        lba = 32'h00000100;
        arm_fill(lba,        11'h000, 1'b0);      // блок 1 - в буфер A
        arm_fill(lba + 1,    11'h200, 1'b0);      // блок 2 - в буфер B, упреждающе
        mb_mode = 1'b1; mb_buf = 1'b0;
        sd_cmd(8'h52, lba, 8'hFF);
        poll_nonff(r1, 12);
        if (r1 !== 8'h00) begin errors=errors+1; $display("ОТКАЗ CMD18: R1=%02h", r1); end
        poll_nonff(b, 12);
        if (b !== 8'hFE) begin errors=errors+1; $display("ОТКАЗ CMD18: нет токена первого блока"); end
        for (i = 0; i < 514; i = i + 1) xfer_rd(b);
        poll_nonff(b, 12);                         // промежуток и токен ВТОРОГО блока
        if (b !== 8'hFE) begin
            errors = errors + 1; $display("ОТКАЗ CMD18: поток оборвался на втором блоке (%02h)", b);
        end
        for (i = 0; i < 100; i = i + 1) xfer_rd(b);
        // 🥇 CMD12 идёт ПОСРЕДИ данных - паузы у карты нет. Приёмник команд обязан её увидеть, не
        // сбив передачу: сверка байт продолжается ровно с того места.
        xfer_wr(8'h4C); xfer_wr(8'h00); xfer_wr(8'h00); xfer_wr(8'h00); xfer_wr(8'h00); xfer_wr(8'hFF);
        /* 🥇 B0145: ПОТОК ВСТАЁТ СРАЗУ, А НЕ В КОНЦЕ БЛОКА. Здесь стояло «дотактовать 408 байт»
           (100 + 6 + 408 = 514, то есть остаток блока и оба байта CRC) и лишь потом ждать R1 -
           стенд ЗАКРЕПЛЯЛ дефект как требование, ровно как когда-то проверка «запись обязана
           отвергаться» в хостовом стенде. Настоящая карта отвечает на стоп-команду там, где её
           поймали (Spec 6.00, Figure 7-5 и §7.2.8), а драйверу длину остатка знать неоткуда: он
           ищет первый байт ответа и на нашем «остатке» законно принимал за R1 байт ДАННЫХ.
           Один байт потока после кадра остаётся законно: в ПЛИС он уже лежал в конвейере
           `nxt_byte`, когда кадр закончился. */
        got_r1 = 0;
        for (i = 0; i < 8; i = i + 1) begin
            xfer_rd(b);
            if (!got_r1 && (b === 8'h00)) got_r1 = 1;
        end
        if (!got_r1) begin
            errors = errors + 1;
            $display("ОТКАЗ CMD12: R1b не пришёл за 8 байт после кадра стоп-команды");
        end
        b = 8'h00;
        for (i = 0; (i < 24) && (b === 8'h00); i = i + 1) xfer_rd(b);
        mb_mode = 1'b0;
        if (dut_dbg[3:0] != 4'd0) begin
            errors = errors + 1;
            $display("ОТКАЗ: мультиблок насчитал %0d рассинхронов кадра", dut_dbg[3:0]);
        end

        $display("=== 6. Темп обменов: карта не имеет права стоить машине ни такта ===");
        t0 = ce_ticks; for (i = 0; i < 32; i = i + 1) xfer_wr(8'hFF); rate_on = ce_ticks - t0;
        card_en = 1'b0; repeat (40) @(posedge clk);
        t0 = ce_ticks; for (i = 0; i < 32; i = i + 1) xfer_wr(8'hFF); rate_off = ce_ticks - t0;
        card_en = 1'b1;
        if (rate_on !== rate_off) begin
            errors = errors + 1;
            $display("ОТКАЗ: 32 обмена стоят %0d тактов при живой карте и %0d при выключенной",
                     rate_on, rate_off);
        end else
            $display("    32 обмена = %0d тактов разрешения и с картой, и без неё", rate_on);
        if (hold_seen != 0) begin errors=errors+1; $display("ОТКАЗ: cpu_hold поднимался %0d раз", hold_seen); end

        //=========================================================================================
        $display("");
        $display("ИТОГ: обменов %0d, сверено байт %0d, расхождений с эталоном %0d",
                 xfers, checks, errors);
        $display("      подтверждений оболочки: чтений %0d, записей %0d", acks_rd, acks_wr);
        $display("      DMMC_DBG = %08h  (команд %0d, блоков чтения %0d, записи %0d, illegal %0d, рассинхронов %0d)",
                 dut_dbg, dut_dbg[31:24], dut_dbg[23:16], dut_dbg[15:8], dut_dbg[7:4], dut_dbg[3:0]);
        $display("      DMMC_STAT = %08h  (последняя команда %0d, неизвестная %0d, состояние %0d)",
                 dut_stat, dut_stat[19:14], dut_stat[25:20], dut_stat[29:26]);
        if (dut_dbg[3:0] != 4'd0) $display("      ВНИМАНИЕ: счётчик рассинхронов кадра не ноль");
        if (dut_stat[31])         $display("      ВНИМАНИЕ: было несовпадение CRC7 - проверить битность");
        if (errors == 0) $display("СТЕНД ПРОЙДЕН ПОЛНОСТЬЮ");
        else             $display("СТЕНД ОТКАЗАЛ: %0d расхождений", errors);
        $finish;
    end
endmodule
