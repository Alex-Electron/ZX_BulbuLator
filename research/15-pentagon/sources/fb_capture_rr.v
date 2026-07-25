`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_capture_rr.v  -  RE-RASTER capture: force every line to exactly 360 pixels so each frame is
// exactly 6480 words (= what the DDR loader/display expect). Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Streaming to DDR needs EXACTLY 6480 words/frame in raster order. The real core's vblank lines
// (vCount 248..255) carry 0 non-blank pixels, so a straight packer pushes ~6300 words/frame and the
// image SCROLLS. Fix: a ping-pong line buffer. The write side (framebuffer.v sx/sy logic) fills the
// current line buffer with the line's non-blank pixels; the stream side then emits EXACTLY 360
// pixels for that line (the captured ones, padded with black to 360), packed 16/word into the FIFO.
// 288 lines x 360 = 6480 words/frame, geometry identical to the proven framebuffer.v. Line buffers
// are distributed RAM (no BRAM). Stream of 360 @ spclk (~6.3 us) << one line (~65 us) -> ping-pong
// never collides. The packer runs continuously across lines (360 not a multiple of 16); after 288
// lines it has emitted exactly 6480 words with pixk back at 0.
//-------------------------------------------------------------------------------------------------
// STEP-15 LOCAL COPY (Step 11's own file stays exactly as published; assemble.sh copies THIS one).
// Delta: MACHINE-AGNOSTIC AUTO-WINDOW capture (the MiSTer-ascal idea, sized to our fabric):
//   1. The capture window start is DERIVED from the MEASURED frame length (the geometry probe
//      counts lines between vsyncs anyway): skip = frame_lines - 303, clamped to 0..31. That yields
//      the proven vsync+8 on the 311-line 128K, vsync+9 on the 48K, vsync+17 on the 320-line
//      Pentagon, and 0 on short rasters (e.g. a future NES's 262) - no per-machine constants.
//   2. Every frame is CLOSED to exactly FB_H lines at vsync: if the core delivered fewer (short
//      raster, a mid-frame model switch, a glitching guest), the stream side PADS the remainder
//      with black lines. The DDR writer counts a fixed 6795 words/frame and has no vsync of its
//      own, so whole-frames-always is what makes it impossible for ANY guest behaviour to leave
//      the picture scrolled or phase-shifted. The OSD/display side never notices any of this.
module fb_capture_rr #(
    parameter integer FB_W = 384,      // ZX default (Pentagon 384-wide). NES instance overrides -> 256.
    parameter integer FB_H = 302       // ZX default. NES -> 240.
)(
    input  wire        wr_clk,        // spclk
    input  wire        resetn,
    input  wire        wr_ce,         // pe7M0
    input  wire        hsync, vsync, blank,
    input  wire        r, g, b, i,
    input  wire        enable,        // HP write path up

    output reg         fifo_wr,
    output reg  [63:0] fifo_din,
    // ---- frame-geometry probe (spclk domain; 2-FF synced to aclk in the top, read via AXI 0x64) ----
    // {2'b0, frame_lines[9:0], vis_last[9:0], vis_first[9:0]} latched per frame at vsync.
    output reg  [31:0] cap_geom
);
    // FB_W/FB_H are now module parameters (ZX default 384/302; NES instance passes 256/240). 384 for
    // Pentagon wider border (64 left + 256 paper + 64 right). Top vblank lines (vc 6-7) NOT captured:
    // they fall in the VSYNC region -> re-raster grabs garbage. Clean: rainbow from first visible.

    //---- polarity-robust sync edge detect (framebuffer.v) ----
    reg  hs_d, vs_d, hs_pulse_hi=1'b1, vs_pulse_hi=1'b1;
    wire hs_in   = hs_pulse_hi ?  hsync :  ~hsync;
    wire hs_in_d = hs_pulse_hi ?  hs_d  :  ~hs_d;
    wire vs_in   = vs_pulse_hi ?  vsync :  ~vsync;
    wire vs_in_d = vs_pulse_hi ?  vs_d  :  ~vs_d;
    wire hs_lead = hs_in & ~hs_in_d;
    wire vs_lead = vs_in & ~vs_in_d;
    reg [17:0] hs_hi_cnt, hs_lo_cnt, vs_hi_cnt, vs_lo_cnt;
    always @(posedge wr_clk) if (wr_ce) begin
        hs_d<=hsync; vs_d<=vsync;
        if (hsync) hs_hi_cnt<=hs_hi_cnt+1'b1; else hs_lo_cnt<=hs_lo_cnt+1'b1;
        if (vsync) vs_hi_cnt<=vs_hi_cnt+1'b1; else vs_lo_cnt<=vs_lo_cnt+1'b1;
        if (vs_lead) begin
            hs_pulse_hi<=(hs_hi_cnt<hs_lo_cnt); vs_pulse_hi<=(vs_hi_cnt<vs_lo_cnt);
            hs_hi_cnt<=0; hs_lo_cnt<=0; vs_hi_cnt<=0; vs_lo_cnt<=0;
        end
    end

    //---- frame-geometry probe: per frame, count total lines + first/last VISIBLE (blank=0) line ----
    reg [9:0] g_lcnt = 10'd0, g_first = 10'h3FF, g_last = 10'd0;
    reg       g_linevis = 1'b0, g_seen = 1'b0;
    initial cap_geom = 32'd0;
    always @(posedge wr_clk) if (wr_ce) begin
        if (vs_lead) begin
            cap_geom  <= {2'b00, g_lcnt, g_last, g_first};   // latch the just-finished frame
            flen      <= g_lcnt;                             // feed the auto-window (skip_v) above
            g_lcnt    <= 10'd0; g_first <= 10'h3FF; g_last <= 10'd0;
            g_linevis <= 1'b0;  g_seen  <= 1'b0;
        end else if (hs_lead) begin
            if (g_linevis) begin
                if (!g_seen) begin g_first <= g_lcnt; g_seen <= 1'b1; end
                g_last <= g_lcnt;
            end
            g_lcnt    <= g_lcnt + 10'd1;
            g_linevis <= 1'b0;
        end else if (~blank) begin
            g_linevis <= 1'b1;
        end
    end

    //---- write side: capture the line's non-blank pixels into the current line buffer ----
    reg [8:0]  sx, sy;
    reg        sx_max_pending, sy_over;
    reg        wr_lb;                 // line buffer being written
    reg        started_w;             // gate (HP up + frame-aligned)
    reg        trig;                  // pulse: a completed line is ready to stream
    reg        rd_lb;                 // line buffer to stream
    reg [8:0]  ll;                    // captured pixel count of that line
    // AUTO capture-window start, derived from the MEASURED frame length (previous frame's line count
    // from the geometry probe): skip = frame_lines - 303 -> always leaves 303 lines = 302 captured +
    // 1 spare before the next vsync, for ANY raster. 311 (128K) -> 8 (the proven value); 312 (48K) ->
    // 9; 320 (Pentagon) -> 17; <=303 (short rasters) -> 0 (+ the pad engine fills the budget below).
    reg  [9:0] flen = 10'd311;        // measured lines/frame (updated at each vsync; init = 128K)
    wire [9:0] flen_m303 = flen - 10'd303;
    wire [4:0] skip_v = (flen <= 10'd303) ? 5'd0 : (flen >= 10'd334) ? 5'd31 : flen_m303[4:0];
    reg [4:0]  skip_cnt;              // counts skip_v lines after vsync before capture begins
    reg        armed;                 // skipping the vblank, not yet capturing

    wire sx_max = (sx >= FB_W-1);
    wire sy_max = (sy >= FB_H-1);
    wire wr_en  = wr_ce & ~blank & ~sx_max_pending & ~sy_over & started_w;
    wire [3:0] nib = {i, r, g, b};

    // ---- frame-close FLUSH: the DDR writer counts a FIXED 6795 words (302 lines) per frame and has
    // no vsync of its own, so a short capture frame would leave it phase-shifted FOREVER (the
    // "picture wrapped down" symptom). At every vsync, if the frame came up short (raster change,
    // short-raster core, glitching guest), the stream side PADS it to exactly 302 lines with black.
    // The writer always sees whole frames; nothing downstream ever resets. ----
    reg       flush_go  = 1'b0;       // 1-cycle: control -> stream "pad the rest of the frame"
    reg [8:0] flush_set = 9'd0;       // lines still owed to the writer (FB_H - sy)
    reg       flushing  = 1'b0;       // stream side is padding (set/cleared in the stream block)
    reg [8:0] flush_left= 9'd0;

    (* ram_style="distributed" *) reg [3:0] lb [0:1][0:FB_W-1];   // two 360-pixel line buffers
    always @(posedge wr_clk) if (wr_en) lb[wr_lb][sx] <= nib;

    always @(posedge wr_clk) begin
        if (!resetn) begin
            sx<=0; sy<=0; sx_max_pending<=0; sy_over<=0; wr_lb<=1'b0;
            trig<=1'b0; rd_lb<=1'b0; ll<=0; started_w<=1'b0;
            skip_cnt<=0; armed<=1'b0;
        end else begin
            trig <= 1'b0;
            flush_go <= 1'b0;
            if (!enable) started_w <= 1'b0;
            if (wr_ce) begin
                if (vs_lead) begin
                    if (started_w && !sy_over) begin        // SHORT frame (raster change / short-raster core /
                        flush_go  <= 1'b1;                  // glitching guest): owe the writer the rest of the
                        flush_set <= FB_H[8:0] - sy;        // 302-line budget -> the stream side pads it black
                    end
                    sx<=0; sx_max_pending<=0; sy_over<=0;
                    skip_cnt <= skip_v; armed <= 1'b1;      // auto lead-in (from the measured frame length)
                    started_w <= 1'b0;
                end else if (hs_lead) begin
                    if (armed) begin
                        if (skip_cnt == 5'd0) begin          // lead-in dropped -> begin capture at line 0
                            armed <= 1'b0; started_w <= enable & ~flushing;   // never start while still padding
                            sy<=0; sx<=0; sx_max_pending<=0; sy_over<=0;
                        end else skip_cnt <= skip_cnt - 5'd1;
                    end else begin
                        if (started_w && !sy_over) begin     // a captured line just ended -> stream it
                            ll<=sx; rd_lb<=wr_lb; wr_lb<=~wr_lb; trig<=1'b1;
                        end
                        sx<=0; sx_max_pending<=0;
                        if (sy_max) sy_over<=1'b1; else sy<=sy+1'b1;
                    end
                end else if (~blank && started_w) begin
                    if (sx_max) sx_max_pending<=1'b1; else sx<=sx+1'b1;
                end
            end
        end
    end

    //---- stream side: emit EXACTLY 360 pixels (captured + black pad), pack 16/word -> FIFO ----
    reg        busy;
    reg [8:0]  sxs, ll_q;
    reg        lb_q;
    reg [3:0]  pixk;
    reg [63:0] acc;
    wire [3:0] spix = (sxs < ll_q) ? lb[lb_q][sxs] : 4'h0;   // captured pixel, else black pad

    reg pad_line;                                            // current streamed line is a flush pad (black)
    always @(posedge wr_clk) begin
        if (!resetn) begin
            busy<=1'b0; sxs<=0; pixk<=0; acc<=0; fifo_wr<=1'b0; ll_q<=0; lb_q<=0; fifo_din<=0;
            flushing<=1'b0; flush_left<=9'd0; pad_line<=1'b0;
        end else begin
            fifo_wr <= 1'b0;
            if (flush_go) begin flushing<=1'b1; flush_left<=flush_set; end   // control block owes lines
            if (!busy) begin
                if (trig) begin busy<=1'b1; sxs<=0; ll_q<=ll; lb_q<=rd_lb; pad_line<=1'b0; end
                else if (flushing && flush_left!=9'd0) begin                 // self-triggered black pad line
                    busy<=1'b1; sxs<=0; ll_q<=9'd0; lb_q<=rd_lb; pad_line<=1'b1;
                end else if (flushing) flushing<=1'b0;                        // owed lines done
            end else begin
                acc[{pixk,2'b00} +: 4] <= spix;
                if (pixk==4'd15) begin
                    fifo_din <= {spix, acc[59:0]};
                    fifo_wr  <= 1'b1;
                    pixk     <= 4'd0;
                end else pixk <= pixk + 4'd1;
                if (sxs==FB_W-1) begin
                    busy<=1'b0;
                    if (pad_line) flush_left <= flush_left - 9'd1;
                end else sxs<=sxs+9'd1;
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
