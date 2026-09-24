`timescale 1ps/1ps
// tb_line_disp_blend - читатель строк fb_line_disp (B0198) с параметрами ZX, модель DDR с двумя кадрами
// известного содержимого, развёртка 720p50. Каждый выведенный пиксель сверяется с ожиданием:
//   фаза OFF  : ровно цвет кадра N (как до B0198);
//   фаза ON   : точное среднее кадров N и N-1 по каналам;
//   фаза SWIT : режим переключается посреди кадра - каждая ИСХОДНАЯ строка обязана быть целиком
//               или смешанной, или нет (мусора и половинок быть не должно);
//   задержка пикселя (латентность) в OFF и ON обязана быть одной и той же;
//   недогрузок строк (underrun_cnt) после разгона - ноль.
// Запуск (ThinkPad): xvlog ../sources/fb_line_disp.v tb_line_disp_blend.v && xelab tb_line_disp_blend -s tld && xsim tld -R
module tb_line_disp_blend;
    localparam integer SRC_W=384, SRC_H=302, HM=256, VM=58, XM=2, YM=2;
    localparam integer HT=1980, HA=1280, VT=750, VA=720;
    localparam [31:0] FA = 32'h0FF0_0000, FB = 32'h0FF1_0000;   // кадр N и кадр N-1

    reg clk = 0, rd_clk = 0, resetn = 0;
    always #5000 clk = ~clk;          // 100 МГц
    always #6734 rd_clk = ~rd_clk;    // ~74.25 МГц

    // ---- развёртка ----
    reg [10:0] cx = 0, cy = 0;
    always @(posedge rd_clk) begin
        if (cx == HT-1) begin cx <= 0; cy <= (cy == VT-1) ? 11'd0 : cy + 11'd1; end
        else cx <= cx + 11'd1;
    end
    // frame_kick: вход в гашение (cy >= 720), тоггл -> домен clk (как в control_plane)
    reg vbl_tog = 0, invbl_d = 0;
    always @(posedge rd_clk) begin invbl_d <= (cy >= VA); if ((cy >= VA) && !invbl_d) vbl_tog <= ~vbl_tog; end
    reg [2:0] vbl_s = 0; always @(posedge clk) vbl_s <= {vbl_s[1:0], vbl_tog};
    wire frame_kick = vbl_s[2] ^ vbl_s[1];
    reg frame_kick_d = 0; always @(posedge clk) frame_kick_d <= frame_kick;

    // ---- содержимое кадров: 4bpp, пиксель i слова лежит в битах [4i+:4] ----
    function [3:0] pix(input integer f, input integer x, input integer y); pix = (x + y*3 + f*5) & 15; endfunction
    function [23:0] palf(input [3:0] v);
        palf = { v[2] ? (v[3] ? 8'hFF : 8'hD7) : 8'h00, v[1] ? (v[3] ? 8'hFF : 8'hD7) : 8'h00, v[0] ? (v[3] ? 8'hFF : 8'hD7) : 8'h00 };
    endfunction
    function [23:0] avg(input [23:0] a, input [23:0] b);
        reg [8:0] r, g, bb; begin r = a[23:16] + b[23:16]; g = a[15:8] + b[15:8]; bb = a[7:0] + b[7:0]; avg = {r[8:1], g[8:1], bb[8:1]}; end
    endfunction
    function [63:0] ddr_word(input [31:0] addr);   // слово DDR по байтовому адресу
        integer f, w, x0, y, k; reg [63:0] d;
        begin
            f = (addr >= FB) ? 1 : 0;
            w = (addr - (f ? FB : FA)) >> 3;            // номер 64-битного слова в кадре
            y = (w*16) / SRC_W; x0 = (w*16) % SRC_W;
            for (k = 0; k < 16; k = k + 1) d[4*k +: 4] = pix(f ? 1 : 0, x0 + k, y);   // кадр N = f0, N-1 = f1
            ddr_word = d;
        end
    endfunction

    // ---- модель AXI-чтения: очередь бёрстов, задержка 30 тактов, данные строго по порядку ----
    wire [31:0] ar_addr; wire ar_valid; wire [3:0] ar_len; wire r_ready;
    reg ar_ready = 1; reg [63:0] r_data = 0; reg r_valid = 0, r_last = 0;
    reg [31:0] q_addr [0:15]; integer q_wr = 0, q_rd = 0, lat = 0, beat = 0;
    always @(posedge clk) begin
        if (ar_valid && ar_ready) begin q_addr[q_wr % 16] <= ar_addr; q_wr <= q_wr + 1; end
        r_valid <= 0; r_last <= 0;
        if (q_rd != q_wr) begin
            if (lat < 30) lat <= lat + 1;
            else begin
                r_valid <= 1; r_data <= ddr_word(q_addr[q_rd % 16] + beat*8); r_last <= (beat == 15);
                if (beat == 15) begin beat <= 0; q_rd <= q_rd + 1; lat <= 0; end else beat <= beat + 1;
            end
        end
    end

    reg blend_en = 0;
    wire [23:0] rgb; wire live, idle; wire [15:0] und, stl;
    fb_line_disp #(.SRC_W(384), .STRIDE(384), .CROP_W(384), .CROP_H(302), .HMARGIN(256), .VMARGIN(58), .SX0(0),
                   .SRC_BPP(4), .WSH(4), .LBPP(2), .FBURSTS(3)) dut (
        .pal_wclk(clk), .pal_we(1'b0), .pal_addr(8'd0), .pal_rgb(24'd0),
        .clk(clk), .resetn(resetn), .disp_base(FA), .prev_base(FB), .prev_ok(1'b1), .blend_en(blend_en),
        .frame_kick(frame_kick_d),
        .ar_addr(ar_addr), .ar_id(), .ar_len(ar_len), .ar_size(), .ar_burst(), .ar_cache(), .ar_prot(), .ar_lock(), .ar_qos(),
        .ar_valid(ar_valid), .ar_ready(ar_ready), .r_data(r_data), .r_last(r_last), .r_valid(r_valid), .r_ready(r_ready),
        .rd_clk(rd_clk), .cx(cx), .cy(cy),
        .hmargin_a(12'd256), .vmargin_a(12'd58), .xmul_a(4'd2), .ymul_a(4'd2),
        .sx0_a(12'd0), .sy0_a(12'd0), .cropw_a(12'd384), .croph_a(12'd302),
        .rgb(rgb), .live(live), .underrun_cnt(und), .stale_base_cnt(stl), .quiesce_i(1'b0), .idle_o(idle));

    // ---- проверка: для латентности L ожидание считается по координате L тактов назад ----
    integer L, phase = 0, frames = 0;   // phase 0 разгон, 1 OFF, 2 ON, 3 SWITCH
    reg [10:0] cxh [0:7]; reg [10:0] cyh [0:7]; integer i;
    integer err_off [0:7], err_on [0:7], checked = 0, sw_lines_bad = 0, und_at_start = 0;
    reg [1:0] line_kind [0:SRC_H-1];   // SWITCH: 0 не видели, 1 смешанная, 2 нет, 3 испорчена
    initial for (i = 0; i < 8; i = i + 1) begin err_off[i] = 0; err_on[i] = 0; end
    always @(posedge rd_clk) begin
        for (i = 7; i > 0; i = i - 1) begin cxh[i] <= cxh[i-1]; cyh[i] <= cyh[i-1]; end
        cxh[0] <= cx; cyh[0] <= cy;
    end
    function [23:0] expect(input integer mode, input [10:0] x, input [10:0] y);   // mode 0 OFF, 1 ON
        integer sx, sy;
        begin
            if (x < HM || x >= HM + SRC_W*XM || y < VM || y >= VM + SRC_H*YM) expect = 24'h505050;
            else begin
                sx = (x - HM) / XM; sy = (y - VM) / YM;
                expect = mode ? avg(palf(pix(0,sx,sy)), palf(pix(1,sx,sy))) : palf(pix(0,sx,sy));
            end
        end
    endfunction
    integer sy_sw, k;
    always @(posedge rd_clk) if (phase == 1 || phase == 2 || phase == 3) begin
        for (L = 1; L < 8; L = L + 1) begin
            if (phase == 1 && rgb != expect(0, cxh[L-1], cyh[L-1])) err_off[L] = err_off[L] + 1;
            if (phase == 2 && rgb != expect(1, cxh[L-1], cyh[L-1])) err_on[L]  = err_on[L]  + 1;
        end
        checked = checked + 1;
    end
    // SWITCH: сверка по найденной латентности, классификация исходных строк
    integer LB = -1;
    always @(posedge rd_clk) if (phase == 3 && LB > 0) begin
        if (cyh[LB-1] >= VM && cyh[LB-1] < VM + SRC_H*YM && cxh[LB-1] >= HM && cxh[LB-1] < HM + SRC_W*XM) begin
            sy_sw = (cyh[LB-1] - VM) / YM;
            k = (rgb == expect(1, cxh[LB-1], cyh[LB-1])) ? 1 : (rgb == expect(0, cxh[LB-1], cyh[LB-1])) ? 2 : 3;
            // пиксели, где смешанное и несмешанное совпадают, не несут информации
            if (expect(1, cxh[LB-1], cyh[LB-1]) == expect(0, cxh[LB-1], cyh[LB-1])) k = 0;
            if (k == 3) line_kind[sy_sw] = 3;
            else if (k != 0) begin
                if (line_kind[sy_sw] == 0) line_kind[sy_sw] = k;
                else if (line_kind[sy_sw] != k && line_kind[sy_sw] != 3) line_kind[sy_sw] = 3;
            end
        end
    end

    // ---- сценарий по кадрам (кадр = переход cy в 0) ----
    reg [10:0] cy_d = 0;
    initial begin
        for (i = 0; i < SRC_H; i = i + 1) line_kind[i] = 0;
        #100000 resetn = 1;
    end
    always @(posedge rd_clk) begin
        cy_d <= cy;
        if (cy == 0 && cy_d == VT-1) begin
            frames = frames + 1;
            case (frames)
                3: begin phase = 1; und_at_start = und; end                          // OFF, 2 кадра
                5: begin phase = 0; blend_en = 1; end                                // включить: кадр на заливку
                7: begin phase = 2; end                                              // ON, 2 кадра
                9: begin phase = 3;                                                  // найти латентность, переключать
                       LB = -1;
                       for (L = 7; L >= 1; L = L - 1) if (err_off[L] == 0 && err_on[L] == 0) LB = L;
                   end
                10: begin
                        $display("checked=%0d", checked);
                        for (L = 1; L < 8; L = L + 1) $display("L=%0d  err_off=%0d  err_on=%0d", L, err_off[L], err_on[L]);
                        for (i = 0; i < SRC_H; i = i + 1) if (line_kind[i] == 3) sw_lines_bad = sw_lines_bad + 1;
                        $display("latency=%0d  switch_bad_lines=%0d  underrun_after_start=%0d  live=%0d",
                                 LB, sw_lines_bad, und - und_at_start, live);
                        if (LB > 0 && sw_lines_bad == 0 && und == und_at_start) $display("TB_LINE_DISP_BLEND PASS");
                        else $display("TB_LINE_DISP_BLEND FAIL");
                        $finish;
                    end
            endcase
        end
        // в кадре SWITCH дёргаем режим несколько раз посреди картинки
        if (phase == 3 && cx == 100 && (cy == 150 || cy == 301 || cy == 452 || cy == 603)) blend_en = ~blend_en;
    end
endmodule
