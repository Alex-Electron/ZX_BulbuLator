//-------------------------------------------------------------------------------------------------
module main
//-------------------------------------------------------------------------------------------------
(
	input  wire       model,  // 0 = 48K, 1 = 128K
	input  wire       pentagon, // 1 = Pentagon: 448x320 raster + NO memory contention (paging stays per `model`)
	input  wire       ula_late, // 1 = requested Sinclair ULA Type 2/Late profile
	input  wire[31:0] ula_tune, // B0053 native-48 sweep: EN/FREEZE/EPOCH/signed IRQ+ULA half-T deltas/INT source
	input  wire       warp_nc,  // 1 = CPU-only warp active: suppress memory contention so the 8x CPU is not stalled by 1x-ULA-timed wait-states (fixes WAV/turbo loads on contended 128K; visual during warp is don't-care)
	input  wire[8:0]  pent_int_v, // Pentium INT line (runtime-tunable)
	input  wire[8:0]  pent_int_h, // Pentium INT start hc (runtime-tunable)
	input  wire[8:0]  paper_h,    // live paper h start (left border)
	input  wire[8:0]  paper_v,    // live paper v start (top border)
	input  wire       mapper, // 0 = off, 1 = on

	input  wire       reset,  // signals
	input  wire       nmi,

	input  wire       clock,  // clock 56 MHz
	input  wire       pe7M0,
	input  wire       ne7M0,
	input  wire       pe3M5,
	input  wire       ne3M5,

	output wire       blank,  // video
	output wire       hsync,
	output wire       vsync,
	output wire       r,
	output wire       g,
	output wire       b,
	output wire       i,

	input  wire       ear,    // audio
	output wire[10:0] laudio,
	output wire[10:0] raudio,
	output wire       midi,

	input  wire       strb,   // keyboard
	input  wire       make,
	input  wire[ 7:0] code,

	input  wire[ 7:0] joy1,   // joystick
	input  wire[ 7:0] joy2,

	output wire       cs,     // uSD
	output wire       ck,
	input  wire       miso,
	output wire       mosi,

	output wire       vmmCe,  // video memory
	output wire[13:0] vmmA1,
	output wire[13:0] vmmA2,
	input  wire[ 7:0] vmmD,

	output wire       memCe,  // cpu memory
	output wire       memRf,
	output wire       memRd,
	output wire       memWr,
	output wire[18:0] memA,
	input  wire[ 7:0] memD,
	output wire[ 7:0] memQ,

	input  wire        dirset,        // ARM control plane: register injection + port overrides
	input  wire[211:0] dir,
	output wire[211:0] reg_out,
	input  wire        force_7ffd,
	input  wire[ 5:0]  port7ffd_in,
	input  wire        force_border,
	input  wire[ 2:0]  border_in,

	output wire        tape_sample,       // 1 during an IN from port 0xFE (loader reading the ear) - drives smart warp
	output wire        tape_sample_strobe,// exact CEN_n phase of an IN-FE; T80 latches DI here
	output wire        tape_di_bit,       // actual bit 6 offered to the CPU on an IN-FE
	output wire        cpu_ten,           // contended CPU T-state enable (pc3M5) - the REAL CPU advance rate; tape/sampling lock to this (128K contention-aware)
	output wire        rom_trap,          // ROM-trap (#65): M1 fetch of LD-BREAK (0x056B) with the 48K loader ROM paged -> Fuse-style instant tape load
	output wire [5:0]  p7ffd_live,        // live 128K paging latch (bit4 = 48K ROM paged) - trap condition + ARM IX->bank map
	output wire [7:0]  map_diag_o,        // passive automapper state (B0048 trace only)
	output wire [26:0] ula_diag_o,        // passive raster/IRQ/contention state (B0048 trace only)
	output wire [31:0] int_dbg0_o,        // B0053 passive interrupt trace, exposed through REG4 while ROMTRAP=0
	output wire [31:0] int_dbg1_o,        // B0053 raster/ack trace, REG5
	output wire [31:0] int_dbg2_o,        // B0053 PC/R/address at interrupt acknowledge, REG6
	// BulbuLator screen-mirror tap (raw ZX screen -> fabric BRAM in the top; read via AXI-GP, off the DDR path)
	output wire [12:0] scr_capA,          // ULA fetch address: bitmap 0x0000..0x17FF + attr 0x1800..0x1AFF (6912 bytes)
	output wire [7:0]  scr_capD,          // fetched screen byte (from the displayed bank -> 128K shadow handled for free)
	output wire        scr_capWe,         // strobe: (scr_capA, scr_capD) valid this cycle (parent gates with ne7M0)
	output wire [2:0]  border_o           // live ULA border colour (parent samples per-scanline for the loading stripes)
);
//-------------------------------------------------------------------------------------------------

