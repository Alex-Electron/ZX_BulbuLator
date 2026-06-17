`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ddrfb_p1a_top.v  -  Phase 1a: prove the DDR -> HDMI read path (no Spectrum logic).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// PS7 (FCLK0=100, GP0 control, HP0 read) + the proven Step-5 MMCM/HDMI scaffold. An xsdb-loaded
// test frame sits in PS DDR @0x0FF0_0000 (360x288 RGBI, 16 px / 64-bit word). fb_loader bursts it
// DDR -> display BRAM each HDMI vblank; the proven pillarbox upscaler scans the BRAM to 720p50 ->
// hdl-util/hdmi. Pass = the DDR pattern appears, stable, pillarboxed.
//
// Clocking (de-risked): the loader + HP0 run on fclk100 EXACTLY as the proven hp_test probe; the
// display BRAM itself is the clock-domain crossing (write fclk100 / read clk_pixel), exactly as the
// original framebuffer crossed spclk->clk_pixel. The only new CDC is the 1-bit vblank kick.
//-------------------------------------------------------------------------------------------------
module ddrfb_p1a_top (
    output wire        led_lock,                 // D18: MMCM locked
    output wire        led_heart,                // H18: loader heartbeat (blinks while loading)
    output wire        TMDS_Clk_p,  output wire TMDS_Clk_n,
    output wire [2:0]  TMDS_Data_p, output wire [2:0] TMDS_Data_n
);
    //=============================================================================================
    // PS7 nets
    //=============================================================================================
    wire [3:0] fclk;
    // M_AXI_GP0 (control)
    wire [31:0] gp0_awaddr; wire [11:0] gp0_awid; wire [3:0] gp0_awlen; wire gp0_awvalid, gp0_awready;
    wire [31:0] gp0_wdata;  wire [3:0]  gp0_wstrb; wire gp0_wlast, gp0_wvalid, gp0_wready;
    wire [11:0] gp0_bid;    wire [1:0]  gp0_bresp; wire gp0_bvalid, gp0_bready;
    wire [31:0] gp0_araddr; wire [11:0] gp0_arid; wire [3:0] gp0_arlen; wire gp0_arvalid, gp0_arready;
    wire [31:0] gp0_rdata;  wire [11:0] gp0_rid;  wire [1:0] gp0_rresp; wire gp0_rlast, gp0_rvalid, gp0_rready;
    // S_AXI_HP0 (read used)
    wire        hp_aresetn;
    wire [31:0] hp_araddr;  wire [5:0] hp_arid; wire [3:0] hp_arlen; wire [2:0] hp_arsize;
    wire [1:0]  hp_arburst; wire [3:0] hp_arcache; wire [2:0] hp_arprot; wire [1:0] hp_arlock; wire [3:0] hp_arqos;
    wire        hp_arvalid, hp_arready;
    wire [63:0] hp_rdata;   wire [5:0] hp_rid; wire [1:0] hp_rresp; wire hp_rlast, hp_rvalid, hp_rready;

    wire fclk100;
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));

    //=============================================================================================
    // HDMI clocks: 100 -> 74.25 (pixel) + 371.25 (serial x5). VCO 742.5. (verbatim Step-5)
    //=============================================================================================
    wire clk_pix_raw, clk_ser_raw, fbk, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.000), .CLKFBOUT_MULT_F(37.125), .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.000), .CLKOUT1_DIVIDE(2)
    ) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fbk), .CLKFBOUT(fbk),
        .CLKOUT0(clk_pix_raw), .CLKOUT1(clk_ser_raw),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked)
    );
    wire clk_pixel, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pixel));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire hdmi_reset = ~locked;

    // 48 kHz audio clock (hdl-util needs a sample clock even with silent audio). 74.25M/1547.
    reg [10:0] adiv = 11'd0; reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv        <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end

    wire [10:0] cx, cy;            // raster position from hdl-util (declared early: used by the kick)

    //=============================================================================================
    // PS7 (verbatim hp_test pattern: GP0 + HP0-read, HP write tied off). All ACLK = fclk100.
    //=============================================================================================
    (* DONT_TOUCH = "true" *) PS7 ps7_stub (
        .FCLKCLK(fclk),
        .MAXIGP0ACLK(fclk100),
        .MAXIGP0AWADDR(gp0_awaddr), .MAXIGP0AWID(gp0_awid), .MAXIGP0AWLEN(gp0_awlen),
        .MAXIGP0AWVALID(gp0_awvalid), .MAXIGP0AWREADY(gp0_awready),
        .MAXIGP0WDATA(gp0_wdata), .MAXIGP0WSTRB(gp0_wstrb), .MAXIGP0WLAST(gp0_wlast),
        .MAXIGP0WVALID(gp0_wvalid), .MAXIGP0WREADY(gp0_wready),
        .MAXIGP0BID(gp0_bid), .MAXIGP0BRESP(gp0_bresp), .MAXIGP0BVALID(gp0_bvalid), .MAXIGP0BREADY(gp0_bready),
        .MAXIGP0ARADDR(gp0_araddr), .MAXIGP0ARID(gp0_arid), .MAXIGP0ARLEN(gp0_arlen),
        .MAXIGP0ARVALID(gp0_arvalid), .MAXIGP0ARREADY(gp0_arready),
        .MAXIGP0RDATA(gp0_rdata), .MAXIGP0RID(gp0_rid), .MAXIGP0RRESP(gp0_rresp),
        .MAXIGP0RLAST(gp0_rlast), .MAXIGP0RVALID(gp0_rvalid), .MAXIGP0RREADY(gp0_rready),
        .SAXIHP0ACLK(fclk100),
        .SAXIHP0ARESETN(hp_aresetn),
        .SAXIHP0ARADDR(hp_araddr), .SAXIHP0ARID(hp_arid), .SAXIHP0ARLEN(hp_arlen),
        .SAXIHP0ARSIZE(hp_arsize[1:0]), .SAXIHP0ARBURST(hp_arburst), .SAXIHP0ARCACHE(hp_arcache),
        .SAXIHP0ARPROT(hp_arprot), .SAXIHP0ARLOCK(hp_arlock), .SAXIHP0ARQOS(hp_arqos),
        .SAXIHP0ARVALID(hp_arvalid), .SAXIHP0ARREADY(hp_arready),
        .SAXIHP0RDATA(hp_rdata), .SAXIHP0RID(hp_rid), .SAXIHP0RRESP(hp_rresp),
        .SAXIHP0RLAST(hp_rlast), .SAXIHP0RVALID(hp_rvalid), .SAXIHP0RREADY(hp_rready),
        .SAXIHP0RDISSUECAP1EN(1'b0),
        .SAXIHP0AWADDR(32'd0), .SAXIHP0AWID(6'd0), .SAXIHP0AWLEN(4'd0), .SAXIHP0AWSIZE(2'b11),
        .SAXIHP0AWBURST(2'b01), .SAXIHP0AWCACHE(4'd0), .SAXIHP0AWPROT(3'd0), .SAXIHP0AWLOCK(2'd0),
        .SAXIHP0AWQOS(4'd0), .SAXIHP0AWVALID(1'b0),
        .SAXIHP0WDATA(64'd0), .SAXIHP0WID(6'd0), .SAXIHP0WSTRB(8'd0), .SAXIHP0WLAST(1'b0),
        .SAXIHP0WVALID(1'b0), .SAXIHP0WRISSUECAP1EN(1'b0),
        .SAXIHP0BREADY(1'b1)
    );

    //=============================================================================================
    // Resets (fclk100): power-on + the PS-driven HP reset.
    //=============================================================================================
    reg [3:0] por = 4'h0; reg aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (por != 4'hF) begin por <= por + 4'h1; aresetn <= 1'b0; end else aresetn <= 1'b1;
    end
    reg [1:0] hprstn_s = 2'b00;
    always @(posedge fclk100) hprstn_s <= {hprstn_s[0], hp_aresetn};
    wire loader_resetn = aresetn & hprstn_s[1];

    //=============================================================================================
    // GP0 control/readout (fclk100)
    //=============================================================================================
    wire        cfg_load_en; wire [31:0] cfg_base;
    wire [31:0] frame_cnt, beat_cnt; wire busy;
    ddrfb_p1a_regs regs (
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
        .cfg_load_en(cfg_load_en), .cfg_base(cfg_base),
        .frame_cnt(frame_cnt), .beat_cnt(beat_cnt), .busy(busy)
    );

    //=============================================================================================
    // vblank kick: clk_pixel (cy enters vblank) -> toggle -> 3-FF sync to fclk100 -> 1-cyc pulse.
    //=============================================================================================
    reg vbl_tog = 1'b0, cy_in_vbl_d = 1'b0;
    wire cy_in_vbl = (cy >= 11'd720);
    always @(posedge clk_pixel) begin
        cy_in_vbl_d <= cy_in_vbl;
        if (cy_in_vbl & ~cy_in_vbl_d) vbl_tog <= ~vbl_tog;   // toggle at vblank start
    end
    reg [2:0] vbl_s = 3'b000;
    always @(posedge fclk100) vbl_s <= {vbl_s[1:0], vbl_tog};
    wire frame_kick = vbl_s[2] ^ vbl_s[1];                   // synced edge -> 1 fclk100 pulse

    //=============================================================================================
    // Loader (fclk100, HP0 read master) -> display BRAM write port
    //=============================================================================================
    wire        ld_wr_en; wire [12:0] ld_wr_addr; wire [63:0] ld_wr_data;
    fb_loader loader (
        .clk(fclk100), .resetn(loader_resetn),
        .frame_kick(frame_kick), .base(cfg_base), .load_en(cfg_load_en),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .frame_cnt(frame_cnt), .beat_cnt(beat_cnt), .busy_o(busy)
    );

    //=============================================================================================
    // Display BRAM + pillarbox upscaler (read side = clk_pixel)
    //=============================================================================================
    wire [23:0] rgb24;
    fb_display disp (
        .wr_clk(fclk100), .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy), .rgb(rgb24)
    );

    //=============================================================================================
    // HDMI (hdl-util) - video only, silent stereo
    //=============================================================================================
    wire [2:0] tmds; wire tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser), .clk_pixel(clk_pixel), .clk_audio(clk_audio_r),
        .reset(hdmi_reset),
        .rgb(rgb24), .audio_left(16'd0), .audio_right(16'd0),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi = 0; gi < 3; gi = gi + 1) begin: tmds_obuf
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    //=============================================================================================
    // LEDs (active-low board LEDs)
    //=============================================================================================
    assign led_lock  = ~locked;          // D18 lit while the MMCM is locked
    assign led_heart = frame_cnt[5];     // H18 blinks ~0.8 Hz while the loader cycles frames
endmodule
//-------------------------------------------------------------------------------------------------
