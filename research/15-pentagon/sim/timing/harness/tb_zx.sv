//-------------------------------------------------------------------------------------------------
// tb_zx.sv - стенд ЦЕЛОЙ машины Atlas (sources/atlas_core/main.v) в xsim.
//
// Что внутри:
//   * такт мастера 56.6667 МГц и разрешения pe7M0/ne7M0/pe3M5/ne3M5 - ровно по clock_zx.v
//     (регистр ce по negedge, те же уравнения), MMCM в стенде нет;
//   * память машины - настоящий mem_zx_bulb.v (ROM_PAGES=4, как в топе) + поведенческая
//     модель PS DDR для банков 8..63 (нулевая задержка, mem_wait=0);
//   * все входы от ARM - константы с умолчаниями прошивки (см. README.md), часть - плюс-аргументы;
//   * счётчики: тактов мастера, пикселей (ne7M0), T-состояний процессора (pc3M5 = реально
//     исполненные, pe3M5 = какие были бы без контеншена), строк, кадров, прерываний;
//   * инициализация регистров без сброса (video.v и др.) в момент 0 - иначе весь стенд в x.
//
// Плюс-аргументы (все через -testplusarg NAME=VAL, run.sh добавляет сам):
//   MACHINE=48|128|PENT   модель: 48 -> model=0, 128 -> model=1, PENT -> model=1, pentagon=1
//   PROG=<file.bin> ORG=<hex>  бинарник в ОЗУ по ORG + JP ORG в байты 0..2 страниц ПЗУ 0 и 1
//   ROM=<file>            альтернативное ПЗУ: .hex -> $readmemh со страницы 0; иначе бинарник
//                         (16К -> в страницы 0 И 1; 32К -> 0,1; 64К -> 0..3)
//   RUNUS=<мкс>           длительность прогона (по умолчанию 45000)
//   RESETUS=<мкс>         длительность сброса (по умолчанию 5)
//   PINTV/PINTH/PAPERH/PAPERV  ручки Пентагона (умолчания 239/326/2/60)
//   PENT1024=0|1 SNOWOFF=0|1 ULALATE=0|1 MEMWAIT=0|1 WARPNC=0|1
//   NOREGINIT=1           не обнулять регистровый файл T80 через dirset во время сброса
//   PCTRACE=<N>           печатать адрес первых N выборок команд (M1)
//   CHECKMARK=1           после прогона проверить маркер 0x4000..0x40FF и бордюр (тест marker.asm)
//   QUIET=1               не печатать таблицу кадров
//   TRACEFROM=<мкс>       начинать след M1 (PCTRACE=N выборок) не раньше этого момента
//   ACKMON=1              печатать каждый цикл подтверждения прерывания и байт на шине в его nc3M5
//   DUMP=<hex>            в конце напечатать 32 байта ОЗУ/ПЗУ с этого адреса Z80
//   BUSMON=<hex> BUSMON2=<hex>  печатать каждый цикл чтения/записи в окне 64 байта от адреса
//   BUSALL=1              печатать ВСЕ циклы шины начиная с TRACEFROM (вместе с PCTRACE даёт полный след)
//-------------------------------------------------------------------------------------------------
`timescale 1ps/1fs

module tb_zx;

//------------------------------------------------------------------------- такты и разрешения
// 100 МГц * 34/3 / 20 = 56.666667 МГц -> период 17647.0588 пс, полупериод 8823.5294 пс.
localparam real HALF_PS = 8823.5294;
localparam real MCLK_PER_US = 56.6666667;   // тактов мастера в микросекунде

reg clock = 1'b0;
always #(HALF_PS) clock = ~clock;

reg aclk = 1'b0;                            // fclk100 (домен ARM) - только для моста дисковода
always #(5000.0) aclk = ~aclk;

// Копия clock_zx.v (ветка warp_l == 0), включая начальное ce = 1 и защёлку по negedge.
reg [3:0] ce = 4'd1;
reg ne14M = 1'b0, pe7M0 = 1'b0, ne7M0 = 1'b0, pe3M5 = 1'b0, ne3M5 = 1'b0;
always @(negedge clock) begin
	ce    <= ce + 1'd1;
	ne14M <= ~ce[0] & ~ce[1];
	pe7M0 <= ~ce[0] & ~ce[1] &  ce[2];
	ne7M0 <= ~ce[0] & ~ce[1] & ~ce[2];
	pe3M5 <= ~ce[0] & ~ce[1] & ~ce[2] &  ce[3];
	ne3M5 <= ~ce[0] & ~ce[1] & ~ce[2] & ~ce[3];
end

//------------------------------------------------------------------------- конфигурация
reg        model    = 1'b0;   // 0 = 48K, 1 = 128K
reg        pentagon = 1'b0;
reg        pent1024 = 1'b0;
reg [2:0]  ram_nobit = 3'd0;
reg        mem_wait = 1'b0;
reg        snow_off = 1'b1;
reg        ula_late = 1'b0;
reg [31:0] ula_tune = 32'd0;
reg        warp_nc  = 1'b0;
reg [8:0]  pent_int_v = 9'd239;
reg [8:0]  pent_int_h = 9'd326;
reg [8:0]  paper_h  = 9'd2;
reg [8:0]  paper_v  = 9'd60;

reg        reset_n  = 1'b0;   // main.reset активен НУЛЁМ (T80 RESET_n, memory.v if(!reset))
reg        nmi_n    = 1'b1;   // cpu.v: .nmi -> NMI_n, активен нулём
reg        dirset   = 1'b0;   // порт инжекции регистров T80 (ARM control plane): 1 = загрузить все регистры из dir

string  machine  = "48";
string  progfile = "";
string  romfile  = "";
integer org      = 32'h8000;
integer run_us   = 45000;
integer reset_us = 5;
integer tmp;
integer noreginit = 0, pctrace = 0, checkmark = 0, quiet = 0;
integer tracefrom_us = 0, n_trace = 0, dumpaddr = -1, ackmon = 0;
integer busmon = -1, busmon2 = -1;   // окна монитора шины (64 байта от адреса), -1 = выкл
integer busall = 0;                  // 1 = печатать ВСЕ циклы шины начиная с TRACEFROM (много вывода)

//------------------------------------------------------------------------- шины к памяти
wire        vmmCe;
wire [13:0] vmmA1, vmmA2;
wire [7:0]  vmmD;
wire        memCe, memRf, memRd, memWr;
wire [18:0] memA;
wire [5:0]  ram_bank;
wire [7:0]  eff7_o;
wire [7:0]  memD, memQ;

wire        blank, hsync, vsync, r, g, b, i;
wire [10:0] laudio, raudio;
wire        midi, cs, ck, mosi;
wire [211:0] reg_out;
wire        tape_sample, tape_sample_strobe, tape_di_bit, cpu_ten, rom_trap;
wire [5:0]  p7ffd_live;
wire [7:0]  map_diag_o;
wire [26:0] ula_diag_o;
wire [31:0] int_dbg0_o, int_dbg1_o, int_dbg2_o;
wire [12:0] scr_capA;
wire [7:0]  scr_capD;
wire        scr_capWe;
wire [2:0]  border_o;
wire [31:0] gs_stat, gs_stat2, gs_stat3, fdc_stat, fdc_stat2, rom_dbg_o, aud_dbg_o, nemo_stat, nemo_stat2;
wire [7:0]  gs_wq_din;
wire        gs_wq_we, trdos_o, page3_seen_o;
wire [1:0]  rom_page_o;

//------------------------------------------------------------------------- машина
main dut (
	.model(model), .pent1024(pent1024), .ram_nobit(ram_nobit), .mem_wait(mem_wait),
	.snow_off(snow_off), .pentagon(pentagon), .ula_late(ula_late), .ula_tune(ula_tune),
	.warp_nc(warp_nc), .pent_int_v(pent_int_v), .pent_int_h(pent_int_h),
	.paper_h(paper_h), .paper_v(paper_v),
	.zc_en(1'b0), .zc_turbo(1'b0), .mapper(1'b0), .dm_opt(4'd0), .dm_pagein_off(1'b0),
	.reset(reset_n), .nmi(nmi_n),
	.clock(clock), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5),
	.blank(blank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b), .i(i),
	.ear(1'b0), .laudio(laudio), .raudio(raudio), .midi(midi),
	.strb(1'b0), .make(1'b0), .code(8'h00),
	.joy1(8'h00), .joy2(8'h00),
	.cs(cs), .ck(ck), .miso(1'b1), .mosi(mosi),
	.vmmCe(vmmCe), .vmmA1(vmmA1), .vmmA2(vmmA2), .vmmD(vmmD),
	.memCe(memCe), .memRf(memRf), .memRd(memRd), .memWr(memWr), .memA(memA),
	.ram_bank(ram_bank), .eff7_o(eff7_o), .memD(memD), .memQ(memQ),
	.dirset(dirset), .dir(212'd0), .reg_out(reg_out),
	.force_7ffd(1'b0), .port7ffd_in(6'd0), .force_border(1'b0), .border_in(3'd0),
	.tape_sample(tape_sample), .tape_sample_strobe(tape_sample_strobe), .tape_di_bit(tape_di_bit),
	.cpu_ten(cpu_ten), .rom_trap(rom_trap), .p7ffd_live(p7ffd_live),
	.map_diag_o(map_diag_o), .ula_diag_o(ula_diag_o),
	.int_dbg0_o(int_dbg0_o), .int_dbg1_o(int_dbg1_o), .int_dbg2_o(int_dbg2_o),
	.scr_capA(scr_capA), .scr_capD(scr_capD), .scr_capWe(scr_capWe), .border_o(border_o),
	.trdos_en(1'b0), .service_en(1'b0), .dos_svc_en(1'b0), .svc_nmi_en(1'b0),
	.gs_en(1'b0), .gs_ctl(32'd0), .gs_ctl_we(1'b0), .gs_stat(gs_stat),
	.gs_wq_din(gs_wq_din), .gs_wq_we(gs_wq_we), .gs_wq_full(1'b0), .gs_wq_afull(1'b0),
	.gs_wq_drain(1'b0), .gs_stat2(gs_stat2), .gs_stat3(gs_stat3),
	.fdc_aclk(aclk), .fdc_ctl(32'd0), .fdc_ctl_we(1'b0), .fdc_data(8'd0), .fdc_data_we(1'b0),
	.fdc_stat(fdc_stat), .fdc_stat2(fdc_stat2), .bdi_always(1'b0), .saa_mode(2'd0),
	.trdos_o(trdos_o), .rom_page_o(rom_page_o), .rom_dbg_o(rom_dbg_o), .page3_seen_o(page3_seen_o),
	.aud_dbg_o(aud_dbg_o),
	.nemo_en(1'b0), .nemo_ctl(32'd0), .nemo_ctl_we(1'b0), .nemo_stat(nemo_stat), .nemo_stat2(nemo_stat2),
	.km_en(1'b0), .km_ctl(32'd0), .km_ctl_we(1'b0)
);

//------------------------------------------------------------------------- память (как в топе)
wire [19:0] ddr_addr;
wire [7:0]  ddr_wdata;
wire        ddr_rd, ddr_wr;
reg  [7:0]  ddr_rdata = 8'h00;

mem_zx #(.ROM_PAGES(4)) mem (
	.clock(clock),
	.memRf(memRf), .memRd(memRd), .memWr(memWr), .memA(memA), .ram_bank(ram_bank),
	.memQ(memQ), .memD(memD),
	.ddr_addr(ddr_addr), .ddr_wdata(ddr_wdata), .ddr_rd(ddr_rd), .ddr_wr(ddr_wr), .ddr_rdata(ddr_rdata),
	.vmmCe(vmmCe), .vmmA1(vmmA1), .vmmA2(vmmA2), .vmmD(vmmD),
	.rom_ld_clk(aclk), .rom_ld_we(1'b0), .rom_ld_addr(16'd0), .rom_ld_data(8'd0)
);

// Поведенческая модель окна PS DDR (1 МБ): банки Пентагона 8..63 и ОЗУ DivMMC. Нулевая
// задержка: байт готов через такт после ddr_rd, T80 берёт данные на nc3M5 много позже.
reg [7:0] ddr [0:1048575];
always @(posedge clock) begin
	if (ddr_wr) ddr[ddr_addr] <= ddr_wdata;
	if (ddr_rd) ddr_rdata <= ddr[ddr_addr];
end

//------------------------------------------------------------------------- счётчики
integer n_mclk = 0;      // тактов мастера
integer n_px   = 0;      // ne7M0 (пикселей 7 МГц)
integer n_pe   = 0;      // pe3M5 (T без контеншена)
integer n_pc   = 0;      // pc3M5 (реально исполненные T процессора)
integer n_m1   = 0;      // выборок команд (M1 c MREQ)
integer n_rd   = 0;      // циклов чтения памяти (memRd, по фронту)
integer n_wr   = 0;      // циклов записи памяти (memWr, по фронту)
integer n_iord = 0, n_iowr = 0;
integer n_irq_raw = 0;   // спадов Video.irq (сырой /INT ULA)
integer n_irq_cpu = 0;   // спадов cpu_irq (то, что видит T80)
integer n_intack  = 0;   // циклов подтверждения прерывания (!m1 && !iorq), по фронту
integer n_lines  = 0;    // начал строк (hc==0 на ce)
integer n_frames = 0;    // начал кадров (hc==0 && vc==0 на ce)
integer n_x_pc3  = 0;    // тактов с x на pc3M5 после сброса
integer n_x_d_m1 = 0;    // выборок с x на шине данных

reg memRd_d = 0, memWr_d = 0, m1cyc_d = 0, intack_d = 0, iord_d = 0, iowr_d = 0;
wire m1cyc  = ~dut.m1 & ~dut.mreq;
wire intack = ~dut.m1 & ~dut.iorq;
wire iord   = ~dut.iorq & ~dut.rd & dut.m1;
wire iowr   = ~dut.iorq & ~dut.wr;

always @(posedge clock) begin
	n_mclk = n_mclk + 1;
	if (ne7M0)      n_px = n_px + 1;
	if (pe3M5)      n_pe = n_pe + 1;
	if (dut.pc3M5 === 1'b1) n_pc = n_pc + 1;
	if (reset_n && $isunknown(dut.pc3M5)) n_x_pc3 = n_x_pc3 + 1;
	memRd_d <= memRd; memWr_d <= memWr; m1cyc_d <= m1cyc; intack_d <= intack; iord_d <= iord; iowr_d <= iowr;
	if (memRd & ~memRd_d) n_rd = n_rd + 1;
	if (memWr & ~memWr_d) n_wr = n_wr + 1;
	if (iord & ~iord_d)   n_iord = n_iord + 1;
	if (iowr & ~iowr_d)   n_iowr = n_iowr + 1;
	if (intack & ~intack_d) begin
		n_intack = n_intack + 1;
		if (ackmon) $display("[%0t] INT ACK #%0d: A=%04h (PC на шине) SP=%04h", $time, n_intack, dut.a, reg_out[63:48]);
	end
	if (ackmon && intack && dut.nc3M5 === 1'b1) $display("[%0t]   ACK nc3M5: d=%02h (вектор IM2 = байт на шине в защёлке T80)", $time, dut.d);
	if (m1cyc & ~m1cyc_d) begin
		n_m1 = n_m1 + 1;
		if (n_trace < pctrace && $time >= tracefrom_us * 1000000.0) begin
			n_trace = n_trace + 1;
			$display("[%0t] M1 #%0d PC=%04h SP=%04h", $time, n_m1, dut.a, reg_out[63:48]);
		end
	end
	// шина данных в момент защёлки T80 (nc3M5) при выборке команды
	if (m1cyc && dut.nc3M5 === 1'b1 && $isunknown(dut.d)) n_x_d_m1 = n_x_d_m1 + 1;
end

// Монитор шины: по концу каждого цикла чтения/записи в окне печатает адрес, байт (для чтения -
// тот, что стоял на d в ПОСЛЕДНИЙ nc3M5 цикла = момент защёлки DI у T80), тип цикла и состояние
// контеншена. Окна: BUSMON и BUSMON2, по 64 байта.
reg [7:0] mon_rd_d = 8'h00;  reg mon_rd_m1 = 1'b0;  integer mon_rd_nc = 0, mon_rd_pc = 0, mon_rd_pe = 0;
reg [7:0] mon_wr_q = 8'h00;  integer mon_wr_pc = 0, mon_wr_pe = 0;
reg [15:0] mon_a_rd = 16'd0, mon_a_wr = 16'd0;
function automatic bit in_win(input [15:0] a);
	in_win = (busall && ($time >= tracefrom_us * 1000000.0)) ||
	         ((busmon  >= 0) && (a >= busmon)  && (a < busmon  + 64)) ||
	         ((busmon2 >= 0) && (a >= busmon2) && (a < busmon2 + 64));
endfunction
always @(posedge clock) begin
	if (memRd & ~memRd_d) begin mon_rd_nc = 0; mon_rd_pc = 0; mon_rd_pe = 0; mon_a_rd = dut.a; mon_rd_m1 = ~dut.m1; end
	if (memRd) begin
		if (dut.nc3M5 === 1'b1) begin mon_rd_d = dut.d; mon_rd_nc = mon_rd_nc + 1; end
		if (dut.pc3M5 === 1'b1) mon_rd_pc = mon_rd_pc + 1;
		if (pe3M5) mon_rd_pe = mon_rd_pe + 1;
	end
	if (memRd_d & ~memRd && in_win(mon_a_rd))
		$display("[%0t] RD%s A=%04h D=%02h  nc3M5=%0d pc3M5=%0d pe3M5=%0d  hc=%0d vc=%0d contend=%b cpuck=%b",
			$time, mon_rd_m1 ? " M1" : "   ", mon_a_rd, mon_rd_d, mon_rd_nc, mon_rd_pc, mon_rd_pe,
			dut.Video.hCount, dut.Video.vCount, dut.contend, dut.cpuck);
	if (memWr & ~memWr_d) begin mon_wr_pc = 0; mon_wr_pe = 0; mon_a_wr = dut.a; end
	if (memWr) begin mon_wr_q = memQ; if (dut.pc3M5 === 1'b1) mon_wr_pc = mon_wr_pc + 1; if (pe3M5) mon_wr_pe = mon_wr_pe + 1; end
	if (memWr_d & ~memWr && in_win(mon_a_wr))
		$display("[%0t] WR    A=%04h Q=%02h  pc3M5=%0d pe3M5=%0d  hc=%0d vc=%0d contend=%b cpuck=%b",
			$time, mon_a_wr, mon_wr_q, mon_wr_pc, mon_wr_pe, dut.Video.hCount, dut.Video.vCount, dut.contend, dut.cpuck);
end

always @(negedge dut.Video.irq) if (reset_n) n_irq_raw = n_irq_raw + 1;
always @(negedge dut.cpu_irq)   if (reset_n) n_irq_cpu = n_irq_cpu + 1;

// Начало строки/кадра: на такте ne7M0, когда старое значение hc == 0 (оно живёт ровно один
// период ce). Все счётчики защёлкиваются в этот момент - наследники берут дельты.
event ev_line, ev_frame;
integer line_mclk0 = 0, line_px0 = 0, line_pe0 = 0, line_pc0 = 0;
integer frame_mclk0 = 0, frame_px0 = 0, frame_pe0 = 0, frame_pc0 = 0, frame_lines0 = 0;
integer last_line_mclk = 0, last_line_px = 0, last_line_pe = 0, last_line_pc = 0;
integer last_frame_mclk = 0, last_frame_px = 0, last_frame_pe = 0, last_frame_pc = 0, last_frame_lines = 0;
always @(posedge clock) if (ne7M0 && dut.Video.hc == 9'd0) begin
	last_line_mclk = n_mclk - line_mclk0; last_line_px = n_px - line_px0;
	last_line_pe = n_pe - line_pe0;       last_line_pc = n_pc - line_pc0;
	line_mclk0 = n_mclk; line_px0 = n_px; line_pe0 = n_pe; line_pc0 = n_pc;
	n_lines = n_lines + 1;
	-> ev_line;
	if (dut.Video.vc == 9'd0) begin
		last_frame_mclk = n_mclk - frame_mclk0; last_frame_px = n_px - frame_px0;
		last_frame_pe = n_pe - frame_pe0;       last_frame_pc = n_pc - frame_pc0;
		last_frame_lines = n_lines - 1 - frame_lines0;
		frame_mclk0 = n_mclk; frame_px0 = n_px; frame_pe0 = n_pe; frame_pc0 = n_pc; frame_lines0 = n_lines - 1;
		n_frames = n_frames + 1;
		-> ev_frame;
	end
end

// Положение спада /INT внутри кадра (в пикселях от начала кадра и координаты растра).
integer irq_px_in_frame = -1, irq_hc = -1, irq_vc = -1;
integer irq_mclk_prev = 0, irq_period_mclk = 0, irq_period_pe = 0, irq_pe_prev = 0;
always @(negedge dut.Video.irq) if (reset_n) begin
	irq_px_in_frame = n_px - frame_px0;
	irq_hc = dut.Video.hCount; irq_vc = dut.Video.vCount;
	irq_period_mclk = n_mclk - irq_mclk_prev; irq_mclk_prev = n_mclk;
	irq_period_pe = n_pe - irq_pe_prev; irq_pe_prev = n_pe;
end

//------------------------------------------------------------------------- утилиты
task automatic wait_frames(input integer n);
	integer k;
	begin for (k = 0; k < n; k = k + 1) @(ev_frame); end
endtask

task automatic wait_lines(input integer n);
	integer k;
	begin for (k = 0; k < n; k = k + 1) @(ev_line); end
endtask

task automatic wait_us(input real us);
	begin #(us * 1000000.0); end
endtask

// Индекс байта ОЗУ модели по адресу Z80 (раскладка memory.v: memA[16:0] = {ramPage, a[13:0]})
// с ТЕКУЩИМ 7FFD. Для 48К окно 0xC000 - банк 0.
function automatic integer ram_index(input integer addr);
	integer page;
	begin
		case (addr[15:14])
			2'b01: page = 5;
			2'b10: page = 2;
			2'b11: page = model ? dut.Memory.port7FFD[2:0] : 0;
			default: page = -1;
		endcase
		ram_index = (page < 0) ? -1 : page * 16384 + (addr & 16'h3FFF);
	end
endfunction

function automatic [7:0] peek(input integer addr);
	integer idx;
	begin
		idx = ram_index(addr);
		peek = (idx < 0) ? mem.rom[(model ? 0 : 1) * 16384 + (addr & 16'h3FFF)] : mem.ram[idx];
	end
endfunction

//------------------------------------------------------------------------- инициализация
integer k, fd, nbytes, romsz;
reg [7:0] fbuf [0:65535];

initial begin
	// --- плюс-аргументы
	if ($value$plusargs("MACHINE=%s", machine)) ;
	case (machine)
		"48":   begin model = 1'b0; pentagon = 1'b0; end
		"128":  begin model = 1'b1; pentagon = 1'b0; end
		"PENT": begin model = 1'b1; pentagon = 1'b1; end
		default: begin $display("MACHINE=%s не понято (48|128|PENT)", machine); $finish; end
	endcase
	if ($value$plusargs("PENT1024=%d", tmp)) pent1024 = tmp[0];
	if ($value$plusargs("SNOWOFF=%d", tmp))  snow_off = tmp[0];
	if ($value$plusargs("ULALATE=%d", tmp))  ula_late = tmp[0];
	if ($value$plusargs("MEMWAIT=%d", tmp))  mem_wait = tmp[0];
	if ($value$plusargs("WARPNC=%d", tmp))   warp_nc  = tmp[0];
	if ($value$plusargs("PINTV=%d", tmp))    pent_int_v = tmp[8:0];
	if ($value$plusargs("PINTH=%d", tmp))    pent_int_h = tmp[8:0];
	if ($value$plusargs("PAPERH=%d", tmp))   paper_h = tmp[8:0];
	if ($value$plusargs("PAPERV=%d", tmp))   paper_v = tmp[8:0];
	if ($value$plusargs("RUNUS=%d", run_us)) ;
	if ($value$plusargs("RESETUS=%d", reset_us)) ;
	if ($value$plusargs("ORG=%h", org)) ;
	if ($value$plusargs("PROG=%s", progfile)) ;
	if ($value$plusargs("ROM=%s", romfile)) ;
	if ($value$plusargs("NOREGINIT=%d", noreginit)) ;
	if ($value$plusargs("PCTRACE=%d", pctrace)) ;
	if ($value$plusargs("CHECKMARK=%d", checkmark)) ;
	if ($value$plusargs("QUIET=%d", quiet)) ;
	if ($value$plusargs("TRACEFROM=%d", tracefrom_us)) ;
	if ($value$plusargs("DUMP=%h", dumpaddr)) ;
	if ($value$plusargs("ACKMON=%d", ackmon)) ;
	if ($value$plusargs("BUSMON=%h", busmon)) ;
	if ($value$plusargs("BUSMON2=%h", busmon2)) ;
	if ($value$plusargs("BUSALL=%d", busall)) ;

	// --- регистры без сброса: в железе они стартуют чем попало, в xsim - x НАВСЕГДА.
	// video.v: счётчики растра и конвейер выборки
	dut.Video.hc = 9'd0;  dut.Video.hCount = 9'd0;
	dut.Video.vc = 9'd0;  dut.Video.vCount = 9'd0;
	dut.Video.fc = 5'd0;  dut.Video.fCount = 5'd0;
	dut.Video.dataEnable = 1'b0; dut.Video.videoEnable = 1'b0;
	dut.Video.dataInput = 8'd0;  dut.Video.attrInput = 8'd0;
	dut.Video.dataOutput = 8'd0; dut.Video.attrOutput = 8'd0;
	dut.Video.a = 13'd0;         dut.Video.q = 8'hFF;
	// main.v: контеншен и порт #FE
	dut.mreqt23iorqtw3 = 1'b0; dut.cpuck = 1'b0;
	dut.mic = 1'b0; dut.speaker = 1'b0; dut.border = 3'd7;
	// memory.v: защёлка данных 7FFD (применяется только вместе с mapOnIORQ, но пусть не x)
	dut.Memory.mapOnIORQData = 8'd0;
	// specdrum: только в звук
	dut.Specdrum.q = 8'd0;

	// --- ОЗУ модели: нули вместо x (в железе - мусор, но не x; иначе x расползается по T80)
	for (k = 0; k < 131072; k = k + 1) mem.ram[k] = 8'h00;
	for (k = 0; k < 16384;  k = k + 1) mem.scr[k] = 8'h00;
	for (k = 0; k < 1048576; k = k + 1) ddr[k] = 8'h00;

	// --- ПЗУ: mem_zx сам делает $readmemh("rom128.hex") в момент 0; наши правки - на 1 пс позже
	#1;
	if (romfile != "") begin
		if (romfile.len() > 4 && romfile.substr(romfile.len()-4, romfile.len()-1) == ".hex") begin
			$readmemh(romfile, mem.rom);
			$display("ROM: %s (hex) -> страницы с 0", romfile);
		end else begin
			fd = $fopen(romfile, "rb");
			if (fd == 0) begin $display("ROM: не открыть %s", romfile); $finish; end
			nbytes = $fread(fbuf, fd); $fclose(fd);
			if (nbytes == 16384) begin
				for (k = 0; k < 16384; k = k + 1) begin mem.rom[k] = fbuf[k]; mem.rom[16384 + k] = fbuf[k]; end
				$display("ROM: %s (bin, 16К) -> страницы 0 и 1", romfile);
			end else begin
				for (k = 0; k < nbytes && k < 65536; k = k + 1) mem.rom[k] = fbuf[k];
				$display("ROM: %s (bin, %0d байт) -> страницы с 0", romfile, nbytes);
			end
		end
	end
	if (progfile != "") begin
		fd = $fopen(progfile, "rb");
		if (fd == 0) begin $display("PROG: не открыть %s", progfile); $finish; end
		nbytes = $fread(fbuf, fd); $fclose(fd);
		for (k = 0; k < nbytes; k = k + 1) begin
			tmp = ram_index(org + k);
			if (tmp < 0) begin $display("PROG: адрес %04h - не ОЗУ", org + k); $finish; end
			mem.ram[tmp] = fbuf[k];
		end
		// JP ORG в байты 0..2 страницы 1 (48 BASIC - в неё стартует 48К) И страницы 0
		// (128-меню - в неё стартуют 128К и Пентагон, 7FFD=0 после сброса).
		mem.rom[0] = 8'hC3; mem.rom[1] = org[7:0]; mem.rom[2] = org[15:8];
		mem.rom[16384] = 8'hC3; mem.rom[16385] = org[7:0]; mem.rom[16386] = org[15:8];
		$display("PROG: %s, %0d байт по %04h; JP %04h записан в ПЗУ страниц 0 и 1", progfile, nbytes, org, org);
	end

	// --- регистровый файл T80. В стенде ep4spectrum его обнуляют иерархическим присваиванием в
	// RegsH/RegsL; у нас это Verilog -> VHDL, и xelab 2023.1 на такой записи ПАДАЕТ (SIGSEGV).
	// Поэтому используем штатный порт инжекции машины: T80_Reg грузит DIR при DIRSet=1 по любому
	// такту (без гейта сброса и CEN), dir = 0 -> BC/DE/HL/IX/IY и альтернативные = 0.
	// ACC/F/PC/SP/I/R сбрасывает сам RESET_n (у него приоритет над DIRSet в T80.vhd).
	if (!noreginit) begin
		wait_us(1.0);
		dirset = 1'b1;
		wait_us(1.0);
		dirset = 1'b0;
	end

	$display("tb_zx: MACHINE=%s model=%0d pentagon=%0d pent1024=%0d snow_off=%0d ula_late=%0d mem_wait=%0d warp_nc=%0d",
	         machine, model, pentagon, pent1024, snow_off, ula_late, mem_wait, warp_nc);
	$display("tb_zx: pent_int_v=%0d pent_int_h=%0d paper_h=%0d paper_v=%0d reset=%0d мкс run=%0d мкс",
	         pent_int_v, pent_int_h, paper_h, paper_v, reset_us, run_us);

	// --- сброс
	wait_us(reset_us);
	reset_n = 1'b1;
	$display("[%0t] сброс снят", $time);
	@(posedge clock); #1;
	$display("REG после сброса: AF=%04h AF'=%04h I=%02h R=%02h SP=%04h PC=%04h BC=%04h DE=%04h HL=%04h IX=%04h BC'=%04h DE'=%04h HL'=%04h IY=%04h IM=%0d IFF1=%b IFF2=%b (x = регистр не инициализирован)",
		reg_out[15:0], reg_out[31:16], reg_out[39:32], reg_out[47:40], reg_out[63:48], reg_out[79:64],
		reg_out[95:80], reg_out[111:96], reg_out[127:112], reg_out[143:128], reg_out[159:144], reg_out[175:160],
		reg_out[191:176], reg_out[207:192], reg_out[209:208], reg_out[210], reg_out[211]);
end

//------------------------------------------------------------------------- печать кадров
integer fr;
initial begin
	@(posedge reset_n);
	if (!quiet) $display("кадр |  мастер |  ne7M0 |  pe3M5 |  pc3M5 | строк | строка: мастер/px/pe/pc | INT: px_in_frame hc vc | период INT (мастер, pe)");
	forever begin
		@(ev_frame);
		if (!quiet && n_frames >= 2)
			$display("%4d | %7d | %6d | %6d | %6d | %5d | %5d/%3d/%3d/%3d | %6d %3d %3d | %7d %6d",
				n_frames - 1, last_frame_mclk, last_frame_px, last_frame_pe, last_frame_pc, last_frame_lines,
				last_line_mclk, last_line_px, last_line_pe, last_line_pc,
				irq_px_in_frame, irq_hc, irq_vc, irq_period_mclk, irq_period_pe);
	end
end

//------------------------------------------------------------------------- периодический след PC
initial begin
	@(posedge reset_n);
	forever begin
		wait_us(1000.0);
		$display("[%0t] t=%0d мкс PC=%04h SP=%04h HL=%04h 7FFD=%02h border=%0d M1=%0d rd=%0d wr=%0d io_rd=%0d io_wr=%0d irq_raw=%0d irq_cpu=%0d intack=%0d",
			$time, (n_mclk / MCLK_PER_US), reg_out[79:64], reg_out[63:48], reg_out[127:112], dut.Memory.port7FFD, border_o,
			n_m1, n_rd, n_wr, n_iord, n_iowr, n_irq_raw, n_irq_cpu, n_intack);
	end
end

//------------------------------------------------------------------------- конец прогона
integer bad, cnt_cpu;
initial begin
	@(posedge reset_n);
	wait_us(run_us);
	$display("================================================================");
	$display("ИТОГ (%s): прогон %0d мкс после сброса", machine, run_us);
	$display("  тактов мастера %0d, ne7M0 %0d, pe3M5 %0d, pc3M5 %0d, кадров %0d, строк %0d",
		n_mclk, n_px, n_pe, n_pc, n_frames, n_lines);
	$display("  последний кадр: мастер %0d, px %0d, pe3M5 %0d, pc3M5 %0d, строк %0d; строка: мастер %0d, px %0d, pe3M5 %0d",
		last_frame_mclk, last_frame_px, last_frame_pe, last_frame_pc, last_frame_lines, last_line_mclk, last_line_px, last_line_pe);
	$display("  прерываний: спадов Video.irq %0d, спадов cpu_irq %0d, подтверждений INT %0d (период INT: %0d мастер = %0d pe3M5)",
		n_irq_raw, n_irq_cpu, n_intack, irq_period_mclk, irq_period_pe);
	$display("  процессор: M1 %0d, чтений памяти %0d, записей %0d, IN %0d, OUT %0d, PC=%04h",
		n_m1, n_rd, n_wr, n_iord, n_iowr, reg_out[79:64]);
	$display("  x-контроль: тактов с x на pc3M5 после сброса %0d, выборок с x на d %0d", n_x_pc3, n_x_d_m1);
	if (dumpaddr >= 0) begin
		$write("  дамп %04h:", dumpaddr);
		for (k = 0; k < 32; k = k + 1) $write(" %02h", peek(dumpaddr + k));
		$display("");
	end
	if (checkmark) begin
		$write("  таблица IM2 6000..600F:"); for (k = 0; k < 16; k = k + 1) $write(" %02h", peek(16'h6000 + k)); $display("");
		$write("  обработчик 6161..616C:  "); for (k = 0; k < 12; k = k + 1) $write(" %02h", peek(16'h6161 + k)); $display("");
		$write("  начало программы %04h:  ", org); for (k = 0; k < 12; k = k + 1) $write(" %02h", peek(org + k)); $display("");
		bad = 0;
		for (k = 0; k < 256; k = k + 1)
			if (peek(16'h4000 + k) !== (k[7:0] ^ 8'hA5)) begin
				if (bad < 8) $display("  маркер: [%04h] = %02h, ожидалось %02h", 16'h4000 + k, peek(16'h4000 + k), k[7:0] ^ 8'hA5);
				bad = bad + 1;
			end
		cnt_cpu = peek(16'h7000) + 256 * peek(16'h7001);
		$display("  маркер 0x4000..0x40FF: %0d расхождений -> %s", bad, bad == 0 ? "PASS" : "FAIL");
		$display("  бордюр: %0d (ожидалось 2) -> %s", border_o, border_o == 3'd2 ? "PASS" : "FAIL");
		$display("  счётчик прерываний в ОЗУ (0x7000) = %0d; спадов Video.irq %0d, подтверждений %0d -> %s",
			cnt_cpu, n_irq_raw, n_intack, (cnt_cpu == n_intack && n_intack > 0) ? "PASS" : "FAIL");
	end
	$display("================================================================");
	$finish;
end

endmodule
