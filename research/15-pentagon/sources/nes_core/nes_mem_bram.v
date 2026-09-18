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
    // v165/CE18: 64К -> 128К. Contra (USA) = mapper 2 (в ядре это Mapper28, RTL уже вкомпилен),
    // PRG 128К, CHR-RAM 8К. Стоимость: 16 -> 32 плитки RAMB36, итого ~36.5 из 60 (61%), LUT +0.
    // ЗАКЛАДКА НА БУДУЩЕЕ: WRAM у MMC1/MMC3 помечается prg_linaddr[21:18]==4'b1111, но nes.v:525
    // отбрасывает бит 21 ({1'b0, prg_linaddr[20:0]}) -> при AW=17 адрес WRAM усечётся в 0 и запись
    // в $6000-$7FFF затрёт нулевой банк PRG. Для mapper 2 записи в ROM-окно запрещены (prg_allow),
    // поэтому Contra безопасна; ПЕРЕД первой MMC1/MMC3-игрой с сейвами нужен отдельный 8К WRAM.
    parameter integer PRG_AW = 17,
    // v165/CE19: CHR 8К -> 32К (+6 плиток RAMB36). Открывает CNROM (переключение графики) и
    // значительную часть MMC3. Загрузчик соответственно поднял гард CHR до 32К.
    parameter integer CHR_AW = 15
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
    // v165/CE19: ОТДЕЛЬНОЕ окно WRAM 8К ($6000-$7FFF, батарейные сейвы MMC1/MMC3).
    // Мина, которую это снимает: cart.sv кладёт WRAM в окно 0x3C0000, но nes.v:525 отдаёт нам только
    // prg_linaddr[20:0] (бит 21 занят нашим же флагом внутренней ОЗУ консоли), поэтому окно приходит как
    // 0x1C0000 и при PRG_AW=17 усекалось в 0x00000 -> любая запись сейва затирала НУЛЕВОЙ БАНК PRG, то есть
    // код игры. Настоящий PRG при 128К занимает лишь 0x00000-0x1FFFF, поэтому окно однозначно опознаётся
    // по битам [20:18]==111 и разводится здесь - БЕЗ правки вендоренного nes.v.
    // (Для будущего DDR-тира с картриджем >512К этот признак перестанет быть уникальным - тогда WRAM
    //  надо будет выносить отдельным сигналом из ядра.)
    (* ram_style = "block" *) reg [7:0] wram [0:8191];

    // ---- CPU bus: console 2KB RAM ($0000-$07FF) vs cart PRG/WRAM ----
    // nes.v:525 tags internal CPU RAM with cpumem_addr[21]=1 (low bits [10:0]=RAM offset); cart PRG has bit21=0.
    // WITHOUT a dedicated cpuram, zero-page/stack writes aliased into prg[] and CORRUPTED the game code -> the
    // 6502 had no working stack/zero-page and hung at boot (that was the black-screen root cause). Route them here.
    // Separate registered reads + delayed select (like CIRAM) -> clean RAM inference, 1-clk latency preserved.
    wire       cpu_is_ram  = cpumem_addr[21];
    wire       cpu_is_wram = (cpumem_addr[20:18] == 3'b111);   // CE19: свёрнутое окно 0x3C0000 -> 0x1C0000
    reg  [7:0] prg_q, cram_q, wram_q;  reg cpu_is_ram_d, cpu_is_wram_d;
    always @(posedge clk) begin
        if (!loading && cpumem_write) begin
            if      (cpu_is_ram)  cpuram[cpumem_addr[10:0]] <= cpumem_dout;                // internal RAM: keep OFF prg[]
            else if (cpu_is_wram) wram[cpumem_addr[12:0]]   <= cpumem_dout;                // CE19: сейвы, НЕ в prg[]
            else begin            prg[cpumem_addr[PRG_AW-1:0]] <= cpumem_dout; dbg[2] <= 1'b1; end // cart PRG write (sticky = тревога)
        end
        // v165/CE12: same latch-and-hold contract the PPU port got in CE11. The 6502 core also runs on
        // ce-divided phases, so its sample edge is several nesclk ticks after the request, while upstream
        // sdram_nes.v holds doutA until the next request. Reading every nesclk from the live address is
        // the same race that scrambled the PPU fetches; games ran, but a stale/neighbouring byte reaching
        // the CPU is how rare hangs in other cartridges would look. cpumem_read was also unconnected.
        if (cpumem_read) begin
            prg_q         <= prg[cpumem_addr[PRG_AW-1:0]];
            cram_q        <= cpuram[cpumem_addr[10:0]];
            wram_q        <= wram[cpumem_addr[12:0]];
            cpu_is_ram_d  <= cpu_is_ram;
            cpu_is_wram_d <= cpu_is_wram;
        end
    end
    assign cpumem_din = cpu_is_ram_d ? cram_q : (cpu_is_wram_d ? wram_q : prg_q);
    always @(posedge ld_clk) if (ld_we && !ld_sel) prg[ld_addr[PRG_AW-1:0]] <= ld_data;

    // ---- PPU bus: cart CHR ($0000-$1FFF) vs 2KB CIRAM nametable ($2000-$2FFF, mirrored) ----
    // The NESTang mapper drops the pattern/nametable bit from the linear address and flags a CIRAM
    // access ONLY via vram_ce (a10 = mirroring). Route nametable reads/writes to the dedicated CIRAM
    // so they don't alias into / corrupt the cart CHR pattern tables (that was the black-background bug).
    // Registered read = 1-clk latency (same as before); vram_ce sampled at issue so din matches address.
    // Separate registered reads for chr (BRAM) and ciram, muxed on a DELAYED select -> both infer as
    // clean RAMs. (The earlier muxed-read-before-register hit "Unable to infer RAMs" AND broke the CHR
    // read: sprites went black. This pattern keeps the 1-clk latency and both memories functional.)
    // v164/CE10: select CIRAM by the ADDRESS WINDOW the cart itself encodes (cart.sv:1899 maps every
    // nametable access to 0x300000|{vram_a10,addr[9:0]}, i.e. addr[21:20]==2'b11 and addr[10]==a10) -
    // the upstream SDRAM contract. Single-source select (no separately exported vram_ce/a10 wires ->
    // no possible skew against the address). The exported ppu_vram_* inputs stay as ports (unused).
    wire        ci_sel  = (ppumem_addr[21:20] == 2'b11);
    wire [10:0] ci_addr = ppumem_addr[10:0];
    reg  [7:0]  chr_q, ci_q;  reg vce_d;
    always @(posedge clk) begin
        if (!loading && ppumem_write) begin
            if (ci_sel) begin ciram[ci_addr] <= ppumem_dout; dbg[1] <= 1'b1; dbg[31:16] <= dbg[31:16] + 16'd1; end  // nametable write (sticky+count)
            else        chr[ppumem_addr[CHR_AW-1:0]] <= ppumem_dout;   // cart CHR-RAM write only
        end
        if (ci_sel) dbg[0] <= 1'b1;   // sticky: nametable window accessed
        // v165/CE11: LATCH ON REQUEST, HOLD UNTIL THE NEXT ONE - the upstream sdram_nes.v contract.
        // ppu.v runs as `always @(posedge clk) if (ce)`, so ONE PPU cycle spans several nesclk ticks, and
        // its contract is "one cycle after vram_r was asserted, the value is available on the bus" - one
        // PPU cycle, not one nesclk. Upstream's SDRAM latches the byte at the request and HOLDS doutA/doutB
        // until the next request, so it is still valid when the PPU samples. We instead re-registered the
        // read EVERY nesclk from the LIVE address (ppumem_read was not even connected), so by the sampling
        // edge the bus had moved on to the next fetch and the PPU took a neighbouring byte. Which fetches
        // were lost depended on the ce-vs-nesclk phase and on routing: partly correct picture, stable
        // within a run but a DIFFERENT scramble per build (CE0F vs CE10 differed in 16.7% of the frame,
        // each stable to 0.2% over seconds), tiles wrong coherently down all 8 rows of a tile, sprites hit
        // harder (their fetches sit in HBlank beside different bus neighbours).
        // Gating with ppumem_read is just the block-RAM read enable, so RAM inference is preserved.
        if (ppumem_read) begin        // capture ONLY on a request...
            chr_q <= chr[ppumem_addr[CHR_AW-1:0]];
            ci_q  <= ciram[ci_addr];
            vce_d <= ci_sel;
        end                           // ...and HOLD between requests (upstream doutA/doutB semantics)
    end
    assign ppumem_din = vce_d ? ci_q : chr_q;
    always @(posedge ld_clk) if (ld_we && ld_sel) chr[ld_addr[CHR_AW-1:0]] <= ld_data;
endmodule
