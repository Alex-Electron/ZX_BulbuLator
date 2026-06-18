`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ps2_test_top.v  -  EBAZ4205 (xc7z010clg400-1)  -  standalone PS/2 keyboard READ test.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Proves the board reads a real PS/2 keyboard on two pins, BEFORE wiring it into the ZX core.
//   PS2_CLK  = G19 (DATA2-07)   PS2_DATA = H20 (DATA2-08)   LVCMOS33 + external ~10k pull-ups.
// The Atlas core's own ps2.v decodes the 11-bit frames; the last scan-code and a byte counter are
// latched and exposed over M_AXI_GP0 so the ARM / JTAG can read them:
//   0x4000_0000 VERSION R 0xB01B0009
//   0x4000_0004 STATUS  R {8'b0, count[15:0], scancode[7:0]}
// led_heart (H18) = ~3 Hz alive blink; led_lock (D18) toggles on every received byte (instant
// "a key was read" feedback). Single clock domain (fclk100) -> no CDC. ps7_init configures FCLK0
// + the PS->PL level shifters at runtime; this PS7 primitive is only the boundary.
//-------------------------------------------------------------------------------------------------
module ps2_test_top
(
    input  wire ps2_clk,    // G19  PS/2 clock  (open-collector, external pull-up to 3V3)
    input  wire ps2_data,   // H20  PS/2 data   (open-collector, external pull-up to 3V3)
    output wire led_lock,   // D18  toggles per received byte
    output wire led_heart   // H18  ~3 Hz alive blink
);
    //=============================================================================================
    // PS7: FCLK0 (100 MHz) + M_AXI_GP0 master only.
    //=============================================================================================
    wire [3:0] fclk;
    wire [3:0] FCLKRESETN;

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
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));

    (* DONT_TOUCH = "true" *) PS7 ps7_stub (
        .FCLKCLK        (fclk),
        .FCLKRESETN     (FCLKRESETN),
        .MAXIGP0ACLK    (fclk100),
        .MAXIGP0AWADDR  (gp0_awaddr),  .MAXIGP0AWID   (gp0_awid),    .MAXIGP0AWLEN  (gp0_awlen),
        .MAXIGP0AWVALID (gp0_awvalid), .MAXIGP0AWREADY(gp0_awready),
        .MAXIGP0WDATA   (gp0_wdata),   .MAXIGP0WSTRB  (gp0_wstrb),   .MAXIGP0WLAST  (gp0_wlast),
        .MAXIGP0WVALID  (gp0_wvalid),  .MAXIGP0WREADY (gp0_wready),
        .MAXIGP0BID     (gp0_bid),     .MAXIGP0BRESP  (gp0_bresp),   .MAXIGP0BVALID (gp0_bvalid),
        .MAXIGP0BREADY  (gp0_bready),
        .MAXIGP0ARADDR  (gp0_araddr),  .MAXIGP0ARID   (gp0_arid),    .MAXIGP0ARLEN  (gp0_arlen),
        .MAXIGP0ARVALID (gp0_arvalid), .MAXIGP0ARREADY(gp0_arready),
        .MAXIGP0RDATA   (gp0_rdata),   .MAXIGP0RID    (gp0_rid),     .MAXIGP0RRESP  (gp0_rresp),
        .MAXIGP0RLAST   (gp0_rlast),   .MAXIGP0RVALID (gp0_rvalid),  .MAXIGP0RREADY (gp0_rready)
    );

    //=============================================================================================
    // AXI slave power-on reset (fclk100, active-low).
    //=============================================================================================
    reg [3:0] por = 4'h0;
    reg       aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (por != 4'hF) begin por <= por + 4'h1; aresetn <= 1'b0; end
        else                                      aresetn <= 1'b1;
    end

    //=============================================================================================
    // Synchronise the async PS/2 pins (2 FF), then a ~3.5 MHz clock-enable for the sampler
    // (100/28 = 3.57 MHz, matches the core's pe3M5 rate).
    //=============================================================================================
    reg [1:0] ck_s = 2'b11, d_s = 2'b11;
    always @(posedge fclk100) begin ck_s <= {ck_s[0], ps2_clk}; d_s <= {d_s[0], ps2_data}; end

    reg [4:0] cediv = 5'd0;
    wire      ps2_ce = (cediv == 5'd0);
    always @(posedge fclk100) cediv <= (cediv == 5'd27) ? 5'd0 : cediv + 5'd1;

    //=============================================================================================
    // Atlas PS/2 receiver: 11-bit frame + parity. strb pulses on each good byte.
    //=============================================================================================
    wire       ps2_strb, ps2_make;
    wire [7:0] ps2_code;
    ps2 ps2_i (
        .clock(fclk100), .ce(ps2_ce),
        .ps2Ck(ck_s[1]), .ps2D(d_s[1]),
        .strb(ps2_strb), .make(ps2_make), .code(ps2_code)
    );

    //=============================================================================================
    // Latch the last scan-code, count received bytes, toggle the activity LED.
    //=============================================================================================
    reg [7:0]  last_code = 8'h00;
    reg [15:0] byte_cnt  = 16'd0;
    reg        act       = 1'b0;
    always @(posedge fclk100) if (ps2_ce && ps2_strb) begin
        last_code <= ps2_code;
        byte_cnt  <= byte_cnt + 16'd1;
        act       <= ~act;
    end
    wire [31:0] ps2_status = {8'd0, byte_cnt, last_code};

    //=============================================================================================
    // GP0 read-back slave.
    //=============================================================================================
    ps2_axi #(.VERSION(32'hB01B0009)) axi_i (
        .aclk(fclk100), .aresetn(aresetn),
        .s_awid(gp0_awid), .s_awaddr(gp0_awaddr), .s_awlen(gp0_awlen),
        .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
        .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
        .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
        .s_bid(gp0_bid), .s_bresp(gp0_bresp), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
        .s_arid(gp0_arid), .s_araddr(gp0_araddr), .s_arlen(gp0_arlen),
        .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
        .s_rid(gp0_rid), .s_rdata(gp0_rdata), .s_rresp(gp0_rresp),
        .s_rlast(gp0_rlast), .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
        .ps2_status(ps2_status)
    );

    //=============================================================================================
    // LEDs.
    //=============================================================================================
    reg [25:0] hb = 26'd0;
    always @(posedge fclk100) hb <= hb + 26'd1;
    assign led_heart = hb[24];   // ~3 Hz alive blink
    assign led_lock  = act;      // toggles on every PS/2 byte
endmodule
//-------------------------------------------------------------------------------------------------
