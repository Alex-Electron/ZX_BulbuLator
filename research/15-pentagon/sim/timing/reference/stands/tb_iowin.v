// tb_iowin - the shape of the contention window, printed out
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The board says the border beside and below the raster does not just
// sit in the wrong place, it SPREADS - the first edge out by a little
// and the next by more. A window in the wrong place cannot do that: it
// would move every write by the same amount. A window of the wrong
// shape can, because each write in a run meets the pattern at a
// different point and is charged a different number of T-states.
//
// So the thing to look at is the pattern itself, per CPU T-state,
// across one display line. A 48K charges 6,5,4,3,2,1,0,0 repeating over
// 128 of the 224 T-states, and nothing outside that.
//
// Printed rather than checked: the published figure is the delay in
// T-states per slot, while what this module carries is a per-T-state
// hold, so the two are the same fact in different units and the
// comparison is better made by eye than by an assertion that bakes in
// one reading of it.

`timescale 1ns / 1ps

module tb_iowin;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	integer     mval;
	initial if ($value$plusargs("MACHINE=%d", mval)) machine = mval[1:0];
	reg  [7:0]  io_adj = 8'd0;

	integer     adjval;
	initial if ($value$plusargs("IOADJ=%d", adjval)) io_adj = adjval[7:0];

	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire cont_mem, cont_io;

	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(cont_mem), .CONTENTION_IO(cont_io),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(io_adj),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0), .OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd0),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(), .nIRQ()
	);

	// One CPU T-state is four hcounter counts. Sample each window once a
	// T-state, on the same count every time, so the string below is one
	// character per T-state of the line.
	reg [8:0] memrow [0:255];
	reg [8:0] iorow  [0:255];
	integer   t;
	integer   i;
	integer   memtot, iotot;
	wire [8:0] nts = (machine == 2'd1 || machine == 2'd2) ? 9'd228 : 9'd224;

	initial begin
		nreset = 1'b0;
		repeat (40) @(posedge clk);
		nreset = 1'b1;

		// First: which lines have any contention at all - the vertical
		// edge is where a one-time loss at the top border would live.
		begin : vscan
			integer ln, seen, firstln, lastln;
			firstln = -1; lastln = -1;
			for (ln = 0; ln < 311; ln = ln + 1) begin
				wait (vid.vcounter[9:1] == ln[8:0]);
				seen = 0;
				while (vid.vcounter[9:1] == ln[8:0]) begin
					@(posedge clk);
					if (cont_mem) seen = seen + 1;
				end
				if (seen != 0) begin
					if (firstln < 0) firstln = ln;
					lastln = ln;
				end
			end
			$display("contention on lines %0d..%0d", firstln, lastln);
		end

		// Somewhere well inside the display area.
		wait (vid.vcounter[9:1] == 9'd100);
		wait (vid.hcounter == 10'd0);

		for (t = 0; t < nts; t = t + 1) begin
			// One T-state is four CLKEN ticks, eight posedges of the
			// 28MHz clock. Sample once per T-state, exactly.
			repeat (8) @(posedge clk);
			memrow[t] = cont_mem;
			iorow[t]  = cont_io;
		end

		memtot = 0; iotot = 0;
		for (i = 0; i < nts; i = i + 1) begin
			memtot = memtot + memrow[i];
			iotot  = iotot  + iorow[i];
		end

		$write("MEM window, one char per T-state of a display line:\n  ");
		for (i = 0; i < nts; i = i + 1) $write("%s", memrow[i] ? "#" : ".");
		$write("\n  held for %0d of %0d T-states\n", memtot, nts);

		$write("IO  window:\n  ");
		for (i = 0; i < nts; i = i + 1) $write("%s", iorow[i] ? "#" : ".");
		$write("\n  held for %0d of %0d T-states\n", iotot, nts);

		memtot = -1; iotot = -1;
		for (i = nts - 1; i >= 0; i = i - 1) begin
			if (memrow[i]) memtot = i;
			if (iorow[i])  iotot  = i;
		end
		$display("first MEM T-state %0d, first IO T-state %0d, IO leads by %0d",
			memtot, iotot, memtot - iotot);
		$display("DONE");
		$finish;
	end


	initial begin
		#40_000_000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
