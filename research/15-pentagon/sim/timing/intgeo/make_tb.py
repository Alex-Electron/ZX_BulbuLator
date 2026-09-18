#!/usr/bin/env python3
# make_tb.py - собрать tb_intgeo.sv из копии харнеса tb_zx.sv (tb_zx.orig.sv) + блок измерений геометрии INT.
# Харнес НЕ правится: наследник = копия + вставки, помеченные "// intgeo:".
import sys
src = open('tb_zx.orig.sv', encoding='utf-8').read()

def sub1(old, new):
    global src
    assert src.count(old) == 1, ('якорь не найден ровно один раз: ' + old[:60])
    src = src.replace(old, new)

sub1('module tb_zx;', 'module tb_intgeo;   // intgeo: наследник tb_zx (копия харнеса + измерения геометрии прерывания)')
sub1('integer busall = 0;                  // 1 = печатать ВСЕ циклы шины начиная с TRACEFROM (много вывода)',
     'integer busall = 0;                  // 1 = печатать ВСЕ циклы шины начиная с TRACEFROM (много вывода)\n'
     'integer hcinit = 0;                  // intgeo: начальное hc/hCount растра (сдвиг фазы hc относительно pe3M5; 0 = как в железе)\n'
     'integer isrpatch = -1;               // intgeo: адрес для JP по 0x0038 страниц ПЗУ 0 и 1 (обработчик IM 1), -1 = не патчить')
sub1('	if ($value$plusargs("BUSALL=%d", busall)) ;',
     '	if ($value$plusargs("BUSALL=%d", busall)) ;\n'
     '	if ($value$plusargs("HCINIT=%d", hcinit)) ;      // intgeo\n'
     '	if ($value$plusargs("ISRPATCH=%h", isrpatch)) ;  // intgeo')
sub1('	dut.Video.hc = 9\'d0;  dut.Video.hCount = 9\'d0;',
     '	dut.Video.hc = hcinit[8:0];  dut.Video.hCount = hcinit[8:0];   // intgeo: HCINIT (по умолчанию 0 = харнес)')
sub1('		$display("PROG: %s, %0d байт по %04h; JP %04h записан в ПЗУ страниц 0 и 1", progfile, nbytes, org, org);\n	end',
     '		$display("PROG: %s, %0d байт по %04h; JP %04h записан в ПЗУ страниц 0 и 1", progfile, nbytes, org, org);\n	end\n'
     '	if (isrpatch >= 0) begin   // intgeo: обработчик IM 1 - JP isrpatch по 0x0038 страниц 0 и 1\n'
     '		mem.rom[16\'h0038] = 8\'hC3; mem.rom[16\'h0039] = isrpatch[7:0]; mem.rom[16\'h003A] = isrpatch[15:8];\n'
     '		mem.rom[16384 + 16\'h0038] = 8\'hC3; mem.rom[16384 + 16\'h0039] = isrpatch[7:0]; mem.rom[16384 + 16\'h003A] = isrpatch[15:8];\n'
     '		$display("ISRPATCH: JP %04h записан по 0x0038 страниц ПЗУ 0 и 1", isrpatch);\n'
     '	end')

