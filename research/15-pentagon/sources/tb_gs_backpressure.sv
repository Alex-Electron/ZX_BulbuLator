`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_gs_backpressure.sv - стенд ТАКТОВ ОЖИДАНИЯ на порте данных #B3 (General Sound), ядро B0119.
//
// Чем отличается от tb_gs_wq_fifo.sv: там гость ЧЕСТНО ждал снятия «занято» (`while(afull)`), то
// есть стенд проверял очередь при заведомо вежливом госте. А настоящий гость флаг записи не
// опрашивает вовсе - у настоящей карты такого флага нет: бит7 порта #BB значит только «у карты есть
// байт для тебя». Поэтому здесь гость ЛЬЁТ БЕЗ ОГЛЯДКИ, а тормозит его шина - цикл записи
// растягивается, пока фабрика держит `hold`. Это ровно то, что делает на плате main.v, гася
// разрешения такта pc3M5/nc3M5.
//
// Что доказываем:
//   1) при МЕДЛЕННОМ вычерпывании (паузы оболочки 1.25 и 2 мс, как замерено на плате) поток
//      проходит БАЙТ-В-БАЙТ и не теряется ни одного байта;
//   2) ожидание действительно появляется - удержания посчитаны и их цена в тактах процессора видна;
//   3) сторож: мёртвая оболочка НЕ морозит машину навсегда - давление снимается, машина едет
//      дальше (с потерей, и потеря считается ПОШТУЧНО);
//   4) ожившая оболочка возвращает давление сама, без всякого вмешательства.
// Сторож взят разрядностью 15 (32768 тактов процессора ≈ 9.4 мс) вместо боевых 19 (≈150 мс) -
// иначе стенд считал бы полмиллиона тактов ради одной проверки. Логика от разрядности не зависит,
// но порог обязан быть ЗАМЕТНО БОЛЬШЕ самой длинной паузы оболочки, иначе сторож срабатывает
// посреди штатной работы. Разрядность 13 (145 мкс) стенд отверг сразу: при паузе оболочки 1.25 мс
// давление снималось на каждом такте ожидания, и очередь переполнялась ровно как без него - с
// 128-го байта. На плате соотношение то же: 150 мс сторожа против 134 мс самой длинной
// измеренной паузы оболочки.
//-------------------------------------------------------------------------------------------------
module tb_gs_backpressure;
    localparam AW = 6, HDR = 8, LOW = 16, WDB = 15;
    localparam integer HI_TH  = (1 << AW) - HDR;      // 56
    localparam integer NBYTES = 1500;

    reg  wclk = 0, rclk = 0, rst_n = 0;
    always #8.824 wclk = ~wclk;                       // 56.667 МГц - домен машины
    always #5.000 rclk = ~rclk;                       // 100 МГц    - домен оболочки

    // ---- разрешение такта процессора: 3.5 МГц = импульс раз в 16 тактов машины ----
    reg [3:0] tdiv = 0; wire ten = (tdiv == 4'd0);
    always @(posedge wclk) tdiv <= tdiv + 4'd1;

    // ---- очередь ----
    reg        wr_en = 0;  reg [7:0] din = 0;
    wire       full, afull, drain_w;
    wire [AW:0] wr_count, rd_count;   /* ширина ровно по параметру - иначе старший бит z и сравнение X */
    reg        rd_en = 0;  wire [7:0] dout; wire empty;

    gs_wq_fifo #(.DW(8), .AW(AW), .HDR(HDR), .LO(LOW)) fifo (
        .wr_clk(wclk), .wr_rst_n(rst_n), .wr_en(wr_en), .din(din),
        .full(full), .afull(afull), .wr_count(wr_count), .drain_w(drain_w),
        .rd_clk(rclk), .rd_rst_n(rst_n), .rd_en(rd_en),
        .dout(dout), .empty(empty), .rd_count(rd_count)
    );

    // ---- ловушка потока (то же, что стоит в машине) ----
    reg  acc = 0, evt = 0;
    wire hold;  wire [31:0] stat2, stat3;
    gs_flow #(.WDB(WDB)) flow (
        .clock(wclk), .reset_n(rst_n), .ten(ten),
        .wr_acc_b3(acc), .wr_evt_b3(evt),
        .wq_afull(afull), .wq_full(full), .drain(drain_w),
        .hold(hold), .stat2(stat2), .stat3(stat3)
    );
    wire [11:0] lost7   = stat2[27:16];
    wire [11:0] stall_n = stat2[11:0];
    wire [19:0] hold_ts = stat3[19:0];
    wire [1:0]  wd_hits = stat3[31:30];

    integer errs = 0, sent = 0, got = 0, dropped = 0;
    integer max_wait = 0, occ_peak = 0;
    reg        check_seq = 1'b1;
    reg [7:0]  expect_b  = 8'h00;
    reg        shell_alive = 1'b1;

    // ---- ГОСТЬ: OUTI без единой проверки флага; тормозит его только шина ----
    integer tw;
    task guest_out(input [7:0] v);
        begin
            @(negedge wclk); acc = 1'b1; evt = 1'b1; wr_en = 1'b1; din = v;
            @(posedge wclk);                          // на этом фронте байт ложится в очередь
            if(full) begin dropped = dropped + 1; if(check_seq) begin
                $display("FAIL: байт %0d предъявлен в ПОЛНУЮ очередь при живой оболочке", sent); errs = errs + 1; end end
            @(negedge wclk); evt = 1'b0; wr_en = 1'b0;
            sent = sent + 1;
            repeat(2) @(posedge wclk);                // требование удержания регистрируется
            tw = 0;
            while(hold) begin @(posedge wclk); tw = tw + 1; end   // ТАКТЫ ОЖИДАНИЯ: цикл растянут
            if(tw > max_wait) max_wait = tw;
            repeat(4) @(posedge wclk);                // остаток цикла записи
            @(negedge wclk); acc = 1'b0;
        end
    endtask

    // ---- ОБОЛОЧКА: вычерпывает рывками, между рывками паузы, как замерено на плате ----
    integer k;
    initial begin
        rd_en = 0;
        @(posedge rst_n);
        forever begin
            if(!shell_alive) begin #1000; end
            else begin
                k = 0;
                while(k < 64 && !empty) begin
                    @(negedge rclk); rd_en = 1'b1; @(posedge rclk);
                    if(check_seq && dout !== expect_b) begin
                        $display("FAIL: на месте %0d ждали %02h, пришло %02h", got, expect_b, dout);
                        errs = errs + 1;
                    end
                    expect_b = dout + 8'd1; got = got + 1; k = k + 1;
                    @(negedge rclk); rd_en = 1'b0;
                end
                #1250000;                              // 1.25 мс - чтение сектора образа
                if((got % 512) < 64) #2000000;         // и изредка 2 мс
            end
        end
    end

    always @(posedge wclk) if(wr_count > occ_peak) occ_peak = wr_count;

    /* Страховка стенда: если давление не работает, поток встаёт навсегда (ждём числа байт), и
       стенд молча крутился бы вечно вместо того, чтобы сказать «не сошлось». */
    initial begin
        #400000000;
        $display("FAIL: стенд не сошёлся за 400 мс модельного времени (отдано %0d, принято %0d)", sent, got);
        $finish;
    end

    integer i, lost_base, stall_base;
    initial begin
        repeat(20) @(posedge wclk); rst_n = 1;
        repeat(20) @(posedge wclk);

        // ---- ФАЗА 1: оболочка жива. Ни одного потерянного байта, но ожидание обязано появиться ----
        for(i = 0; i < NBYTES; i = i + 1) begin
            guest_out(i[7:0]);
            #4700;                                     // темп потока OUTI: байт за ~4.7 мкс
        end
        wait(got == sent);
        #20000;
        if(dropped != 0) begin $display("FAIL: потеряно %0d байт при живой оболочке", dropped); errs = errs + 1; end
        if(lost7 != 0)   begin $display("FAIL: прибор насчитал %0d потерянных байт", lost7); errs = errs + 1; end
        if(stall_n == 0) begin $display("FAIL: ожидания не было вовсе - обратное давление не работает"); errs = errs + 1; end
        if(hold_ts == 0) begin $display("FAIL: цена ожидания не посчитана"); errs = errs + 1; end
        if(wd_hits != 0) begin $display("FAIL: сторож сработал при живой оболочке"); errs = errs + 1; end
        $display("ФАЗА 1: отдано %0d, принято %0d, потеряно %0d; удержаний %0d, тактов ожидания %0d, самое долгое %0d тактов, пик очереди %0d",
                 sent, got, lost7, stall_n, hold_ts, max_wait, occ_peak);

        // ---- ФАЗА 2: оболочка умерла. Сторож обязан отпустить машину ----
        check_seq   = 1'b0;
        shell_alive = 1'b0;
        lost_base   = lost7; stall_base = stall_n;
        for(i = 0; i < 400; i = i + 1) begin
            guest_out(8'hA5);
            #4700;
        end
        if(wd_hits == 0) begin $display("FAIL: сторож не сработал - мёртвая оболочка заморозила бы Z80"); errs = errs + 1; end
        if(lost7 == lost_base) begin $display("FAIL: байты при мёртвой оболочке не теряются? прибор молчит"); errs = errs + 1; end
        $display("ФАЗА 2: сторож сработал %0d раз, потеряно байт %0d (было %0d) - машина ЖИВА",
                 wd_hits, lost7, lost_base);

        // ---- ФАЗА 3: оболочка ожила - давление обязано вернуться само ----
        shell_alive = 1'b1;
        stall_base  = stall_n;
        #3000000;
        for(i = 0; i < 400; i = i + 1) begin
            guest_out(8'h5A);
            #4700;
        end
        if(stall_n == stall_base) begin $display("FAIL: давление не вернулось после оживления оболочки"); errs = errs + 1; end
        $display("ФАЗА 3: удержаний стало %0d (было %0d) - давление вернулось само", stall_n, stall_base);

        if(errs == 0) $display("PASS: поток без опроса флага не теряет байт, ожидание есть, сторож держит машину живой");
        else          $display("ОШИБОК: %0d", errs);
        $finish;
    end
endmodule
//-------------------------------------------------------------------------------------------------
