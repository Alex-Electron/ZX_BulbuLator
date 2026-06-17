`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ddrfb_p1a_regs.v  -  GP0 AXI3 register slave for the Phase-1a DDR->HDMI test (control/readout).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Same proven AXI3-slave machinery as axi_ctl / hp_gp0_regs. Base = M_AXI_GP0 0x4000_0000, 32-bit:
//   0x00 VERSION   R   0xB01BDDF1
//   0x04 CONTROL   RW  bit0 LOAD_EN (default 1)
//   0x08 BASE      RW  DDR source-frame base (default 0x0FF0_0000)
//   0x0C FRAME_CNT R   loader-completed frames (liveness: must climb at ~50 Hz)
//   0x10 BEAT_CNT  R   total beats read (=words written; /8 = bytes)
//   0x14 STATUS    R   bit0 = loader busy
//-------------------------------------------------------------------------------------------------
module ddrfb_p1a_regs (
    input  wire        aclk,
    input  wire        aresetn,
    // ---- AXI3 GP0 slave ----
    input  wire [11:0] s_awid,  input  wire [31:0] s_awaddr, input wire [3:0] s_awlen,
    input  wire        s_awvalid, output reg s_awready,
    input  wire [31:0] s_wdata,  input  wire [3:0] s_wstrb,  input wire s_wlast,
    input  wire        s_wvalid,  output reg s_wready,
    output reg  [11:0] s_bid,    output reg [1:0] s_bresp,  output reg s_bvalid, input wire s_bready,
    input  wire [11:0] s_arid,   input  wire [31:0] s_araddr, input wire [3:0] s_arlen,
    input  wire        s_arvalid, output reg s_arready,
    output reg  [11:0] s_rid,    output reg [31:0] s_rdata,  output reg [1:0] s_rresp,
    output reg         s_rlast,   output reg s_rvalid, input wire s_rready,
    // ---- config (out) + status (in) ----
    output reg         cfg_load_en,
    output reg  [31:0] cfg_base,
    input  wire [31:0] frame_cnt,
    input  wire [31:0] beat_cnt,
    input  wire        busy
);
    localparam [31:0] VERSION = 32'hB01B_DDF1;

    // ---- write channel ----
    localparam W_IDLE=2'd0, W_DATA=2'd1, W_RESP=2'd2;
    reg [1:0]  wstate; reg [11:0] awid_q; reg [5:0] awidx_q;
    always @(posedge aclk) begin
        if (!aresetn) begin
            wstate<=W_IDLE; s_awready<=1'b0; s_wready<=1'b0; s_bvalid<=1'b0; s_bresp<=2'b00; s_bid<=12'd0;
            cfg_load_en<=1'b1; cfg_base<=32'h0FF0_0000;
        end else case (wstate)
            W_IDLE: begin
                s_bvalid<=1'b0; s_awready<=1'b1;
                if (s_awvalid && s_awready) begin awid_q<=s_awid; awidx_q<=s_awaddr[7:2]; s_awready<=1'b0; s_wready<=1'b1; wstate<=W_DATA; end
            end
            W_DATA: if (s_wvalid && s_wready) begin
                case (awidx_q)
                    6'h01: cfg_load_en <= s_wdata[0];
                    6'h02: cfg_base    <= s_wdata;
                    default: ;
                endcase
                if (s_wlast) begin s_wready<=1'b0; s_bid<=awid_q; s_bresp<=2'b00; s_bvalid<=1'b1; wstate<=W_RESP; end
            end
            W_RESP: if (s_bvalid && s_bready) begin s_bvalid<=1'b0; wstate<=W_IDLE; end
            default: wstate<=W_IDLE;
        endcase
    end

    // ---- read channel ----
    localparam R_IDLE=1'b0, R_DATA=1'b1;
    reg rstate; reg [11:0] arid_q; reg [5:0] aridx_q;
    always @(posedge aclk) begin
        if (!aresetn) begin
            rstate<=R_IDLE; s_arready<=1'b0; s_rvalid<=1'b0; s_rresp<=2'b00; s_rlast<=1'b0; s_rdata<=32'd0; s_rid<=12'd0;
        end else case (rstate)
            R_IDLE: begin
                s_rvalid<=1'b0; s_arready<=1'b1;
                if (s_arvalid && s_arready) begin arid_q<=s_arid; aridx_q<=s_araddr[7:2]; s_arready<=1'b0; rstate<=R_DATA; end
            end
            R_DATA: begin
                s_rid<=arid_q; s_rresp<=2'b00; s_rlast<=1'b1;
                case (aridx_q)
                    6'h00: s_rdata <= VERSION;
                    6'h01: s_rdata <= {31'd0, cfg_load_en};
                    6'h02: s_rdata <= cfg_base;
                    6'h03: s_rdata <= frame_cnt;
                    6'h04: s_rdata <= beat_cnt;
                    6'h05: s_rdata <= {31'd0, busy};
                    default: s_rdata <= 32'hDEAD_BEEF;
                endcase
                s_rvalid<=1'b1;
                if (s_rvalid && s_rready) begin s_rvalid<=1'b0; s_rlast<=1'b0; rstate<=R_IDLE; end
            end
            default: rstate<=R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
