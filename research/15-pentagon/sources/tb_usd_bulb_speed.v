`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tb_usd_bulb_speed.v - РЕГРЕССИЯ НА ДВЕ СКОРОСТИ SPI (опция машины MACHINE_CFG[20], B0145).
//
// В стенде НАСТОЯЩАЯ связка usd_bulb + divmmc_card, и карте, как в топе, подан .ce(1'b1). Хост
// изображает Z80: запись и чтение порта #57 (Z-Controller) с окном IORQ около 48 тактов spclk.
// Плюсарг TURBO выбирает режим: TURBO=0 - Standard 3.5 МГц, TURBO=1 - Turbo 28.33 МГц.
//
// Что доказывает: инициализация проходит ОДИНАКОВО в обоих режимах (CMD0 и CMD8 отвечают R1 = 0x01,
// desync = 0). До B0145 в стандартном режиме движок не выдавал НИ ОДНОГО фронта ck (ckedges = 0,
// потерянный стартовый импульс), а если импульс починить, но оставить выборку карты по УРОВНЮ sck -
// счётчик рассинхрона насыщался на 15 и ни одна команда не разбиралась.
//
// Запуск (ThinkPad, Vivado 2023.1):
//   export PATH=/tools/Xilinx/Vivado/2023.1/bin:$PATH
//   xvlog usd_bulb.v divmmc_card.v tb_usd_bulb_speed.v
//   xelab -debug off --timescale 1ns/1ps tb_zc_speed -s tbz
//   xsim tbz -testplusarg TURBO=1 -runall ; xsim tbz -testplusarg TURBO=0 -runall
//-------------------------------------------------------------------------------------------------
module tb_zc_speed;

    reg clk = 1'b0, aclk = 1'b0;
    always #8.824 clk  = ~clk;
    always #5.0   aclk = ~aclk;

    integer turbo_i;
    reg turbo = 1'b1;

    // clock enables like clock_zx.v at warp=0: one clk in 8
    reg [2:0] cec = 3'd0;
    always @(posedge clk) cec <= cec + 3'd1;
    wire ne7M0 = (cec == 3'd0);
    wire pe7M0 = (cec == 3'd4);

    // Z80 bus stub
    reg        iorq = 1'b1, wr = 1'b1, rd = 1'b1;
    reg  [7:0] a = 8'h00, d = 8'hFF;
    wire [7:0] q;
    wire       cs, ck, mosi, miso, zc_sel;

    usd_bulb uSD (
        .clock(clk), .cep(pe7M0), .cen(ne7M0), .turbo(turbo),
        .en_dm(1'b0), .en_zc(1'b1), .sd_cd(1'b1),
        .iorq(iorq), .wr(wr), .rd(rd), .d(d), .q(q), .a(a),
        .cs(cs), .ck(ck), .miso(miso), .mosi(mosi), .zc_sel(zc_sel)
    );

    reg        arst_n = 1'b0;
    reg [31:0] ctl = 32'd0;  reg ctl_we = 1'b0;
    reg [31:0] cap = 32'h0001_0000;
    reg [31:0] bufa = 32'd0, bufw = 32'd0;
    wire [31:0] stat, lba_q, dbg, bufa_q, bufr_q;

    divmmc_card dut (
        .clk(clk), .ce(1'b1), .rst_n(1'b1), .en(1'b1),
        .cs_n(cs), .sck(ck), .mosi(mosi), .miso(miso), .map_dbg(9'd0),
        .aclk(aclk), .arst_n(arst_n),
        .ctl(ctl), .ctl_we(ctl_we), .cap_in(cap),
        .bufa_in(bufa), .bufa_we(1'b0),
        .bufw_in(bufw), .bufw_we(1'b0), .bufr_re(1'b0),
        .bufa_q(bufa_q), .bufr_q(bufr_q),
        .stat(stat), .lba_q(lba_q), .dbg(dbg)
    );

    wire [3:0] st_state = stat[29:26];
    wire [5:0] st_lcmd  = stat[19:14];
    wire [7:0] n_cmds   = dbg[31:24];
    wire [3:0] n_desync = dbg[3:0];

    task arm_write_ctl(input [31:0] w);
        begin
            @(posedge aclk) ctl = w;
            repeat (3) @(posedge aclk);
            ctl_we = ~ctl_we;
            repeat (8) @(posedge aclk);
        end
    endtask

    // one port write to #57 = one SPI byte; then wait for engine idle
    task pwrite57(input [7:0] v);
        begin
            @(negedge clk) begin a = 8'h57; d = v; iorq = 1'b0; wr = 1'b0; end
            repeat (40) @(posedge clk);   // Z80 IORQ/WR window ~3 T = 48 spclk
            @(negedge clk) begin iorq = 1'b1; wr = 1'b1; end
            // 8 bits * 16 clk in standard mode + slack
            repeat (turbo ? 40 : 180) @(posedge clk);
        end
    endtask

    task pread57(output [7:0] v);
        begin
            @(negedge clk) begin a = 8'h57; iorq = 1'b0; rd = 1'b0; end
            repeat (40) @(posedge clk);   // Z80 IORQ/WR window ~3 T = 48 spclk
            v = q;
            @(negedge clk) begin iorq = 1'b1; rd = 1'b1; end
            repeat (turbo ? 40 : 180) @(posedge clk);
        end
    endtask

    task pwrite77(input [7:0] v);
        begin
            @(negedge clk) begin a = 8'h77; d = v; iorq = 1'b0; wr = 1'b0; end
            repeat (40) @(posedge clk);   // Z80 IORQ/WR window ~3 T = 48 spclk
            @(negedge clk) begin iorq = 1'b1; wr = 1'b1; end
            repeat (10) @(posedge clk);
        end
    endtask

    integer ckedges = 0;
    reg ck_d = 0;
    always @(posedge clk) begin
        if (ck && !ck_d) ckedges = ckedges + 1;
        ck_d <= ck;
    end
    reg [7:0] rb;
    integer k;
    initial begin
        turbo_i = 1;
        if (!$value$plusargs("TURBO=%d", turbo_i)) turbo_i = 1;
        turbo = (turbo_i != 0);
        $display("=== turbo=%0d ===", turbo_i);
        repeat (20) @(posedge aclk); arst_n = 1'b1;
        arm_write_ctl(32'h0000_0005);          // EN | CCS
        repeat (50) @(posedge clk);

        pwrite77(8'h01);                       // select card (cs <= d[1] | ~d[0])
        $display("  after pwrite77: cs=%b iorq=%b wr=%b a=%02h d=%02h", cs, iorq, wr, a, d);
        repeat (20) @(posedge clk);

        // 10 dummy 0xFF clock bytes, then CMD0
        for (k = 0; k < 10; k = k + 1) pwrite57(8'hFF);
        pwrite57(8'h40); pwrite57(8'h00); pwrite57(8'h00);
        pwrite57(8'h00); pwrite57(8'h00); pwrite57(8'h95);
        for (k = 0; k < 8; k = k + 1) begin
            pread57(rb);
            if (rb[7] == 1'b0) begin
                $display("  R1 = %02h after %0d polls", rb, k);
                k = 8;
            end
        end
        // CMD8
        pwrite57(8'h48); pwrite57(8'h00); pwrite57(8'h00);
        pwrite57(8'h01); pwrite57(8'hAA); pwrite57(8'h87);
        for (k = 0; k < 8; k = k + 1) begin
            pread57(rb);
            if (rb[7] == 1'b0) begin
                $display("  R1(CMD8) = %02h", rb);
                k = 8;
            end
        end
        $display("  probe: attached=%b cs=%b ckedges=%0d bitc=%0d count=%0d", dut.attached, cs, ckedges, dut.bitc, uSD.count);
        $display("RESULT turbo=%0d: cmds=%0d last_cmd=%0d state=%0d desync=%0d",
                 turbo_i, n_cmds, st_lcmd, st_state, n_desync);
        $finish;
    end
endmodule
