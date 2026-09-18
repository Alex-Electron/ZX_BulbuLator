// tb_intgeo - where the interrupt sits against the raster
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The top border is the only place a program's timing shows raw: it is
// drawn between the interrupt and the first display line, and nothing
// snaps it. Below and beside the raster the OUT stream passes through
// the contended area and comes out aligned, which is why those parts
// are right on the board while the top is not.
//
// So the first thing to establish is whether the interrupt itself sits
// where a 48K puts it. The published figure is 14336 T-states from the
// interrupt to the first paper pixel.
//
// Measured here on the video module alone. The whole-machine testbench
// can report the same number but needs a full 20ms frame to do it,
// which is a hundred times slower than this.

`timescale 1ns / 1ps

module tb_intgeo;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	integer     mval;
	initial if ($value$plusargs("MACHINE=%d", mval)) machine = mval[1:0];
	reg  [11:0] int_adj_arg = 12'd0;
	integer     adjval;
	initial begin
		if ($value$plusargs("INTADJ=%d", adjval)) int_adj_arg = adjval[11:0];
	end

	// 28MHz
	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire nirq;

	video vid (
		.CLK(clk),
		.CLKEN(clken),
		.MEM_CYC(1'b0),
		.nRESET(nreset),
		.VGA(1'b0),
		.MACHINE(machine),
		.CONTENTION(),
		.CONTENTION_IO(),
		.INT_ADJ(int_adj_arg),
		.INT_VADJ(8'd0),
		.CONT_ADJ(5'd0),
		.IO_ADJ(8'd0),
		.BORD_PHASE(4'd9),
		.BORD_DELAY(2'd0), .OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(),
		.PORT_FF_DATA(),
		.VID_A(),
		.VID_D_IN(8'h00),
		.nVID_RD(),
		.nWAIT(),
		.VID_REQ_STEP(),
		.VID_REQ_GEN(),
		.VID_STALE(),
		.VID_REQ_ACK(1'b0),
		.VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0),
		.VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd0),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(),
		.SCANLINE(),
		.nIRQ(nirq)
	);

	// hcounter steps once per CLKEN, four steps to a CPU T-state.
	integer counts = 0;
	reg     counting = 1'b0;
	always @(posedge clk)
		if (clken && counting) counts = counts + 1;

	reg prev_nirq = 1'b1;
	reg prev_pic  = 1'b0;
	reg armed     = 1'b0;
	integer frames = 0;

	initial begin
		nreset = 1'b0;
		repeat (40) @(posedge clk);
		nreset = 1'b1;

		// Skip the first interrupt: the counters come out of reset
		// wherever they come out, and only a whole frame later is the
		// geometry the one a running machine sees.
		@(negedge nirq);
		@(posedge nirq);
		@(negedge nirq);

		counts   = 0;
		counting = 1'b1;
		// vid.picture is hpicture & vpicture - the first paper pixel of
		// the frame is its first rise after the interrupt.
		wait (vid.picture === 1'b1);
		counting = 1'b0;

		$display("INT -> first paper pixel: %0d counts = %0d T-states (a 48K wants 14336)",
			counts, counts / 4);
		$display("  int_line=%0d int_hpos=%0d hline=%0d",
			vid.int_line, vid.int_hpos, vid.hline);
		$display("DONE");
		$finish;
	end

	initial begin
		#400_000_000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
