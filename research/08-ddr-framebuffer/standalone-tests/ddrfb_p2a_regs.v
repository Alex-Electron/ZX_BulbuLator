`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ddrfb_p2a_regs.v  -  GP0 AXI3 readout for Phase-2a (capture path + triple buffer).
// Contact: lavrinovich.alex@gmail.com
//   0x00 VERSION    R   0xB01BDDF3
//   0x0C LD_FRAMES  R   loader frames (HDMI side)
//   0x18 WR_FRAMES  R   writer frames (capture side)
//   0x1C BUFSTATE   R   {.., ready_buf[1:0], disp_buf[1:0], wr_buf[1:0]}
//   0x20 FIFO_MAX   R   high-water mark of the capture FIFO (debug)
//-------------------------------------------------------------------------------------------------
module ddrfb_p2a_regs (
    input  wire        aclk, aresetn,
    input  wire [11:0] s_awid,  input  wire [31:0] s_awaddr, input wire [3:0] s_awlen,
    input  wire        s_awvalid, output reg s_awready,
    input  wire [31:0] s_wdata,  input  wire [3:0] s_wstrb,  input wire s_wlast,
    input  wire        s_wvalid,  output reg s_wready,
    output reg  [11:0] s_bid,    output reg [1:0] s_bresp,  output reg s_bvalid, input wire s_bready,
    input  wire [11:0] s_arid,   input  wire [31:0] s_araddr, input wire [3:0] s_arlen,
    input  wire        s_arvalid, output reg s_arready,
    output reg  [11:0] s_rid,    output reg [31:0] s_rdata,  output reg [1:0] s_rresp,
    output reg         s_rlast,   output reg s_rvalid, input wire s_rready,
    input  wire [31:0] ld_frames,
    input  wire [31:0] wr_frames,
    input  wire [1:0]  wr_buf, disp_buf, ready_buf,
    input  wire [15:0] fifo_max
);
    localparam [31:0] VERSION = 32'hB01B_DDF3;
    localparam W_IDLE=2'd0, W_DATA=2'd1, W_RESP=2'd2;
    reg [1:0] wstate; reg [11:0] awid_q;
    always @(posedge aclk) begin
        if (!aresetn) begin wstate<=W_IDLE; s_awready<=1'b0; s_wready<=1'b0; s_bvalid<=1'b0; s_bresp<=2'b00; s_bid<=12'd0;
        end else case (wstate)
            W_IDLE: begin s_bvalid<=1'b0; s_awready<=1'b1;
                if (s_awvalid&&s_awready) begin awid_q<=s_awid; s_awready<=1'b0; s_wready<=1'b1; wstate<=W_DATA; end end
            W_DATA: if (s_wvalid&&s_wready) begin
                if (s_wlast) begin s_wready<=1'b0; s_bid<=awid_q; s_bresp<=2'b00; s_bvalid<=1'b1; wstate<=W_RESP; end end
            W_RESP: if (s_bvalid&&s_bready) begin s_bvalid<=1'b0; wstate<=W_IDLE; end
            default: wstate<=W_IDLE;
        endcase
    end
    localparam R_IDLE=1'b0, R_DATA=1'b1;
    reg rstate; reg [11:0] arid_q; reg [5:0] aridx_q;
    always @(posedge aclk) begin
        if (!aresetn) begin rstate<=R_IDLE; s_arready<=1'b0; s_rvalid<=1'b0; s_rresp<=2'b00; s_rlast<=1'b0; s_rdata<=32'd0; s_rid<=12'd0;
        end else case (rstate)
            R_IDLE: begin s_rvalid<=1'b0; s_arready<=1'b1;
                if (s_arvalid&&s_arready) begin arid_q<=s_arid; aridx_q<=s_araddr[7:2]; s_arready<=1'b0; rstate<=R_DATA; end end
            R_DATA: begin s_rid<=arid_q; s_rresp<=2'b00; s_rlast<=1'b1;
                case (aridx_q)
                    6'h00: s_rdata <= VERSION;
                    6'h03: s_rdata <= ld_frames;
                    6'h06: s_rdata <= wr_frames;
                    6'h07: s_rdata <= {26'd0, ready_buf, disp_buf, wr_buf};
                    6'h08: s_rdata <= {16'd0, fifo_max};
                    default: s_rdata <= 32'hDEAD_BEEF;
                endcase
                s_rvalid<=1'b1;
                if (s_rvalid&&s_rready) begin s_rvalid<=1'b0; s_rlast<=1'b0; rstate<=R_IDLE; end end
            default: rstate<=R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
