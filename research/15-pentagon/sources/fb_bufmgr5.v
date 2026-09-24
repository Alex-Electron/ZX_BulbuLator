`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_bufmgr5.v - пятибуферный менеджер кадра: вывод получает ДВА СОСЕДНИХ кадра машины (N и N-1).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// B0198. Зачем: смешение кадров на выводе (Display -> Frame blend). Демки, которые каждый кадр
// переключают экран (тень, gigascreen), на ЭЛТ сливаются в ровную картинку, а на ЖК мерцают с
// частотой 25 Гц. Выводу нужны два СОСЕДНИХ кадра МАШИНЫ, а не два показанных на HDMI: машина идёт
// 50.02 Гц против 50.00 у HDMI, и раз в ~50 с один кадр машины не показывается вовсе. Смешай мы два
// показанных - в этот момент пара окажется (N, N-2), то есть одной фазы, и тень мигнёт.
//
// Роли буферов:
//   wr    - сюда пишет захват;
//   ready - последний ЦЕЛИКОМ записанный кадр (N);
//   older - записанный перед ним (N-1);
//   disp / dprev - пара, защёлкнутая выводом на гашении HDMI (frame_kick): disp <= ready, dprev <= older.
// Писатель не имеет права трогать ни одну из четырёх ролей: disp и dprev сейчас выводятся, ready и
// older понадобятся на следующем гашении. Худший случай - все четыре разные (машина успела два кадра
// за один кадр HDMI), значит пятый буфер свободен ВСЕГДА, и захват, который остановить нельзя, никогда
// не наезжает на читаемое. При четырёх буферах в этот момент свободного бы не нашлось.
//
// disp_base ведёт себя ровно как у fb_bufmgr3 (последний готовый кадр на гашении), поэтому при
// выключенном смешении вывод бит в бит прежний. prev_ok = 1, когда пара уже состоит из двух
// настоящих кадров (после сброса первые кадры смешивать не с чем).
//-------------------------------------------------------------------------------------------------
module fb_bufmgr5 #(
    parameter [31:0] FB0    = 32'h0FF0_0000,
    parameter [31:0] STRIDE = 32'h0001_0000
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire        frame_done,      // захват дописал кадр в wr
    input  wire        frame_kick,      // гашение HDMI: защёлкнуть пару для вывода

    output wire [31:0] wr_base,
    output wire [31:0] disp_base,       // кадр N
    output wire [31:0] prev_base,       // кадр N-1
    output wire        prev_ok,
    output wire [2:0]  wr_buf_o,
    output wire [2:0]  disp_buf_o,
    output wire [2:0]  prev_buf_o
);
    reg [2:0] wr, ready, older, disp, dprev;
    reg [1:0] nfr;                       // сколько кадров записано (насыщается на 2)
    reg       pok;
    assign wr_buf_o = wr; assign disp_buf_o = disp; assign prev_buf_o = dprev; assign prev_ok = pok;

    function [31:0] base_of(input [2:0] b); base_of = FB0 + (STRIDE * b); endfunction
    assign wr_base   = base_of(wr);
    assign disp_base = base_of(disp);
    assign prev_base = base_of(dprev);

    // первый буфер 0..4, не входящий в занятые a,b,c,d
    function [2:0] pick_free(input [2:0] a, input [2:0] b, input [2:0] c, input [2:0] d);
        integer k; reg found; reg [2:0] r;
        begin
            found = 1'b0; r = 3'd0;
            for (k = 0; k < 5; k = k + 1)
                if (!found && k[2:0]!=a && k[2:0]!=b && k[2:0]!=c && k[2:0]!=d) begin r = k[2:0]; found = 1'b1; end
            pick_free = r;
        end
    endfunction

    // пара вывода ПОСЛЕ этого такта (гашение в тот же такт берёт ещё СТАРЫЕ ready/older)
    wire [2:0] disp_n  = frame_kick ? ready : disp;
    wire [2:0] dprev_n = frame_kick ? older : dprev;

    always @(posedge clk) begin
        if (!resetn) begin
            wr<=3'd0; ready<=3'd1; older<=3'd2; disp<=3'd3; dprev<=3'd4; nfr<=2'd0; pok<=1'b0;
        end else begin
            if (frame_done) begin
                older <= ready;
                ready <= wr;
                // занятые после такта: disp_n, dprev_n, новый ready (= wr), новый older (= ready)
                wr    <= pick_free(disp_n, dprev_n, wr, ready);
                if (nfr != 2'd2) nfr <= nfr + 2'd1;
            end
            if (frame_kick) begin
                disp  <= ready;
                dprev <= older;
                pok   <= (nfr == 2'd2);
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
