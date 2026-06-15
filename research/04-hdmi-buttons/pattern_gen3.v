`timescale 1ns/1ps
// 1280x720@60 (CEA-861, hsync/vsync АКТИВНЫЙ ВЫСОКИЙ), пиксель-клок ~74.25 МГц.
// Контент 4:3 (960x720) по центру, по бокам чёрные поля (pillarbox).
// Кнопки (active-low): btn0 режим, btn1 инверсия, btn2/btn3 скорость анимации -/+.
// led_heart — мигание от пиксель-клока (~1 Гц): жив ли клок.
module pattern_gen (
    input  wire        pclk,
    input  wire        btn0, btn1, btn2, btn3,
    output reg  [23:0] vid_data,
    output reg         vde,
    output reg         hsync,
    output reg         vsync,
    output wire        led_heart
);
    // 720p60: H 1280+110+40+220=1650; V 720+5+5+20=750
    localparam H_ACT=1280, H_TOT=1650, H_SS=1390, H_SE=1430;
    localparam V_ACT=720,  V_TOT=750,  V_SS=725,  V_SE=730;
    localparam WX0=160, WW=960;           // окно 4:3 по центру

    reg [10:0] hc = 11'd0;
    reg [9:0]  vc = 10'd0;
    wire frame_end = (hc == H_TOT-1) && (vc == V_TOT-1);
    always @(posedge pclk) begin
        if (hc == H_TOT-1) begin
            hc <= 11'd0;
            if (vc == V_TOT-1) vc <= 10'd0; else vc <= vc + 10'd1;
        end else hc <= hc + 11'd1;
    end

    wire hact = (hc < H_ACT);
    wire vact = (vc < V_ACT);
    wire hs   = (hc >= H_SS) && (hc < H_SE);   // активный высокий
    wire vs   = (vc >= V_SS) && (vc < V_SE);
    wire in_win = hact && vact && (hc >= WX0) && (hc < WX0+WW);
    wire [9:0] cx = hc[9:0] - WX0[9:0];        // 0..959 внутри окна

    // сердцебиение ~1 Гц от пиксель-клока
    reg [26:0] beat = 27'd0;
    always @(posedge pclk) beat <= beat + 27'd1;
    assign led_heart = beat[25];

    // ---- антидребезг + детектор нажатия ----
    reg [3:0] btn_sync0 = 4'hF, btn_sync1 = 4'hF, btn_state = 4'hF;
    reg [19:0] db_cnt [3:0];
    reg [3:0] btn_press = 4'h0;
    integer i;
    initial for (i=0;i<4;i=i+1) db_cnt[i] = 20'd0;
    always @(posedge pclk) begin
        btn_sync0 <= {btn3, btn2, btn1, btn0};
        btn_sync1 <= btn_sync0;
        btn_press <= 4'h0;
        for (i=0;i<4;i=i+1) begin
            if (btn_sync1[i] != btn_state[i]) begin
                db_cnt[i] <= db_cnt[i] + 20'd1;
                if (db_cnt[i] == 20'hFFFFF) begin   // ~14 мс @ 74 МГц
                    btn_state[i] <= btn_sync1[i];
                    if (btn_sync1[i] == 1'b0) btn_press[i] <= 1'b1;
                end
            end else db_cnt[i] <= 20'd0;
        end
    end

    // ---- состояние демо ----
    reg [1:0] mode = 2'd3;        // стартуем сразу с анимации (квадрат)
    reg       inv  = 1'b0;
    reg [2:0] speed = 3'd3;
    always @(posedge pclk) begin
        if (btn_press[0]) mode  <= mode + 2'd1;
        if (btn_press[1]) inv   <= ~inv;
        if (btn_press[2] && speed != 3'd1) speed <= speed - 3'd1;
        if (btn_press[3] && speed != 3'd7) speed <= speed + 3'd1;
    end

    // ---- скачущий квадрат (в координатах окна 960x720) ----
    localparam BOX = 10'd144;
    reg [9:0] bx = 10'd120, by = 10'd90;
    reg       dx = 1'b1,    dy = 1'b1;
    always @(posedge pclk) begin
        if (frame_end) begin
            if (dx) begin
                if (bx + BOX + {7'd0,speed} >= WW) dx <= 1'b0; else bx <= bx + {7'd0,speed};
            end else begin
                if (bx <= {7'd0,speed}) dx <= 1'b1; else bx <= bx - {7'd0,speed};
            end
            if (dy) begin
                if (by + BOX + {7'd0,speed} >= V_ACT) dy <= 1'b0; else by <= by + {7'd0,speed};
            end else begin
                if (by <= {7'd0,speed}) dy <= 1'b1; else by <= by - {7'd0,speed};
            end
        end
    end
    wire in_box = (cx >= bx) && (cx < bx + BOX) && (vc >= by) && (vc < by + BOX);
    reg [7:0] frame_cnt = 8'd0;
    always @(posedge pclk) if (frame_end) frame_cnt <= frame_cnt + 8'd1;

    // ---- картинки (внутри окна) ----
    wire [2:0] bar = (cx < 120) ? 3'd0 : (cx < 240) ? 3'd1 : (cx < 360) ? 3'd2 :
                     (cx < 480) ? 3'd3 : (cx < 600) ? 3'd4 : (cx < 720) ? 3'd5 :
                     (cx < 840) ? 3'd6 : 3'd7;
    reg [23:0] bar_color;
    always @(*) case (bar)
        3'd0: bar_color = 24'hFFFFFF;  3'd1: bar_color = 24'hFFFF00;
        3'd2: bar_color = 24'h00FFFF;  3'd3: bar_color = 24'h00FF00;
        3'd4: bar_color = 24'hFF00FF;  3'd5: bar_color = 24'hFF0000;
        3'd6: bar_color = 24'h0000FF;  default: bar_color = 24'h000000;
    endcase

    wire [23:0] grad_color  = {cx[7:0], vc[7:0], cx[8:1] ^ vc[8:1]};
    wire [23:0] check_color = (cx[5] ^ vc[5]) ? 24'hFFFFFF : 24'h202020;
    wire [23:0] box_color   = in_box ? {frame_cnt, ~frame_cnt, 8'hFF} : 24'h102838;

    reg [23:0] pix;
    always @(*) case (mode)
        2'd0: pix = bar_color;
        2'd1: pix = grad_color;
        2'd2: pix = check_color;
        default: pix = box_color;
    endcase

    always @(posedge pclk) begin
        vde      <= hact & vact;
        hsync    <= hs;
        vsync    <= vs;
        vid_data <= in_win ? (inv ? ~pix : pix) : 24'h000000;
    end
endmodule
