// tb_bpix - положение полосы бордюра относительно первого видимого пикселя бумаги в video.v
// ep4spectrum (Потапов), при записи в порт на заданном такте процессора после приёма /INT.
//
// Процессора в стенде нет: его сетка воспроизведена по clocks.v платы. `counter` там идёт по
// negedge, CLKEN_VID регистрируется из counter[0]==1, CLKEN_CPU (SPEED=0) из counter[2:0]==6, то
// есть фронт процессора лежит между двумя шагами hcounter, на счёте hcounter[1:0]==3 (сброс обоих
// счётчиков общий). В стенде: CLKEN чередуется каждый posedge, «фронт процессора» = posedge с
// CLKEN=0 и hcounter[1:0]==CPUPH (умолчание 3; аргумент CPUPH позволяет проверить чувствительность).
//   E1  - первый фронт процессора, на котором nIRQ уже низкий (T80 защёлкивает INT_s на CEN).
//   N   - номер фронта процессора после E1 (E1 = 0), на котором T80se (T2Write=1) выставляет
//         IORQ_n/WR_n; они видны со следующего posedge, ula_port регистрирует BORDER_OUT ещё через
//         posedge -> BORDER_IN видео меняется через 2 posedge после фронта N.
//   Печатается: где виден новый цвет на выходе R/G/B (регистры 28 МГц): строка, hcounter, px =
//   hcounter>>1; и где на строке 0 бумага (attr=0, чёрная) сменяет белый бордюр: px_paper.
// Один N на кадр: N = N0, N0+1, ... (NN кадров). MACHINE 0/1/2/3 как в video.v.
`timescale 1ns / 1ps
module tb_bpix;
	reg clk = 1'b0, clken = 1'b0, nreset = 1'b0;
	reg [1:0] machine = 2'd0;
	reg [2:0] border_in = 3'd7;
	integer v, cpuph = 3, n0 = 14330, nn = 14, bphase = 9, bdelay = 0;
	initial begin
		if ($value$plusargs("MACHINE=%d", v)) machine = v[1:0];
		if ($value$plusargs("CPUPH=%d", v)) cpuph = v;
		if ($value$plusargs("N0=%d", v)) n0 = v;
		if ($value$plusargs("NN=%d", v)) nn = v;
		if ($value$plusargs("BPHASE=%d", v)) bphase = v;
		if ($value$plusargs("BDELAY=%d", v)) bdelay = v;
	end
	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;
	wire [3:0] r, g, b; wire nirq;
	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(bphase[3:0]), .BORD_DELAY(bdelay[1:0]),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(border_in),
		.R(r), .G(g), .B(b),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(), .nIRQ(nirq)
	);
	wire [2:0] rgb = {r[3], g[3], b[3]};
	reg [2:0] rgb_p = 3'd0;
	reg nirq_p = 1'b1;
	integer irq_n = 0, fr = 0, cpu_n = -1, target = -1;
	reg armed = 1'b0, wr_d = 1'b0, watch = 1'b0, paper_done = 1'b0;
	integer e1_line, e1_hc, wr_line, wr_hc, px_paper = -1, paper_hc = -1;
	wire [8:0] line = vid.vcounter[9:1];

	always @(posedge clk) if (nreset) begin
		// сырой спад nIRQ
		if (nirq_p && !nirq) begin
			irq_n = irq_n + 1;
			if (irq_n <= 3) $display("RAW nIRQ low first seen: line=%0d hcounter=%0d clken=%0d", line, vid.hcounter, clken);
			if (irq_n >= 2 && fr < nn) begin armed = 1'b1; target = n0 + fr; fr = fr + 1; end
			if (irq_n >= 2 + nn) begin $display("DONE"); $finish; end
		end
		nirq_p = nirq;
		// фронт процессора
		if (!clken && vid.hcounter[1:0] == cpuph[1:0]) begin
			if (armed && !nirq) begin
				armed = 1'b0; cpu_n = 0; e1_line = line; e1_hc = vid.hcounter;
				if (fr <= 1) $display("E1 (first CPU edge with nIRQ low): line=%0d hcounter=%0d", e1_line, e1_hc);
			end else if (cpu_n >= 0) cpu_n = cpu_n + 1;
			if (target >= 0 && cpu_n == target) begin wr_d = 1'b1; cpu_n = -1; wr_line = line; wr_hc = vid.hcounter; end
		end
		// запись: BORDER_IN видим через 2 posedge после фронта процессора
		if (wr_d) begin wr_d = 1'b0; border_in <= 3'd2; watch <= 1'b1; end
		// выход
		if (watch && rgb !== rgb_p) begin
			$display("N=%0d write: line=%0d hcounter=%0d | visible %0d->%0d: line=%0d hcounter=%0d clken=%0d px=%0d | px-px_paper=%0d",
				target, wr_line, wr_hc, rgb_p, rgb, line, vid.hcounter, clken, vid.hcounter >> 1, (vid.hcounter >> 1) - px_paper);
			watch <= 1'b0; target = -1;
		end
		if (line == 9'd0 && vid.hcounter < 10'd200 && rgb_p == 3'd7 && rgb == 3'd0 && !paper_done) begin
			paper_done = 1'b1; paper_hc = vid.hcounter; px_paper = vid.hcounter >> 1;
			if (irq_n <= 2) $display("PAPER start on line 0 (white border -> black paper) first seen: hcounter=%0d clken=%0d px=%0d", paper_hc, clken, px_paper);
		end
		if (line == 9'd100 && vid.hcounter == 10'd0 && clken) begin border_in <= 3'd7; paper_done = 1'b0; end
		rgb_p = rgb;
	end
	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk); nreset = 1'b1;
		$display("MACHINE %0d CPUPH %0d BORD_PHASE %0d BORD_DELAY %0d N0 %0d NN %0d", machine, cpuph, bphase, bdelay, n0, nn);
		#800_000_000; $display("TIMED OUT"); $finish;
	end
endmodule
