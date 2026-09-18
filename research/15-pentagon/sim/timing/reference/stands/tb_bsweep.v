// tb_bsweep - border latch delay of ep4spectrum's video.v, swept over all
// sixteen hcounter phases inside an 8-pixel group.
//
// Companion to Sergey Potapov's tb_border.v, which measures one phase only
// (the one the counters happen to be at 4000 clocks after reset). Here
// BORDER_IN is stepped exactly when hcounter[3:0] == P (on the CLKEN edge
// that makes the counter show P), for P = 0..15, and two things are
// counted until border_out shows the new value:
//   counts  - CLKEN ticks (hcounter steps, 4 per CPU T-state, 2 per pixel)
//   pixels  - CLKEN ticks with hcounter[0]==1 (pixel-rate edges, the same
//             edges the border_d1..d3 chain shifts on)
// Plusargs: MACHINE=0..3, BDELAY=0..3 (BORD_DELAY port), BPHASE=0..15
// (BORD_PHASE port; the board uses 9).
// Same clocking as tb_border.v: 28 MHz CLK, CLKEN every other edge.

`timescale 1ns / 1ps

module tb_bsweep;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	reg  [1:0]  bdelay = 2'd0;
	reg  [3:0]  bphase = 4'd9;
	reg  [2:0]  border_in = 3'd0;
	integer     v;
	initial begin
		if ($value$plusargs("MACHINE=%d", v)) machine = v[1:0];
		if ($value$plusargs("BDELAY=%d", v))  bdelay  = v[1:0];
		if ($value$plusargs("BPHASE=%d", v))  bphase  = v[3:0];
	end

	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire [3:0] r, g, b;

	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(bphase), .BORD_DELAY(bdelay),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(border_in),
		.R(r), .G(g), .B(b),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(), .nIRQ()
	);

	integer counts = 0, pix = 0;
	reg     counting = 1'b0;
	always @(posedge clk) if (clken && counting) begin
		counts = counts + 1;
		if (vid.hcounter[0] == 1'b1) pix = pix + 1;
	end

	integer p;
	reg [2:0] val;
	integer minc, maxc, minp, maxp;
	integer h0;

	initial begin
		nreset = 1'b0;
		repeat (20) @(posedge clk);
		nreset = 1'b1;
		val = 3'd0;
		minc = 9999; maxc = -1; minp = 9999; maxp = -1;
		$display("MACHINE %0d BORD_DELAY %0d BORD_PHASE %0d (border_update phase %s)",
			machine, bdelay, bphase,
			(machine == 2'd3) ? "every pixel (hcounter[0]==1), delay forced to 3" : "hcounter[3:0]==BORD_PHASE");
		$display("  phase = hcounter[3:0] shown when BORDER_IN changed (inside lines 100.., visible part)");
		$display("  phase  counts(=hcounter steps)  pixels  hcounter_at_change");
		for (p = 0; p < 16; p = p + 1) begin
			// somewhere in the visible part of a display line, well inside the picture
			wait (vid.vcounter[9:1] == 9'd100 + p);
			wait (vid.hcounter == 10'd192);
			// step to the wanted phase: change BORDER_IN right after the CLKEN
			// edge on which hcounter became 192+p (so the latch sees it from
			// the next CLKEN edge, like a CPU write landing in that count)
			wait (vid.hcounter == 10'd192 + p);
			h0 = vid.hcounter;
			val = val + 3'd1;
			counts = 0; pix = 0;
			counting = 1'b1;
			border_in = val;
			wait (vid.border_out == val);
			counting = 1'b0;
			$display("  %2d     %3d   %3d   %0d", h0 % 16, counts, pix, h0);
			if (counts < minc) minc = counts;
			if (counts > maxc) maxc = counts;
			if (pix < minp) minp = pix;
			if (pix > maxp) maxp = pix;
		end
		$display("  range: counts %0d..%0d, pixels %0d..%0d", minc, maxc, minp, maxp);
		$display("DONE");
		$finish;
	end

	initial begin
		#60_000_000;
		$display("TIMED OUT");
		$finish;
	end
endmodule