block = r'''
//------------------------------------------------------------------------- intgeo: ГЕОМЕТРИЯ ПРЕРЫВАНИЯ
// Все измерения - в ОДНОМ always-блоке со СВОИМИ счётчиками (g_*), чтобы не гоняться с блоком харнеса.
// Соглашения о моменте события (везде одинаковые):
//   * "выборка" = posedge clock; значения регистров/проводов читаются ДО обновления на этом фронте -
//     ровно так их видит и T80 (он тоже читает INT_n на posedge при CEN=pc3M5).
//   * событие A = ПЕРВЫЙ posedge с dut.pc3M5=1, на котором cpu_irq читается 0: первый такт, на котором
//     T80 МОЖЕТ принять прерывание (T80.vhd:1166 читает INT_n напрямую на CEN). Это "T = 0 после INT"
//     в смысле софта/Fuse.
//   * "спад" сигнала (vduI, cpu_irq, шинные IORQ/WR/M1) = posedge, на котором регистры приняли новое
//     значение = (первый posedge, где сигнал читается 0) - 1 такт мастера.
//   * событие B = posedge с ne7M0 (ce видео), на котором dataOutputLoad=1 первый раз в кадре: на нём
//     dataOutput <= dataInput (video.v:186-188), и сразу после него бит 7 этого байта стоит на выходе
//     r/g/b (dataSelect = dataOutput[7], video.v:302,345-347). Байт и адрес выборки печатаются - это
//     должен быть 0x4000 (Video.a = 0).
//   * счётчики: g_mclk (posedge), g_px (ne7M0), g_pe (pe3M5), g_pc (dut.pc3M5) - инкремент ДО обработки
//     событий, поэтому "g_pc в момент A" ВКЛЮЧАЕТ импульс самого A, и разность g_pc(B)-g_pc(A) = число
//     импульсов pc3M5 в полуинтервале (A, B].
integer g_mclk = 0, g_px = 0, g_pe = 0, g_pc = 0, g_frames = 0, g_fpx0 = 0, g_fmclk0 = 0;
// событие A и серия выборок с INT_n=0
reg     cpu_low = 1'b0;
integer a_n = 0, a_mclk = -1, a_px = 0, a_pe = 0, a_pc = 0;
integer a_low_pc = 0, a_low_pe = 0, a_low_mclk0 = 0;
// спад vduI (сырой /INT ULA) и спад cpu_irq
reg     raw_d = 1'b1, cpu_d = 1'b1;
integer r_mclk = -1, r_px = 0, r_pe = 0, r_pc = 0, r_low_px = 0, r_low_mclk0 = 0;
integer r_wpc = 0, r_wne = 0, r_topc = -1, r_tone = -1;
integer c_mclk = -1, c_wpc = 0, c_wne = 0, c_topc = -1, c_tone = -1;
// первый пиксель бумаги
integer b_done = 1;
integer f_a = -1; reg [7:0] f_d = 8'h00;
// цепочка после A: подтверждение INT, M1 обработчика, IORQ&WR, защёлка бордюра
integer ack_p = 0, m1h_p = 0, iowr_p = 0, bord_p = 0;
reg     ack_d = 1'b0, m1c_d = 1'b0, iowr_d2 = 1'b0;
integer ack_mclk = -1;

always @(posedge clock) begin
	g_mclk = g_mclk + 1;
	if (ne7M0) g_px = g_px + 1;
	if (pe3M5) g_pe = g_pe + 1;
	if (dut.pc3M5 === 1'b1) g_pc = g_pc + 1;
	if (ne7M0 && dut.Video.hc == 9'd0 && dut.Video.vc == 9'd0) begin
		g_frames = g_frames + 1; b_done = 0; g_fpx0 = g_px; g_fmclk0 = g_mclk;
	end
	if (!reset_n) b_done = 1;   // кадр, в который попал сброс, не измеряем (как и харнес)
	if (reset_n) begin
		// ---- сырой /INT ULA: vduI = Video.irq
		if (dut.Video.irq === 1'b0 && raw_d === 1'b1) begin
			r_mclk = g_mclk - 1; r_px = g_px; r_pe = g_pe; r_pc = g_pc; r_low_px = 0; r_low_mclk0 = g_mclk;
			r_wpc = 1; r_wne = 1; r_topc = -1; r_tone = -1;
			$display("INTGEO RAWFALL f=%0d: спад vduI (posedge %0d): px_in_frame=%0d hCount=%0d vCount=%0d hc=%0d vc=%0d; на posedge спада: pe3M5=%b ne3M5=%b pe7M0=%b ne7M0=%b",
				g_frames, r_mclk, g_px - g_fpx0, dut.Video.hCount, dut.Video.vCount, dut.Video.hc, dut.Video.vc, pe3M5, ne3M5, pe7M0, ne7M0);
		end
		if (dut.Video.irq === 1'b0 && ne7M0) r_low_px = r_low_px + 1;
		if (dut.Video.irq === 1'b1 && raw_d === 1'b0)
			$display("INTGEO RAWLOW f=%0d: vduI низок %0d мастер = %0d px (ne7M0) = %0.2f T", g_frames, g_mclk - 1 - r_mclk, r_low_px, (g_mclk - 1 - r_mclk) / 16.0);
		raw_d = dut.Video.irq;
		if (r_wpc && dut.pc3M5 === 1'b1) begin r_wpc = 0; r_topc = g_mclk - r_mclk; end
		if (r_wne && dut.nc3M5 === 1'b1) begin r_wne = 0; r_tone = g_mclk - r_mclk; end
		// ---- cpu_irq (то, что подано на INT_n T80)
		if (dut.cpu_irq === 1'b0 && cpu_d === 1'b1) begin
			c_mclk = g_mclk - 1; c_wpc = 1; c_wne = 1; c_topc = -1; c_tone = -1;
		end
		cpu_d = dut.cpu_irq;
		if (c_wpc && dut.pc3M5 === 1'b1) begin c_wpc = 0; c_topc = g_mclk - c_mclk; end
		if (c_wne && dut.nc3M5 === 1'b1) begin c_wne = 0; c_tone = g_mclk - c_mclk; end
		// ---- событие A: выборки pc3M5 с INT_n=0
		if (dut.pc3M5 === 1'b1) begin
			if (dut.cpu_irq === 1'b0) begin
				if (!cpu_low) begin
					cpu_low = 1'b1; a_n = a_n + 1;
					a_mclk = g_mclk; a_px = g_px; a_pe = g_pe; a_pc = g_pc; a_low_pc = 0; a_low_pe = 0; a_low_mclk0 = g_mclk;
					ack_p = 1; m1h_p = 0; iowr_p = 1; bord_p = 1;
					$display("INTGEO A f=%0d #%0d: первая выборка pc3M5 с INT_n=0 (posedge %0d): px_in_frame=%0d hCount=%0d vCount=%0d hc=%0d vc=%0d | спад cpu_irq за %0d мастер до A (спад->pc3M5 %0d, спад->nc3M5 %0d) | спад vduI за %0d мастер = %0.3f T до A (спад->pc3M5 %0d, ->nc3M5 %0d)",
						g_frames, a_n, a_mclk, g_px - g_fpx0, dut.Video.hCount, dut.Video.vCount, dut.Video.hc, dut.Video.vc,
						a_mclk - c_mclk, c_topc, c_tone, a_mclk - r_mclk, (a_mclk - r_mclk) / 16.0, r_topc, r_tone);
				end
				a_low_pc = a_low_pc + 1;
			end else if (cpu_low) begin
				cpu_low = 1'b0;
				$display("INTGEO CPULOW f=%0d #%0d: INT_n=0 на %0d выборках pc3M5 подряд (T процессора); первая->первая высокая %0d мастер = %0.2f T",
					g_frames, a_n, a_low_pc, g_mclk - a_low_mclk0, (g_mclk - a_low_mclk0) / 16.0);
			end
		end
		// ---- первый пиксель бумаги (B)
		if (ne7M0 && dut.Video.dataInputLoad === 1'b1) begin f_a = dut.Video.a; f_d = dut.Video.d; end
		if (!b_done && ne7M0 && dut.Video.dataOutputLoad === 1'b1) begin
			b_done = 1;
			$display("INTGEO B f=%0d: загрузка dataOutput первым байтом бумаги (posedge %0d): px_in_frame=%0d hCount=%0d vCount=%0d hc=%0d vc=%0d h_rel=%0d v_rel=%0d байт=%02h (последняя выборка: Video.a=%04h = Z80 %04h, d=%02h); на этом posedge pe3M5=%b ne3M5=%b",
				g_frames, g_mclk, g_px - g_fpx0, dut.Video.hCount, dut.Video.vCount, dut.Video.hc, dut.Video.vc, dut.Video.h_rel, dut.Video.v_rel,
				dut.Video.dataInput, f_a, 16'h4000 + f_a, f_d, pe3M5, ne3M5);
			if (a_mclk >= 0)
				$display("INTGEO A2B f=%0d: A (T80 видит INT) -> B (первый пиксель 0x4000): %0d мастер = %0.3f T | pc3M5 в (A,B] = %0d | pe3M5 = %0d | px = %0d",
					g_frames, g_mclk - a_mclk, (g_mclk - a_mclk) / 16.0, g_pc - a_pc, g_pe - a_pe, g_px - a_px);
			if (r_mclk >= 0)
				$display("INTGEO R2B f=%0d: спад vduI -> B: %0d мастер = %0.3f T | px (ne7M0 в (спад,B]) = %0d | pe3M5 = %0d | pc3M5 = %0d",
					g_frames, g_mclk - r_mclk, (g_mclk - r_mclk) / 16.0, g_px - r_px, g_pe - r_pe, g_pc - r_pc);
			if (c_mclk >= 0)
				$display("INTGEO C2B f=%0d: спад cpu_irq -> B: %0d мастер = %0.3f T", g_frames, g_mclk - c_mclk, (g_mclk - c_mclk) / 16.0);
		end
		// ---- цепочка после A: подтверждение INT (M1&IORQ), M1 обработчика, IORQ&WR, защёлка бордюра
		if (ack_p && (~dut.m1 & ~dut.iorq) === 1'b1 && !ack_d) begin
			ack_p = 0; m1h_p = 1; ack_mclk = g_mclk - 1;
			$display("INTGEO ACK f=%0d #%0d: спад M1&IORQ (подтверждение INT) через %0d мастер = %0.2f T после A", g_frames, a_n, ack_mclk - a_mclk, (ack_mclk - a_mclk) / 16.0);
		end
		ack_d = (~dut.m1 & ~dut.iorq) === 1'b1;
		if (m1h_p && !ack_d && (~dut.m1 & ~dut.mreq) === 1'b1 && !m1c_d) begin
			m1h_p = 0;
			$display("INTGEO M1H f=%0d #%0d: спад M1 первой команды обработчика через %0d мастер = %0.2f T после A (%0.2f T после подтверждения), адрес %04h", g_frames, a_n, g_mclk - 1 - a_mclk, (g_mclk - 1 - a_mclk) / 16.0, (g_mclk - 1 - ack_mclk) / 16.0, dut.a);
		end
		m1c_d = (~dut.m1 & ~dut.mreq) === 1'b1;
		if (iowr_p && (~dut.iorq & ~dut.wr) === 1'b1 && !iowr_d2) begin
			iowr_p = 0;
			$display("INTGEO IOWR f=%0d #%0d: спад IORQ&WR через %0d мастер = %0.2f T после A; A=%04h q=%02h hCount=%0d vCount=%0d", g_frames, a_n, g_mclk - 1 - a_mclk, (g_mclk - 1 - a_mclk) / 16.0, dut.a, dut.q, dut.Video.hCount, dut.Video.vCount);
		end
		iowr_d2 = (~dut.iorq & ~dut.wr) === 1'b1;
		if (bord_p && pe7M0 && !dut.ioFE && !dut.wr) begin
			bord_p = 0;
			$display("INTGEO BORDER f=%0d #%0d: защёлка бордюра (pe7M0 & OUT #FE, main.v:230, posedge %0d): %0d -> %0d; через %0d мастер = %0.3f T после A | pc3M5 в (A,latch] = %0d | px_in_frame=%0d hCount=%0d vCount=%0d hc=%0d vc=%0d | от спада vduI %0d мастер = %0.3f T, px %0d",
				g_frames, a_n, g_mclk, dut.border, dut.q[2:0], g_mclk - a_mclk, (g_mclk - a_mclk) / 16.0, g_pc - a_pc,
				g_px - g_fpx0, dut.Video.hCount, dut.Video.vCount, dut.Video.hc, dut.Video.vc, g_mclk - r_mclk, (g_mclk - r_mclk) / 16.0, g_px - r_px);
		end
	end
end

endmodule
'''
sub1('\nendmodule\n', block)
open('tb_intgeo.sv', 'w', encoding='utf-8').write(src)
print("tb_intgeo.sv:", len(src.splitlines()), "строк")
