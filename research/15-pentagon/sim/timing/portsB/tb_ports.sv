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

// tb_ports.sv - стенд-наследник tb_zx.sv (sim/timing/harness) для измерений ПОРТОВ и плавающей
// шины. Отличия от харнеса (все добавления помечены "PORTS:"):
//   * EAR=0|1        - уровень входа ear (в харнесе константа 0);
//   * IOMON=1|2      - монитор циклов ввода-вывода: для каждого IN печатается адрес, байт на шине в
//                      момент защёлки T80 (последний nc3M5 цикла), число nc3M5 в цикле, координаты
//                      растра hCount/vCount и бумажные h_rel/v_rel в момент защёлки, расстояние от
//                      последнего спада Video.irq в тактах мастера (16 = 1 T) и в pe3M5, начало M1
//                      команды и начало IORQ; IOMON=2 печатает каждый nc3M5 цикла. OUT печатаются тоже;
//   * DUMPLEN=<n>    - длина дампа DUMP (в харнесе 32); DUMP2=<hex> - второй дамп той же длины.
// Остальное - байт в байт tb_zx.sv (список файлов, такты, память, умолчания входов).
module tb_ports;

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
reg        io_cont_early = 1'b0;   // TT48: вход B0154, стенд его не подключал (X травил contend)
reg        kj_en = 1'b0;             // B0175: джойстик Kempston (умолчание - нет, как на голом 48K)
reg [31:0] ula_tune2  = 32'd0;   // TT48: то же
reg        warp_nc  = 1'b0;
reg [8:0]  pent_int_v = 9'd239;
reg [8:0]  pent_int_h = 9'd326;
reg [8:0]  paper_h  = 9'd2;
reg [8:0]  paper_v  = 9'd60;

reg        reset_n  = 1'b0;   // main.reset активен НУЛЁМ (T80 RESET_n, memory.v if(!reset))
reg        nmi_n    = 1'b1;   // cpu.v: .nmi -> NMI_n, активен нулём
reg        dirset   = 1'b0;
reg        ear_r    = 1'b0;   // PORTS: вход ear (плюс-аргумент EAR)   // порт инжекции регистров T80 (ARM control plane): 1 = загрузить все регистры из dir

string  machine  = "48";
string  progfile = "";
string  romfile  = "";
integer org      = 32'h8000;
integer entry_pc = -1;
integer xmon = 0; reg xmon_done = 1'b0;
integer tmon = 0, tmon_left = 0;
integer femon = 0, femon_left = 0;
integer wt0 = 0, wt1 = 0;   // WTRACE: оконная трасса по каждому ne7M0 в [wt0, wt1] тактов от /INT (3-й кадр)
   // BORDMON: печатать каждую смену цвета бордюра (строка, hUla)
