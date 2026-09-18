// tb_border - how many pixels does the border chain actually delay by
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Trimming the border delay on the board twice produced no visible
// change at all, which the code says is impossible: border_out is
// literally what the red, green and blue outputs are made of outside
// the raster, and moving the tap removes register stages from the path.
// Either the delay is not what it reads as, or the change is not
// reaching the screen. This measures it directly instead of arguing.
//
// The measurement: hold the border at one value, step it to another,
// and record how many pixel times pass before border_out follows.
// Done for each machine, so the per-machine tap is measured rather
// than assumed.

`timescale 1ns / 1ps

module tb_border;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	reg  [2:0]  border_in = 3'd0;

	wire [3:0]  r, g, b;

	// 28MHz
	always #17.857 clk = ~clk;

	// CLKEN is the 14MHz video enable: every other master clock.
	always @(posedge clk) clken <= ~clken;

	video vid (
		.CLK(clk),
		.CLKEN(clken),
		.MEM_CYC(1'b0),
		.nRESET(nreset),
		.VGA(1'b0),
		.MACHINE(machine),
		.CONTENTION(),
		.CONTENTION_IO(),
		.INT_ADJ(12'd0),
		.BORD_PHASE(4'd9),
		.BORD_DELAY(2'd0), .OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.INT_VADJ(8'd0),
		.CONT_ADJ(5'd0),
		.IO_ADJ(8'd0),
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
		.BORDER_IN(border_in),
		.R(r), .G(g), .B(b),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(),
		.SCANLINE(),
		.nIRQ()
	);

	// A pixel is two counts of hcounter, so count the enabled edges
	// where hcounter[0] is high - the same tick the chain shifts on.
	integer pix = 0;
	reg     counting = 1'b0;
	always @(posedge clk) begin
		if (clken && vid.hcounter[0] == 1'b1 && counting)
			pix = pix + 1;
	end

	task measure;
		input [1:0] m;
		begin
			machine   = m;
			nreset    = 1'b0;
			border_in = 3'd0;
			repeat (20) @(posedge clk);
			nreset = 1'b1;
			// Let the counters settle somewhere inside a line, well
			// away from blanking, so border_out is actually driving
			// something.
			repeat (4000) @(posedge clk);

			pix = 0;
			counting = 1'b1;
			border_in = 3'd7;
			wait (vid.border_out == 3'd7);
			counting = 1'b0;
			$display("MACHINE %0d: border_out follows after %0d pixel ticks",
				m, pix);
		end
	endtask

	initial begin
		measure(2'd0);   // 48K
		measure(2'd3);   // Pentagon
		measure(2'd1);   // 128K
		$display("Done.");
		$finish;
	end

	// Never let it run away if border_out somehow never follows.
	initial begin
		#500_000;
		$display("TIMED OUT - border_out never followed BORDER_IN");
		$finish;
	end

endmodule
