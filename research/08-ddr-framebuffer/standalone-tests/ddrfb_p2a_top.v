`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ddrfb_p2a_top.v  -  Phase 2a: validate the live CAPTURE path (spclk) + CDC + triple buffer.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// A synthetic ULA (zx_raster_gen on the real spclk from clock_zx) drives fb_capture, whose words
// cross to fclk100 through async_fifo and are bursted to PS DDR by fb_wr_axi into the write buffer
// chosen by fb_bufmgr3 (TRIPLE buffer, continuous source -> writer never stalls). The Phase-1 loader
// + display + hdl-util scan it out tear-free. PASS = colour bars scroll smoothly (no tear) -> the
// spclk->fclk100 capture/CDC/AXI-write/triple-swap chain is proven before the dense real-core build.
//-------------------------------------------------------------------------------------------------
module ddrfb_p2a_top (
    output wire        led_lock,
    output wire        led_heart,
    output wire        TMDS_Clk_p,  output wire TMDS_Clk_n,
    output wire [2:0]  TMDS_Data_p, output wire [2:0] TMDS_Data_n
);
    wire [3:0] fclk;
    wire [31:0] gp0_awaddr; wire [11:0] gp0_awid; wire [3:0] gp0_awlen; wire gp0_awvalid, gp0_awready;
    wire [31:0] gp0_wdata;  wire [3:0]  gp0_wstrb; wire gp0_wlast, gp0_wvalid, gp0_wready;
    wire [11:0] gp0_bid;    wire [1:0]  gp0_bresp; wire gp0_bvalid, gp0_bready;
    wire [31:0] gp0_araddr; wire [11:0] gp0_arid; wire [3:0] gp0_arlen; wire gp0_arvalid, gp0_arready;
    wire [31:0] gp0_rdata;  wire [11:0] gp0_rid;  wire [1:0] gp0_rresp; wire gp0_rlast, gp0_rvalid, gp0_rready;
    wire        hp_aresetn;
    wire [31:0] hp_araddr;  wire [5:0] hp_arid; wire [3:0] hp_arlen; wire [2:0] hp_arsize;
    wire [1:0]  hp_arburst; wire [3:0] hp_arcache; wire [2:0] hp_arprot; wire [1:0] hp_arlock; wire [3:0] hp_arqos;
    wire        hp_arvalid, hp_arready;
    wire [63:0] hp_rdata;   wire [5:0] hp_rid; wire [1:0] hp_rresp; wire hp_rlast, hp_rvalid, hp_rready;
    wire [31:0] hp_awaddr;  wire [5:0] hp_awid; wire [3:0] hp_awlen; wire [2:0] hp_awsize;
    wire [1:0]  hp_awburst; wire [3:0] hp_awcache; wire [2:0] hp_awprot; wire [1:0] hp_awlock; wire [3:0] hp_awqos;
    wire        hp_awvalid, hp_awready;
    wire [63:0] hp_wdata;   wire [7:0] hp_wstrb; wire hp_wlast, hp_wvalid, hp_wready;
    wire        hp_bvalid, hp_bready;

    wire fclk100;
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));

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
    reg [10:0] adiv = 11'd0; reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end
    wire [10:0] cx, cy;

    // Spectrum clock + enables
    wire spclk, sp_lock, pe7M0, ne7M0, pe3M5, ne3M5;
    clock_zx clock_zx_i (.fclk100(fclk100), .clock(spclk), .power(sp_lock),
        .ne14M(), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5));

    // PS7
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
        .SAXIHP0ACLK(fclk100), .SAXIHP0ARESETN(hp_aresetn),
        .SAXIHP0ARADDR(hp_araddr), .SAXIHP0ARID(hp_arid), .SAXIHP0ARLEN(hp_arlen),
        .SAXIHP0ARSIZE(hp_arsize[1:0]), .SAXIHP0ARBURST(hp_arburst), .SAXIHP0ARCACHE(hp_arcache),
        .SAXIHP0ARPROT(hp_arprot), .SAXIHP0ARLOCK(hp_arlock), .SAXIHP0ARQOS(hp_arqos),
        .SAXIHP0ARVALID(hp_arvalid), .SAXIHP0ARREADY(hp_arready),
        .SAXIHP0RDATA(hp_rdata), .SAXIHP0RID(hp_rid), .SAXIHP0RRESP(hp_rresp),
        .SAXIHP0RLAST(hp_rlast), .SAXIHP0RVALID(hp_rvalid), .SAXIHP0RREADY(hp_rready),
        .SAXIHP0RDISSUECAP1EN(1'b0),
        .SAXIHP0AWADDR(hp_awaddr), .SAXIHP0AWID(hp_awid), .SAXIHP0AWLEN(hp_awlen),
        .SAXIHP0AWSIZE(hp_awsize[1:0]), .SAXIHP0AWBURST(hp_awburst), .SAXIHP0AWCACHE(hp_awcache),
        .SAXIHP0AWPROT(hp_awprot), .SAXIHP0AWLOCK(hp_awlock), .SAXIHP0AWQOS(hp_awqos),
        .SAXIHP0AWVALID(hp_awvalid), .SAXIHP0AWREADY(hp_awready),
        .SAXIHP0WDATA(hp_wdata), .SAXIHP0WID(6'd0), .SAXIHP0WSTRB(hp_wstrb), .SAXIHP0WLAST(hp_wlast),
        .SAXIHP0WVALID(hp_wvalid), .SAXIHP0WREADY(hp_wready), .SAXIHP0WRISSUECAP1EN(1'b0),
        .SAXIHP0BVALID(hp_bvalid), .SAXIHP0BREADY(hp_bready)
    );

    // resets
    reg [3:0] por = 4'h0; reg aresetn = 1'b0;
    always @(posedge fclk100) begin
        if (por != 4'hF) begin por <= por + 4'h1; aresetn <= 1'b0; end else aresetn <= 1'b1;
    end
    reg [1:0] hprstn_s = 2'b00;
    always @(posedge fclk100) hprstn_s <= {hprstn_s[0], hp_aresetn};
    wire core_resetn = aresetn & hprstn_s[1];

    reg [1:0] splk_s = 2'b00; reg [7:0] spor = 8'd0; reg sp_resetn = 1'b0;
    always @(posedge spclk) begin
        splk_s <= {splk_s[0], sp_lock};
        if (!splk_s[1]) begin spor<=8'd0; sp_resetn<=1'b0; end
        else if (spor != 8'hFF) begin spor<=spor+8'd1; sp_resetn<=1'b0; end
        else sp_resetn<=1'b1;
    end

    // vblank kick + delayed copy
    reg vbl_tog = 1'b0, cy_in_vbl_d = 1'b0;
    wire cy_in_vbl = (cy >= 11'd720);
    always @(posedge clk_pixel) begin
        cy_in_vbl_d <= cy_in_vbl;
        if (cy_in_vbl & ~cy_in_vbl_d) vbl_tog <= ~vbl_tog;
    end
    reg [2:0] vbl_s = 3'b000;
    always @(posedge fclk100) vbl_s <= {vbl_s[1:0], vbl_tog};
    wire frame_kick = vbl_s[2] ^ vbl_s[1];
    reg frame_kick_d = 1'b0;
    always @(posedge fclk100) frame_kick_d <= frame_kick;

    // synthetic ULA -> capture -> async FIFO
    wire vr, vg, vb, vi, vhs, vvs, vbl;
    zx_raster_gen rgen (.spclk(spclk), .resetn(sp_resetn), .pe7M0(pe7M0),
        .r(vr), .g(vg), .b(vb), .i(vi), .hsync(vhs), .vsync(vvs), .blank(vbl));

    // gate the capture until the HP path is up (loader has read >=1 frame -> post_config done),
    // so the FIFO never overflows at startup and the writer's frame count stays aligned.
    reg  [1:0] capen_s = 2'b00;
    wire       cap_en = capen_s[1];
    always @(posedge spclk) capen_s <= {capen_s[0], (ld_frames != 32'd0)};

    wire        cap_wr; wire [63:0] cap_din;
    fb_capture cap (.spclk(spclk), .resetn(sp_resetn), .pe7M0(pe7M0),
        .r(vr), .g(vg), .b(vb), .i(vi), .blank(vbl), .vsync(vvs), .enable(cap_en),
        .fifo_wr(cap_wr), .fifo_din(cap_din));

    wire        fifo_empty, fifo_rd; wire [63:0] fifo_dout; wire [6:0] fifo_rdcount;
    async_fifo #(.DW(64), .AW(6)) fifo (
        .wr_clk(spclk), .wr_rst_n(sp_resetn), .wr_en(cap_wr), .din(cap_din), .full(fifo_full),
        .rd_clk(fclk100), .rd_rst_n(core_resetn), .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .rd_count(fifo_rdcount)
    );

    // AXI writer (drain FIFO -> DDR) + triple buffer
    wire        wr_done;
    wire [31:0] wr_base, disp_base;
    wire [1:0]  wr_buf, disp_buf, ready_buf;
    fb_bufmgr3 bufmgr (
        .clk(fclk100), .resetn(core_resetn),
        .frame_done(wr_done), .frame_kick(frame_kick),
        .wr_base(wr_base), .disp_base(disp_base),
        .wr_buf_o(wr_buf), .disp_buf_o(disp_buf), .ready_buf_o(ready_buf)
    );
    fb_wr_axi wraxi (
        .clk(fclk100), .resetn(core_resetn), .base(wr_base),
        .fifo_empty(fifo_empty), .fifo_dout(fifo_dout), .fifo_rd(fifo_rd),
        .aw_addr(hp_awaddr), .aw_id(hp_awid), .aw_len(hp_awlen), .aw_size(hp_awsize),
        .aw_burst(hp_awburst), .aw_cache(hp_awcache), .aw_prot(hp_awprot),
        .aw_lock(hp_awlock), .aw_qos(hp_awqos), .aw_valid(hp_awvalid), .aw_ready(hp_awready),
        .w_data(hp_wdata), .w_strb(hp_wstrb), .w_last(hp_wlast), .w_valid(hp_wvalid), .w_ready(hp_wready),
        .b_valid(hp_bvalid), .b_ready(hp_bready),
        .frame_done(wr_done), .busy_o()
    );

    // loader -> display BRAM
    wire        ld_wr_en; wire [12:0] ld_wr_addr; wire [63:0] ld_wr_data;
    wire [31:0] ld_frames, ld_beats; wire ld_busy;
    fb_loader loader (
        .clk(fclk100), .resetn(core_resetn),
        .frame_kick(frame_kick_d), .base(disp_base), .load_en(1'b1),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .frame_cnt(ld_frames), .beat_cnt(ld_beats), .busy_o(ld_busy)
    );

    // counters / debug
    reg [31:0] wr_frames = 32'd0;
    always @(posedge fclk100) if (!core_resetn) wr_frames<=32'd0; else if (wr_done) wr_frames<=wr_frames+32'd1;
    reg [15:0] fifo_max = 16'd0;
    always @(posedge fclk100) if (!core_resetn) fifo_max<=16'd0; else if ({9'd0,fifo_rdcount} > fifo_max) fifo_max<={9'd0,fifo_rdcount};

    ddrfb_p2a_regs regs (
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
        .ld_frames(ld_frames), .wr_frames(wr_frames),
        .wr_buf(wr_buf), .disp_buf(disp_buf), .ready_buf(ready_buf), .fifo_max(fifo_max)
    );

    wire [23:0] rgb24;
    fb_display disp (
        .wr_clk(fclk100), .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy), .rgb(rgb24)
    );
    wire [2:0] tmds; wire tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser), .clk_pixel(clk_pixel), .clk_audio(clk_audio_r),
        .reset(hdmi_reset),
        .rgb(rgb24), .audio_left(16'd0), .audio_right(16'd0),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi=0; gi<3; gi=gi+1) begin: tmds_obuf
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    assign led_lock  = ~locked;
    assign led_heart = ld_frames[5];
endmodule
//-------------------------------------------------------------------------------------------------