reg mreqt23iorqtw3;
always @(posedge clock) if(pc3M5) mreqt23iorqtw3 <= mreq & ioFE;

reg cpuck;
always @(posedge clock) if(ne7M0) cpuck <= !(cpuck && contend);

wire contend = (pentagon | warp_nc) ? 1'b1 : !(vduC && cpuck && mreqt23iorqtw3 && (memC || !ioFE));  // Pentagon: NO contention; warp_nc: suppress it while the CPU-only warp runs 8x (1x-ULA wait-states would misalign and corrupt coarse WAV edges)

wire pc3M5 = pe3M5 & contend;
wire nc3M5 = ne3M5 & contend;

//-------------------------------------------------------------------------------------------------

// Atlas historically re-samples the raw ULA /INT on pc3M5 before presenting it to T80.  Because
// T80 makes its interrupt-acceptance decision on that same master-clock edge, nonblocking semantics
// make the registered path one complete CPU T later than the current raw vduI value.  Keep that
// established path bit-for-bit for Type 1/Early.  For Type 2/Late bypass the resample stage: the
// CPU-visible interrupt is then exactly one T earlier relative to the display/contention phase,
// matching Fuse/Spectrusty late-timing coordinates.  vduI is generated synchronously in this same
// spclk domain; this is a phase selection, not an asynchronous clock-domain crossing.
reg irq = 1'b1;
reg irq_ne = 1'b1;
always @(posedge clock) if(pc3M5) irq <= vduI;
always @(posedge clock) if(nc3M5) irq_ne <= vduI;
wire tune_en = ula_tune[31] && !model && !pentagon;
wire[1:0] int_sel_req = tune_en ? ula_tune[8:7] : (ula_late ? 2'd1 : 2'd0);
wire[1:0] int_sel = int_sel_req == 2'd3 ? 2'd0 : int_sel_req; // reserved source fails safe to legacy
wire cpu_irq = int_sel == 2'd1 ? vduI
             : int_sel == 2'd2 ? irq_ne
             : irq;

wire rfsh;
wire mreq;
wire iorq;
wire m1;
wire rd;
wire wr;

wire[15:0] a;
wire[ 7:0] d;
wire[ 7:0] q;

cpu Cpu
(
	.clock  (clock  ),
	.pe     (pc3M5  ),
	.ne     (nc3M5  ),
	.reset  (reset  ),
	.rfsh   (rfsh   ),
	.mreq   (mreq   ),
	.iorq   (iorq   ),
	.nmi    (nmi    ),
	.irq    (cpu_irq),
	.m1     (m1     ),
	.rd     (rd     ),
	.wr     (wr     ),
	.a      (a      ),
	.d      (d      ),
	.q      (q      ),
	.dirset (dirset ),
	.dir    (dir    ),
	.reg_out(reg_out)
);

//-------------------------------------------------------------------------------------------------

reg mic;
reg speaker;
reg[2:0] border;

always @(posedge clock)
	if(force_border) border <= border_in;                          // ARM override (raw clock)
	else if(pe7M0) if(!ioFE && !wr) { speaker, mic, border } <= q[4:0];

//-------------------------------------------------------------------------------------------------

wire       vduI;
wire       vduC;
wire[12:0] vduA;
wire[8:0]  vdu_dbg_h, vdu_dbg_v;
wire[ 7:0] vduD = vmmD;
wire[ 7:0] vduQ;
wire       vdu_scr_we;                    // BulbuLator: ULA screen-fetch strobe (from video)
assign scr_capA  = vduA;                  // raw ZX screen address (native interleaved layout)
assign scr_capD  = vduD;                  // = vmmD: byte from the displayed bank (shadow-aware)
assign scr_capWe = vdu_scr_we;
assign border_o  = border;                // live ULA border colour (declared below at reg[2:0] border)

