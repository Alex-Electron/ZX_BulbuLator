`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_line_disp.v  -  Phase 1a: line-buffered DDR display (replaces fb_loader + the whole-frame BRAM
// in fb_display). Per-source-line AXI-HP0 read into a small LUTRAM buffer, scanned out at 720p50.
// ZX output BYTE-IDENTICAL to fb_display.v; frees ~11 BRAM36. Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// v2 = code-review (workflow ws1b0mjym, FIX-THEN-GO) fixes applied:
//   B1: frame_base/fk_d reset + `base_valid` gate -> NO AR until disp_base pinned by first frame_kick
//       (else a boot burst reads garbage DDR and falsely asserts live -> bad cap_en re-source).
//   B2: need_row clk_pixel->fclk100 uses a SETTLED multi-bit cross (use nr_s2 only when nr_s2==nr_s3),
//       not a bare binary 2-FF (which can present a bogus intermediate at a multi-bit row boundary and
//       make the eviction logic drop a resident line).
//   F3: clear buf_row tag (=ROW_NONE) at invalidate so a mid-fill buffer can never tag-match.
//   F4: pixel select parameterized by SRC_BPP (psel=nib<<LBPP, px=rd[psel +: SRC_BPP]) -> the palette is
//       the only per-core stage. (ZX 4bpp output byte-identical.)
//   F5: MAXOUT param; LBW = FBURSTS*BEATS single source; widened word-address; named burst granule.
//   F6: lb read forced to 0 when !have_line (no X); dead code removed.
//
// CORE-INDEPENDENT scaler (machine-backend contract): geometry/scale/crop/bpp are PARAMETERS (ZX
// defaults). Buffering = TWO tag-addressed line buffers (buf_row + valid); the fclk100 reader keeps
// {need_row, need_row+1} resident; the scanout reads whichever buffer is tagged with the current rd_sy.
// Frame-top prime is automatic (in the top pillarbox need_row=SY0 -> SY0/SY0+1 load before the picture).
//-------------------------------------------------------------------------------------------------
module fb_line_disp #(
    parameter integer SRC_W   = 360,
    parameter integer SRC_H   = 302,      // capture writes 302 rows (vc 8..309, clean visible frame)
    parameter integer SRC_BPP = 4,
    parameter integer STRIDE  = 360,
    parameter integer SX0     = 0,        // show cols 0..356 = FULL left border, right edge = last good col 356
    parameter integer SY0     = 0,        // (white rgb/blank-skew garbage at 357-358 and black pad 359 excluded).
    parameter integer CROP_W  = 357,      // User choice: keep the WHOLE border, don't trim left; left 53 / right 48
    parameter integer CROP_H  = 302,      // show 302 rows (vc 8..309): rainbow top + active + rainbow + 1 black bottom
    parameter integer HMARGIN = 283,      // center 357*2=714 px in the 1280-wide active raster ((1280-714)/2)
    parameter integer VMARGIN = 58,       // center 302*2=604 lines in the 720-line active raster ((720-604)/2)
    parameter integer XSH     = 1,        // horizontal upscale shift
    parameter integer YSH     = 1,        // vertical upscale shift
    parameter integer WSH     = 4,        // log2(px per 64-bit word) = log2(64/SRC_BPP)
    parameter integer LBPP    = 2,        // log2(SRC_BPP) (4bpp->2)
    parameter integer FBURSTS = 3,        // 16-beat bursts per line fetch
    parameter integer MAXOUT  = 6,        // outstanding read bursts (<=8 HP cap)
    parameter integer WA      = 21        // word-address width (covers big frames)
)(
    // ---- fclk100 (= S_AXI_HP0 ACLK) ----
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] disp_base,
    input  wire        frame_kick,
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
    // ---- clk_pixel (HDMI 720p50) ----
    input  wire        rd_clk,
    input  wire [10:0] cx,
    input  wire [10:0] cy,
    output reg  [23:0] rgb,
    // ---- status ----
    output reg         live,
    output reg  [31:0] underrun_cnt
);
    localparam integer BEATS   = 16;              // 16-beat = 128B INCR bursts
    localparam integer LBW     = FBURSTS*BEATS;   // line-buffer depth (words)
    localparam [8:0]   ROW_NONE= 9'h1FF;          // "no row" tag
    localparam integer MAXR    = (1<<($clog2(2*LBW)));

    assign ar_id=6'd0; assign ar_len=BEATS-1; assign ar_size=3'b011; assign ar_burst=2'b01;
    assign ar_cache=4'b0011; assign ar_prot=3'b000; assign ar_lock=2'b00; assign ar_qos=4'b0000;
    assign r_ready = 1'b1;

    //=============================================================================================
    // clk_pixel: which SOURCE ROW does the scanout need now (= need_row)?  In the top pillarbox we
    // point at SY0 so the reader primes SY0/SY0+1 before the picture; in-picture it tracks the row.
    //=============================================================================================
    wire        in_v   = (cy >= VMARGIN) && (cy < VMARGIN + (CROP_H<<YSH));
    wire [8:0]  row_in = SY0 + ((cy - VMARGIN) >> YSH);
    reg  [8:0]  need_row;
    always @(posedge rd_clk) need_row <= in_v ? row_in : SY0[8:0];

    //=============================================================================================
    // disp_base pinned ONCE per frame; reader keeps {want0,want1} resident in 2 tagged buffers.
    //=============================================================================================
    (* ram_style="distributed" *) reg [63:0] lb [0:2*LBW-1];
    reg  [8:0]    buf_row [0:1];
    reg  [WA-1:0] buf_base[0:1];
    reg  [1:0]    buf_valid;

    // need_row clk_pixel->fclk100, SETTLED (use nr_s2 only when it equals nr_s3) -> no bogus multi-bit
    reg [8:0] nr_s1, nr_s2, nr_s3, nr_stable;
    always @(posedge clk) begin
        nr_s1 <= need_row; nr_s2 <= nr_s1; nr_s3 <= nr_s2;
        if (nr_s2 == nr_s3) nr_stable <= nr_s2;
    end
    wire [8:0] want0 = nr_stable;
    wire [8:0] want1 = (nr_stable + 9'd1 < SRC_H[8:0]) ? nr_stable + 9'd1 : nr_stable;

    // disp_base pin (latched the cycle after frame_kick) + base_valid (set once a frame has been pinned)
    reg        fk_d, base_valid;
    reg [31:0] frame_base;
    always @(posedge clk) begin
        if (!resetn) begin fk_d<=1'b0; frame_base<=disp_base; base_valid<=1'b0; end
        else begin
            fk_d <= frame_kick;
            if (fk_d) begin frame_base <= disp_base; base_valid <= 1'b1; end
        end
    end

    wire b0_is0 = buf_valid[0] && (buf_row[0]==want0);
    wire b0_is1 = buf_valid[0] && (buf_row[0]==want1);
    wire b1_is0 = buf_valid[1] && (buf_row[1]==want0);
    wire b1_is1 = buf_valid[1] && (buf_row[1]==want1);
    wire have0    = b0_is0 | b1_is0;
    wire have1    = b0_is1 | b1_is1;
    wire b0_spare = !(b0_is0 | b0_is1);
    wire b1_spare = !(b1_is0 | b1_is1);

    localparam RD_IDLE=1'b0, RD_AR=1'b1;
    reg        rstate;
    reg        tgt;
    reg [8:0]  tgt_row;
    reg [WA-1:0] tgt_base;
    reg [8:0]  ar_issued;
    reg [8:0]  words_rcvd;
    reg [2:0]  outstanding;

    wire ar_hs = ar_valid & ar_ready;
    wire r_hs  = r_valid & r_ready;

    function [WA-1:0] base_word_f(input [8:0] r); base_word_f = (r*STRIDE) >> WSH; endfunction
    function [WA-1:0] align_f   (input [8:0] r); align_f     = ((r*STRIDE) >> WSH) & ~{{(WA-4){1'b0}},4'd15}; endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            rstate<=RD_IDLE; ar_valid<=1'b0; ar_addr<=32'd0; ar_issued<=9'd0; words_rcvd<=9'd0;
            outstanding<=3'd0; buf_valid<=2'b00; tgt<=1'b0; live<=1'b0; underrun_cnt<=32'd0;
            buf_row[0]<=ROW_NONE; buf_row[1]<=ROW_NONE; buf_base[0]<={WA{1'b0}}; buf_base[1]<={WA{1'b0}};
        end else begin
            case (rstate)
            RD_IDLE: begin
                ar_valid<=1'b0; outstanding<=3'd0; ar_issued<=9'd0; words_rcvd<=9'd0;
                if (base_valid && !have0 && (b0_spare || b1_spare)) begin
                    tgt      <= b0_spare ? 1'b0 : 1'b1;
                    tgt_row  <= want0;
                    tgt_base <= align_f(want0);
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr  <= frame_base + ({{(32-WA-3){1'b0}}, align_f(want0), 3'b000});
                    rstate   <= RD_AR;
                end else if (base_valid && !have1 && (b0_spare || b1_spare)) begin
                    tgt      <= b0_spare ? 1'b0 : 1'b1;
                    tgt_row  <= want1;
                    tgt_base <= align_f(want1);
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr  <= frame_base + ({{(32-WA-3){1'b0}}, align_f(want1), 3'b000});
                    rstate   <= RD_AR;
                end
            end
            RD_AR: begin
                if (!ar_valid && (ar_issued < FBURSTS) && (outstanding < MAXOUT[2:0]))
                    ar_valid <= 1'b1;
                if (ar_hs) begin
                    ar_valid  <= 1'b0;
                    ar_addr   <= ar_addr + 32'd128;
                    ar_issued <= ar_issued + 9'd1;
                end
                if (r_hs) begin
                    lb[(tgt?LBW:0) + words_rcvd] <= r_data;
                    words_rcvd <= words_rcvd + 9'd1;
                end
                case ({ar_hs,(r_hs & r_last)})
                    2'b10: outstanding<=outstanding+3'd1;
                    2'b01: outstanding<=outstanding-3'd1;
                    default:;
                endcase
                if (words_rcvd==LBW-1 && r_hs) begin
                    buf_row [tgt] <= tgt_row;
                    buf_base[tgt] <= tgt_base;
                    buf_valid[tgt]<= 1'b1;
                    live          <= 1'b1;
                    rstate        <= RD_IDLE;
                end
            end
            endcase
        end
    end

    //=============================================================================================
    // clk_pixel scanout (crop/upscale/palette LIFTED from fb_display.v; mem[rd_word] -> line buffer).
    //=============================================================================================
    wire in_pic = (cx >= HMARGIN) && (cx < HMARGIN + (CROP_W<<XSH)) &&
                  (cy >= VMARGIN) && (cy < VMARGIN + (CROP_H<<YSH));
    wire [8:0]  rd_sx = SX0 + ((cx - HMARGIN) >> XSH);
    // rd_sy COMBINATIONAL from cy (byte-identical to fb_display.v) -- NOT the registered need_row
    // (which exists only for the reader-CDC). Using need_row here added an extra register stage on the
    // vertical path vs the in_pic gate -> a 1-line data/gate skew visible as ~1px clipped at the top.
    wire [8:0]  rd_sy = SY0 + ((cy - VMARGIN) >> YSH);
    wire [WA-1:0] lin     = rd_sy*STRIDE + rd_sx;
    wire [WA-1:0] lin_word= lin >> WSH;
    wire [3:0]  lin_nib   = lin[WSH-1:0];

    reg [1:0] v_s1, v_s2;
    always @(posedge rd_clk) begin v_s1<=buf_valid; v_s2<=v_s1; end
    wire sel0 = v_s2[0] && (buf_row[0]==rd_sy);
    wire sel1 = v_s2[1] && (buf_row[1]==rd_sy);
    wire        have_line = sel0 | sel1;
    wire [WA-1:0] sbase   = sel0 ? buf_base[0] : buf_base[1];
    wire [WA-1:0] bufidx  = lin_word - sbase;                 // 0..LBW-1 when have_line
    wire [63:0] word      = have_line ? lb[(sel0 ? 0 : LBW) + bufidx[$clog2(LBW)-1:0]] : 64'd0;

    reg [63:0] rd_q; reg [3:0] nib_q; reg in_pic_q; reg have_q;
    always @(posedge rd_clk) begin
        rd_q<=word; nib_q<=lin_nib; in_pic_q<=in_pic; have_q<=have_line;
    end
    wire [9:0] psel = nib_q << LBPP;
    wire [3:0] px   = rd_q[psel +: 4];                        // SRC_BPP=4 for ZX (param-ready: +: SRC_BPP)
    wire bri=px[3], rr=px[2], gg=px[1], bb=px[0];
    wire [7:0] lvl = bri ? 8'hFF : 8'hD7;

    always @(posedge rd_clk) begin
        if (in_pic_q && have_q)
            rgb <= { rr?lvl:8'h00, gg?lvl:8'h00, bb?lvl:8'h00 };
        else
            rgb <= 24'h505050;
    end

    always @(posedge rd_clk) if (in_pic && !have_line) underrun_cnt <= underrun_cnt + 32'd1;
endmodule
//-------------------------------------------------------------------------------------------------
