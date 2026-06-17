`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// axi_ctl.v  -  BulbuLator Stage-1 control plane (AXI3 slave on Zynq-7010 M_AXI_GP0).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM (PS) reaches the Spectrum (PL) through this register file: HALT the Z80, write RAM,
// inject Z80 registers (T80 DIR vector) and machine ports (7FFD / border) -> load .sna/.z80.
//
// Register map (base = M_AXI_GP0 0x4000_0000), AXI3, 32-bit, single-beat:
//   0x00 VERSION   R   0xB01B0004
//   0x04 CONTROL   RW  bit0 HALT (1 = freeze the Z80; ARM owns the memory bus)
//   0x08 STATUS    R   bit0 HALT_ACK, bit1 RAM_BUSY
//   0x0C COUNTER   R   free-running aclk counter (liveness)
//   0x10 RAM_ADDR  RW  17-bit Spectrum RAM byte address; auto-increments after each RAM_DATA write
//   0x14 RAM_DATA  W   byte -> RAM[RAM_ADDR], RAM_ADDR++
//   0x18 SCRATCH   RW  spare
//   0x20..0x38 DIR0..DIR6  RW  the 212-bit T80 register-injection vector (7 words; DIR6 = top 20b)
//   0x3C PORT_7FFD RW  bits[5:0] = 128K paging port value
//   0x40 PORT_FE   RW  bits[2:0] = border
//   0x44 COMMIT    W   bit0 = PORT_COMMIT (apply 7FFD+border), bit1 = DIR_COMMIT (pulse DIRSet)
//
// Purely aclk (FCLK0). The crossing into the Spectrum clock (HALT level, RAM write strobe, the
// DIRSet pulse, the port-force pulses) lives in inject_cdc.v.
//-------------------------------------------------------------------------------------------------
module axi_ctl #(
    parameter [31:0] VERSION = 32'hB01B0004
)(
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

    // ---- control-plane interface (aclk domain) ----
    output reg         ctl_halt,
    output reg         ctl_ram_we,        // 1-aclk pulse
    output reg  [16:0] ctl_ram_addr,      // running pointer (post-inc; for readback)
    output reg  [16:0] ctl_ram_waddr,     // this write's address (pre-inc; what the CDC latches)
    output reg  [7:0]  ctl_ram_data,
    output reg  [211:0] ctl_dir,          // Z80 register-injection vector
    output reg  [5:0]  ctl_7ffd,
    output reg  [2:0]  ctl_border,
    output reg         ctl_dir_commit,    // 1-aclk pulse
    output reg         ctl_port_commit,   // 1-aclk pulse
    input  wire        halt_ack,
    input  wire        ram_busy
);
    localparam IDX_VERSION = 6'h00, IDX_CONTROL = 6'h01, IDX_STATUS = 6'h02,
               IDX_COUNTER = 6'h03, IDX_RAMADDR = 6'h04, IDX_RAMDATA = 6'h05,
               IDX_SCRATCH = 6'h06,
               IDX_DIR0    = 6'h08, // 0x20..0x38 = DIR0..DIR6
               IDX_P7FFD   = 6'h0F, // 0x3C
               IDX_PFE     = 6'h10, // 0x40
               IDX_COMMIT  = 6'h11; // 0x44

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
        ctl_ram_we      <= 1'b0;       // default: one-cycle pulses
        ctl_dir_commit  <= 1'b0;
        ctl_port_commit <= 1'b0;
        if (!aresetn) begin
            wstate <= W_IDLE; s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
            s_bresp <= 2'b00; s_bid <= 12'd0;
            ctl_halt <= 1'b0; ctl_ram_addr <= 17'd0; ctl_ram_waddr <= 17'd0; ctl_ram_data <= 8'd0;
            ctl_dir <= 212'd0; ctl_7ffd <= 6'd0; ctl_border <= 3'd0; reg_scratch <= 32'd0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    s_bvalid <= 1'b0; s_awready <= 1'b1;
                    if (s_awvalid && s_awready) begin
                        awid_q <= s_awid; awidx_q <= s_awaddr[7:2];
                        s_awready <= 1'b0; s_wready <= 1'b1; wstate <= W_DATA;
                    end
                end
                W_DATA: if (s_wvalid && s_wready) begin
                    case (awidx_q)
                        IDX_CONTROL: ctl_halt <= s_wdata[0];
                        IDX_RAMADDR: ctl_ram_addr <= s_wdata[16:0];
                        IDX_RAMDATA: begin
                            ctl_ram_data  <= s_wdata[7:0];
                            ctl_ram_we    <= 1'b1;
                            ctl_ram_waddr <= ctl_ram_addr;
                            ctl_ram_addr  <= ctl_ram_addr + 17'd1;
                        end
                        IDX_SCRATCH: reg_scratch <= s_wdata;
                        6'h08: ctl_dir[ 31:  0] <= s_wdata;          // DIR0
                        6'h09: ctl_dir[ 63: 32] <= s_wdata;          // DIR1
                        6'h0A: ctl_dir[ 95: 64] <= s_wdata;          // DIR2
                        6'h0B: ctl_dir[127: 96] <= s_wdata;          // DIR3
                        6'h0C: ctl_dir[159:128] <= s_wdata;          // DIR4
                        6'h0D: ctl_dir[191:160] <= s_wdata;          // DIR5
                        6'h0E: ctl_dir[211:192] <= s_wdata[19:0];    // DIR6 (top 20 bits)
                        IDX_P7FFD: ctl_7ffd   <= s_wdata[5:0];
                        IDX_PFE:   ctl_border <= s_wdata[2:0];
                        IDX_COMMIT: begin
                            ctl_port_commit <= s_wdata[0];
                            ctl_dir_commit  <= s_wdata[1];
                        end
                        default: ;
                    endcase
                    if (s_wlast) begin
                        s_wready <= 1'b0; s_bid <= awid_q; s_bresp <= 2'b00;
                        s_bvalid <= 1'b1; wstate <= W_RESP;
                    end
                end
                W_RESP: if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; wstate <= W_IDLE; end
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
        end else case (rstate)
            R_IDLE: begin
                s_rvalid <= 1'b0; s_arready <= 1'b1;
                if (s_arvalid && s_arready) begin
                    arid_q <= s_arid; aridx_q <= s_araddr[7:2];
                    s_arready <= 1'b0; rstate <= R_DATA;
                end
            end
            R_DATA: begin
                s_rid <= arid_q; s_rresp <= 2'b00; s_rlast <= 1'b1;
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
                if (s_rvalid && s_rready) begin s_rvalid <= 1'b0; s_rlast <= 1'b0; rstate <= R_IDLE; end
            end
            default: rstate <= R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
