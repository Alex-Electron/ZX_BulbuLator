// nes_wrap.v - BulbuLator wrapper around the NESTang `NES` core (Round-1: BRAM cartridge, NROM-class).
// Bundles: NES core + nes_mem_bram (true-dual-port BRAM) + joypad shifter, and CENTRALISES the
// aclk(control-plane)->nesclk(core) CDC: mapper_flags / joy / loading / resets are all quasi-static
// or slow, so a 2-FF synchroniser into nesclk is correct and lets the whole aclk<->nesclk crossing be
// declared asynchronous (set_clock_groups) for timing closure. The ROM LOAD port stays in aclk (ld_clk)
// and writes the dual-port BRAM in its own domain (no lost strobes).
//
// CE22 UNIFORM JOY_STATE ORDER. joy1/joy2 now arrive in the PLATFORM order, identical for every core:
//   bit0=RIGHT 1=LEFT 2=DOWN 3=UP 4=A/FIRE 5=B/FIRE2 6=SELECT/FIRE3 7=START
// which is what ZX Kempston already delivers (atlas_core/main.v:495 = 000FUDLR) and what
// CORE_DESCRIPTOR_DESIGN.json fixes as a hard invariant: the bit NUMBER is RTL-fixed across cores,
// a core may only relabel bits 4-7. Before CE22 this wrapper consumed the raw NES shift order instead,
// so the same bit meant "Right" on the ZX and "A" on the NES: every label in the ARM mapping wizard
// lied, the SOCD cancel of pairs (0,1)/(2,3) killed A+B and Select+Start instead of opposite
// directions, and the default map left bits 6-7 empty = no Left/Right on the NES at all.
// nes_order() below is the ONLY place that knows the NES shift order (A read first).

