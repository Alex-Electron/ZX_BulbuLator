//-------------------------------------------------------------------------------------------------
// mem_zx_bulb.v - Memory subsystem for the Atlas ZX Spectrum 128K core on Xilinx Zynq-7010
//-------------------------------------------------------------------------------------------------
// B0131: ЭТО ФОРК ОБЩЕГО research/06-zx-spectrum-128/sources/mem_zx.v (образец - turbosound_bulb.v).
// Имя модуля осталось прежним (mem_zx) НАМЕРЕННО - его инстанцирует топ; поэтому апстримный файл
// ОБЯЗАН быть выкинут из сборки ПО ИМЕНИ: assemble.sh больше не копирует "$S6/mem_zx.v", а
// build.tcl читает mem_zx_bulb.v. Два файла с одним именем модуля = молчаливая подмена, у нас это
// уже оплачено немым SAA1099 (CRITICAL WARNING [Synth 8-9873]). После сборки грепать лог на 8-9873.
//
// Отличие от общего файла ОДНО: регион memA[18:17] == 2'b10 больше не «мёртвый esx», а ОЗУ DivMMC
// 128 КБ (16 страниц по 8 КБ). Оно живёт в ДЫРЕ окна PS DDR: смещения 0x00000..0x1FFFF, которых
// машина не порождает никогда (в DDR у неё уходят только банки 8..63 = 0x20000..0xFFFFF, см. selExt
// ниже). Поэтому ни нового мастера DDR, ни нового CDC - а именно новый CDC стоил нам B0074.
// В BRAM эти 128 КБ не влезают физически: 128 КБ = 32 плитки RAMB36, а свободно 2 из 60 (58 занято).
//-------------------------------------------------------------------------------------------------
// The original Atlas targets stored ROM+RAM in external SDRAM and kept a separate 64KB dual-port
// BRAM (the "Dpr" screen shadow) for the video fetch. Since the whole 128K RAM + 64K ROM fits in
// 7-series Block RAM, this module replaces the SDRAM entirely with on-chip BRAM:
//
//   - ROM  : 64KB = 4 страницы по 16КБ, ЗАПИСЫВАЕМАЯ ARM-ом (B0071), содержимое по умолчанию -
//            "rom128.hex" (пара тостера: страница 0 = 128-меню, страница 1 = 48 BASIC).
//            Каноническая раскладка страниц у нас ОДНА для всех наборов ПЗУ:
//              0 = 128-меню, 1 = 48 BASIC, 2 = TR-DOS, 3 = сервисное/резерв.
//            Порядок страниц В ФАЙЛЕ на карте может быть любым (у пентагоновских BIOS он
//            [сервис, TR-DOS, 128, 48]) - раскладывает по слотам ARM, поэтому фабрика знает
//            только канон. $readmemh ОСТАЁТСЯ: чистая плата обязана подниматься без файлов на
//            карте, иначе первая же ошибка в путях = кирпич. ARM лишь перекрывает содержимое.
//   - RAM  : 128KB, CPU read/write
//   - SCR  : 16KB dual-port screen shadow - port A is written by the CPU whenever it writes the
//            displayed screen (RAM bank 5 or 7, lower 8KB), port B is read by the video fetch.
//            This mirrors exactly how the Atlas board wired the "Dpr" BRAM (zx2/zx.v, atlas.cyc/zx.v):
//                dprW2 = memWr && memA[18:17]==2'b01 && (memA[16:14]==5 || ==7) && !memA[13];
//                dprA1 = {2'b00, vmmA1};  dprA2 = vmmA2;
//
// Address map (from src/memory.v):
//   memA[18:17] == 2'b00 -> ROM region (64KB). memA[15:14] picks 16K bank, memA[13:0] is offset.
//   memA[18:17] == 2'b01 -> 128K RAM, addressed by memA[16:0].
//   memA[18:17] == 2'b10 -> ОЗУ DivMMC (B0131): memA[16:13] страница 0..15, memA[12:0] смещение.
//                           Живёт в PS DDR по смещениям 0x00000..0x1FFFF (см. ниже selEsx).
//
// Why a separate screen shadow instead of dual-porting the 128K RAM:
//   7-series Block RAM is true dual-port (2 ports max). The CPU already needs read+write on the
//   128K RAM (one port pair). The video bus actually issues only ONE read (vmmA1 - the bitmap and
//   attribute bytes are fetched on that single address across the pixel cycle); vmmA2 in the Atlas
//   MMU is not a second video read but the CPU's write target used to keep the screen shadow in
//   sync. Replicating the shadow keeps the CPU and video on independent BRAM ports with no
//   arbitration, exactly like the original board.
//
// Pure Verilog-2001, synchronous registered-read BRAM, infers Xilinx 7-series Block RAM.
// No vendor primitives. Synthesises cleanly in Vivado 2023.1 for xc7z010clg400-1.
//-------------------------------------------------------------------------------------------------
module mem_zx
#(
	// B0071: сколько страниц ПЗУ по 16КБ держим.
	//   2 (ПО УМОЛЧАНИЮ) = поведение до B0071: индекс memA[14:0], старший бит страницы
	//     выбрасывается, 8 плиток BRAM. Так обязаны собираться ВСЕ прочие деревья: этот файл -
	//     общая база, и его копируют себе assemble.sh шагов 07..14, где топ инстанцирует mem_zx
	//     БЕЗ параметра, а страницу ПЗУ считает апстримный memory.v (romPage = {model, 7FFD[4]},
	//     то есть 2/3). Дефолт 4 отправил бы их читать пустые страницы = чёрный экран.
	//   4 = наш Atlas шага 15 (128-меню / 48 BASIC / TR-DOS / сервис, индекс memA[15:0],
	//     16 плиток), запрашивается ЯВНО в bulbulator_zx_ddr_top.v.
	parameter integer ROM_PAGES = 2
)
//-------------------------------------------------------------------------------------------------
(
	input  wire        clock,            // ~56.7 MHz Spectrum master clock (all BRAM clocked here)

	input  wire        memRf,            // CPU refresh   (unused here - DRAM artefact)
	input  wire        memRd,            // CPU read strobe
	input  wire        memWr,            // CPU write strobe
	input  wire [18:0] memA,             // CPU address
	input  wire [ 5:0] ram_bank,         // ПОЛНЫЙ номер банка ОЗУ (Пентагон 1024: 0..63)
	input  wire [ 7:0] memQ,             // CPU write data (from core)
	output reg  [ 7:0] memD,             // read data to core

	// --- расширенные банки (8..63) живут в PS DDR: мастер оболочки, байтовый доступ ---
	output wire [19:0] ddr_addr,         // {банк, смещение} в окне 1 МБ
	output wire [ 7:0] ddr_wdata,
	output wire        ddr_rd,           // однотактовый запрос (один на цикл шины процессора)
	output wire        ddr_wr,
	input  wire [ 7:0] ddr_rdata,

	input  wire        vmmCe,            // video clock enable (pe7M0)
	input  wire [13:0] vmmA1,            // video fetch address (bitmap / attribute)
	input  wire [13:0] vmmA2,            // CPU screen-write target (mirrored into the shadow)
	output wire [ 7:0] vmmD,             // video read data to core

	// --- B0071: порт ЗАПИСИ ПЗУ от ARM (порт B той же BRAM, ТАКТ ARM-а) ---
	// Приём тот же, что у картриджа NES (nes_mem_bram.v): у порта B свой клок, поэтому
	// импульс записи живёт в СВОЁМ домене и потеряться не может - никакого CDC не нужно.
	// Записи разрешены только пока ARM держит rom_ld_we (топ гейтит его по rom_loading, а
	// rom_loading держит процессор в сбросе: иначе Z80 исполнял бы полузаписанное ПЗУ).
	input  wire        rom_ld_clk,       // aclk (fclk100)
	input  wire        rom_ld_we,
	input  wire [15:0] rom_ld_addr,      // {страница[1:0], смещение[13:0]}
	input  wire [ 7:0] rom_ld_data
);
//-------------------------------------------------------------------------------------------------
// Region decode for the CPU read mux.
//-------------------------------------------------------------------------------------------------

