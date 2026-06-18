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

    // Held state of the hotkey keys (make=0 => pressed, mirror of keyboard.v's convention).
    reg ctrl_h = 1'b0, alt_h = 1'b0, del_h = 1'b0, ins_h = 1'b0, f11_h = 1'b0;
    always @(posedge spclk) if (pe3M5 && ps2_strb) case (ps2_code)
        8'h14: ctrl_h <= ~ps2_make;   // Ctrl  (also Symbol Shift in the matrix)
        8'h11: alt_h  <= ~ps2_make;   // Alt
        8'h71: del_h  <= ~ps2_make;   // Delete
        8'h70: ins_h  <= ~ps2_make;   // Insert
        8'h78: f11_h  <= ~ps2_make;   // F11
        default: ;
    endcase
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
        end else if (hard_combo & ~hard_d & ~clr_active) begin   // F11 -> start RAM wipe (cold reset)
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
    wire [211:0] ctl_dir, cpu_dir_sp, cpu_reg_sp;
    wire [5:0]   ctl_7ffd, port7ffd_sp;
    wire [2:0]   ctl_border, border_sp;
    wire         ctl_dir_commit, ctl_port_commit;
    wire         dir_set_sp, force_7ffd_sp, force_border_sp;

    axi_ctl #(.VERSION(32'hB01B0004)) ctl (
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
        .halt_ack(halt_ack), .ram_busy(ram_busy)
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
        .force_border_sp(force_border_sp), .border_sp(border_sp)
    );

    // HALT = gate the two 3.5 MHz CPU clock-enables into the core (no Atlas-core edit).
    wire pe3M5_core = pe3M5 & ~cpu_halt_sp & ~clr_active;   // also frozen during the cold-reset RAM wipe
    wire ne3M5_core = ne3M5 & ~cpu_halt_sp & ~clr_active;

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

    // Merge the real PS/2 keyboard with the 4 buttons (PS/2 wins on a simultaneous strobe).
    wire       kb_strb = ps2_strb | kbd_strb;
    wire       kb_make = ps2_strb ? ps2_make : kbd_make;
    wire [7:0] kb_code = ps2_strb ? ps2_code : kbd_code;

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
    wire [31:0] ld_frames, ld_beats;
    reg [1:0] capen_s = 2'b00;
    wire cap_en = capen_s[1];
    always @(posedge spclk) capen_s <= {capen_s[0], (ld_frames != 32'd0)};

    // capture the core video (spclk) -> async FIFO
    wire        cap_wr; wire [63:0] cap_din;
    fb_capture_rr capz (
        .wr_clk(spclk), .resetn(por_n), .wr_ce(pe7M0),
        .hsync(vid_hsync), .vsync(vid_vsync), .blank(vid_blank),
        .r(vid_r), .g(vid_g), .b(vid_b), .i(vid_i), .enable(cap_en),
        .fifo_wr(cap_wr), .fifo_din(cap_din)
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

    // AXI-HP0 read (loader) -> display BRAM
    wire ld_wr_en; wire [12:0] ld_wr_addr; wire [63:0] ld_wr_data; wire ld_busy;
    fb_loader ddrld (
        .clk(fclk100), .resetn(core_resetn),
        .frame_kick(frame_kick_d), .base(disp_base), .load_en(1'b1),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .frame_cnt(ld_frames), .beat_cnt(ld_beats), .busy_o(ld_busy)
    );
    fb_display ddrdisp (
        .wr_clk(fclk100), .wr_en(ld_wr_en), .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy), .rgb(rgb24)
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
