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
    inout  wire       ps2_clk,        // G19 (DATA2-07), PS/2 keyboard clock  (Step 15: now bidirectional / open-drain for host TX)
    inout  wire       ps2_data,       // H20 (DATA2-08), PS/2 keyboard data   (Step 15: bidirectional; RX unchanged, TX drives low)

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

    // S_AXI_HP1: read-only (DDR-RGB OSD line reader on its OWN port -> no contention with video on HP0).
    wire        hp1_aresetn;
    wire [31:0] hp1_araddr;  wire [5:0] hp1_arid; wire [3:0] hp1_arlen; wire [2:0] hp1_arsize;
    wire [1:0]  hp1_arburst; wire [3:0] hp1_arcache; wire [2:0] hp1_arprot; wire [1:0] hp1_arlock; wire [3:0] hp1_arqos;
    wire        hp1_arvalid, hp1_arready;
    wire [63:0] hp1_rdata;   wire [5:0] hp1_rid; wire [1:0] hp1_rresp; wire hp1_rlast, hp1_rvalid, hp1_rready;

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
        .SAXIHP0BVALID(hp_bvalid), .SAXIHP0BREADY(hp_bready),
        // ---- S_AXI_HP1 : read-only (DDR-RGB OSD line reader) ----
        .SAXIHP1ACLK(fclk100), .SAXIHP1ARESETN(hp1_aresetn),
        .SAXIHP1ARADDR(hp1_araddr), .SAXIHP1ARID(hp1_arid), .SAXIHP1ARLEN(hp1_arlen),
        .SAXIHP1ARSIZE(hp1_arsize[1:0]), .SAXIHP1ARBURST(hp1_arburst), .SAXIHP1ARCACHE(hp1_arcache),
        .SAXIHP1ARPROT(hp1_arprot), .SAXIHP1ARLOCK(hp1_arlock), .SAXIHP1ARQOS(hp1_arqos),
        .SAXIHP1ARVALID(hp1_arvalid), .SAXIHP1ARREADY(hp1_arready),
        .SAXIHP1RDATA(hp1_rdata), .SAXIHP1RID(hp1_rid), .SAXIHP1RRESP(hp1_rresp),
        .SAXIHP1RLAST(hp1_rlast), .SAXIHP1RVALID(hp1_rvalid), .SAXIHP1RREADY(hp1_rready),
        .SAXIHP1RDISSUECAP1EN(1'b0),
        // HP1 write channel unused (OSD reads only) - tie the request-valids off
        .SAXIHP1AWVALID(1'b0), .SAXIHP1WVALID(1'b0), .SAXIHP1BREADY(1'b0),
        .SAXIHP1WRISSUECAP1EN(1'b0)
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
    wire vid_blank, vid_hsync, vid_vsync, vid_r, vid_g, vid_b, vid_i;
    wire warp_active;                                       // full whole-core 4x warp (WAV AUTO policy; defined below)
    wire warp_safe2_active;                                 // B0047 diagnostic whole-core 2x route for explicit fmode=2
    wire warp_ack;                                          // clock_zx has actually adopted the requested non-native schedule
    clock_zx clock_zx_i (
        .fclk100(fclk100), .warp(warp_active), .warp2(warp_safe2_active), .clock(spclk), .power(sp_lock),
        .warp_ack(warp_ack),
        .ne14M(), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5)
    );

    //=============================================================================================
    // PS/2 keyboard (real keys) + Ctrl+Alt+Del / Ctrl+Alt+Ins reset hotkeys. Spectrum domain,
    // pe3M5 enable (like kbd_buttons). The core's ps2.v decodes the 11-bit frames; the 0xE0
    // extended prefix is harmlessly ignored, so Del(0x71)/Ins(0x70) base codes are seen.
    //=============================================================================================
    reg [1:0] ps2c_s = 2'b11, ps2d_s = 2'b11;        // 2-FF sync of the async pins
    always @(posedge spclk) begin ps2c_s <= {ps2c_s[0], ps2_clk}; ps2d_s <= {ps2d_s[0], ps2_data}; end

    wire       ps2_strb, ps2_make, ps2_perr;
    wire [7:0] ps2_code;
    ps2 ps2_i (
        .clock(spclk), .ce(pe3M5),
        .ps2Ck(ps2c_s[1]), .ps2D(ps2d_s[1]),
        .strb(ps2_strb), .make(ps2_make), .code(ps2_code), .perr(ps2_perr)
    );

    //---- Step 15: PS/2 HOST TX (LEDs / typematic / resend). ARM writes KBD_TX (0xB0). The write strobe
    //     is CDC'd fclk100->spclk (toggle + 3-FF + edge; the KBD_INJECT idiom) and ps2_tx runs the whole
    //     host->device handshake hardware-timed. CLK/DATA are now inout open-drain: drive low or release
    //     to Hi-Z (the board's 4k7 pull-up returns them high). RX is paused while ps2tx_busy so the bits
    //     WE drive are not mis-decoded as incoming frames. ----
    wire [7:0] ctl_kbd_tx_data;   wire ctl_kbd_tx_we;
    reg  ktx_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_kbd_tx_we) ktx_tog_a <= ~ktx_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] ktx_sync = 3'd0;
    always @(posedge spclk) ktx_sync <= {ktx_sync[1:0], ktx_tog_a};
    wire ktx_pulse = ktx_sync[2] ^ ktx_sync[1];
    (* ASYNC_REG="TRUE" *) reg [7:0] ktx_d0 = 8'd0, ktx_d1 = 8'd0;
    always @(posedge spclk) begin ktx_d0 <= ctl_kbd_tx_data; ktx_d1 <= ktx_d0; end

    wire ps2c_low, ps2d_low, ps2tx_busy, ps2tx_done, ps2tx_ack;
    // AUTO-RESEND: a parity/framing error (ps2_perr) asks the keyboard to resend the last byte (0xFE)
    // as soon as the TX is free -> the lost make/break is recovered (fixes the occasional dropped key).
    // An ARM send (ktx_pulse: LEDs) wins a tie; the resend then fires on the next free cycle.
    reg  resend_req = 1'b0;
    // AUTO-RESEND DISABLED (stability): it fired on the keyboard's power-up/BAT frames right after a
    // reconfig and disrupted the device (dead-until-power-cycle). parity errors are still COUNTED
    // (KBD_DIAG) so we can measure them. To be re-enabled behind a post-reset startup grace + a robust
    // guard so it never touches the device before it is up.
    wire resend_launch = 1'b0;
    always @(posedge spclk or negedge aresetn) begin
        if (!aresetn)                            resend_req <= 1'b0;
        else if (pe3M5 && ps2_perr && ~ps2tx_busy) resend_req <= 1'b1;   // ONLY a real keyboard frame - never our own TX bits (else self-resend loop)
        else if (resend_launch)                  resend_req <= 1'b0;
    end
    wire       tx_start = ktx_pulse | resend_launch;
    wire [7:0] tx_byte  = ktx_pulse ? ktx_d1 : 8'hFE;
    ps2_tx ps2tx_i (
        .clk(spclk), .rst_n(aresetn),
        .start(tx_start), .tx_data(tx_byte),
        .ps2c_in(ps2c_s[1]), .ps2d_in(ps2d_s[1]),
        .clk_low(ps2c_low), .data_low(ps2d_low),
        .busy(ps2tx_busy), .done(ps2tx_done), .ackok(ps2tx_ack)
    );
    // Diagnostic counters (KBD_DIAG 0xB8): how often frames drop, and how often we recover them.
    reg [15:0] perr_cnt = 16'd0, resend_cnt = 16'd0;
    always @(posedge spclk or negedge aresetn) begin
        if (!aresetn) begin perr_cnt <= 16'd0; resend_cnt <= 16'd0; end
        else begin
            if (pe3M5 && ps2_perr && ~ps2tx_busy && perr_cnt != 16'hFFFF) perr_cnt   <= perr_cnt   + 16'd1;
            if (resend_launch                     && resend_cnt != 16'hFFFF) resend_cnt <= resend_cnt + 16'd1;
        end
    end
    (* ASYNC_REG="TRUE" *) reg [31:0] diag_s0 = 32'd0, diag_s1 = 32'd0;
    always @(posedge fclk100) begin diag_s0 <= {resend_cnt, perr_cnt}; diag_s1 <= diag_s0; end
    wire [31:0] kbd_diag_aclk = diag_s1;
    assign ps2_clk  = ps2c_low ? 1'b0 : 1'bz;   // open-drain: pull low or release (Hi-Z)
    assign ps2_data = ps2d_low ? 1'b0 : 1'bz;
    (* ASYNC_REG="TRUE" *) reg [1:0] txbusy_s = 2'd0, txack_s = 2'd0;   // TX status -> aclk for KBD_TXSTAT (0xB4)
    always @(posedge fclk100) begin txbusy_s <= {txbusy_s[0], ps2tx_busy}; txack_s <= {txack_s[0], ps2tx_ack}; end
    wire kbd_tx_busy_aclk = txbusy_s[1];
    wire kbd_tx_ack_aclk  = txack_s[1];

    // Pause key = E1 14 77 (make) / E1 F0 14 F0 77 (break) is ARM-owned (intercepted from the always-
    // tap FIFO). Suppress its whole byte run from the Z80 matrix AND the hotkey latches, so a resume
    // can never leak Symbol-Shift (0x14) into the core or stick a reset-combo flag. Anchor on 0xE1
    // (no other set-2 key emits it); eat up to 4 following bytes (covers make 14 77 + break F0 14 F0 77).
    reg [2:0] pse = 3'd0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~ps2tx_busy) begin
        if (ps2_code == 8'hE1) pse <= 3'd4;
        else if (pse != 3'd0)  pse <= pse - 3'd1;
    end
    wire pause_byte = (ps2_code == 8'hE1) | (pse != 3'd0);

    // Held state of the hotkey keys (make=0 => pressed). Qualified by ~pause_byte (Pause never touches
    // a combo flag); belt-and-suspenders: ANY 0xF0 break frame clears ALL latches, so no key can leave
    // ctrl_h/alt_h/del_h permanently stuck and silently arm Ctrl+Alt+Del. Normal press/release still
    // works: a held key sets its latch on make; F0+code clears it (and the per-key make=1 agrees).
    reg ctrl_h = 1'b0, alt_h = 1'b0, del_h = 1'b0, ins_h = 1'b0, f11_h = 1'b0;
    always @(posedge spclk) if (pe3M5 && ps2_strb && ~pause_byte && ~ps2tx_busy) begin
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
    wire [31:0]  ctl_osd_ddr_base;                // DDR-RGB OSD canvas base (0x94)
    wire [31:0]  ctl_ddr_osd_pos;                 // DDR-RGB OSD canvas position (0x98, independent of the 1bpp OSD_POS)
    wire         ctl_tape_run, ctl_tape_earmux, ctl_tape_mute, ctl_tape_we;  // Step 14.2 tape station
    wire [1:0]   ctl_tape_fmode;                         // 0x9C [4:3]: fast-load mode 0=off 1=FAST(8x CPU-only) 2=SAFE(4x whole-core)
    wire         ctl_tape_sync;                          // 0x9C bit5: SYNC LOADER (demand tape - freeze between blocks until CPU samples)
    wire         ctl_tape_more;                          // 0x9C bit6: tape_more_data - ARM still delivering; keep a tail FIFO underrun CPU-frozen (protects the tail against the last-block sampling_active decay)
    wire [31:0]  ctl_tape_data;
    wire         tape_full, tape_playing, tape_ear, tape_playing_a;
    wire         tape_eot_now;       // true final EOT: last descriptor ended and ARM producer is done
    wire         tape_eot_safe;      // B0046 applies local EOT exit only to explicit SAFE4
    reg          tape_seen_playing;  // prevents an empty start-of-run from looking like EOT
    reg          tape_seen_more;     // local EOT is valid only for a producer that explicitly owned MORE
    wire         tape_empty_sp;   // tape pulse-FIFO empty (spclk) -> underrun backpressure
    wire [31:0]  tape_diag_count_sp, tape_diag_hash_sp, tape_diag_gaps_sp, tape_diag_resumes_sp;
    // Diagnostics cross spclk->aclk only for post-run inspection. Two samples are enough because
    // every value is stable before software/JTAG reads it; none feeds functional logic.
    reg [31:0] tape_diag_count_a0=32'd0, tape_diag_count_a1=32'd0;
    reg [31:0] tape_diag_hash_a0=32'd0,  tape_diag_hash_a1=32'd0;
    reg [31:0] tape_diag_gaps_a0=32'd0,  tape_diag_gaps_a1=32'd0;
    reg [31:0] tape_diag_res_a0=32'd0,   tape_diag_res_a1=32'd0;
    reg [31:0] fe_trace_count_a0=32'd0, fe_trace_count_a1=32'd0;
    reg [31:0] fe_trace_hash_a0=32'd0,  fe_trace_hash_a1=32'd0;
    reg [31:0] fe_trace_last_a0=32'd0,  fe_trace_last_a1=32'd0;
    always @(posedge fclk100) begin
        tape_diag_count_a0 <= tape_diag_count_sp; tape_diag_count_a1 <= tape_diag_count_a0;
        tape_diag_hash_a0  <= tape_diag_hash_sp;  tape_diag_hash_a1  <= tape_diag_hash_a0;
        tape_diag_gaps_a0  <= tape_diag_gaps_sp;  tape_diag_gaps_a1  <= tape_diag_gaps_a0;
        tape_diag_res_a0   <= tape_diag_resumes_sp; tape_diag_res_a1 <= tape_diag_res_a0;
    end
    wire         ctl_ddr_osd_en;                  // DDR-RGB OSD enable (OSD_CTRL bit1)
    wire         ctl_ban_enable, ctl_ban_we;     // independent banner overlay control (aclk)
    wire [8:0]   ctl_ban_waddr;
    wire [31:0]  ctl_ban_wdata;
    wire [31:0]  ctl_ban_pos;
    wire [7:0]   ctl_vol;
    wire         ctl_pentagon, ctl_model48, ctl_ula_late; // 0xBC MACHINE_CFG: bit0 Pentagon, bit1 48K, bit2 Sinclair ULA Late
    wire [31:0]  ctl_pent_int;                  // 0xC4 PENT_INT: {v[24:16], hc[8:0]} INT-position tuner (aclk)
    wire [8:0]   ctl_paper_h, ctl_paper_v;      // live paper offsets from ARM menu (0xC8/0xCC)
    wire [31:0]  ctl_joy;                       // 0xC4 JOY_STATE (aclk): [15:0] p1, [31:16] p2 (v0x4A)
    wire [31:0]  ctl_scr_pos;                   // live whole-frame HDMI position {vmargin[15:0], hmargin[15:0]} (0xD0)
    wire [31:0]  ctl_crop_a, ctl_crop_b;        // live crop {sy0,sx0} (0xD4) / {croph,cropw} (0xD8)
    wire [31:0]  ctl_warp_hold;                 // 0xDC WARP_HOLD: fast-load continuous-warp idle-release timeout (CPU T-states; 0 = hold until tape-run clears) (aclk)
    wire [31:0]  ctl_sync_hold;                 // 0x1C SYNC_HOLD: SYNC-loader hysteretic-hold sustained-quiet release threshold (CPU T-states) (aclk)
    wire         ctl_player_en, ctl_audio_we;   // machine-agnostic ARM audio player (mux + FIFO push)
    wire [31:0]  ctl_audio_data;
    wire         aud_full, aud_empty;
    wire [7:0]   aud_rdcount;
    wire [31:0]  aud_dout;
    wire [31:0]  ctl_osd_wdata;
    wire [8:0]   kbd_fifo_dout;                  // keyboard scancode FIFO head {make,code} (aclk read)
    wire         kbd_fifo_empty, kbd_fifo_rd, kbd_deadman_kick;
    wire [8:0]   ctl_kbd_inject;                  // ARM key inject {make,code} (0xA8), aclk
    wire         ctl_kbd_inject_we;               // 1-aclk pulse on a KBD_INJECT write

    wire [31:0] cap_geom_sp;
    // cap_geom is a multi-bit bus crossing spclk->fclk100; a plain 2-FF can bit-skew on the once-per-
    // frame update. 3-FF it and latch only a settled value (two equal samples), like the OSD position.
    reg [31:0] cap_geom_s1=32'd0, cap_geom_s2=32'd0, cap_geom_s3=32'd0, cap_geom_f=32'd0;
    always @(posedge fclk100) begin
        cap_geom_s1<=cap_geom_sp; cap_geom_s2<=cap_geom_s1; cap_geom_s3<=cap_geom_s2;
        if (cap_geom_s2==cap_geom_s3) cap_geom_f<=cap_geom_s2;
    end
    // BulbuLator screen-mirror readback nets (MUST precede the axi_ctl instance that connects them)
    wire [10:0] scr_bram_raddr;   // mirror BRAM word address, driven by axi_ctl on a 0x8000+ read
    reg  [31:0] scr_rdata_r;      // mirror BRAM read data -> axi_ctl s_rdata
    reg  [15:0] sync_diag_a = 16'd0; // demand-tape post-mortem diagnostics, synchronized below
    // B0053 trace buses must be declared before axi_ctl uses them; declaring them later would let
    // Verilog create implicit scalar nets at this connection point and silently truncate readback.
    wire [31:0] int_dbg0_core, int_dbg1_core, int_dbg2_core;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg0_a0=32'd0, int_dbg0_a1=32'd0;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg1_a0=32'd0, int_dbg1_a1=32'd0;
    (* ASYNC_REG="TRUE" *) reg [31:0] int_dbg2_a0=32'd0, int_dbg2_a1=32'd0;
    always @(posedge fclk100) begin
        int_dbg0_a0 <= int_dbg0_core; int_dbg0_a1 <= int_dbg0_a0;
        int_dbg1_a0 <= int_dbg1_core; int_dbg1_a1 <= int_dbg1_a0;
        int_dbg2_a0 <= int_dbg2_core; int_dbg2_a1 <= int_dbg2_a0;
    end
`ifdef HYBRID_CORE
    localparam [31:0] BUILD_VERSION = 32'hB01B005A; // dynamic MiSTer-native48 + Atlas-128/Pentagon
`elsif MISTER48_CORE
    localparam [31:0] BUILD_VERSION = 32'hB01B0059; // MiSTer native48: phase-safe CPU-only FAST8 + tape tied to actual CPU T-state
`elsif MISTER_T80_AB
    localparam [31:0] BUILD_VERSION = 32'hB01B0054; // CPU-only A/B: MiSTer T80pa v0250, Atlas ULA unchanged
`else
    localparam [31:0] BUILD_VERSION = 32'hB01B0053;
`endif
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
        .ctl_halt(ctl_halt), .ctl_ram_we(ctl_ram_we),
        .ctl_ram_addr(ctl_ram_addr), .ctl_ram_waddr(ctl_ram_waddr), .ctl_ram_data(ctl_ram_data),
        .ctl_dir(ctl_dir), .ctl_7ffd(ctl_7ffd), .ctl_border(ctl_border),
        .ctl_dir_commit(ctl_dir_commit), .ctl_port_commit(ctl_port_commit),
        .ctl_osd_enable(ctl_osd_enable), .ctl_osd_we(ctl_osd_we),
        .ctl_osd_waddr(ctl_osd_waddr), .ctl_osd_wdata(ctl_osd_wdata), .ctl_osd_bg(ctl_osd_bg), .ctl_osd_op(ctl_osd_op), .ctl_osd_pos(ctl_osd_pos), .ctl_vol(ctl_vol),
        .ctl_osd_ddr_base(ctl_osd_ddr_base), .ctl_ddr_osd_en(ctl_ddr_osd_en), .ctl_ddr_osd_pos(ctl_ddr_osd_pos),
        .ctl_tape_run(ctl_tape_run), .ctl_tape_earmux(ctl_tape_earmux), .ctl_tape_mute(ctl_tape_mute), .ctl_tape_fmode(ctl_tape_fmode), .ctl_tape_sync(ctl_tape_sync), .ctl_tape_more(ctl_tape_more),
        .ctl_tape_we(ctl_tape_we), .ctl_tape_data(ctl_tape_data), .tape_full(tape_full), .tape_playing(tape_playing_a),
        .tape_diag_count(tape_diag_count_a1), .tape_diag_hash(tape_diag_hash_a1),
        .tape_diag_gaps(tape_diag_gaps_a1), .tape_diag_resumes(tape_diag_res_a1),
        // B0053 diagnostic bit: REG4..REG6 are temporarily the 48K INT/ULA sweep trace.
        .fe_trace_count(int_dbg0_a1), .fe_trace_hash(int_dbg1_a1), .fe_trace_last(int_dbg2_a1),
        .ctl_ban_enable(ctl_ban_enable), .ctl_ban_we(ctl_ban_we),
        .ctl_ban_waddr(ctl_ban_waddr), .ctl_ban_wdata(ctl_ban_wdata), .ctl_ban_pos(ctl_ban_pos),
        .ctl_player_en(ctl_player_en), .ctl_audio_we(ctl_audio_we), .ctl_audio_data(ctl_audio_data),
        .aud_full(aud_full), .aud_empty(aud_empty), .aud_rdcount(aud_rdcount),
        .kbd_fifo_dout(kbd_fifo_dout), .kbd_fifo_empty(kbd_fifo_empty),
        .kbd_fifo_rd(kbd_fifo_rd), .kbd_deadman_kick(kbd_deadman_kick),
        .halt_ack(halt_ack), .ram_busy(ram_busy), .reset_busy(reset_busy_aclk),
        .ctl_reset(ctl_reset),
        .ctl_kbd_inject(ctl_kbd_inject), .ctl_kbd_inject_we(ctl_kbd_inject_we), .memwr_cnt(memwr_sync),
        .ctl_kbd_tx_data(ctl_kbd_tx_data), .ctl_kbd_tx_we(ctl_kbd_tx_we),
        .kbd_tx_busy(kbd_tx_busy_aclk), .kbd_tx_ack(kbd_tx_ack_aclk), .kbd_diag(kbd_diag_aclk),
        .ctl_pentagon(ctl_pentagon), .ctl_model48(ctl_model48), .ctl_ula_late(ctl_ula_late), .ctl_pent_int(ctl_pent_int),
        .ctl_joy(ctl_joy),
        .ctl_paper_h(ctl_paper_h), .ctl_paper_v(ctl_paper_v), .ctl_scr_pos(ctl_scr_pos),
        .ctl_crop_a(ctl_crop_a), .ctl_crop_b(ctl_crop_b),
        .ctl_warp_hold(ctl_warp_hold),
        .ctl_sync_hold(ctl_sync_hold),
        .cap_geom(cap_geom_f),
        // ---- Step 15 ROM-trap ----
        .ctl_romtrap_en(ctl_romtrap_en), .ctl_romtrap_done_we(ctl_romtrap_done_we),
        .rt_pending_a_in(rt_pending_a), .p7ffd_s1_in(p7ffd_s1), .reg_rd1_in(reg_rd1),
        .sync_diag_in(sync_diag_a),
        // ---- BulbuLator screen-mirror readback (AXI-GP window @ 0x40008000, off the DDR path) ----
        .ctl_scr_raddr(scr_bram_raddr), .scr_rdata(scr_rdata_r)
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
    // ---- FAST LOAD: two selectable modes (owner), active only while a tape is running (never in-game):
    //   FAST (mode 1) = CPU-only 8x (28.35 MHz, T80pa ceiling CLK/2). Fastest; works for most loaders
    //         incl. many custom (like MiSTer). Video/audio stay normal. Rare timing-critical titles
    //         (border FX, some TZX pauses) can break -> use SAFE or realtime.
    //   SAFE (mode 2) = whole-core 4x via clock_zx.warp (CPU+ULA+contention+tape all 4x in lock-step).
    //         Bulletproof (all ratios preserved); half the speed of FAST; screen flickers during load.
    // The tape (t_en=pe3M5_core) is locked to the CPU enable in BOTH modes, so pulse ratios hold.
    (* ASYNC_REG="TRUE" *) reg [1:0] fm_s0 = 2'd0, fm_s1 = 2'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] tsync_s = 2'b00;
    wire rom_trap_core;     // passive PC=0x056B qualifier; trapping itself still requires ROMTRAP enable
    wire tape_sync_rom;     // stream-aligned descriptor metadata from tape_player
    wire tape_block_start;  // first descriptor of a new logical tape block was loaded
    always @(posedge spclk) begin
        fm_s0 <= ctl_tape_fmode; fm_s1 <= fm_s0;
        tsync_s <= {tsync_s[0], ctl_tape_sync};
    end
    // Core outputs are declared before the load-state machinery below because
    // the sampling detector consumes the core's actual IN-FE signals.
    wire tape_sample;
    wire tape_sample_strobe, tape_di_bit;
    wire cpu_ten_sp;
    // SAMPLING DETECTOR (frequency-based, measured in CPU T-STATES so it is warp-INDEPENDENT):
    // the ROM/turbo loader reads port 0xFE in a TIGHT edge-timing loop (~every 13 T-states). A
    // border/multicolour effect ALSO reads 0xFE (floating-bus raster sync) but only ~once per scanline
    // (~224 T). Counting the interval in T-states (pe3M5_core ticks) cleanly separates them at ANY
    // speed. "sampling_active" = a TIGHT burst of reads = the loader is actively loading. This stops
    // warp from lingering at 8x into the post-load border effect (the bug: FAST broke the timing-exact
    // Pentagon border while 1x/4x passed - the effect's sparse FE reads were mis-counted as loading).
    (* ASYNC_REG="TRUE" *) reg tsmp_s0 = 1'b0, tsmp_s1 = 1'b0, tsmp_s2 = 1'b0;
    always @(posedge spclk) begin tsmp_s0 <= tape_sample; tsmp_s1 <= tsmp_s0; tsmp_s2 <= tsmp_s1; end
    wire smp_edge = tsmp_s1 & ~tsmp_s2;                    // one pulse per port-FE read
    reg [11:0] smp_tgap  = 12'hFFF;                        // CPU T-states since last FE read (saturating)
    reg        smp_tight = 1'b0;                           // last inter-read interval was tight (loader loop, not a per-line border read)
    always @(posedge spclk) begin
        if (smp_edge) begin
            smp_tight <= (smp_tgap < 12'd64);              // < 64 T apart -> a loader edge-loop (~13 T); a border read is ~224 T
            smp_tgap  <= 12'd0;
        end else if (cpu_ten_sp && smp_tgap != 12'hFFF) smp_tgap <= smp_tgap + 12'd1;   // tick in REAL CPU T-states (pc3M5, contention-aware) - warp-independent AND matches the loader's own timing on 128K (contended). Fixes the 128K SYNC distortion (pe3M5 over-counted during contention -> false sampling drops).
    end
    // EDGE-CORRELATED detection: catches once-per-bit / timing-loop custom loaders (e.g. Letris part 2)
    // that read FE only ~once per bit (~1000 T) - the tight-<64T test above misses them, so warp used to
    // drop to 1x after the first (ROM-loaded) part. Insight: while LOADING, every FE read follows a TAPE
    // signal edge (the loader tracks the tape). A post-load border effect reads FE with NO tape edges
    // (the tape has finished) -> not correlated. So: warp when FE reads correlate with recent tape edges,
    // at ANY read rate. Border-safe (tape done -> no edges), countdown-safe (no reads -> decays off).
    reg tear_s0 = 1'b0, tear_s1 = 1'b0;
    always @(posedge spclk) begin tear_s0 <= tape_ear; tear_s1 <= tear_s0; end
    wire tape_edge = tear_s0 ^ tear_s1;                        // a tape signal transition (edge)
    reg [11:0] edge_age = 12'hFFF;                             // CPU T-states since the last tape edge (saturating)
    always @(posedge spclk) begin
        if (tape_edge) edge_age <= 12'd0;
        else if (cpu_ten_sp && edge_age != 12'hFFF) edge_age <= edge_age + 12'd1;
    end
    wire corr_read = smp_edge & (edge_age < 12'd2048);         // this FE read observed a recent tape edge -> the CPU is tracking the tape
    reg [11:0] corr_age = 12'hFFF;                             // T-states since the last correlated read
    always @(posedge spclk) begin
        if (corr_read) corr_age <= 12'd0;
        else if (cpu_ten_sp && corr_age != 12'hFFF) corr_age <= corr_age + 12'd1;
    end
    wire edge_corr_active = (corr_age < 12'd1024);             // correlated reads still flowing
    wire sampling_active = (smp_tight & (smp_tgap < 12'd256)) | edge_corr_active;   // SUPERSET: tight poll OR edge-correlated (once-per-bit) - keeps the proven tight-loop behaviour, adds slow custom loaders
    // WARP_HOLD tuner (0xDC): idle-release timeout in CPU T-states. Multi-bit, changes rarely -> 3-FF +
    // settle-latch (the PENT_INT / osd_pos idiom). 0 = never idle-release (hold until the tape-run bit clears).
    (* ASYNC_REG="TRUE" *) reg [31:0] whold_s1 = 32'd0, whold_s2 = 32'd0, whold_s3 = 32'd0;
    reg [31:0] warp_hold_ts = 32'd0;
    always @(posedge spclk) begin
        whold_s1 <= ctl_warp_hold; whold_s2 <= whold_s1; whold_s3 <= whold_s2;
        if (whold_s2 == whold_s3) warp_hold_ts <= whold_s2;
    end
    // CONTINUOUS / LATCHED WARP (fixes the intra-load 8x jitter). The detector above proves we are inside
    // a loader, but `sampling_active` toggles ON/OFF per FE-read window (~1024T corr decay + the gaps
    // between the loader's reads and between blocks). Gating warp on that instantaneous window makes the
    // CPU speed flap 8x<->1x DURING a load; the timebase jitter occasionally mis-samples one bit -> the
    // loader checksum fails -> hang (~50% at 8x). FIX: once loading is CONFIRMED (detector fires during an
    // active tape run with a warp fmode), LATCH warp ON and hold it CONTINUOUSLY across every read / bit /
    // inter-block gap. Release only at the TRUE end: the ARM clears the tape-run bit (authoritative EOT),
    // OR no tape edge AND no FE read for warp_hold_ts CPU T-states (a generous idle watchdog, re-armed on
    // EVERY edge/read - orders of magnitude longer than the old 1024T, so once-per-bit loaders (Letris)
    // and normal inter-block processing never drop it). Steady 8x = zero toggling jitter; and because the
    // tape advance (tape_advance = pe3M5_core) is locked to the warped CPU enable, the pulse-to-T-state
    // ratio is IDENTICAL to 1x for the whole load. Guarded by trun_s[1] & a warp fmode, so a running game
    // (no tape) is NEVER warped.
    wire warp_fmode     = (fm_s1 == 2'd1) | (fm_s1 == 2'd2) | (fm_s1 == 2'd3); // FAST(1), SAFE(2), WAV AUTO(3)
    wire warp_guard     = trun_s[1] & warp_fmode;                          // tape running AND a warp mode chosen
    wire load_confirmed = warp_guard & sampling_active;                    // detector fired -> we are inside a loader
    wire load_activity  = tape_edge | smp_edge;                            // a tape transition OR an FE read = still loading
    // FAST is CPU-only: ULA/INT remain at their native clock.  Standard ROM
    // blocks can be separated by a 0/1-ms recorded pause, which is eight times
    // shorter in wall time while FAST is active.  Critical Mass then consumes an
    // exact stream but returns to BASIC at EOT.  The proven safe contract is the
    // existing PC=056B demand gate.  FAST therefore enables that gate
    // automatically for *marked standard-ROM blocks*.  Raw SYNC still controls
    // the same gate at 1x/SAFE; turbo/custom descriptors, WAV and MP3 are
    // unmarked and remain continuous at their requested speed.
    wire sync_effective = tsync_s[1] | (fm_s1 == 2'd1);
    // B0045 WAV-AUTO, selected only by the otherwise-unused fmode=3 via JTAG.
    // B0044's ROM->RAM handoff worked for EXOLON/ARKANOID2 but IK+'s animated
    // ROM phase already depends on native ULA/INT timing.  Therefore mode3 is
    // whole-core SAFE4 from the START of a WAV tape.  This is deliberately the
    // reliable policy, not a false claim of CPU-only 8x; modes 1/2 and all
    // existing TAP/TZX/MP3 semantics remain unchanged.
    reg cpuw_active = 1'b0;
    reg wav_auto_pending = 1'b0, wav_auto_safe = 1'b0;
    wire wav_auto_ram_pc = (cpu_reg_sp[79:64] >= 16'h4000);
    always @(posedge spclk) begin
        if (!trun_s[1] || (fm_s1 != 2'd3)) begin
            wav_auto_pending <= 1'b0;
            wav_auto_safe <= 1'b0;
        end else begin
            if (!wav_auto_pending && !wav_auto_safe)
                wav_auto_pending <= 1'b1;
            if (wav_auto_pending && !cpuw_active) begin
                wav_auto_pending <= 1'b0;
                wav_auto_safe <= 1'b1;
            end
        end
    end
    reg  [23:0] warp_idle  = 24'hFFFFFF;                                   // CPU T-states since the last load activity (saturating)
    reg         warp_latch = 1'b0;
    reg         warp_eot_done = 1'b0;                                      // B0046: ARM RUN cleanup must not re-arm SAFE4 after genuine player EOT
    wire        warp_idle_to = (warp_hold_ts != 32'd0) & ({8'd0, warp_idle} >= warp_hold_ts);  // idle watchdog fired (0 = never)
    always @(posedge spclk) begin
        if (!warp_guard) begin
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
            warp_eot_done <= 1'b0;
        end else if (tape_eot_safe) begin                                  // B0046: explicit SAFE4 returns to native time at local player EOT
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
            warp_eot_done <= 1'b1;
        end else if (warp_eot_done) begin                                  // ARM still owns RUN for CDC/polling, but may never re-arm post-EOT warp
            warp_latch <= 1'b0;
            warp_idle  <= 24'hFFFFFF;
        end else begin
            if (load_activity) warp_idle <= 24'd0;                         // re-arm the idle watchdog on every edge / FE read
            else if (cpu_ten_sp && warp_idle != 24'hFFFFFF) warp_idle <= warp_idle + 24'd1;
            /* B0046 A/B: explicit SAFE4 starts before the first descriptor,
               not halfway through the pilot when FE sampling is first seen.
               Keep FAST and WAV-AUTO policies untouched; this isolates the
               whole-core clock-transition hypothesis without changing any
               tape word or EAR level. */
            if      (fm_s1 == 2'd2) warp_latch <= 1'b1;
            else if (load_confirmed) warp_latch <= 1'b1;                   // confirmed loading -> hold warp ON
            else if (warp_idle_to)   warp_latch <= 1'b0;                   // long idle -> the load really ended
        end
    end
    // Gate the warp clock-enables on the HELD latch (not the instantaneous sampling window). warp_latch
    // already implies trun_s[1] & a warp fmode (set only under warp_guard, forced 0 the cycle it drops).
    // B0048 restores the original whole-core 4x fmode=2 path and adds a
    // passive IN-FE trace.  B0047's whole2 PASS is retained as evidence;
    // this build compares 1x and 4x guest-observed reads without touching
    // descriptors or EAR routing.
    assign warp_safe2_active = 1'b0;
    assign warp_active = ((fm_s1 == 2'd2) | ((fm_s1 == 2'd3) & wav_auto_safe)) & warp_latch;
    wire cpuwarp_req   = ((fm_s1 == 2'd1) | ((fm_s1 == 2'd3) & ~wav_auto_pending & ~wav_auto_safe)) & warp_latch;
    // DEMAND TAPE (option SYNC LOADER): the ARM marks standard-ROM pulses with descriptor bit30.
    // Recorded pauses and all turbo/custom pulses are unmarked and always replay continuously.  At the
    // first marked pilot pulse we wait for the core's exact passive PC=0x056B fetch; arbitrary port-FE
    // reads made by a loading animation can therefore never creep the tape forward.
    // Keep the legacy SYNC_HOLD register synchronized for ABI/readback compatibility.  The old
    // heuristic used it to stop a block after a quiet interval; that could cut the final 1710-T
    // pulse in half.  Stream-aligned SYNC below deliberately runs a started block to its boundary.
    (* ASYNC_REG="TRUE" *) reg [31:0] shold_s1 = 32'd0, shold_s2 = 32'd0, shold_s3 = 32'd0;
    reg [31:0] sync_hold_ts = 32'd0;
    always @(posedge spclk) begin
        shold_s1 <= ctl_sync_hold; shold_s2 <= shold_s1; shold_s3 <= shold_s2;
        if (shold_s2 == shold_s3) sync_hold_ts <= shold_s2;
    end
    // Exact demand replay.  PC=056B is the ROM's LD-BYTES entry and is a much stronger request than
    // port-FE traffic: loading animations scan FE too, which made the former heuristic creep through
    // BigThings one fragment at a time.  Latch the request even BEFORE RUN (autostart reaches 056B
    // before the ARM starts the tape), consume it only at a marked standard block boundary, then run
    // the WHOLE block continuously.  Untagged recorded pauses and turbo/custom TZX always bypass SYNC.
    // A custom loader fed from a .TAP cannot be distinguished structurally on the ARM side, so a
    // conservative fallback recognizes a dense FE polling loop executing in RAM and makes the rest
    // of that tape continuous.  BigThings' animation is in ROM (PC 0x25xx), so it cannot trip this.
    localparam SYNC_WAIT=2'd0, SYNC_ACTIVE=2'd1, SYNC_CUSTOM=2'd2;
    reg  [1:0] sync_state = SYNC_WAIT;
    reg        sync_hold = 1'b0;
    reg        sync_rt_prev = 1'b0;
    reg        rom_pending = 1'b0;
    reg        consume_rom_pending = 1'b0;
    reg        sync_wait_popped = 1'b0;  // WAIT is holding an already-popped first pilot descriptor
    reg        sync_run_d = 1'b0;
    reg  [6:0] sync_fe_run = 7'd0;
    wire       sync_rt_rise = rom_trap_core & ~sync_rt_prev;
    wire       sync_guard = trun_s[1] & sync_effective;        // tape running AND explicit/FAST auto-SYNC selected
    wire       sync_ram_pc = (cpu_reg_sp[79:64] >= 16'h4000);   // T80 DIR word2 low half = live PC
    // LD-EDGE can retry PC=056B while a standard block is already playing.  Such a retry belongs to
    // the CURRENT LOAD and must never arm the following block (BigThings has a long animation between
    // BT.1 and BT.2, so a stale retry otherwise releases BT.2's header during the animation).
    wire       sync_req_eligible = !(sync_guard && (sync_state == SYNC_ACTIVE) && tape_sync_rom);

    // Request storage is deliberately independent of sync_guard.  A completed run clears stale
    // requests, but an as-yet-unstarted run keeps the request produced by zx_tape_autostart().
    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_rt_prev <= 1'b0; rom_pending <= 1'b0; sync_run_d <= 1'b0;
        end else begin
            sync_rt_prev <= rom_trap_core;
            sync_run_d <= trun_s[1];
            if (sync_run_d && !trun_s[1]) rom_pending <= 1'b0;
            else if (consume_rom_pending) rom_pending <= sync_rt_rise && sync_req_eligible;
            else if (sync_rt_rise && sync_req_eligible) rom_pending <= 1'b1;
        end
    end

    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_state <= SYNC_WAIT; sync_hold <= 1'b0;
            consume_rom_pending <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
        end else begin
            consume_rom_pending <= 1'b0;
            if (!sync_guard) begin
                sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
            end else if (sync_state == SYNC_CUSTOM) begin
                sync_hold <= 1'b1; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0; // continuous until RUN ends
            end else if (tape_block_start && tape_sync_rom) begin
                // The first descriptor has just been loaded but has not spent a T-state yet.  This
                // is therefore an exact, lossless place to stop before a following pause=0 block.
                if (rom_pending || (sync_rt_rise && sync_req_eligible)) begin
                    sync_state <= SYNC_ACTIVE; sync_hold <= 1'b1;
                    consume_rom_pending <= 1'b1; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0;
                end else begin
                    sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b1; sync_fe_run <= 7'd0;
                end
            end else if (!tape_sync_rom) begin
                sync_state <= SYNC_WAIT; sync_hold <= 1'b0; sync_wait_popped <= 1'b0; sync_fe_run <= 7'd0; // pause/custom bypasses below
            end else if (sync_state == SYNC_ACTIVE) begin
                sync_hold <= 1'b1; sync_fe_run <= 7'd0;       // never truncate a started block
            end else if (rom_pending || (sync_rt_rise && sync_req_eligible)) begin
                // If block_start already happened, the first pilot descriptor is busy/frozen and this
                // is a LATE grant: consume the request now.  Otherwise the descriptor is still at the
                // FWFT head; keep the request until its bit29 pulse confirms the pop next cycle.
                sync_state <= SYNC_ACTIVE; sync_hold <= 1'b1; sync_fe_run <= 7'd0;
                if (sync_wait_popped) begin consume_rom_pending <= 1'b1; sync_wait_popped <= 1'b0; end
            end else begin
                sync_hold <= 1'b0;
                if (smp_edge) begin
                    if (smp_tgap < 12'd2048) begin
                        // A keyboard/animation scan normally contains only 8..16 clustered reads.
                        // Requiring 64 consecutive reads preserves custom-TAP liveness (well within
                        // one 2168-T pilot pulse for a ~13-T polling loop) without permanently
                        // switching BigThings to continuous mode on a matrix-scan burst.
                        if (sync_fe_run != 7'h7F) sync_fe_run <= sync_fe_run + 7'd1;
                        if (sync_fe_run >= 7'd63 && sync_ram_pc) begin
                            sync_state <= SYNC_CUSTOM; sync_hold <= 1'b1;
                        end
                    end else sync_fe_run <= 7'd1;
                end
            end
        end
    end
    // Post-mortem SYNC diagnostics (retained after EOT): upper ROMTRAP readback bits expose whether
    // the custom fallback fired, the longest dense FE run, late-preloaded grants and block starts.
    reg sync_diag_run_d = 1'b0, sync_diag_custom = 1'b0;
    reg [6:0] sync_diag_fe_max = 7'd0;
    reg [3:0] sync_diag_late_grants = 4'd0, sync_diag_blocks = 4'd0;
    always @(posedge spclk or negedge sp_reset_n) begin
        if (!sp_reset_n) begin
            sync_diag_run_d<=1'b0; sync_diag_custom<=1'b0; sync_diag_fe_max<=7'd0;
            sync_diag_late_grants<=4'd0; sync_diag_blocks<=4'd0;
        end else begin
            sync_diag_run_d <= trun_s[1];
            if (trun_s[1] && !sync_diag_run_d) begin
                sync_diag_custom<=1'b0; sync_diag_fe_max<=7'd0;
                sync_diag_late_grants<=4'd0; sync_diag_blocks<=4'd0;
            end else begin
                if (sync_wait_popped && (sync_state == SYNC_WAIT) &&
                    (rom_pending || (sync_rt_rise && sync_req_eligible)) && sync_diag_late_grants != 4'hF)
                    sync_diag_late_grants <= sync_diag_late_grants + 4'd1;
                if (tape_block_start && tape_sync_rom && sync_diag_blocks != 4'hF) sync_diag_blocks <= sync_diag_blocks + 4'd1;
                if (sync_fe_run > sync_diag_fe_max) sync_diag_fe_max <= sync_fe_run;
                if (sync_state == SYNC_CUSTOM) sync_diag_custom <= 1'b1;
            end
        end
    end
    wire [15:0] sync_diag_sp = {sync_diag_custom, sync_diag_fe_max,
                                sync_diag_late_grants, sync_diag_blocks};
    (* ASYNC_REG="TRUE" *) reg [15:0] sync_diag_s0 = 16'd0;
    always @(posedge fclk100) begin sync_diag_s0 <= sync_diag_sp; sync_diag_a <= sync_diag_s0; end
    /* B0046: mode2 cannot spend any initial descriptor ticks at the native
       rate while clock_zx is adopting /4.  FAST and WAV-AUTO retain their
       established paths; this is solely the whole-core SAFE4 A/B. */
    wire tape_warp_ready = (fm_s1 != 2'd2) | warp_ack;
    // UNDERRUN BACKPRESSURE: while the loader is actively sampling and the pulse FIFO has run dry,
    // FREEZE the CPU until the ARM (ISR, independent of this freeze) refills it. The loader counts in
    // T-states which are frozen too, so the next pulse lands on time in its own timebase -> no misread,
    // no gap reaches the machine. Fixes marginal MP3 8x underruns (and any format/rate). No deadlock:
    // the ISR pushes into the FIFO regardless of the CPU freeze.
    // TAIL FIX: sampling_active decays OFF exactly at the last-block boundary, so on its own it stops
    // protecting the very tail - a FIFO underrun there used to leak a stale edge into a still-running
    // turbo loader (deterministic ~95.5% hang at 8x). tmore_s[1] (TAPE_CTRL bit6, ARM-held "still
    // delivering the tape") keeps the freeze armed through the tail; the ARM drops it only once the
    // software ring is empty (nothing left to refill), so the final FIFO underrun = true EOT releases
    // the CPU into the running game. No deadlock: run/bit0 clears at EOT anyway, tmore is a superset.
    // PL3F isolation/fix: raw FIFO `empty` does NOT mean that the player needs data.  It asserts as
    // soon as the LAST descriptor is popped, while `busy` is still replaying that descriptor.  The
    // old expression froze pe/ne and tape_advance at that instant; COUNT/HASH were already complete,
    // but the last pulse never finished and the ARM's 3 s stuck backstop eventually cut it short ->
    // deterministic BigThings checksum 0:9 in both FAST8x and SAFE4x.  Step 14 had no starvation and
    // the 1024-entry FIFO showed zero real gaps in the hardware traces, so disable the broken path for
    // this A/B.  A future WAV/MP3 underrun guard must use an explicit player `need_data` handshake,
    // never raw `empty`, and must preserve the pe/ne phase while stopped.
    wire cpu_starve = 1'b0;
    // CPU-only 8x generator (FAST): pe on even master cycles, ne on odd (pe first) -> T-state per 2
    // cycles, t_en(=pe) once per T-state. Switch state ONLY right after an `ne` (T80pa CEN_pol=0,
    // between T-states) so the enable-source flip never leaves the handshake half-done.
    reg cpuw_tog = 1'b0;
    wire cw_pe = cpuw_active & ~cpuw_tog;
    wire cw_ne = cpuw_active &  cpuw_tog;
    wire pe_sel = cpuw_active ? cw_pe : pe3M5;              // pe3M5 = clock_zx output (normal in FAST, 4x in SAFE - but SAFE never sets cpuw_active)
    wire ne_sel = cpuw_active ? cw_ne : ne3M5;
    always @(posedge spclk) begin
        cpuw_tog <= cpuw_active ? ~cpuw_tog : 1'b0;
        if (ne_sel) cpuw_active <= cpuwarp_req;             // change at a T-state boundary only
    end

    //=============================================================================================
    // Step 15: ROM-trap (machine-intercept). The core raises rom_trap_core on a trapped M1 opcode
    // fetch; we freeze the CPU AT that fetch (rt_halt gates the SAME enables as HALT) and raise
    // rt_pending for the ARM to poll (ROMTRAP 0xE0 bit0). The ARM services the block, then writes
    // "done" (0xE0 bit1) which clears the latch and lets the CPU resume. Enable + done cross
    // aclk<->spclk with the file's toggle/edge + ASYNC_REG idioms (as kbd_inject / the deadman kick).
    //=============================================================================================
    wire ctl_romtrap_en, ctl_romtrap_done_we;              // from axi_ctl (aclk)
    // enable synced to spclk
    (* ASYNC_REG="TRUE" *) reg [1:0] rten_s = 2'b0;
    always @(posedge spclk) rten_s <= {rten_s[0], ctl_romtrap_en};
    // ARM "done" pulse: aclk toggle -> spclk edge
    reg rtdone_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_romtrap_done_we) rtdone_tog_a <= ~rtdone_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] rtdone_s = 3'b0;
    always @(posedge spclk) rtdone_s <= {rtdone_s[1:0], rtdone_tog_a};
    wire rtdone_pulse = rtdone_s[2] ^ rtdone_s[1];
    // trap latch + CPU freeze
    reg rt_prev = 1'b0, rt_pending = 1'b0, rt_halt = 1'b0;
    always @(posedge spclk) begin
        rt_prev <= rom_trap_core;
        if (rtdone_pulse) begin rt_pending <= 1'b0; rt_halt <= 1'b0; end
        else if (rom_trap_core & ~rt_prev & rten_s[1] & ~rt_pending) begin   // rten_s only (ROM-trap is enabled only during an armed trap-only load; no tape-run in trap-only)
            rt_pending <= 1'b1;   // ARM will read this and handle the block
            rt_halt    <= 1'b1;   // freeze the CPU AT the trapped M1 fetch
        end
    end
    // pending -> aclk for the ARM to poll
    (* ASYNC_REG="TRUE" *) reg [2:0] rtp_s = 3'b0;
    always @(posedge fclk100) rtp_s <= {rtp_s[1:0], rt_pending};
    wire rt_pending_a = rtp_s[2];
    // Register readback: cpu_reg_sp (212b, spclk) is STABLE while the CPU is halted (rt_halt), which
    // is exactly when the ARM reads it -> a plain 2-FF sync is safe. Live 7FFD synced the same way.
    (* ASYNC_REG="TRUE" *) reg [211:0] reg_rd0 = 212'd0, reg_rd1 = 212'd0;
    always @(posedge fclk100) begin reg_rd0 <= cpu_reg_sp; reg_rd1 <= reg_rd0; end
    (* ASYNC_REG="TRUE" *) reg [5:0] p7ffd_s0 = 6'd0, p7ffd_s1 = 6'd0;
    always @(posedge fclk100) begin p7ffd_s0 <= p7ffd_live_core; p7ffd_s1 <= p7ffd_s0; end

    wire pe3M5_core = pe_sel & ~cpu_halt_sp & ~rt_halt & ~cpu_starve & ~clr_active;
    wire ne3M5_core = ne_sel & ~cpu_halt_sp & ~rt_halt & ~cpu_starve & ~clr_active;

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
    // (a) OSD gate: engage when EITHER the 1bpp OSD (bit0) OR the DDR player window (bit1) is shown,
    //     so a visible player window takes keyboard focus (the machine gets no keys until it is hidden -
    //     even if it is not paused). Both are aclk level signals; OR then 2-FF level-sync to spclk.
    (* ASYNC_REG = "TRUE" *) reg [1:0] osd_en_s = 2'b00;
    always @(posedge spclk) osd_en_s <= {osd_en_s[0], (ctl_osd_enable | ctl_ddr_osd_en)};
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
    async_fifo #(.DW(9), .AW(7)) kbd_fifo_i (   /* 128 deep (was 32): a heavy main-loop iteration (MP3 decode / big redraw) delays the key read; a deeper FIFO absorbs the backlog so no MAKE is dropped -> no "first press ignored" */
        .wr_clk(spclk),  .wr_rst_n(aresetn),  .wr_en(ps2_strb & pe3M5 & ~ps2tx_busy),
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

    // ---- Step 14.2 tape station: replay ARM {level,dur} pulses into the ear (machine adapter here:
    //      tick = the CPU's own pe3M5_core T-state enable, mux = the ZX ear; the module is agnostic). ----
    (* ASYNC_REG="TRUE" *) reg [1:0] trun_s = 2'b00, tem_s = 2'b00, tmore_s = 2'b00;  // run/earmux/more-data aclk -> spclk
    always @(posedge spclk) begin trun_s <= {trun_s[0], ctl_tape_run}; tem_s <= {tem_s[0], ctl_tape_earmux}; tmore_s <= {tmore_s[0], ctl_tape_more}; end
    wire tape_earmux_sp = tem_s[1];
`ifdef HYBRID_CORE
    // The selected backend exposes the exact CE presented to its active T80.
    wire tape_cpu_tick = cpu_ten_sp;
`elsif MISTER48_CORE
    // MiSTer native48 owns native contention CEs internally and owns the
    // phase-safe FAST8 handoff in mister48_core.  Count pulses from the CE
    // actually presented to T80, never from the legacy Atlas top generator.
    wire tape_cpu_tick = cpu_ten_sp;
`else
    wire tape_cpu_tick = pe3M5_core;
`endif
    wire tape_advance = tape_cpu_tick & tape_warp_ready &
                        (~sync_effective | ~tape_sync_rom | sync_hold | (sync_state == SYNC_CUSTOM));
    /* B0046 A/B uses the player's genuine idle transition only to return the
       SAFE4 clock policy to native time without waiting for ARM CDC/polling.
       It deliberately DOES NOT alter EAR: descriptor parity makes Aliens'
       last recorded level LOW, so an EAR-tail theory cannot explain it.  The
       seen latch prevents an empty start-of-run from qualifying as EOT. */
    assign tape_eot_now = trun_s[1] & tape_seen_playing & tape_seen_more & ~tape_playing & ~tmore_s[1];
    assign tape_eot_safe = tape_eot_now & (fm_s1 == 2'd2);
    always @(posedge spclk or negedge sp_reset_n) begin
        if(!sp_reset_n) begin
            tape_seen_playing <= 1'b0;
            tape_seen_more    <= 1'b0;
        end
        else if(!trun_s[1]) begin
            tape_seen_playing <= 1'b0;
            tape_seen_more    <= 1'b0;
        end
        else begin
            if(tape_playing) tape_seen_playing <= 1'b1;
            if(tmore_s[1])   tape_seen_more    <= 1'b1;
        end
    end
    tape_player #(.DUR_W(24), .AW(12)) tape_i (
        .wr_clk(fclk100), .wr_rst_n(aresetn), .push(ctl_tape_we), .push_data(ctl_tape_data), .full(tape_full),
        .rd_clk(spclk), .rd_rst_n(sp_reset_n), .fifo_rd_rst_n(aresetn), .t_en(tape_advance), .run(trun_s[1]),
        .tape_ear(tape_ear), .playing(tape_playing), .empty(tape_empty_sp),
        .sync_rom(tape_sync_rom), .block_start(tape_block_start),
        .diag_pop_count(tape_diag_count_sp), .diag_pop_hash(tape_diag_hash_sp),
        .diag_gap_count(tape_diag_gaps_sp), .diag_resume_count(tape_diag_resumes_sp)
    );
    (* ASYNC_REG="TRUE" *) reg [1:0] tpl_a = 2'b00;                      // playing spclk -> aclk (status)
    always @(posedge fclk100) tpl_a <= {tpl_a[0], tape_playing};
    assign tape_playing_a = tpl_a[1];

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

    // ---- ARM keyboard inject (0xA8): a synthetic scancode fed into the core's key stream, the same
    //      path as the Alt-chord (syn_*), but it BYPASSES the OSD gate so the ARM can drive the machine's
    //      keyboard even with the player window up (autonomous tape-loader start + self-test). aclk write
    //      -> toggle CDC -> spclk; the data word (held stable in aclk) is sampled at the synchronised
    //      pulse. Convention (as syn_*): make=0 press, make=1 release. Injects are spaced milliseconds
    //      apart, so the single-entry pending latch never collides.
    reg kinj_tog_a = 1'b0;
    always @(posedge fclk100) if (ctl_kbd_inject_we) kinj_tog_a <= ~kinj_tog_a;
    (* ASYNC_REG="TRUE" *) reg [2:0] kinj_sync = 3'd0;
    always @(posedge spclk) kinj_sync <= {kinj_sync[1:0], kinj_tog_a};
    wire kinj_pulse = kinj_sync[2] ^ kinj_sync[1];
    (* ASYNC_REG="TRUE" *) reg [8:0] kinj_d0 = 9'd0, kinj_d1 = 9'd0;
    always @(posedge spclk) begin kinj_d0 <= ctl_kbd_inject; kinj_d1 <= kinj_d0; end

    reg       arm_strb = 1'b0, arm_make = 1'b1;
    reg [7:0] arm_code = 8'h00;
    reg       arm_pending = 1'b0;
    reg [8:0] arm_lat = 9'd0;
    always @(posedge spclk) begin
        if (kinj_pulse) begin arm_pending <= 1'b1; arm_lat <= kinj_d1; end
        if (pe3M5) begin
            arm_strb <= 1'b0;                        // default: emit nothing this enable tick (mirror syn_strb)
            if (arm_pending) begin
                arm_strb <= 1'b1;
                arm_make <= arm_lat[8];
                arm_code <= arm_lat[7:0];
                arm_pending <= 1'b0;
            end
        end
    end

    // Merge synthetic Alt chord + real PS/2 keyboard + the 4 buttons (synthetic wins, then PS/2).
    // ZX matrix adapter for the gate: while the OSD is open (gate_on) the real PS/2 is suppressed
    // here so the ARM owns the keys; the Alt chord (syn_*) and the 4 buttons stay live.
    wire       ps2_to_core = ps2_strb & ~gate_on & ~pause_byte & ~ps2tx_busy;   // ARM-owned Pause never reaches the matrix; our own TX bits never leak either
    wire       kb_strb = arm_strb | syn_strb | ps2_to_core | kbd_strb;                                    // ARM inject wins (bypasses the gate)
    wire       kb_make = arm_strb ? arm_make : (syn_strb ? syn_make : (ps2_to_core ? ps2_make : kbd_make));
    wire [7:0] kb_code = arm_strb ? arm_code : (syn_strb ? syn_code : (ps2_to_core ? ps2_code : kbd_code));

    //=============================================================================================
    // Atlas ZX Spectrum core (main). CPU enables gated by halt; video enables free-running.
    //=============================================================================================
    wire [10:0] laudio, raudio;
    wire        vmmCe;
    wire [13:0] vmmA1, vmmA2_core;
    wire [7:0]  vmmD;
    wire        memRf, memRd, memWr_core;
    wire [18:0] memA_core;
    wire [7:0]  memD, memQ_core;
    wire [5:0]  p7ffd_live_core;                          // Step 15: live 128K paging port (7FFD) from the core
    wire [7:0]  map_diag_core;                            // B0048: passive Atlas automapper/MMU observer state
    wire [26:0] ula_diag_core;                            // B0048: passive ULA/IRQ/contention snapshot
    // Machine select - CDC control bits (aclk) -> spclk (2-FF).  The Atlas core has native 48K
    // support; keeping this separate from Pentagon timing lets tape images select their real ROM.
    // v0x4A JOYMAP: joystick mask aclk->spclk, plain 2-FF per bit (level-type quasi-static signal;
    // 1-clk bit skew == real stick chatter). deadman gate: if the ARM dies holding FIRE, the pad is
    // released when the keyboard-gate deadman expires - reuse gate_deadman state via kbd path? The
    // Step-10 deadman lives inside the gate logic; simplest equivalent here: zero the pad whenever
    // the keyboard gate itself has been forced open by the deadman (same aliveness signal).
    (* ASYNC_REG="TRUE" *) reg [31:0] joy_m = 32'd0, joy_sp = 32'd0;
    always @(posedge spclk) begin joy_m <= ctl_joy; joy_sp <= joy_m; end
    (* ASYNC_REG="TRUE" *) reg [1:0] pentagon_s = 2'b00, model48_s = 2'b00, ula_late_s = 2'b00;
    always @(posedge spclk) begin
        pentagon_s <= {pentagon_s[0], ctl_pentagon};
        model48_s  <= {model48_s[0],  ctl_model48};
        ula_late_s <= {ula_late_s[0], ctl_ula_late};
    end
    wire pentagon_sp = pentagon_s[1];
    wire core_model_sp = ~model48_s[1];              // Atlas: 0 = 48K, 1 = 128K
    wire ula_late_sp = ~pentagon_s[1] & ula_late_s[1]; // Ferranti ULA variation: valid on Sinclair 48K and 128K, never Pentagon

    // Step 15: live paper offsets CDC aclk -> spclk (slow controls, simple 2FF sufficient)
    (* ASYNC_REG="TRUE" *) reg [8:0] paper_h_s1=9'd64, paper_h_s2=9'd64;
    (* ASYNC_REG="TRUE" *) reg [8:0] paper_v_s1=9'd24, paper_v_s2=9'd24;
    always @(posedge spclk) begin
        paper_h_s1 <= ctl_paper_h; paper_h_s2 <= paper_h_s1;
        paper_v_s1 <= ctl_paper_v; paper_v_s2 <= paper_v_s1;
    end
    wire [8:0] paper_h_sp = paper_h_s2;
    wire [8:0] paper_v_sp = paper_v_s2;
    // PENT_INT / B0053 tuner bus: multi-bit, changes rarely -> 3-FF + settle-latch. The diagnostic
    // native-48 config is then committed only on a VSYNC edge, so a JTAG write can never move ULA
    // timing or /INT halfway through a frame. Ordinary Pentagon tuning inherits the same safe delay.
    (* ASYNC_REG="TRUE" *) reg [31:0] pint_s1 = 32'h00EF0146, pint_s2 = 32'h00EF0146, pint_s3 = 32'h00EF0146;
    reg [31:0] pint_q = 32'h00EF0146;
    reg [31:0] pint_active = 32'h00EF0146;
    reg pint_vsync_d = 1'b0;
    always @(posedge spclk) begin
        pint_s1 <= ctl_pent_int; pint_s2 <= pint_s1; pint_s3 <= pint_s2;
        if (pint_s2 == pint_s3) pint_q <= pint_s2;
        pint_vsync_d <= vid_vsync;
        if (vid_vsync && !pint_vsync_d) pint_active <= pint_q;
    end

    // ---- BulbuLator screen mirror: raw ZX screen tapped off the ULA fetch (main.v scr_cap*) ----
    wire [12:0] scr_capA_w;
    wire [7:0]  scr_capD_w;
    wire        scr_capWe_w;
    wire [2:0]  border_w;                       // live ULA border colour (per-scanline capture below)

`ifdef HYBRID_CORE
    hybrid_zx_core core_i (
        .cpu_halt(cpu_halt_sp),
`elsif MISTER48_CORE
    mister48_core core_i (
        .cpu_halt(cpu_halt_sp),
`else
    main core_i (
`endif
        .model  (core_model_sp),
        .pentagon(pentagon_sp),
        .ula_late(ula_late_sp),
        .ula_tune(pint_active),        // B0053: PENT_INT is free on native48 and becomes a frame-atomic JTAG timing tuner
        .pent_int_v(pint_active[24:16]),
        .pent_int_h(pint_active[8:0]),
        .paper_h(paper_h_sp),
        .paper_v(paper_v_sp),
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

        .ear    (tape_earmux_sp ? tape_ear : sp_ear),   // tape replay overrides the physical ear while loading
        .laudio (laudio),
        .raudio (raudio),
        .midi   (),

        .strb   (kb_strb), .make(kb_make), .code(kb_code),
        .joy1   (joy_sp[7:0]), .joy2(joy_sp[23:16]),   // v0x4A: Kempston fed from JOY_STATE (bits FUDLR match 1:1)
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
        .border_in   (border_sp),
        .tape_sample (tape_sample),
        .tape_sample_strobe(tape_sample_strobe),
        .tape_di_bit(tape_di_bit),
        .cpu_ten     (cpu_ten_sp),
        .warp_nc     (cpuw_active),                // suppress 128K contention ONLY for CPU-only 8x. At 1x and SAFE4x retain the real ZX128 ULA contention: a physical tape is independent of CPU wait-states, and disabling contention for every tape run corrupts long ROM loads such as BigThings BT.2.
        .rom_trap    (rom_trap_core),  // Step 15: trapped M1 opcode fetch
        .p7ffd_live  (p7ffd_live_core), // Step 15: live 128K paging port (7FFD)
        .map_diag_o  (map_diag_core),
        .ula_diag_o  (ula_diag_core),
        .int_dbg0_o  (int_dbg0_core),
        .int_dbg1_o  (int_dbg1_core),
        .int_dbg2_o  (int_dbg2_core),
        .scr_capA    (scr_capA_w),      // BulbuLator screen-mirror tap: ULA fetch address
        .scr_capD    (scr_capD_w),      //   fetched screen byte (displayed bank -> shadow-aware)
        .scr_capWe   (scr_capWe_w),     //   strobe (gated with ne7M0 at the mirror BRAM below)
        .border_o    (border_w)         //   live ULA border colour (per-scanline capture)
    );
    // B0048 passive guest-observation trace.  T80 accepts DI on CEN_n, so
    // retain the LAST nc3M5-qualified sample of each IN-FE window and commit
    // once that window falls.  This fingerprints what the CPU actually saw,
    // unlike the pulse-FIFO hash which stops before the guest input mux.
    // Results reset on each RUN rising edge (not RUN-low), so EOT leaves a
    // retained snapshot for AXI/JTAG post-mortem inspection.
    reg        fe_trace_d = 1'b0, fe_trace_seen = 1'b0, fe_trace_run_d = 1'b0;
    reg [31:0] fe_trace_count_sp = 32'd0, fe_trace_hash_sp = 32'h811C_9DC5, fe_trace_last_sp = 32'h811C_9DC5;
    reg [31:0] fe_trace_cpu_candidate = 32'd0, fe_trace_ula_candidate = 32'd0;
    wire [31:0] fe_trace_cpu_word = {p7ffd_live_core, tape_di_bit, tape_earmux_sp,
                                     cpu_reg_sp[79:64], memA_core[7:0]};
    wire [31:0] fe_trace_ula_word = {5'd0, ula_diag_core};
    always @(posedge spclk) begin
        fe_trace_d <= tape_sample;
        fe_trace_run_d <= trun_s[1];
        if (trun_s[1] && !fe_trace_run_d) begin
            fe_trace_count_sp <= 32'd0;
            fe_trace_hash_sp  <= 32'h811C_9DC5;
            fe_trace_last_sp  <= 32'h811C_9DC5;
            fe_trace_cpu_candidate <= 32'd0;
            fe_trace_ula_candidate <= 32'd0;
            fe_trace_seen <= 1'b0;
        end else if (trun_s[1]) begin
            if (tape_sample_strobe) begin
                fe_trace_cpu_candidate <= fe_trace_cpu_word;
                fe_trace_ula_candidate <= fe_trace_ula_word;
                fe_trace_seen <= 1'b1;
            end
            if (!tape_sample && fe_trace_d && fe_trace_seen) begin
                // Falling after the final CEN_n of this IN-FE: candidate is
                // the same DI[6]/PC/paging state that T80 latched at T3.
                fe_trace_seen <= 1'b0;
                fe_trace_count_sp <= fe_trace_count_sp + 32'd1;
                fe_trace_hash_sp  <= {fe_trace_hash_sp[30:0], fe_trace_hash_sp[31]} ^ fe_trace_cpu_candidate ^
                                     {fe_trace_count_sp[7:0], fe_trace_count_sp[15:8], fe_trace_count_sp[23:16], fe_trace_count_sp[31:24]};
                fe_trace_last_sp  <= {fe_trace_last_sp[30:0], fe_trace_last_sp[31]} ^ fe_trace_ula_candidate ^
                                     {fe_trace_count_sp[7:0], fe_trace_count_sp[15:8], fe_trace_count_sp[23:16], fe_trace_count_sp[31:24]};
            end
        end
    end
    always @(posedge fclk100) begin
        fe_trace_count_a0 <= fe_trace_count_sp; fe_trace_count_a1 <= fe_trace_count_a0;
        fe_trace_hash_a0  <= fe_trace_hash_sp;  fe_trace_hash_a1  <= fe_trace_hash_a0;
        fe_trace_last_a0  <= fe_trace_last_sp;  fe_trace_last_a1  <= fe_trace_last_a0;
    end

    //=============================================================================================
    // Memory-bus mux: while the ARM holds the Z80 halted, it drives the write side of the bus.
    // The video read side (vmmA1 / vmmCe) always comes from the core, so the picture stays live.
    //=============================================================================================
    wire        memWr_eff = clr_active ? 1'b1                         : (cpu_halt_sp ? arm_memWr : memWr_core);
    wire [18:0] memA_eff   = clr_active ? {2'b01, clr_addr}            : (cpu_halt_sp ? arm_memA  : memA_core);
    wire [7:0]  memQ_eff   = clr_active ? 8'h00                        : (cpu_halt_sp ? arm_memQ  : memQ_core);
    wire [13:0] vmmA2_eff  = clr_active ? {clr_addr[15], clr_addr[12:0]} : (cpu_halt_sp ? arm_vmmA2 : vmmA2_core);

    // ---- Load-verification probe: count core RAM writes (spclk). A successful tape load stores
    //      thousands of bytes; a failed pilot-lock stores ~none. The ARM reads MEMWR_CNT (0xAC) before
    //      and after a load window and checks the delta. Coarse 32-bit 2-FF CDC to aclk is fine: the
    //      verdict is a >1000x delta (harness reads a few times, takes the max). Counts memWr_core only -
    //      the cold-reset RAM wipe freezes the core (clr_active gates ne3M5_core), so it never inflates.
    reg        memwr_d_sp   = 1'b0;
    reg [31:0] memwr_cnt_sp = 32'd0;
    always @(posedge spclk) begin
        memwr_d_sp <= memWr_core;
        if (memWr_core & ~memwr_d_sp) memwr_cnt_sp <= memwr_cnt_sp + 32'd1;   // one count per write (rising edge)
    end
    (* ASYNC_REG="TRUE" *) reg [31:0] memwr_s0 = 32'd0, memwr_sync = 32'd0;
    always @(posedge fclk100) begin memwr_s0 <= memwr_cnt_sp; memwr_sync <= memwr_s0; end

    // ============================================================================================
    // SCREEN MIRROR (async, non-intrusive): the ULA screen fetch (scr_cap* from the core) is written
    // into a 2048x32 fabric BRAM in the spclk domain, "as it lands" (shadow-aware: scr_capD is the
    // byte from the DISPLAYED bank). The ARM/JTAG reads it over M_AXI_GP0 (window 0x40008000) which
    // is a SEPARATE path from the DDR controller the core/video/ARM use -> reading it NEVER steals
    // DDR bandwidth -> zero effect on the running machine. 6912 raw ZX bytes = words 0..1727:
    // bitmap 0x0000..0x17FF (interleaved) + attributes 0x1800..0x1AFF. Byte B -> word B[12:2], lane B[1:0].
    // ============================================================================================
    (* ram_style="block" *) reg [31:0] scrmir [0:2047];
    // per-scanline BORDER capture: sample border_w at each hsync into mirror words 1728.. (byte 0).
    // The host renders the loading stripes from these; screen (words 0..1727) + border share one BRAM.
    reg vhs_d = 1'b0, vvs_d = 1'b0;
    reg [8:0] bl_line = 9'd0;
    wire hs_edge = vid_hsync & ~vhs_d;
    wire vs_edge = vid_vsync & ~vvs_d;
    always @(posedge spclk) begin
        vhs_d <= vid_hsync; vvs_d <= vid_vsync;
        if (vs_edge)                          bl_line <= 9'd0;
        else if (hs_edge && bl_line < 9'd319) bl_line <= bl_line + 9'd1;
    end
    // ONE write port, muxed between screen (words 0..1727, all lanes) and border (words 1728.., lane 0).
    // Canonical single-statement byte-write template -> infers as a byte-enabled BRAM (two write
    // statements to the same array flip it to LUTRAM and blow the LUT-as-memory budget).
    wire        mir_scr  = ne7M0 & scr_capWe_w;                 // screen write wins over border
    wire        mir_we   = mir_scr | hs_edge;
    wire [10:0] mir_addr = mir_scr ? scr_capA_w[12:2] : (11'd1728 + {2'b00, bl_line});
    wire [1:0]  mir_lane = mir_scr ? scr_capA_w[1:0]  : 2'd0;
    wire [7:0]  mir_byte = mir_scr ? scr_capD_w       : {5'b0, border_w};
    always @(posedge spclk) if (mir_we) begin
        case (mir_lane)
            2'd0: scrmir[mir_addr][ 7: 0] <= mir_byte;
            2'd1: scrmir[mir_addr][15: 8] <= mir_byte;
            2'd2: scrmir[mir_addr][23:16] <= mir_byte;
            2'd3: scrmir[mir_addr][31:24] <= mir_byte;
        endcase
    end
    // scr_bram_raddr / scr_rdata_r are DECLARED above (before the axi_ctl instance that uses them).
    always @(posedge fclk100) scr_rdata_r <= scrmir[scr_bram_raddr];

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
    fb_wr_axi #(.WORDS(13'd7248)) ddrwr (   // 384*302/16 = 7248 words/frame (Pentagon 384-wide capture). MUST match
        .clk(fclk100), .resetn(core_resetn), .base(wr_base),   // fb_capture_rr FB_W*FB_H/16 and fb_line_disp CROP_W*CROP_H, else the frame boundary lands mid-line -> picture creeps down-left
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
    fb_line_disp #(
        .SRC_W(384), .STRIDE(384), .CROP_W(384), .HMARGIN(256), .SX0(0),
        .CROP_H(302), .VMARGIN(58)
    ) ddrdisp (
        .clk(fclk100), .resetn(core_resetn),
        .disp_base(disp_base), .frame_kick(frame_kick_d),
        .ar_addr(hp_araddr), .ar_id(hp_arid), .ar_len(hp_arlen), .ar_size(hp_arsize),
        .ar_burst(hp_arburst), .ar_cache(hp_arcache), .ar_prot(hp_arprot),
        .ar_lock(hp_arlock), .ar_qos(hp_arqos), .ar_valid(hp_arvalid), .ar_ready(hp_arready),
        .r_data(hp_rdata), .r_last(hp_rlast), .r_valid(hp_rvalid), .r_ready(hp_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .hmargin_a(ctl_scr_pos[11:0]), .vmargin_a(ctl_scr_pos[27:16]),   // Step 15: LIVE whole-frame HDMI position (settle-latched inside fb_line_disp)
        .sx0_a(ctl_crop_a[11:0]), .sy0_a(ctl_crop_a[27:16]),             // Step 15: LIVE crop origin
        .cropw_a(ctl_crop_b[11:0]), .croph_a(ctl_crop_b[27:16]),         // Step 15: LIVE crop size

        .rgb(rgb24),
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

    // ---- Step 14: DDR-backed TRUE-COLOUR OSD layer. ARGB canvas in the non-cacheable DDR window,
    // read over its OWN AXI-HP1 port (osd_ddr_rd = simplified fb_line_disp clone), alpha-blended OVER
    // the 1bpp OSD output. Position/enable synced aclk->clk_pixel (settle-latch/2-FF); base is
    // fclk100-domain (static, set once by the ARM). Full per-pixel FFFFFF true colour (Winamp skin). ----
    reg [31:0] odpos_s1=32'd0, odpos_s2=32'd0, odpos_s3=32'd0, odpos_q=32'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] oden_s = 2'b00;
    always @(posedge clk_pixel) begin
        odpos_s1<=ctl_ddr_osd_pos; odpos_s2<=odpos_s1; odpos_s3<=odpos_s2;
        if (odpos_s2==odpos_s3) odpos_q<=odpos_s2;
        oden_s <= {oden_s[0], ctl_ddr_osd_en};
    end
    wire [23:0] osd_ddr_rgb; wire [7:0] osd_ddr_a; wire osd_ddr_active;
    osd_ddr_rd #(.CW(640), .CH(400)) osddr (   /* Step 14.4: enlarge canvas to DOS 80x25 (640x400 @ VGA 8x16) */
        .clk(fclk100), .resetn(core_resetn), .osd_base(ctl_osd_ddr_base), .frame_kick(frame_kick_d),
        .ar_addr(hp1_araddr), .ar_id(hp1_arid), .ar_len(hp1_arlen), .ar_size(hp1_arsize),
        .ar_burst(hp1_arburst), .ar_cache(hp1_arcache), .ar_prot(hp1_arprot),
        .ar_lock(hp1_arlock), .ar_qos(hp1_arqos), .ar_valid(hp1_arvalid), .ar_ready(hp1_arready),
        .r_data(hp1_rdata), .r_last(hp1_rlast), .r_valid(hp1_rvalid), .r_ready(hp1_rready),
        .rd_clk(clk_pixel), .cx(cx), .cy(cy),
        .x0(odpos_q[10:0]), .y0(odpos_q[26:16]), .en(oden_s[1]),
        .osd_rgb(osd_ddr_rgb), .osd_a(osd_ddr_a), .osd_active(osd_ddr_active)
    );
    // ---- Step 15 timing fix: the compositing chain (1bpp OSD -> DDR-OSD alpha -> banner -> hdmi)
    // was ONE combinational cone (~21 logic levels, 18.2 ns in a 13.468 ns pixel period - the first
    // constrained build exposed it at WNS -5.06; it had silently been the dot/stripe artefact source
    // for the project's whole life). Split into pipeline stages. Every layer's decision + pixels are
    // delayed TOGETHER, so intra-layer alignment is exact; the only global effect is the whole
    // picture (fb + all overlays uniformly) shifting right by 2 px - invisible next to borders. ----
    reg [10:0] cx_d1 = 11'd0, cx_d2 = 11'd0, cy_d1 = 11'd0, cy_d2 = 11'd0;
    always @(posedge clk_pixel) begin cx_d1<=cx; cx_d2<=cx_d1; cy_d1<=cy; cy_d2<=cy_d1; end

    // stage A: register the 1bpp-OSD composite (cuts window-compare + LUTRAM + panel blend out of the cone)
    reg [23:0] rgb24_osd_q = 24'd0;
    always @(posedge clk_pixel) rgb24_osd_q <= rgb24_osd;

    // DDR-OSD layer: +1 delay to stay aligned with the stage-A register (its own 2-stage contract holds)
    reg        od_act_d1 = 1'b0; reg [7:0] od_a_d1 = 8'd0; reg [23:0] od_rgb_d1 = 24'd0;
    always @(posedge clk_pixel) begin
        od_act_d1 <= osd_ddr_active; od_a_d1 <= osd_ddr_a; od_rgb_d1 <= osd_ddr_rgb;
    end

    // stage B: per-pixel alpha blend of the DDR OSD over the 1bpp-OSD output, REGISTERED:
    // osd*a + under*(255-a) >>8  (the 6 multiplies now live alone in one pixel period)
    wire [7:0]  od_ia = 8'd255 - od_a_d1;
    wire [15:0] od_r = od_rgb_d1[23:16]*od_a_d1 + rgb24_osd_q[23:16]*od_ia;
    wire [15:0] od_g = od_rgb_d1[15:8] *od_a_d1 + rgb24_osd_q[15:8] *od_ia;
    wire [15:0] od_b = od_rgb_d1[7:0]  *od_a_d1 + rgb24_osd_q[7:0]  *od_ia;
    reg [23:0] rgb24_ddr_q = 24'd0;
    always @(posedge clk_pixel)
        rgb24_ddr_q <= od_act_d1 ? { od_r[15:8], od_g[15:8], od_b[15:8] } : rgb24_osd_q;

    // Independent status BANNER, composited OVER the OSD output (visible regardless of osd_enable).
    // Runs on the 2-cycle-delayed coordinates so its window tracks the pipelined underlay.
    // Chain: rgb24 -> osd_i -> [reg A] -> DDR-OSD blend [reg B] -> banner_i -> rgb24_ovl -> hdmi.
    wire [23:0] rgb24_ovl;
    banner_compositor banner_i (
        .clk_pixel(clk_pixel), .aclk(fclk100),
        .ban_enable_a(ctl_ban_enable), .ban_we(ctl_ban_we),
        .ban_waddr(ctl_ban_waddr), .ban_wdata(ctl_ban_wdata), .ban_pos_a(ctl_ban_pos),
        .cx(cx_d2), .cy(cy_d2), .rgb_in(rgb24_ddr_q), .rgb_out(rgb24_ovl)
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

    // ANTI-POP 4b: DC-block the FABRIC leg BEFORE the machine<->player crossfade. Otherwise the machine's
    // idle DC level F crossfades through the FINAL blocker on every mux engage/release -> the residual
    // low-freq thump after 4a. Same single-pole HPF (fc~30 Hz); the machine loses only sub-40 Hz content
    // it never produces. Both crossfade legs now DC-free -> crossfade output ~0 DC throughout -> no step.
    reg signed [15:0] fdc_lx = 16'sd0, fdc_rx = 16'sd0;
    reg signed [19:0] fdc_ly = 20'sd0, fdc_ry = 20'sd0;
    wire signed [19:0] fdc_xl  = { {4{left16_a1[15]}},  left16_a1  };
    wire signed [19:0] fdc_xr  = { {4{right16_a1[15]}}, right16_a1 };
    wire signed [19:0] fdc_xl1 = { {4{fdc_lx[15]}}, fdc_lx };
    wire signed [19:0] fdc_xr1 = { {4{fdc_rx[15]}}, fdc_rx };
    wire signed [19:0] fdc_lyn = fdc_xl - fdc_xl1 + fdc_ly - (fdc_ly >>> 8);
    wire signed [19:0] fdc_ryn = fdc_xr - fdc_xr1 + fdc_ry - (fdc_ry >>> 8);
    always @(posedge clk_audio_r) begin
        fdc_lx <= left16_a1;  fdc_ly <= fdc_lyn;
        fdc_rx <= right16_a1; fdc_ry <= fdc_ryn;
    end
    wire signed [15:0] fdc_l16 = (fdc_ly > 20'sd32767) ? 16'sd32767 : (fdc_ly < -20'sd32768) ? -16'sd32768 : fdc_ly[15:0];
    wire signed [15:0] fdc_r16 = (fdc_ry > 20'sd32767) ? 16'sd32767 : (fdc_ry < -20'sd32768) ? -16'sd32768 : fdc_ry[15:0];

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
    // Step 14.3b anti-click (the mux itself was the click source):
    //  (1) HOLD-LAST: on an empty FIFO keep the last player sample instead of falling back to the
    //      machine audio - a 1-sample underrun used to flap the source machine<->player at audio
    //      rate (the "chain of clicks"), and a paused player let the machine leak into the silence.
    reg [31:0] aud_hold = 32'd0;
    always @(posedge clk_audio_r) if (player_live) aud_hold <= aud_dout;
    wire [31:0] player_pcm = player_live ? aud_dout : aud_hold;
    //  (2) CROSSFADE machine<->player over ~1.3 ms on AUDIO_CTRL on/off (mirrors the mgain pause
    //      fade) - no more DC step when the mux engages/releases (start/stop clicks).
    reg  [8:0] pgain = 9'd0;
    wire [8:0] ptgt = pen_s[1] ? 9'd256 : 9'd0;
    always @(posedge clk_audio_r)                            /* 1/sample slew = ~5.3 ms crossfade (a 1.3 ms DC ramp was still a soft thump) */
        if (pgain < ptgt) pgain <= pgain + 9'd1; else if (pgain > ptgt) pgain <= pgain - 9'd1;
    wire [8:0] mgn = 9'd256 - pgain;
    // blend in full-width products (lesson: a narrow assignment context truncates the multiply)
    wire signed [25:0] lmix_p = $signed(fdc_l16) * $signed({1'b0, mgn}) + $signed(player_pcm[15:0])  * $signed({1'b0, pgain});
    wire signed [25:0] rmix_p = $signed(fdc_r16) * $signed({1'b0, mgn}) + $signed(player_pcm[31:16]) * $signed({1'b0, pgain});
    wire signed [16:0] lmix_s = lmix_p >>> 8;
    wire signed [16:0] rmix_s = rmix_p >>> 8;
    wire signed [15:0] lmix16 = (lmix_s > 17'sd32767) ? 16'sd32767 : (lmix_s < -17'sd32768) ? -16'sd32768 : lmix_s[15:0];
    wire signed [15:0] rmix16 = (rmix_s > 17'sd32767) ? 16'sd32767 : (rmix_s < -17'sd32768) ? -16'sd32768 : rmix_s[15:0];

    // Select/blend the audio source BEFORE applying the volume scaling, so that the player
    // obeys the OSD F9 volume level (ctl_vol) just like the fabric machine's audio.
    // Step 14.2: mix the tape loading sound (1-bit ear -> +/-A square, gated by "playing", muteable)
    // into the pre-volume PCM so it obeys the F9 volume (ctl_vol) + the pause mute. Saturating add.
    (* ASYNC_REG="TRUE" *) reg [1:0] tear_aud = 2'b00, tmute_aud = 2'b00, tplay_aud = 2'b00;
    always @(posedge clk_audio_r) begin
        tear_aud  <= {tear_aud[0],  tape_ear};
        tmute_aud <= {tmute_aud[0], ctl_tape_mute};
        tplay_aud <= {tplay_aud[0], tape_playing};
    end
    wire signed [15:0] tape_pcm = (tmute_aud[1] | ~tplay_aud[1]) ? 16'sd0
                                 : (tear_aud[1] ? 16'sd6000 : -16'sd6000);
    wire signed [16:0] lsum = lmix16 + tape_pcm;
    wire signed [16:0] rsum = rmix16 + tape_pcm;
    wire [15:0] src_left  = (lsum > 17'sd32767) ? 16'h7FFF : (lsum < -17'sd32768) ? 16'h8000 : lsum[15:0];
    wire [15:0] src_right = (rsum > 17'sd32767) ? 16'h7FFF : (rsum < -17'sd32768) ? 16'h8000 : rsum[15:0];

    // HDMI volume (Step 13, F9 menu): scale the signed-16 PCM by ctl_vol (0..255 gain, /256; 255 ~=
    // unity) in the slow clk_audio domain, so the multiply has ample slack and one DSP per channel.
    // ctl_vol is set by the ARM from the options menu; 2-FF sync it in. Composes with the pause mute
    // (while halted src_left/src_right is already silenced, and silence*gain stays silent).
    reg  [7:0] vol_c0 = 8'd255, vol_c1 = 8'd255;   // 2-FF CDC of the TARGET volume (ctl_vol)
    reg  [7:0] vgain  = 8'd255;                     // click-free SLEWED gain (ramps toward the target)
    always @(posedge clk_audio_r) begin
        vol_c0 <= ctl_vol; vol_c1 <= vol_c0;        // sync the target across the clock domain
        if      (vgain < vol_c1) vgain <= vgain + 8'd1;   // 1 LSB/sample: full 0..255 swing ~5.3 ms;
        else if (vgain > vol_c1) vgain <= vgain - 8'd1;   // a 5%-step (~13 LSB) glides in ~0.27 ms -> no zipper
    end
    // FULL-WIDTH product first (a bare (a*b)>>>8 assigned to a 16-bit reg makes Verilog size the
    // multiply to the 16-bit assignment context -> the product overflows + truncates -> garbage/no
    // sound). Compute the signed product in a 25-bit wire, THEN arithmetic-shift /256 (vol 255 ~= 1x).
    wire signed [24:0] lprod = $signed(src_left)  * $signed({1'b0, vgain});
    wire signed [24:0] rprod = $signed(src_right) * $signed({1'b0, vgain});
    reg signed [15:0] left16_v, right16_v;
    always @(posedge clk_audio_r) begin
        left16_v  <= lprod >>> 8;
        right16_v <= rprod >>> 8;
    end

    // Step 14.3c studio-grade DC blocker (single-pole HPF, fc ~30 Hz): y[n] = x[n] - x[n-1] + (255/256)y[n-1].
    // This is the digital twin of the AC-coupling caps in the real hardware's audio path - NO source
    // (machine DC from the beeper bit, mux transitions, pause) can push a DC step to the speakers, so
    // any residual transition thump dies by construction. Audio content above ~40 Hz is untouched.
    reg signed [15:0] dcb_lx = 16'sd0, dcb_rx = 16'sd0;
    reg signed [19:0] dcb_ly = 20'sd0, dcb_ry = 20'sd0;       /* headroom against clip-adjacent swings */
    // Verilog gotcha (caused a full-scale rumble on hardware): a CONCATENATION is always UNSIGNED and
    // poisons the whole expression -> ">>>" degraded to a logical shift for negative y. Sign-extend
    // through intermediate SIGNED wires so the arithmetic (and the shift) stay signed. Verified
    // against a bit-exact host simulation (buggy: mean err 30807 = garbage; signed: 389 = clean HPF).
    wire signed [19:0] dcb_xl  = { {4{left16_v[15]}},  left16_v  };
    wire signed [19:0] dcb_xr  = { {4{right16_v[15]}}, right16_v };
    wire signed [19:0] dcb_xl1 = { {4{dcb_lx[15]}}, dcb_lx };
    wire signed [19:0] dcb_xr1 = { {4{dcb_rx[15]}}, dcb_rx };
    wire signed [19:0] dcb_lyn = dcb_xl - dcb_xl1 + dcb_ly - (dcb_ly >>> 8);
    wire signed [19:0] dcb_ryn = dcb_xr - dcb_xr1 + dcb_ry - (dcb_ry >>> 8);
    always @(posedge clk_audio_r) begin
        dcb_lx <= left16_v;  dcb_ly <= dcb_lyn;
        dcb_rx <= right16_v; dcb_ry <= dcb_ryn;
    end
    wire signed [15:0] dcb_l16 = (dcb_ly > 20'sd32767) ? 16'sd32767 : (dcb_ly < -20'sd32768) ? -16'sd32768 : dcb_ly[15:0];
    wire signed [15:0] dcb_r16 = (dcb_ry > 20'sd32767) ? 16'sd32767 : (dcb_ry < -20'sd32768) ? -16'sd32768 : dcb_ry[15:0];
    wire [15:0] audio_left_f  = dcb_l16;
    wire [15:0] audio_right_f = dcb_r16;

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
