`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_divmmc_stop.sv - РЕГРЕССИЯ НА ОСТАНОВКУ МУЛЬТИБЛОЧНОГО ЧТЕНИЯ (B0145).
//
// Проверяет ОДНО утверждение, зато во всех четырёх местах, где стоп-команду может застать карта:
//     на CMD12 карта ОБЯЗАНА ответить R1b - где бы кадр её ни поймал - и после этого снова слушать
//     команды.
// Родился из виса Z-Player 4.1 (19.08): «диск увидел, прочитать не смог, подвис, и определил не
// сразу, со второго раза». Приборы с живого виса: DMMC_STAT = 0x00049808 (state IDLE, last_cmd 18,
// card_busy 0), DMMC_LBA = 2049, DMMC_DBG = 0x50480004 (команд 80, чтений 72, desync 4), дельта
// счётчиков за 4 с НУЛЕВАЯ. Сценарий B воспроизводит этот снимок: до правки «за 64 байта ни одного
// байта с нулевым старшим битом», после - R1 на второй позиции.
//
// Запуск (ThinkPad, Vivado 2023.1):
//   export PATH=/tools/Xilinx/Vivado/2023.1/bin:$PATH
//   xvlog -sv divmmc_card.v tb_divmmc_stop.sv && xelab -debug off tb_stop -s tbs && xsim tbs -runall
//
// Стенд самопроверяющийся: печатает ОК/ОТКАЗ и итог. Сообщения проверок - латиницей НАМЕРЕННО:
// xsim портит кириллицу, переданную через параметр типа string (проверено).
//
// Данные блоков оболочка кладёт так, что у КАЖДОГО байта старший бит = 1: тогда байт данных
// невозможно спутать с R1, и «первый байт с битом7=0» - это заведомо ответ карты.
//-------------------------------------------------------------------------------------------------
module tb_stop;

    reg clk = 1'b0, aclk = 1'b0;
    always #8.824 clk  = ~clk;      // 56.667 МГц
    always #5.0   aclk = ~aclk;     // 100 МГц

    integer fails = 0;
    task chk(input bit cond, input string what);
        begin
            if (cond) $display("   ОК     : %s", what);
            else      begin $display("   ОТКАЗ  : %s", what); fails = fails + 1; end
        end
    endtask

    reg        cs_n = 1'b1, sck = 1'b0, mosi = 1'b1;
    wire       miso;
    reg [31:0] ctl = 32'd0;  reg ctl_we = 1'b0;
    reg [31:0] cap = 32'h0001_0000;
    reg [31:0] bufa = 32'd0; reg bufa_we = 1'b0;
    reg [31:0] bufw = 32'd0; reg bufw_we = 1'b0;
    reg        arst_n = 1'b0;
    wire [31:0] stat, lba_q, dbg, bufa_q, bufr_q;

    divmmc_card dut (
        .clk(clk), .ce(1'b1), .rst_n(1'b1), .en(1'b1),
        .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso), .map_dbg(9'd0),
        .aclk(aclk), .arst_n(arst_n),
        .ctl(ctl), .ctl_we(ctl_we), .cap_in(cap),
        .bufa_in(bufa), .bufa_we(bufa_we),
        .bufw_in(bufw), .bufw_we(bufw_we), .bufr_re(1'b0),
        .bufa_q(bufa_q), .bufr_q(bufr_q),
        .stat(stat), .lba_q(lba_q), .dbg(dbg)
    );

    wire [3:0] st_state = stat[29:26];
    wire [5:0] st_lcmd  = stat[19:14];
    wire       st_rdreq = stat[0];
    wire [1:0] st_seq   = stat[3:2];
    wire [3:0] n_desync = dbg[3:0];

    //---------------------------------------------------------------- сторона машины (SPI) ------
    task xfer(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                @(negedge clk); mosi = tx[i]; sck = 1'b1;
                rx[i] = miso;
                @(posedge clk);
                @(negedge clk); sck = 1'b0;
                @(posedge clk);
            end
            repeat (24) @(posedge clk);
        end
    endtask

    reg [7:0] rxb;
    task ff(output [7:0] r); begin xfer(8'hFF, r); end endtask

    task send_cmd(input [5:0] idx, input [31:0] arg);
        begin
            xfer({2'b01, idx}, rxb);
            xfer(arg[31:24], rxb); xfer(arg[23:16], rxb);
            xfer(arg[15:8],  rxb); xfer(arg[7:0],   rxb);
            xfer(8'hFF, rxb);
        end
    endtask

    task wait_r1(input integer n, output [7:0] r);
        integer k; reg [7:0] bb;
        begin
            r = 8'hFF;
            for (k = 0; k < n; k = k + 1) begin
                ff(bb);
                if (bb[7] == 1'b0) begin r = bb; k = n; end
            end
        end
    endtask

    // первый байт с битом7=0 после кадра: pos = сколько байт до него, -1 = ответа нет вовсе
    integer r1_pos; reg [7:0] r1_val;
    task scan_r1(input integer lim);
        integer n; reg [7:0] x;
        begin
            r1_pos = -1; r1_val = 8'hFF;
            for (n = 0; n < lim; n = n + 1) begin
                ff(x);
                if ((r1_pos < 0) && (x[7] == 1'b0)) begin r1_pos = n; r1_val = x; end
            end
        end
    endtask

    // ищем токен данных 0xFE в следующих lim байтах (для проверки «лишнего блока не было»)
    integer tok_seen;
    task scan_token(input integer lim);
        integer n; reg [7:0] x;
        begin
            tok_seen = 0;
            for (n = 0; n < lim; n = n + 1) begin ff(x); if (x == 8'hFE) tok_seen = 1; end
        end
    endtask

    //---------------------------------------------------------------- сторона оболочки (ARM) ----
    integer arm_serves = 1;
    integer blocks_served = 0;

    task arm_write_ctl(input [31:0] w);
        begin
            @(posedge aclk) ctl = w;
            repeat (3) @(posedge aclk);
            ctl_we = ~ctl_we;
            repeat (6) @(posedge aclk);
        end
    endtask

    // блок, у каждого байта которого старший бит = 1 (байт данных != похож на R1)
    task arm_fill_buf(input [10:0] base, input [7:0] seed);
        integer i; reg [31:0] w;
        begin
            @(posedge aclk) bufa = {21'd0, base}; bufa_we = 1'b1;
            @(posedge aclk) bufa_we = 1'b0;
            repeat (10) @(posedge aclk);
            for (i = 0; i < 128; i = i + 1) begin
                w = {(8'h80 | ((seed + 8'd3 + i[7:0]*8'd4) & 8'h7F)),
                     (8'h80 | ((seed + 8'd2 + i[7:0]*8'd4) & 8'h7F)),
                     (8'h80 | ((seed + 8'd1 + i[7:0]*8'd4) & 8'h7F)),
                     (8'h80 | ((seed + 8'd0 + i[7:0]*8'd4) & 8'h7F))};
                @(posedge aclk) bufw = w; bufw_we = 1'b1;
                @(posedge aclk) bufw_we = 1'b0;
                repeat (8) @(posedge aclk);
            end
        end
    endtask

    initial begin : arm_service
        forever begin
            @(posedge aclk);
            if (st_rdreq && arm_serves) begin
                arm_fill_buf(11'h000, lba_q[7:0]);
                arm_write_ctl(32'h0000_0005 | ({30'd0, st_seq} << 6) | (32'd1 << 8));
                blocks_served = blocks_served + 1;
                arm_write_ctl(32'h0000_0005);
            end
        end
    end

    //---------------------------------------------------------------- инициализация -------------
    task card_init;
        reg [7:0] r; integer k;
        begin
            cs_n = 1'b1; repeat (10) ff(r); cs_n = 1'b0; ff(r);
            send_cmd(6'd0, 32'd0);  wait_r1(16, r);
            send_cmd(6'd8, 32'h1AA); wait_r1(16, r);
            ff(r); ff(r); ff(r); ff(r);
            for (k = 0; k < 4; k = k + 1) begin
                send_cmd(6'd55, 32'd0);        wait_r1(16, r);
                send_cmd(6'd41, 32'h4000_0000); wait_r1(16, r);
            end
        end
    endtask

    task read_one_block(output integer ok);
        reg [7:0] bb; integer k;
        begin
            ok = 0;
            for (k = 0; k < 4000; k = k + 1) begin
                ff(bb);
                if (bb == 8'hFE) begin ok = 1; k = 4000; end
            end
            if (ok) begin
                for (k = 0; k < 512; k = k + 1) ff(bb);
                ff(bb); ff(bb);              // CRC16 - вычитываем, как канонический драйвер
            end
        end
    endtask

    // после остановки карта ОБЯЗАНА снова слушать команды: одиночное чтение должно пройти
    task check_listens_again;
        reg [7:0] r; integer ok2;
        begin
            send_cmd(6'd17, 32'd9); wait_r1(16, r);
            chk(r == 8'h00, "CMD17 accepted after stop (R1=0x00)");
            read_one_block(ok2);
            chk(ok2 == 1,   "single-block read after stop delivered (0xFE token)");
        end
    endtask

    integer ok;
    reg [7:0] b;
    initial begin
        arst_n = 1'b0; repeat (10) @(posedge aclk); arst_n = 1'b1;
        repeat (20) @(posedge aclk);
        arm_write_ctl(32'h0000_0005);              // EN|CCS
        repeat (20) @(posedge aclk);

        //--------------------------------------------------------------------------------------
        $display("=== A. CMD12 ПОСРЕДИ ТЕЛА БЛОКА ===");
        card_init();
        send_cmd(6'd18, 32'd5); wait_r1(16, b);
        chk(b == 8'h00, "A: CMD18 accepted");
        read_one_block(ok);
        wait (st_rdreq == 1'b0);                   // оболочка отдала блок 2
        repeat (40) ff(b);                         // токен и ~39 байт данных блока 2
        chk(st_state == 4'd6, "A: card is inside block body (state=TX)");
        send_cmd(6'd12, 32'd0);
        scan_r1(700);
        $display("   первый байт с битом7=0: %02X на позиции %0d (data-байты все со старшим битом 1)",
                 r1_val, r1_pos);
        chk((r1_pos >= 0) && (r1_pos <= 8), "A: CMD12 response arrived within 8 bytes");
        chk(r1_val == 8'h00,               "A: CMD12 response is R1 0x00");
        check_listens_again();
        $display("   итог A: state=%0d last_cmd=%0d cmds=%0d rd=%0d desync=%0d",
                 st_state, st_lcmd, dbg[31:24], dbg[23:16], n_desync);
        chk(n_desync == 4'd0, "A: desync == 0");

        //--------------------------------------------------------------------------------------
        $display("=== B. CMD12 В ПАУЗЕ МЕЖДУ БЛОКАМИ, ОБОЛОЧКА МЕДЛИТ (снимок с виса) ===");
        arm_write_ctl(32'h0000_000D); arm_write_ctl(32'h0000_0005);
        card_init();
        send_cmd(6'd18, 32'd2048); wait_r1(16, b);
        chk(b == 8'h00, "B: CMD18 accepted");
        read_one_block(ok);
        chk(ok == 1, "B: first block delivered in full");
        arm_serves = 0;                            // главный цикл оболочки занят (на плате до 134 мс)
        repeat (4) @(posedge aclk);
        send_cmd(6'd12, 32'd0);                    // кадр целиком попадает в паузу
        scan_r1(64);
        $display("   state сразу после кадра=%0d, ответ %02X на позиции %0d, lba=%0d",
                 st_state, r1_val, r1_pos, lba_q);
        chk((r1_pos >= 0) && (r1_pos <= 8), "B: CMD12 response arrived within 8 bytes");
        chk(r1_val == 8'h00,               "B: CMD12 response is R1 0x00");
        arm_serves = 1;
        repeat (600) @(posedge aclk);              // оболочка ожила и досдала брошенный блок
        check_listens_again();
        $display("   итог B: state=%0d last_cmd=%0d cmds=%0d rd=%0d desync=%0d lba=%0d",
                 st_state, st_lcmd, dbg[31:24], dbg[23:16], n_desync, lba_q);
        chk(n_desync == 4'd0, "B: desync == 0");

        //--------------------------------------------------------------------------------------
        $display("=== C. CMD12 ДО ПЕРВОГО БЛОКА (карта ждёт оболочку в S_NAC) ===");
        arm_write_ctl(32'h0000_000D); arm_write_ctl(32'h0000_0005);
        card_init();
        arm_serves = 0;
        send_cmd(6'd18, 32'd7); wait_r1(16, b);
        chk(b == 8'h00, "C: CMD18 accepted");
        chk(st_state == 4'd4, "C: card waits for shell block (state=NAC)");
        send_cmd(6'd12, 32'd0);
        scan_r1(64);
        chk((r1_pos >= 0) && (r1_pos <= 8), "C: CMD12 response arrived within 8 bytes");
        chk(r1_val == 8'h00,               "C: CMD12 response is R1 0x00");
        arm_serves = 1;
        repeat (600) @(posedge aclk);
        scan_token(64);
        chk(tok_seen == 0, "C: no stray data block after stop (no 0xFE token)");
        check_listens_again();
        chk(n_desync == 4'd0, "C: desync == 0");

        //--------------------------------------------------------------------------------------
        $display("=== D. КАНОНИЧЕСКИЙ ДРАЙВЕР: два блока, CMD12 на границе, оболочка живая ===");
        arm_write_ctl(32'h0000_000D); arm_write_ctl(32'h0000_0005);
        card_init();
        send_cmd(6'd18, 32'd100); wait_r1(16, b);
        read_one_block(ok); chk(ok == 1, "D: block 1 delivered");
        read_one_block(ok); chk(ok == 1, "D: block 2 delivered");
        send_cmd(6'd12, 32'd0);
        scan_r1(64);
        chk((r1_pos >= 0) && (r1_pos <= 8), "D: CMD12 response arrived within 8 bytes");
        chk(r1_val == 8'h00,               "D: CMD12 response is R1 0x00");
        check_listens_again();
        $display("   итог D: state=%0d cmds=%0d rd=%0d desync=%0d lba=%0d",
                 st_state, dbg[31:24], dbg[23:16], n_desync, lba_q);
        chk(n_desync == 4'd0, "D: desync == 0");

        $display("\n==== tb_stop: %s (отказов %0d) ====", fails ? "FAILURES" : "ALL PASS", fails);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
