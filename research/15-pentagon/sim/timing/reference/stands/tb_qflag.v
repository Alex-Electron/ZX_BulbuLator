// tb_qflag - what SCF and CCF do to the undocumented XF and YF flags
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// A Z80 type tester names the manufacturer from exactly this. Zilog
// takes both bits from (Q ^ F) | A - so after an instruction that did
// not write the flags they are OR-ed with what is already there, and
// after one that did they come from A alone. A core that always takes
// them from A reads as a NEC clone.
//
// Two cases, both entered through POP AF, which counts as writing no
// flags:
//
//   A: F = $28 (both bits set), A = $00   Zilog keeps them   -> $29
//   B: F = $00, A = $28 (both bits set)   Zilog sets them    -> $29
//
// A core taking them from A alone gives $01 for the first and $29 for
// the second, which is how the difference shows.

`timescale 1ns / 1ps

module tb_qflag;

	reg clk = 1'b0;
	always #10 clk = ~clk;
	reg nreset = 1'b0;

	wire [15:0] a;
	wire  [7:0] dout;
	reg   [7:0] din;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n;

	T80se cpu (
		.RESET_n(nreset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(1'b1),
		.INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(),
		.A(a), .DI(din), .DO(dout), .MC(), .TS()
	);

	reg [7:0] mem [0:255];
	always @* din = mem[a[7:0]];
	// The stack lives in this memory too, so it has to be writable -
	// without this PUSH did nothing and POP read zeros.
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0)
			mem[a[7:0]] <= dout;

	// Two results, written to ports $01 and $02.
	reg [7:0] res_a = 8'hxx, res_b = 8'hxx;
	always @(posedge clk)
		if (nreset && iorq_n == 1'b0 && wr_n == 1'b0) begin
			if (a[7:0] == 8'h01) res_a <= dout;
			if (a[7:0] == 8'h02) res_b <= dout;
		end

	integer n = 0;
	reg m1_d = 1'b1;
	always @(posedge clk) if (nreset) begin
		if (m1_d == 1'b1 && m1_n == 1'b0 && n < 30) begin
			n = n + 1;
			$display("   fetch %0d at $%04h = $%02h", n, a, mem[a[7:0]]);
		end
		m1_d <= m1_n;
	end

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		i = 0;
		mem[i]=8'hF3; i=i+1;                          // DI
		mem[i]=8'h31; i=i+1; mem[i]=8'hF0; i=i+1; mem[i]=8'h00; i=i+1; // LD SP,$00F0
		// case A: F = $28, A = $00
		mem[i]=8'h21; i=i+1; mem[i]=8'h28; i=i+1; mem[i]=8'h00; i=i+1; // LD HL,$0028
		mem[i]=8'hE5; i=i+1;                          // PUSH HL
		mem[i]=8'hF1; i=i+1;                          // POP AF
		mem[i]=8'h37; i=i+1;                          // SCF
		mem[i]=8'hF5; i=i+1;                          // PUSH AF
		mem[i]=8'hC1; i=i+1;                          // POP BC   (C = F)
		mem[i]=8'h79; i=i+1;                          // LD A,C
		mem[i]=8'hD3; i=i+1; mem[i]=8'h01; i=i+1;     // OUT ($01),A
		// case B: F = $00, A = $28
		mem[i]=8'h21; i=i+1; mem[i]=8'h00; i=i+1; mem[i]=8'h28; i=i+1; // LD HL,$2800
		mem[i]=8'hE5; i=i+1;                          // PUSH HL
		mem[i]=8'hF1; i=i+1;                          // POP AF
		mem[i]=8'h37; i=i+1;                          // SCF
		mem[i]=8'hF5; i=i+1;                          // PUSH AF
		mem[i]=8'hC1; i=i+1;                          // POP BC
		mem[i]=8'h79; i=i+1;                          // LD A,C
		mem[i]=8'hD3; i=i+1; mem[i]=8'h02; i=i+1;     // OUT ($02),A
		mem[i]=8'h76;                                 // HALT

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
		#40000;
		$display("");
		$display("  case A  F=$28 A=$00 then SCF : got $%02h", res_a);
		$display("  case B  F=$00 A=$28 then SCF : got $%02h", res_b);
		$display("  Zilog wants $29 in both. Bits from A alone give $01 and $29.");
		$display("  %s", (res_a == 8'h29 && res_b == 8'h29) ?
			"ZILOG - both bits come from (Q ^ F) | A" :
			"NOT Zilog");
		$finish;
	end
endmodule
