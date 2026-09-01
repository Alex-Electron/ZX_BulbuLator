`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// osd_ddr_rd.v  -  BulbuLator Step 14: DDR-backed TRUE-COLOUR (ARGB8888) OSD line-reader on AXI-HP1.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// A close clone of the proven fb_line_disp.v (Phase 1a line-buffered DDR reader), SIMPLIFIED for the
// OSD layer: 1:1 (no upscale), no palette (direct ARGB), 32 bpp = 2 pixels per 64-bit AXI beat, and
// a RUNTIME position (x0/y0) + base + enable instead of compile-time geometry. The canvas is a fixed
// CW x CH ARGB8888 surface (stride = CW) that the ARM draws into (alpha = 0 => transparent) in the
// non-cacheable DDR window; the top composites this over the live video by the per-pixel alpha.
// Keeps {need_row, need_row+1} resident in two tag-addressed line buffers (same idiom as fb_line_disp:
// base_valid gate B1, settled multi-bit need_row cross B2, tag-clear F3). Reads its OWN AXI-HP1 port,
// so it never contends with the video framebuffer on HP0.
//-------------------------------------------------------------------------------------------------
module osd_ddr_rd #(
    parameter integer CW  = 512,        // canvas width  (px)  -- must be a multiple of 32 (2px/word * 16-beat)
    parameter integer CH  = 384,        // canvas height (px)
    parameter integer WPR = CW/2,       // 64-bit words per row (2 ARGB px / 64-bit word)
    parameter integer WA  = 21
)(
    // ---- fclk100 (= S_AXI_HP1 ACLK) ----
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] osd_base,        // DDR byte address of the ARGB canvas (from OSD_DDR_BASE)
    input  wire        frame_kick,      // per-frame pin (fclk100), same source as the video reader
    output reg  [31:0] ar_addr,
    output wire [5:0]  ar_id,
    output wire [3:0]  ar_len,
    output wire [2:0]  ar_size,
    output wire [1:0]  ar_burst,
    output wire [3:0]  ar_cache,
    output wire [2:0]  ar_prot,
    output wire [1:0]  ar_lock,
    output wire [3:0]  ar_qos,
    output reg         ar_valid,
    input  wire        ar_ready,
    input  wire [63:0] r_data,
    input  wire        r_last,
    input  wire        r_valid,
    output wire        r_ready,
    // ---- clk_pixel (HDMI 720p50 scanout) ----
    input  wire        rd_clk,
    input  wire [10:0] cx,
    input  wire [10:0] cy,
    input  wire [10:0] x0,              // canvas top-left X (runtime, from OSD_POS)
    input  wire [10:0] y0,              // canvas top-left Y (runtime)
    input  wire        en,              // DDR-OSD enable (synced from OSD_CTRL bit1)
    output reg  [23:0] osd_rgb,         // pixel RGB (valid when osd_active)
    output reg  [7:0]  osd_a,           // pixel alpha 0..255
    output reg         osd_active       // 1 = composite this pixel (in-window, line resident, alpha!=0)
);
    localparam integer BEATS   = 16;               // 16-beat = 128B INCR bursts
    localparam integer FBURSTS = WPR/BEATS;        // bursts per row (CW=512 => 256/16 = 16)
    localparam integer LBW     = WPR;              // words per row buffer
    localparam [9:0]   ROW_NONE= 10'h3FF;

    assign ar_id=6'd0; assign ar_len=BEATS-1; assign ar_size=3'b011; assign ar_burst=2'b01;
    assign ar_cache=4'b0011; assign ar_prot=3'b000; assign ar_lock=2'b00; assign ar_qos=4'b0000;
    assign r_ready = 1'b1;

    //=============================================================================================
    // clk_pixel: which canvas ROW does the scanout need now?  (1:1 -> row = cy - y0)
    //=============================================================================================
    wire        in_v   = en && (cy >= y0) && (cy < y0 + CH[10:0]);
    wire [9:0]  row_in = cy - y0;                  // 0..CH-1 when in_v
    reg  [9:0]  need_row;
    always @(posedge rd_clk) need_row <= in_v ? row_in : 10'd0;

    // need_row clk_pixel->clk, SETTLED (use nr_s2 only when it equals nr_s3) -> no bogus multi-bit
    reg [9:0] nr_s1, nr_s2, nr_s3, nr_stable;
    always @(posedge clk) begin
        nr_s1 <= need_row; nr_s2 <= nr_s1; nr_s3 <= nr_s2;
        if (nr_s2 == nr_s3) nr_stable <= nr_s2;
    end
    wire [9:0] want0 = nr_stable;
    wire [9:0] want1 = (nr_stable + 10'd1 < CH[9:0]) ? nr_stable + 10'd1 : nr_stable;

    // base pinned once per frame (latched the cycle after frame_kick) + base_valid gate
    reg        fk_d, base_valid;
    reg [31:0] frame_base;
    always @(posedge clk) begin
        if (!resetn) begin fk_d<=1'b0; frame_base<=osd_base; base_valid<=1'b0; end
        else begin fk_d <= frame_kick; if (fk_d) begin frame_base <= osd_base; base_valid <= 1'b1; end end
    end

    //=============================================================================================
    // Two tag-addressed line buffers; keep {want0,want1} resident.
    //=============================================================================================
    (* ram_style="distributed" *) reg [63:0] lb [0:2*LBW-1];
    reg [9:0] buf_row [0:1];
    reg [1:0] buf_valid;

    wire b0_is0 = buf_valid[0] && (buf_row[0]==want0);
    wire b0_is1 = buf_valid[0] && (buf_row[0]==want1);
    wire b1_is0 = buf_valid[1] && (buf_row[1]==want0);
    wire b1_is1 = buf_valid[1] && (buf_row[1]==want1);
    wire have0    = b0_is0 | b1_is0;
    wire have1    = b0_is1 | b1_is1;
    wire b0_spare = !(b0_is0 | b0_is1);
    wire b1_spare = !(b1_is0 | b1_is1);

    localparam RD_IDLE=1'b0, RD_AR=1'b1;
    reg        rstate, tgt;
    reg [9:0]  tgt_row;
    reg [9:0]  ar_issued, words_rcvd;
    reg [2:0]  outstanding;

    wire ar_hs = ar_valid & ar_ready;
    wire r_hs  = r_valid & r_ready;

    // row byte address = base + row * (WPR*8 bytes). Step 15 timing fix: this multiply used to sit
    // COMBINATIONALLY inside the FSM's ar_addr assignment (nr_stable -> DSP48 -> add -> FSM mux ->
    // ar_addr in one 10 ns fclk100 cycle = WNS -2.96 in the first constrained build). Precompute both
    // candidate addresses into registers, each with a ROW TAG; the FSM launches a fetch only when the
    // tag matches the row it wants - a just-changed nr_stable can never pair a stale address with a
    // fresh row tag (coherent by construction; worst case a 1-cycle stall per row change).
    reg [31:0] addr0_q = 32'd0, addr1_q = 32'd0;
    reg [9:0]  addr0_row_q = ROW_NONE, addr1_row_q = ROW_NONE;
    always @(posedge clk) begin
        addr0_q <= frame_base + (want0 * (WPR*8));  addr0_row_q <= want0;
        addr1_q <= frame_base + (want1 * (WPR*8));  addr1_row_q <= want1;
    end

    always @(posedge clk) begin
        if (!resetn) begin
            rstate<=RD_IDLE; ar_valid<=1'b0; ar_addr<=32'd0; ar_issued<=10'd0; words_rcvd<=10'd0;
            outstanding<=3'd0; buf_valid<=2'b00; tgt<=1'b0;
            buf_row[0]<=ROW_NONE; buf_row[1]<=ROW_NONE;
        end else begin
            case (rstate)
            RD_IDLE: begin
                ar_valid<=1'b0; outstanding<=3'd0; ar_issued<=10'd0; words_rcvd<=10'd0;
                if (base_valid && !have0 && (b0_spare || b1_spare) && (addr0_row_q == want0)) begin
                    tgt <= b0_spare ? 1'b0 : 1'b1;  tgt_row <= want0;
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr <= addr0_q; rstate <= RD_AR;
                end else if (base_valid && !have1 && (b0_spare || b1_spare) && (addr1_row_q == want1)) begin
                    tgt <= b0_spare ? 1'b0 : 1'b1;  tgt_row <= want1;
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr <= addr1_q; rstate <= RD_AR;
                end
            end
            RD_AR: begin
                if (!ar_valid && (ar_issued < FBURSTS[9:0]) && (outstanding < 3'd6))
                    ar_valid <= 1'b1;
                if (ar_hs) begin ar_valid<=1'b0; ar_addr<=ar_addr+32'd128; ar_issued<=ar_issued+10'd1; end
                if (r_hs)  begin lb[(tgt?LBW:0) + words_rcvd] <= r_data; words_rcvd<=words_rcvd+10'd1; end
                case ({ar_hs,(r_hs & r_last)})
                    2'b10: outstanding<=outstanding+3'd1;
                    2'b01: outstanding<=outstanding-3'd1;
                    default:;
                endcase
                if (words_rcvd==LBW[9:0]-10'd1 && r_hs) begin
                    buf_row[tgt]<=tgt_row; buf_valid[tgt]<=1'b1; rstate<=RD_IDLE;
                end
            end
            endcase
        end
    end

    //=============================================================================================
    // clk_pixel scanout: fetch the resident row's pixel, split ARGB, gate on alpha.
    //=============================================================================================
    wire        in_h  = en && (cx >= x0) && (cx < x0 + CW[10:0]);
    wire        in_win= in_h && in_v;
    wire [9:0]  col   = cx - x0;                   // 0..CW-1
    wire [9:0]  crow  = cy - y0;                   // 0..CH-1
    wire [8:0]  col_w = col[9:1];                  // /2 (2 px per word)
    wire        col_p = col[0];                    // which pixel in the word
    reg [1:0] v_s1, v_s2;
    always @(posedge rd_clk) begin v_s1<=buf_valid; v_s2<=v_s1; end
    wire sel0 = v_s2[0] && (buf_row[0]==crow);
    wire sel1 = v_s2[1] && (buf_row[1]==crow);
    wire        have_line = sel0 | sel1;
    wire [63:0] wq = have_line ? lb[(sel0 ? 0 : LBW) + col_w] : 64'd0;
    wire [31:0] px = col_p ? wq[63:32] : wq[31:0]; // ARGB8888: {A[31:24],R[23:16],G[15:8],B[7:0]}

    // TWO output register stages to match fb_line_disp's 2-stage scanout latency (rgb24 = 2 stages;
    // osd_compositor is combinational -> rgb24_osd also 2). A single stage here would put the DDR-OSD
    // one clk_pixel (one column) ahead of the underlay at the top's alpha blend -> a 1px horizontal
    // misregistration + alpha-edge fringe (RTL-review wzw8zry0j). All three outputs pipeline together
    // so the layer stays internally self-consistent (content + window/alpha aligned).
    reg        act1;  reg [7:0] a1;  reg [23:0] rgb1;
    always @(posedge rd_clk) begin
        act1       <= in_win && have_line && (px[31:24] != 8'd0);   // stage 1: composite only where alpha != 0
        a1         <= px[31:24];
        rgb1       <= px[23:0];
        osd_active <= act1;                                          // stage 2: aligns to the 2-stage video path
        osd_a      <= a1;
        osd_rgb    <= rgb1;
    end
endmodule
//-------------------------------------------------------------------------------------------------
