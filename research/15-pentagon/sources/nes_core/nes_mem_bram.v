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
    output reg  [7:0]  cpumem_din,

    // ---- core PPU/CHR port (nesclk) ----
    input  wire [21:0] ppumem_addr,
    input  wire        ppumem_read,
    input  wire        ppumem_write,
    input  wire [7:0]  ppumem_dout,
    output reg  [7:0]  ppumem_din,

    // ---- ARM load port (ld_clk / aclk) ----
    input  wire        ld_we,
    input  wire        ld_sel,       // 0 = PRG, 1 = CHR
    input  wire [21:0] ld_addr,
    input  wire [7:0]  ld_data
);
    (* ram_style = "block" *) reg [7:0] prg [0:(1<<PRG_AW)-1];
    (* ram_style = "block" *) reg [7:0] chr [0:(1<<CHR_AW)-1];

    // ---- PRG: port A = core (nesclk), port B = ARM load (aclk) ----
    always @(posedge clk) begin
        if (!loading && cpumem_write) prg[cpumem_addr[PRG_AW-1:0]] <= cpumem_dout;
        cpumem_din <= prg[cpumem_addr[PRG_AW-1:0]];
    end
    always @(posedge ld_clk) if (ld_we && !ld_sel) prg[ld_addr[PRG_AW-1:0]] <= ld_data;

    // ---- CHR (CHR-RAM writable): port A = core (nesclk), port B = ARM load (aclk) ----
    always @(posedge clk) begin
        if (!loading && ppumem_write) chr[ppumem_addr[CHR_AW-1:0]] <= ppumem_dout;
        ppumem_din <= chr[ppumem_addr[CHR_AW-1:0]];
    end
    always @(posedge ld_clk) if (ld_we && ld_sel) chr[ld_addr[CHR_AW-1:0]] <= ld_data;
endmodule
