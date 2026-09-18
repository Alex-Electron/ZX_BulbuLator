// tb_intack - what an interrupt costs to accept, in each of the four
// ways a program can be waiting for it
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The board says the top border is right for one demo and eight pixels
// right for two others, with everything beside and below the raster
// correct in all three. Beside the raster IO contention snaps the OUT
// stream and hides any error; above it nothing does, so the top border
// shows the raw interrupt-to-OUT phase. Eight pixels is four T-states,
// and the only thing that can differ by four T-states between two
// programs taking the same interrupt is what they were doing when it
// arrived, and in which interrupt mode.
//
// A real Z80:
//   IM1 = 13 T-states to accept, IM2 = 19, and being halted changes
//   neither - HALT executes internal NOPs and the acceptance that ends
//   one is the same acceptance that ends any other 4-T instruction.
//
// So the four numbers below must come out as two pairs, and the pairs
// must be six apart. Anything else is the bug.
//
// No ULA, no SDRAM, no contention: this measures the core alone, with
// WAIT_n tied high, so nothing outside T80 can be blamed for the
// answer.

`timescale 1ns / 1ps

module tb_intack;

	reg         clk = 1'b0;
	reg         reset_n = 1'b0;
	reg         int_n = 1'b1;

	wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
	wire [15:0] a;
	wire [7:0]  d_out;
	reg  [7:0]  d_in;

	always #10 clk = ~clk;

	T80se #(.T2Write(1)) cpu (
		.RESET_n(reset_n),
		.CLK_n(clk),
		.CLKEN(1'b1),
		.WAIT_n(1'b1),
		.INT_n(int_n),
		.NMI_n(1'b1),
		.BUSRQ_n(1'b1),
		.M1_n(m1_n),
		.MREQ_n(mreq_n),
		.IORQ_n(iorq_n),
		.RD_n(rd_n),
		.WR_n(wr_n),
		.RFSH_n(rfsh_n),
		.HALT_n(halt_n),
		.BUSAK_n(busak_n),
		.A(a),
		.DI(d_in),
		.DO(d_out),
		.MC(),
		.TS(),
		.IO_CYC()
	);

	// Flat 64K, read combinationally. Writes are accepted so the
	// acceptance PUSH has somewhere to go.
	reg [7:0] mem [0:65535];
	always @* d_in = mem[a];
	always @(posedge clk)
		if (mreq_n == 1'b0 && wr_n == 1'b0)
			mem[a] <= d_out;

	// T-states, counted from the clock INT_n goes low.
	integer tcount = 0;
	reg     counting = 1'b0;
	always @(posedge clk)
		if (counting) tcount = tcount + 1;

	// The handler's first instruction is OUT ($FE),A. IORQ with WR is
	// the moment the ULA would latch the border, so that is the moment
	// worth timing - not the handler's first fetch, which is a T-state
	// or two earlier depending on how the core sequences the write.
	wire io_write = (iorq_n == 1'b0) && (wr_n == 1'b0);

	integer k;
	integer result [0:3];

	task build;
		input im2;      // 1 = IM 2, 0 = IM 1
		input halted;   // 1 = wait in HALT, 0 = wait on a slide of NOPs
		begin
			for (k = 0; k < 65536; k = k + 1) mem[k] = 8'h00;

			// DI / LD SP,$C000 / LD A,$81 / LD I,A
			mem[16'h0000] = 8'hF3;
			mem[16'h0001] = 8'h31; mem[16'h0002] = 8'h00; mem[16'h0003] = 8'hC0;
			mem[16'h0004] = 8'h3E; mem[16'h0005] = 8'h81;
			mem[16'h0006] = 8'hED; mem[16'h0007] = 8'h47;
			// IM 2 / IM 1
			mem[16'h0008] = 8'hED;
			mem[16'h0009] = im2 ? 8'h5E : 8'h56;
			// EI
			mem[16'h000A] = 8'hFB;
			// Then either HALT, or a slide of NOPs - both 4 T-states a
			// turn, both sampling the interrupt line at the same rate.
			// A real Z80 accepts on the same grid either way.
			if (halted)
				mem[16'h000B] = 8'h76;
			// (the slide is the zero fill, which is NOP)

			// IM2 vector table: 257 bytes of $81 at $8100, so the vector
			// read gives $8181.
			for (k = 16'h8100; k <= 16'h8201; k = k + 1) mem[k] = 8'h81;

			// Handlers. First instruction is the border write in both.
			mem[16'h0038] = 8'hD3; mem[16'h0039] = 8'hFE;   // IM1
			mem[16'h8181] = 8'hD3; mem[16'h8182] = 8'hFE;   // IM2
		end
	endtask

	task measure;
		input integer slot;
		input im2;
		input halted;
		begin
			build(im2, halted);
			reset_n  = 1'b0;
			int_n    = 1'b1;
			counting = 1'b0;
			tcount   = 0;
			repeat (8) @(posedge clk);
			reset_n = 1'b1;

			// Let it reach the idle - past EI, and for the HALT case
			// past the HALT itself.
			repeat (200) @(posedge clk);

			@(posedge clk);
			counting = 1'b1;
			int_n    = 1'b0;

			// Hold it well past acceptance, as the ULA does.
			fork
				begin
					repeat (64) @(posedge clk);
					int_n = 1'b1;
				end
				begin
					@(posedge io_write);
					counting = 1'b0;
					result[slot] = tcount;
				end
			join
			$display("  %s, %s: %0d T-states from INT to the border write",
				im2 ? "IM 2" : "IM 1",
				halted ? "halted    " : "on a slide",
				result[slot]);
		end
	endtask

	initial begin
		$display("INT ACCEPTANCE");
		measure(0, 1'b0, 1'b0);
		measure(1, 1'b0, 1'b1);
		measure(2, 1'b1, 1'b0);
		measure(3, 1'b1, 1'b1);
		$display("");
		$display("  IM1 halted - IM1 on a slide = %0d (a real Z80: 0, allowing the 4-T grid)",
			result[1] - result[0]);
		$display("  IM2 halted - IM2 on a slide = %0d (a real Z80: 0, allowing the 4-T grid)",
			result[3] - result[2]);
		$display("  IM2 - IM1, on a slide       = %0d (a real Z80: 6)",
			result[2] - result[0]);
		$display("  IM2 - IM1, halted           = %0d (a real Z80: 6)",
			result[3] - result[1]);
		$display("DONE");
		$finish;
	end

	initial begin
		#2_000_000;
		$display("TIMED OUT - no border write seen");
		$finish;
	end

endmodule