integer cmon = 0, cmon_left = 0, cont_t0 = 0, cont_len = 0;   // TT48: разложение цепочки прерывание -> тело по звеньям   // TT48: точка входа JP в ПЗУ (по умолчанию = org)
integer run_us   = 45000;
integer reset_us = 5;
integer tmp;
integer noreginit = 0, pctrace = 0, checkmark = 0, quiet = 0;
integer tracefrom_us = 0, n_trace = 0, dumpaddr = -1, ackmon = 0;
integer busmon = -1, busmon2 = -1;   // окна монитора шины (64 байта от адреса), -1 = выкл
integer busall = 0;
integer iomon = 0, dumplen = 32, dumpaddr2 = -1, scrfill = 0;   // PORTS                  // 1 = печатать ВСЕ циклы шины начиная с TRACEFROM (много вывода)

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
	.io_cont_early(io_cont_early), .ula_tune2(ula_tune2),
	.kj_en(kj_en),
	.warp_nc(warp_nc), .pent_int_v(pent_int_v), .pent_int_h(pent_int_h),
	.paper_h(paper_h), .paper_v(paper_v),
	.zc_en(1'b0), .zc_turbo(1'b0), .mapper(1'b0), .dm_opt(4'd0), .dm_pagein_off(1'b0),
	.reset(reset_n), .nmi(nmi_n),
	.clock(clock), .pe7M0(pe7M0), .ne7M0(ne7M0), .pe3M5(pe3M5), .ne3M5(ne3M5),
	.blank(blank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b), .i(i),
	.ear(ear_r), .laudio(laudio), .raudio(raudio), .midi(midi),
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

// PORTS: монитор ввода-вывода. Отсчёт - от последнего спада Video.irq (сырой /INT ULA):
// irq_*_fall снимаются в момент спада (NBA-область того же posedge, счётчики уже обновлены).
integer irq_mclk_fall = 0, irq_pe_fall = 0, irq_pc_fall = 0;
// Собственные счётчики монитора (my_*): инкремент в НАЧАЛЕ того же блока, что и снимки, поэтому
// внутри блока нет гонки с блоком счётчиков харнеса. Конвенция: значение ПОСЛЕ инкремента текущего
// posedge (то же, что видит блок спада irq, который срабатывает после NBA-обновления hCount).
integer my_mclk = 0, my_pe = 0, my_pc = 0;
integer irqmon = 0;   // PORTS: IRQMON=1 - печатать каждый спад Video.irq (метка времени, счётчики, hCount/vCount)
always @(negedge dut.Video.irq) if (reset_n) begin
	if (irqmon) $display("[%0t] IRQ fall: my_mclk=%0d (d=%0d) my_pe=%0d hCount=%0d vCount=%0d", $time, my_mclk, my_mclk - irq_mclk_fall, my_pe, dut.Video.hCount, dut.Video.vCount);
	irq_mclk_fall = my_mclk; irq_pe_fall = my_pe; irq_pc_fall = my_pc;
end
integer   io_nc = 0, io_mclk_start = 0, io_mclk_m1 = 0, io_pe_start = 0, io_pe_m1 = 0;
integer   io_mclk_l = 0, io_pe_l = 0, io_pc_l = 0, io_hc_l = 0, io_vc_l = 0, io_hrel_l = 0, io_vrel_l = 0;
integer   m1_mclk_last = 0, m1_pe_last = 0, n_io_rd_mon = 0;
reg [7:0] io_d_l = 8'h00, io_q_l = 8'h00;
reg [15:0] io_a_l = 16'd0;
reg       m1cyc_p = 1'b0, iord_p = 1'b0, iowr_p = 1'b0;
reg [7:0] iowr_q = 8'h00; reg [15:0] iowr_a = 16'd0; integer iowr_mclk = 0, iowr_hc = 0, iowr_vc = 0;
always @(posedge clock) begin
	my_mclk = my_mclk + 1; if (pe3M5) my_pe = my_pe + 1; if (dut.pc3M5 === 1'b1) my_pc = my_pc + 1;
	m1cyc_p <= m1cyc; iord_p <= iord; iowr_p <= iowr;
	if (m1cyc & ~m1cyc_p) begin m1_mclk_last = my_mclk; m1_pe_last = my_pe; end
	if (iord & ~iord_p) begin
		io_nc = 0; io_a_l = dut.a;
		io_mclk_start = my_mclk; io_pe_start = my_pe;
		io_mclk_m1 = m1_mclk_last; io_pe_m1 = m1_pe_last;
	end
	if (iord && dut.nc3M5 === 1'b1) begin
		io_nc = io_nc + 1;
		io_d_l = dut.d; io_q_l = dut.Video.q;
		io_mclk_l = my_mclk; io_pe_l = my_pe; io_pc_l = my_pc;
		io_hc_l = dut.Video.hCount; io_vc_l = dut.Video.vCount;
		io_hrel_l = dut.Video.h_rel; io_vrel_l = dut.Video.v_rel;
		if (iomon >= 2)
			$display("[%0t]   IORD nc3M5 #%0d: A=%04h d=%02h vduQ=%02h hc=%0d vc=%0d h_rel=%0d v_rel=%0d dT_mclk=%0d",
				$time, io_nc, dut.a, dut.d, dut.Video.q, dut.Video.hCount, dut.Video.vCount,
				dut.Video.h_rel, dut.Video.v_rel, my_mclk - irq_mclk_fall);
	end
	if (iord_p & ~iord) begin
		n_io_rd_mon = n_io_rd_mon + 1;
		if (iomon)
			$display("[%0t] IORD #%0d A=%04h D=%02h vduQ=%02h nc3M5=%0d | latch: hc=%0d vc=%0d h_rel=%0d v_rel=%0d | from INT: latch %0d mclk (%0d pe3M5, %0d pc3M5), IORQ start %0d mclk (%0d pe), M1 start %0d mclk (%0d pe)",
				$time, n_io_rd_mon, io_a_l, io_d_l, io_q_l, io_nc, io_hc_l, io_vc_l, io_hrel_l, io_vrel_l,
				io_mclk_l - irq_mclk_fall, io_pe_l - irq_pe_fall, io_pc_l - irq_pc_fall,
				io_mclk_start - irq_mclk_fall, io_pe_start - irq_pe_fall,
				io_mclk_m1 - irq_mclk_fall, io_pe_m1 - irq_pe_fall);
	end
	if (iowr & ~iowr_p) begin iowr_a = dut.a; iowr_mclk = my_mclk; end
	if (iowr) begin iowr_q = dut.q; iowr_hc = dut.Video.hCount; iowr_vc = dut.Video.vCount; end
	if (iowr_p & ~iowr && iomon)
		$display("[%0t] IOWR A=%04h Q=%02h hc=%0d vc=%0d from INT %0d mclk", $time, iowr_a, iowr_q, iowr_hc, iowr_vc, iowr_mclk - irq_mclk_fall);
end


// TT48: кто первым уводит contend в X
always @(posedge clock) if (reset_n && xmon && !xmon_done && $isunknown(dut.contend)) begin
	xmon_done <= 1'b1;
	$display("[%0t] X на contend: cpuck=%b flag=%b vduC=%b vduC_mem=%b vduC_io=%b memC=%b ioFE=%b dataEnable=%b hUla=%0d vUla=%0d a=%04h iorq=%b mreq=%b wr=%b m1=%b",
		$time, dut.cpuck, dut.mreqt23iorqtw3, dut.vduC, dut.vduC_mem, dut.vduC_io, dut.memC, dut.ioFE,
		dut.Video.dataEnable, dut.Video.hUla, dut.Video.vUla, dut.a, dut.iorq, dut.mreq, dut.wr, dut.m1);
end

// TT48: звенья цепочки от прерывания до тела. Печатаем T в pe3M5 ОТ СЫРОГО спада /INT.
reg m1cyc_tp = 1'b0, ackp = 1'b0;
// FEMON: где по растру ЛОЖИТСЯ каждая смена цвета бордюра. Это то, что видит глаз на мониторе:
// регистр `border` в main.v меняется на первом неостановленном такте цикла записи (s+d, B0174).
// Печатаем строку и hUla растра в момент смены - сравнивать с окном гашения (наше 316..411,
// Потапов 308..403, кристалл 320..415) и с положением шва на плате (x=25 <-> hUla 421).
// WTRACE: волна первого занятого доступа кадра. Печатается на каждом ne7M0 (отсчёт 7 МГц), пока
// такт от /INT (my_pe - irq_pe_fall) внутри окна. Нужно, чтобы увидеть, ПОЧЕМУ первый штраф строки
// начинается на такт позже и длится 6 при канонических 4 (cmondiff.py по тесту 3 занятому).
always @(posedge clock) if (reset_n && wt1 > 0 && dut.ne7M0 && n_irq_raw >= 3) begin
    if ((my_pe - irq_pe_fall) >= wt0 && (my_pe - irq_pe_fall) <= wt1)
        $display("[ВОЛНА] T=%0d h=%0d pe=%b cpuck=%b flag=%b mreq=%b m1=%b iorq=%b a=%04h cn_mem=%b memC=%b contend=%b pc3M5=%b",
            my_pe - irq_pe_fall, dut.Video.hUla, pe3M5, dut.cpuck, dut.mreqt23iorqtw3, dut.mreq, dut.m1, dut.iorq,
            dut.a, dut.vduC_mem, dut.memC, dut.contend, dut.pc3M5);
end
reg [2:0] femon_bd = 3'd7;
always @(posedge clock) if (reset_n && femon_left > 0) begin
    if (dut.border !== femon_bd) begin
        $display("[БОРДЮР] строка=%0d hUla=%0d цвет %0d->%0d", dut.Video.vCount, dut.Video.hUla, femon_bd, dut.border);
        femon_left = femon_left - 1;
    end
    femon_bd = dut.border;
end
// SMON: АБСОЛЮТНЫЕ такты процессора между двумя опорными M1. Нужен, чтобы сравнить пролог
// теста (вход 0x8000 -> первый HALT 0xC0AD) с независимым эталоном: на этом участке прерывания
// запрещены (DI стоит прямо на входе), поэтому участок чисто процессорный и сравним напрямую.
integer smon_t0 = -1;
reg m1cyc_sp = 1'b0;
always @(posedge clock) if (reset_n) begin
	m1cyc_sp <= m1cyc;
	if (m1cyc & ~m1cyc_sp) begin
		if (dut.a == 16'h8000 && smon_t0 == -1) begin
			smon_t0 = my_pe;
			$display("[ПРОЛОГ] вход 8000: my_pe=%0d", my_pe);
		end
		else if (dut.a == 16'hC0AD && smon_t0 >= 0) begin
			$display("[ПРОЛОГ] HALT c0ad: тактов от входа = %0d", my_pe - smon_t0);
			smon_t0 = -2;
		end
	end
end

always @(posedge clock) if (reset_n && tmon_left > 0) begin
	m1cyc_tp <= m1cyc; ackp <= (~dut.m1 & ~dut.iorq);
	if ((~dut.m1 & ~dut.iorq) & ~ackp) begin
		$display("[ЗВЕНО] подтверждение INT: T=%0d", my_pe - irq_pe_fall); tmon_left = tmon_left - 1;
	end
	if (m1cyc & ~m1cyc_tp)
		if (dut.a == 16'hF5F5 || dut.a == 16'hC0F3 || dut.a == 16'hC121 ||
		    dut.a == 16'hDDDD || dut.a == 16'h5B00 || dut.a == 16'hC12F) begin
			$display("[ЗВЕНО] M1 %04h: T=%0d", dut.a, my_pe - irq_pe_fall); tmon_left = tmon_left - 1;
		end
end

// TT48/CMON: каждый штраф контеншена. Длина считается в pe3M5 (свободных тактах процессора).
// считаем ТОЛЬКО с третьего прерывания: до него идёт копия тела харнесом, и отсчёт T бессмыслен
always @(posedge clock) if (reset_n && cmon_left > 0 && pe3M5 && n_irq_raw >= 3) begin
	if (dut.contend === 1'b0) begin
		if (cont_len == 0) cont_t0 = my_pe - irq_pe_fall;
		cont_len = cont_len + 1;
	end else if (cont_len != 0) begin
		$display("[ШТРАФ] T=%0d длина=%0d a=%04h mreq=%b iorq=%b m1=%b rd=%b wr=%b v=%0d h=%0d", cont_t0, cont_len, dut.a, dut.mreq, dut.iorq, dut.m1, dut.rd, dut.wr, dut.Video.vCount, dut.Video.hUla);
		cmon_left = cmon_left - 1; cont_len = 0;
	end
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
	if ($value$plusargs("ENTRY=%h", entry_pc)) ;   // TT48
	if ($value$plusargs("XMON=%d", xmon)) ;
	if ($value$plusargs("TMON=%d", tmon)) tmon_left = tmon;
	if ($value$plusargs("FEMON=%d", femon)) femon_left = femon;
	if ($value$plusargs("WT0=%d", wt0)) ;
	if ($value$plusargs("WT1=%d", wt1)) ;
	if ($value$plusargs("CMON=%d", cmon)) cmon_left = cmon;
	if ($value$plusargs("IOCONTEARLY=%d", tmp)) io_cont_early = tmp[0];
	if ($value$plusargs("KJ=%d", tmp)) kj_en = tmp[0];
	if ($value$plusargs("TUNE=%h", ula_tune)) ;
	if ($value$plusargs("TUNE2=%h", ula_tune2)) ;   // TT48: ловить первый X на contend
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
	if ($value$plusargs("EAR=%d", tmp)) ear_r = tmp[0];      // PORTS
	if ($value$plusargs("IOMON=%d", iomon)) ;                 // PORTS
	if ($value$plusargs("IRQMON=%d", irqmon)) ;               // PORTS
	if ($value$plusargs("DUMPLEN=%d", dumplen)) ;             // PORTS
	if ($value$plusargs("DUMP2=%h", dumpaddr2)) ;             // PORTS
	if ($value$plusargs("SCRFILL=%d", scrfill)) ;             // PORTS

	// --- регистры без сброса: в железе они стартуют чем попало, в xsim - x НАВСЕГДА.
	// video.v: счётчики растра и конвейер выборки
	dut.Video.hc = 9'd0;  dut.Video.hCount = 9'd0;
	dut.Video.vc = 9'd0;  dut.Video.vCount = 9'd0;
	dut.Video.fc = 5'd0;  dut.Video.fCount = 5'd0;
	dut.Video.dataEnable = 1'b0; dut.Video.videoEnable = 1'b0;
	dut.Video.dataInput = 8'd0;  dut.Video.attrInput = 8'd0;
	dut.Video.dataOutput = 8'd0; dut.Video.attrOutput = 8'd0;
	dut.Video.a = 13'd0;   // B0175: Video.q стал ПРОВОДОМ, инициализировать его нельзя
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
	// PORTS: SCRFILL=1 - заполнить экран (банк 5, 0x4000..0x5AFF) обратимым узором И в ОЗУ модели, И в
	// зеркале экрана mem.scr (видео читает ТОЛЬКО зеркало, mem_zx_bulb.v:186; зеркало пишется при записях
	// процессора, а мы кладём напрямую, чтобы не тратить ~100 мс машины на заливку кодом Z80):
	//   битмап: байт = { 0, y[7:6], колонка[4:0] }  (y[7:6] = a[12:11]) -> 0x00..0x5F
	//   атрибут: байт = { 1, строка[0], 0, колонка[4:0] } (строка[0] = a[5]) -> 0x80..0x9F / 0xC0..0xDF
	// 0xFF не встречается ни в одном байте, битмап и атрибут различимы по биту 7.
	if (scrfill) begin
		for (k = 0; k < 6144; k = k + 1) begin
			mem.ram[5 * 16384 + k] = {1'b0, k[12:11], k[4:0]};
			mem.scr[k]             = {1'b0, k[12:11], k[4:0]};
		end
		for (k = 6144; k < 6912; k = k + 1) begin
			mem.ram[5 * 16384 + k] = {1'b1, k[5], 1'b0, k[4:0]};
			mem.scr[k]             = {1'b1, k[5], 1'b0, k[4:0]};
		end
	end

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
			// TT48: зеркало экрана ULA - отдельный массив, PROG обязан заполнять и его
			if (org + k >= 16'h4000 && org + k < 16'h5B00) mem.scr[org + k - 16'h4000] = fbuf[k];
		end
		// JP ORG в байты 0..2 страницы 1 (48 BASIC - в неё стартует 48К) И страницы 0
		// (128-меню - в неё стартуют 128К и Пентагон, 7FFD=0 после сброса).
		if (entry_pc < 0) entry_pc = org;
		mem.rom[0] = 8'hC3; mem.rom[1] = entry_pc[7:0]; mem.rom[2] = entry_pc[15:8];
		mem.rom[16384] = 8'hC3; mem.rom[16385] = entry_pc[7:0]; mem.rom[16386] = entry_pc[15:8];
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
	if (dumpaddr >= 0) begin   // PORTS: длина DUMPLEN, по 32 байта в строке, второй дамп DUMP2
		for (k = 0; k < dumplen; k = k + 1) begin
			if (k % 32 == 0) $write("  дамп %04h:", dumpaddr + k);
			$write(" %02h", peek(dumpaddr + k));
			if (k % 32 == 31 || k == dumplen - 1) $display("");
		end
	end
	if (dumpaddr2 >= 0) begin
		for (k = 0; k < dumplen; k = k + 1) begin
			if (k % 32 == 0) $write("  дамп %04h:", dumpaddr2 + k);
			$write(" %02h", peek(dumpaddr2 + k));
			if (k % 32 == 31 || k == dumplen - 1) $display("");
		end
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
