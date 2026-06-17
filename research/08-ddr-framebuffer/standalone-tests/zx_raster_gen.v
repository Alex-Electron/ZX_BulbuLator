`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// zx_raster_gen.v  -  synthetic "ULA" raster for Phase-2a (stands in for the real video.v).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Runs in the Spectrum clock domain (spclk + pe7M0 enable, exactly like the real core). Produces a
// CLEAN 360x288 visible window inside a 448x312 frame, with active-high hsync/vsync/blank in the
// same convention framebuffer.v expects, and an animated RGBI pattern (8 colour bars scrolling
// horizontally, position = per-frame phase). ~50.6 Hz frame -> async to HDMI 50.000, the realistic
// beat. Lets Phase-2a validate the spclk->fclk100 capture/CDC/AXI-write/triple-buffer path with a
// live second-clock-domain video source before the dense real-core integration (Phase 2b).
//-------------------------------------------------------------------------------------------------
module zx_raster_gen (
    input  wire       spclk,
    input  wire       resetn,
    input  wire       pe7M0,        // one visible pixel per pulse
    output reg        r,
    output reg        g,
    output reg        b,
    output reg        i,
    output reg        hsync,        // active-high
    output reg        vsync,        // active-high
    output reg        blank         // 1 = outside the 360x288 visible window
);
    localparam HVIS=360, VVIS=288, HTOT=448, VTOT=312;
    reg [8:0] hc;     // 0..447
    reg [8:0] vc;     // 0..311
    reg [9:0] phase;  // 0..359 (bar scroll)

    // 8 classic colour bars (bright): white,yellow,cyan,green,magenta,red,blue,black
    function [3:0] bar(input [8:0] x);   // x in 0..359
        case (x / 9'd45)
            3'd0: bar=4'hF; 3'd1: bar=4'hE; 3'd2: bar=4'hB; 3'd3: bar=4'hA;
            3'd4: bar=4'hD; 3'd5: bar=4'hC; 3'd6: bar=4'h9; default: bar=4'h0;
        endcase
    endfunction

    wire        visible = (hc < HVIS) && (vc < VVIS);
    wire [9:0]  xs  = {1'b0, hc} + phase;                 // 0..718
    wire [8:0]  xsw = (xs >= 10'd360) ? (xs - 10'd360) : xs[8:0];
    wire [3:0]  nib = visible ? bar(xsw) : 4'h0;

    always @(posedge spclk) begin
        if (!resetn) begin
            hc<=9'd0; vc<=9'd0; phase<=10'd0;
            r<=0; g<=0; b<=0; i<=0; hsync<=0; vsync<=0; blank<=1;
        end else if (pe7M0) begin
            // raster counters
            if (hc == HTOT-1) begin
                hc <= 9'd0;
                if (vc == VTOT-1) begin
                    vc    <= 9'd0;
                    phase <= (phase >= 10'd358) ? 10'd0 : phase + 10'd2;   // scroll per frame
                end else vc <= vc + 9'd1;
            end else hc <= hc + 9'd1;

            // outputs (registered, so they line up with pe7M0 like the real core)
            blank <= ~visible;
            i <= nib[3]; r <= nib[2]; g <= nib[1]; b <= nib[0];
            hsync <= (hc >= 9'd380) && (hc < 9'd412);
            vsync <= (vc >= 9'd295) && (vc < 9'd298);
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
