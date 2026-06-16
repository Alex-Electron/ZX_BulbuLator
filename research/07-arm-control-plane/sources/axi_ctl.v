`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// axi_ctl.v  -  BulbuLator Stage-1 control plane (AXI3 slave on Zynq-7010 M_AXI_GP0).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM (PS) reaches the Spectrum (PL) through this register file. Milestone 2 scope:
// HALT the Z80 + write Spectrum RAM (so the ARM can draw on the screen; the .sna loader and
// Z80-register injection grow from the same map later).
//
// Register map (base = M_AXI_GP0 0x4000_0000), AXI3, 32-bit, 12-bit ID, single-beat:
//   0x00 VERSION  R   0xB01B0002
//   0x04 CONTROL  RW  bit0 HALT (1 = freeze the Z80; ARM owns the memory bus)
//   0x08 STATUS   R   bit0 HALT_ACK (CPU frozen, safe to write), bit1 RAM_BUSY
//   0x0C COUNTER  R   free-running aclk counter (liveness)
//   0x10 RAM_ADDR RW  17-bit Spectrum RAM byte address; auto-increments after each RAM_DATA write
//   0x14 RAM_DATA W   write byte -> RAM[RAM_ADDR] (via CDC to the Spectrum clock), then RAM_ADDR++
//   0x18 SCRATCH  RW  spare 32-bit (sanity)
//
// This module is purely in the AXI clock domain (aclk = FCLK0). The clock-domain crossing into
// the ~56.7 MHz Spectrum domain (the actual RAM write strobe + the halt level) lives in
// inject_cdc.v. Here we only expose aclk-domain control/handshake signals.
//-------------------------------------------------------------------------------------------------
module axi_ctl #(
    parameter [31:0] VERSION = 32'hB01B0002
)(
    input  wire        aclk,
    input  wire        aresetn,

    // ---- AXI3 write address ----
    input  wire [11:0] s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire        s_awvalid,
    output reg         s_awready,
    // ---- AXI3 write data ----
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,
    // ---- AXI3 write response ----
    output reg  [11:0] s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    // ---- AXI3 read address ----
    input  wire [11:0] s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,
    // ---- AXI3 read data ----
    output reg  [11:0] s_rid,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ---- control-plane interface (aclk domain), to inject_cdc ----
    output reg         ctl_halt,        // CONTROL[0]
    output reg         ctl_ram_we,      // 1-aclk pulse: a RAM byte write was issued
    output reg  [16:0] ctl_ram_addr,    // running RAM_ADDR pointer (post-increment, for readback)
    output reg  [16:0] ctl_ram_waddr,   // address of THIS write (pre-increment) - what the CDC latches
    output reg  [7:0]  ctl_ram_data,    // the byte to write
    input  wire        halt_ack,        // from spclk side (synced)
    input  wire        ram_busy         // from spclk side (synced)
);
    localparam IDX_VERSION = 6'h00, IDX_CONTROL = 6'h01, IDX_STATUS = 6'h02,
               IDX_COUNTER = 6'h03, IDX_RAMADDR = 6'h04, IDX_RAMDATA = 6'h05,
               IDX_SCRATCH = 6'h06;

    reg [31:0] counter;
    reg [31:0] reg_scratch;
    always @(posedge aclk) counter <= aresetn ? counter + 32'd1 : 32'd0;

    //---------------------------------------------------------------------------------------------
    // Write channel.
    //---------------------------------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;
    reg [1:0]  wstate;
    reg [11:0] awid_q;
    reg [5:0]  awidx_q;

    always @(posedge aclk) begin
        ctl_ram_we <= 1'b0;                     // default: one-cycle pulse
        if (!aresetn) begin
            wstate      <= W_IDLE;
            s_awready   <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
            s_bresp     <= 2'b00; s_bid <= 12'd0;
            ctl_halt     <= 1'b0;
            ctl_ram_addr <= 17'd0;
            ctl_ram_waddr<= 17'd0;
            ctl_ram_data <= 8'd0;
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
                            IDX_CONTROL: ctl_halt     <= s_wdata[0];
                            IDX_RAMADDR: ctl_ram_addr <= s_wdata[16:0];
                            IDX_RAMDATA: begin
                                ctl_ram_data  <= s_wdata[7:0];
                                ctl_ram_we    <= 1'b1;                 // issue the RAM write
                                ctl_ram_waddr <= ctl_ram_addr;         // THIS write's address (pre-increment)
                                ctl_ram_addr  <= ctl_ram_addr + 17'd1; // advance the pointer
                            end
                            IDX_SCRATCH: reg_scratch  <= s_wdata;
                            default: ;
                        endcase
                        if (s_wlast) begin
                            s_wready <= 1'b0;
                            s_bid    <= awid_q;
                            s_bresp  <= 2'b00;
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
    // Read channel.
    //---------------------------------------------------------------------------------------------
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;
    reg        rstate;
    reg [11:0] arid_q;
    reg [5:0]  aridx_q;

    always @(posedge aclk) begin
        if (!aresetn) begin
            rstate <= R_IDLE; s_arready <= 1'b0; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rlast <= 1'b0; s_rdata <= 32'd0; s_rid <= 12'd0;
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
                    s_rresp <= 2'b00;
                    s_rlast <= 1'b1;
                    case (aridx_q)
                        IDX_VERSION: s_rdata <= VERSION;
                        IDX_CONTROL: s_rdata <= {31'd0, ctl_halt};
                        IDX_STATUS:  s_rdata <= {30'd0, ram_busy, halt_ack};
                        IDX_COUNTER: s_rdata <= counter;
                        IDX_RAMADDR: s_rdata <= {15'd0, ctl_ram_addr};
                        IDX_SCRATCH: s_rdata <= reg_scratch;
                        default:     s_rdata <= 32'hDEADBEEF;
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