module nes_wrap (
    input  wire        clk,          // NES master ~21.5 MHz (nesclk)
    input  wire        ld_clk,       // control-plane clock (aclk/fclk100) - ROM load port
    input  wire        reset_nes,    // aclk: soft reset pulse (ctl_nes_reset)
    input  wire        cold_reset,   // aclk: power-on reset level
    input  wire [1:0]  sys_type,     // region (static)
    input  wire [63:0] mapper_flags, // aclk (quasi-static, latched before reset release)

    // ARM ROM load port (aclk domain)
    input  wire        loading,      // aclk (quasi-static)
    input  wire        ld_we,
    input  wire        ld_sel,
    input  wire [21:0] ld_addr,
    input  wire [7:0]  ld_data,

    // two parallel joypads (aclk, slow)
    input  wire [7:0]  joy1,
    input  wire [7:0]  joy2,

    output wire [5:0]  color,
    output wire [8:0]  cycle,
    output wire [8:0]  scanline,
    output wire [2:0]  emphasis,
    output wire [15:0] sample,
    output wire        apu_ce,
    output wire [31:0] mem_dbg      // bring-up: {vram_ce_cnt, ciram_write_cnt} from nes_mem_bram
);
    // ---- aclk -> nesclk 2-FF synchronisers (quasi-static / slow signals) ----
    (* ASYNC_REG="TRUE" *) reg [63:0] mf_s1=0, mf_s2=0;
    (* ASYNC_REG="TRUE" *) reg [7:0]  j1_s1=8'hFF, j1_s2=8'hFF, j2_s1=8'hFF, j2_s2=8'hFF;
    (* ASYNC_REG="TRUE" *) reg [1:0]  ldg_s=2'b00, rn_s=2'b00, cr_s=2'b00;
    always @(posedge clk) begin
        mf_s1 <= mapper_flags; mf_s2 <= mf_s1;
        j1_s1 <= joy1; j1_s2 <= j1_s1;  j2_s1 <= joy2; j2_s2 <= j2_s1;
        ldg_s <= {ldg_s[0], loading};
        rn_s  <= {rn_s[0],  reset_nes};
        cr_s  <= {cr_s[0],  cold_reset};
    end
    wire loading_ns = ldg_s[1];
    wire core_reset = cr_s[1] | ldg_s[1] | rn_s[1];   // in nesclk

    // ---- cartridge memory buses ----
    wire [21:0] cpumem_addr, ppumem_addr;
    wire        cpumem_read, cpumem_write, ppumem_read, ppumem_write;
    wire [7:0]  cpumem_dout, ppumem_dout, cpumem_din, ppumem_din;
    wire        vram_ce_ns, vram_a10_ns;   // PPU CIRAM select/mirroring (nametable vs cart CHR)
    nes_mem_bram mem (
        .clk(clk), .ld_clk(ld_clk), .loading(loading_ns),
        .cpumem_addr(cpumem_addr), .cpumem_read(cpumem_read), .cpumem_write(cpumem_write),
        .cpumem_dout(cpumem_dout), .cpumem_din(cpumem_din),
        .ppumem_addr(ppumem_addr), .ppumem_read(ppumem_read), .ppumem_write(ppumem_write),
        .ppumem_dout(ppumem_dout), .ppumem_din(ppumem_din),
        .ppu_vram_ce(vram_ce_ns), .ppu_vram_a10(vram_a10_ns),
        .ld_we(ld_we & loading), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),  // aclk-domain load
        .dbg(mem_dbg)
    );

    // ---- joypad parallel->serial shifter (nesclk) ----
    // CE20 ГОЧА, СТОИЛА «ЗАЛИПШЕЙ КНОПКИ»: nes.v:387 держит joypad_clock ВЕСЬ такт чтения CPU
    // (joypad1_cs && mr_int), а не выдаёт импульс. Сдвиг по ФРОНТУ применялся за ~11 тактов nesclk
    // до того, как процессор защёлкивал шину -> CPU получал УЖЕ СДВИНУТОЕ значение: чтение №1
    // отдавало B вместо A, вся раскладка съезжала на бит, а чтение №8 отдавало вдвинутую 1'b1.
    // Для меню мультикарта это код 0x01 («вправо»), зажатый навсегда -> бесконечное листание страниц.
    // Эталон (NESTang nestang_top.sv:452) сдвигает по СПАДУ, когда чтение уже завершено. Возвращаем
    // эталонное поведение, включая приоритет: при совпадении строба и спада выигрывает сдвиг.
    // CE22: platform order -> NES shift order. Shift register is read LSB first and the NES reads
    // A,B,Select,Start,Up,Down,Left,Right in that order, so sh[0]=A ... sh[7]=Right.
    function [7:0] nes_order;
        input [7:0] u;                        // u = platform order (0=R 1=L 2=D 3=U 4=A 5=B 6=Sel 7=Start)
        nes_order = {u[0], u[1], u[2], u[3], u[7], u[6], u[5], u[4]};
    endfunction
    wire [2:0] joypad_out;  wire [1:0] joypad_clock;
    reg  [7:0] sh1 = 8'hFF, sh2 = 8'hFF;  reg jclk1_d, jclk2_d;
    always @(posedge clk) begin
        jclk1_d <= joypad_clock[0];  jclk2_d <= joypad_clock[1];
        if (joypad_out[0]) begin sh1 <= nes_order(j1_s2); sh2 <= nes_order(j2_s2); end
        if (~joypad_clock[0] & jclk1_d) sh1 <= {1'b1, sh1[7:1]};
        if (~joypad_clock[1] & jclk2_d) sh2 <= {1'b1, sh2[7:1]};
    end
    wire [4:0] joypad1_data = {4'b0000, sh1[0]};
    wire [4:0] joypad2_data = {4'b0000, sh2[0]};

    NES core (
        .clk(clk), .reset_nes(core_reset), .cold_reset(cr_s[1]), .sys_type(sys_type),
        .nes_div(), .mapper_flags(mf_s2),
        .sample(sample), .color(color),
        .joypad_out(joypad_out), .joypad_clock(joypad_clock),
        .joypad1_data(joypad1_data), .joypad2_data(joypad2_data),
        .fds_busy(1'b0), .fds_eject(1'b0), .diskside_req(), .diskside(2'b00),
        .audio_channels(5'b11111),
        .cpumem_addr(cpumem_addr), .cpumem_read(cpumem_read), .cpumem_write(cpumem_write),
        .cpumem_dout(cpumem_dout), .cpumem_din(cpumem_din),
        .ppumem_addr(ppumem_addr), .ppumem_read(ppumem_read), .ppumem_write(ppumem_write),
        .ppumem_dout(ppumem_dout), .ppumem_din(ppumem_din),
        .ppumem_vram_ce(vram_ce_ns), .ppumem_vram_a10(vram_a10_ns),
        .bram_addr(), .bram_din(8'h00), .bram_dout(), .bram_write(), .bram_override(),
        .cycle(cycle), .scanline(scanline),
        .int_audio(1'b1), .ext_audio(1'b0), .apu_ce(apu_ce),
        .gg(1'b0), .gg_code(129'b0), .gg_avail(), .gg_reset(1'b0),
        .emphasis(emphasis), .save_written()
    );
endmodule