video Video
(
	.model  (model  ),
	.pentagon(pentagon),
	.ula_late(ula_late),
	.ula_tune(ula_tune),
	.pent_int_v(pent_int_v),
	.pent_int_h(pent_int_h),
	.paper_h(paper_h),
	.paper_v(paper_v),
	.clock  (clock  ),
	.ce     (ne7M0  ),
	.border (border ),
	.irq    (vduI   ),
	.cn     (vduC   ),
	.a      (vduA   ),
	.d      (vduD   ),
	.q      (vduQ   ),
	.blank  (blank  ),
	.hsync  (hsync  ),
	.vsync  (vsync  ),
	.r      (r      ),
	.g      (g      ),
	.b      (b      ),
	.i      (i      ),
	.scr_we (vdu_scr_we),
	.dbg_h  (vdu_dbg_h),
	.dbg_v  (vdu_dbg_v)
);

//-------------------------------------------------------------------------------------------------

wire[7:0] psgA1;
wire[7:0] psgB1;
wire[7:0] psgC1;

wire[7:0] psgA2;
wire[7:0] psgB2;
wire[7:0] psgC2;

wire[ 7: 0] psgQ;
wire[15:14] psgAh = a[15:14];
wire[ 1: 1] psgAl = a[1];

turbosound Turbosound
(
	.clock  (clock  ),
	.ce     (pe3M5  ),
	.reset  (reset  ),
	.iorq   (iorq   ),
	.wr     (wr     ),
	.rd     (rd     ),
	.d      (q      ),
	.ah     (psgAh  ),
	.al     (psgAl  ),
	.q      (psgQ   ),
	.a1     (psgA1  ),
	.b1     (psgB1  ),
	.c1     (psgC1  ),
	.a2     (psgA2  ),
	.b2     (psgB2  ),
	.c2     (psgC2  ),
	.midi   (midi   )
);

//-------------------------------------------------------------------------------------------------

wire[7:0] spdQ;
wire[7:4] spdA = a[7:4];

specdrum Specdrum
(
	.clock  (clock  ),
	.ce     (pc3M5  ),
	.iorq   (iorq   ),
	.wr     (wr     ),
	.d      (q      ),
	.q      (spdQ   ),
	.a      (spdA   )
);

//-------------------------------------------------------------------------------------------------

reg[3:0] ce8;
wire ce8M0 = !ce8;
always @(negedge clock) if(ce8 == 6) ce8 <= 1'd0; else ce8 <= ce8+1'd1;

