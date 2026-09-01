// bulbulator_nes_top.v - NES/Famicom/Dendy top for BulbuLator (Round-1: NROM in BRAM).
// Reuses the proven ZX board infra (PS7 + AXI-HP + HDMI MMCM + DDR framebuffer chain + hdmi_wrap +
// axi_ctl control plane) and swaps the ZX core for the vendored NESTang NES core (nes_wrap) fed to
// the video chain via nes_video. Self-contained reset/frame_kick on fclk100 (no ZX spclk logic).
// Built with -verilog_define NES_CORE (activates axi_ctl's ctl_nes_* registers). See MASTER_ROADMAP.md.
`default_nettype wire

module bulbulator_nes_top (
    output wire       TMDS_Clk_p,  output wire TMDS_Clk_n,
    output wire [2:0] TMDS_Data_p, output wire [2:0] TMDS_Data_n,
    input  wire [3:0] btn,
    inout  wire       ps2_clk, inout wire ps2_data,   // (reserved for the menu; unused in Round-1)
    output wire       led_lock, output wire led_heart
);
    localparam [31:0] BUILD_VERSION = 32'hB01BCE09;   // NES core id (CE09 = FIX: add 2KB internal CPU RAM, decode cpumem_addr[21])

    //==== PS7: FCLK0 100 MHz + M_AXI_GP0 + S_AXI_HP0/HP1 ====
    wire [3:0] fclk;  wire [3:0] FCLKRESETN;
    wire [31:0] gp0_awaddr; wire [11:0] gp0_awid; wire [3:0] gp0_awlen;
    wire gp0_awvalid, gp0_awready;
    wire [31:0] gp0_wdata; wire [3:0] gp0_wstrb; wire gp0_wlast, gp0_wvalid, gp0_wready;
    wire [11:0] gp0_bid; wire [1:0] gp0_bresp; wire gp0_bvalid, gp0_bready;
    wire [31:0] gp0_araddr; wire [11:0] gp0_arid; wire [3:0] gp0_arlen; wire gp0_arvalid, gp0_arready;
    wire [31:0] gp0_rdata; wire [11:0] gp0_rid; wire [1:0] gp0_rresp; wire gp0_rlast, gp0_rvalid, gp0_rready;
    wire hp_aresetn;
    wire [31:0] hp_araddr; wire [5:0] hp_arid; wire [3:0] hp_arlen; wire [2:0] hp_arsize;
    wire [1:0] hp_arburst; wire [3:0] hp_arcache; wire [2:0] hp_arprot; wire [1:0] hp_arlock; wire [3:0] hp_arqos;
    wire hp_arvalid, hp_arready;
    wire [63:0] hp_rdata; wire [5:0] hp_rid; wire [1:0] hp_rresp; wire hp_rlast, hp_rvalid, hp_rready;
    wire [31:0] hp_awaddr; wire [5:0] hp_awid; wire [3:0] hp_awlen; wire [2:0] hp_awsize;
    wire [1:0] hp_awburst; wire [3:0] hp_awcache; wire [2:0] hp_awprot; wire [1:0] hp_awlock; wire [3:0] hp_awqos;
    wire hp_awvalid, hp_awready;
    wire [63:0] hp_wdata; wire [7:0] hp_wstrb; wire hp_wlast, hp_wvalid, hp_wready;
    wire hp_bvalid, hp_bready;
    wire hp1_aresetn;
    wire [31:0] hp1_araddr; wire [5:0] hp1_arid; wire [3:0] hp1_arlen; wire [2:0] hp1_arsize;
    wire [1:0] hp1_arburst; wire [3:0] hp1_arcache; wire [2:0] hp1_arprot; wire [1:0] hp1_arlock; wire [3:0] hp1_arqos;
    wire hp1_arvalid, hp1_arready;
    wire [63:0] hp1_rdata; wire [5:0] hp1_rid; wire [1:0] hp1_rresp; wire hp1_rlast, hp1_rvalid, hp1_rready;

    wire fclk100;  BUFG bufg100 (.I(fclk[0]), .O(fclk100));

    (* DONT_TOUCH = "true" *) PS7 ps7_stub (
        .FCLKCLK(fclk), .FCLKRESETN(FCLKRESETN), .MAXIGP0ACLK(fclk100),
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
        .SAXIHP0RLAST(hp_rlast), .SAXIHP0RVALID(hp_rvalid), .SAXIHP0RREADY(hp_rready), .SAXIHP0RDISSUECAP1EN(1'b0),
        .SAXIHP0AWADDR(hp_awaddr), .SAXIHP0AWID(hp_awid), .SAXIHP0AWLEN(hp_awlen),
        .SAXIHP0AWSIZE(hp_awsize[1:0]), .SAXIHP0AWBURST(hp_awburst), .SAXIHP0AWCACHE(hp_awcache),
        .SAXIHP0AWPROT(hp_awprot), .SAXIHP0AWLOCK(hp_awlock), .SAXIHP0AWQOS(hp_awqos),
        .SAXIHP0AWVALID(hp_awvalid), .SAXIHP0AWREADY(hp_awready),
        .SAXIHP0WDATA(hp_wdata), .SAXIHP0WID(6'd0), .SAXIHP0WSTRB(hp_wstrb), .SAXIHP0WLAST(hp_wlast),
        .SAXIHP0WVALID(hp_wvalid), .SAXIHP0WREADY(hp_wready), .SAXIHP0WRISSUECAP1EN(1'b0),
        .SAXIHP0BVALID(hp_bvalid), .SAXIHP0BREADY(hp_bready),
        .SAXIHP1ACLK(fclk100), .SAXIHP1ARESETN(hp1_aresetn),
        .SAXIHP1ARADDR(hp1_araddr), .SAXIHP1ARID(hp1_arid), .SAXIHP1ARLEN(hp1_arlen),
        .SAXIHP1ARSIZE(hp1_arsize[1:0]), .SAXIHP1ARBURST(hp1_arburst), .SAXIHP1ARCACHE(hp1_arcache),
        .SAXIHP1ARPROT(hp1_arprot), .SAXIHP1ARLOCK(hp1_arlock), .SAXIHP1ARQOS(hp1_arqos),
        .SAXIHP1ARVALID(hp1_arvalid), .SAXIHP1ARREADY(hp1_arready),
        .SAXIHP1RDATA(hp1_rdata), .SAXIHP1RID(hp1_rid), .SAXIHP1RRESP(hp1_rresp),
        .SAXIHP1RLAST(hp1_rlast), .SAXIHP1RVALID(hp1_rvalid), .SAXIHP1RREADY(hp1_rready), .SAXIHP1RDISSUECAP1EN(1'b0),
        .SAXIHP1AWVALID(1'b0), .SAXIHP1WVALID(1'b0), .SAXIHP1BREADY(1'b0), .SAXIHP1WRISSUECAP1EN(1'b0)
    );

    //==== HDMI clocks 74.25 (pixel) + 371.25 (serial) ====
    wire clk_pix_raw, clk_ser_raw, fb, locked;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.000), .CLKFBOUT_MULT_F(37.125), .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.000), .CLKOUT1_DIVIDE(2)) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fb), .CLKFBOUT(fb),
        .CLKOUT0(clk_pix_raw), .CLKOUT1(clk_ser_raw),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked));
    wire clk_pixel, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pixel));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire hdmi_reset = ~locked;
    reg [10:0] adiv = 11'd0;  reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end

    //==== NES master clock ~21.48 MHz (video decoupled via framebuffer -> exactness not critical R1) ====
    wire nesclk_raw, nfb, nlocked;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.000), .CLKFBOUT_MULT_F(10.750), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(50.000)) mmcm_nes (   // VCO=1075, /50 = 21.5 MHz
        .CLKIN1(fclk100), .CLKFBIN(nfb), .CLKFBOUT(nfb),
        .CLKOUT0(nesclk_raw), .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(nlocked));
    wire nesclk;  BUFG bnes (.I(nesclk_raw), .O(nesclk));

    //==== self-contained reset (fclk100) ====
    reg [15:0] porc = 16'd0;  reg arstn = 1'b0;
    always @(posedge fclk100) begin
        if (!(locked & nlocked)) begin porc <= 16'd0; arstn <= 1'b0; end
        else if (porc != 16'hFFFF)  begin porc <= porc + 16'd1; arstn <= 1'b0; end
        else arstn <= 1'b1;
    end
    wire aresetn = arstn;
    // NOTE: hp_aresetn / hp1_aresetn are DRIVEN BY the PS7 stub (SAXIHPx ARESETN outputs) - do NOT drive here.
    // core_resetn MUST also wait for the HP0 AXI slave to leave reset (hp_aresetn). Otherwise fb_wr_axi
    // comes out of reset first and issues its first write while HP0 is still resetting -> that write hangs
    // (no b_valid) forever and the writer stalls after 1 burst. (This gate is what the proven ZX top does.)
    (* ASYNC_REG="TRUE" *) reg [1:0] hprstn_s = 2'b00;
    always @(posedge fclk100) hprstn_s <= {hprstn_s[0], hp_aresetn};
    wire core_resetn = arstn & hprstn_s[1];
    (* ASYNC_REG="TRUE" *) reg [1:0] pns = 2'b00;   // por synced to nesclk (for capture)
    always @(posedge nesclk) pns <= {pns[0], arstn};
    wire por_n = pns[1];

    //==== axi_ctl control plane (GP0). NES regs active via NES_CORE; ZX outputs -> stub wires, ZX inputs -> 0 ====
    wire [63:0] ctl_nes_mapper; wire [21:0] ctl_nes_ld_addr; wire [7:0] ctl_nes_ld_data;
    wire ctl_nes_ld_we, ctl_nes_ld_sel, ctl_nes_loading, ctl_nes_reset;
    wire [31:0] ctl_joy;
    // stub sinks for the ZX control outputs we don't use here
    wire zx_halt; wire zx_ram_we; wire [16:0] zx_ram_addr, zx_ram_waddr; wire [7:0] zx_ram_data;
    wire [211:0] zx_dir; wire [5:0] zx_7ffd; wire [2:0] zx_border; wire zx_dircommit, zx_portcommit;
    wire zx_osd_en, zx_osd_we; wire [9:0] zx_osd_waddr; wire [31:0] zx_osd_wdata; wire [23:0] zx_osd_bg; wire [7:0] zx_osd_op; wire [31:0] zx_osd_pos; wire [7:0] zx_vol;
    wire [31:0] zx_osd_ddr_base; wire zx_ddr_osd_en; wire [31:0] zx_ddr_osd_pos;
    wire zx_tape_run, zx_tape_earmux, zx_tape_mute; wire [1:0] zx_tape_fmode; wire zx_tape_sync, zx_tape_more, zx_tape_we; wire [31:0] zx_tape_data;
    wire zx_ban_en, zx_ban_we; wire [8:0] zx_ban_waddr; wire [31:0] zx_ban_wdata; wire [31:0] zx_ban_pos;
    wire zx_player_en, zx_audio_we; wire [31:0] zx_audio_data;
    wire zx_kbd_rd, zx_deadman; wire zx_reset; wire [8:0] zx_kbd_inj; wire zx_kbd_inj_we;
    wire [7:0] zx_kbd_tx; wire zx_kbd_tx_we;
    wire zx_pent, zx_model48, zx_ula_late, zx_force_atlas, zx_snow; wire [31:0] zx_pent_int;
    wire [8:0] zx_paper_h, zx_paper_v; wire [31:0] zx_scr_pos, zx_crop_a, zx_crop_b, zx_warp_hold, zx_sync_hold;
    wire zx_romtrap_en, zx_romtrap_done_we;
    wire [10:0] zx_scr_raddr;
    wire [31:0] cap_geom_f;
    wire [31:0] nes_dbg;    // bring-up debug -> axi_ctl memwr_cnt read @GP0+0xAC = {hpw, nes_act}
    wire [31:0] nes_dbg2;   // bring-up debug2 -> axi_ctl kbd_diag read @GP0+0xB8 = {awv_cnt, capwr}

    axi_ctl #(.VERSION(BUILD_VERSION)) ctl (
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
        // ---- NES control (active) ----
        .ctl_nes_mapper(ctl_nes_mapper), .ctl_nes_ld_addr(ctl_nes_ld_addr), .ctl_nes_ld_data(ctl_nes_ld_data),
        .ctl_nes_ld_we(ctl_nes_ld_we), .ctl_nes_ld_sel(ctl_nes_ld_sel), .ctl_nes_loading(ctl_nes_loading), .ctl_nes_reset(ctl_nes_reset),
        // ---- used: joystick ----
        .ctl_joy(ctl_joy),
        // ---- ZX outputs -> stub wires ----
        .ctl_halt(zx_halt), .ctl_ram_we(zx_ram_we), .ctl_ram_addr(zx_ram_addr), .ctl_ram_waddr(zx_ram_waddr), .ctl_ram_data(zx_ram_data),
        .ctl_dir(zx_dir), .ctl_7ffd(zx_7ffd), .ctl_border(zx_border), .ctl_dir_commit(zx_dircommit), .ctl_port_commit(zx_portcommit),
        .ctl_osd_enable(zx_osd_en), .ctl_osd_we(zx_osd_we), .ctl_osd_waddr(zx_osd_waddr), .ctl_osd_wdata(zx_osd_wdata),
        .ctl_osd_bg(zx_osd_bg), .ctl_osd_op(zx_osd_op), .ctl_osd_pos(zx_osd_pos), .ctl_vol(zx_vol),
        .ctl_osd_ddr_base(zx_osd_ddr_base), .ctl_ddr_osd_en(zx_ddr_osd_en), .ctl_ddr_osd_pos(zx_ddr_osd_pos),
        .ctl_tape_run(zx_tape_run), .ctl_tape_earmux(zx_tape_earmux), .ctl_tape_mute(zx_tape_mute), .ctl_tape_fmode(zx_tape_fmode),
        .ctl_tape_sync(zx_tape_sync), .ctl_tape_more(zx_tape_more), .ctl_tape_we(zx_tape_we), .ctl_tape_data(zx_tape_data),
        .tape_full(1'b0), .tape_playing(1'b0), .tape_diag_count(32'd0), .tape_diag_hash(32'd0), .tape_diag_gaps(32'd0), .tape_diag_resumes(32'd0),
        .fe_trace_count(32'd0), .fe_trace_hash(32'd0), .fe_trace_last(32'd0),
        .ctl_ban_enable(zx_ban_en), .ctl_ban_we(zx_ban_we), .ctl_ban_waddr(zx_ban_waddr), .ctl_ban_wdata(zx_ban_wdata), .ctl_ban_pos(zx_ban_pos),
        .ctl_player_en(zx_player_en), .ctl_audio_we(zx_audio_we), .ctl_audio_data(zx_audio_data),
        .aud_full(1'b0), .aud_empty(1'b1), .aud_rdcount(7'd0),
        .kbd_fifo_dout(kbd_fifo_dout), .kbd_fifo_empty(kbd_fifo_empty), .kbd_fifo_rd(zx_kbd_rd), .kbd_deadman_kick(zx_deadman),
        .halt_ack(1'b0), .ram_busy(1'b0), .reset_busy(1'b0), .ctl_reset(zx_reset),
        .ctl_kbd_inject(zx_kbd_inj), .ctl_kbd_inject_we(zx_kbd_inj_we), .memwr_cnt(nes_dbg),
        .ctl_kbd_tx_data(zx_kbd_tx), .ctl_kbd_tx_we(zx_kbd_tx_we),
        .kbd_tx_busy(1'b0), .kbd_tx_ack(1'b0), .kbd_diag(nes_dbg2),
        .ctl_pentagon(zx_pent), .ctl_model48(zx_model48), .ctl_ula_late(zx_ula_late), .ctl_force_atlas(zx_force_atlas), .ctl_snow_off(zx_snow), .ctl_pent_int(zx_pent_int),
        .ctl_paper_h(zx_paper_h), .ctl_paper_v(zx_paper_v), .ctl_scr_pos(zx_scr_pos),
        .ctl_crop_a(zx_crop_a), .ctl_crop_b(zx_crop_b), .ctl_warp_hold(zx_warp_hold), .ctl_sync_hold(zx_sync_hold),
        .cap_geom(cap_geom_f),
        .ctl_romtrap_en(zx_romtrap_en), .ctl_romtrap_done_we(zx_romtrap_done_we),
        .rt_pending_a_in(1'b0), .p7ffd_s1_in(6'd0), .reg_rd1_in(212'd0), .sync_diag_in(32'd0),
        .ctl_scr_raddr(zx_scr_raddr), .scr_rdata(32'd0)
    );

    //==== NES core + video ====
    wire [5:0] nes_color; wire [8:0] nes_cycle, nes_scanline; wire [15:0] nes_sample;
    nes_wrap nescore (
        .clk(nesclk), .ld_clk(fclk100),                       // core clk + control-plane (load) clk
        .reset_nes(ctl_nes_reset), .cold_reset(~arstn), .sys_type(2'd0),   // aclk-domain resets (synced inside)
        .mapper_flags(ctl_nes_mapper),
        .loading(ctl_nes_loading), .ld_we(ctl_nes_ld_we), .ld_sel(ctl_nes_ld_sel),
        .ld_addr(ctl_nes_ld_addr), .ld_data(ctl_nes_ld_data),
        .joy1(ctl_joy[7:0]), .joy2(ctl_joy[23:16]),
        .color(nes_color), .cycle(nes_cycle), .scanline(nes_scanline),
        .emphasis(), .sample(nes_sample), .apu_ce(),
        .mem_dbg(nes_mem_dbg)
    );
    wire [31:0] nes_mem_dbg;   // {vram_ce_access_cnt, ciram_write_cnt} on nesclk (read approx via 0xB8)
    wire vid_r, vid_g, vid_b, vid_i, vid_hsync, vid_vsync, vid_blank, vid_wr_ce;
    nes_video nesvid (
        .clk(nesclk), .color(nes_color), .cycle(nes_cycle), .scanline(nes_scanline),
        .wr_ce(vid_wr_ce), .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i)
    );

    //==== capture -> DDR triple buffer -> line scanout (NES 256x240) ====
    wire cap_wr; wire [63:0] cap_din;
    fb_capture_rr #(.FB_W(256), .FB_H(240)) capz (
        .wr_clk(nesclk), .resetn(por_n), .wr_ce(vid_wr_ce),
        .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i), .enable(1'b1),
        .fifo_wr(cap_wr), .fifo_din(cap_din), .cap_geom(cap_geom_f)
    );
    wire fifo_empty, fifo_rd; wire [63:0] fifo_dout; wire [6:0] fifo_rdcount;
    async_fifo #(.DW(64), .AW(6)) ddrfifo (
        .wr_clk(nesclk), .wr_rst_n(por_n), .wr_en(cap_wr), .din(cap_din), .full(),
        .rd_clk(fclk100), .rd_rst_n(core_resetn), .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .rd_count(fifo_rdcount));

    // frame_kick from the NES vsync synced to fclk100
    (* ASYNC_REG="TRUE" *) reg [2:0] vbl_s = 3'd0;
    always @(posedge fclk100) vbl_s <= {vbl_s[1:0], vid_vsync};
    wire frame_kick = vbl_s[2] ^ vbl_s[1];
    reg frame_kick_d = 1'b0;  always @(posedge fclk100) frame_kick_d <= frame_kick;

    wire wr_done; wire [31:0] wr_base, disp_base;
    fb_bufmgr3 ddrbuf (.clk(fclk100), .resetn(core_resetn),
        .frame_done(wr_done), .frame_kick(frame_kick),
        .wr_base(wr_base), .disp_base(disp_base), .wr_buf_o(), .disp_buf_o(), .ready_buf_o());
    fb_wr_axi #(.WORDS(13'd3840)) ddrwr (   // 256*240/16 = 3840 words/frame
        .clk(fclk100), .resetn(core_resetn), .base(wr_base),
        .fifo_empty(fifo_empty), .fifo_dout(fifo_dout), .fifo_rd(fifo_rd),
        .aw_addr(hp_awaddr), .aw_id(hp_awid), .aw_len(hp_awlen), .aw_size(hp_awsize),
        .aw_burst(hp_awburst), .aw_cache(hp_awcache), .aw_prot(hp_awprot),
        .aw_lock(hp_awlock), .aw_qos(hp_awqos), .aw_valid(hp_awvalid), .aw_ready(hp_awready),
        .w_data(hp_wdata), .w_strb(hp_wstrb), .w_last(hp_wlast), .w_valid(hp_wvalid), .w_ready(hp_wready),
        .b_valid(hp_bvalid), .b_ready(hp_bready), .frame_done(wr_done), .busy_o());

    // ---- NES bring-up debug -> axi_ctl memwr_cnt read (GP0+0xAC) = {hpw[31:16], nes_act[15:0]} ----
    // nes_act advances iff the PPU produces pixels (vid_wr_ce on nesclk) => core is running.
    // hpw advances iff fb_wr_axi issues AXI-HP writes that HP0 accepts => write path reaches DDR.
    reg [15:0] wrce_ctr = 16'd0;  reg wrce_tog = 1'b0;
    always @(posedge nesclk) if (vid_wr_ce) begin
        wrce_ctr <= wrce_ctr + 16'd1;
        if (wrce_ctr[7:0] == 8'hFF) wrce_tog <= ~wrce_tog;
    end
    (* ASYNC_REG="TRUE" *) reg [2:0] wt_s = 3'd0;
    always @(posedge fclk100) wt_s <= {wt_s[1:0], wrce_tog};
    reg [15:0] nes_act = 16'd0;
    always @(posedge fclk100) if (wt_s[2] ^ wt_s[1]) nes_act <= nes_act + 16'd1;
    reg [15:0] hpw = 16'd0;
    always @(posedge fclk100) if (hp_awvalid & hp_awready) hpw <= hpw + 16'd1;
    assign nes_dbg = {hpw, nes_act};
    // debug2: capwr = fb_capture emits to FIFO (nesclk); awv = fb_wr_axi requests aw (fclk100)
    reg [15:0] capwr_ctr = 16'd0;
    always @(posedge nesclk) if (cap_wr) capwr_ctr <= capwr_ctr + 16'd1;
    (* ASYNC_REG="TRUE" *) reg [15:0] capwr_s1 = 16'd0, capwr_s2 = 16'd0;   // approx CDC (is-it-moving)
    always @(posedge fclk100) begin capwr_s1 <= capwr_ctr; capwr_s2 <= capwr_s1; end
    reg [15:0] awv_ctr = 16'd0;
    always @(posedge fclk100) if (hp_awvalid) awv_ctr <= awv_ctr + 16'd1;
    // sync nes_mem_dbg (nesclk) -> fclk100 for a reliable read at 0xB8. dbg[3:0] are STICKY bits (1-bit CDC = safe):
    // [0]=vram_ce ever asserted, [1]=CPU ever wrote nametable(CIRAM), [2]=CPU ever wrote memory. [31:16]=ciram write count.
    (* ASYNC_REG="TRUE" *) reg [31:0] memdbg_s1 = 32'd0, memdbg_s2 = 32'd0;
    always @(posedge fclk100) begin memdbg_s1 <= nes_mem_dbg; memdbg_s2 <= memdbg_s1; end
    assign nes_dbg2 = memdbg_s2;   // 0xB8

    wire [23:0] rgb24;  wire [10:0] cx, cy;  wire ld_live; wire [31:0] ld_underrun;
    fb_line_disp #(.SRC_W(256), .STRIDE(256), .CROP_W(256), .HMARGIN(0), .SX0(0),
        .CROP_H(240), .VMARGIN(0)) ddrdisp (
        .clk(fclk100), .resetn(core_resetn), .disp_base(disp_base), .frame_kick(frame_kick_d),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .hmargin_a(12'd160), .vmargin_a(12'd120),      // center 256*? in 720p; tune later (5x/3x scale is in fb_line_disp)
        .sx0_a(12'd0), .sy0_a(12'd0), .cropw_a(12'd256), .croph_a(12'd240),
        .rgb(rgb24), .live(ld_live), .underrun_cnt(ld_underrun));

    // OSD compositor (1-bpp toast strip over raw NES scanout)
    wire [23:0] rgb24_osd;
    osd_compositor osd_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .osd_enable_a(zx_osd_en), .osd_we(zx_osd_we),
        .osd_waddr(zx_osd_waddr), .osd_wdata(zx_osd_wdata), .osd_bg_a(zx_osd_bg), .osd_op_a(zx_osd_op), .osd_pos_a(zx_osd_pos),
        .cx(cx), .cy(cy), .rgb_in(rgb24), .rgb_out(rgb24_osd)
    );

    // DDR-backed TRUE-COLOUR OSD layer read over HP1 port
    reg [31:0] odpos_s1=32'd0, odpos_s2=32'd0, odpos_s3=32'd0, odpos_q=32'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] oden_s = 2'b00;
    always @(posedge clk_pixel) begin
        odpos_s1<=zx_ddr_osd_pos; odpos_s2<=odpos_s1; odpos_s3<=odpos_s2;
        if (odpos_s2==odpos_s3) odpos_q<=odpos_s2;
        oden_s <= {oden_s[0], zx_ddr_osd_en};
    end
    wire [23:0] osd_ddr_rgb; wire [7:0] osd_ddr_a; wire osd_ddr_active;
    osd_ddr_rd #(.CW(640), .CH(400)) osddr (
        .clk(fclk100), .resetn(core_resetn), .osd_base(zx_osd_ddr_base), .frame_kick(frame_kick_d),
        .ar_addr(hp1_araddr), .ar_id(hp1_arid), .ar_len(hp1_arlen), .ar_size(hp1_arsize),
        .ar_burst(hp1_arburst), .ar_cache(hp1_arcache), .ar_prot(hp1_arprot),
        .ar_lock(hp1_arlock), .ar_qos(hp1_arqos), .ar_valid(hp1_arvalid), .ar_ready(hp1_arready),
        .r_data(hp1_rdata), .r_last(hp1_rlast), .r_valid(hp1_rvalid), .r_ready(hp1_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .x0(odpos_q[10:0]), .y0(odpos_q[26:16]), .en(oden_s[1]),
        .osd_rgb(osd_ddr_rgb), .osd_a(osd_ddr_a), .osd_active(osd_ddr_active)
    );

    // Pipelining stage for OSD blend alignment
    reg [10:0] cx_d1 = 11'd0, cx_d2 = 11'd0, cy_d1 = 11'd0, cy_d2 = 11'd0;
    always @(posedge clk_pixel) begin cx_d1<=cx; cx_d2<=cx_d1; cy_d1<=cy; cy_d2<=cy_d1; end

    reg [23:0] rgb24_osd_q = 24'd0;
    always @(posedge clk_pixel) rgb24_osd_q <= rgb24_osd;

    reg        od_act_d1 = 1'b0; reg [7:0] od_a_d1 = 8'd0; reg [23:0] od_rgb_d1 = 24'd0;
    always @(posedge clk_pixel) begin
        od_act_d1 <= osd_ddr_active; od_a_d1 <= osd_ddr_a; od_rgb_d1 <= osd_ddr_rgb;
    end

    wire [7:0]  od_ia = 8'd255 - od_a_d1;
    wire [15:0] od_r = od_rgb_d1[23:16]*od_a_d1 + rgb24_osd_q[23:16]*od_ia;
    wire [15:0] od_g = od_rgb_d1[15:8] *od_a_d1 + rgb24_osd_q[15:8] *od_ia;
    wire [15:0] od_b = od_rgb_d1[7:0]  *od_a_d1 + rgb24_osd_q[7:0]  *od_ia;
    reg [23:0] rgb24_ddr_q = 24'd0;
    always @(posedge clk_pixel)
        rgb24_ddr_q <= od_act_d1 ? { od_r[15:8], od_g[15:8], od_b[15:8] } : rgb24_osd_q;

    // Independent status BANNER
    wire [23:0] rgb24_ovl;
    banner_compositor banner_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .ban_enable_a(zx_ban_en), .ban_we(zx_ban_we),
        .ban_waddr(zx_ban_waddr), .ban_wdata(zx_ban_wdata), .ban_pos_a(zx_ban_pos),
        .cx(cx_d2), .cy(cy_d2), .rgb_in(rgb24_ddr_q), .rgb_out(rgb24_ovl)
    );

    //==== HDMI out (pipelined and composited) ====
    wire [2:0] tmds;  wire tmds_clock;
    wire signed [15:0] nes_audio = $signed(nes_sample) - 16'sd16384;   // rough unsigned->signed centering
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser), .clk_pixel(clk_pixel), .clk_audio(clk_audio_r), .reset(hdmi_reset),
        .rgb(rgb24_ovl), .audio_left(nes_audio), .audio_right(nes_audio),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy));
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi; generate for (gi=0; gi<3; gi=gi+1) begin : tb
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    //=============================================================================================
    // PS/2 keyboard receiver (Step 15 NES port)
    // Runs on fclk100 using a 3.57 MHz clock enable to match the Sorgelig ps2 watchdog timing.
    //=============================================================================================
    reg [1:0] ps2c_s = 2'b11, ps2d_s = 2'b11;        // 2-FF sync of the async pins
    always @(posedge fclk100) begin ps2c_s <= {ps2c_s[0], ps2_clk}; ps2d_s <= {ps2d_s[0], ps2_data}; end

    reg [4:0] ce_div = 5'd0;
    always @(posedge fclk100) ce_div <= (ce_div == 5'd27) ? 5'd0 : ce_div + 5'd1;
    wire ce_3m5 = (ce_div == 5'd0);

    wire       ps2_strb, ps2_make, ps2_perr;
    wire [7:0] ps2_code;
    ps2 ps2_i (
        .clock(fclk100), .ce(ce_3m5),
        .ps2Ck(ps2c_s[1]), .ps2D(ps2d_s[1]),
        .strb(ps2_strb), .make(ps2_make), .code(ps2_code), .perr(ps2_perr)
    );

    wire [8:0] kbd_fifo_dout;
    wire       kbd_fifo_empty;
    async_fifo #(.DW(9), .AW(7)) kbd_fifo_i (
        .wr_clk(fclk100),  .wr_rst_n(aresetn),  .wr_en(ps2_strb),
        .din({ps2_make, ps2_code}), .full(),
        .rd_clk(fclk100), .rd_rst_n(aresetn), .rd_en(zx_kbd_rd),
        .dout(kbd_fifo_dout), .empty(kbd_fifo_empty), .rd_count()
    );

    assign ps2_clk  = 1'bz;
    assign ps2_data = 1'bz;

    assign led_lock = arstn;
    reg [25:0] hb = 26'd0;  always @(posedge clk_pixel) hb <= hb + 26'd1;
    assign led_heart = hb[24];
endmodule
