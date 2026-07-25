//-------------------------------------------------------------------------------------------------
module memory
//-------------------------------------------------------------------------------------------------
(
	input  wire       model,
	input  wire       mapper,

	input  wire       clock,
	input  wire       ce,

	input  wire       reset,
	input  wire       rfsh,
	input  wire       mreq,
	input  wire       iorq,
	input  wire       rd,
	input  wire       wr,
	input  wire       m1,
	input  wire[15:0] a,
	input  wire[ 7:0] d,

	output wire       cn,
	input  wire[12:0] va,

	output wire[13:0] vmmA1,
	output wire[13:0] vmmA2,

	output wire       memRf,
	output wire       memRd,
	output wire       memWr,
	output wire[18:0] memA,
	input  wire       force_7ffd,    // ARM override of the 128K paging port
	input  wire[ 5:0] port7ffd_in,
	output wire[ 5:0] port7ffd_o,    // LIVE 7FFD (bit4=1 -> 48K ROM paged) - for the ROM-trap condition + IX->bank map
	output wire[ 7:0] map_diag       // passive automapper state for the tape timing trace
);
assign port7ffd_o = port7FFD;
//-------------------------------------------------------------------------------------------------
//-------------------------------------------------------------------------------------------------

reg mapOnIORQ;
reg[5:0] mapOnIORQData;

reg[5:0] port7FFD;
always @(posedge clock, negedge reset)
if(!reset) begin
	port7FFD <= 1'd0;
	mapOnIORQ <= 1'b0;
end
else if(force_7ffd && model) begin  // ARM 7FFD override ONLY in 128K. In 48K there is no paging; a stray
	port7FFD  <= port7ffd_in;        // force (ctl_port_commit fires it together with force_border when the OSD
	mapOnIORQ <= 1'b0;               // sets the border) must never leak stale 128K paging into the flat 48K model.
end
else if(ce) begin
	if(!iorq && !wr && !a[15] && !a[1] && model && !port7FFD[5]) begin
		mapOnIORQ <= 1'b1;
		mapOnIORQData <= d[5:0];
	end
	if(mapOnIORQ) begin
		port7FFD <= mapOnIORQData;
		mapOnIORQ <= 1'b0;
	end
end
/*
reg[5:0] port7FFD;
always @(posedge clock, negedge reset)
	if(!reset) port7FFD <= 1'd0; else
	if(ce) if(!iorq && !a[15] && !a[1] && !wr && model && !port7FFD[5]) port7FFD <= d[5:0];
*/
wire      vmmPage = model & port7FFD[3];
// The board-side mem_zx keeps the two toastrack ROMs as a 32K pair and indexes them with
// memA[14:0]. In 128K mode, page 2/3 therefore selects 128-0/128-1 as before. The flat 48K
// model must explicitly select page 1 (128-1 = the original 48 BASIC ROM); page 0 is the
// 128K editor/menu and was the cause of the B004A black/corrupt 48K cold boot.
wire[1:0] romPage = model ? { 1'b1, port7FFD[4] } : 2'b01;
// v0x4A 48K fix: map the 48K top region (0xC000) to BANK 0, matching the 128K post-boot default
// (7FFD=0) and - critically - the ARM control plane: load_sna/tier0/romtrap_ix_flat all write the
// 0xC000 image into bank 0 by the 128K convention. The old {a[15:14],1'b0}=bank 6 mapping made every
// injected 48K program land in memory the machine never reads (black screen); no real-48K behavior
// depends on WHICH physical bank backs the flat RAM, so bank 0 is free compatibility.
wire[2:0] ramPage = a[15:14] == 2'b01 ? 3'd5 : a[15:14] == 2'b10 ? 3'd2 : model ? port7FFD[2:0] : 3'd0;

//-------------------------------------------------------------------------------------------------

reg mapForce;
reg mapAuto;
reg mapOnM1;
reg mapRam;
reg[4:0] mapPage;
assign map_diag = {mapForce, mapAuto, mapOnM1, mapRam, mapPage[3:0]};

always @(posedge clock) // if(ce)
if(!reset) begin
	mapForce <= 1'b0;
	mapAuto <= 1'b0;
	mapOnM1 <= 1'b0;
	mapPage <= 1'd0;
	mapRam <= 1'b0;
end
else begin
	if(!iorq && !wr && a[7:0] == 8'hE3) begin
		mapForce <= d[7];
		mapPage <= d[4:0];
		mapRam <= d[6]|mapRam;
	end
	if(!mreq && !m1) begin
		if(a == 16'h0000 || a == 16'h0008 || a == 16'h0038 || a == 16'h0066 || a == 16'h04C6 || a == 16'h0562)
			mapOnM1 <= 1'b1; // activate automapper after this cycle

		else if(a[15:3] == 13'h3FF)
			mapOnM1 <= 1'b0; // deactivate automapper after this cycle

		else if(a[15:8] == 8'h3D) begin
			mapOnM1 <= 1'b1; // activate automapper immediately
			mapAuto <= 1'b1;
		end
	end
	if(m1) mapAuto <= mapOnM1;
end

wire map = mapForce || (mapAuto && mapper);
wire[4:0] page = !a[13] && mapRam ? 5'd3 : mapPage;

//-------------------------------------------------------------------------------------------------

wire addr01 = !a[15] &&  a[14];
wire addr11 =  a[15] &&  a[14];

assign cn = addr01 || (model && addr11 && ramPage[0]);

`ifdef NO_SNOW
assign vmmA1 = { vmmPage, va[12:7], va[6:0] };                            // ULA snow OFF (clean variant: always raster fetch)
`else
assign vmmA1 = { vmmPage, va[12:7], !rfsh && addr01 ? a[6:0] : va[6:0] }; // ULA snow ON (faithful 128 hardware, default)
`endif
assign vmmA2 = { model & ramPage[1], a[12:0] };

assign memRf = !mreq && !rfsh;
assign memRd = !mreq && !rd;
assign memWr = !mreq && !wr && (a[15] || a[14] || (map && (a[13] || mapRam)));
assign memA
	= a[15:14] == 2'b00 && !map                     ? { 2'b00, 1'b0, romPage, a[13:0] }
	: a[15:14] == 2'b00 && map && !a[13] && !mapRam ? { 2'b00, 1'b0,  3'b010, a[12:0] }
	: a[15] || a[14]                                ? { 2'b01,       ramPage, a[13:0] }
	:                                                 { 1'b1,           page, a[12:0] };

//-------------------------------------------------------------------------------------------------
//            MEM  //             ROM
// 18:17 16:0      // 15:14 13:0     
//  0  0 128K rom  //  0  0  16K  48K
//  0  1 128K ram  //  0  1  16K  esx
//  1  0 128K esx  //  1  0  16K   +2
//  1  1 128K ---  //  1  1  16K   +2

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
