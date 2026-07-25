`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// tape_player.v  -  BulbuLator Step 14: real-time ZX tape pulse replay (.tap / .tzx via the ARM).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM parses the tape and pushes a stream of {level, sync_rom, duration} pulses (duration in Z80 T-states)
// into a dual-clock FIFO. This module replays them into `tape_ear` - the ear/tape input the fabric mux
// feeds to the core (and mixes into the audio out for the authentic loading sound). The replay clock
// is the CPU's own T-state enable (pe3M5_core), so tape and CPU advance in exact lock-step: a pause
// (HALT) freezes BOTH, and the ROM/turbo/custom loader's T-state timing loops measure the pulses
// exactly as a real tape. This is the machine-agnostic PULSE class of the loader contract; the ARM
// owns all format knowledge (ROM pilot/sync/data, turbo, or verbatim WAV edges) - the fabric just
// times the edges. CDC: Gray pointers; payload is in true dual-port BRAM, ARM push = wr_clk (fclk100),
// replay = rd_clk (spclk); the single-bit `run` must be level-synced by the caller.
//-------------------------------------------------------------------------------------------------
module tape_player #(
    parameter integer DUR_W = 24,     // duration field: up to 16.7M T-states (~4.8 s) per pulse
    parameter integer AW    = 12      // 4096 pulse descriptors in true BRAM: absorbs FAST8 MP3 bursts
)(
    // ---- ARM push side (fclk100) ----
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        push,          // 1-cycle strobe: enqueue push_data
    input  wire [31:0] push_data,     // [31] ear, [30] standard ROM block, [29] first pulse of block, [DUR_W-1:0] duration
    output wire        full,          // FIFO full (backpressure to the ARM)
    // ---- core replay side (spclk) ----
    input  wire        rd_clk,        // spclk (~56.7 MHz)
    input  wire        rd_rst_n,
    // FIFO pointers use only a common POR reset.  A ZX hot reset is local to
    // the player and must never reset just one side of a dual-clock FIFO.
    input  wire        fifo_rd_rst_n,
    input  wire        t_en,          // pe3M5_core: one strobe per Z80 T-state (HALT-synced)
    input  wire        run,           // TAPE_CTRL run enable (level; sync upstream before wiring here)
    output reg         tape_ear,      // replayed ear level -> core ear mux + audio mixer
    output wire        playing,       // 1 = actively replaying (mid-pulse or pulses queued)
    output wire        empty,         // 1 = pulse FIFO empty (underrun backpressure to the CPU)
    output wire        sync_rom,      // current/next descriptor belongs to a standard ROM-loader block
    output reg         block_start,   // 1 rd_clk pulse after the first descriptor of a block is popped
    // Passive post-mortem probes. They are reset on each rising edge of run and
    // otherwise do not participate in replay or flow control.
    output reg  [31:0] diag_pop_count,
    output reg  [31:0] diag_pop_hash,
    output reg  [31:0] diag_gap_count,    // current pulse ended while FIFO was empty (includes final EOT)
    output reg  [31:0] diag_resume_count  // a new pulse arrived after such a gap (true mid-stream gap)
);
    wire [31:0] dout;
    reg         rd_en;

    tape_bram_fifo #(.DW(32), .AW(AW)) fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(push), .din(push_data), .full(full),
        .rd_clk(rd_clk), .rd_rst_n(fifo_rd_rst_n), .rd_en(rd_en), .dout(dout), .empty(empty)
    );

    reg [DUR_W-1:0] cnt;              // T-states remaining in the current pulse
    reg             busy;             // 1 = a pulse is currently being held
    reg             cur_sync_rom;     // metadata latched with the current descriptor
    reg             run_d;
    reg             gap_wait;
    assign playing = busy | ~empty;
    /* FWFT look-ahead is essential at a block boundary: while idle, expose the head descriptor's
       marker so the top can stop BEFORE consuming its first pilot T-state. */
    assign sync_rom = busy ? cur_sync_rom : (!empty ? dout[30] : cur_sync_rom);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            cnt <= {DUR_W{1'b0}}; busy <= 1'b0; cur_sync_rom <= 1'b0; tape_ear <= 1'b0; rd_en <= 1'b0; block_start <= 1'b0;
            run_d <= 1'b0; gap_wait <= 1'b0;
            diag_pop_count <= 32'd0; diag_pop_hash <= 32'h811C9DC5;
            diag_gap_count <= 32'd0; diag_resume_count <= 32'd0;
        end else begin
            run_d <= run;
            rd_en <= 1'b0;                              // default: no pop this cycle
            block_start <= 1'b0;                        // descriptor-boundary marker is a one-cycle pulse
            if (run && !run_d) begin                    // start of a fresh tape run
                diag_pop_count <= 32'd0;
                diag_pop_hash <= 32'h811C9DC5;
                diag_gap_count <= 32'd0;
                diag_resume_count <= 32'd0;
                gap_wait <= 1'b0;
            end
            if (!run) begin
                busy <= 1'b0; cur_sync_rom <= 1'b0; tape_ear <= 1'b0; // stopped -> release ear low, drop any mid-pulse
                gap_wait <= 1'b0;
                if (!empty) rd_en <= 1'b1;              // AND drain any queued pulses so a restart begins at the FILE start,
                                                        // not on leftover FIFO (fixes: quick BkSp-stop then Enter replays a stale pilot)
            end else if (t_en) begin
                if (busy && (cnt > {{(DUR_W-1){1'b0}},1'b1})) begin
                    cnt <= cnt - 1'b1;                  // hold the current pulse
                end else if (!empty) begin              // pulse finished (or idle) + one waiting -> load it
                    tape_ear <= dout[31];               // FWFT: dout is the head while !empty
                    cur_sync_rom <= dout[30];
                    cnt      <= dout[DUR_W-1:0];
                    busy     <= 1'b1;
                    rd_en    <= 1'b1;                    // advance the FIFO to the next pulse
                    block_start <= dout[29];             // top closes/re-arms SYNC before the next T-state
                    diag_pop_count <= diag_pop_count + 32'd1;
                    // Cheap order-sensitive rolling fingerprint: rotate-left five, then fold the
                    // descriptor and its ordinal. No multiplier/DSP and no path into tape timing.
                    diag_pop_hash <= {diag_pop_hash[26:0],diag_pop_hash[31:27]} ^ dout ^ diag_pop_count;
                    if (gap_wait) begin
                        diag_resume_count <= diag_resume_count + 32'd1;
                        gap_wait <= 1'b0;
                    end
                end else begin
                    busy <= 1'b0;                       // starved: hold the last level, mark idle (no glitch)
                    if (busy && !gap_wait) begin         // count the transition once, not every empty t_en
                        diag_gap_count <= diag_gap_count + 32'd1;
                        gap_wait <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
