//-------------------------------------------------------------------------------------------------
// mem_zx.v - Memory subsystem for the Atlas ZX Spectrum 128K core on Xilinx Zynq-7010
//-------------------------------------------------------------------------------------------------
// The original Atlas targets stored ROM+RAM in external SDRAM and kept a separate 64KB dual-port
// BRAM (the "Dpr" screen shadow) for the video fetch. Since the whole 128K RAM + 64K ROM fits in
// 7-series Block RAM, this module replaces the SDRAM entirely with on-chip BRAM:
//
//   - ROM  : 32KB, read-only, initialised from "rom128.hex" (the +2 ROM pair: ROM0 128 menu +
//            ROM1 48 BASIC). 128K-only build, so the 48K/esx banks are never reached - holding
//            just these 32KB saves 8 BRAM tiles, which the framebuffer needs on the xc7z010.
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
//   memA[18:17] == 2'b10 -> DivMMC esx RAM (ignored - we run with the mapper disabled).
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
//-------------------------------------------------------------------------------------------------
(
	input  wire        clock,            // ~56.7 MHz Spectrum master clock (all BRAM clocked here)

	input  wire        memRf,            // CPU refresh   (unused here - DRAM artefact)
	input  wire        memRd,            // CPU read strobe
	input  wire        memWr,            // CPU write strobe
	input  wire [18:0] memA,             // CPU address
	input  wire [ 7:0] memQ,             // CPU write data (from core)
	output reg  [ 7:0] memD,             // read data to core

	input  wire        vmmCe,            // video clock enable (pe7M0)
	input  wire [13:0] vmmA1,            // video fetch address (bitmap / attribute)
	input  wire [13:0] vmmA2,            // CPU screen-write target (mirrored into the shadow)
	output wire [ 7:0] vmmD              // video read data to core
);
//-------------------------------------------------------------------------------------------------
// Region decode for the CPU read mux.
//-------------------------------------------------------------------------------------------------

wire selRom = (memA[18:17] == 2'b00); // 64KB ROM
wire selRam = (memA[18:17] == 2'b01); // 128KB RAM

//-------------------------------------------------------------------------------------------------
// ROM : 32KB (+2 ROM pair), read-only, initialised from rom128.hex. Synchronous registered read.
// In the 128K-only build memory.v drives memA[15:14] = romPage = {model=1, port7FFD[4]}, so
// memA[15] is always 1 and memA[14] = port[4] selects ROM0 (128 menu, reset value) or ROM1
// (48 BASIC). rom128.hex holds bank2 then bank3, so memA[14:0] indexes it directly.
//-------------------------------------------------------------------------------------------------

reg [7:0] rom [0:32767];
initial $readmemh("rom128.hex", rom, 0);

reg [7:0] romQ;
always @(posedge clock) romQ <= rom[memA[14:0]];

//-------------------------------------------------------------------------------------------------
// RAM : 128KB, CPU read/write. Single-port (read OR write per access) - the Z80 never reads and
// writes the same cycle. Synchronous registered read. Addressed by memA[16:0].
//-------------------------------------------------------------------------------------------------

reg [7:0] ram [0:131071];

reg [7:0] ramQ;
always @(posedge clock) begin
	if(selRam && memWr) ram[memA[16:0]] <= memQ; // CPU write
	else                ramQ            <= ram[memA[16:0]]; // CPU read (registered)
end

//-------------------------------------------------------------------------------------------------
// SCREEN SHADOW : 64KB true dual-port BRAM.
//   Port A (write) : CPU writes to the displayed screen are mirrored here. The Atlas board only
//                    mirrors RAM banks 5 and 7, lower 8KB (the bitmap+attribute area):
//                        memWr && selRam && (memA[16:14]==5 || ==7) && !memA[13]
//                    The write address is vmmA2 (the MMU pre-formed screen offset).
//   Port B (read)  : video fetch at vmmA1, enabled by vmmCe.
//-------------------------------------------------------------------------------------------------

wire scrWr = memWr && selRam
           && (memA[16:14] == 3'd5 || memA[16:14] == 3'd7) // displayed banks 5 / 7
           && !memA[13];                                    // lower 8KB (6912-byte screen)

reg [7:0] scr [0:16383];                           // 16KB - vmmA1/vmmA2 are 14-bit (one 16K window)

reg [7:0] scrQ;
always @(posedge clock) begin
	if(scrWr)  scr[vmmA2] <= memQ;                 // mirror CPU write
end
always @(posedge clock) begin
	if(vmmCe)  scrQ <= scr[vmmA1];                 // video read
end

assign vmmD = scrQ;

//-------------------------------------------------------------------------------------------------
// CPU read mux. ROM region -> ROM, RAM region -> RAM, otherwise (esx/unmapped) -> 0xFF.
// The selects are registered alongside the BRAM read so the mux follows the one-cycle read latency.
//-------------------------------------------------------------------------------------------------

reg selRomR, selRamR;
always @(posedge clock) begin
	selRomR <= selRom;
	selRamR <= selRam;
end

always @* begin
	if      (selRomR) memD = romQ;
	else if (selRamR) memD = ramQ;
	else              memD = 8'hFF;
end

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
