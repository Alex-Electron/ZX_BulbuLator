`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ddr_probe.v - hardware measurement of the PL->memory read path (AXI-HP master).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// WHY. The DDR cartridge (task 3) stands or falls on ONE number we never actually measured: how long
// a PL-side read takes, and how that changes when the video chain is already hammering the DDR. All
// our design talk ("bandwidth is fine, latency is the problem, 400-800 ns") came from documentation
// and from indirect evidence, not from this board. This module measures it in fabric, so the cache
// design that follows is dimensioned by data instead of by belief.
//
// WHAT IT MEASURES, per run:
//   * FIRST-WORD LATENCY, in aclk cycles, from the AR handshake to the first R beat: min / max / sum
//     (so the host can compute the mean). This is the number a cartridge fetch actually pays.
//   * TOTAL CYCLES from start to the last R beat, and TOTAL BEATS -> sustained throughput.
//   * Timeouts, so a dead address region reports itself instead of hanging the run.
//
// ADDRESS PATTERNS (mode), because DRAM only looks fast when you stay inside an open row:
//   0 SEQ    - addr += burst bytes. Best case; row hits, prefetch-friendly.
//   1 STRIDE - addr += STRIDE_BYTES (default 8 KB) -> forces a DRAM row miss every time. This is the
//              honest worst case and the one a random cartridge fetch resembles.
//   2 RANDOM - LFSR address inside a 16 MB window, 64-byte aligned. Real emulator access pattern.
//   3 FIXED  - the same address every time -> measures the pure port/controller round trip with the
//              row already open (the floor nothing can beat).
// The TARGET is just the base address, so the same probe measures DDR (0x0xxxxxxx) and the PS on-chip
// memory OCM (0xFFFC0000) over the same port - two answers for the price of one build.
//
// It is a READ probe on purpose: a cartridge is ROM. Writes are a separate question (save RAM) and
// would need their own counters.
//-------------------------------------------------------------------------------------------------
module ddr_probe #(
    parameter integer STRIDE_BYTES = 8192,      // mode 1: enough to leave the open DRAM row
    parameter integer TIMEOUT_CYC  = 100000     // ~1 ms at 100 MHz: a dead region must not hang us
)(
    input  wire        clk,                     // aclk = fclk100
    input  wire        resetn,

    // ---- control (aclk, from axi_ctl) ----
    input  wire [31:0] cfg_base,                // start address (DDR or OCM)
    input  wire [31:0] cfg_ctrl,                // {mode[1:0], len_code[1:0], 12'x, count[15:0]}
    input  wire        start,                    // 1-cycle pulse: begin a run
    output reg         busy,
    output reg  [31:0] res_lat_min,
    output reg  [31:0] res_lat_max,
    output reg  [31:0] res_lat_sum,             // sum of first-word latencies (host divides by count)
    output reg  [31:0] res_cycles,              // total cycles, start -> last beat
    output reg  [31:0] res_beats,               // total 64-bit beats returned
    output reg  [31:0] res_status,              // {timeouts[15:0], done, busy, mode[1:0], len_code[1:0]}

    // ---- AXI3 read master (S_AXI_HPx) ----
    output reg  [31:0] ar_addr,
    output wire [5:0]  ar_id,
    output reg  [3:0]  ar_len,
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
    output wire        r_ready
);
    assign ar_id    = 6'd0;
    assign ar_size  = 3'b011;      // 8 bytes/beat = 64-bit port
    assign ar_burst = 2'b01;       // INCR
    assign ar_cache = 4'b0011;     // bufferable+modifiable, same as our other masters
    assign ar_prot  = 3'b000;
    assign ar_lock  = 2'b00;
    assign ar_qos   = 4'b1111;     // highest QoS: we are measuring the BEST the port can do
    assign r_ready  = 1'b1;        // never backpressure - the DUT is the memory path, not us

    localparam S_IDLE = 2'd0, S_AR = 2'd1, S_R = 2'd2, S_FIN = 2'd3;
    reg [1:0]  st = S_IDLE;
    reg [1:0]  mode = 2'd0;
    reg [1:0]  lenc = 2'd0;
    reg [15:0] left = 16'd0;
    reg [31:0] addr = 32'd0;
    reg [31:0] lat  = 32'd0;       // cycles since the AR handshake of the current transaction
    reg [31:0] tot  = 32'd0;       // cycles since the run began
    reg [31:0] beats = 32'd0;
    reg [15:0] tmo_cnt = 16'd0;
    reg [30:0] lfsr = 31'h7FFF_FFFF;
    reg        first_beat;          // still waiting for the FIRST beat of this transaction

    // burst length from the code: 1 / 4 / 8 / 16 beats
    wire [3:0] len_of = (lenc == 2'd0) ? 4'd0 : (lenc == 2'd1) ? 4'd3 : (lenc == 2'd2) ? 4'd7 : 4'd15;
    wire [31:0] bytes_of = (lenc == 2'd0) ? 32'd8 : (lenc == 2'd1) ? 32'd32 : (lenc == 2'd2) ? 32'd64 : 32'd128;

    // LFSR (x^31 + x^28 + 1), 64-byte aligned inside a 16 MB window
    wire [30:0] lfsr_nx = {lfsr[29:0], lfsr[30] ^ lfsr[27]};

    always @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; busy <= 1'b0; ar_valid <= 1'b0; ar_addr <= 32'd0; ar_len <= 4'd0;
            res_lat_min <= 32'hFFFF_FFFF; res_lat_max <= 32'd0; res_lat_sum <= 32'd0;
            res_cycles <= 32'd0; res_beats <= 32'd0; res_status <= 32'd0;
            left <= 16'd0; addr <= 32'd0; lat <= 32'd0; tot <= 32'd0; beats <= 32'd0;
            tmo_cnt <= 16'd0; lfsr <= 31'h7FFF_FFFF; first_beat <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                ar_valid <= 1'b0;
                if (start) begin
                    mode <= cfg_ctrl[31:30];
                    lenc <= cfg_ctrl[29:28];
                    left <= (cfg_ctrl[15:0] == 16'd0) ? 16'd1 : cfg_ctrl[15:0];
                    addr <= cfg_base;
                    res_lat_min <= 32'hFFFF_FFFF; res_lat_max <= 32'd0; res_lat_sum <= 32'd0;
                    res_cycles <= 32'd0; res_beats <= 32'd0;
                    tot <= 32'd0; beats <= 32'd0; tmo_cnt <= 16'd0;
                    busy <= 1'b1; st <= S_AR;
                end
            end
            S_AR: begin
                tot      <= tot + 32'd1;
                ar_addr  <= addr;
                ar_len   <= len_of;
                ar_valid <= 1'b1;
                if (ar_valid && ar_ready) begin
                    ar_valid   <= 1'b0;
                    lat        <= 32'd0;
                    first_beat <= 1'b1;
                    st         <= S_R;
                end
            end
            S_R: begin
                tot <= tot + 32'd1;
                lat <= lat + 32'd1;
                if (r_valid) begin
                    beats <= beats + 32'd1;
                    if (first_beat) begin                    // FIRST-WORD latency: the number that matters
                        first_beat  <= 1'b0;
                        res_lat_sum <= res_lat_sum + lat;
                        if (lat < res_lat_min) res_lat_min <= lat;
                        if (lat > res_lat_max) res_lat_max <= lat;
                    end
                    if (r_last) begin
                        // next address per pattern
                        case (mode)
                        2'd0: addr <= addr + bytes_of;                          // SEQ
                        2'd1: addr <= addr + STRIDE_BYTES[31:0];                // STRIDE (row miss)
                        2'd2: begin addr <= (cfg_base & 32'hFF00_0000) |         // RANDOM in a 16 MB window
                                            ({1'b0, lfsr[23:0], 6'd0} & 32'h00FF_FFC0);
                                    lfsr <= lfsr_nx; end
                        default: addr <= cfg_base;                              // FIXED
                        endcase
                        if (left <= 16'd1) st <= S_FIN;
                        else begin left <= left - 16'd1; st <= S_AR; end
                    end
                end else if (lat > TIMEOUT_CYC[31:0]) begin   // dead region / no response
                    tmo_cnt <= tmo_cnt + 16'd1;
                    if (left <= 16'd1) st <= S_FIN;
                    else begin left <= left - 16'd1; st <= S_AR; end
                end
            end
            S_FIN: begin
                res_cycles <= tot;
                res_beats  <= beats;
                res_status <= {tmo_cnt, 1'b1 /*done*/, 1'b0 /*busy*/, mode, lenc, 10'd0};
                busy       <= 1'b0;
                st         <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
