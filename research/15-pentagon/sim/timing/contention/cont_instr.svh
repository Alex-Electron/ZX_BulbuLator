//------------------------------------------------------------------------- ПРИБОРЫ КОНТЕНШЕНА
// Этот файл подключается в КОПИЮ стенда harness/tb_zx.sv (gen/tb_cont.sv генерирует run.sh:
// module tb_zx -> tb_cont + `include перед endmodule). Сам харнес не правится.
//
// Дополнительные плюс-аргументы:
//   ISR=1                 стенд сам собирает обработчик IM2 по 0x8383 (см. build_handler):
//                         JP -> [паддинг PADT тактов] -> LD A,AVAL ; LD BC,PORT -> измеряемая команда @0x8400
//                         -> [CHAIN блоков: LD A,AVAL ; паддинг с остатком j mod 8 ; команда] -> NOP EI RET
//   INSTR=RD|WR|INCHL|OUTFE|INFE|OUTC|INC|LDIX|NOP   измеряемая команда (умолчание RD = LD A,(HL))
//   PADT=<T> SWEEP=<n>    паддинг в тактах и число прерываний (PADT растёт на 1 на каждое прерывание)
//   PADT2/SWEEP2 PADT3/SWEEP3  ещё два диапазона свипа подряд
//   CHAIN=<n>             после первой команды ещё n блоков (паддинг j = номер блока mod 8: 0,9,6,7,4,13,10,11 T)
//   HLV=<hex> IXV=<hex>   указатели HL/IX программы im2sweep (умолчание 4000)
//   P7FFD=<hex>           байт, который программа пишет в 7FFD при старте (128K: банк в 0xC000)
//   PORT=<hex> AVAL=<hex> BC и A перед измеряемой командой (умолчания 7FFD и 02)
//   CONTLOG=1 CLFROM=<k> CLTO=<k>  печатать каждый потерянный pe3M5 с T-индексом k в [CLFROM,CLTO]
//   ACCLOG=1              печатать каждый интервал шины с контендуемым адресом или циклом ввода-вывода
//                         (строки ACC: k начала T1, hUla/vCount в этот момент, потерянные такты)
//   WINLINE=<vc>          напечатать форму окна по строке vc (пиксели и такты)
//   FRAMESTAT=1           на каждом кадре: pe / pc / потеряно / потеряно в строках бумаги / M1
//   MWPULSE=<тактов мастера>  (d) раз за кадр поднять mem_wait на столько тактов мастера
//   CPUCKINIT=<0|1>       (d) начальное значение dut.cpuck (харнес ставит 0)
//   HCINIT=<n>            (d) начальное hc растра (харнес ставит 0): меняет чётность hc относительно pe3M5
//   NOCOMP=1              не компенсировать фазу решётки HALT (фаза гуляет; так виден минимум kacc)
//
// Единицы: T-индекс k = номер импульса pe3M5, считая от ДЕТЕКЦИИ спада Video.irq (сырой /INT):
// k=1 - первый pe3M5 после спада. pe3M5 - шаг T80 «если бы не контеншен», pc3M5 - реальный шаг.
// Потерянный такт = posedge clock с pe3M5=1 и dut.contend=0 (cpu_hold исключён явно).
// hUla = координата video.v (= hCount = hc+1 в момент импульса); окно cn = dataEnable && (hUla[3]||hUla[2]).

integer isr = 0, sweep = 0, sweep2 = 0, sweep3 = 0, padt = 0, padt2 = -1, padt3 = -1, chain = 0;
integer hlv = 32'h4000, ixv = 32'h4000, p7ffd = 0, portv = 32'h7FFD, aval = 32'h02;
string  instr = "RD";
integer contlog = 0, clfrom = 0, clto = 0, acclog = 0, winline = -1, framestat = 0, mwpulse = 0;
integer cpuckinit = -1, hcinit = -1, nocomp = 0;
reg m1cyc_q = 1'b0;

