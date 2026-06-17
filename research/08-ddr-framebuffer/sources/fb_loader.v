`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_loader.v  -  AXI-HP0 read master: copy one ZX source frame DDR -> display BRAM per vblank.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// On each frame_kick (one fclk100 pulse, derived from the HDMI vblank) it bursts WORDS x 64-bit
// (6480 words = 51840 bytes) from PS DDR @base into the display BRAM, in order, one word per beat.
// Single ARID (=0), 64-bit (ARSIZE=3), 16-beat INCR bursts -> in-order R -> sequential BRAM fill.
// Adapted from the proven axi_hp_probe (latency gate). All on fclk100 = S_AXI_HP0 ACLK (no CDC on
// the AXI side); the only crossing is frame_kick (synchronised in the top) and the BRAM read port.
//
// Bandwidth: 51840 B x 50 Hz ~= 2.6 MB/s (a rounding error against the ~800 MB/s HP0 ceiling); the
// whole frame loads in ~65 us, comfortably inside the ~417 us 720p vblank.
//-------------------------------------------------------------------------------------------------
module fb_loader #(
    parameter [12:0] WORDS  = 13'd6480,    // 360*288/16
    parameter [8:0]  BURSTS = 9'd405,      // WORDS/16
    parameter [2:0]  MAXOUT = 3'd6         // outstanding read bursts (<=8 HP issuing cap)
)(
    input  wire        clk,                // fclk100 (= S_AXI_HP0 ACLK)
    input  wire        resetn,
    input  wire        frame_kick,         // 1-cycle pulse: start a frame load (vblank)
    input  wire [31:0] base,               // DDR base, 8-byte aligned
    input  wire        load_en,

    // ---- AXI-HP0 read address channel ----
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
    // ---- AXI-HP0 read data channel ----
    input  wire [63:0] r_data,
    input  wire        r_last,
    input  wire        r_valid,
    output wire        r_ready,

    // ---- display BRAM write port ----
    output reg         wr_en,
    output reg  [12:0] wr_addr,
    output reg  [63:0] wr_data,

    // ---- status / liveness ----
    output reg  [31:0] frame_cnt,
    output reg  [31:0] beat_cnt,
    output wire        busy_o
);
    assign ar_id    = 6'd0;
    assign ar_len   = 4'd15;        // 16-beat bursts
    assign ar_size  = 3'b011;       // 8 bytes/beat (top connects [1:0] to the HP port)
    assign ar_burst = 2'b01;        // INCR
    assign ar_cache = 4'b0011;
    assign ar_prot  = 3'b000;
    assign ar_lock  = 2'b00;
    assign ar_qos   = 4'b0000;
    assign r_ready  = 1'b1;         // BRAM write keeps up (1 word/beat) -> always ready

    reg        busy;
    reg [8:0]  ar_issued;           // bursts issued this frame (0..BURSTS)
    reg [12:0] beats_rcvd;          // beats/words received this frame (0..WORDS)
    reg [2:0]  outstanding;

    assign busy_o = busy;

    wire ar_hs = ar_valid & ar_ready;
    wire r_hs  = r_valid & r_ready;

    always @(posedge clk) begin
        if (!resetn) begin
            busy<=1'b0; ar_valid<=1'b0; ar_addr<=base; ar_issued<=9'd0;
            beats_rcvd<=13'd0; outstanding<=3'd0; wr_en<=1'b0; wr_addr<=13'd0; wr_data<=64'd0;
            frame_cnt<=32'd0; beat_cnt<=32'd0;
        end else begin
            wr_en <= 1'b0;                              // default: no BRAM write this cycle
            if (!busy) begin
                ar_valid <= 1'b0;
                if (frame_kick && load_en) begin        // arm a fresh frame load
                    busy<=1'b1; ar_addr<=base; ar_issued<=9'd0;
                    beats_rcvd<=13'd0; outstanding<=3'd0;
                end
            end else begin
                // -- AR issue: keep <=MAXOUT bursts in flight until BURSTS issued --
                if (!ar_valid && (ar_issued < BURSTS) && (outstanding < {1'b0,MAXOUT}))
                    ar_valid <= 1'b1;
                if (ar_hs) begin
                    ar_valid  <= 1'b0;
                    ar_addr   <= ar_addr + 32'd128;     // 16 beats * 8 bytes
                    ar_issued <= ar_issued + 9'd1;
                end
                // -- R consume: write one BRAM word per beat, in order --
                if (r_hs) begin
                    wr_en      <= 1'b1;
                    wr_addr    <= beats_rcvd;            // pre-increment index = linear word
                    wr_data    <= r_data;
                    beats_rcvd <= beats_rcvd + 13'd1;
                    beat_cnt   <= beat_cnt + 32'd1;
                    if (beats_rcvd == WORDS-1) begin     // last word of the frame
                        busy      <= 1'b0;
                        frame_cnt <= frame_cnt + 32'd1;
                    end
                end
                // -- outstanding accounting --
                case ({ar_hs, (r_hs & r_last)})
                    2'b10:   outstanding <= outstanding + 3'd1;
                    2'b01:   outstanding <= outstanding - 3'd1;
                    default: outstanding <= outstanding;
                endcase
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
