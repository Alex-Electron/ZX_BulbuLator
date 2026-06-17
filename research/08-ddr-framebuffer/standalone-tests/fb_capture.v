`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_capture.v  -  capture the ULA RGBI raster (spclk) into 64-bit words for the DDR writer.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Spectrum clock domain. On every visible pixel (pe7M0 & ~blank) it packs {i,r,g,b} into a 64-bit
// word (16 px, low nibble = first pixel - matches fb_loader/fb_display). A completed word is pushed
// into the async FIFO (-> fclk100 AXI writer). The 16-pixel packer resets on the vsync leading edge
// so each frame starts word-aligned. For a clean 360x288 source this yields exactly 6480 words/frame.
//
// NOTE (Phase 2a): the synthetic raster is exactly 360x288, so straight packing of every visible
// pixel is correct. The real core (Phase 2b) has an arbitrary visible width -> it will need a
// re-raster line buffer (pad/clamp to a fixed width) feeding this same packer.
//-------------------------------------------------------------------------------------------------
module fb_capture (
    input  wire        spclk,
    input  wire        resetn,
    input  wire        pe7M0,
    input  wire        r,
    input  wire        g,
    input  wire        b,
    input  wire        i,
    input  wire        blank,
    input  wire        vsync,
    input  wire        enable,        // 1 = HP write path is up (gate startup -> no FIFO overflow)

    // async FIFO write side (spclk)
    output reg         fifo_wr,
    output reg  [63:0] fifo_din
);
    reg [3:0]  pixk;
    reg [63:0] acc;
    reg        vsync_d;
    reg        started;               // only push whole, frame-aligned frames once enabled
    wire       vs_lead = vsync & ~vsync_d;
    wire [3:0] nib = {i, r, g, b};

    always @(posedge spclk) begin
        if (!resetn) begin
            pixk<=4'd0; acc<=64'd0; vsync_d<=1'b0; fifo_wr<=1'b0; fifo_din<=64'd0; started<=1'b0;
        end else begin
            fifo_wr <= 1'b0;
            vsync_d <= vsync;
            if (!enable) started <= 1'b0;
            if (vs_lead) begin
                pixk    <= 4'd0;                    // new frame: re-align the packer
                started <= enable;                  // begin (or keep going) only on a frame boundary
            end else if (pe7M0 && !blank && started) begin
                acc[{pixk,2'b00} +: 4] <= nib;      // pack this pixel
                if (pixk == 4'd15) begin
                    fifo_din <= {nib, acc[59:0]};   // complete word (incl. this 16th pixel)
                    fifo_wr  <= 1'b1;
                    pixk     <= 4'd0;
                end else pixk <= pixk + 4'd1;
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
