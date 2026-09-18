//-------------------------------------------------------------------------------------------------
// tb_divmmc_map.v - стенд автомаппера и МАТРИЦЫ ПАМЯТИ DivMMC (B0131), xsim / Vivado 2023.1
//-------------------------------------------------------------------------------------------------
// Что проверяется (и почему именно это):
//
//  A. ТАБЛИЦА ПРИОРИТЕТОВ Divide_pgm_model.txt:137-153 («EPROM jumper -> MAPRAM -> CONMEM»,
//     снизу вверх). Это единственный документ, где приоритеты записаны словами автора железа,
//     и наш прежний код им противоречил: страница 3 попадала в низ окна при ЛЮБОМ липком MAPRAM,
//     то есть CONMEM НЕ перекрывал MAPRAM.
//  B. ВСЕ ВОСЕМЬ входов и выходов автомаппера циклами M1: 0x0000, 0x0008, 0x0038, 0x0066,
//     0x04C6, 0x0562 (отложенный вход - «в рефреше после выборки»), 0x3Dxx (МГНОВЕННЫЙ вход) и
//     диапазон 0x1FF8..0x1FFF (выход). Плюс ГЕЙТ входов двумя термами (живой Sizif divmmc.sv:61-71).
//  C. РЕГРЕССИЯ: при MACHINE_CFG[17] = 0 (mapper = 0) машина обязана вести себя БАЙТ-В-БАЙТ как
//     до B0131. Сравнение идёт не «на глаз», а с НЕЗАВИСИМОЙ моделью прежнего поведения, которая
//     живёт в этом файле (ref_memA/ref_memWr) и написана по формулам ДО правки.
//
// Стенд НАМЕРЕННО гоняет модуль `memory` в одиночку: матрица - чистая комбинаторика от защёлок,
// и полный core сюда не нужен, зато нужен полный перебор состояний (conmem/mapram/page).
//
// Запуск:
//   source /tools/Xilinx/Vivado/2023.1/settings64.sh
//   cp .../sources/atlas_core/memory.v .   (стенд гоняет ИМЕННО файл репозитория)
//   xvlog memory.v tb_divmmc_map.v
//   xelab -timescale 1ns/1ps tb_divmmc_map -s tb    # -timescale ОБЯЗАТЕЛЕН: у memory.v его нет
//   xsim tb -R                                      # PASS = 76 утверждений, 0 отказов
//
// Стенд ПРОВЕРЕН НА МУТАЦИЯХ (иначе «прошло с первого раза» ничего не значит). Каждая правка
// ломает ровно своё утверждение: старая матрица (CONMEM не перекрывает MAPRAM) -> [57];
// защита записи без терма !conmem -> [59]; гейт одним термом -> [29]; ПЗУ DivMMC в странице 1
// -> [9],[27],[39]; страница 5 бит (уезжает в регион 2'b11) -> [45],[46]; трап 0x3Dxx без гейта
// по DivMMC -> [68],[70],[73]; терм A4 без гейта mapper -> 240 расхождений в регрессии.
//-------------------------------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_divmmc_map;

	// ---- шина машины -------------------------------------------------------------------------
	reg         clock = 1'b0;
	reg         ce    = 1'b0;
	reg         reset = 1'b0;
	reg         rfsh  = 1'b1;
	reg         mreq  = 1'b1;
	reg         iorq  = 1'b1;
	reg         rd    = 1'b1;
	reg         wr    = 1'b1;
	reg         m1    = 1'b1;
	reg  [15:0] a     = 16'h0000;
	reg  [ 7:0] d     = 8'h00;

	// ---- статические входы -------------------------------------------------------------------
	reg         model      = 1'b1;   // 128K
	reg         pent1024   = 1'b1;   // Пентагон 1024
	reg  [ 2:0] ram_nobit  = 3'b000; // все банки есть
	reg         snow_off   = 1'b1;
	reg         mapper     = 1'b0;   // MACHINE_CFG[17]
	reg  [ 3:0] dm_opt     = 4'b0000;
	reg         dm_pagein_off = 1'b0;
	reg         force_7ffd = 1'b0;
	reg  [ 5:0] port7ffd_in= 6'd0;
	reg         trdos_en   = 1'b0;
	reg         service_en = 1'b0;
	reg  [12:0] va         = 13'd0;

	wire        cn, memRf, memRd, memWr, trdos_o;
	wire [13:0] vmmA1, vmmA2;
	wire [18:0] memA;
	wire [ 5:0] ram_bank;
	wire [ 7:0] eff7_o, map_diag;
	wire [ 5:0] port7ffd_o;
	wire [ 1:0] rom_page_o;

	memory dut (
		.model(model), .pent1024(pent1024), .ram_nobit(ram_nobit), .snow_off(snow_off),
		.mapper(mapper), .dm_opt(dm_opt), .dm_pagein_off(dm_pagein_off),
		.clock(clock), .ce(ce), .reset(reset), .rfsh(rfsh), .mreq(mreq), .iorq(iorq),
		.rd(rd), .wr(wr), .m1(m1), .a(a), .d(d),
		.cn(cn), .va(va), .vmmA1(vmmA1), .vmmA2(vmmA2),
		.memRf(memRf), .memRd(memRd), .memWr(memWr), .memA(memA), .ram_bank(ram_bank),
		.eff7_o(eff7_o), .force_7ffd(force_7ffd), .port7ffd_in(port7ffd_in),
		.port7ffd_o(port7ffd_o), .map_diag(map_diag),
		.trdos_en(trdos_en), .service_en(service_en), .trdos_o(trdos_o), .rom_page_o(rom_page_o)
	);

	// 56.667 МГц - настоящий такт машины (spclk)
	always #8.824 clock = ~clock;
	// ce = pc3M5: один такт из шестнадцати
	integer cediv = 0;
	always @(posedge clock) begin
		cediv <= (cediv == 15) ? 0 : cediv + 1;
		ce    <= (cediv == 15);
	end

	// ---- счётчики утверждений -----------------------------------------------------------------
	integer n_chk = 0, n_pass = 0, n_fail = 0;

	task ok;
		input        cond;
		input [4095:0] name;
		begin
			n_chk = n_chk + 1;
			if (cond) n_pass = n_pass + 1;
			else begin
				n_fail = n_fail + 1;
				$display("  FAIL [%0d] %0s   (memA=%05h memWr=%b map_diag=%02h t=%0t)",
				         n_chk, name, memA, memWr, map_diag, $time);
			end
		end
	endtask

	task eq19;
		input [18:0] got;
		input [18:0] exp;
		input [4095:0] name;
		begin
			n_chk = n_chk + 1;
			if (got === exp) n_pass = n_pass + 1;
			else begin
				n_fail = n_fail + 1;
				$display("  FAIL [%0d] %0s   ожидалось %05h, получено %05h (t=%0t)",
				         n_chk, name, exp, got, $time);
			end
		end
	endtask

	// ---- элементарные циклы шины Z80 ----------------------------------------------------------
	localparam integer TQ = 4;   // четверть T-такта в тактах spclk (T = 16 clock)

	// #1 после последнего фронта обязателен: без него стенд менял бы входы В ТОТ ЖЕ момент, что и
	// фронт, и результат зависел бы от порядка планировщика (классическая гонка стенда, которая
	// даёт «плавающие» отказы вместо честного FAIL).
	task tick; input integer n; integer i; begin for(i=0;i<n;i=i+1) @(posedge clock); #1; end endtask

	// Выборка команды (M1): mreq и m1 активны НУЛЁМ одновременно, затем рефреш.
	task m1_fetch;
		input [15:0] addr;
		begin
			a = addr; m1 = 1'b0; mreq = 1'b0; rd = 1'b0; rfsh = 1'b1;
			tick(2*TQ);                       // T1..T2 - выборка
			mreq = 1'b1; rd = 1'b1; m1 = 1'b1;
			rfsh = 1'b0;  tick(2*TQ);         // T3..T4 - рефреш (здесь автомаппер и переключается)
			rfsh = 1'b1;  tick(TQ);
		end
	endtask

	// Обычное чтение памяти: возвращает адрес, который выставил MMU.
	task mem_read;
		input  [15:0] addr;
		output [18:0] pa;
		begin
			a = addr; mreq = 1'b0; rd = 1'b0;
			tick(TQ);
			pa = memA;
			mreq = 1'b1; rd = 1'b1;
			tick(TQ);
		end
	endtask

	// Запись в память: отдаёт и адрес, и разрешение записи.
	task mem_write;
		input  [15:0] addr;
		input  [ 7:0] data;
		output [18:0] pa;
		output        we;
		begin
			a = addr; d = data; mreq = 1'b0; wr = 1'b0;
			tick(TQ);
			pa = memA; we = memWr;
			mreq = 1'b1; wr = 1'b1;
			tick(TQ);
		end
	endtask

	// OUT (n),A - старший байт адреса РАВЕН выводимому байту (так работает Z80, и ровно из-за
	// этого OUT (#E3),#E4 попадал в дешифратор EFF7).
	// ВНИМАНИЕ: цикл ввода-вывода держится ДОЛЬШЕ периода ce (16 тактов), иначе защёлки 7FFD/EFF7,
	// живущие под `else if(ce)`, просто не увидят цикл - и стенд «докажет» несуществующий отказ.
	task out_na;
		input [7:0] port;
		input [7:0] data;
		begin
			a = {data, port}; d = data; iorq = 1'b0; wr = 1'b0;
			tick(24);
			iorq = 1'b1; wr = 1'b1;
			tick(24);
		end
	endtask

	// OUT (C),r - полный 16-битный адрес.
	task out_bc;
		input [15:0] port;
		input [7:0]  data;
		begin
			a = port; d = data; iorq = 1'b0; wr = 1'b0;
			tick(24);
			iorq = 1'b1; wr = 1'b1;
			tick(24);
		end
	endtask

	task do_reset;
		begin
			reset = 1'b0; tick(4); reset = 1'b1; tick(4);
		end
	endtask

	// ---- ожидаемые физические адреса ----------------------------------------------------------
	// ПЗУ машины: {2'b00, 1'b0, romPage, a[13:0]}
	function [18:0] pa_rom; input [1:0] pg; input [15:0] addr;
		pa_rom = {2'b00, 1'b0, pg, addr[13:0]};
	endfunction
	// ПЗУ DivMMC = страница ПЗУ 2, младшие 8 КБ
	function [18:0] pa_esxrom; input [15:0] addr;
		pa_esxrom = {2'b00, 1'b0, 3'b100, addr[12:0]};
	endfunction
	// ОЗУ DivMMC: страница 0..15 по 8 КБ
	function [18:0] pa_esxram; input [3:0] pg; input [15:0] addr;
		pa_esxram = {2'b10, pg, addr[12:0]};
	endfunction
	// ОЗУ машины
	function [18:0] pa_ram; input [2:0] pg; input [15:0] addr;
		pa_ram = {2'b01, pg, addr[13:0]};
	endfunction

	//---------------------------------------------------------------------------------------------
	// НЕЗАВИСИМАЯ МОДЕЛЬ ПРЕЖНЕГО (до B0131) ПОВЕДЕНИЯ - для регрессии при mapper = 0.
	// Написана по формулам ДО правки и НЕ смотрит ни на один сигнал модуля, кроме входов шины.
	//---------------------------------------------------------------------------------------------
	reg [5:0] r7ffd = 6'd0;
	reg [2:0] rhi   = 3'd0;
	reg [7:0] reff7 = 8'd0;
	reg       rtrdos = 1'b0;
	reg       rmapOnIORQ = 1'b0;
	reg [7:0] rmapData = 8'd0;

	wire r_pent_ext  = pent1024 & model;
	wire r_page_lock = r_pent_ext ? (reff7[2] & r7ffd[5]) : r7ffd[5];
	// ПРЕЖНЕЕ (неполное) декодирование EFF7 - БЕЗ терма A4: именно оно обязано сохраниться при
	// выключенном DivMMC, иначе это уже другая машина.
	wire r_eff7_wr = !iorq && !wr && a[15] && a[14] && a[13] && !a[12] && !a[3] && r_pent_ext;
	always @(posedge clock, negedge reset)
	if(!reset) begin r7ffd <= 6'd0; rhi <= 3'd0; reff7 <= 8'd0; rmapOnIORQ <= 1'b0; end
	else if(force_7ffd && model) begin r7ffd <= port7ffd_in; rhi <= 3'd0; rmapOnIORQ <= 1'b0; end
	else if(ce) begin
		if(!iorq && !wr && !a[15] && !a[1] && model && !r_page_lock) begin
			rmapOnIORQ <= 1'b1; rmapData <= d;
		end
		if(r_eff7_wr) reff7 <= d;
		if(rmapOnIORQ) begin
			r7ffd <= rmapData[5:0];
			if(r_pent_ext && !reff7[2]) rhi <= {rmapData[5], rmapData[7:6]};
			rmapOnIORQ <= 1'b0;
		end
	end
	wire r_rom48 = model ? r7ffd[4] : 1'b1;
	always @(posedge clock)
	if(!reset || !trdos_en) rtrdos <= 1'b0;
	else if(!mreq && !m1) begin
		if(a[15:8] == 8'h3D && r_rom48) rtrdos <= 1'b1;
		else if(a[15] || a[14])         rtrdos <= 1'b0;
	end
	wire [1:0] r_romPage = rtrdos ? 2'd2 : service_en ? 2'd3 : (model ? {1'b0, r7ffd[4]} : 2'b01);
	wire [2:0] r_ramPage = a[15:14] == 2'b01 ? 3'd5 : a[15:14] == 2'b10 ? 3'd2
	                     : model ? r7ffd[2:0] : 3'd0;
	wire [2:0] r_bankHi;
	assign r_bankHi[0] = r_pent_ext & a[15] & a[14] & rhi[0] & ~ram_nobit[0];
	assign r_bankHi[1] = r_pent_ext & a[15] & a[14] & rhi[1] & ~ram_nobit[1];
	assign r_bankHi[2] = r_pent_ext & a[15] & a[14] & rhi[2] & ~ram_nobit[2];
	// ПРЕЖНИЕ memA/memWr при map = 0 (а при mapper = 0 map был нулём по построению).
	wire [18:0] ref_memA = (a[15] || a[14]) ? {2'b01, r_ramPage, a[13:0]}
	                                        : {2'b00, 1'b0, r_romPage, a[13:0]};
	wire        ref_memWr = !mreq && !wr && (a[15] || a[14]);
	wire [5:0]  ref_bank  = {r_bankHi, r_ramPage};

	// Живое сравнение: пока mapper = 0, расхождение ловится в ЛЮБОЙ такт, а не только там,
	// где стенд догадался посмотреть.
	integer n_reg_chk = 0, n_reg_fail = 0;
	reg reg_watch = 1'b0;
	always @(posedge clock) if (reg_watch && reset) begin
		n_reg_chk = n_reg_chk + 1;
		if (memA !== ref_memA || memWr !== ref_memWr || ram_bank !== ref_bank
		    || eff7_o !== reff7 || rom_page_o !== r_romPage || trdos_o !== rtrdos) begin
			n_reg_fail = n_reg_fail + 1;
			if (n_reg_fail < 6)
				$display("  FAIL регрессия: a=%04h memA=%05h/%05h memWr=%b/%b bank=%02h/%02h eff7=%02h/%02h romPg=%0d/%0d dos=%b/%b (t=%0t)",
				         a, memA, ref_memA, memWr, ref_memWr, ram_bank, ref_bank,
				         eff7_o, reff7, rom_page_o, r_romPage, trdos_o, rtrdos, $time);
		end
	end

	//---------------------------------------------------------------------------------------------
	integer i;
	reg [18:0] pa;
	reg        we;
	reg [18:0] pa2;

	initial begin
		$display("=== tb_divmmc_map: автомаппер и матрица памяти DivMMC (B0131) ===");

		//-----------------------------------------------------------------------------------------
		// C. РЕГРЕССИЯ: MACHINE_CFG[17] = 0 -> машина байт-в-байт прежняя
		//-----------------------------------------------------------------------------------------
		$display("-- C. Регрессия при DIVMMC = OFF (mapper = 0) --");
		mapper = 1'b0; dm_opt = 4'b1111; dm_pagein_off = 1'b1;  // опции подняты ВСЕ: не должны влиять
		trdos_en = 1'b1;                                        // и трап TR-DOS включён - он обязан жить
		do_reset;
		reg_watch = 1'b1;

		// прогон, который трогает всё сразу: страничность, EFF7, порт #E3, все входы автомаппера
		out_bc(16'h7FFD, 8'h00);
		mem_read(16'h0000, pa);  mem_read(16'h4000, pa);  mem_read(16'h8000, pa);  mem_read(16'hC000, pa);
		out_bc(16'h7FFD, 8'h10);                       // 48 BASIC в окно
		mem_read(16'h0000, pa);
		out_na(8'hE3, 8'h80);                          // МИНА 1: CONMEM при выключенном DivMMC
		mem_read(16'h0000, pa);
		mem_write(16'h2000, 8'h55, pa, we);
		out_na(8'hE3, 8'hC0);                          // + MAPRAM (липкий)
		mem_read(16'h0000, pa);
		mem_write(16'h2000, 8'hAA, pa, we);
		out_na(8'hE3, 8'hE4);                          // МИНА 2: и CONMEM, и «EFF7» из-за A3=0
		mem_read(16'h0000, pa);
		m1_fetch(16'h0000); m1_fetch(16'h0008); m1_fetch(16'h0038); m1_fetch(16'h0066);
		m1_fetch(16'h04C6); m1_fetch(16'h0562); m1_fetch(16'h3D13); m1_fetch(16'h1FFB);
		mem_read(16'h0000, pa);  mem_read(16'h2000, pa);
		out_bc(16'hEFF7, 8'h04);                       // настоящий EFF7: уход в стандартный режим
		out_bc(16'h7FFD, 8'hC7);                       // расширенные биты банка
		mem_read(16'hC000, pa);
		out_bc(16'hEFF7, 8'h00);
		out_bc(16'h7FFD, 8'hC7);
		mem_read(16'hC000, pa);
		for (i = 0; i < 64; i = i + 1) begin
			out_bc(16'h7FFD, i[7:0]);
			mem_read(16'h0000 + i[7:0], pa);
			mem_write(16'hC000, i[7:0], pa, we);
		end
		reg_watch = 1'b0;
		n_chk = n_chk + 1;
		if (n_reg_fail == 0) begin
			n_pass = n_pass + 1;
			$display("  PASS регрессия: %0d тактов сверено с независимой моделью, 0 расхождений", n_reg_chk);
		end else begin
			n_fail = n_fail + 1;
			$display("  FAIL регрессия: %0d расхождений на %0d тактов", n_reg_fail, n_reg_chk);
		end
		// Отдельными утверждениями - две мины B0130, они обязаны оставаться закрытыми
		ok(map_diag[7] === 1'b0, "MINE1: OUT (#E3),#80 with DIVMMC=OFF must not set CONMEM");
		ok(map_diag[4] === 1'b0, "MINE1: OUT (#E3),#C0 with DIVMMC=OFF must not set MAPRAM");
		mem_read(16'h0000, pa);
		eq19(pa, pa_rom(rom_page_o, 16'h0000), "MINE1: window 0x0000 still the machine ROM");
		trdos_en = 1'b0;

		//-----------------------------------------------------------------------------------------
		// B. Восемь входов и выходов автомаппера
		//-----------------------------------------------------------------------------------------
		$display("-- B. Входы и выходы автомаппера (M1) --");
		mapper = 1'b1; dm_opt = 4'b0000; dm_pagein_off = 1'b0;
		do_reset;
		out_bc(16'h7FFD, 8'h10);       // 48 BASIC в окне -> гейт входов открыт по первому терму
		tick(40);
		ok(map_diag[6] === 1'b0, "after reset automapper is off");
		mem_read(16'h0000, pa);
		eq19(pa, pa_rom(2'd1, 16'h0000), "before entry 0x0000 holds machine ROM (48 BASIC)");

		// 1. вход 0x0000 - ОТЛОЖЕННЫЙ: во время самой выборки память ещё машинная
		a = 16'h0000; m1 = 1'b0; mreq = 1'b0; rd = 1'b0; tick(TQ);
		eq19(memA, pa_rom(2'd1, 16'h0000), "entry 0x0000: DURING the fetch ROM is still the machine one");
		mreq = 1'b1; rd = 1'b1; m1 = 1'b1; rfsh = 1'b0; tick(2*TQ); rfsh = 1'b1; tick(TQ);
		ok(map_diag[6] === 1'b1, "entry 0x0000: automapper on after the fetch");
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "entry 0x0000: DivMMC ROM in the window (ROM page 2)");

		// 8. выход 0x1FF8..0x1FFF
		m1_fetch(16'h1FFB);
		ok(map_diag[6] === 1'b0, "exit 0x1FFB: automapper cleared");
		mem_read(16'h0000, pa);
		eq19(pa, pa_rom(2'd1, 16'h0000), "exit 0x1FFB: machine ROM is back");
		for (i = 0; i < 8; i = i + 1) begin
			m1_fetch(16'h0038);
			m1_fetch(16'h1FF8 + i[15:0]);
			ok(map_diag[6] === 1'b0, "exit: whole 0x1FF8..0x1FFF range unmaps");
		end

		// 2..6. отложенные входы
		m1_fetch(16'h1FFB); m1_fetch(16'h0008);
		ok(map_diag[6] === 1'b1, "entry 0x0008 (RST 8, esxDOS API)");
		m1_fetch(16'h1FFB); m1_fetch(16'h0038);
		ok(map_diag[6] === 1'b1, "entry 0x0038 (IM1)");
		m1_fetch(16'h1FFB); m1_fetch(16'h04C6);
		ok(map_diag[6] === 1'b1, "entry 0x04C6 (SA-BYTES)");
		m1_fetch(16'h1FFB); m1_fetch(16'h0562);
		ok(map_diag[6] === 1'b1, "entry 0x0562 (LD-BYTES)");

		// 4. 0x0066 - ТОЛЬКО по своей маске (MACHINE_CFG бит24)
		m1_fetch(16'h1FFB); m1_fetch(16'h0066);
		ok(map_diag[6] === 1'b0, "entry 0x0066 masked: NMI belongs to the magic button by default");
		dm_opt[2] = 1'b1;
		m1_fetch(16'h0066);
		ok(map_diag[6] === 1'b1, "entry 0x0066 opened by MACHINE_CFG bit24");
		dm_opt[2] = 1'b0;

		// 7. 0x3Dxx - МГНОВЕННЫЙ вход (Divide_pgm_model.txt:113-115)
		m1_fetch(16'h1FFB);
		a = 16'h3D13; m1 = 1'b0; mreq = 1'b0; rd = 1'b0; tick(2*TQ);
		ok(map_diag[6] === 1'b1, "entry 0x3Dxx: INSTANT, inside the same fetch");
		mreq = 1'b1; rd = 1'b1; m1 = 1'b1; rfsh = 1'b0; tick(2*TQ); rfsh = 1'b1; tick(TQ);
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "entry 0x3Dxx: DivMMC ROM in the window");

		// ГЕЙТ входов двумя термами: 128-меню в окне (не 48 BASIC) + предыдущая выборка ИЗ ПЗУ
		$display("-- B2. Гейт входов (basic48_paged || !rom_m1_access) --");
		m1_fetch(16'h1FFB);
		out_bc(16'h7FFD, 8'h00);          // страница ПЗУ 0 = 128-меню
		m1_fetch(16'h0100);               // предыдущая выборка ИЗ окна ПЗУ
		m1_fetch(16'h0008);
		ok(map_diag[6] === 1'b0, "gate: RST 8 from the 128 ROM must NOT enter esxDOS");
		m1_fetch(16'h8000);               // предыдущая выборка из ОЗУ
		m1_fetch(16'h0008);
		ok(map_diag[6] === 1'b1, "gate: RST 8 from RAM enters esxDOS (second term)");
		m1_fetch(16'h1FFB);
		m1_fetch(16'h0100);
		m1_fetch(16'h0000);
		ok(map_diag[6] === 1'b1, "gate: entry 0x0000 is never gated (machine start)");
		m1_fetch(16'h1FFB);
		m1_fetch(16'h0100); m1_fetch(16'h3D13);
		ok(map_diag[6] === 1'b0, "gate: 0x3Dxx from the 128 ROM is closed (live Sizif)");
		dm_opt[0] = 1'b1;                 // СНЯТЬ гейт (поведение Prato/MiSTer)
		m1_fetch(16'h0100); m1_fetch(16'h0008);
		ok(map_diag[6] === 1'b1, "opt18: gate removed - RST 8 works from the 128 ROM too");
		dm_opt[0] = 1'b0;
		m1_fetch(16'h1FFB);

		// ловушки ленты гасятся, пока лентой рулим мы
		out_bc(16'h7FFD, 8'h10);
		dm_pagein_off = 1'b1;
		m1_fetch(16'h0562);
		ok(map_diag[6] === 1'b0, "hook 0x0562 masked while our tape player runs");
		m1_fetch(16'h04C6);
		ok(map_diag[6] === 1'b0, "hook 0x04C6 masked as well");
		m1_fetch(16'h0038);
		ok(map_diag[6] === 1'b1, "... but 0x0038 still works (ONLY the tape hooks are masked)");
		dm_pagein_off = 1'b0;
		m1_fetch(16'h1FFB);

		//-----------------------------------------------------------------------------------------
		// A. Таблица приоритетов Divide_pgm_model.txt:137-153
		//-----------------------------------------------------------------------------------------
		$display("-- A. Матрица памяти: EPROM jumper -> MAPRAM -> CONMEM --");
		do_reset;
		out_bc(16'h7FFD, 8'h10);

		// A6. «Otherwise, there's normal speccy memory layout»
		mem_read(16'h0000, pa);
		eq19(pa, pa_rom(2'd1, 16'h0000), "A6: no CONMEM, no entry - machine ROM");
		mem_write(16'h2000, 8'h11, pa, we);
		ok(we === 1'b0, "A6: write to 0x2000 denied (machine ROM there)");
		mem_read(16'h4000, pa);
		eq19(pa, pa_ram(3'd5, 16'h4000), "A6: 0x4000 - machine bank 5");

		// A5. MAPRAM = 0, CONMEM = 0, вход пройден:
		//     0000-1FFF EPROM только на чтение, 2000-3FFF банк, всегда на запись
		m1_fetch(16'h0038);
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "A5: low window - DivMMC ROM");
		mem_write(16'h0000, 8'h22, pa, we);
		ok(we === 1'b0, "A5: DivMMC ROM is read-only");
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd0, 16'h2000), "A5: high window - DivMMC RAM page 0");
		mem_write(16'h2000, 8'h33, pa, we);
		ok(we === 1'b1, "A5: high window always writable");
		// страница выбирается битами 3:0 порта #E3
		out_na(8'hE3, 8'h0A);
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd10, 16'h2000), "A5: OUT (#E3),#0A -> page 10");
		mem_read(16'h3FFF, pa);
		eq19(pa, pa_esxram(4'd10, 16'h3FFF), "A5: end of the window, same page");
		// СТРАНИЦА ОБРЕЗАНА ДО 4 БИТ: #1F не должен уехать в мёртвый регион 2'b11
		out_na(8'hE3, 8'h1F);
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd15, 16'h2000), "A5: OUT (#E3),#1F -> page 15, NOT region 2'b11");
		ok(memA[18:17] === 2'b10, "A5: region stays esx (page truncated AT THE PORT)");
		out_na(8'hE3, 8'h00);

		// A2. CONMEM: 0000-1FFF EPROM, 2000-3FFF банк, ВСЕГДА на запись, независимо от automap
		m1_fetch(16'h1FFB);                      // автомаппер снят
		out_na(8'hE3, 8'h82);                    // CONMEM + страница 2
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "A2: CONMEM without automap - DivMMC ROM low");
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd2, 16'h2000), "A2: CONMEM - selected page high");
		mem_write(16'h2000, 8'h44, pa, we);
		ok(we === 1'b1, "A2: under CONMEM the high window is always writable");

		// A3. MAPRAM = 1, CONMEM = 0, вход пройден:
		//     0000-1FFF банк 3 ТОЛЬКО НА ЧТЕНИЕ, 2000-3FFF банк (если не 3 - на запись)
		out_na(8'hE3, 8'h42);                    // MAPRAM (липкий), CONMEM снят, страница 2
		m1_fetch(16'h0038);
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxram(4'd3, 16'h0000), "A3: MAPRAM - page 3 in the low window");
		mem_write(16'h0000, 8'h55, pa, we);
		ok(we === 1'b0, "A3: page 3 low is WRITE-PROTECTED");
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd2, 16'h2000), "A3: selected page 2 high");
		mem_write(16'h2000, 8'h66, pa, we);
		ok(we === 1'b1, "A3: a page other than 3 is writable");
		out_na(8'hE3, 8'h43);                    // та же страница 3 во ВТОРОЕ окно
		mem_write(16'h2000, 8'h77, pa, we);
		ok(we === 1'b0, "A3: page 3 protected through the high window too");
		mem_read(16'h2000, pa);
		eq19(pa, pa_esxram(4'd3, 16'h2000), "A3: and the address is right (page 3)");

		// A4. ГЛАВНОЕ: CONMEM ПЕРЕКРЫВАЕТ ЛИПКИЙ MAPRAM (Divide_pgm_model.txt:137-141)
		out_na(8'hE3, 8'h80);                    // CONMEM=1, MAPRAM остаётся поднятым (липкий)
		ok(map_diag[4] === 1'b1, "A4: MAPRAM is sticky - still set");
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "A4: CONMEM overrides MAPRAM - ROM low, NOT bank 3");
		mem_write(16'h2000, 8'h88, pa, we);
		ok(we === 1'b1, "A4: under CONMEM the high window is writable even with MAPRAM set");
		// ... и последовательность заливки системы из Divide_pgm_model.txt:93-96 целиком
		out_na(8'hE3, 8'h83);                    // CONMEM + страница 3
		mem_write(16'h2000, 8'h99, pa, we);
		ok(we === 1'b1, "A4: loading the system into page 3 under CONMEM is allowed");
		eq19(pa, pa_esxram(4'd3, 16'h2000), "A4: and it goes exactly to page 3");
		out_na(8'hE3, 8'h40);                    // снять CONMEM, MAPRAM остаётся
		m1_fetch(16'h0038);
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxram(4'd3, 16'h0000), "A4: after clearing CONMEM the low window is bank 3 again");
		mem_write(16'h0000, 8'hAA, pa, we);
		ok(we === 1'b0, "A4: and it is read-only again");

		// опция 23: снятая защита (поведение MiSTer)
		dm_opt[1] = 1'b1;
		mem_write(16'h0000, 8'hBB, pa, we);
		ok(we === 1'b1, "opt23: protection removed - page 3 writable (MiSTer)");
		dm_opt[1] = 1'b0;

		// опция 26: выход из MAPRAM по Prato
		ok(map_diag[4] === 1'b1, "opt26: MAPRAM is set before the write");
		out_na(8'hE3, 8'hC0);                    // %11xxxxxx
		ok(map_diag[4] === 1'b1, "opt26 off: %11xxxxxx does NOT clear MAPRAM (original)");
		dm_opt[3] = 1'b1;
		out_na(8'hE3, 8'hC0);
		ok(map_diag[4] === 1'b0, "opt26 on: %11xxxxxx clears MAPRAM (Prato mod)");
		ok(map_diag[7] === 1'b1, "opt26: and sets CONMEM");
		dm_opt[3] = 1'b0;

		//-----------------------------------------------------------------------------------------
		// D. Разведение с бета-диском и с портом EFF7 (решения владельца 13.08 + мина 2)
		//-----------------------------------------------------------------------------------------
		$display("-- D. Бета-диск и EFF7 при включённом DivMMC --");
		do_reset;
		trdos_en = 1'b1;                          // трап TR-DOS «включён» в настройках
		out_bc(16'h7FFD, 8'h10);
		m1_fetch(16'h8000);                       // зов из ОЗУ - гейт открыт вторым термом
		m1_fetch(16'h3D13);
		ok(trdos_o === 1'b0, "DIVMMC=ON: the 0x3Dxx trap must NOT page in TR-DOS");
		ok(map_diag[6] === 1'b1, "... DivMMC takes it instead (owner: no beta disk)");
		ok(rom_page_o === 2'd1, "machine ROM page did not move to TR-DOS (48 BASIC stays)");
		mem_read(16'h0000, pa);
		eq19(pa, pa_esxrom(16'h0000), "... and 0x0000 reads the DivMMC ROM (ROM page 2)");
		mapper = 1'b0;                            // выключаем DivMMC - бета-диск обязан ожить
		do_reset;
		out_bc(16'h7FFD, 8'h10);
		m1_fetch(16'h3D13);
		ok(trdos_o === 1'b1, "DIVMMC=OFF: the 0x3Dxx trap pages in TR-DOS again");
		mapper = 1'b1;
		tick(4);
		ok(trdos_o === 1'b0, "turning DivMMC on CLEARS the TR-DOS latch (else the window freezes)");
		trdos_en = 1'b0;

		// МИНА 2: OUT (#E3),#E4 не должен писать в EFF7 при включённом DivMMC
		do_reset;
		out_bc(16'hEFF7, 8'h00);
		out_na(8'hE3, 8'hE4);
		ok(eff7_o === 8'h00, "MINE2: OUT (#E3),#E4 with DIVMMC=ON must not write EFF7 (A4 term)");
		out_bc(16'hEFF7, 8'h04);
		ok(eff7_o === 8'h04, "MINE2: the real #EFF7 still writes as before");
		out_na(8'hE7, 8'hE0);
		ok(eff7_o === 8'h04, "MINE2: port #E7 (same A3=0) does not reach EFF7 either");

		//-----------------------------------------------------------------------------------------
		$display("=== ИТОГ: утверждений %0d, PASS %0d, FAIL %0d ===", n_chk, n_pass, n_fail);
		if (n_fail == 0) $display("=== tb_divmmc_map: PASS ===");
		else             $display("=== tb_divmmc_map: FAIL ===");
		$finish;
	end

endmodule
