`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_wr_axi.v  -  drain the capture FIFO into PS DDR over the S_AXI_HP0 WRITE channel.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// fclk100 domain. Pops 64-bit words (one per W beat) from the async capture FIFO and writes them to
// DDR as INCR bursts at `base`. WORDS words = one frame. The frame is FULLB full 16-beat bursts plus,
// if WORDS is not a multiple of 16, ONE final PARTIAL burst of LASTB beats (so the frame height need
// not be a multiple of 32 lines). On the WORDS-th word it pulses frame_done and re-latches `base`.
// FWFT FIFO: fifo_dout is valid while !fifo_empty; fifo_rd pops on the W handshake.
//-------------------------------------------------------------------------------------------------
module fb_wr_axi #(
    parameter [12:0] WORDS  = 13'd6795        // 302 lines * 360 / 16 (vc 8..309: clean visible frame)
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] base,           // current write-buffer base (from fb_bufmgr3)

    // async FIFO read side (FWFT)
    input  wire        fifo_empty,
    input  wire [63:0] fifo_dout,
    output wire        fifo_rd,

    // AXI-HP0 write
    output reg  [31:0] aw_addr,
    output wire [5:0]  aw_id,
    output wire [3:0]  aw_len,
    output wire [2:0]  aw_size,
    output wire [1:0]  aw_burst,
    output wire [3:0]  aw_cache,
    output wire [2:0]  aw_prot,
    output wire [1:0]  aw_lock,
    output wire [3:0]  aw_qos,
    output reg         aw_valid,
    input  wire        aw_ready,
    output wire [63:0] w_data,
    output wire [7:0]  w_strb,
    output wire        w_last,
    output wire        w_valid,
    input  wire        w_ready,
    input  wire        b_valid,
    output wire        b_ready,

    output reg         frame_done,
    output wire        busy_o
);
    // burst structure derived from WORDS: FULLB full 16-beat bursts + optional 1 partial (LASTB beats)
    localparam [12:0] FULLB = WORDS >> 4;                              // # of full 16-beat bursts
    localparam [3:0]  LASTB = WORDS[3:0];                             // remainder beats (0..15)
    localparam        HASLAST = (LASTB != 4'd0);
    localparam [8:0]  TOTB  = FULLB[8:0] + (HASLAST ? 9'd1 : 9'd0);    // total bursts/frame

    assign aw_id=6'd0; assign aw_size=3'b011; assign aw_burst=2'b01;
    assign aw_cache=4'b0011; assign aw_prot=3'b000; assign aw_lock=2'b00; assign aw_qos=4'b0000;
    assign w_strb=8'hFF; assign b_ready=1'b1;

    localparam S_AW=2'd0, S_W=2'd1, S_B=2'd2, S_WAIT=2'd3;
    reg [1:0]  state;
    reg [8:0]  burst;
    reg [3:0]  beat;
    reg [12:0] word_total;
    reg [1:0]  wcnt;

    // this burst is the (only) partial one -> LASTB beats, else a full 16-beat burst
    wire       is_last  = HASLAST && (burst == TOTB-9'd1);
    wire [3:0] last_beat = is_last ? (LASTB-4'd1) : 4'd15;

    assign aw_len  = last_beat;                                       // burst length-1 (10 for partial, 15 full)
    assign busy_o  = 1'b1;
    assign w_data  = fifo_dout;
    assign w_last  = (state==S_W) && (beat==last_beat);
    // present a W beat (combinationally) only when the FIFO has a word; pop it on the handshake
    assign w_valid = (state==S_W) && !fifo_empty;
    assign fifo_rd = w_valid && w_ready;

    always @(posedge clk) begin
        if (!resetn) begin
            state<=S_AW; aw_valid<=1'b0; aw_addr<=base;
            burst<=9'd0; beat<=4'd0; word_total<=13'd0; wcnt<=2'd0; frame_done<=1'b0;
        end else begin
            frame_done <= 1'b0;
            case (state)
                S_AW: begin
                    aw_valid <= 1'b1;
                    if (aw_valid && aw_ready) begin aw_valid<=1'b0; beat<=4'd0; state<=S_W; end
                end
                S_W: begin
                    if (w_valid && w_ready) begin            // one W beat accepted
                        word_total <= word_total + 13'd1;
                        if (beat==last_beat) state<=S_B;
                        else beat <= beat + 4'd1;
                    end
                end
                S_B: if (b_valid) begin
                    if (burst==TOTB-9'd1) begin              // frame complete (full + partial done)
                        frame_done <= 1'b1;                  // -> manager advances wr_buf
                        wcnt<=2'd0; state<=S_WAIT;
                    end else begin
                        burst<=burst+9'd1; aw_addr<=aw_addr+32'd128; state<=S_AW;
                    end
                end
                S_WAIT: begin                               // wait for wr_buf (-> base) to settle,
                    if (wcnt==2'd3) begin                   // then latch the NEW buffer's base
                        burst<=9'd0; word_total<=13'd0; aw_addr<=base; state<=S_AW;
                    end else wcnt <= wcnt + 2'd1;
                end
                default: state<=S_AW;
            endcase
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
