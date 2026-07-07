`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tape_player.v  -  BulbuLator Step 14: real-time ZX tape pulse replay (.tap / .tzx via the ARM).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM parses the tape and pushes a stream of {level, duration} pulses (duration in Z80 T-states)
// into an async FIFO. This module replays them into `tape_ear` - the ear/tape input the fabric mux
// feeds to the core (and mixes into the audio out for the authentic loading sound). The replay clock
// is the CPU's own T-state enable (pe3M5_core), so tape and CPU advance in exact lock-step: a pause
// (HALT) freezes BOTH, and the ROM/turbo/custom loader's T-state timing loops measure the pulses
// exactly as a real tape. This is the machine-agnostic PULSE class of the loader contract; the ARM
// owns all format knowledge (ROM pilot/sync/data, turbo, or verbatim WAV edges) - the fabric just
// times the edges. CDC: standard dual-clock gray FIFO (async_fifo), ARM push = wr_clk (fclk100),
// replay = rd_clk (spclk); the single-bit `run` must be level-synced by the caller.
//-------------------------------------------------------------------------------------------------
module tape_player #(
    parameter integer DUR_W = 24,     // duration field: up to 16.7M T-states (~4.8 s) per pulse
    parameter integer AW    = 9       // FIFO depth 2^9 = 512 pulses (ARM refills with backpressure)
)(
    // ---- ARM push side (fclk100) ----
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        push,          // 1-cycle strobe: enqueue push_data
    input  wire [31:0] push_data,     // [31] = ear level, [DUR_W-1:0] = duration in T-states
    output wire        full,          // FIFO full (backpressure to the ARM)
    // ---- core replay side (spclk) ----
    input  wire        rd_clk,        // spclk (~56.7 MHz)
    input  wire        rd_rst_n,
    input  wire        t_en,          // pe3M5_core: one strobe per Z80 T-state (HALT-synced)
    input  wire        run,           // TAPE_CTRL run enable (level; sync upstream before wiring here)
    output reg         tape_ear,      // replayed ear level -> core ear mux + audio mixer
    output wire        playing        // 1 = actively replaying (mid-pulse or pulses queued)
);
    wire [31:0] dout;
    wire        empty;
    reg         rd_en;

    async_fifo #(.DW(32), .AW(AW)) fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(push), .din(push_data), .full(full),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .rd_en(rd_en), .dout(dout), .empty(empty),
        .rd_count()
    );

    reg [DUR_W-1:0] cnt;              // T-states remaining in the current pulse
    reg             busy;             // 1 = a pulse is currently being held
    assign playing = busy | ~empty;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            cnt <= {DUR_W{1'b0}}; busy <= 1'b0; tape_ear <= 1'b0; rd_en <= 1'b0;
        end else begin
            rd_en <= 1'b0;                              // default: no pop this cycle
            if (!run) begin
                busy <= 1'b0; tape_ear <= 1'b0;         // stopped -> release ear low, drop any mid-pulse
            end else if (t_en) begin
                if (busy && (cnt > {{(DUR_W-1){1'b0}},1'b1})) begin
                    cnt <= cnt - 1'b1;                  // hold the current pulse
                end else if (!empty) begin              // pulse finished (or idle) + one waiting -> load it
                    tape_ear <= dout[31];               // FWFT: dout is the head while !empty
                    cnt      <= dout[DUR_W-1:0];
                    busy     <= 1'b1;
                    rd_en    <= 1'b1;                    // advance the FIFO to the next pulse
                end else begin
                    busy <= 1'b0;                       // starved: hold the last level, mark idle (no glitch)
                end
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
