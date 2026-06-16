`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// inject_cdc.v  -  clock-domain crossing for the ARM control plane.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Bridges axi_ctl (aclk = FCLK0, 100 MHz) into the Spectrum clock domain (spclk, ~56.7 MHz):
//   * HALT level  : aclk -> spclk, 2-FF synchroniser -> cpu_halt_sp (gates the core's 3.5 MHz
//                   clock-enables in the top, and selects the ARM onto the memory bus).
//   * RAM write   : each ctl_ram_we pulse latches {addr,data} and toggles a request bit; the
//                   spclk side edge-detects the toggle and emits ONE spclk write strobe with
//                   the (multi-cycle-stable) address/data, then toggles an ack back.
//   * HALT_ACK    : spclk asserts after the CPU has been frozen a few cycles; synced back to aclk.
//
// {addr,data} cross as a classic toggle-synchronised multi-cycle path: they are held stable in
// the aclk domain from one ctl_ram_we to the next, and the spclk side only samples them after
// the request toggle has propagated through its 2-FF synchroniser. Constrain them false-path /
// max-delay in the XDC. The slow xsdb/JTAG write cadence (and later the ram_busy handshake) keeps
// successive writes well separated, so no request is lost.
//-------------------------------------------------------------------------------------------------
module inject_cdc
(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        spclk,

    // from axi_ctl (aclk domain)
    input  wire        ctl_halt,
    input  wire        ctl_ram_we,
    input  wire [16:0] ctl_ram_addr,
    input  wire [7:0]  ctl_ram_data,

    // status back to axi_ctl (aclk domain)
    output reg         halt_ack,
    output reg         ram_busy,

    // to the core / memory mux (spclk domain)
    output reg         cpu_halt_sp,
    output reg         arm_memWr,
    output reg  [18:0] arm_memA,
    output reg  [7:0]  arm_memQ,
    output reg  [13:0] arm_vmmA2
);
    //---------------------------------------------------------------------------------------------
    // aclk: latch the RAM write payload + toggle a request bit.
    //---------------------------------------------------------------------------------------------
    reg        req_tog  = 1'b0;
    reg [16:0] addr_lat = 17'd0;
    reg [7:0]  data_lat = 8'd0;
    always @(posedge aclk) begin
        if (!aresetn) req_tog <= 1'b0;
        else if (ctl_ram_we) begin
            addr_lat <= ctl_ram_addr;
            data_lat <= ctl_ram_data;
            req_tog  <= ~req_tog;
        end
    end

    //---------------------------------------------------------------------------------------------
    // spclk: sync HALT, edge-detect the request, emit one write strobe, settle HALT_ACK.
    //---------------------------------------------------------------------------------------------
    reg [1:0] halt_sync = 2'd0;
    reg [2:0] req_sync  = 3'd0;
    reg       ack_tog   = 1'b0;
    reg [3:0] hcnt      = 4'd0;
    reg       halt_ack_sp = 1'b0;
    wire      req_edge  = req_sync[2] ^ req_sync[1];

    initial begin cpu_halt_sp = 1'b0; arm_memWr = 1'b0; arm_memA = 19'd0; arm_memQ = 8'd0; arm_vmmA2 = 14'd0; end

    always @(posedge spclk) begin
        halt_sync   <= {halt_sync[0], ctl_halt};
        cpu_halt_sp <= halt_sync[1];
        req_sync    <= {req_sync[1:0], req_tog};

        arm_memWr <= 1'b0;
        if (req_edge) begin
            arm_memWr <= 1'b1;
            arm_memA  <= {2'b01, addr_lat};   // RAM region (memA[18:17]=01)
            arm_memQ  <= data_lat;
            arm_vmmA2 <= addr_lat[13:0];      // screen-shadow offset within the 16K bank
            ack_tog   <= ~ack_tog;
        end

        if (!cpu_halt_sp)      begin hcnt <= 4'd0; halt_ack_sp <= 1'b0; end
        else if (hcnt != 4'hF) hcnt <= hcnt + 4'd1;
        else                   halt_ack_sp <= 1'b1;
    end

    //---------------------------------------------------------------------------------------------
    // aclk: sync ack + halt_ack back, drive ram_busy.
    //---------------------------------------------------------------------------------------------
    reg [2:0] ack_sync  = 3'd0;
    reg [1:0] hack_sync = 2'd0;
    always @(posedge aclk) begin
        ack_sync  <= {ack_sync[1:0], ack_tog};
        hack_sync <= {hack_sync[0], halt_ack_sp};
        halt_ack  <= hack_sync[1];
        if (!aresetn)                          ram_busy <= 1'b0;
        else if (ctl_ram_we)                   ram_busy <= 1'b1;
        else if (ack_sync[2] ^ ack_sync[1])    ram_busy <= 1'b0;
    end
endmodule
//-------------------------------------------------------------------------------------------------