wire saaCs = !(!iorq && !wr && a[7:0] == 8'hFF);
wire saaA0 = a[8];

wire[7:0] saaD = q;
wire[7:0] saaL;
wire[7:0] saaR;

saa1099 SAA
(
	.clk_sys(clock  ),
	.ce     (ce8M0  ),
	.rst_n  (reset  ),
	.cs_n   (saaCs  ),
	.wr_n   (saaCs  ),
	.a0     (saaA0  ),
	.din    (saaD   ),
	.out_l  (saaL   ),
	.out_r  (saaR   )
);

//-------------------------------------------------------------------------------------------------

audio Audio
(
	.ear    (ear    ),
	.mic    (mic    ),
	.speaker(speaker),
	.a1     (psgA1  ),
	.b1     (psgB1  ),
	.c1     (psgC1  ),
	.a2     (psgA2  ),
	.b2     (psgB2  ),
	.c2     (psgC2  ),
	.spd    (spdQ   ),
	.saaL   (saaL   ),
	.saaR   (saaR   ),
	.laudio (laudio ),
	.raudio (raudio )
);

//-------------------------------------------------------------------------------------------------

wire memC;
wire [7:0] map_diag;

memory Memory
(
	.model  (model  ),
	.mapper (mapper ),
	.clock  (clock  ),
	.ce     (pc3M5  ),
	.reset  (reset  ),
	.rfsh   (rfsh   ),
	.mreq   (mreq   ),
	.iorq   (iorq   ),
	.rd     (rd     ),
	.wr     (wr     ),
	.m1     (m1     ),
	.a      (a      ),
	.d      (q      ),
	.cn     (memC   ),
	.va     (vduA   ),
	.vmmA1  (vmmA1  ),
	.vmmA2  (vmmA2  ),
	.memRf  (memRf  ),
	.memRd  (memRd  ),
	.memWr  (memWr  ),
	.memA   (memA   ),
	.force_7ffd (force_7ffd ),
	.port7ffd_in(port7ffd_in),
	.port7ffd_o (p7ffd_live ),
	.map_diag   (map_diag)
);

// ROM-trap (#65): fire on the M1 opcode fetch of LD-BREAK (0x056B) - by then LD-BYTES has run DI +
// white border + PUSH 0x053F, so the ARM reads the SHADOW A'/F', fills RAM, sets PC=0x05E2 and lets
// the ROM's own LD-RET do EI/border/return. Gate on the 48K loader ROM being paged (48K: always;
// 128/Pentagon: port7FFD bit4=1). The top edge-detects + halts on an M1 boundary.
assign rom_trap = ~m1 & ~mreq & (a == 16'h056B) & ((~model) | p7ffd_live[4]);   // m1/mreq are M1_n/MREQ_n (active-LOW): opcode fetch = both 0
//-------------------------------------------------------------------------------------------------

wire[7:0] keyA = a[15:8];
wire[4:0] keyQ;

keyboard Keyboard
(
	.clock  (clock  ),
	.ce     (pe7M0  ),
	.strb   (strb   ),
	.make   (make   ),
	.code   (code   ),
	.a      (keyA   ),
	.q      (keyQ   )
);

//-------------------------------------------------------------------------------------------------

wire[7:0] usdQ;
wire[7:0] usdA = a[7:0];

usd uSD
(
	.clock  (clock  ),
	.cep    (pe7M0  ),
	.cen    (ne7M0  ),
	.iorq   (iorq   ),
	.wr     (wr     ),
	.rd     (rd     ),
	.d      (q      ),
	.q      (usdQ   ),
	.a      (usdA   ),
	.cs     (cs     ),
	.ck     (ck     ),
	.miso   (miso   ),
	.mosi   (mosi   )
);

//-------------------------------------------------------------------------------------------------

wire ioDF   = !(!iorq && !a[5]);                   // kempston
wire ioEB   = !(!iorq && a[7:0] == 8'hEB);         // usd
wire ioFE   = !(!iorq && !a[0]);                   // ula
	assign tape_sample = ~ioFE & wr;   // port-FE access that is NOT a write = a READ (loader sampling the ear bit)
	assign tape_sample_strobe = tape_sample & nc3M5; // T80's CEN_n / DI latch phase
	assign tape_di_bit = ear | speaker;              // exact d[6] for the port-FE mux below
	assign cpu_ten = pc3M5;   // = pe3M5 & contend -> on 128K it stalls with the CPU during contention (Pentagon: contend=1, so == pe3M5)
	assign map_diag_o = map_diag;
	assign ula_diag_o = {map_diag, vduA, vduI, vduC, cpuck, contend, cpu_irq, mreqt23iorqtw3};

// B0053 interrupt acceptance observer. The externally visible Z80 interrupt-ack bus cycle
// (!M1_n && !IORQ_n) is used instead of modifying T80. Ages are counted in ne7M0 events, i.e. the
// same 7-MHz half-T unit as the runtime knobs. A settled config/epoch change invalidates and re-arms
// the snapshot; FREEZE retains the first accepted interrupt. Software reads TRACE0/1/2/TRACE0 and
// retries if ACK_SEQ changed, making the three independently synchronized AXI words coherent.
wire int_ack = !m1 && !iorq;
reg int_ack_d = 1'b0, vduI_d = 1'b1, cpu_irq_d = 1'b1;
reg pc3M5_d = 1'b0, nc3M5_d = 1'b0;
reg[6:0] raw_age = 7'h7F, cpu_age = 7'h7F;
reg[7:0] ack_seq = 8'd0, raw_pulse_seq = 8'd0;
reg[31:0] tune_prev = 32'd0;
reg pending = 1'b0, missed_raw_window = 1'b0;
reg raw_fall_seen = 1'b0, selected_fall_seen = 1'b0;
reg trace_valid = 1'b0;
reg[1:0] trace_source = 2'd0;
reg[8:0] trace_irq_delta = 9'd0;
reg[5:0] trace_ula_delta = 6'd0;
reg trace_raw_n = 1'b1, trace_legacy_n = 1'b1, trace_half_n = 1'b1, trace_cpu_n = 1'b1;
reg trace_pc3M5_d = 1'b0, trace_nc3M5_d = 1'b0;
reg trace_raw_seen = 1'b0, trace_selected_seen = 1'b0;
reg[8:0] trace_v = 9'd0, trace_h = 9'd0;
reg[6:0] trace_raw_age = 7'h7F, trace_cpu_age = 7'h7F;
reg[15:0] trace_pc = 16'd0;
reg[7:0] trace_r = 8'd0, trace_raw_seq = 8'd0;
wire trace_frozen = ula_tune[30] && trace_valid;
always @(posedge clock) begin
	int_ack_d <= int_ack;
	vduI_d <= vduI;
	cpu_irq_d <= cpu_irq;
	pc3M5_d <= pc3M5;
	nc3M5_d <= nc3M5;
	if(tune_prev != ula_tune) begin
		tune_prev <= ula_tune;
		trace_valid <= 1'b0;
		pending <= 1'b0;
		missed_raw_window <= 1'b0;
		raw_fall_seen <= 1'b0;
		selected_fall_seen <= 1'b0;
		raw_age <= 7'h7F;
		cpu_age <= 7'h7F;
	end
	else if(!trace_frozen) begin
		if(vduI_d && !vduI) begin
			raw_age <= 7'd0;
			raw_fall_seen <= 1'b1;
			pending <= 1'b1;
			missed_raw_window <= 1'b0;
			raw_pulse_seq <= raw_pulse_seq + 8'd1;
		end
		else if(ne7M0 && raw_fall_seen && raw_age != 7'h7F)
			raw_age <= raw_age + 7'd1;

		if(cpu_irq_d && !cpu_irq) begin
			cpu_age <= 7'd0;
			selected_fall_seen <= 1'b1;
		end
		else if(ne7M0 && selected_fall_seen && cpu_age != 7'h7F)
			cpu_age <= cpu_age + 7'd1;

		if(!vduI_d && vduI && pending) begin
			missed_raw_window <= 1'b1;
			pending <= 1'b0;
		end

		if(tune_en && int_ack && !int_ack_d && pending) begin
			ack_seq <= ack_seq + 8'd1;
			trace_valid <= 1'b1;
			pending <= 1'b0;
			trace_source <= int_sel;
			trace_irq_delta <= ula_tune[23:15];
			trace_ula_delta <= ula_tune[14:9];
			trace_raw_n <= vduI;
			trace_legacy_n <= irq;
			trace_half_n <= irq_ne;
			trace_cpu_n <= cpu_irq;
			trace_pc3M5_d <= pc3M5_d;
			trace_nc3M5_d <= nc3M5_d;
			trace_raw_seen <= raw_fall_seen;
			trace_selected_seen <= selected_fall_seen;
			trace_v <= vdu_dbg_v;
			trace_h <= vdu_dbg_h;
			trace_raw_age <= raw_age;
			trace_cpu_age <= cpu_age;
			trace_pc <= reg_out[79:64];
			trace_r <= reg_out[47:40];
			trace_raw_seq <= raw_pulse_seq;
		end
	end
end
assign int_dbg0_o = {ack_seq, trace_valid, missed_raw_window, trace_source,
                     trace_irq_delta, trace_ula_delta,
                     trace_raw_n, trace_legacy_n, trace_half_n, trace_cpu_n,
                     trace_raw_seen};
assign int_dbg1_o = {trace_v, trace_h, trace_raw_age, trace_cpu_age};
assign int_dbg2_o = {trace_pc, trace_r, trace_raw_seq};
wire ioFFFD = !(!iorq && a[15] && a[14] && !a[1]); // psg

assign d
	= !mreq ? memD
	: !ioDF ? joy1|joy2
	: !ioEB ? usdQ
	: !ioFE ? { 1'b1, ear|speaker, 1'b1, keyQ }
	: !ioFFFD ? psgQ
	: pentagon ? 8'hFF                             // Pentagon has NO floating bus: unmapped IN = 0xFF (MiSTer: mZX ? ff_data : 8'hFF)
	: vduQ;                                        // Sinclair floating bus (video fetch byte)

//-------------------------------------------------------------------------------------------------

assign vmmCe = pe7M0;
assign memCe = pc3M5;
assign memQ = q;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
