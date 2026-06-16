`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// axi_ctl.v
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// BulbuLator Stage-1 control plane - milestone slave.
//
// A small AXI3 slave for the Zynq-7010 M_AXI_GP0 master (32-bit data, 12-bit ID, 4-bit LEN).
// For Milestone 1 it implements only four registers so a bare-metal `xsdb mrd/mwr` round-trip
// proves the whole PS->PL path (AW/W/B/AR/R) on our bare-PS7 pure-RTL flow, BEFORE any
// Spectrum logic is touched. The register block then grows into the real control plane
// (HALT/STATUS/RAM window/DIR injection) - so the AXI handshake here is the foundation,
// not throwaway.
//
// Register map (base = M_AXI_GP0 0x4000_0000), word-addressed:
//   0x00  VERSION   R   0xB01B0001  (proves reads return PL data, not a bus error)
//   0x04  CONTROL   RW  bit0 -> led (visual proof of the write path); read-back proves latch
//   0x08  SCRATCH   RW  full 32-bit scratch (proves the 32-bit data path both directions)
//   0x0C  COUNTER   R   free-running fclk counter (proves the slave is clocked & alive)
//
// Only single-beat transfers are expected (register access); the FSMs latch AxID and assert
// xLAST so AXI3 ordering is satisfied. Bursts are not the use case for a register file.
//-------------------------------------------------------------------------------------------------
module axi_ctl #(
    parameter [31:0] VERSION = 32'hB01B0001
)(
    input  wire        aclk,
    input  wire        aresetn,      // active-low

    // ---- write address channel ----
    input  wire [11:0] s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,      // AXI3 (ignored: single-beat register writes)
    input  wire        s_awvalid,
    output reg         s_awready,
    // ---- write data channel ----
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,      // (ignored: full-word register writes)
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,
    // ---- write response channel ----
    output reg  [11:0] s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    // ---- read address channel ----
    input  wire [11:0] s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,      // AXI3 (ignored: single-beat register reads)
    input  wire        s_arvalid,
    output reg         s_arready,
    // ---- read data channel ----
    output reg  [11:0] s_rid,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ---- user side ----
    output wire        led          // CONTROL[0]
);
    //---------------------------------------------------------------------------------------------
    // Register storage + a free-running liveness counter.
    //---------------------------------------------------------------------------------------------
    reg [31:0] reg_control;
    reg [31:0] reg_scratch;
    reg [31:0] counter;
    always @(posedge aclk) begin
        if (!aresetn) counter <= 32'd0;
        else          counter <= counter + 32'd1;
    end
    assign led = reg_control[0];

    //---------------------------------------------------------------------------------------------
    // Write channel FSM (independent of read, so the slave is full-duplex).
    //---------------------------------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;
    reg [1:0]  wstate;
    reg [11:0] awid_q;
    reg [5:0]  awidx_q;    // word index = AWADDR[7:2]

    always @(posedge aclk) begin
        if (!aresetn) begin
            wstate      <= W_IDLE;
            s_awready   <= 1'b0;
            s_wready    <= 1'b0;
            s_bvalid    <= 1'b0;
            s_bresp     <= 2'b00;
            s_bid       <= 12'd0;
            reg_control <= 32'd0;
            reg_scratch <= 32'd0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    s_bvalid  <= 1'b0;
                    s_awready <= 1'b1;
                    if (s_awvalid && s_awready) begin
                        awid_q    <= s_awid;
                        awidx_q   <= s_awaddr[7:2];
                        s_awready <= 1'b0;
                        s_wready  <= 1'b1;
                        wstate    <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (s_wvalid && s_wready) begin
                        case (awidx_q)
                            6'h01: reg_control <= s_wdata;   // 0x04 CONTROL
                            6'h02: reg_scratch <= s_wdata;   // 0x08 SCRATCH
                            default: ;                       // VERSION / COUNTER read-only
                        endcase
                        if (s_wlast) begin
                            s_wready <= 1'b0;
                            s_bid    <= awid_q;
                            s_bresp  <= 2'b00;               // OKAY
                            s_bvalid <= 1'b1;
                            wstate   <= W_RESP;
                        end
                    end
                end
                W_RESP: begin
                    if (s_bvalid && s_bready) begin
                        s_bvalid <= 1'b0;
                        wstate   <= W_IDLE;
                    end
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    //---------------------------------------------------------------------------------------------
    // Read channel FSM.
    //---------------------------------------------------------------------------------------------
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;
    reg        rstate;
    reg [11:0] arid_q;
    reg [5:0]  aridx_q;

    always @(posedge aclk) begin
        if (!aresetn) begin
            rstate    <= R_IDLE;
            s_arready <= 1'b0;
            s_rvalid  <= 1'b0;
            s_rresp   <= 2'b00;
            s_rlast   <= 1'b0;
            s_rdata   <= 32'd0;
            s_rid     <= 12'd0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    s_rvalid  <= 1'b0;
                    s_arready <= 1'b1;
                    if (s_arvalid && s_arready) begin
                        arid_q    <= s_arid;
                        aridx_q   <= s_araddr[7:2];
                        s_arready <= 1'b0;
                        rstate    <= R_DATA;
                    end
                end
                R_DATA: begin
                    s_rid   <= arid_q;
                    s_rresp <= 2'b00;                        // OKAY
                    s_rlast <= 1'b1;                         // single beat
                    case (aridx_q)
                        6'h00:   s_rdata <= VERSION;         // 0x00 VERSION
                        6'h01:   s_rdata <= reg_control;     // 0x04 CONTROL
                        6'h02:   s_rdata <= reg_scratch;     // 0x08 SCRATCH
                        6'h03:   s_rdata <= counter;         // 0x0C COUNTER
                        default: s_rdata <= 32'hDEADBEEF;
                    endcase
                    s_rvalid <= 1'b1;
                    if (s_rvalid && s_rready) begin
                        s_rvalid <= 1'b0;
                        s_rlast  <= 1'b0;
                        rstate   <= R_IDLE;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
