// bulbulator_nes_top.v - NES/Famicom/Dendy top for BulbuLator.
// CE24: the whole machine-agnostic shell (PS7/AXI, HDMI, DDR framebuffer chain, OSD layers, PS/2
// RX+TX, scancode FIFO, ARM music FIFO, volume, QUIESCE, axi_ctl) now lives in control_plane.v -
// ONE instance, impossible to carry over half of it (the drift that cost the missing ps2_tx, the
// hard-coded ZX lead-in, the diverged joypad bit order and the compile-time screen scale).
// This file is ONLY the NES: its clock, the core, its video/audio conditioning, its debug counters.
// Built with -verilog_define NES_CORE (activates the ctl_nes_* registers).
`default_nettype wire

module bulbulator_nes_top (
    output wire       TMDS_Clk_p,  output wire TMDS_Clk_n,
    output wire [2:0] TMDS_Data_p, output wire [2:0] TMDS_Data_n,
    input  wire [3:0] btn,
    inout  wire       ps2_clk, inout wire ps2_data,
    output wire       led_lock, output wire led_heart
);
    localparam [31:0] BUILD_VERSION = 32'hB01BCE30;   // CE28 = сборка кадра клавиатуры в фабрике (ext-бит + фильтр байтов-ответов) + свой регистр диагностики PS/2 у оболочки. CE26 = CE25 + incremental pixel-path address generation (see fb_line_disp: the 74.25 MHz fix)
    // CE25 = CE24 + hardware memory-path probe on AXI-HP2 (ddr_probe): real read latency/throughput
    // CE24 = CE23 re-housed: the shared shell is control_plane.v
    // CE23 = PS/2 host TX ported into the NES top (NumLock LED / keyboard commands were impossible)
    // CE22 = UNIFORM joypad bit order (0=R 1=L 2=D 3=U 4=A 5=B 6=Sel 7=Start) - see nes_wrap.v

    //==== the machine-agnostic shell ====
    wire fclk100, clk_pixel, clk_audio, aresetn, core_resetn;
    wire [63:0] ctl_nes_mapper; wire [21:0] ctl_nes_ld_addr; wire [7:0] ctl_nes_ld_data;
    wire ctl_nes_ld_we, ctl_nes_ld_sel, ctl_nes_loading, ctl_nes_reset;
    wire [31:0] ctl_joy, ctl_mach_cfg;
    wire [8:0]  ctl_paper_h, ctl_paper_v;
    wire        ctl_halt;
    wire [15:0] hpw;                 // AXI-HP writes accepted (shell tap - the classic liveness counter)
    wire        cap_fifo_ov;         // capture FIFO overflow sticky (shell tap)
    wire [31:0] nes_dbg;             // -> memwr_cnt 0xAC = {hpw, nes_act}
    wire [31:0] nes_dbg2;            // -> kbd_diag  0xB8 = {ciram_writes, fifo_ov, sticky bits}

    // CE29: своя идентичность ('NE' + вариант 1). Раньше NES представлялся оболочкой как "ZX 128K".
    control_plane #(
        .VERSION(BUILD_VERSION), .MACHINE_ID(32'h00014E45),
        .POR_BITS(16), .WAIT_HDMI_LOCK(1),
        // capture: 256x240 @ 8bpp palette index, lead-in from the MEASURED first visible line
        .CAP_W(256), .CAP_H(240), .CAP_BPP(8), .CAP_LEADIN_AUTO(1),
        .WR_WORDS(7680),                        // 256*240/8 words per frame
        .KICK_CORE_VSYNC(1),                    // buffer swap on the NES vsync
        // scanout: 8bpp + NES palette, fixed full-frame window (the ARM's CROP regs carry ZX maths)
        .SRC_W(256), .STRIDE(256), .CROP_W(256), .CROP_H(240), .HMARGIN(0), .VMARGIN(0), .SX0(0),
        .SRC_BPP(8), .WSH(3), .LBPP(3), .FBURSTS(2),
        .LIVE_CROP(0),
        .AUDIO_DC_BLOCK(0),
        // PS/2 on the internal fclk100/28 clock enable (machine-independent home)
        .PS2_INT_CE(1),
        .PS2TX_INHIBIT(14100),                  // >=100 us request-to-send at 100 MHz
        .PS2TX_TIMEOUT(500000)
    ) shell (
        .TMDS_Clk_p(TMDS_Clk_p), .TMDS_Clk_n(TMDS_Clk_n),
        .TMDS_Data_p(TMDS_Data_p), .TMDS_Data_n(TMDS_Data_n),
        .ps2_clk(ps2_clk), .ps2_data(ps2_data),
        .led_heart(led_heart),
        .fclk100_o(fclk100), .clk_pixel_o(clk_pixel), .clk_audio_o(clk_audio),
        .aresetn_o(aresetn), .core_resetn_o(core_resetn),
        .ext_lock_i(nlocked),
        // machine video (nesclk domain)
        .cap_clk_i(nesclk), .cap_rstn_i(por_n), .cap_ce_i(vid_wr_ce),
        .cap_hsync_i(vid_hsync), .cap_vsync_i(vid_vsync), .cap_blank_i(vid_blank),
        .cap_r_i(vid_r), .cap_g_i(vid_g), .cap_b_i(vid_b), .cap_i_i(vid_i),
        .cap_pix8_i(vid_pix8),
        // machine audio (pre-volume mix computed below)
        .aud_src_l_i(src_left), .aud_src_r_i(src_right),
        .player_pcm_o(player_pcm), .player_gain_o(pgain), .machine_gain_o(mgn),
        // PS/2 stream taps: internal CE -> kclk_i/kce_i unused
        .kclk_i(1'b0), .kce_i(1'b0),
        // CE30/B0067: память машины в DDR (порт HP2 теперь её). Пока заглушки - машина к ней
        // ещё не подведена; испытательный стенд идёт через регистр 0x148 от ARM.
        // Картридж в DDR (задача E) сюда ещё не подведён: дедлайн PPU 186 нс требует строчного
        // кеша, иначе голое чтение не успевает. Стенд ARM (регистр 0x148) работает и так.
        .mem_mclk_i(nesclk), .mem_addr_i(20'd0), .mem_wdata_i(8'd0),
        .mem_rd_i(1'b0), .mem_wr_i(1'b0), .mem_rdata_o(), .mem_wait_o(),
        .mach_dbg_i(32'd0),   // слот отладки NES пока не наполнен
        .aud_dbg_i (32'd0),   // B0088: пики звука NES пока не наполнены
        .ps2_strb_o(), .ps2_make_o(), .ps2_code_o(), .ps2tx_busy_o(),
        .ps2_diag_o(),
        // QUIESCE: no NES-side DDR masters (yet - the DDR cartridge joins here)
        .ctl_quiesce_o(), .mach_axi_idle_i(1'b1),
        .wr_accept_cnt_o(hpw), .cap_fifo_ov_o(cap_fifo_ov), .ld_live_o(),
        // NES registers
        .ctl_nes_mapper_o(ctl_nes_mapper), .ctl_nes_ld_addr_o(ctl_nes_ld_addr), .ctl_nes_ld_data_o(ctl_nes_ld_data),
        .ctl_nes_ld_we_o(ctl_nes_ld_we), .ctl_nes_ld_sel_o(ctl_nes_ld_sel),
        .ctl_nes_loading_o(ctl_nes_loading), .ctl_nes_reset_o(ctl_nes_reset),
        // shared registers the NES actually consumes
        .ctl_halt_o(ctl_halt), .ctl_joy_o(ctl_joy), .ctl_mach_cfg_o(ctl_mach_cfg),
        .ctl_paper_h_o(ctl_paper_h), .ctl_paper_v_o(ctl_paper_v),
        // ZX-only register outputs: left unconnected on purpose (outputs are safe to ignore)
        .ctl_ram_we_o(), .ctl_ram_addr_o(), .ctl_ram_waddr_o(), .ctl_ram_data_o(),
        .ctl_dir_o(), .ctl_7ffd_o(), .ctl_border_o(), .ctl_dir_commit_o(), .ctl_port_commit_o(),
        .ctl_reset_o(), .ctl_osd_enable_o(), .ctl_ddr_osd_en_o(),
        .ctl_tape_run_o(), .ctl_tape_earmux_o(), .ctl_tape_mute_o(), .ctl_tape_fmode_o(),
        .ctl_tape_sync_o(), .ctl_tape_more_o(), .ctl_tape_we_o(), .ctl_tape_data_o(),
        .ctl_kbd_inject_o(), .ctl_kbd_inject_we_o(), .kbd_deadman_kick_o(),
        .ctl_pentagon_o(), .ctl_model48_o(), .ctl_ula_late_o(), .ctl_force_atlas_o(), .ctl_snow_off_o(),
        .ctl_pent_int_o(), .ctl_warp_hold_o(), .ctl_sync_hold_o(),
        .ctl_romtrap_en_o(), .ctl_romtrap_done_we_o(), .ctl_scr_raddr_o(),
        // machine status inputs: the NES has no tape/ROM-trap/RAM-inject machinery
        .scr_rdata_i(32'd0),
        .tape_full_i(1'b0), .tape_playing_i(1'b0),
        .tape_diag_count_i(32'd0), .tape_diag_hash_i(32'd0), .tape_diag_gaps_i(32'd0), .tape_diag_resumes_i(32'd0),
        .fe_trace_count_i(32'd0), .fe_trace_hash_i(32'd0), .fe_trace_last_i(32'd0),
        .halt_ack_i(halt_ns[1]),                // real HALT_ACK = the clock-gate state (v162)
        .ram_busy_i(1'b0), .reset_busy_i(1'b0),
        .rt_pending_a_i(1'b0), .p7ffd_s1_i(6'd0), .reg_rd1_i(212'd0), .sync_diag_i(16'd0),
        .memwr_cnt_i(nes_dbg),                  // 0xAC = {hpw, nes_act}
        .kbd_diag_i(nes_dbg2)                   // 0xB8 = NES memory-debug word
    );

    //==== NES master clock ~21.48 MHz (video decoupled via framebuffer) ====
    wire nesclk_raw, nfb, nlocked;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.000), .CLKFBOUT_MULT_F(10.750), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(50.000)) mmcm_nes (   // VCO=1075, /50 = 21.5 MHz
        .CLKIN1(fclk100), .CLKFBIN(nfb), .CLKFBOUT(nfb),
        .CLKOUT0(nesclk_raw), .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(nlocked));
    wire nesclk_free;  BUFG bnes_free (.I(nesclk_raw), .O(nesclk_free));
    // v161 PAUSE: full-machine freeze - the shell's HALT gates the NES master clock (BUFGCE),
    // so CPU+PPU+APU+capture freeze coherently and the frame stays put.
    (* ASYNC_REG="TRUE" *) reg [1:0] halt_ns = 2'b00;
    always @(posedge nesclk_free) halt_ns <= {halt_ns[0], ctl_halt};
    wire nesclk;  BUFGCE bnes (.I(nesclk_raw), .CE(~halt_ns[1]), .O(nesclk));

    // core-domain POR (from the shell's aresetn)
    (* ASYNC_REG="TRUE" *) reg [1:0] pns = 2'b00;
    always @(posedge nesclk) pns <= {pns[0], aresetn};
    wire por_n = pns[1];

    // v165/CE16: console region. MACHINE_CFG[1:0] = region (0=NTSC, 1=PAL, 2=Dendy); static, 2FF.
    (* ASYNC_REG="TRUE" *) reg [1:0] region_s1 = 2'b00, region_s2 = 2'b00;
    always @(posedge nesclk) begin region_s1 <= ctl_mach_cfg[1:0]; region_s2 <= region_s1; end

    //==== NES core + video ====
    wire [5:0] nes_color; wire [8:0] nes_cycle, nes_scanline; wire [15:0] nes_sample;
    wire [31:0] nes_mem_dbg;   // {vram_ce_access_cnt, ciram_write_cnt} on nesclk
    nes_wrap nescore (
        .clk(nesclk), .ld_clk(fclk100),
        .reset_nes(ctl_nes_reset), .cold_reset(~aresetn), .sys_type(region_s2),
        .mapper_flags(ctl_nes_mapper),
        .loading(ctl_nes_loading), .ld_we(ctl_nes_ld_we), .ld_sel(ctl_nes_ld_sel),
        .ld_addr(ctl_nes_ld_addr), .ld_data(ctl_nes_ld_data),
        .joy1(ctl_joy[7:0]), .joy2(ctl_joy[23:16]),
        .color(nes_color), .cycle(nes_cycle), .scanline(nes_scanline),
        .emphasis(), .sample(nes_sample), .apu_ce(),
        .mem_dbg(nes_mem_dbg)
    );
    wire vid_r, vid_g, vid_b, vid_i, vid_hsync, vid_vsync, vid_blank, vid_wr_ce;
    wire [7:0] vid_pix8;
    nes_video nesvid (
        .clk(nesclk), .color(nes_color), .cycle(nes_cycle), .scanline(nes_scanline),
        .h_off(ctl_paper_h[7:0]), .v_off(ctl_paper_v[7:0]),   // v160: Picture X/Y pan
        .wr_ce(vid_wr_ce), .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i), .pix8(vid_pix8)
    );

    //==== NES debug words (fed back into the shell's repurposable registers) ====
    // nes_act advances iff the PPU produces pixels => the core is running.
    reg [15:0] wrce_ctr = 16'd0;  reg wrce_tog = 1'b0;
    always @(posedge nesclk) if (vid_wr_ce) begin
        wrce_ctr <= wrce_ctr + 16'd1;
        if (wrce_ctr[7:0] == 8'hFF) wrce_tog <= ~wrce_tog;
    end
    (* ASYNC_REG="TRUE" *) reg [2:0] wt_s = 3'd0;
    always @(posedge fclk100) wt_s <= {wt_s[1:0], wrce_tog};
    reg [15:0] nes_act = 16'd0;
    always @(posedge fclk100) if (wt_s[2] ^ wt_s[1]) nes_act <= nes_act + 16'd1;
    assign nes_dbg = {hpw, nes_act};
    // 0xB8: [31:16]=ciram write count, [15]=capture FIFO overflow sticky, [14:0]=core sticky bits
    (* ASYNC_REG="TRUE" *) reg [31:0] memdbg_s1 = 32'd0, memdbg_s2 = 32'd0;
    always @(posedge fclk100) begin memdbg_s1 <= nes_mem_dbg; memdbg_s2 <= memdbg_s1; end
    assign nes_dbg2 = {memdbg_s2[31:16], cap_fifo_ov, memdbg_s2[14:0]};

    //==== audio: APU + ARM player crossfade (pre-volume; the shell applies volume + HDMI) ====
    wire [31:0] player_pcm; wire [8:0] pgain, mgn;
    wire signed [15:0] apu_pcm = $signed({~nes_sample[15], nes_sample[14:0]});
    wire signed [25:0] lmix_p = apu_pcm * $signed({1'b0,mgn}) + $signed(player_pcm[15:0])  * $signed({1'b0,pgain});
    wire signed [25:0] rmix_p = apu_pcm * $signed({1'b0,mgn}) + $signed(player_pcm[31:16]) * $signed({1'b0,pgain});
    wire signed [16:0] lmix_s = lmix_p >>> 8;
    wire signed [16:0] rmix_s = rmix_p >>> 8;
    wire signed [15:0] src_left  = (lmix_s > 17'sd32767) ? 16'sd32767 : (lmix_s < -17'sd32768) ? -16'sd32768 : lmix_s[15:0];
    wire signed [15:0] src_right = (rmix_s > 17'sd32767) ? 16'sd32767 : (rmix_s < -17'sd32768) ? -16'sd32768 : rmix_s[15:0];

    assign led_lock = aresetn;
endmodule