task automatic poke(input integer addr, input [7:0] b);
	integer ix;
	begin ix = ram_index(addr); if (ix < 0) begin $display("poke: %04h не ОЗУ", addr); $finish; end mem.ram[ix] = b; end
endtask
localparam integer ENTRY  = 32'h8383;   // вектор IM2 (I=0x81, таблица 0x8100..0x8200 = 0x83)
localparam integer ADDR_M = 32'h8400;   // адрес измеряемой команды
localparam integer LOOP   = 32'h8360;   // im2sweep: halt ; jp COMP
localparam integer COMP   = 32'h8370;   // стенд пишет сюда компенсацию фазы (0/6/7/9 T) + JP LOOP
// Компенсация: длина обработчика (паддинг + потерянные такты) приводится к константе по модулю 4,
// иначе решётка HALT (4 T) сдвигается с каждым прерыванием и kacc гуляет. r = требуемый остаток (0..3), НЕ отрицательный.
task automatic write_comp(input integer r);
	integer p;
	begin
		p = COMP;
		case (r)
			1: begin poke(p, 8'hED); poke(p + 1, 8'h4F); p = p + 2; end   // LD R,A  9 T = 1 mod 4
			2: begin poke(p, 8'h13); p = p + 1; end                        // INC DE  6 T = 2 mod 4
			3: begin poke(p, 8'h1E); poke(p + 1, 8'h00); p = p + 2; end   // LD E,n  7 T = 3 mod 4
			default: ;
		endcase
		poke(p, 8'hC3); poke(p + 1, LOOP[7:0]); poke(p + 2, LOOP[15:8]);
	end
endtask

integer c_pe = 0, c_pc = 0, c_px = 0;
integer int_pe_base = 0, int_px_base = 0, cint_pe_base = 0, n_int = 0;
reg irq_q = 1'b1, cirq_q = 1'b1;
integer last_pc_k = 0, last_pc_hula = 0, last_pc_vc = 0;
integer lost_frame = 0, lost_paper = 0, lost_total = 0, lost_paper_total = 0;
integer lost_hist [0:7];
integer first_lost_k = -1, first_lost_hula = -1, first_lost_vc = -1;
reg [15:0] first_lost_a = 16'd0;
integer first_cn_px = -1, first_cn_hc = -1, first_cn_vc = -1;
integer first_paper_px = -1, first_paper_hc = -1, first_paper_vc = -1;
integer first_vduc_k = -1, first_vduc_hula = -1, first_vduc_vc = -1;   // первый импульс pe3M5 с vduC=1 после /INT
integer first_lost_k_frame = -1;

// приём прерывания
reg m1_q = 1'b1, intack_q = 1'b0;
integer k_m1_start = 0, k_acc = -1, k_acc_min = 1000000, k_acc_max = -1, in_isr = 0, isr_lost = 0, isr_acc = 0;
integer k_entry = -1;   // k начала M1 по адресу ENTRY (первая команда обработчика)

// интервалы шины (доступы)
reg [15:0] a_q = 16'hFFFF;
integer acc_k = 0, acc_hula = 0, acc_vc = 0, acc_pe0 = 0, acc_pc0 = 0, acc_lost = 0, acc_io = 0, acc_memc = 0, acc_wr = 0, acc_n = 0;
string  acc_lostk = "";
integer cur_padt = 0, cur_padt_real = 0, ret_addr = 0, addr_next = 0;
integer sweep_left = 0, sweep_stage = 0, meas_n = 0;

// окно по строке
string  s_cn = "", s_paper = "", s_pe = "", s_vduc = "", s_win = "", s_cont = "";
integer win_done = 0, win_active = 0, win_first_vduc_k = -1, win_first_cont_k = -1, win_first_vduc_hula = -1;

integer q_i;
initial for (q_i = 0; q_i < 8; q_i = q_i + 1) lost_hist[q_i] = 0;

// ------------------------------------------------------------------ сборка обработчика
reg [7:0] hbuf [0:1023];
integer   hlen = 0, hb_start = 0;
task automatic emit(input [7:0] b); begin hbuf[hlen] = b; hlen = hlen + 1; end endtask
task automatic emit_instr(input string s);
	case (s)
		"RD":    emit(8'h7E);                                   // LD A,(HL)     7 T  pc:4 hl:3
		"WR":    emit(8'h77);                                   // LD (HL),A     7 T  pc:4 hl:3
		"INCHL": emit(8'h34);                                   // INC (HL)     11 T  pc:4 hl:3 hl:1 hl:3
		"OUTFE": begin emit(8'hD3); emit(8'hFE); end            // OUT (FE),A   11 T  pc:4 pc+1:3 IO:4
		"INFE":  begin emit(8'hDB); emit(8'hFE); end            // IN A,(FE)    11 T
		"OUTC":  begin emit(8'hED); emit(8'h79); end            // OUT (C),A    12 T  pc:4 pc+1:4 IO:4
		"INC":   begin emit(8'hED); emit(8'h78); end            // IN A,(C)     12 T
		"LDIX":  begin emit(8'hDD); emit(8'h7E); emit(8'h00); end // LD A,(IX+0) 19 T
		default: emit(8'h00);
	endcase
endtask
// паддинг с остатком j mod 8 (0,9,6,7,4,13,10,11 T), не трогает A/BC/HL
task automatic emit_pad8(input integer j);
	case (j % 8)
		1: begin emit(8'hED); emit(8'h4F); end                       // LD R,A 9
		2: emit(8'h13);                                              // INC DE 6
		3: begin emit(8'h1E); emit(8'h00); end                       // LD E,0 7
		4: emit(8'h00);                                              // NOP 4
		5: begin emit(8'h00); emit(8'hED); emit(8'h4F); end          // 13
		6: begin emit(8'h00); emit(8'h13); end                       // 10
		7: begin emit(8'h00); emit(8'h1E); emit(8'h00); end          // 11
		default: ;
	endcase
endtask
// паддинг ровно на pad_t тактов (если представимо): циклы LD B,n / DJNZ (13n+2), затем NOP(4) INC DE(6) LD E,n(7) LD R,A(9)
task automatic build_handler(input integer pad_t);
	integer rem, n, r, i, a, j;
	begin
		hlen = 0; rem = pad_t;
		while (rem >= 41) begin
			n = (rem - 2) / 13; if (n > 255) n = 255;
			r = rem - (13 * n + 2);
			if (r == 1 || r == 2 || r == 3 || r == 5) n = n - 1;
			emit(8'h06); emit(n[7:0]); emit(8'h10); emit(8'hFE);
			rem = rem - (13 * n + 2);
		end
		r = rem % 4;
		if (r == 1 && rem >= 9) begin emit(8'hED); emit(8'h4F); rem = rem - 9; end
		else if (r == 2 && rem >= 6) begin emit(8'h13); rem = rem - 6; end
		else if (r == 3 && rem >= 7) begin emit(8'h1E); emit(8'h00); rem = rem - 7; end
		while (rem >= 4) begin emit(8'h00); rem = rem - 4; end
		cur_padt_real = pad_t - rem;   // rem = непредставимый остаток (0..3 или 5)
		// установка A и BC
		emit(8'h3E); emit(aval[7:0]);
		emit(8'h01); emit(portv[7:0]); emit(portv[15:8]);
		if (hlen > ADDR_M - (ENTRY + 3)) begin $display("build_handler: паддинг %0d T не влезает (%0d байт)", pad_t, hlen); $finish; end
		hb_start = ADDR_M - hlen;
		for (a = ENTRY; a < ADDR_M + 16 + 8 * chain; a = a + 1) poke(a, 8'h00);
		poke(ENTRY, 8'hC3); poke(ENTRY + 1, hb_start[7:0]); poke(ENTRY + 2, hb_start[15:8]);
		for (i = 0; i < hlen; i = i + 1) poke(hb_start + i, hbuf[i]);
		hlen = 0; emit_instr(instr);
		for (j = 0; j < chain; j = j + 1) begin
			emit(8'h3E); emit(aval[7:0]);   // LD A,n 7 T (для IN восстанавливает старший байт порта)
			emit_pad8(j);
			emit_instr(instr);
		end
		emit(8'h00); emit(8'hFB); emit(8'hC9);   // NOP EI RET
		for (i = 0; i < hlen; i = i + 1) poke(ADDR_M + i, hbuf[i]);
		addr_next = ADDR_M + hlen - 3;
		ret_addr  = ADDR_M + hlen - 1;
	end
endtask

initial begin
	if ($value$plusargs("ISR=%d", isr)) ;
	if ($value$plusargs("INSTR=%s", instr)) ;
	if ($value$plusargs("PADT=%d", padt)) ;
	if ($value$plusargs("SWEEP=%d", sweep)) ;
	if ($value$plusargs("PADT2=%d", padt2)) ;
	if ($value$plusargs("SWEEP2=%d", sweep2)) ;
	if ($value$plusargs("PADT3=%d", padt3)) ;
	if ($value$plusargs("SWEEP3=%d", sweep3)) ;
	if ($value$plusargs("CHAIN=%d", chain)) ;
	if ($value$plusargs("HLV=%h", hlv)) ;
	if ($value$plusargs("IXV=%h", ixv)) ;
	if ($value$plusargs("P7FFD=%h", p7ffd)) ;
	if ($value$plusargs("PORT=%h", portv)) ;
	if ($value$plusargs("AVAL=%h", aval)) ;
	if ($value$plusargs("CONTLOG=%d", contlog)) ;
	if ($value$plusargs("CLFROM=%d", clfrom)) ;
	if ($value$plusargs("CLTO=%d", clto)) ;
	if ($value$plusargs("ACCLOG=%d", acclog)) ;
	if ($value$plusargs("WINLINE=%d", winline)) ;
	if ($value$plusargs("FRAMESTAT=%d", framestat)) ;
	if ($value$plusargs("MWPULSE=%d", mwpulse)) ;
	if ($value$plusargs("CPUCKINIT=%d", cpuckinit)) ;
	if ($value$plusargs("HCINIT=%d", hcinit)) ;
	if ($value$plusargs("NOCOMP=%d", nocomp)) ;
	#2;   // харнес загрузил PROG на #1 и проинициализировал регистры на #0
	if (hcinit >= 0) begin dut.Video.hc = hcinit[8:0]; dut.Video.hCount = hcinit[8:0] + 9'd1; $display("tb_cont: hc стартует с %0d", hcinit); end
	if (isr) begin
		// патчи каркаса im2sweep: org+2/3 = HL, org+6/7 = IX, org+9 = байт для 7FFD
		poke(org + 2, hlv[7:0]); poke(org + 3, hlv[15:8]);
		poke(org + 6, ixv[7:0]); poke(org + 7, ixv[15:8]);
		poke(org + 9, p7ffd[7:0]);
		cur_padt = padt; sweep_left = (sweep > 0) ? sweep : 1; sweep_stage = 1;
		build_handler(cur_padt);
		write_comp(0);
		$display("tb_cont: ISR INSTR=%s PADT=%0d (реально %0d) SWEEP=%0d CHAIN=%0d HL=%04h IX=%04h 7FFD=%02h BC=%04h A=%02h; обработчик %04h -> JP %04h, команда @%04h, RET @%04h",
			instr, cur_padt, cur_padt_real, sweep, chain, hlv, ixv, p7ffd, portv, aval, ENTRY, hb_start, ADDR_M, ret_addr);
	end
end

// (d) CPUCKINIT: cpuck ставится ПОСЛЕ снятия сброса (T80 уже выдаёт определённые MREQ/адрес). Ставить до сброса
// нельзя: mreq = X в сбросе -> флаг X -> при cpuck=1 contend = X -> cpuck = X навсегда (первый прогон так и отравился).
initial if (cpuckinit >= 0) begin
	@(posedge reset_n); repeat (100) @(posedge clock); @(negedge clock);
	dut.cpuck = cpuckinit[0];
	$display("[%0t] tb_cont: cpuck принудительно = %0d (после сброса; hc=%0d contend=%b)", $time, cpuckinit[0], dut.Video.hc, dut.contend);
end

// ------------------------------------------------------------------ главный прибор
always @(posedge clock) begin
	if (pe3M5) c_pe = c_pe + 1;
	if (ne7M0) c_px = c_px + 1;
	if (dut.pc3M5 === 1'b1) c_pc = c_pc + 1;
	irq_q  <= dut.Video.irq;
	cirq_q <= dut.cpu_irq;
	if (reset_n && irq_q && !dut.Video.irq) begin
		int_pe_base = c_pe; int_px_base = c_px; n_int = n_int + 1;
		first_lost_k_frame = -1;
	end
	if (reset_n && cirq_q && !dut.cpu_irq) cint_pe_base = c_pe;
	// окно контеншена (cn) и первый пиксель бумаги на выходе, в пикселях от /INT
	if (ne7M0 && n_int > 0 && first_cn_px < 0 && dut.Video.cn === 1'b1) begin
		first_cn_px = c_px - int_px_base; first_cn_hc = dut.Video.hCount; first_cn_vc = dut.Video.vCount;
	end
	if (ne7M0 && n_int > 0 && first_paper_px < 0 && blank === 1'b0 && r === 1'b0 && g === 1'b0 && b === 1'b0) begin
		first_paper_px = c_px - int_px_base; first_paper_hc = dut.Video.hCount; first_paper_vc = dut.Video.vCount;
	end
	// такты
	if (pe3M5 && reset_n) begin
		if (n_int > 0 && first_vduc_k < 0 && dut.vduC === 1'b1) begin
			first_vduc_k = c_pe - int_pe_base; first_vduc_hula = dut.Video.hUla; first_vduc_vc = dut.Video.vCount;
		end
		if (dut.pc3M5 === 1'b1) begin
			last_pc_k = c_pe - int_pe_base; last_pc_hula = dut.Video.hUla; last_pc_vc = dut.Video.vCount;
		end else if (dut.contend === 1'b0) begin
			lost_frame = lost_frame + 1; lost_total = lost_total + 1;
			if (dut.Video.vCount < 192) begin lost_paper = lost_paper + 1; lost_paper_total = lost_paper_total + 1; end
			lost_hist[dut.Video.hUla[3:1]] = lost_hist[dut.Video.hUla[3:1]] + 1;
			if (first_lost_k < 0) begin
				first_lost_k = c_pe - int_pe_base; first_lost_hula = dut.Video.hUla; first_lost_vc = dut.Video.vCount; first_lost_a = dut.a;
			end
			if (first_lost_k_frame < 0) first_lost_k_frame = c_pe - int_pe_base;
			if (contlog && (c_pe - int_pe_base) >= clfrom && (c_pe - int_pe_base) <= clto)
				$display("LOST k=%0d a=%04h m1=%b mreq=%b iorq=%b rd=%b wr=%b hUla=%0d vCount=%0d flag=%b cpuck=%b memC=%b ioFE=%b",
					c_pe - int_pe_base, dut.a, dut.m1, dut.mreq, dut.iorq, dut.rd, dut.wr,
					dut.Video.hUla, dut.Video.vCount, dut.mreqt23iorqtw3, dut.cpuck, dut.memC, dut.ioFE);
			if (in_isr) isr_lost = isr_lost + 1;
			acc_lost = acc_lost + 1;
			acc_lostk = {acc_lostk, $sformatf(" %0d", c_pe - int_pe_base)};
		end
	end
	// приём прерывания: k начала M1 цикла подтверждения
	m1_q <= dut.m1; intack_q <= intack;
	if (reset_n && m1_q && !dut.m1) k_m1_start = last_pc_k;
	if (reset_n && intack && !intack_q) begin
		k_acc = k_m1_start; in_isr = 1; isr_lost = 0; isr_acc = 0; k_entry = -1;
		if (k_acc < k_acc_min) k_acc_min = k_acc;
		if (k_acc > k_acc_max) k_acc_max = k_acc;
	end
	// интервалы шины: адрес сменился -> предыдущий интервал закончен
	a_q <= dut.a;
	if (reset_n && dut.a !== a_q) begin
		if (acc_io || acc_memc) begin
			acc_n = acc_n + 1; isr_acc = isr_acc + 1;
			if (acclog)
				$display("ACC k=%0d kacc=%0d hUla=%0d vCount=%0d a=%04h %s%s pe=%0d pc=%0d lost=%0d lostk=%s",
					acc_k, k_acc, acc_hula, acc_vc, a_q, acc_io ? "IO" : "MEM", acc_wr ? "-WR" : "-RD",
					c_pe - acc_pe0, c_pc - acc_pc0, acc_lost, acc_lostk);
		end
		acc_k = last_pc_k; acc_hula = last_pc_hula; acc_vc = last_pc_vc; acc_pe0 = c_pe; acc_pc0 = c_pc;
		acc_lost = 0; acc_lostk = ""; acc_io = 0; acc_wr = 0;
		acc_memc = (dut.memC === 1'b1);
	end
	if (reset_n) begin
		if (dut.iorq === 1'b0) acc_io = 1;
		if (dut.wr === 1'b0) acc_wr = 1;
	end
	// обработчик: вход и выход
	m1cyc_q <= m1cyc;
	if (isr && m1cyc && !m1cyc_q && reset_n) begin
		if (dut.a == ENTRY[15:0]) k_entry = last_pc_k;
		if (in_isr && dut.a == ret_addr[15:0]) begin
			in_isr = 0; meas_n = meas_n + 1;
			$display("ISR pad=%0d int=%0d kacc=%0d kentry=%0d доступов=%0d isr_lost=%0d", cur_padt_real, n_int, k_acc, k_entry, isr_acc, isr_lost);
			// От приёма INT (k_acc) до начала M1 команды RET прошло last_pc_k - k_acc тактов; дальше RET(10) + JP(10) +
			// comp + JP(10) = 30 + comp. Кадр 69888/70908 = 0 mod 4, значит решётка HALT сохраняется, если весь путь = 0 mod 4.
			if (!nocomp) write_comp((4 - ((last_pc_k - k_acc + 30) % 4)) % 4);
			sweep_left = sweep_left - 1;
			if (sweep_left <= 0) begin
				if (sweep_stage == 1 && padt2 >= 0 && sweep2 > 0) begin sweep_stage = 2; cur_padt = padt2; sweep_left = sweep2; end
				else if (sweep_stage == 2 && padt3 >= 0 && sweep3 > 0) begin sweep_stage = 3; cur_padt = padt3; sweep_left = sweep3; end
				else begin
					$display("SWEEP DONE: %0d прерываний, %0d доступов; kacc min/max=%0d/%0d; потеряно всего %0d (в бумаге %0d)",
						meas_n, acc_n, k_acc_min, k_acc_max, lost_total, lost_paper_total);
					$finish;
				end
			end else cur_padt = cur_padt + 1;
			build_handler(cur_padt);   // процессор сейчас на RET, область паддинга не исполняется; байты цепочки те же
		end
	end
end

// ------------------------------------------------------------------ форма окна по строке WINLINE
always @(posedge clock) if (winline >= 0 && !win_done && n_int > 0) begin
	if (ne7M0) begin
		if (dut.Video.vc == winline[8:0] && dut.Video.hc == 9'd0) win_active = 1;
		if (win_active && dut.Video.vc == winline[8:0]) begin
			s_cn    = {s_cn,    (dut.Video.cn === 1'b1) ? "#" : "."};
			s_paper = {s_paper, (blank === 1'b0 && r === 1'b0 && g === 1'b0 && b === 1'b0) ? "P" : (blank === 1'b1 ? "b" : ".")};
			s_pe    = {s_pe,    pe3M5 ? "|" : "."};
		end
		if (win_active && dut.Video.vc != winline[8:0]) begin
			win_done = 1;
			$display("WINLINE vc=%0d, по пикселям (индекс = hc в момент ne7M0, %0d px):", winline, s_cn.len());
			$display("  cn    : %s", s_cn);
			$display("  paper : %s   (P = бумага на выходе r=g=b=0 при !blank, b = гашение)", s_paper);
			$display("  pe3M5 : %s   (| = такт мастера с pe3M5, шаг T80)", s_pe);
			$display("  по тактам (индекс = номер pe3M5 в строке, %0d T):", s_vduc.len());
			$display("  vduC        : %s", s_vduc);
			$display("  vduC&&cpuck : %s", s_win);
			$display("  contend==0  : %s   (реально потерянные такты программы)", s_cont);
			$display("  первый импульс pe3M5 с vduC=1 на строке: k=%0d (hUla %0d); первый с contend=0: k=%0d; kacc=%0d", win_first_vduc_k, win_first_vduc_hula, win_first_cont_k, k_acc);
		end
	end
	if (pe3M5 && win_active && dut.Video.vc == winline[8:0]) begin
		s_vduc = {s_vduc, (dut.vduC === 1'b1) ? "#" : "."};
		s_win  = {s_win,  (dut.vduC === 1'b1 && dut.cpuck === 1'b1) ? "#" : "."};
		s_cont = {s_cont, (dut.contend === 1'b0) ? "#" : "."};
		if (win_first_vduc_k < 0 && dut.vduC === 1'b1) begin win_first_vduc_k = c_pe - int_pe_base; win_first_vduc_hula = dut.Video.hUla; end
		if (win_first_cont_k < 0 && dut.contend === 1'b0) win_first_cont_k = c_pe - int_pe_base;
	end
end

// ------------------------------------------------------------------ статистика по кадрам
integer fs_m1_0 = 0;
always @(ev_frame) begin
	if (framestat && n_frames >= 2)
		$display("FRAME %0d: pe3M5=%0d pc3M5=%0d потеряно=%0d (в строках бумаги %0d) M1=%0d первый потерянный k в кадре=%0d kacc=%0d",
			n_frames - 1, last_frame_pe, last_frame_pc, lost_frame, lost_paper, n_m1 - fs_m1_0, first_lost_k_frame, k_acc);
	fs_m1_0 = n_m1; lost_frame = 0; lost_paper = 0;
end

// ------------------------------------------------------------------ (d) импульс mem_wait раз за кадр
always @(ev_frame) if (mwpulse > 0 && n_frames >= 2) begin
	repeat (1000) @(posedge clock);
	@(negedge clock); mem_wait = 1'b1;
	repeat (mwpulse) @(negedge clock);
	mem_wait = 1'b0;
end

final begin
	$display("CONT ИТОГ: потеряно всего %0d, в строках бумаги %0d; гистограмма потерь по фазе hUla[3:1] (0..7): %0d %0d %0d %0d %0d %0d %0d %0d",
		lost_total, lost_paper_total, lost_hist[0], lost_hist[1], lost_hist[2], lost_hist[3], lost_hist[4], lost_hist[5], lost_hist[6], lost_hist[7]);
	$display("CONT ИТОГ: первый потерянный такт после первого /INT: k=%0d hUla=%0d vCount=%0d a=%04h; первый импульс pe3M5 с vduC=1: k=%0d hUla=%0d vCount=%0d",
		first_lost_k, first_lost_hula, first_lost_vc, first_lost_a, first_vduc_k, first_vduc_hula, first_vduc_vc);
	$display("CONT ИТОГ: после первого /INT: первый пиксель cn=1 px=%0d (hCount %0d vCount %0d); первый пиксель бумаги на выходе (r=g=b=0, !blank) px=%0d (hCount %0d vCount %0d); /INT видел процессор (cpu_irq) на %0d T позже сырого; kacc min/max=%0d/%0d",
		first_cn_px, first_cn_hc, first_cn_vc, first_paper_px, first_paper_hc, first_paper_vc, cint_pe_base - int_pe_base, k_acc_min, k_acc_max);
end
