//-------------------------------------------------------------------------------------------------
module video
//-------------------------------------------------------------------------------------------------
(
	input  wire       model,
	input  wire       pentagon, // 1 = Pentagon raster (448x320; sources: MiSTer ula.sv / ZX-Uno / Speccy2010)
	input  wire       ula_late, // 1 = Sinclair Type 2/Late: raster/contention 1T later relative to CPU-facing /INT
	input  wire[31:0] ula_tune, // B0053 native-48 sweep: EN[31], FREEZE[30], EPOCH[29:24], IRQ_D9[23:15], ULA_D6[14:9], SRC[8:7]
	input  wire[8:0]  pent_int_v, // Pentium INT line (runtime-tunable; reference default 239)
	input  wire[8:0]  pent_int_h, // Pentium INT start hc (runtime-tunable; reference default 326)
	input  wire[8:0]  paper_h,    // live from ARM: h start of paper (left border offset)
	input  wire[8:0]  paper_v,    // live from ARM: v start of paper (top border offset)

	input  wire       clock,
	input  wire       ce,

	input  wire[ 2:0] border,
	output wire       irq,
	output wire       cn,
	output reg [12:0] a,
	input  wire[ 7:0] d,
	output reg [ 7:0] q,

	output wire       blank,
	output wire       hsync,
	output wire       vsync,
	output wire       r,
	output wire       g,
	output wire       b,
	output wire       i,
	output wire       scr_we,  // BulbuLator screen-mirror tap: 1 on the cycle a fetched bitmap/attr byte (d) is valid for address a
	output wire[8:0]  dbg_h,
	output wire[8:0]  dbg_v
);
//-------------------------------------------------------------------------------------------------

// Pentagon: 448 clk/line (224 T, like 48K) x 320 lines = 71680 T/frame; INT on line 239 late in the
// line (hc 326..397, 36 T) - constants cross-checked against MiSTer ula.sv, ZX-Uno pal_sync_generator
// and Speccy2010 (all agree). 128K keeps 456x311, 48K keeps 448x312.
wire[8:0] hCountEnd = pentagon ? 9'd448 : (model ? 9'd456 : 9'd448);
wire[8:0] vCountEnd = pentagon ? 9'd320 : (model ? 9'd311 : 9'd312);

wire tune_en = ula_tune[31] && !model && !pentagon;
wire[8:0] irqLine = pentagon ? pent_int_v : 9'd248;                     // Pentagon INT position is runtime-TUNABLE
// Raw /INT remains the frame-counter reference. main.v can select the historical Atlas pc3M5
// re-sampling stage, raw /INT, or the opposite-half sample for diagnostics. The original timing
// detector spins JP (HL) in uncontended RAM between consecutive frame interrupts and samples loop
// count/R/stop address in its IM2 handler. B0053 hardware proved that translating every frame's
// /INT together (up to -256 half-T) changes the ACK PC but does NOT change its Type-1 verdict:
// absolute IRQ position cancels over the frame-to-frame measurement. Therefore this tuner maps T80
// acceptance buckets only; it is not a valid implementation of a Type-1/Type-2 machine option.
// Keep pulse width independent of phase and use modular membership so negative deltas that wrap to
// the end of the preceding line remain valid. Normal widths are unchanged: 48K=64, 128K=72 and
// Pentagon=72 7-MHz ticks.
wire signed [9:0] tune_irq_sum = 10'sd2 + {ula_tune[23],ula_tune[23:15]};
wire[8:0] tune_irq_beg = tune_irq_sum[9]
                       ? tune_irq_sum + 10'sd448
                       : tune_irq_sum[8:0];
