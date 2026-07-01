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
module bulbulator_zx_ddr_top
(
    output wire       TMDS_Clk_p,     // F19
    output wire       TMDS_Clk_n,     // F20
    output wire [2:0] TMDS_Data_p,    // D19 / C20 / B19
    output wire [2:0] TMDS_Data_n,    // D20 / B20 / A20

    input  wire [3:0] btn,            // P19 / T19 / U20 / U19, active-low
    input  wire       ear_in,         // J19, tape audio in (LVCMOS33, PULLDOWN)
    input  wire       ps2_clk,        // G19 (DATA2-07), PS/2 keyboard clock
    input  wire       ps2_data,       // H20 (DATA2-08), PS/2 keyboard data

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

    // S_AXI_HP0: read (DDR-framebuffer loader) + write (capture writer). ACLK = fclk100.
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
        .MAXIGP0RLAST   (gp0_rlast),   .MAXIGP0RVALID (gp0_rvalid),  .MAXIGP0RREADY (gp0_rready),
        // ---- S_AXI_HP0 : read (loader) + write (capture writer) ----
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
    // PS/2 keyboard (real keys) + Ctrl+Alt+Del / Ctrl+Alt+Ins reset hotkeys. Spectrum domain,
    // pe3M5 enable (like kbd_buttons). The core's ps2.v decodes the 11-bit frames; the 0xE0
    // extended prefix is harmlessly ignored, so Del(0x71)/Ins(0x70) base codes are seen.
    //=============================================================================================
    reg [1:0] ps2c_s = 2'b11, ps2d_s = 2'b11;        // 2-FF sync of the async pins
    always @(posedge spclk) begin ps2c_s <= {ps2c_s[0], ps2_clk}; ps2d_s <= {ps2d_s[0], ps2_data}; end

    wire       ps2_strb, ps2_make;
    wire [7:0] ps2_code;
    ps2 ps2_i (
        .clock(spclk), .ce(pe3M5),
        .ps2Ck(ps2c_s[1]), .ps2D(ps2d_s[1]),
        .strb(ps2_strb), .make(ps2_make), .code(ps2_code)
    );

    // Pause key = E1 14 77 (make) / E1 F0 14 F0 77 (break) is ARM-owned (intercepted from the always-
    // tap FIFO). Suppress its whole byte run from the Z80 matrix AND the hotkey latches, so a resume
    // can never leak Symbol-Shift (0x14) into the core or stick a reset-combo flag. Anchor on 0xE1
    // (no other set-2 key emits it); eat up to 4 following bytes (covers make 14 77 + break F0 14 F0 77).
    reg [2:0] pse = 3'd0;
    always @(posedge spclk) if (pe3M5 && ps2_strb) begin
        if (ps2_code == 8'hE1) pse <= 3'd4;
        else if (pse != 3'd0)  pse <= pse - 3'd1;
    end
    wire pause_byte = (ps2_code == 8'hE1) | (pse != 3'd0);

    // Held state of the hotkey keys (make=0 => pressed). Qualified by ~pause_byte (Pause never touches
    // a combo flag); belt-and-suspenders: ANY 0xF0 break frame clears ALL latches, so no key can leave
    // ctrl_h/alt_h/del_h permanently stuck and silently arm Ctrl+Alt+Del. Normal press/release still
    // works: a held key sets its latch on make; F0+code clears it (and the per-key make=1 agrees).
    reg ctrl_h = 1'b0, alt_h = 1'b0, del_h = 1'b0, ins_h = 1'b0, f11_h = 1'b0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~pause_byte) begin
        if (ps2_code == 8'hF0) begin ctrl_h<=1'b0; alt_h<=1'b0; del_h<=1'b0; ins_h<=1'b0; f11_h<=1'b0; end
        else case (ps2_code)
            8'h14: ctrl_h <= ~ps2_make;   // Ctrl (also Symbol Shift in the matrix)
            8'h11: alt_h  <= ~ps2_make;   // Alt
            8'h71: del_h  <= ~ps2_make;   // Delete
            8'h70: ins_h  <= ~ps2_make;   // Insert
            8'h78: f11_h  <= ~ps2_make;   // F11
            default: ;
        endcase
    end
    wire soft_combo = ctrl_h & alt_h & del_h;        // Ctrl+Alt+Del -> soft reset
    wire nmi_combo  = ctrl_h & alt_h & ins_h;        // Ctrl+Alt+Ins -> NMI (Magic / freezer)
    wire hard_combo = f11_h;                          // F11          -> hard / cold reset (RAM wipe)

    // NMI: one short pulse on the Ctrl+Alt+Ins press edge -> the core's nmi input.
    reg       nmi_d   = 1'b0;
    reg [4:0] nmi_cnt = 5'd0;
    always @(posedge spclk) begin
        nmi_d <= nmi_combo;
        if (nmi_combo & ~nmi_d)   nmi_cnt <= 5'd31;
        else if (nmi_cnt != 5'd0) nmi_cnt <= nmi_cnt - 5'd1;
    end
    wire nmi_pulse = (nmi_cnt != 5'd0);

    //=============================================================================================
    // Power-on reset in the Spectrum domain (ACTIVE-LOW).
    //=============================================================================================
    // por_n = power-on reset ONLY (never re-asserts on a hotkey). It resets the video pipeline.
    reg  [1:0]  lock_sync = 2'b00;
    reg  [15:0] por_cnt   = 16'd0;
    reg         por_n     = 1'b0;
    wire        lock_in   = lock_sync[1];
    always @(posedge spclk) begin
        lock_sync <= {lock_sync[0], sp_lock};
        if (!lock_in) begin
            por_cnt <= 16'd0; por_n <= 1'b0;
        end else if (por_cnt != 16'hFFFF) begin
            por_cnt <= por_cnt + 16'd1; por_n <= 1'b0;
        end else begin
            por_n <= 1'b1;
        end
    end

    // Cold-reset RAM wipe (F11): freeze the Z80, sweep-write 0 to all 128KB RAM (and the
    // screen shadow), then reset the core - a true power-on cold boot. Soft reset (Ctrl+Alt+Del)
    // skips the wipe (keeps RAM, like a warm reset). The video pipeline stays on por_n throughout,
    // so the picture re-aligns and the AXI-HP bus never hangs.
    reg        soft_d = 1'b0, hard_d = 1'b0;
    reg        clr_active = 1'b0;
    reg [16:0] clr_addr   = 17'd0;
    reg        clr_done   = 1'b0;
    always @(posedge spclk) begin
        soft_d   <= soft_combo;
        hard_d   <= hard_combo;
        clr_done <= 1'b0;
        if (!por_n) begin
            clr_active <= 1'b0; clr_addr <= 17'd0;
        end else if (((hard_combo & ~hard_d) | arm_reset_sp) & ~clr_active) begin   // F11 OR ARM AXI-RESET -> RAM wipe + cold reset
            clr_active <= 1'b1; clr_addr <= 17'd0;
        end else if (clr_active) begin
            if (clr_addr == 17'h1FFFF) begin clr_active <= 1'b0; clr_done <= 1'b1; end
            else                             clr_addr   <= clr_addr + 17'd1;
        end
    end

    reg [17:0] rst_cnt = 18'd0;
    reg        core_rst_n = 1'b0;
    always @(posedge spclk) begin
        if (!por_n) begin
            rst_cnt <= 18'd0; core_rst_n <= 1'b0;
        end else if (clr_done) begin                 // cold reset: pulse after the RAM wipe finishes
            rst_cnt <= 18'd200000; core_rst_n <= 1'b0;
        end else if (soft_combo & ~soft_d) begin     // soft reset: short pulse, RAM preserved
            rst_cnt <= 18'd50000;  core_rst_n <= 1'b0;
        end else if (rst_cnt != 18'd0) begin
            rst_cnt <= rst_cnt - 18'd1; core_rst_n <= 1'b0;
        end else begin
            core_rst_n <= 1'b1;
        end
    end
    wire sp_reset_n = por_n & core_rst_n;            // to the core: power-on OR a hotkey reset
    wire reset_busy_sp = clr_active | (rst_cnt != 18'd0);   // RESET/wipe in progress -> ARM STATUS bit2
    // NemoBus / expansion bus: sp_reset_n IS the master reset. Route it (active-low /RESET) to the
    // expansion-connector pin when that bus is physically wired (one XDC line) so an attached board
    // resets on every load / F11 / AXI-RESET, like a real Spectrum edge-connector /RESET.

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
    wire        halt_ack, ram_busy, reset_busy_aclk;
    wire        ctl_reset, arm_reset_sp;
    wire        cpu_halt_sp;
    wire        arm_memWr;
    wire [18:0] arm_memA;
    wire [7:0]  arm_memQ;
    wire [13:0] arm_vmmA2;
    wire [211:0] ctl_dir, cpu_dir_sp, cpu_reg_sp;
    wire [5:0]   ctl_7ffd, port7ffd_sp;
    wire [2:0]   ctl_border, border_sp;
    wire         ctl_dir_commit, ctl_port_commit;
    wire         dir_set_sp, force_7ffd_sp, force_border_sp;
    wire         ctl_osd_enable, ctl_osd_we;     // OSD overlay control (aclk)
    wire [9:0]   ctl_osd_waddr;
    wire [23:0]  ctl_osd_bg;
    wire [7:0]   ctl_osd_op;
    wire [31:0]  ctl_osd_pos;
    wire         ctl_ban_enable, ctl_ban_we;     // independent banner overlay control (aclk)
    wire [8:0]   ctl_ban_waddr;
    wire [31:0]  ctl_ban_wdata;
    wire [31:0]  ctl_ban_pos;
    wire [7:0]   ctl_vol;
    wire         ctl_player_en, ctl_audio_we;   // machine-agnostic ARM audio player (mux + FIFO push)
    wire [31:0]  ctl_audio_data;
    wire         aud_full, aud_empty;
    wire [7:0]   aud_rdcount;
    wire [31:0]  aud_dout;
    wire [31:0]  ctl_osd_wdata;
    wire [8:0]   kbd_fifo_dout;                  // keyboard scancode FIFO head {make,code} (aclk read)
    wire         kbd_fifo_empty, kbd_fifo_rd, kbd_deadman_kick;

    wire [31:0] cap_geom_sp;
    // cap_geom is a multi-bit bus crossing spclk->fclk100; a plain 2-FF can bit-skew on the once-per-
    // frame update. 3-FF it and latch only a settled value (two equal samples), like the OSD position.
    reg [31:0] cap_geom_s1=32'd0, cap_geom_s2=32'd0, cap_geom_s3=32'd0, cap_geom_f=32'd0;
    always @(posedge fclk100) begin
        cap_geom_s1<=cap_geom_sp; cap_geom_s2<=cap_geom_s1; cap_geom_s3<=cap_geom_s2;
        if (cap_geom_s2==cap_geom_s3) cap_geom_f<=cap_geom_s2;
    end
    axi_ctl #(.VERSION(32'hB01B0013)) ctl (
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
        .ctl_dir(ctl_dir), .ctl_7ffd(ctl_7ffd), .ctl_border(ctl_border),
        .ctl_dir_commit(ctl_dir_commit), .ctl_port_commit(ctl_port_commit),
        .ctl_osd_enable(ctl_osd_enable), .ctl_osd_we(ctl_osd_we),
        .ctl_osd_waddr(ctl_osd_waddr), .ctl_osd_wdata(ctl_osd_wdata), .ctl_osd_bg(ctl_osd_bg), .ctl_osd_op(ctl_osd_op), .ctl_osd_pos(ctl_osd_pos), .ctl_vol(ctl_vol),
        .ctl_ban_enable(ctl_ban_enable), .ctl_ban_we(ctl_ban_we),
        .ctl_ban_waddr(ctl_ban_waddr), .ctl_ban_wdata(ctl_ban_wdata), .ctl_ban_pos(ctl_ban_pos),
        .ctl_player_en(ctl_player_en), .ctl_audio_we(ctl_audio_we), .ctl_audio_data(ctl_audio_data),
        .aud_full(aud_full), .aud_empty(aud_empty), .aud_rdcount(aud_rdcount),
        .kbd_fifo_dout(kbd_fifo_dout), .kbd_fifo_empty(kbd_fifo_empty),
        .kbd_fifo_rd(kbd_fifo_rd), .kbd_deadman_kick(kbd_deadman_kick),
        .halt_ack(halt_ack), .ram_busy(ram_busy), .reset_busy(reset_busy_aclk),
        .ctl_reset(ctl_reset),
        .cap_geom(cap_geom_f)
    );

    inject_cdc inj_i (
        .aclk(fclk100), .aresetn(aresetn), .spclk(spclk),
        .ctl_halt(ctl_halt), .ctl_ram_we(ctl_ram_we),
        .ctl_ram_addr(ctl_ram_waddr), .ctl_ram_data(ctl_ram_data),
        .ctl_dir_commit(ctl_dir_commit), .ctl_port_commit(ctl_port_commit),
        .ctl_dir(ctl_dir), .ctl_7ffd(ctl_7ffd), .ctl_border(ctl_border),
        .halt_ack(halt_ack), .ram_busy(ram_busy),
        .cpu_halt_sp(cpu_halt_sp),
        .arm_memWr(arm_memWr), .arm_memA(arm_memA), .arm_memQ(arm_memQ), .arm_vmmA2(arm_vmmA2),
        .dir_set_sp(dir_set_sp), .cpu_dir_sp(cpu_dir_sp),
        .force_7ffd_sp(force_7ffd_sp), .port7ffd_sp(port7ffd_sp),
        .force_border_sp(force_border_sp), .border_sp(border_sp),
        .ctl_reset(ctl_reset), .arm_reset_sp(arm_reset_sp),
        .reset_busy_sp(reset_busy_sp), .reset_busy(reset_busy_aclk)
    );

    // HALT = gate the two 3.5 MHz CPU clock-enables into the core (no Atlas-core edit).
    wire pe3M5_core = pe3M5 & ~cpu_halt_sp & ~clr_active;   // also frozen during the cold-reset RAM wipe
    wire ne3M5_core = ne3M5 & ~cpu_halt_sp & ~clr_active;

    //=============================================================================================
    // Keyboard gate (control-plane scancode tap -> ARM).
    // Lines (a)-(d) below are MACHINE-AGNOSTIC: the ARM always sees every scancode through this FIFO
    // and owns ALL hotkey / OSD policy, and the fabric decodes no function key, so this block ports
    // unchanged to a NES/C64/Atari core. (Only the kb_* suppression mux further down — among the
    // ear sync / 4-button decode / Alt-chord / ZX 8x5 matrix merge — is this machine's adapter.)
    // Two roles:
    //   * always-tap FIFO: every PS/2 event -> async_fifo -> ARM (so F12 can OPEN the OSD even
    //     while it is closed; the FIFO never depends on the gate state).
    //   * gate_on (OSD open, OSD_ENABLE synced to spclk): only SUPPRESSES PS/2 into the core's
    //     matrix. A deadman drops the gate if the ARM stalls, so a dead ARM can't lock the user out.
    //=============================================================================================
    // (a) OSD_ENABLE (aclk) -> spclk gate decision, 2-FF level sync.
    (* ASYNC_REG = "TRUE" *) reg [1:0] osd_en_s = 2'b00;
    always @(posedge spclk) osd_en_s <= {osd_en_s[0], ctl_osd_enable};
    wire osd_en_sp = osd_en_s[1];

    // (b) Deadman heartbeat: aclk KBD_HB pulse -> spclk via toggle + 3-FF + edge (inject_cdc idiom).
    //     CONSTRAINT: the ARM must kick at most once per main-loop pass (never a tight burst). aclk
    //     (100 MHz) toggles ~1.76x faster than spclk samples, so two kicks inside one spclk period
    //     would cancel as a missed edge. Safe today (osd.c kicks once per for(;;) pass, hundreds of
    //     aclk cycles apart; missed kick is self-healing and bounded by the 1.18 s timeout). If a
    //     timer-ISR / DMA heartbeat is ever added, stretch the kick on aclk to >=2 spclk periods first.
    reg kick_tog_a = 1'b0;
    always @(posedge fclk100) if (kbd_deadman_kick) kick_tog_a <= ~kick_tog_a;
    (* ASYNC_REG = "TRUE" *) reg [2:0] kick_sync = 3'd0;
    always @(posedge spclk) kick_sync <= {kick_sync[1:0], kick_tog_a};
    wire kick_sp = kick_sync[2] ^ kick_sync[1];

    // (c) Deadman counter (free-running spclk, NOT pe3M5_core which freezes on HALT). ~1.18 s at
    //     56.7 MHz; expiry forces the gate off until the ARM kicks again or closes the OSD.
    reg [25:0] deadman = 26'd0;
    reg        deadman_expired = 1'b0;
    always @(posedge spclk) begin
        if (!osd_en_sp)      begin deadman <= 26'd0; deadman_expired <= 1'b0; end
        else if (kick_sp)    begin deadman <= 26'd0; deadman_expired <= 1'b0; end
        else if (&deadman)   deadman_expired <= 1'b1;
        else                 deadman <= deadman + 26'd1;
    end
    wire gate_on = osd_en_sp & ~deadman_expired;

    // (d) Scancode FIFO: ALWAYS-TAP. wr_en = ps2_strb & pe3M5 -> exactly one capture per frame
    //     (ps2_strb stays high across a whole pe3M5 period). Both rst_n = aresetn (power-on only,
    //     never re-asserts on a hotkey or MMCM relock) so the two FIFO sides always reset together
    //     and the FIFO is immune to ZX-side resets - the ARM owns the keys. Overflow (.full unused)
    //     is silently dropped: safe, the ARM drains far faster (MHz) than PS/2 fills (~10 keys/s).
    async_fifo #(.DW(9), .AW(5)) kbd_fifo_i (
        .wr_clk(spclk),  .wr_rst_n(aresetn),  .wr_en(ps2_strb & pe3M5),
        .din({ps2_make, ps2_code}), .full(),
        .rd_clk(fclk100), .rd_rst_n(aresetn), .rd_en(kbd_fifo_rd),
        .dout(kbd_fifo_dout), .empty(kbd_fifo_empty), .rd_count()
    );

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
    // Alt = ZX Extended mode (the red lower-row token). On the Alt press edge, inject a short
    // Caps+Symbol Shift chord (this arms the ROM's "E" mode), then hold Symbol Shift while Alt
    // stays down - so the next key, pressed with Alt held, prints the red extended token. A quick
    // Alt tap (released before any key) leaves E-mode armed with no shift held -> the next key
    // gives the green top token instead. Done as synthetic scan-code events fed into the keyboard
    // stream (no Atlas-core edit): CS = 0x12, SS = 0x14, make = 0 press / make = 1 release.
    //=============================================================================================
    localparam [17:0] ALT_PULSE = 18'd210000;   // ~60 ms @ 3.5 MHz pe3M5: spans >=2 of the ROM's 50 Hz key scans
    reg        alt_d2   = 1'b0;
    reg [2:0]  alt_st   = 3'd0;                  // 0 idle / 1 SS-down / 3 chord-hold then CS-up / 5 held while Alt
    reg [17:0] alt_tmr  = 18'd0;
    reg        syn_strb = 1'b0, syn_make = 1'b1;
    reg [7:0]  syn_code = 8'h00;
    always @(posedge spclk) if (pe3M5) begin
        alt_d2   <= alt_h;
        syn_strb <= 1'b0;                         // default: emit nothing on this enable tick
        case (alt_st)
            3'd0: if (alt_h & ~alt_d2) begin                                  // Alt just pressed
                      syn_strb <= 1'b1; syn_make <= 1'b0; syn_code <= 8'h12;  //   -> Caps Shift down
                      alt_st   <= 3'd1;
                  end
            3'd1: begin                                                       //   -> Symbol Shift down
                      syn_strb <= 1'b1; syn_make <= 1'b0; syn_code <= 8'h14;
                      alt_tmr  <= ALT_PULSE; alt_st <= 3'd3;
                  end
            3'd3: if (alt_tmr == 18'd0) begin                                 // chord held long enough
                      syn_strb <= 1'b1; syn_make <= 1'b1; syn_code <= 8'h12;  //   -> Caps Shift up (SS stays down)
                      alt_st   <= 3'd5;
                  end else alt_tmr <= alt_tmr - 18'd1;
            3'd5: if (~alt_h) begin                                           // Alt released
                      syn_strb <= 1'b1; syn_make <= 1'b1; syn_code <= 8'h14;  //   -> Symbol Shift up
                      alt_st   <= 3'd0;
                  end
            default: alt_st <= 3'd0;
        endcase
    end

    // Merge synthetic Alt chord + real PS/2 keyboard + the 4 buttons (synthetic wins, then PS/2).
    // ZX matrix adapter for the gate: while the OSD is open (gate_on) the real PS/2 is suppressed
    // here so the ARM owns the keys; the Alt chord (syn_*) and the 4 buttons stay live.
    wire       ps2_to_core = ps2_strb & ~gate_on & ~pause_byte;   // ARM-owned Pause never reaches the matrix
    wire       kb_strb = syn_strb | ps2_to_core | kbd_strb;
    wire       kb_make = syn_strb ? syn_make : (ps2_to_core ? ps2_make : kbd_make);
    wire [7:0] kb_code = syn_strb ? syn_code : (ps2_to_core ? ps2_code : kbd_code);

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
        .nmi    (nmi_pulse),

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

        .strb   (kb_strb), .make(kb_make), .code(kb_code),
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
        .memQ   (memQ_core),

        .dirset      (dir_set_sp),
        .dir         (cpu_dir_sp),
        .reg_out     (cpu_reg_sp),
        .force_7ffd  (force_7ffd_sp),
        .port7ffd_in (port7ffd_sp),
        .force_border(force_border_sp),
        .border_in   (border_sp)
    );

    //=============================================================================================
    // Memory-bus mux: while the ARM holds the Z80 halted, it drives the write side of the bus.
    // The video read side (vmmA1 / vmmCe) always comes from the core, so the picture stays live.
    //=============================================================================================
    wire        memWr_eff = clr_active ? 1'b1                         : (cpu_halt_sp ? arm_memWr : memWr_core);
    wire [18:0] memA_eff   = clr_active ? {2'b01, clr_addr}            : (cpu_halt_sp ? arm_memA  : memA_core);
    wire [7:0]  memQ_eff   = clr_active ? 8'h00                        : (cpu_halt_sp ? arm_memQ  : memQ_core);
    wire [13:0] vmmA2_eff  = clr_active ? {clr_addr[15], clr_addr[12:0]} : (cpu_halt_sp ? arm_vmmA2 : vmmA2_core);

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
    // DDR double-buffered framebuffer (tear-free) - replaces the single-BRAM framebuffer.
    //   capture (spclk) -> async FIFO -> AXI-HP0 write -> PS DDR (triple buffer) -> AXI-HP0 read
    //   -> display BRAM -> pillarbox upscaler -> rgb24. Buffer swap on the HDMI vblank.
    //=============================================================================================
    wire [10:0] cx, cy;
    wire [23:0] rgb24;

    // HP reset into fclk100 + the loader/writer/manager reset (power-on only - NOT pulsed by the
    // soft/hard hotkeys, so the DDR masters never reset mid-burst and the AXI-HP bus can't hang).
    reg [1:0] hprstn_s = 2'b00;
    always @(posedge fclk100) hprstn_s <= {hprstn_s[0], hp_aresetn};
    wire core_resetn = aresetn & hprstn_s[1];

    // HDMI vblank kick (clk_pixel -> fclk100) + a 1-cycle-delayed copy to arm the loader
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

    // capture enable: gate until HP is up (loader read >=1 frame -> post_config done), synced to spclk
    wire        ld_live; wire [31:0] ld_underrun;   // from fb_line_disp (replaces fb_loader.frame_cnt)
    reg [1:0] capen_s = 2'b00;
    wire cap_en = capen_s[1];
    always @(posedge spclk) capen_s <= {capen_s[0], ld_live};

    // capture the core video (spclk) -> async FIFO
    wire        cap_wr; wire [63:0] cap_din;
    fb_capture_rr capz (
        .wr_clk(spclk), .resetn(por_n), .wr_ce(pe7M0),
        .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i), .enable(cap_en),
        .fifo_wr(cap_wr), .fifo_din(cap_din),
        .cap_geom(cap_geom_sp)
    );
    wire fifo_empty, fifo_rd; wire [63:0] fifo_dout; wire [6:0] fifo_rdcount;
    async_fifo #(.DW(64), .AW(6)) ddrfifo (
        .wr_clk(spclk), .wr_rst_n(por_n), .wr_en(cap_wr), .din(cap_din), .full(),
        .rd_clk(fclk100), .rd_rst_n(core_resetn), .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .rd_count(fifo_rdcount)
    );

    // AXI-HP0 write + triple buffer
    wire wr_done; wire [31:0] wr_base, disp_base;
    fb_bufmgr3 ddrbuf (
        .clk(fclk100), .resetn(core_resetn),
        .frame_done(wr_done), .frame_kick(frame_kick),
        .wr_base(wr_base), .disp_base(disp_base),
        .wr_buf_o(), .disp_buf_o(), .ready_buf_o()
    );
    fb_wr_axi ddrwr (
        .clk(fclk100), .resetn(core_resetn), .base(wr_base),
        .fifo_empty(fifo_empty), .fifo_dout(fifo_dout), .fifo_rd(fifo_rd),
        .aw_addr(hp_awaddr), .aw_id(hp_awid), .aw_len(hp_awlen), .aw_size(hp_awsize),
        .aw_burst(hp_awburst), .aw_cache(hp_awcache), .aw_prot(hp_awprot),
        .aw_lock(hp_awlock), .aw_qos(hp_awqos), .aw_valid(hp_awvalid), .aw_ready(hp_awready),
        .w_data(hp_wdata), .w_strb(hp_wstrb), .w_last(hp_wlast), .w_valid(hp_wvalid), .w_ready(hp_wready),
        .b_valid(hp_bvalid), .b_ready(hp_bready),
        .frame_done(wr_done), .busy_o()
    );

    // AXI-HP0 read (per-LINE) + line-buffered scanout -> rgb24. Phase 1a: replaces fb_loader + the
    // whole-frame display BRAM (frees ~11 BRAM36). cap_en is re-sourced from .live (above).
    fb_line_disp ddrdisp (
        .clk(fclk100), .resetn(core_resetn),
        .disp_base(disp_base), .frame_kick(frame_kick_d),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy), .rgb(rgb24),
        .live(ld_live), .underrun_cnt(ld_underrun)
    );

    // OSD MVP step 1: composite a 1-bpp toast strip over the live scanout (post-upscaler, RGB888,
    // clk_pixel), gated by the AXI OSD_ENABLE bit. No BRAM tile, no Z80 halt. (osd_compositor.v)
    wire [23:0] rgb24_osd;
    osd_compositor osd_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .osd_enable_a(ctl_osd_enable), .osd_we(ctl_osd_we),
        .osd_waddr(ctl_osd_waddr), .osd_wdata(ctl_osd_wdata), .osd_bg_a(ctl_osd_bg), .osd_op_a(ctl_osd_op), .osd_pos_a(ctl_osd_pos),
        .cx(cx), .cy(cy), .rgb_in(rgb24), .rgb_out(rgb24_osd)
    );

    // Independent status BANNER, composited OVER the OSD output (visible regardless of osd_enable).
    // Chain: rgb24 -> osd_i -> rgb24_osd -> banner_i -> rgb24_ovl -> hdmi. (banner_compositor in osd_compositor.v)
    wire [23:0] rgb24_ovl;
    banner_compositor banner_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .ban_enable_a(ctl_ban_enable), .ban_we(ctl_ban_we),
        .ban_waddr(ctl_ban_waddr), .ban_wdata(ctl_ban_wdata), .ban_pos_a(ctl_ban_pos),
        .cx(cx), .cy(cy), .rgb_in(rgb24_osd), .rgb_out(rgb24_ovl)
    );

    //=============================================================================================
    // Audio: 11-bit UNSIGNED PCM -> signed 16-bit, then resync into clk_audio.
    //=============================================================================================
    // Step 13.1 "full pause" mute: while the Z80 is HALTed (Pause), the AY/beeper clock-enables are
    // gated (pe3M5_core = pe3M5 & ~cpu_halt_sp), so the sound chips freeze mid-sample and their last
    // value would hold as a DC level. Force the PCM to silence (0x400 = signed-16 zero after the
    // ~MSB offset->two's-complement conversion below) so a paused machine is genuinely quiet. On
    // resume (HALT deasserted) the frozen AY continues bit-exact - registers, envelope phase and the
    // noise LFSR all survive the freeze, so there is no save/restore and no resume click.
    wire [15:0] left16_raw  = { ~laudio[10], laudio[9:0], 5'b0 };   // signed PCM (NO hard mute)
    wire [15:0] right16_raw = { ~raudio[10], raudio[9:0], 5'b0 };
    // Pause FADE (anti-click): slew a gain 256<->0 over ~1.3 ms on HALT/resume instead of an instant
    // step to silence. Multiplying the SIGNED waveform toward zero ramps the real audio down to true
    // silence and back - no DC step, no click. The Z80/AY still freeze the instant HALT asserts
    // (pe3M5_core gating unchanged); only the audible envelope is smoothed, so resume is bit-exact.
    reg  [8:0] mgain = 9'd256;
    // cpu_halt_sp is spclk-domain; 2-FF sync it into clk_audio_r before it steers the fade target
    // (mirrors the vol_c0/osd_en_s discipline in this file - no unsynced control into the audio domain).
    (* ASYNC_REG = "TRUE" *) reg [1:0] halt_aud_s = 2'b00;
    always @(posedge clk_audio_r) halt_aud_s <= {halt_aud_s[0], cpu_halt_sp};
    wire [8:0] mtgt  = halt_aud_s[1] ? 9'd0 : 9'd256;
    always @(posedge clk_audio_r)
        if (mgain < mtgt) mgain <= mgain + 9'd4; else if (mgain > mtgt) mgain <= mgain - 9'd4;
    wire signed [24:0] lfp = $signed(left16_raw)  * $signed({1'b0, mgain});
    wire signed [24:0] rfp = $signed(right16_raw) * $signed({1'b0, mgain});
    wire [15:0] left16_sp  = lfp >>> 8;
    wire [15:0] right16_sp = rfp >>> 8;

    reg [15:0] left16_a0, left16_a1;
    reg [15:0] right16_a0, right16_a1;
    always @(posedge clk_audio_r) begin
        left16_a0  <= left16_sp;   left16_a1  <= left16_a0;
        right16_a0 <= right16_sp;  right16_a1 <= right16_a0;
    end

    //=============================================================================================
    // Machine-agnostic ARM -> HDMI audio: the ARM player pushes signed-16 {R[31:16],L[15:0]} samples
    // into this async FIFO (fclk100 write side), drained one per clk_audio_r tick. When the player is
    // active the HDMI audio mux selects player PCM over the fabric core's audio - so it plays under
    // ANY fabric machine or none. Fabric leg (fade + volume) is untouched when the player is off.
    //=============================================================================================
    // ctl_player_en is fclk100(aclk)-domain; 2-FF sync it into clk_audio_r before it gates the audio
    // FIFO read enable AND the source mux. An unsynchronised enable into the FIFO read-pointer counter
    // is a real CDC hazard (metastable rd_en can corrupt the gray/binary pointer pair). aud_empty is
    // already a clk_audio_r (read-side) signal, so it needs no extra sync.
    (* ASYNC_REG = "TRUE" *) reg [1:0] pen_s = 2'b00;
    always @(posedge clk_audio_r) pen_s <= {pen_s[0], ctl_player_en};
    wire player_live = pen_s[1] & ~aud_empty;
    async_fifo #(.DW(32), .AW(8)) audio_fifo (
        .wr_clk(fclk100),    .wr_rst_n(aresetn), .wr_en(ctl_audio_we), .din(ctl_audio_data), .full(aud_full),
        .rd_clk(clk_audio_r), .rd_rst_n(aresetn), .rd_en(player_live),
        .dout(aud_dout), .empty(aud_empty), .rd_count(aud_rdcount)
    );

    // Select the audio source BEFORE applying the volume scaling, so that the player
    // obeys the OSD F9 volume level (ctl_vol) just like the fabric machine's audio.
    wire [15:0] src_left  = player_live ? aud_dout[15:0]  : left16_a1;
    wire [15:0] src_right = player_live ? aud_dout[31:16] : right16_a1;

    // HDMI volume (Step 13, F9 menu): scale the signed-16 PCM by ctl_vol (0..255 gain, /256; 255 ~=
    // unity) in the slow clk_audio domain, so the multiply has ample slack and one DSP per channel.
    // ctl_vol is set by the ARM from the options menu; 2-FF sync it in. Composes with the pause mute
    // (while halted src_left/src_right is already silenced, and silence*gain stays silent).
    reg  [7:0] vol_c0 = 8'd255, vol_c1 = 8'd255;
    always @(posedge clk_audio_r) begin vol_c0 <= ctl_vol; vol_c1 <= vol_c0; end
    // FULL-WIDTH product first (a bare (a*b)>>>8 assigned to a 16-bit reg makes Verilog size the
    // multiply to the 16-bit assignment context -> the product overflows + truncates -> garbage/no
    // sound). Compute the signed product in a 25-bit wire, THEN arithmetic-shift /256 (vol 255 ~= 1x).
    wire signed [24:0] lprod = $signed(src_left)  * $signed({1'b0, vol_c1});
    wire signed [24:0] rprod = $signed(src_right) * $signed({1'b0, vol_c1});
    reg signed [15:0] left16_v, right16_v;
    always @(posedge clk_audio_r) begin
        left16_v  <= lprod >>> 8;
        right16_v <= rprod >>> 8;
    end

    wire [15:0] audio_left_f  = left16_v;
    wire [15:0] audio_right_f = right16_v;

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
        .rgb         (rgb24_ovl),
        .audio_left  (audio_left_f),
        .audio_right (audio_right_f),
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
