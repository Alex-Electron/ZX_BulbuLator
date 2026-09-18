`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_gs_wq_fifo.sv - стенд обратного давления на очереди записей #B3 (General Sound).
//
// Что доказываем и почему именно это: дефект Z-Player 4.1 был не в скорости, а в МОЛЧАЛИВОЙ ПОТЕРЕ -
// оболочка отвлекалась дольше, чем держала очередь, и байт исчезал без следа. Значит стенд обязан
// воспроизвести ровно ту повадку гостя, на которой мы погорели:
//   * байт уходит примерно раз в 4.7 мкс (поток OUTI на 3.5 МГц);
//   * флаг гость проверяет ПЕРЕД записью, но на перевороте счётчика делает ДВЕ записи подряд
//     вообще без проверки - слепая зона, ради которой и держится резерв HDR;
//   * оболочка вычерпывает рывками, между рывками паузы 1.25 мс (чтение сектора) и 2 мс.
// Критерий: прочитанный поток БАЙТ-В-БАЙТ равен записанному, настоящая полнота не наступала ни разу,
// «занято» встаёт не позже верхнего порога и снимается не выше нижнего.
//-------------------------------------------------------------------------------------------------
module tb_gs_wq_fifo;
    localparam AW = 7, HDR = 32, LOW = 32;
    localparam integer HI_TH  = (1 << AW) - HDR;   // 224
    localparam integer NBYTES = 1200;

    reg  wclk = 0, rclk = 0, rst_n = 0;
    always #8.824 wclk = ~wclk;                    // 56.667 МГц - домен машины
    always #5.000 rclk = ~rclk;                    // 100 МГц    - домен оболочки

    reg        wr_en = 0;
    reg  [7:0] din = 0;
    wire       full, afull;
    wire [AW:0] wr_count, rd_count;   /* ширина ровно по параметру: узкий выход в широкий провод дал бы z в старшем бите, и любое сравнение с порогом молча стало бы X */
    reg        rd_en = 0;
    wire [7:0] dout;
    wire       empty;

    gs_wq_fifo #(.DW(8), .AW(AW), .HDR(HDR), .LO(LOW)) dut (
        .wr_clk(wclk), .wr_rst_n(rst_n), .wr_en(wr_en), .din(din),
        .full(full), .afull(afull), .wr_count(wr_count),
        .rd_clk(rclk), .rd_rst_n(rst_n), .rd_en(rd_en),
        .dout(dout), .empty(empty), .rd_count(rd_count)
    );

    integer errs = 0, sent = 0, got = 0, drops = 0;
    integer afull_up_max = 0, afull_dn_max = 0, occ_peak = 0;
    reg [7:0] expect_b = 8'h00;
    reg       drain_on = 1'b0;
    reg       done_tx  = 1'b0;

    task guest_write(input [7:0] v);
        begin
            @(negedge wclk); wr_en = 1'b1; din = v;
            @(posedge wclk);                        // на этом фронте байт ложится, если очередь не полна
            if(full) begin drops = drops + 1; $display("DROP: t=%0t байт %0d, занятость %0d, afull=%b", $time, sent, wr_count, afull); end
            @(negedge wclk); wr_en = 1'b0;
            sent = sent + 1;
        end
    endtask

    integer i;
    initial begin
        repeat(20) @(posedge wclk); rst_n = 1;
        repeat(20) @(posedge wclk);
        i = 0;
        while(i < NBYTES) begin
            if((i % 256) == 0 && i != 0) begin      // переворот счётчика: две записи БЕЗ опроса флага
                guest_write(i[7:0]); i = i + 1;
                if(i < NBYTES) begin guest_write(i[7:0]); i = i + 1; end
            end else begin
                while(afull) @(posedge wclk);       // честное ожидание, как перед настоящей картой
                guest_write(i[7:0]); i = i + 1;
            end
            #4700;                                  // темп потока OUTI: байт за ~4.7 мкс
        end
        done_tx = 1'b1;
        wait(got == sent);
        #10000;
        if(drops != 0) begin $display("FAIL: %0d записей в ПОЛНУЮ очередь - байт потерян", drops); errs = errs + 1; end
        if(got != sent) begin $display("FAIL: записано %0d, прочитано %0d", sent, got); errs = errs + 1; end
        if(afull_up_max > HI_TH) begin $display("FAIL: 'занято' встало на %0d, порог %0d", afull_up_max, HI_TH); errs = errs + 1; end
        if(afull_dn_max > LOW)   begin $display("FAIL: 'занято' снялось на %0d, порог %0d", afull_dn_max, LOW); errs = errs + 1; end
        if(errs == 0)
            $display("PASS: sent=%0d got=%0d drops=%0d  пик занятости=%0d  'занято' с %0d, снято с %0d",
                     sent, got, drops, occ_peak, afull_up_max, afull_dn_max);
        else
            $display("FAILED: errs=%0d", errs);
        $finish;
    end

    // ---- оболочка: рывками, между рывками длинные паузы ----
    initial begin
        wait(rst_n);
        forever begin
            drain_on = 1'b0; #1250000;              // 1.25 мс - чтение сектора образа
            drain_on = 1'b1; #300000;               // рывок вычерпывания
            drain_on = 1'b0; #2000000;              // 2 мс - длинная фаза оболочки
        end
    end
    always @(posedge rclk) begin
        rd_en <= 1'b0;
        if(drain_on && !empty && !rd_en) begin      // FWFT: голова видна, пока не пусто
            if(dout !== expect_b) begin
                if(errs < 3) $display("FAIL: t=%0t байт %0d: получено %02h, ждали %02h", $time, got, dout, expect_b);
                errs = errs + 1;
            end
            expect_b <= expect_b + 8'd1;
            got = got + 1;
            rd_en <= 1'b1;
        end
    end

    // ---- наблюдатель порогов (в домене записи) ----
    reg afull_d = 1'b0;
    always @(posedge wclk) if(rst_n) begin
        afull_d <= afull;
        if(wr_count > occ_peak) occ_peak = wr_count;
        if(afull && !afull_d && wr_count > afull_up_max) afull_up_max = wr_count;
        if(!afull && afull_d && wr_count > afull_dn_max) afull_dn_max = wr_count;
    end

    initial begin #60000000; $display("FAILED: стенд не завершился - вероятно вечное ожидание флага"); $finish; end
endmodule
