`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// bulbulator_zx_top.v
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Atlas ZX Spectrum 128K core on the EBAZ4205 (Xilinx Zynq xc7z010clg400-1) with HDMI video +
// audio (720p50) AND a PS->PL control plane: the ARM, over M_AXI_GP0, can HALT the Z80 and write
// Spectrum RAM (axi_ctl + inject_cdc). Stage-1 / Milestone 2 of putting the idle ARM to work.
//
// Clock domains:
//   * fclk100   100 MHz from PS7 FCLK0  -> source for both PLLs AND the AXI slave (aclk).
//   * clk_pixel 74.25 MHz  (HDMI pixel) -> hdmi core + framebuffer read.
//   * clk_ser   371.25 MHz (HDMI x5)    -> TMDS serializer.
//   * clk_audio ~48 kHz                 -> HDMI audio sample.
//   * spclk     ~56.7 MHz (Spectrum)    -> core + mem + keyboard + framebuffer write + inject_cdc.
//
// Control plane (NEW): axi_ctl is a small AXI3 slave on the GP0 master (0x4000_0000). inject_cdc
// crosses its HALT level + RAM-write strobe into the Spectrum clock domain. HALT is implemented
// WITHOUT touching the Atlas core: the two 3.5 MHz CPU clock-enables (pe3M5/ne3M5) are gated off
// at the core's input, which freezes the Z80 + the MMU (so memWr/memA/vmmA2 hold) while video
// (pe7M0/ne7M0) and HDMI audio keep running. While halted, the ARM is muxed onto the memory bus
// (memWr/memA/memQ/vmmA2) so it can poke RAM - including the displayed screen shadow.
//-------------------------------------------------------------------------------------------------
module bulbulator_zx_top
(
    output wire       TMDS_Clk_p,     // F19
    output wire       TMDS_Clk_n,     // F20
    output wire [2:0] TMDS_Data_p,    // D19 / C20 / B19
    output wire [2:0] TMDS_Data_n,    // D20 / B20 / A20

    input  wire [3:0] btn,            // P19 / T19 / U20 / U19, active-low
    input  wire       ear_in,         // J19, tape audio in (LVCMOS33, PULLDOWN)

    output wire       led_lock,       // D18: Spectrum MMCM locked
    output wire       led_heart       // H18: heartbeat (alive indicator)
);
    //=============================================================================================
    // PS7: FCLK0 (100 MHz) + M_AXI_GP0 master. (GP0 ports per the Vivado 2023.1 unisim PS7.v;
    // AXI3 = 32b data / 12b ID / 4b LEN. FCLKRESETN is a [3:0] bus.)
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
    // HDMI clocks: 100 -> 74.25 (pixel) + 371.25 (serial x5). VCO 742.5 (M=37.125, D=5).
    //=============================================================================================
    wire clk_pix_raw, clk_ser_raw, fb, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.000),
        .CLKFBOUT_MULT_F(37.125), .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.000),   // 742.5 / 10  = 74.25 MHz
        .CLKOUT1_DIVIDE(2)           // 742.5 / 2   = 371.25 MHz
    ) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fb), .CLKFBOUT(fb),
        .CLKOUT0(clk_pix_raw), .CLKOUT1(clk_ser_raw),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked)
    );
    wire clk_pixel, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pixel));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire hdmi_reset = ~locked;

    //=============================================================================================
    // 48 kHz audio clock: 74.25 MHz / 1547 = 47996 Hz   (verbatim from Step-5)
    //=============================================================================================
    reg [10:0] adiv = 11'd0;
    reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end

    //=============================================================================================
    // Spectrum master clock (~56.7 MHz) + clock enables from clock_zx.
    //=============================================================================================
    wire spclk;
    wire sp_lock;
    wire pe7M0, ne7M0, pe3M5, ne3M5;
    clock_zx clock_zx_i (
        .fclk100(fclk100), .clock(spclk), .power(sp_lock),
        .ne14M(), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5)
    );

    //=============================================================================================
    // Power-on reset in the Spectrum domain (ACTIVE-LOW).
    //=============================================================================================
    reg  [1:0]  lock_sync = 2'b00;
    reg  [15:0] por_cnt   = 16'd0;
    reg         sp_reset_n = 1'b0;
    wire        lock_in   = lock_sync[1];
    always @(posedge spclk) begin
        lock_sync <= {lock_sync[0], sp_lock};
        if (!lock_in) begin
            por_cnt    <= 16'd0;
            sp_reset_n <= 1'b0;
        end else if (por_cnt != 16'hFFFF) begin
            por_cnt    <= por_cnt + 16'd1;
            sp_reset_n <= 1'b0;
        end else begin
            sp_reset_n <= 1'b1;
        end
    end

    //=============================================================================================
    // AXI control plane: aclk = fclk100. Power-on reset for the slave.
    //=============================================================================================
    reg [3:0] axi_por = 4'h0;
    reg       aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (axi_por != 4'hF) begin axi_por <= axi_por + 4'h1; aresetn <= 1'b0; end
        else                                                  aresetn <= 1'b1;
    end

    // axi_ctl (aclk) <-> inject_cdc <-> Spectrum domain
    wire        ctl_halt;
    wire        ctl_ram_we;
    wire [16:0] ctl_ram_addr;
    wire [16:0] ctl_ram_waddr;
    wire [7:0]  ctl_ram_data;
    wire        halt_ack, ram_busy;
    wire        cpu_halt_sp;
    wire        arm_memWr;
    wire [18:0] arm_memA;
    wire [7:0]  arm_memQ;
    wire [13:0] arm_vmmA2;

    axi_ctl #(.VERSION(32'hB01B0002)) ctl (
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
        .ctl_halt(ctl_halt), .ctl_ram_we(ctl_ram_we),
        .ctl_ram_addr(ctl_ram_addr), .ctl_ram_waddr(ctl_ram_waddr), .ctl_ram_data(ctl_ram_data),
        .halt_ack(halt_ack), .ram_busy(ram_busy)
    );

    inject_cdc inj_i (
        .aclk(fclk100), .aresetn(aresetn), .spclk(spclk),
        .ctl_halt(ctl_halt), .ctl_ram_we(ctl_ram_we),
        .ctl_ram_addr(ctl_ram_waddr), .ctl_ram_data(ctl_ram_data),
        .halt_ack(halt_ack), .ram_busy(ram_busy),
        .cpu_halt_sp(cpu_halt_sp),
        .arm_memWr(arm_memWr), .arm_memA(arm_memA), .arm_memQ(arm_memQ), .arm_vmmA2(arm_vmmA2)
    );

    // HALT = gate the two 3.5 MHz CPU clock-enables into the core (no Atlas-core edit).
    wire pe3M5_core = pe3M5 & ~cpu_halt_sp;
    wire ne3M5_core = ne3M5 & ~cpu_halt_sp;

    //=============================================================================================
    // Tape input: synchronise the async ear_in pin into the Spectrum domain (2 FF).
    //=============================================================================================
    reg [1:0] ear_sync = 2'b00;
    always @(posedge spclk) ear_sync <= {ear_sync[0], ear_in};
    wire sp_ear = ear_sync[1];

    //=============================================================================================
    // Keyboard: 4 buttons -> PS/2-set-2 scan-code strobes (NOT gated by halt).
    //=============================================================================================
    wire       kbd_strb, kbd_make;
    wire [7:0] kbd_code;
    kbd_buttons kbd_i (
        .clock(spclk), .ce(pe3M5), .btn(btn),
        .strb(kbd_strb), .make(kbd_make), .code(kbd_code)
    );

    //=============================================================================================
    // Atlas ZX Spectrum core (main). CPU enables gated by halt; video enables free-running.
    //=============================================================================================
    wire vid_blank, vid_hsync, vid_vsync, vid_r, vid_g, vid_b, vid_i;
    wire [10:0] laudio, raudio;
    wire        vmmCe;
    wire [13:0] vmmA1, vmmA2_core;
    wire [7:0]  vmmD;
    wire        memRf, memRd, memWr_core;
    wire [18:0] memA_core;
    wire [7:0]  memD, memQ_core;

    main core_i (
        .model  (1'b1),
        .mapper (1'b0),
        .reset  (sp_reset_n),
        .nmi    (1'b0),

        .clock  (spclk),
        .pe7M0  (pe7M0),
        .ne7M0  (ne7M0),
        .pe3M5  (pe3M5_core),     // gated for HALT
        .ne3M5  (ne3M5_core),     // gated for HALT

        .blank  (vid_blank), .hsync(vid_hsync), .vsync(vid_vsync),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i),

        .ear    (sp_ear),
        .laudio (laudio),
        .raudio (raudio),
        .midi   (),

        .strb   (kbd_strb), .make(kbd_make), .code(kbd_code),
        .joy1   (8'h00), .joy2(8'h00),
        .cs(), .ck(), .miso(1'b1), .mosi(),

        .vmmCe  (vmmCe),
        .vmmA1  (vmmA1),
        .vmmA2  (vmmA2_core),
        .vmmD   (vmmD),

        .memCe  (),
        .memRf  (memRf),
        .memRd  (memRd),
        .memWr  (memWr_core),
        .memA   (memA_core),
        .memD   (memD),
        .memQ   (memQ_core)
    );

    //=============================================================================================
    // Memory-bus mux: while the ARM holds the Z80 halted, it drives the write side of the bus.
    // The video read side (vmmA1 / vmmCe) always comes from the core, so the picture stays live.
    //=============================================================================================
    wire        memWr_eff = cpu_halt_sp ? arm_memWr  : memWr_core;
    wire [18:0] memA_eff   = cpu_halt_sp ? arm_memA   : memA_core;
    wire [7:0]  memQ_eff   = cpu_halt_sp ? arm_memQ   : memQ_core;
    wire [13:0] vmmA2_eff  = cpu_halt_sp ? arm_vmmA2  : vmmA2_core;

    mem_zx mem_i (
        .clock (spclk),
        .memRf (memRf),
        .memRd (memRd),
        .memWr (memWr_eff),
        .memA  (memA_eff),
        .memQ  (memQ_eff),
        .memD  (memD),
        .vmmCe (vmmCe),
        .vmmA1 (vmmA1),
        .vmmA2 (vmmA2_eff),
        .vmmD  (vmmD)
    );

    //=============================================================================================
    // Framebuffer / scaler. Write side = Spectrum domain (pe7M0), read side = clk_pixel.
    //=============================================================================================
    wire [10:0] cx, cy;
    wire [23:0] rgb24;
    framebuffer fb_i (
        .wr_clk (spclk), .wr_ce(pe7M0),
        .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i),
        .rd_clk (clk_pixel), .cx(cx), .cy(cy), .rgb(rgb24)
    );

    //=============================================================================================
    // Audio: 11-bit UNSIGNED PCM -> signed 16-bit, then resync into clk_audio. UNCHANGED - the
    // control plane never touches the AY/beeper/tape -> HDMI audio path.
    //=============================================================================================
    wire [15:0] left16_sp  = { ~laudio[10], laudio[9:0], 5'b0 };
    wire [15:0] right16_sp = { ~raudio[10], raudio[9:0], 5'b0 };

    reg [15:0] left16_a0, left16_a1;
    reg [15:0] right16_a0, right16_a1;
    always @(posedge clk_audio_r) begin
        left16_a0  <= left16_sp;   left16_a1  <= left16_a0;
        right16_a0 <= right16_sp;  right16_a1 <= right16_a0;
    end

    //=============================================================================================
    // HDMI 1.4 (720p50) with stereo audio + OBUFDS to the TMDS pins.
    //=============================================================================================
    wire [2:0] tmds;
    wire       tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser),
        .clk_pixel   (clk_pixel),
        .clk_audio   (clk_audio_r),
        .reset       (hdmi_reset),
        .rgb         (rgb24),
        .audio_left  (left16_a1),
        .audio_right (right16_a1),
        .tmds        (tmds),
        .tmds_clock  (tmds_clock),
        .cx          (cx),
        .cy          (cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi = 0; gi < 3; gi = gi + 1) begin : tb
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    //=============================================================================================
    // Indicators.
    //=============================================================================================
    assign led_lock = sp_lock;
    reg [25:0] hb = 26'd0;
    always @(posedge clk_pixel) hb <= hb + 26'd1;
    assign led_heart = hb[24];
endmodule
//-------------------------------------------------------------------------------------------------
