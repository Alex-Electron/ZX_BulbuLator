`timescale 1ns/1ps
// Step 3: the most primitive HDMI test — eight static vertical colour bars at
// 1280x720@60 (CEA-861, sync active HIGH), pixel clock 74.25 MHz.
// Module name and ports match the HDMI block design so it drops straight in.
// btn inputs are not used here.
module pattern_gen (
    input  wire        pclk,
    output reg  [23:0] vid_data,
    output reg         vde,
    output reg         hsync,
    output reg         vsync,
    output wire        led_heart
);
    // 720p60 timing: H 1280+110+40+220 = 1650; V 720+5+5+20 = 750.
    localparam H_ACT = 1280, H_TOT = 1650, H_SS = 1390, H_SE = 1430;
    localparam V_ACT = 720,  V_TOT = 750,  V_SS = 725,  V_SE = 730;

    reg [10:0] hc = 11'd0;
    reg [9:0]  vc = 10'd0;
    always @(posedge pclk) begin
        if (hc == H_TOT-1) begin
            hc <= 11'd0;
            if (vc == V_TOT-1) vc <= 10'd0; else vc <= vc + 10'd1;
        end else hc <= hc + 11'd1;
    end

    wire hact = (hc < H_ACT);
    wire vact = (vc < V_ACT);
    wire hs   = (hc >= H_SS) && (hc < H_SE);   // active high
    wire vs   = (vc >= V_SS) && (vc < V_SE);

    // Eight equal vertical bars (1280 / 8 = 160 px each), classic colour-bar order.
    wire [2:0] bar = (hc <  160) ? 3'd0 : (hc <  320) ? 3'd1 :
                     (hc <  480) ? 3'd2 : (hc <  640) ? 3'd3 :
                     (hc <  800) ? 3'd4 : (hc <  960) ? 3'd5 :
                     (hc < 1120) ? 3'd6 : 3'd7;
    reg [23:0] color;
    always @(*) case (bar)
        3'd0: color = 24'hFFFFFF;   // white
        3'd1: color = 24'hFFFF00;   // yellow
        3'd2: color = 24'h00FFFF;   // cyan
        3'd3: color = 24'h00FF00;   // green
        3'd4: color = 24'hFF00FF;   // magenta
        3'd5: color = 24'hFF0000;   // red
        3'd6: color = 24'h0000FF;   // blue
        default: color = 24'h000000; // black
    endcase

    always @(posedge pclk) begin
        vde      <= hact & vact;
        hsync    <= hs;
        vsync    <= vs;
        vid_data <= (hact && vact) ? color : 24'h000000;
    end

    // Heartbeat on the pixel clock (~1 Hz): proves the pixel clock is alive.
    reg [26:0] beat = 27'd0;
    always @(posedge pclk) beat <= beat + 27'd1;
    assign led_heart = beat[25];
endmodule
