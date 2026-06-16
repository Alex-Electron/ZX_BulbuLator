`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// bulb_axi_test_top.v
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// BulbuLator Stage-1, Milestone 1: bare-metal AXI handshake test (NO Spectrum logic).
//
// PS7 FCLK0 (100 MHz) + the M_AXI_GP0 master, wired to the axi_ctl register slave. The whole
// point is to prove the PS->PL AXI path (AW/W/B/AR/R) on our bare-PS7 pure-RTL flow BEFORE
// integrating anything into the ZX core. Test from xsdb over the Pico/XVC link:
//     ps7_init  (brings up FCLK0 -> MAXIGP0ACLK; GP0 is dead without it)
//     mrd 0x40000000   -> expect 0xB01B0001  (VERSION; proves the read path)
//     mwr 0x40000004 1 -> led_ctrl (D18) lights (proves the write path)
//     mrd 0x40000004   -> expect 1            (proves the latch / read-back)
//     mwr 0x40000008 v / mrd 0x40000008       (proves the full 32-bit data path)
//     mrd 0x4000000C (twice) -> changing      (COUNTER; proves the slave is clocked)
//
// PS7 port names/widths taken verbatim from the Vivado 2023.1 unisim PS7.v (AXI3: 32-bit data,
// 12-bit ID, 4-bit LEN). FCLKRESETN is a [3:0] bus (there is no scalar FCLKRESET0N).
//-------------------------------------------------------------------------------------------------
module bulb_axi_test_top
(
    output wire led_ctrl,    // D18: CONTROL[0], driven by the ARM/xsdb over AXI GP0
    output wire led_heart    // H18: ~3 Hz heartbeat (proves the bitstream is configured & FCLK0 alive)
);
    //=============================================================================================
    // PS7: FCLK0 (100 MHz) + M_AXI_GP0 master. Only the ports we use are connected; the rest of
    // the GP0 master sidebands (BURST/CACHE/LOCK/PROT/QOS/SIZE/WID) and the unused PS interfaces
    // are left open, exactly like the proven FCLK-only stub.
    //=============================================================================================
    wire [3:0] FCLKCLK;
    wire [3:0] FCLKRESETN;

    // M_AXI_GP0 channels (AXI3)
    wire [31:0] gp0_awaddr;  wire [11:0] gp0_awid;  wire [3:0] gp0_awlen;
    wire        gp0_awvalid; wire        gp0_awready;
    wire [31:0] gp0_wdata;   wire [3:0]  gp0_wstrb; wire        gp0_wlast;
    wire        gp0_wvalid;  wire        gp0_wready;
    wire [11:0] gp0_bid;     wire [1:0]  gp0_bresp; wire        gp0_bvalid; wire gp0_bready;
    wire [31:0] gp0_araddr;  wire [11:0] gp0_arid;  wire [3:0] gp0_arlen;
    wire        gp0_arvalid; wire        gp0_arready;
    wire [31:0] gp0_rdata;   wire [11:0] gp0_rid;   wire [1:0] gp0_rresp;
    wire        gp0_rlast;   wire        gp0_rvalid; wire       gp0_rready;

    wire fclk100;
    BUFG bufg100 (.I(FCLKCLK[0]), .O(fclk100));

    (* DONT_TOUCH = "true" *) PS7 ps7_stub (
        .FCLKCLK        (FCLKCLK),
        .FCLKRESETN     (FCLKRESETN),
        .MAXIGP0ACLK    (fclk100),
        // write address
        .MAXIGP0AWADDR  (gp0_awaddr),
        .MAXIGP0AWID    (gp0_awid),
        .MAXIGP0AWLEN   (gp0_awlen),
        .MAXIGP0AWVALID (gp0_awvalid),
        .MAXIGP0AWREADY (gp0_awready),
        // write data
        .MAXIGP0WDATA   (gp0_wdata),
        .MAXIGP0WSTRB   (gp0_wstrb),
        .MAXIGP0WLAST   (gp0_wlast),
        .MAXIGP0WVALID  (gp0_wvalid),
        .MAXIGP0WREADY  (gp0_wready),
        // write response
        .MAXIGP0BID     (gp0_bid),
        .MAXIGP0BRESP   (gp0_bresp),
        .MAXIGP0BVALID  (gp0_bvalid),
        .MAXIGP0BREADY  (gp0_bready),
        // read address
        .MAXIGP0ARADDR  (gp0_araddr),
        .MAXIGP0ARID    (gp0_arid),
        .MAXIGP0ARLEN   (gp0_arlen),
        .MAXIGP0ARVALID (gp0_arvalid),
        .MAXIGP0ARREADY (gp0_arready),
        // read data
        .MAXIGP0RDATA   (gp0_rdata),
        .MAXIGP0RID     (gp0_rid),
        .MAXIGP0RRESP   (gp0_rresp),
        .MAXIGP0RLAST   (gp0_rlast),
        .MAXIGP0RVALID  (gp0_rvalid),
        .MAXIGP0RREADY  (gp0_rready)
    );

    //=============================================================================================
    // Power-on reset for the slave, in the FCLK0 domain (active-low). FCLK0 only starts toggling
    // after ps7_init, so this releases a few cycles after the GP0 clock is alive.
    //=============================================================================================
    reg [3:0] por     = 4'h0;
    reg       aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (por != 4'hF) begin por <= por + 4'h1; aresetn <= 1'b0; end
        else                                      aresetn <= 1'b1;
    end

    //=============================================================================================
    // The register slave (the seed of the real Stage-1 control plane).
    //=============================================================================================
    axi_ctl #(.VERSION(32'hB01B0001)) ctl (
        .aclk     (fclk100),
        .aresetn  (aresetn),
        .s_awid   (gp0_awid),   .s_awaddr (gp0_awaddr), .s_awlen (gp0_awlen),
        .s_awvalid(gp0_awvalid),.s_awready(gp0_awready),
        .s_wdata  (gp0_wdata),  .s_wstrb  (gp0_wstrb),  .s_wlast (gp0_wlast),
        .s_wvalid (gp0_wvalid), .s_wready (gp0_wready),
        .s_bid    (gp0_bid),    .s_bresp  (gp0_bresp),  .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
        .s_arid   (gp0_arid),   .s_araddr (gp0_araddr), .s_arlen (gp0_arlen),
        .s_arvalid(gp0_arvalid),.s_arready(gp0_arready),
        .s_rid    (gp0_rid),    .s_rdata  (gp0_rdata),  .s_rresp (gp0_rresp),
        .s_rlast  (gp0_rlast),  .s_rvalid (gp0_rvalid), .s_rready(gp0_rready),
        .led      (led_ctrl)
    );

    //=============================================================================================
    // Heartbeat: ~3 Hz on D... H18, so we can see at a glance the bitstream is configured and
    // FCLK0 is running, independent of any AXI traffic.
    //=============================================================================================
    reg [25:0] hb = 26'd0;
    always @(posedge fclk100) hb <= hb + 26'd1;
    assign led_heart = hb[24];
endmodule
//-------------------------------------------------------------------------------------------------
