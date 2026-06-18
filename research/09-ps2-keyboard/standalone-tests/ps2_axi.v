`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ps2_axi.v  -  read-only AXI3 slave on Zynq-7010 M_AXI_GP0, for the PS/2 keyboard read test.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
//   0x00 VERSION R  0xB01B0009
//   0x04 STATUS  R  {8'b0, count[15:0], scancode[7:0]}   (latched from the ps2 receiver, aclk)
// The read channel mirrors the proven axi_ctl.v. Writes are accepted and dropped so a stray
// write can never hang the GP0 bus. Pure aclk (FCLK0).
//-------------------------------------------------------------------------------------------------
module ps2_axi #( parameter [31:0] VERSION = 32'hB01B0009 )
(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [11:0] s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [11:0] s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [11:0] s_rid,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

    input  wire [31:0] ps2_status        // {8'b0, count[15:0], scancode[7:0]}
);
    localparam IDX_VERSION = 6'h00, IDX_STATUS = 6'h01;

    //---------------------------------------------------------------------------------------------
    // Write channel: accept the address + data, return OKAY, ignore the payload.
    //---------------------------------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;
    reg [1:0]  wstate;
    reg [11:0] awid_q;
    always @(posedge aclk) begin
        if (!aresetn) begin
            wstate <= W_IDLE; s_awready <= 1'b0; s_wready <= 1'b0;
            s_bvalid <= 1'b0; s_bresp <= 2'b00; s_bid <= 12'd0;
        end else case (wstate)
            W_IDLE: begin
                s_bvalid <= 1'b0; s_awready <= 1'b1;
                if (s_awvalid && s_awready) begin
                    awid_q <= s_awid; s_awready <= 1'b0; s_wready <= 1'b1; wstate <= W_DATA;
                end
            end
            W_DATA: if (s_wvalid && s_wready && s_wlast) begin
                s_wready <= 1'b0; s_bid <= awid_q; s_bresp <= 2'b00; s_bvalid <= 1'b1; wstate <= W_RESP;
            end
            W_RESP: if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; wstate <= W_IDLE; end
            default: wstate <= W_IDLE;
        endcase
    end

    //---------------------------------------------------------------------------------------------
    // Read channel (verbatim shape from axi_ctl.v).
    //---------------------------------------------------------------------------------------------
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;
    reg        rstate;
    reg [11:0] arid_q;
    reg [5:0]  aridx_q;
    always @(posedge aclk) begin
        if (!aresetn) begin
            rstate <= R_IDLE; s_arready <= 1'b0; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rlast <= 1'b0; s_rdata <= 32'd0; s_rid <= 12'd0;
        end else case (rstate)
            R_IDLE: begin
                s_rvalid <= 1'b0; s_arready <= 1'b1;
                if (s_arvalid && s_arready) begin
                    arid_q <= s_arid; aridx_q <= s_araddr[7:2]; s_arready <= 1'b0; rstate <= R_DATA;
                end
            end
            R_DATA: begin
                s_rid <= arid_q; s_rresp <= 2'b00; s_rlast <= 1'b1;
                case (aridx_q)
                    IDX_VERSION: s_rdata <= VERSION;
                    IDX_STATUS:  s_rdata <= ps2_status;
                    default:     s_rdata <= 32'hDEADBEEF;
                endcase
                s_rvalid <= 1'b1;
                if (s_rvalid && s_rready) begin s_rvalid <= 1'b0; s_rlast <= 1'b0; rstate <= R_IDLE; end
            end
            default: rstate <= R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
