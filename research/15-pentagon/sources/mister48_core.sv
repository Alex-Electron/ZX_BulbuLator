// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal BulbuLator adapter for the ZX Spectrum MiSTer ULA + T80pa.
//
// This is deliberately a compile-time diagnostic backend, not a replacement
// for the complete Step-15 design.  The board-facing ARM/AXI control plane,
// mem_zx storage, snapshot injection, tape FIFO, keyboard event source,
// framebuffer/HDMI and OSD remain in bulbulator_zx_ddr_top.
//
// The upstream ULA is Sorgelig's rtl/ula.sv from ZX-Spectrum_MISTer,
// pinned by the experiment manifest.  T80pa v0250 comes from the same tree.

module mister48_core
(
    input  wire       model,
    input  wire       pentagon,
    input  wire       ula_late,
    input  wire[31:0] ula_tune,
    input  wire       warp_nc,
    input  wire[8:0]  pent_int_v,
    input  wire[8:0]  pent_int_h,
    input  wire[8:0]  paper_h,
    input  wire[8:0]  paper_v,
    input  wire       mapper,

    input  wire       reset,       // active-low, matching Atlas main
    input  wire       nmi,
    input  wire       cpu_halt,    // halt CPU only; ULA remains free-running

    input  wire       clock,
    input  wire       pe7M0,
    input  wire       ne7M0,
    input  wire       pe3M5,
    input  wire       ne3M5,

    output wire       blank,
    output wire       hsync,
    output wire       vsync,
    output wire       r,
    output wire       g,
    output wire       b,
    output wire       i,

    input  wire       ear,
    output wire[10:0] laudio,
    output wire[10:0] raudio,
    output wire       midi,

    input  wire       strb,
    input  wire       make,
    input  wire[7:0]  code,

    input  wire[7:0]  joy1,
    input  wire[7:0]  joy2,

    output wire       cs,
    output wire       ck,
    input  wire       miso,
    output wire       mosi,

    output wire       vmmCe,
    output wire[13:0] vmmA1,
    output wire[13:0] vmmA2,
    input  wire[7:0]  vmmD,

    output wire       memCe,
    output wire       memRf,
    output wire       memRd,
    output wire       memWr,
    output wire[18:0] memA,
    input  wire[7:0]  memD,
    output wire[7:0]  memQ,

    input  wire        dirset,
    input  wire[211:0] dir,
    output wire[211:0] reg_out,
    input  wire        force_7ffd,
    input  wire[5:0]   port7ffd_in,
    input  wire        force_border,
    input  wire[2:0]   border_in,

    output wire        tape_sample,
    output wire        tape_sample_strobe,
    output wire        tape_di_bit,
    output wire        cpu_ten,
    output wire        rom_trap,
    output wire[5:0]   p7ffd_live,
    output wire[7:0]   map_diag_o,
    output wire[26:0]  ula_diag_o,
    output wire[31:0]  int_dbg0_o,
    output wire[31:0]  int_dbg1_o,
    output wire[31:0]  int_dbg2_o,

    output wire[12:0]  scr_capA,
    output wire[7:0]   scr_capD,
    output wire        scr_capWe,
    output wire[2:0]   border_o
);

    // The first smoke build is intentionally fixed to native 48K.  Keep the
    // otherwise-common interface so the top can swap backends without moving
    // any ARM/AXI wiring.
    wire unused_cfg = model ^ pentagon ^ ula_late ^ ula_tune[0] ^ warp_nc ^
                      pent_int_v[0] ^ pent_int_h[0] ^ paper_h[0] ^ paper_v[0] ^
                      mapper ^ force_7ffd ^ port7ffd_in[0] ^ pe3M5 ^ ne3M5 ^
                      miso;

    wire [15:0] a;
    wire [7:0]  d;
    wire [7:0]  q;
    wire        rfsh;
    wire        mreq;
    wire        iorq;
    wire        m1;
    wire        rd;
    wire        wr;
    wire        ula_int_n;
    wire        ula_cpu_pe;
    wire        ula_cpu_ne;

    // MiSTer ULA owns the exact native CPU/contention cadence.  FAST8 must
    // accelerate only T80 while leaving that ULA/raster cadence untouched.
    // Do not mux directly between two unrelated CE pairs: doing so can leave
    // T80 after a PE without its matching NE (the historic half-CEN failure).
    //
    // Enter FAST only after an actual MiSTer ULA NE.  The local FAST pair then
    // emits PE,NE on alternating 56.7-MHz master cycles (~28.3M T/s = 8x).
    // Leave FAST after its own NE, suppress native NE until the next native PE,
    // and only then return ownership to the ULA.  tape_player is clocked from
    // cpu_ten below, so tape and CPU see the same T-state count during both
    // transitions and throughout the warp.
    localparam [1:0] CPU_NATIVE = 2'd0,
                     CPU_FAST   = 2'd1,
                     CPU_RESUME = 2'd2;
    reg [1:0] cpu_speed_state = CPU_NATIVE;
    reg       fast_phase = 1'b0; // FAST: 0=PE, 1=NE

    always @(posedge clock or negedge reset) begin
        if (!reset) begin
            cpu_speed_state <= CPU_NATIVE;
            fast_phase      <= 1'b0;
        end else begin
            case (cpu_speed_state)
                CPU_NATIVE: begin
                    fast_phase <= 1'b0;
                    if (warp_nc && ula_cpu_ne)
                        cpu_speed_state <= CPU_FAST;
                end
                CPU_FAST: begin
                    fast_phase <= ~fast_phase;
                    if (!warp_nc && fast_phase) begin
                        cpu_speed_state <= CPU_RESUME;
                        fast_phase      <= 1'b0;
                    end
                end
                default: begin // CPU_RESUME
                    fast_phase <= 1'b0;
                    if (ula_cpu_pe)
                        cpu_speed_state <= CPU_NATIVE;
                end
            endcase
        end
    end

    wire cpu_pe_raw = (cpu_speed_state == CPU_FAST)   ? ~fast_phase :
                      (cpu_speed_state == CPU_RESUME) ?  ula_cpu_pe :
                                                        ula_cpu_pe;
    wire cpu_ne_raw = (cpu_speed_state == CPU_FAST)   ?  fast_phase :
                      (cpu_speed_state == CPU_RESUME) ?  1'b0 :
                                                        ula_cpu_ne;
    wire cpu_pe = cpu_pe_raw & ~cpu_halt;
    wire cpu_ne = cpu_ne_raw & ~cpu_halt;

    cpu cpu_i (
        .clock(clock),
        .pe(cpu_pe),
        .ne(cpu_ne),
        .reset(reset),
        .rfsh(rfsh),
        .mreq(mreq),
        .iorq(iorq),
        .nmi(nmi),
        .irq(ula_int_n),
        .m1(m1),
        .rd(rd),
        .wr(wr),
        .d(d),
        .q(q),
        .a(a),
        .dirset(dirset),
        .dir(dir),
        .reg_out(reg_out)
    );

    // 48K physical map chosen to match the Step-15 ARM snapshot/tier0
    // conventions exactly:
    //   0000 ROM1 (48 BASIC), 4000 bank5, 8000 bank2, C000 bank0.
    wire [2:0] ram_page = (a[15:14] == 2'b01) ? 3'd5 :
                          (a[15:14] == 2'b10) ? 3'd2 : 3'd0;
    assign memRf = ~mreq & ~rfsh;
    assign memRd = ~mreq & ~rd;
    assign memWr = ~mreq & ~wr & (a[15] | a[14]);
    assign memA  = (a[15:14] == 2'b00)
                 ? {2'b00, 1'b0, 2'b01, a[13:0]}
                 : {2'b01, ram_page, a[13:0]};
    assign memQ  = q;
    assign memCe = cpu_pe;

    // Existing mem_zx screen shadow is retained.  MiSTer vram_addr bit 14 is
    // the displayed page selector; standard 48K ignores its Timex bit 13.
    wire [14:0] ula_vram_addr;
    assign vmmCe = pe7M0;
    assign vmmA1 = {ula_vram_addr[14], ula_vram_addr[12:0]};
    assign vmmA2 = {1'b0, a[12:0]};

    // Keep the proven Step-15 scancode-to-matrix adapter for the first port.
    wire [4:0] key_q;
    keyboard keyboard_i (
        .clock(clock),
        .ce(pe7M0),
        .strb(strb),
        .make(make),
        .code(code),
        .q(key_q),
        .a(a[15:8])
    );

    wire io_rd = ~iorq & ~rd;
    wire io_wr = ~iorq & ~wr;
    wire fe_sel = ~a[0];
    wire kemp_sel = (a[5:0] == 6'h1F);

    reg [2:0] border = 3'd0;
    reg       speaker = 1'b0;
    reg       mic = 1'b0;
    reg       io_wr_d = 1'b0;
    always @(posedge clock) begin
        io_wr_d <= io_wr;
        if (!reset) begin
            border  <= 3'd0;
            speaker <= 1'b0;
            mic     <= 1'b0;
        end else if (force_border) begin
            border <= border_in;
        end else if (io_wr && !io_wr_d && fe_sel) begin
            {speaker, mic, border} <= q[4:0];
        end
    end

    wire ear_bit = ear | speaker;
    wire [7:0] ula_port_ff;
    wire ula_hblank, ula_vblank;
    wire ulap_sel, ulap_ena, ulap_mono, mode512;
    wire [7:0] ulap_dout, ulap_color;

    ULA ula_i (
        .reset(~reset),
        .clk_sys(clock),
        .ce_7mp(pe7M0),
        .ce_7mn(ne7M0),
        .ce_cpu_sp(ula_cpu_pe),
        .ce_cpu_sn(ula_cpu_ne),

        .addr(a),
        .din(q),
        .nMREQ(mreq),
        .nIORQ(iorq),
        .nRFSH(rfsh),
        .nRD(rd),
        .nWR(wr),
        .nINT(ula_int_n),

        .vram_addr(ula_vram_addr),
        .vram_dout(vmmD),
        .port_ff(ula_port_ff),

        .ulap_avail(1'b0),
        .ulap_sel(ulap_sel),
        .ulap_dout(ulap_dout),
        .ulap_ena(ulap_ena),
        .ulap_mono(ulap_mono),
        .ulap_color(ulap_color),

        .tmx_avail(1'b0),
        .mode512(mode512),

        .snow_ena(1'b1),
        .mZX(1'b1),
        .m128(1'b0),
        .page_scr(1'b0),
        .page_ram(3'd0),
        .border_color(border),
        .wide(2'd0),

        .HSync(hsync),
        .VSync(vsync),
        .HBlank(ula_hblank),
        .VBlank(ula_vblank),
        .I(i),
        .R(r),
        .G(g),
        .B(b)
    );

    assign blank = ula_hblank | ula_vblank;
    assign border_o = border;

    // ULA/keyboard takes priority on any even I/O address, Kempston on xx1F,
    // and the MiSTer floating bus supplies the remaining reads.
    assign d = ~mreq                 ? memD :
               (io_rd && fe_sel)    ? {1'b1, ear_bit, 1'b1, key_q} :
               (io_rd && kemp_sel)  ? (joy1 | joy2) :
               io_rd                ? ula_port_ff :
                                      8'hFF;

    assign tape_sample        = io_rd & fe_sel;
    assign tape_sample_strobe = tape_sample & cpu_ne;
    assign tape_di_bit        = ear_bit;
    assign cpu_ten            = cpu_pe;
    assign rom_trap           = ~m1 & ~mreq & (a == 16'h056B);
    assign p7ffd_live         = 6'b010000;

    // Rendered ULA-fetch mirror without modifying upstream ula.sv.
    //
    // Merely using ula_vram_addr as the mirror destination is insufficient for
    // snow: when the refresh address corrupts RAS, both the fetched byte AND
    // that source address change, so writing the byte back at the corrupt
    // source reconstructs ordinary RAM rather than the pixels actually shown.
    //
    // Keep a lockstep copy of the MiSTer 48K raster (both start at zero on PL
    // configuration and, like the upstream ULA, intentionally ignore hot
    // machine reset). At the ULA's 9/B/D/F capture phases, write vmmD to the
    // NOMINAL bitmap/attribute destination derived from the beam. A snow-
    // substituted source byte therefore lands where it was visibly rendered.
    reg [8:0] cap_h = 9'd0;
    reg [8:0] cap_v = 9'd0;
    wire [8:0] cap_h_next = (cap_h == 9'd447) ? 9'd0 : (cap_h + 9'd1);
    wire [8:0] cap_v_next = (cap_h == 9'd447)
                           ? ((cap_v == 9'd311) ? 9'd0 : (cap_v + 9'd1))
                           : cap_v;
    always @(posedge clock) if (ne7M0) begin
        cap_h <= cap_h_next;
        cap_v <= cap_v_next;
    end

    wire cap_bitmap = (cap_h_next[3:0] == 4'h9) || (cap_h_next[3:0] == 4'hD);
    wire cap_attr   = (cap_h_next[3:0] == 4'hB) || (cap_h_next[3:0] == 4'hF);
    wire cap_paper  = (cap_h_next < 9'd256) && (cap_v < 9'd192);
    wire [12:0] cap_bitmap_addr =
        {cap_v[7:6], cap_v[2:0], cap_v[5:3], cap_h_next[7:4], cap_h_next[2]};
    wire [12:0] cap_attr_addr =
        {3'b110, cap_v[7:3], cap_h_next[7:4], cap_h_next[2]};

    assign scr_capA  = cap_bitmap ? cap_bitmap_addr : cap_attr_addr;
    assign scr_capD  = vmmD;
    assign scr_capWe = ne7M0 && cap_paper && (cap_bitmap || cap_attr);

    wire audio_bit = speaker | mic | ear;
    assign laudio = {audio_bit, 10'd0};
    assign raudio = {audio_bit, 10'd0};
    assign midi = 1'b0;

    assign cs = 1'b1;
    assign ck = 1'b0;
    assign mosi = 1'b1;

    assign map_diag_o = 8'd0;
    assign ula_diag_o = {26'd0, unused_cfg};
    assign int_dbg0_o = 32'd0;
    assign int_dbg1_o = 32'd0;
    assign int_dbg2_o = 32'd0;

endmodule
