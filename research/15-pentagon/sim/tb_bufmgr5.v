`timescale 1ns/1ps
// tb_bufmgr5 - случайные сочетания frame_done / frame_kick (в том числе в одном такте) и проверка:
//   1) писатель никогда не совпадает с выводимой парой (disp, dprev) и с ready/older;
//   2) после гашения пара - это два СОСЕДНИХ кадра машины: номер(disp) = номер(dprev) + 1;
//   3) disp - всегда последний целиком записанный кадр на момент гашения (как у fb_bufmgr3).
// Запуск: xvlog ../sources/fb_bufmgr5.v tb_bufmgr5.v && xelab tb_bufmgr5 -s tb5 && xsim tb5 -R
module tb_bufmgr5;
    reg clk = 0, resetn = 0, frame_done = 0, frame_kick = 0;
    always #5 clk = ~clk;
    wire [31:0] wr_base, disp_base, prev_base; wire prev_ok;
    wire [2:0] wr_b, disp_b, prev_b;
    fb_bufmgr5 dut(.clk(clk), .resetn(resetn), .frame_done(frame_done), .frame_kick(frame_kick),
                   .wr_base(wr_base), .disp_base(disp_base), .prev_base(prev_base), .prev_ok(prev_ok),
                   .wr_buf_o(wr_b), .disp_buf_o(disp_b), .prev_buf_o(prev_b));
    integer frame_no [0:4];      // номер кадра машины, лежащий в буфере
    integer fcnt = 0, errors = 0, kicks = 0, dones = 0, both = 0, pairs = 0, i;
    integer seed = 12345;
    initial begin
        for (i = 0; i < 5; i = i + 1) frame_no[i] = -100;
        repeat (3) @(posedge clk); resetn = 1;
        for (i = 0; i < 400000; i = i + 1) begin
            @(negedge clk);
            // машина чуть быстрее HDMI: done ~ раз в 50 тактов, kick ~ раз в 50.02; плюс случайный разброс
            frame_done = (($random(seed) & 63) == 0);
            frame_kick = (($random(seed) & 63) == 1) | (frame_done & (($random(seed) & 7) == 0));
            @(posedge clk); #1;
        end
        $display("dones=%0d kicks=%0d both=%0d checked_pairs=%0d errors=%0d", dones, kicks, both, pairs, errors);
        if (errors == 0) $display("TB_BUFMGR5 PASS"); else $display("TB_BUFMGR5 FAIL");
        $finish;
    end
    // модель: номера кадров в ролях ready/older, обновляются в том же порядке, что и в DUT
    integer m_ready = -1, m_older = -2, exp_disp = -1, exp_prev = -2;
    reg kick_d = 0;
    always @(posedge clk) begin
        kick_d <= frame_kick & resetn;
        if (resetn) begin
            if (wr_b == disp_b || wr_b == prev_b || wr_b == dut.ready || wr_b == dut.older) begin
                errors = errors + 1;
                if (errors < 10) $display("ERR t=%0t writer %0d collides: disp=%0d prev=%0d ready=%0d older=%0d", $time, wr_b, disp_b, prev_b, dut.ready, dut.older);
            end
            if (frame_kick) begin exp_disp = m_ready; exp_prev = m_older; kicks = kicks + 1; end   // по значениям ДО фронта
            if (frame_done) begin
                frame_no[wr_b] = fcnt; m_older = m_ready; m_ready = fcnt; fcnt = fcnt + 1; dones = dones + 1;
            end
            if (frame_done && frame_kick) both = both + 1;
        end
    end
    always @(negedge clk) if (kick_d && prev_ok) begin
        pairs = pairs + 1;
        if (frame_no[disp_b] != exp_disp || frame_no[prev_b] != exp_prev || exp_disp != exp_prev + 1) begin
            errors = errors + 1;
            if (errors < 10) $display("ERR t=%0t disp#%0d prev#%0d, expected #%0d/#%0d", $time, frame_no[disp_b], frame_no[prev_b], exp_disp, exp_prev);
        end
    end
endmodule
