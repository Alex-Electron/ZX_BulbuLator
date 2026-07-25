// SPDX-License-Identifier: GPL-3.0-or-later
//
// Step-15 machine-preserving hybrid:
//   native 48K       -> MiSTer ULA + T80 backend
//   128K / Pentagon  -> established Atlas backend
//
// Both backends are reset and receive input together, but only the selected
// backend owns memory, video, audio and diagnostics. Machine changes in ARM
// are already guarded by a cold reset, so no live bus state crosses the mux.

module hybrid_zx_core
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
    input  wire       reset,
    input  wire       nmi,
    input  wire       cpu_halt,
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

    wire use_mister = ~model & ~pentagon;

    wire a_blank, a_hsync, a_vsync, a_r, a_g, a_b, a_i;
    wire [10:0] a_laudio, a_raudio;
    wire a_midi, a_cs, a_ck, a_mosi;
    wire a_vmmCe, a_memCe, a_memRf, a_memRd, a_memWr;
    wire [13:0] a_vmmA1, a_vmmA2;
    wire [18:0] a_memA;
    wire [7:0] a_memQ;
    wire [211:0] a_reg_out;
    wire a_tape_sample, a_tape_sample_strobe, a_tape_di_bit, a_cpu_ten, a_rom_trap;
    wire [5:0] a_p7ffd_live;
    wire [7:0] a_map_diag;
    wire [26:0] a_ula_diag;
    wire [31:0] a_int_dbg0, a_int_dbg1, a_int_dbg2;
    wire [12:0] a_scr_capA;
    wire [7:0] a_scr_capD;
    wire a_scr_capWe;
    wire [2:0] a_border;

    wire m_blank, m_hsync, m_vsync, m_r, m_g, m_b, m_i;
    wire [10:0] m_laudio, m_raudio;
    wire m_midi, m_cs, m_ck, m_mosi;
    wire m_vmmCe, m_memCe, m_memRf, m_memRd, m_memWr;
    wire [13:0] m_vmmA1, m_vmmA2;
    wire [18:0] m_memA;
    wire [7:0] m_memQ;
    wire [211:0] m_reg_out;
    wire m_tape_sample, m_tape_sample_strobe, m_tape_di_bit, m_cpu_ten, m_rom_trap;
    wire [5:0] m_p7ffd_live;
    wire [7:0] m_map_diag;
    wire [26:0] m_ula_diag;
    wire [31:0] m_int_dbg0, m_int_dbg1, m_int_dbg2;
    wire [12:0] m_scr_capA;
    wire [7:0] m_scr_capD;
    wire m_scr_capWe;
    wire [2:0] m_border;

    main atlas_i (
        .model(model), .pentagon(pentagon), .ula_late(ula_late), .ula_tune(ula_tune),
        .warp_nc(warp_nc), .pent_int_v(pent_int_v), .pent_int_h(pent_int_h),
        .paper_h(paper_h), .paper_v(paper_v), .mapper(mapper),
        .reset(reset), .nmi(nmi),
        .clock(clock), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5),
        .blank(a_blank), .hsync(a_hsync), .vsync(a_vsync), .r(a_r), .g(a_g), .b(a_b), .i(a_i),
        .ear(ear), .laudio(a_laudio), .raudio(a_raudio), .midi(a_midi),
        .strb(strb), .make(make), .code(code), .joy1(joy1), .joy2(joy2),
        .cs(a_cs), .ck(a_ck), .miso(miso), .mosi(a_mosi),
        .vmmCe(a_vmmCe), .vmmA1(a_vmmA1), .vmmA2(a_vmmA2), .vmmD(vmmD),
        .memCe(a_memCe), .memRf(a_memRf), .memRd(a_memRd), .memWr(a_memWr),
        .memA(a_memA), .memD(memD), .memQ(a_memQ),
        .dirset(dirset), .dir(dir), .reg_out(a_reg_out),
        .force_7ffd(force_7ffd), .port7ffd_in(port7ffd_in),
        .force_border(force_border), .border_in(border_in),
        .tape_sample(a_tape_sample), .tape_sample_strobe(a_tape_sample_strobe),
        .tape_di_bit(a_tape_di_bit), .cpu_ten(a_cpu_ten), .rom_trap(a_rom_trap),
        .p7ffd_live(a_p7ffd_live), .map_diag_o(a_map_diag), .ula_diag_o(a_ula_diag),
        .int_dbg0_o(a_int_dbg0), .int_dbg1_o(a_int_dbg1), .int_dbg2_o(a_int_dbg2),
        .scr_capA(a_scr_capA), .scr_capD(a_scr_capD), .scr_capWe(a_scr_capWe),
        .border_o(a_border)
    );

    mister48_core mister_i (
        .model(model), .pentagon(pentagon), .ula_late(ula_late), .ula_tune(ula_tune),
        .warp_nc(warp_nc), .pent_int_v(pent_int_v), .pent_int_h(pent_int_h),
        .paper_h(paper_h), .paper_v(paper_v), .mapper(mapper),
        .reset(reset), .nmi(nmi), .cpu_halt(cpu_halt),
        .clock(clock), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5),
        .blank(m_blank), .hsync(m_hsync), .vsync(m_vsync), .r(m_r), .g(m_g), .b(m_b), .i(m_i),
        .ear(ear), .laudio(m_laudio), .raudio(m_raudio), .midi(m_midi),
        .strb(strb), .make(make), .code(code), .joy1(joy1), .joy2(joy2),
        .cs(m_cs), .ck(m_ck), .miso(miso), .mosi(m_mosi),
        .vmmCe(m_vmmCe), .vmmA1(m_vmmA1), .vmmA2(m_vmmA2), .vmmD(vmmD),
        .memCe(m_memCe), .memRf(m_memRf), .memRd(m_memRd), .memWr(m_memWr),
        .memA(m_memA), .memD(memD), .memQ(m_memQ),
        .dirset(dirset), .dir(dir), .reg_out(m_reg_out),
        .force_7ffd(force_7ffd), .port7ffd_in(port7ffd_in),
        .force_border(force_border), .border_in(border_in),
        .tape_sample(m_tape_sample), .tape_sample_strobe(m_tape_sample_strobe),
        .tape_di_bit(m_tape_di_bit), .cpu_ten(m_cpu_ten), .rom_trap(m_rom_trap),
        .p7ffd_live(m_p7ffd_live), .map_diag_o(m_map_diag), .ula_diag_o(m_ula_diag),
        .int_dbg0_o(m_int_dbg0), .int_dbg1_o(m_int_dbg1), .int_dbg2_o(m_int_dbg2),
        .scr_capA(m_scr_capA), .scr_capD(m_scr_capD), .scr_capWe(m_scr_capWe),
        .border_o(m_border)
    );

    assign blank  = use_mister ? m_blank  : a_blank;
    assign hsync  = use_mister ? m_hsync  : a_hsync;
    assign vsync  = use_mister ? m_vsync  : a_vsync;
    assign r      = use_mister ? m_r      : a_r;
    assign g      = use_mister ? m_g      : a_g;
    assign b      = use_mister ? m_b      : a_b;
    assign i      = use_mister ? m_i      : a_i;
    assign laudio = use_mister ? m_laudio : a_laudio;
    assign raudio = use_mister ? m_raudio : a_raudio;
    assign midi   = use_mister ? m_midi   : a_midi;
    assign cs     = use_mister ? m_cs     : a_cs;
    assign ck     = use_mister ? m_ck     : a_ck;
    assign mosi   = use_mister ? m_mosi   : a_mosi;
    assign vmmCe  = use_mister ? m_vmmCe  : a_vmmCe;
    assign vmmA1  = use_mister ? m_vmmA1  : a_vmmA1;
    assign vmmA2  = use_mister ? m_vmmA2  : a_vmmA2;
    assign memCe  = use_mister ? m_memCe  : a_memCe;
    assign memRf  = use_mister ? m_memRf  : a_memRf;
    assign memRd  = use_mister ? m_memRd  : a_memRd;
    assign memWr  = use_mister ? m_memWr  : a_memWr;
    assign memA   = use_mister ? m_memA   : a_memA;
    assign memQ   = use_mister ? m_memQ   : a_memQ;
    assign reg_out            = use_mister ? m_reg_out            : a_reg_out;
    assign tape_sample        = use_mister ? m_tape_sample        : a_tape_sample;
    assign tape_sample_strobe = use_mister ? m_tape_sample_strobe : a_tape_sample_strobe;
    assign tape_di_bit        = use_mister ? m_tape_di_bit        : a_tape_di_bit;
    assign cpu_ten            = use_mister ? m_cpu_ten            : a_cpu_ten;
    assign rom_trap           = use_mister ? m_rom_trap           : a_rom_trap;
    assign p7ffd_live         = use_mister ? m_p7ffd_live         : a_p7ffd_live;
    assign map_diag_o         = use_mister ? m_map_diag           : a_map_diag;
    assign ula_diag_o         = use_mister ? m_ula_diag           : a_ula_diag;
    assign int_dbg0_o         = use_mister ? m_int_dbg0           : a_int_dbg0;
    assign int_dbg1_o         = use_mister ? m_int_dbg1           : a_int_dbg1;
    assign int_dbg2_o         = use_mister ? m_int_dbg2           : a_int_dbg2;
    assign scr_capA           = use_mister ? m_scr_capA           : a_scr_capA;
    assign scr_capD           = use_mister ? m_scr_capD           : a_scr_capD;
    assign scr_capWe          = use_mister ? m_scr_capWe          : a_scr_capWe;
    assign border_o           = use_mister ? m_border             : a_border;

endmodule