wire[8:0] irqBeg   = pentagon ? pent_int_h : (tune_en ? tune_irq_beg : (model ? 9'd6 : 9'd2));
wire[8:0] irqWidth = pentagon ? 9'd72 : (model ? 9'd72 : 9'd64);
// A negative delta from native h=2 belongs to the PREVIOUS raster line. The IRQ pulse can then
// continue through h=0 of irqLine. Track the start line explicitly; an h-only modular comparator
// would incorrectly start such a pulse at h=0 of line 248 and collapse all deltas below -2.
wire[8:0] irqStartLine = (tune_en && tune_irq_sum[9])
                       ? (irqLine - 9'd1)
                       : irqLine;

// Pentagon paper window shift for correct wider border and logo position (to match reference boot screen).
// Now live from ARM menu (PAPER H/V OFF). Default 64/24 gives wider real-Pentagon look + correct logo height.
wire[8:0] h_paper_start = pentagon ? paper_h : 9'd0;
wire[8:0] v_paper_start = pentagon ? paper_v : 9'd0;

//-------------------------------------------------------------------------------------------------

reg[8:0] hc, hCount;
wire hCountReset = hc >= (hCountEnd-1);
always @(posedge clock) if(hCountReset) hCount <= 1'd0; else hCount <= hc+1'd1;
always @(posedge clock) if(ce) hc <= hCount;

reg[8:0] vc, vCount;
wire vCountReset = vc >= (vCountEnd-1);
always @(posedge clock) begin vCount <= vc; if(hCountReset) if(vCountReset) vCount <= 1'd0; else vCount <= vc+1'd1; end
always @(posedge clock) if(ce) vc <= vCount;

// Sinclair Type 2/Late ULA phase. hCount is a 7 MHz coordinate, hence two counts are exactly one
// 3.5 MHz CPU T-state. B0053 can sweep this delay from JTAG on native 48K without another synthesis.
// Use a wrapped raster coordinate delayed by the selected count for EVERY ULA event,
// while the physical frame counter and /INT above remain fixed.  At hCount 0/1 the delayed beam is
// still on the previous raster line, so vUla must wrap too.  Pentagon has no Ferranti ULA Early/Late
// variation and the top-level suppresses ula_late for that machine.
// Signed ULA phase: +2 preserves B004D "Late" semantics (events occur one CPU T later);
// a negative value advances the ULA coordinate and carries into the next raster line.
wire       tune_ula_negative = tune_en && ula_tune[14];
wire[5:0] tune_ula_magnitude = ula_tune[14]
                             ? (~ula_tune[14:9] + 6'd1)
                             : ula_tune[14:9];
wire[8:0] ulaShift = tune_en ? {3'd0,tune_ula_magnitude} : (ula_late ? 9'd2 : 9'd0);
wire[9:0] hUlaAdvance = {1'b0,hCount} + {1'b0,ulaShift};
wire      ulaAdvanceWrap = tune_ula_negative && (hUlaAdvance >= {1'b0,hCountEnd});
wire      ulaDelayWrap = !tune_ula_negative && (ulaShift != 0) && (hCount < ulaShift);
wire[8:0] hUla = tune_ula_negative
               ? (ulaAdvanceWrap ? (hUlaAdvance - {1'b0,hCountEnd}) : hUlaAdvance[8:0])
               : ((ulaShift != 0)
                  ? ((hCount >= ulaShift) ? (hCount - ulaShift) : (hCount + hCountEnd - ulaShift))
                  : hCount);
wire[8:0] vUla = ulaAdvanceWrap
               ? ((vCount >= (vCountEnd - 9'd1)) ? 9'd0 : (vCount + 9'd1))
               : (ulaDelayWrap
                  ? ((vCount == 9'd0) ? (vCountEnd - 9'd1) : (vCount - 9'd1))
                  : vCount);

reg[4:0] fc, fCount;
always @(posedge clock) begin fCount <= fc; if(hCountReset) if(vCountReset) fCount <= fc+1'd1; end
always @(posedge clock) if(ce) fc <= fCount;

//-------------------------------------------------------------------------------------------------

reg dataEnable;
wire de = (hUla >= h_paper_start) && (hUla < h_paper_start + 256) &&
          (vUla >= v_paper_start) && (vUla < v_paper_start + 192);
always @(posedge clock) if(ce) dataEnable <= de;

reg videoEnable;
wire videoEnableLoad = hUla[3];
always @(posedge clock) if(ce) if(videoEnableLoad) videoEnable <= dataEnable;

//-------------------------------------------------------------------------------------------------

wire [8:0] h_addr = hUla - h_paper_start;
wire [8:0] v_addr = vUla - v_paper_start;

reg[7:0] dataInput;
wire dataInputLoad = (h_addr[3:0] ==  9 || h_addr[3:0] == 13) && dataEnable;
always @(posedge clock) if(ce) if(dataInputLoad) dataInput <= d;

reg[7:0] attrInput;
wire attrInputLoad = (h_addr[3:0] == 11 || h_addr[3:0] == 15) && dataEnable;
always @(posedge clock) if(ce) if(attrInputLoad) attrInput <= d;

// BulbuLator screen-mirror tap: at dataInputLoad `a` holds the bitmap address + `d` the bitmap byte;
// at attrInputLoad `a` holds the attribute address (0x1800+) + `d` the attr byte. The parent samples
// (a,d) on this strobe (gated by ce) into a 6912-byte fabric mirror = the raw ZX screen "as it lands".
assign scr_we = dataInputLoad | attrInputLoad;

reg[7:0] dataOutput;
wire dataOutputLoad = h_addr[2:0] == 4 && videoEnable;
always @(posedge clock) if(ce) if(dataOutputLoad) dataOutput <= dataInput; else dataOutput <= { dataOutput[6:0], 1'b0 };

reg[7:0] attrOutput;
wire attrOutputLoad = h_addr[2:0] == 4;
always @(posedge clock) if(ce) if(attrOutputLoad) attrOutput <= { videoEnable ? attrInput[7:3] : { 2'b00, border }, attrInput[2:0] };

wire addrLoad = dataEnable && h_addr[3] && !h_addr[0];
always @(posedge clock) if(ce) if(addrLoad) a <= { !h_addr[1] ? { v_addr[7:6], v_addr[2:0] } : { 3'b110, v_addr[7:6] }, v_addr[5:3], h_addr[7:4], h_addr[2] };

wire fbLoad = dataEnable && h_addr[3] && h_addr[0];
wire fbReset = h_addr[3:0] == 1;
always @(posedge clock) if(ce) if(fbLoad) q <= d; else if(fbReset) q <= 8'hFF;

//-------------------------------------------------------------------------------------------------

wire hBlank = pentagon ? (hUla >= 320 && hUla < 384)   // Pentagon: 64-clk hblank (ZX-Uno: 320..383) -> 384 visible px = the WIDER real-Pentagon side border
                       : (hUla >= 320 && hUla < 416);  // Sinclair: 96-clk (proven)
wire vBlank = pentagon ? (vUla >= 296 && vUla < 304) : (vUla >= 248 && vUla < 256);  // Pentagon vblank around vsync for small top border

wire dataSelect = dataOutput[7] ^ (fCount[4] & attrOutput[7]);

//-------------------------------------------------------------------------------------------------

wire[9:0] irqStopSum = {1'b0,irqBeg} + {1'b0,irqWidth};
wire      irqWrap = irqStopSum >= {1'b0,hCountEnd};
wire[8:0] irqStopH = irqWrap ? (irqStopSum - {1'b0,hCountEnd}) : irqStopSum[8:0];
wire[8:0] irqNextLine = irqStartLine >= (vCountEnd - 9'd1) ? 9'd0 : (irqStartLine + 9'd1);
wire      irqActive = irqWrap
                    ? ((vCount == irqStartLine && hCount >= irqBeg) ||
                       (vCount == irqNextLine && hCount < irqStopH))
                    : (vCount == irqStartLine && hCount >= irqBeg && hCount < irqStopH);
assign irq = !irqActive;
assign cn = dataEnable && (hUla[3] || hUla[2]);

assign blank = hBlank | vBlank;
assign hsync = pentagon ? (hUla >= 320 && hUla < 352) : (hUla >= 344 && hUla < 376);  // Pentagon hsync at 320..351 (ZX-Uno)
assign vsync = pentagon ? (vUla >= 300 && vUla < 304) : (vUla >= 248 && vUla < 252);  // move vsync later for small top border after vsync -> logo higher in frame like reference

assign r = dataSelect ? attrOutput[1] : attrOutput[4];
assign g = dataSelect ? attrOutput[2] : attrOutput[5];
assign b = dataSelect ? attrOutput[0] : attrOutput[3];
assign i = attrOutput[6];
assign dbg_h = hCount;
assign dbg_v = vCount;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
