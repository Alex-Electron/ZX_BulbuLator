`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_nemo_ide.sv - стенд на дефект B0117: DRQ должен сниматься ПО ФАКТУ вычерпывания блока.
//
// Что именно доказываем (в железе это стоило двух прогонов и 105 + 87 битых байт):
//   1. после 512-го байта DRQ снят В ТОТ ЖЕ МОМЕНТ, а не когда спохватится ARM;
//   2. на промежуточном блоке машина видит BSY, пока ARM не подложит следующий;
//   3. второй блок машина читает ЦЕЛИКОМ и это данные ВТОРОГО блока (главная проверка: раньше
//      сюда приезжало начало первого);
//   4. на последнем блоке не остаётся ни DRQ, ни BSY;
//   5. чтение данных при снятом DRQ не двигает указатель - иначе служба ARM примет чужие
//      шевеления за «машина взялась за новый блок».
// Отдельно проверяем IDENTIFY: он идёт тем же путём и обязан закончиться чистым 0x50.
//-------------------------------------------------------------------------------------------------
module tb_nemo_ide;
    reg clk = 0, reset_n = 0;
    always #8.824 clk = ~clk;          // 56.667 МГц - такт машины

    reg        iorq_n = 1, m1_n = 1, rd_n = 1, wr_n = 1;
    reg  [7:0] a = 0, din = 0;
    wire [7:0] dout;
    wire       oe, sup;

    // мост к ARM
    reg  [7:0] ide_status = 8'h50;
    reg  [8:0] buf_waddr  = 0;
    reg  [7:0] buf_wdata  = 0;
    reg        buf_we = 0, arm_stb = 0, buf_arm_owns = 0;
    wire [8:0] buf_raddr;
    wire       dev_slave, drq_live, gap_wait;

    integer errors = 0;
    reg [7:0] blk1 [0:511];
    reg [7:0] blk2 [0:511];

    nemo_ide dut (
        .clk(clk), .reset_n(reset_n), .en(1'b1), .dos_paged(1'b0),
        .iorq_n(iorq_n), .m1_n(m1_n), .rd_n(rd_n), .wr_n(wr_n), .a(a), .din(din),
        .dout(dout), .oe(oe), .sup(sup),
        .ide_cmd(), .ide_cmd_stb(), .ide_feat(), .ide_cnt(),
        .ide_lba0(), .ide_lba1(), .ide_lba2(), .ide_head(),
        .ide_status(ide_status), .ide_error(8'h00),
        .buf_waddr(buf_waddr), .buf_wdata(buf_wdata), .buf_we(buf_we),
        .arm_stb(arm_stb), .buf_raddr(buf_raddr), .dev_slave(dev_slave),
        .buf_arm_owns(buf_arm_owns), .drq_live(drq_live), .gap_wait(gap_wait)
    );

    // ---- шина машины ----
    task host_write(input [7:0] port, input [7:0] val);
    begin
        @(posedge clk); a = port; din = val; iorq_n = 0; wr_n = 0;
        repeat (8) @(posedge clk);
        wr_n = 1; iorq_n = 1; @(posedge clk);
    end endtask

    // Чтение держим 8 тактов, как настоящий цикл ввода Z80: сигнал чтения живёт весь цикл, а байт
    // процессор забирает в последнем такте - в этом вся суть правила «двигать указатель по спаду».
    task host_read(input [7:0] port, output [7:0] val);
    begin
        @(posedge clk); a = port; iorq_n = 0; rd_n = 0;
        repeat (7) @(posedge clk);
        val = dout;                     // берём в последнем такте, как Z80
        @(posedge clk); rd_n = 1; iorq_n = 1; @(posedge clk);
    end endtask

    // ---- сторона ARM: ровно те слова, что шлёт nemo_push ----
    task arm_word(input [7:0] st, input owns, input we, input [8:0] wa, input [7:0] wd);
    begin
        @(posedge clk);
        ide_status = st; buf_arm_owns = owns; buf_we = we; buf_waddr = wa; buf_wdata = wd;
        arm_stb = 1; @(posedge clk); arm_stb = 0;
    end endtask

    // nemo_push(status, owns=0, buf, 512): 512 слов заливки, затем «чистое» слово состояния
    task arm_push_block(input [7:0] st, input integer which);
        integer i;
    begin
        arm_word(8'h80, 1, 0, 0, 0);                 // BSY, пока наполняем буфер
        for (i = 0; i < 512; i = i + 1)
            arm_word(st, 0, 1, i[8:0], (which == 1) ? blk1[i] : blk2[i]);
        arm_word(st, 0, 0, 0, 0);                    // снять строб, оставить состояние
    end endtask

    task arm_plain(input [7:0] st, input owns);
    begin arm_word(st, owns, 0, 0, 0); end endtask

    /* Подписи проверок - латиницей СОЗНАТЕЛЬНО: xsim корёжит UTF-8, переданный в задачу
       аргументом-строкой (в литерале $display кириллица печатается нормально, а здесь приходит
       мусор). Смысл проверок живёт в комментариях выше, а из отчёта должно быть видно, что
       именно отвалилось. */
    task check(input cond, input string what);
    begin
        if (!cond) begin $display("ОТКАЗ: %0s (t=%0t)", what, $time); errors = errors + 1; end
        else         $display("  ok: %0s", what);
    end endtask

    // Прочитать блок из 512 байт и сверить с эталоном
    task read_block(input integer which, input string label);
        integer i, bad;
        reg [7:0] lo, hi_b, want;
    begin
        bad = 0;
        for (i = 0; i < 256; i = i + 1) begin
            host_read(8'h10, lo);                    // младший (и защёлкивает старший)
            host_read(8'h11, hi_b);                  // старший из защёлки
            want = (which == 1) ? blk1[2*i]   : blk2[2*i];
            if (lo != want)   bad = bad + 1;
            want = (which == 1) ? blk1[2*i+1] : blk2[2*i+1];
            if (hi_b != want) bad = bad + 1;
        end
        if (bad != 0) begin
            $display("ОТКАЗ: %0s - расхождений байт: %0d", label, bad); errors = errors + 1;
        end else $display("  ok: %0s - 512 байт байт-в-байт", label);
    end endtask

    reg [7:0] st, tmp;
    integer i;
    initial begin
        for (i = 0; i < 512; i = i + 1) begin
            blk1[i] = i[7:0] ^ 8'h5A;                // два ЗАВЕДОМО разных узора: без затравки
            blk2[i] = i[7:0] ^ 8'hA5;                // «прочитал верно» не отличить от «прочитал старое»
        end
        repeat (10) @(posedge clk); reset_n = 1; repeat (10) @(posedge clk);

        $display("=== 1. Многосекторное чтение: два блока подряд ===");
        host_write(8'hF0, 8'h20);                    // READ SECTOR(S)
        host_read(8'hF0, st);
        check(st[7] === 1'b1, "cmd write -> machine sees BSY (hardware, B0115)");

        arm_push_block(8'h58, 1);                    // первый блок, НЕ последний
        host_read(8'hF0, st);
        check(st[7] === 1'b0 && st[3] === 1'b1, "block loaded: BSY off, DRQ on");
        check(st[1] === 1'b0, "last-block marker is NOT visible to the machine");

        read_block(1, "block 1");

        host_read(8'hF0, st);
        check(st[3] === 1'b0, "512 bytes drained -> DRQ cleared BY THE FABRIC, no ARM involved");
        check(st[7] === 1'b1, "between blocks the machine sees BSY (else it re-reads the old buffer)");
        check(gap_wait === 1'b1, "fabric tells ARM: waiting for next block");

        // Пункт 5: указатель при снятом DRQ стоять.
        tmp = buf_raddr;
        host_read(8'h10, st); host_read(8'h10, st);
        check(buf_raddr === tmp, "data reads without DRQ do not move the pointer");

        arm_push_block(8'h5A, 2);                    // второй блок, ПОСЛЕДНИЙ (бит1 = метка)
        host_read(8'hF0, st);
        check(st[7] === 1'b0 && st[3] === 1'b1, "block 2 loaded: BSY off, DRQ on");
        check(gap_wait === 1'b0, "wait cleared");

        read_block(2, "block 2 == MAIN CHECK (used to deliver the start of block 1)");

        host_read(8'hF0, st);
        check(st[3] === 1'b0, "last block drained -> DRQ gone for good");
        check(st[7] === 1'b0, "and no BSY hangs: transfer over, nothing left to wait for");
        check(gap_wait === 1'b0, "fabric waits for nobody");

        arm_plain(8'h50, 0);                         // ide_rd_stop
        host_read(8'hF0, st);
        check(st === 8'h50, "final status is a clean DRDY|DSC");

        $display("=== 2. IDENTIFY: единственный блок, он же последний ===");
        host_write(8'hF0, 8'hEC);
        arm_push_block(8'h5A, 1);
        host_read(8'hF0, st);
        check(st[3] === 1'b1 && st[7] === 1'b0, "IDENTIFY: data ready");
        read_block(1, "IDENTIFY 512 bytes");
        host_read(8'hF0, st);
        check(st[3] === 1'b0 && st[7] === 1'b0, "IDENTIFY ended with no DRQ and no BSY");

        $display("=== 3. Новая команда посреди передачи отменяет буфер ===");
        arm_push_block(8'h58, 2);
        host_read(8'h10, tmp); host_read(8'h11, tmp);   // забрали одно слово и передумали
        host_write(8'hF0, 8'h20);
        host_read(8'hF0, st);
        check(st[3] === 1'b0, "new command clears DRQ: the old buffer is not its data");
        check(buf_raddr === 9'd0, "pointer reset to zero");

        if (errors == 0) $display("\nИТОГ: стенд пройден полностью");
        else             $display("\nИТОГ: ОТКАЗОВ %0d", errors);
        $finish;
    end
endmodule
