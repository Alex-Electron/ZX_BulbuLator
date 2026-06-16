`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// framebuffer.v
//-------------------------------------------------------------------------------------------------
// Video framebuffer / scaler for the Atlas ZX Spectrum core.
//
//   * Write side runs in the Spectrum clock domain (~56.7 MHz master, one visible
//     pixel per wr_ce / pe7M0 tick, ~50 Hz frame).  It captures the core's ACTUAL
//     rendered RGBI output - active screen AND border - so border effects survive.
//   * Read side runs in the HDMI pixel-clock domain (74.25 MHz, 720p50).  It is fed
//     the raster position cx/cy from the hdl-util/hdmi core (frame 1980x750, active
//     area 1280x720) and must drive a 24-bit rgb word for that cx/cy.
//
// The two domains share a dual-clock (asynchronous) dual-port Block RAM.  The BRAM
// is the clock-domain crossing for the pixel data; that is intentional and safe for
// a streaming framebuffer.  Single buffer, so tearing is possible - acceptable here.
//
// Storage: 360 (wide) x 288 (high) x 4 bits/pixel (RGBI) = 414720 bits ~= 51.8 KB.
//          Infers Xilinx 7-series simple-dual-port Block RAM (no vendor primitives).
//
// Sync polarity detected from the core (src/video.v):
//      hsync = (hCount >= 344 && hCount < 376)  -> ACTIVE HIGH
//      vsync = (vCount >= 248 && vCount < 252)  -> ACTIVE HIGH
// Even so, the edge detection below is polarity-agnostic: we measure, per frame,
// whether sync spends more time high or low and pick the "pulse" sense accordingly,
// then trigger the line/frame reset on the LEADING edge of that pulse.
//-------------------------------------------------------------------------------------------------
module framebuffer
(
    // ---- write side : Spectrum domain ----
    input  wire        wr_clk,   // Spectrum master clock (~56.7 MHz)
    input  wire        wr_ce,    // pixel enable (pe7M0): one Spectrum pixel per tick
    input  wire        hsync,
    input  wire        vsync,
    input  wire        blank,    // 1 = outside visible area (h/v blanking)
    input  wire        r,
    input  wire        g,
    input  wire        b,
    input  wire        i,        // RGBI, 1 bit each

    // ---- read side : HDMI domain ----
    input  wire        rd_clk,   // HDMI pixel clock (74.25 MHz)
    input  wire [10:0] cx,       // hdl-util/hdmi raster X (active 0..1279 within 0..1979)
    input  wire [10:0] cy,       // hdl-util/hdmi raster Y (active 0..719  within 0..749)
    output reg  [23:0] rgb       // 24-bit colour for the current cx/cy
);
    //---------------------------------------------------------------------------------------------
    // Framebuffer geometry
    //---------------------------------------------------------------------------------------------
    localparam FB_W   = 360;          // pixels per stored line
    localparam FB_H   = 288;          // stored lines
    localparam AW     = 17;           // address width: 360*288 = 103680 < 2^17
    localparam DEPTH  = FB_W * FB_H;  // 103680 words of 4 bits

    //=============================================================================================
    // WRITE SIDE  (wr_clk / wr_ce, Spectrum domain)
    //=============================================================================================

    //---------------------------------------------------------------------------------------------
    // Polarity-robust sync edge detection.
    //
    // We do not assume hsync/vsync are active-high.  Each frame we count how many
    // wr_ce ticks hsync was high vs low; the rarer level is the "pulse".  The same
    // is done for vsync over whole lines.  The reset events fire on the LEADING edge
    // of the detected pulse (line start <- hsync pulse, frame start <- vsync pulse).
    // For the Atlas core both syncs are active high, so the pulse is the high level
    // and these reduce to ordinary rising-edge detection - but this keeps working if
    // a future core / polarity option inverts them.
    //---------------------------------------------------------------------------------------------
    reg        hs_d, vs_d;            // delayed sync for edge detect
    reg        hs_pulse_hi;           // 1 => hsync pulse is the HIGH level
    reg        vs_pulse_hi;           // 1 => vsync pulse is the HIGH level

    // Effective "in pulse" signals after applying detected polarity.
    wire hs_in   =  hs_pulse_hi ?  hsync :  ~hsync;
    wire hs_in_d =  hs_pulse_hi ?  hs_d  :  ~hs_d;
    wire vs_in   =  vs_pulse_hi ?  vsync :  ~vsync;
    wire vs_in_d =  vs_pulse_hi ?  vs_d  :  ~vs_d;

    wire hs_lead = hs_in & ~hs_in_d;  // leading edge of hsync pulse  -> new line
    wire vs_lead = vs_in & ~vs_in_d;  // leading edge of vsync pulse  -> new frame

    // Per-frame level accounting to learn the polarity. Counters are wide enough for
    // a full frame of pe7M0 ticks (~448*312 = ~139776).
    reg [17:0] hs_hi_cnt, hs_lo_cnt;
    reg [17:0] vs_hi_cnt, vs_lo_cnt;

    always @(posedge wr_clk) if (wr_ce) begin
        hs_d <= hsync;
        vs_d <= vsync;

        // Accumulate how long each sync sits high vs low this frame.
        if (hsync) hs_hi_cnt <= hs_hi_cnt + 1'b1; else hs_lo_cnt <= hs_lo_cnt + 1'b1;
        if (vsync) vs_hi_cnt <= vs_hi_cnt + 1'b1; else vs_lo_cnt <= vs_lo_cnt + 1'b1;

        // At the start of each new frame, decide polarity from the previous frame's
        // tallies (the pulse is the LESS common level), then clear for the next frame.
        if (vs_lead) begin
            hs_pulse_hi <= (hs_hi_cnt <  hs_lo_cnt);
            vs_pulse_hi <= (vs_hi_cnt <  vs_lo_cnt);
            hs_hi_cnt <= 18'd0; hs_lo_cnt <= 18'd0;
            vs_hi_cnt <= 18'd0; vs_lo_cnt <= 18'd0;
        end
    end

    // Sensible power-on defaults (Atlas core is active-high on both).
    initial begin
        hs_pulse_hi = 1'b1;
        vs_pulse_hi = 1'b1;
        hs_hi_cnt = 0; hs_lo_cnt = 0;
        vs_hi_cnt = 0; vs_lo_cnt = 0;
    end

    //---------------------------------------------------------------------------------------------
    // Source pixel coordinate (sx, sy).
    //
    // sx counts visible wr_ce pixels since the start of the current line, sy counts
    // lines since the start of the frame.  hsync's leading edge happens during the
    // horizontal blank AFTER the visible part of a line, so by counting from there we
    // begin sx at 0 at (or just before) the next line's first visible pixel.  Both
    // counters are clamped to the framebuffer extents so out-of-window pixels (extra
    // border / overscan) are simply dropped instead of wrapping.
    //
    // We capture every non-blank pixel.  The blank region is skipped, so sx advances
    // only over the visible 352-wide strip and sy over the visible 304 lines; the
    // 360x288 window comfortably holds the 256x192 screen plus its border.
    //---------------------------------------------------------------------------------------------
    reg [8:0] sx;                     // 0..359
    reg [8:0] sy;                     // 0..287
    reg       sx_max_pending;         // 1 once sx has hit the right edge this line
    reg       sy_over;                // 1 once sy has run past the bottom of the FB

    wire sx_max = (sx >= FB_W-1);
    wire sy_max = (sy >= FB_H-1);

    // wr_en: store this pixel.  Visible (not blanking) and inside the FB window.
    wire wr_en = wr_ce & ~blank & ~sx_max_pending & ~sy_over;

    always @(posedge wr_clk) if (wr_ce) begin
        if (vs_lead) begin
            // New frame: rewind to top-left.
            sy             <= 9'd0;
            sx             <= 9'd0;
            sx_max_pending <= 1'b0;
            sy_over        <= 1'b0;
        end else if (hs_lead) begin
            // New line: rewind X, advance Y (clamped at the bottom).
            sx             <= 9'd0;
            sx_max_pending <= 1'b0;
            if (sy_max) sy_over <= 1'b1;
            else        sy      <= sy + 1'b1;
        end else if (~blank) begin
            // Visible pixel: advance X until the right edge of the window.
            if (sx_max) sx_max_pending <= 1'b1;
            else        sx             <= sx + 1'b1;
        end
    end

    //---------------------------------------------------------------------------------------------
    // Linear write address and 4-bit RGBI write data.
    //---------------------------------------------------------------------------------------------
    wire [AW-1:0] wr_addr = sy * FB_W + sx;     // multiplier inferred; constant FB_W
    wire [3:0]    wr_data = { i, r, g, b };     // RGBI packed (I msb)

    //=============================================================================================
    // READ SIDE  (rd_clk, HDMI 720p50 domain)
    //=============================================================================================

    //---------------------------------------------------------------------------------------------
    // cx/cy -> sx/sy mapping with integer scaling and a centred pillarbox.
    //
    //   * Vertical:  FB_H(288) x2 = 576 active lines, centred in 720.
    //                top/bottom (letterbox) margin = (720-576)/2 = 72.
    //                picture rows  : cy in [72, 648)
    //   * Horizontal: FB_W(360) x2 = 720 active columns, centred in 1280.
    //                left/right (pillarbox) margin = (1280-720)/2 = 280.
    //                picture cols  : cx in [280, 1000)
    //
    //   sx = (cx - 280) >> 1 ,  sy = (cy - 72) >> 1
    //
    // The native window is 360x288 (5:4); displayed at 720x576 it keeps that 5:4
    // shape inside the 16:9 panel with black bars all round (no horizontal stretch),
    // which is the standard "4:3-style pillarbox" look for a Spectrum image.
    //---------------------------------------------------------------------------------------------
    localparam HMARGIN = 280;         // (1280 - 720) / 2
    localparam VMARGIN = 72;          //  (720 - 576) / 2
    localparam HPIC    = 720;         // FB_W * 2
    localparam VPIC    = 576;         // FB_H * 2

    // Inside the active picture rectangle (and therefore inside the 1280x720 active
    // area, since the picture is fully contained within it)?
    wire in_pic = (cx >= HMARGIN) && (cx < HMARGIN + HPIC) &&
                  (cy >= VMARGIN) && (cy < VMARGIN + VPIC);

    wire [8:0] rd_sx = (cx - HMARGIN) >> 1;     // 0..359
    wire [8:0] rd_sy = (cy - VMARGIN) >> 1;     // 0..287

    wire [AW-1:0] rd_addr = rd_sy * FB_W + rd_sx;

    //=============================================================================================
    // DUAL-CLOCK SIMPLE-DUAL-PORT BLOCK RAM
    //  - write port  : wr_clk
    //  - read port   : rd_clk  (registered output -> one rd_clk of latency)
    //  This template infers RAMB18/RAMB36 in Vivado 2023.1 for xc7z010clg400-1.
    //=============================================================================================
    (* ram_style = "block" *)
    reg [3:0] mem [0:DEPTH-1];

    reg [3:0] rd_q;                   // registered BRAM read data
    reg       in_pic_q;               // pipeline in_pic alongside the read latency

    always @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_q     <= mem[rd_addr];
        in_pic_q <= in_pic;
    end

    //---------------------------------------------------------------------------------------------
    // RGBI -> RGB888 using the standard ZX Spectrum palette.
    //   bit = 0          -> 0x00
    //   bit = 1, I = 0   -> 0xD7  (normal)
    //   bit = 1, I = 1   -> 0xFF  (bright)
    // Black stays 0x000000 in both intensities.  Each of R/G/B is independent.
    //---------------------------------------------------------------------------------------------
    wire        bri = rd_q[3];        // I
    wire        rr  = rd_q[2];        // R
    wire        gg  = rd_q[1];        // G
    wire        bb  = rd_q[0];        // B
    wire [7:0]  lvl = bri ? 8'hFF : 8'hD7;

    wire [7:0]  pr  = rr ? lvl : 8'h00;
    wire [7:0]  pg  = gg ? lvl : 8'h00;
    wire [7:0]  pb  = bb ? lvl : 8'h00;

    // Outside the active picture (pillarbox / letterbox / outside 1280x720) -> black.
    always @(posedge rd_clk) begin
        rgb <= in_pic_q ? { pr, pg, pb } : 24'h000000;
    end

endmodule
//-------------------------------------------------------------------------------------------------