wire selRom = (memA[18:17] == 2'b00); // 64KB ROM
wire selRam = (memA[18:17] == 2'b01); // 128KB RAM
// Расширенный банк Пентагона 1024: младшие 8 банков (128 КБ) остаются в BRAM - там вся классика и
// вся демосцена, им нужен цикл-в-цикл и ноль тактов ожидания. Банки 8..63 идут в DDR.
wire selExt = selRam && (ram_bank[5:3] != 3'd0);
// B0131: ОЗУ DivMMC. memA[16:13] - страница (0..15), memA[12:0] - смещение внутри 8 КБ. Страница
// обрезана до 4 бит НА ПОРТУ #E3 (memory.v), поэтому memA[18:17] == 2'b11 не возникает никогда.
wire selEsx = (memA[18:17] == 2'b10);
wire selDdr = selExt | selEsx;
// ДЫРА в окне DDR: 0x00000..0x1FFFF. Занять её безопасно ровно потому, что банки 0..7 машина
// читает из BRAM и в DDR не ходит вовсе - первый её адрес 8*16384 = 0x20000.
assign ddr_addr  = selEsx ? {3'b000, memA[16:13], memA[12:0]}   // ОЗУ DivMMC: 16 x 8 КБ
                          : {ram_bank, memA[13:0]};             // расширенный банк Пентагона
assign ddr_wdata = memQ;
// Один запрос на ОДИН цикл шины процессора. memRd/memWr держатся весь цикл (а под ожиданием -
// и дольше), поэтому запрос выдаётся по ФРОНТУ, иначе мастер получит его десятки раз.
reg extRd_d = 1'b0, extWr_d = 1'b0;
always @(posedge clock) begin
	extRd_d <= selDdr & memRd;
	extWr_d <= selDdr & memWr;
end
assign ddr_rd = selDdr & memRd & ~extRd_d;
assign ddr_wr = selDdr & memWr & ~extWr_d;

//-------------------------------------------------------------------------------------------------
// ROM : 64KB = 4 страницы по 16КБ. Порт A - чтение машиной (spclk), порт B - запись ARM-ом
// (rom_ld_clk = aclk). Настоящая двухпортовая BRAM с двумя тактами, 16 плиток RAMB36.
//
// Индекс = memA[15:0] = {romPage[1:0], a[13:0]} (см. memory.v). ДО B0071 индекс был memA[14:0],
// то есть старший бит romPage выбрасывался и страниц физически было две; romPage тогда был
// прибит к {1'b1, port7FFD[4]}. Теперь romPage = 2 честных бита, а rom128.hex по-прежнему
// ложится в страницы 0 и 1 - поэтому поведение по умолчанию БАЙТ-В-БАЙТ то же:
//   128К, 7FFD[4]=0 -> стр.0 (128-меню)   |   48К -> romPage=2'b01 -> стр.1 (48 BASIC)
//   128К, 7FFD[4]=1 -> стр.1 (48 BASIC)   |   TR-DOS (B0071) -> стр.2
// Страницы 2/3 после конфигурации ПЛИС нулевые, пока ARM не зальёт набор с карты.
//-------------------------------------------------------------------------------------------------

// Ширина индекса СЧИТАЕТСЯ по глубине, а не выбирается тернаркой: с тернаркой любое значение
// кроме 4 (например 8) молча дало бы ROM_AW=15 при большем массиве - половина ПЗУ стала бы
// недостижимой, а заливка от ARM сложила бы старшие страницы поверх младших.
localparam integer ROM_AW = $clog2(ROM_PAGES*16384);   // 4 страницы -> 16 бит, 2 -> 15

reg [7:0] rom [0:(ROM_PAGES*16384)-1];
initial $readmemh("rom128.hex", rom, 0);   // 32768 байт -> страницы 0 и 1 (остальное = 0)

reg [7:0] romQ;
always @(posedge clock)      romQ <= rom[memA[ROM_AW-1:0]];                              // порт A: машина
always @(posedge rom_ld_clk) if (rom_ld_we) rom[rom_ld_addr[ROM_AW-1:0]] <= rom_ld_data;  // порт B: ARM

//-------------------------------------------------------------------------------------------------
// RAM : 128KB, CPU read/write. Single-port (read OR write per access) - the Z80 never reads and
// writes the same cycle. Synchronous registered read. Addressed by memA[16:0].
//-------------------------------------------------------------------------------------------------

reg [7:0] ram [0:131071];

reg [7:0] ramQ;
always @(posedge clock) begin
	if(selRam && !selExt && memWr) ram[memA[16:0]] <= memQ; // CPU write (расширенный банк - не сюда!)
	else                           ramQ            <= ram[memA[16:0]]; // CPU read (registered)
end

//-------------------------------------------------------------------------------------------------
// SCREEN SHADOW : 64KB true dual-port BRAM.
//   Port A (write) : CPU writes to the displayed screen are mirrored here. The Atlas board only
//                    mirrors RAM banks 5 and 7, lower 8KB (the bitmap+attribute area):
//                        memWr && selRam && (memA[16:14]==5 || ==7) && !memA[13]
//                    The write address is vmmA2 (the MMU pre-formed screen offset).
//   Port B (read)  : video fetch at vmmA1, enabled by vmmCe.
//-------------------------------------------------------------------------------------------------

// Сравнение по ВСЕМ шести битам банка: по трём младшим банк 13 или 45 совпал бы с банком 5
// и молча затирал бы зеркало экрана.
wire scrWr = memWr && selRam
           && (ram_bank == 6'd5 || ram_bank == 6'd7)        // displayed banks 5 / 7
           && !memA[13];                                    // lower 8KB (6912-byte screen)

reg [7:0] scr [0:16383];                           // 16KB - vmmA1/vmmA2 are 14-bit (one 16K window)

reg [7:0] scrQ;
always @(posedge clock) begin
	if(scrWr)  scr[vmmA2] <= memQ;                 // mirror CPU write
end
always @(posedge clock) begin
	scrQ <= scr[vmmA1];                 // video read
end

assign vmmD = scrQ;

//-------------------------------------------------------------------------------------------------
// CPU read mux. ROM region -> ROM, RAM region -> RAM, otherwise (esx/unmapped) -> 0xFF.
// The selects are registered alongside the BRAM read so the mux follows the one-cycle read latency.
//-------------------------------------------------------------------------------------------------

reg selRomR, selRamR, selDdrR;
always @(posedge clock) begin
	selRomR <= selRom;
	selRamR <= selRam;
	selDdrR <= selDdr;                    // B0131: и расширенный банк, и ОЗУ DivMMC - оба из DDR
end

always @* begin
	if      (selDdrR) memD = ddr_rdata;   // байт из DDR держится в мастере до следующего запроса
	else if (selRomR) memD = romQ;
	else if (selRamR) memD = ramQ;
	else              memD = 8'hFF;       // регион 2'b11 не порождается (см. selEsx)
end

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
