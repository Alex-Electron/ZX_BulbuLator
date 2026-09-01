// nes_mem_bram.v - Round-1 BRAM cartridge memory for the NESTang NES core (NROM-class), TRUE DUAL-PORT.
//
// Port A (clk = nesclk): the running core reads/writes cpumem (PRG+WRAM) and ppumem (CHR/CHR-RAM).
// Port B (ld_clk = aclk): the ARM streams the parsed .nes PRG/CHR bytes in WHILE THE CORE IS RESET.
// Two independent clocks + one write path per port -> clean true-dual-port BRAM inference, and the
// ARM's aclk-domain ld_we strobe writes in ITS OWN clock domain (no aclk->nesclk pulse CDC that a
// single-clock design would lose). Load happens with the core in reset (loading=1), so ports never
// touch the same address at once. BRAM read is registered (1 clk) - inside the core's prefetch window.
//
// Sizes: PRG 64 KB (NROM 32K + $6000 WRAM headroom), CHR 8 KB. Round-2 -> DDR for big carts.

module nes_mem_bram #(
    parameter integer PRG_AW = 16,
    parameter integer CHR_AW = 13
)(
    input  wire        clk,          // nesclk - core port
    input  wire        ld_clk,       // aclk   - ARM load port
    input  wire        loading,      // 1 = ARM streaming (core held in reset)

    // ---- core CPU/PRG port (nesclk) ----
    input  wire [21:0] cpumem_addr,
    input  wire        cpumem_read,
    input  wire        cpumem_write,
    input  wire [7:0]  cpumem_dout,
    output wire [7:0]  cpumem_din,

    // ---- core PPU/CHR port (nesclk) ----
    input  wire [21:0] ppumem_addr,
    input  wire        ppumem_read,
    input  wire        ppumem_write,
    input  wire [7:0]  ppumem_dout,
    output wire [7:0]  ppumem_din,
    input  wire        ppu_vram_ce,   // 1 = console nametable (CIRAM) access, 0 = cart CHR pattern
    input  wire        ppu_vram_a10,  // CIRAM A10 (nametable mirroring)

    // ---- ARM load port (ld_clk / aclk) ----
    input  wire        ld_we,
    input  wire        ld_sel,       // 0 = PRG, 1 = CHR
    input  wire [21:0] ld_addr,
    input  wire [7:0]  ld_data,
    output reg  [31:0] dbg          // bring-up: {vram_ce_access_cnt[31:16], ciram_write_cnt[15:0]}
);
    initial dbg = 32'd0;
    (* ram_style = "block" *) reg [7:0] prg [0:(1<<PRG_AW)-1];
    (* ram_style = "block" *) reg [7:0] cpuram [0:2047];   // console-internal 2KB CPU RAM ($0000-$07FF): zero-page + stack
    (* ram_style = "block" *) reg [7:0] chr [0:(1<<CHR_AW)-1];
    (* ram_style = "block" *) reg [7:0] ciram [0:2047];   // 2KB console nametable RAM (CIRAM), selected by vram_ce

    // ---- CPU bus: console 2KB RAM ($0000-$07FF) vs cart PRG/WRAM ----
    // nes.v:525 tags internal CPU RAM with cpumem_addr[21]=1 (low bits [10:0]=RAM offset); cart PRG has bit21=0.
    // WITHOUT a dedicated cpuram, zero-page/stack writes aliased into prg[] and CORRUPTED the game code -> the
    // 6502 had no working stack/zero-page and hung at boot (that was the black-screen root cause). Route them here.
    // Separate registered reads + delayed select (like CIRAM) -> clean RAM inference, 1-clk latency preserved.
    wire       cpu_is_ram = cpumem_addr[21];
    reg  [7:0] prg_q, cram_q;  reg cpu_is_ram_d;
    always @(posedge clk) begin
        if (!loading && cpumem_write) begin
            if (cpu_is_ram) cpuram[cpumem_addr[10:0]]    <= cpumem_dout;                   // internal RAM: keep OFF prg[]
            else begin      prg[cpumem_addr[PRG_AW-1:0]] <= cpumem_dout; dbg[2] <= 1'b1; end // cart PRG/WRAM write (sticky)
        end
        prg_q        <= prg[cpumem_addr[PRG_AW-1:0]];
        cram_q       <= cpuram[cpumem_addr[10:0]];
        cpu_is_ram_d <= cpu_is_ram;
    end
    assign cpumem_din = cpu_is_ram_d ? cram_q : prg_q;
    always @(posedge ld_clk) if (ld_we && !ld_sel) prg[ld_addr[PRG_AW-1:0]] <= ld_data;

    // ---- PPU bus: cart CHR ($0000-$1FFF) vs 2KB CIRAM nametable ($2000-$2FFF, mirrored) ----
    // The NESTang mapper drops the pattern/nametable bit from the linear address and flags a CIRAM
    // access ONLY via vram_ce (a10 = mirroring). Route nametable reads/writes to the dedicated CIRAM
    // so they don't alias into / corrupt the cart CHR pattern tables (that was the black-background bug).
    // Registered read = 1-clk latency (same as before); vram_ce sampled at issue so din matches address.
    // Separate registered reads for chr (BRAM) and ciram, muxed on a DELAYED select -> both infer as
    // clean RAMs. (The earlier muxed-read-before-register hit "Unable to infer RAMs" AND broke the CHR
    // read: sprites went black. This pattern keeps the 1-clk latency and both memories functional.)
    wire [10:0] ci_addr = {ppu_vram_a10, ppumem_addr[9:0]};
    reg  [7:0]  chr_q, ci_q;  reg vce_d;
    always @(posedge clk) begin
        if (!loading && ppumem_write) begin
            if (ppu_vram_ce) begin ciram[ci_addr] <= ppumem_dout; dbg[1] <= 1'b1; dbg[31:16] <= dbg[31:16] + 16'd1; end  // nametable write (sticky+count)
            else             chr[ppumem_addr[CHR_AW-1:0]] <= ppumem_dout;   // cart CHR-RAM write only
        end
        if (ppu_vram_ce) dbg[0] <= 1'b1;   // sticky: vram_ce ever asserted (PPU accessed nametable)
        chr_q <= chr[ppumem_addr[CHR_AW-1:0]];
        ci_q  <= ciram[ci_addr];
        vce_d <= ppu_vram_ce;   // delay select to match the 1-clk registered read
    end
    assign ppumem_din = vce_d ? ci_q : chr_q;
    always @(posedge ld_clk) if (ld_we && ld_sel) chr[ld_addr[CHR_AW-1:0]] <= ld_data;
endmodule
