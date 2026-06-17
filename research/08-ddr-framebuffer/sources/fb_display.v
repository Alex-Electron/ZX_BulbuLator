`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_display.v  -  DDR-loaded display framebuffer + 720p50 pillarbox upscaler (read side).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// One ZX source frame (360x288 x 4-bit RGBI = the active screen AND the ZX border) lives here,
// packed 16 pixels per 64-bit word -> 6480 words. The WRITE port is driven by fb_loader, one
// 64-bit word per AXI-HP beat (whole frame ~65 us -> fits HDMI vblank). The READ port is the
// proven pillarbox upscaler from framebuffer.v: cx/cy -> source pixel -> ZX palette -> rgb24.
//
// This is the single CLOCK-DOMAIN CROSSING: the BRAM itself crosses wr_clk (loader = fclk100)
// to rd_clk (HDMI clk_pixel), exactly as the original BRAM framebuffer crossed spclk->clk_pixel.
// The whole frame is swapped atomically in DDR by fb_loader, so the scanout always reads a
// complete, stable frame -> no tearing anywhere in the image (screen or ZX border).
//-------------------------------------------------------------------------------------------------
module fb_display (
    // ---- write side : loader domain (fclk100) ----
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [12:0] wr_addr,    // 0..6479 (64-bit word index)
    input  wire [63:0] wr_data,    // 16 packed RGBI pixels

    // ---- read side : HDMI 720p50 domain (clk_pixel) ----
    input  wire        rd_clk,
    input  wire [10:0] cx,         // hdl-util raster X (active 0..1279 within 0..1979)
    input  wire [10:0] cy,         // hdl-util raster Y (active 0..719  within 0..749)
    output reg  [23:0] rgb
);
    localparam FB_W = 360, FB_H = 288;          // SOURCE STRIDE - unchanged (6480-word frame contract)
    // Crop tuned to hardware feedback: with SY0=39 + left edge anchored, the user confirmed TOP and
    // LEFT are PERFECT; BOTTOM and RIGHT were over-cut. So keep top/left, EXTEND bottom (to the full
    // src row 287) and right (cut only a thin black strip, src cols 356..359). The border region is
    // real content (ula128 stripes / demo border FX) -> do not over-crop it. HMARGIN/VMARGIN are FIXED
    // (not re-centred) so the perfect top-left edge stays put; the window just grows down + right.
    localparam SX0     = 0,   SY0 = 31;         // capture shifted +8 (vblank reclaimed): top stays, bottom +8
    localparam CROP_W  = 356, CROP_H = 257;     // src cols 0..355 x rows 31..287 (full bottom border)
    localparam HPIC    = CROP_W << 1;           // 712
    localparam VPIC    = CROP_H << 1;           // 514
    localparam HMARGIN = 320;                   // FIXED - anchors the perfect LEFT edge
    localparam VMARGIN = 120;                   // FIXED - anchors the perfect TOP edge

    wire in_pic = (cx >= HMARGIN) && (cx < HMARGIN + HPIC) &&
                  (cy >= VMARGIN) && (cy < VMARGIN + VPIC);

    wire [8:0]  rd_sx = SX0 + ((cx - HMARGIN) >> 1);   // 0..319
    wire [8:0]  rd_sy = SY0 + ((cy - VMARGIN) >> 1);   // 31..287
    wire [16:0] lin   = rd_sy * FB_W + rd_sx;       // linear pixel 0..103679
    wire [12:0] rd_word = lin[16:4];                // /16  -> 64-bit word
    wire [3:0]  rd_nib  = lin[3:0];                 // %16  -> which 4-bit pixel

    //---------------------------------------------------------------------------------------------
    // Dual-clock simple-dual-port Block RAM (write fclk100 / read clk_pixel).
    //---------------------------------------------------------------------------------------------
    (* ram_style = "block" *) reg [63:0] mem [0:6479];

    reg [63:0] rd_q;
    reg [3:0]  rd_nib_q;
    reg        in_pic_q;

    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;

    always @(posedge rd_clk) begin
        rd_q     <= mem[rd_word];
        rd_nib_q <= rd_nib;
        in_pic_q <= in_pic;
    end

    // Select the 4-bit RGBI pixel for this position out of the 64-bit word.
    wire [5:0] sel = {rd_nib_q, 2'b00};             // nibble * 4
    wire [3:0] px  = rd_q[sel +: 4];

    // RGBI -> RGB888, standard ZX palette (0x00 / 0xD7 normal / 0xFF bright).
    wire       bri = px[3];                         // I
    wire       rr  = px[2];                         // R
    wire       gg  = px[1];                         // G
    wire       bb  = px[0];                         // B
    wire [7:0] lvl = bri ? 8'hFF : 8'hD7;

    always @(posedge rd_clk) begin
        rgb <= in_pic_q ? { rr ? lvl : 8'h00, gg ? lvl : 8'h00, bb ? lvl : 8'h00 }
                        : 24'h505050;               // pillarbox / letterbox = dark grey (permanent frame, user pref)
    end
endmodule
//-------------------------------------------------------------------------------------------------
