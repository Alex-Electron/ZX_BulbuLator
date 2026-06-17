`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// inject_cdc.v  -  clock-domain crossing for the ARM control plane.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Bridges axi_ctl (aclk = FCLK0, 100 MHz) into the Spectrum clock domain (spclk, ~56.7 MHz):
//   * HALT level     : 2-FF sync -> cpu_halt_sp.
//   * RAM write      : ctl_ram_we toggle -> one-spclk arm_memWr + arm_memA/memQ/vmmA2.
//   * DIR commit     : ctl_dir_commit toggle -> one-spclk dir_set_sp pulse; cpu_dir_sp holds the
//                      212-bit vector (the T80 latches DIR on a raw spclk edge while halted).
//   * PORT commit    : ctl_port_commit toggle -> one-spclk force_7ffd_sp + force_border_sp;
//                      port7ffd_sp/border_sp hold the values.
// All payloads (addr/data/dir/7ffd/border) are MCP-stable (held in aclk between commits) and
// cross as toggle-synced multi-cycle data -> false-path them in the XDC. The DIR/port pulses are
// gated by cpu_halt_sp so they only act while the Z80 is frozen.
//-------------------------------------------------------------------------------------------------
module inject_cdc
(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        spclk,

    // from axi_ctl (aclk)
    input  wire        ctl_halt,
    input  wire        ctl_ram_we,
    input  wire [16:0] ctl_ram_addr,     // pre-increment write address (ctl_ram_waddr)
    input  wire [7:0]  ctl_ram_data,
    input  wire        ctl_dir_commit,
    input  wire        ctl_port_commit,
    input  wire [211:0] ctl_dir,
    input  wire [5:0]  ctl_7ffd,
    input  wire [2:0]  ctl_border,

    // status back (aclk)
    output reg         halt_ack,
    output reg         ram_busy,

    // to core / memory mux (spclk)
    output reg         cpu_halt_sp,
    output reg         arm_memWr,
    output reg  [18:0] arm_memA,
    output reg  [7:0]  arm_memQ,
    output reg  [13:0] arm_vmmA2,
    output reg         dir_set_sp,
    output reg  [211:0] cpu_dir_sp,
    output reg         force_7ffd_sp,
    output reg  [5:0]  port7ffd_sp,
    output reg         force_border_sp,
    output reg  [2:0]  border_sp
);
    //---------------------------------------------------------------------------------------------
    // aclk: latch payloads + toggle a request bit per action.
    //---------------------------------------------------------------------------------------------
    reg        req_tog  = 1'b0;
    reg [16:0] addr_lat = 17'd0;
    reg [7:0]  data_lat = 8'd0;
    reg        dcom_tog = 1'b0, pcom_tog = 1'b0;
    reg [211:0] dir_lat = 212'd0;
    reg [5:0]  p7_lat   = 6'd0;
    reg [2:0]  bd_lat   = 3'd0;
    always @(posedge aclk) begin
        if (!aresetn) begin req_tog <= 1'b0; dcom_tog <= 1'b0; pcom_tog <= 1'b0; end
        else begin
            if (ctl_ram_we)      begin addr_lat <= ctl_ram_addr; data_lat <= ctl_ram_data; req_tog <= ~req_tog; end
            if (ctl_dir_commit)  begin dir_lat  <= ctl_dir; dcom_tog <= ~dcom_tog; end
            if (ctl_port_commit) begin p7_lat   <= ctl_7ffd; bd_lat <= ctl_border; pcom_tog <= ~pcom_tog; end
        end
    end

    //---------------------------------------------------------------------------------------------
    // spclk: sync HALT + the toggles; emit one-cycle strobes; hold the payloads.
    //---------------------------------------------------------------------------------------------
    reg [1:0] halt_sync = 2'd0;
    reg [2:0] req_sync = 3'd0, dsync = 3'd0, psync = 3'd0;
    reg       ack_tog  = 1'b0;
    reg [3:0] hcnt     = 4'd0;
    reg       halt_ack_sp = 1'b0;
    wire      req_edge = req_sync[2] ^ req_sync[1];

    initial begin
        cpu_halt_sp=1'b0; arm_memWr=1'b0; arm_memA=19'd0; arm_memQ=8'd0; arm_vmmA2=14'd0;
        dir_set_sp=1'b0; cpu_dir_sp=212'd0; force_7ffd_sp=1'b0; port7ffd_sp=6'd0; force_border_sp=1'b0; border_sp=3'd0;
    end

    always @(posedge spclk) begin
        halt_sync   <= {halt_sync[0], ctl_halt};
        cpu_halt_sp <= halt_sync[1];
        req_sync    <= {req_sync[1:0], req_tog};
        dsync       <= {dsync[1:0], dcom_tog};
        psync       <= {psync[1:0], pcom_tog};

        // hold the injection payloads continuously; the single pulses below sample them
        cpu_dir_sp  <= dir_lat;
        port7ffd_sp <= p7_lat;
        border_sp   <= bd_lat;

        arm_memWr       <= 1'b0;
        dir_set_sp      <= 1'b0;
        force_7ffd_sp   <= 1'b0;
        force_border_sp <= 1'b0;

        if (req_edge) begin
            arm_memWr <= 1'b1;
            arm_memA  <= {2'b01, addr_lat};
            arm_memQ  <= data_lat;
            arm_vmmA2 <= {addr_lat[15], addr_lat[12:0]};
            ack_tog   <= ~ack_tog;
        end
        if (cpu_halt_sp) begin
            if (dsync[2] ^ dsync[1]) dir_set_sp <= 1'b1;
            if (psync[2] ^ psync[1]) begin force_7ffd_sp <= 1'b1; force_border_sp <= 1'b1; end
        end

        if (!cpu_halt_sp)      begin hcnt <= 4'd0; halt_ack_sp <= 1'b0; end
        else if (hcnt != 4'hF) hcnt <= hcnt + 4'd1;
        else                   halt_ack_sp <= 1'b1;
    end

    //---------------------------------------------------------------------------------------------
    // aclk: sync ack + halt_ack, drive ram_busy.
    //---------------------------------------------------------------------------------------------
    reg [2:0] ack_sync  = 3'd0;
    reg [1:0] hack_sync = 2'd0;
    always @(posedge aclk) begin
        ack_sync  <= {ack_sync[1:0], ack_tog};
        hack_sync <= {hack_sync[0], halt_ack_sp};
        halt_ack  <= hack_sync[1];
        if (!aresetn)                       ram_busy <= 1'b0;
        else if (ctl_ram_we)                ram_busy <= 1'b1;
        else if (ack_sync[2] ^ ack_sync[1]) ram_busy <= 1'b0;
    end
endmodule
//-------------------------------------------------------------------------------------------------
