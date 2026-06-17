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
module fb_capture_rr (
    input  wire        wr_clk,        // spclk
    input  wire        resetn,
    input  wire        wr_ce,         // pe7M0
    input  wire        hsync, vsync, blank,
    input  wire        r, g, b, i,
    input  wire        enable,        // HP write path up

    output reg         fifo_wr,
    output reg  [63:0] fifo_din
);
    localparam FB_W = 360, FB_H = 288;

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

    //---- write side: capture the line's non-blank pixels into the current line buffer ----
    reg [8:0]  sx, sy;
    reg        sx_max_pending, sy_over;
    reg        wr_lb;                 // line buffer being written
    reg        started_w;             // gate (HP up + frame-aligned)
    reg        trig;                  // pulse: a completed line is ready to stream
    reg        rd_lb;                 // line buffer to stream
    reg [8:0]  ll;                    // captured pixel count of that line
    localparam SKIP = 8;              // dead vblank lines to drop after vsync -> reclaimed for the bottom border
    reg [3:0]  skip_cnt;              // counts SKIP lines after vsync before capture begins
    reg        armed;                 // skipping the vblank, not yet capturing

    wire sx_max = (sx >= FB_W-1);
    wire sy_max = (sy >= FB_H-1);
    wire wr_en  = wr_ce & ~blank & ~sx_max_pending & ~sy_over & started_w;
    wire [3:0] nib = {i, r, g, b};

    (* ram_style="distributed" *) reg [3:0] lb [0:1][0:FB_W-1];   // two 360-pixel line buffers
    always @(posedge wr_clk) if (wr_en) lb[wr_lb][sx] <= nib;

    always @(posedge wr_clk) begin
        if (!resetn) begin
            sx<=0; sy<=0; sx_max_pending<=0; sy_over<=0; wr_lb<=1'b0;
            trig<=1'b0; rd_lb<=1'b0; ll<=0; started_w<=1'b0;
            skip_cnt<=0; armed<=1'b0;
        end else begin
            trig <= 1'b0;
            if (!enable) started_w <= 1'b0;
            if (wr_ce) begin
                if (vs_lead) begin
                    sx<=0; sx_max_pending<=0; sy_over<=0;
                    skip_cnt <= SKIP; armed <= 1'b1;        // drop SKIP dead vblank lines first
                    started_w <= 1'b0;
                end else if (hs_lead) begin
                    if (armed) begin
                        if (skip_cnt == 4'd0) begin          // vblank dropped -> begin capture at line 0
                            armed <= 1'b0; started_w <= enable;
                            sy<=0; sx<=0; sx_max_pending<=0; sy_over<=0;
                        end else skip_cnt <= skip_cnt - 4'd1;
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

    always @(posedge wr_clk) begin
        if (!resetn) begin
            busy<=1'b0; sxs<=0; pixk<=0; acc<=0; fifo_wr<=1'b0; ll_q<=0; lb_q<=0; fifo_din<=0;
        end else begin
            fifo_wr <= 1'b0;
            if (!busy) begin
                if (trig) begin busy<=1'b1; sxs<=0; ll_q<=ll; lb_q<=rd_lb; end
            end else begin
                acc[{pixk,2'b00} +: 4] <= spix;
                if (pixk==4'd15) begin
                    fifo_din <= {spix, acc[59:0]};
                    fifo_wr  <= 1'b1;
                    pixk     <= 4'd0;
                end else pixk <= pixk + 4'd1;
                if (sxs==FB_W-1) busy<=1'b0; else sxs<=sxs+9'd1;
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
