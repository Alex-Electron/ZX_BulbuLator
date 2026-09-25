//-------------------------------------------------------------------------------------------------
module main
//-------------------------------------------------------------------------------------------------
(
	input  wire       model,  // 0 = 48K, 1 = 128K
	input  wire       pent1024, // 1 = Пентагон 1024: банк 6 бит (7FFD[7:5]) + порт EFF7; банки >=8 в DDR
	input  wire[ 2:0] ram_nobit, // B0120 маска ОТСУТСТВУЮЩИХ старших бит банка (MACHINE_CFG [16:14])
	input  wire       mem_wait, // 1 = память не готова (расширенный банк в DDR) -> ТАКТ ОЖИДАНИЯ процессора
	input  wire       snow_off, // 1 = ULA snow OFF (clean raster fetch); 0 = faithful 128 snow (default) - MACHINE_CFG bit4
	input  wire       io_cont_early, // B0154: 1 = окно контеншена ПОРТОВ как до B0154, на такт РАНЬШЕ
	input  wire       ff_attr,  // B0200: 1 = Пентагон отдаёт на чтение #xxFF атрибут (как Sizif-512), 0 = #FF (как MiSTer). MACHINE_CFG бит29
	input  wire       kj_en,        // B0175: джойстик Kempston ЕСТЬ (MACHINE_CFG бит28). На голом
	                                //        48K интерфейса нет, и порты с a[5]=0 обязаны отдавать
	                                //        плавающую шину - иначе тесты 35/36/37 Timing Tests 48K
	                                //        не сходятся: их тело грузит регистр B ПРЯМО С ШИНЫ и
	                                //        делает его старшим байтом порта для следующих чтений.
	                                 // (наследие; MACHINE_CFG бит27). Умолчание 0 = фаза настоящей машины:
	                                 // CONTP из ulatest3 на живом 48K показывает занятость с такта 14339,
	                                 // у нас до B0154 было 14338. Порог stime (память) при этом не двигается
	                                 // - у ветви памяти строб падает на T1, у ветви портов IORQ только на T2.
	                                //   Зачем опция, а не правка: эталон сам себе противоречит. Тест
	                                //   `contp` (ulatest3, порт #FFFE) на нашей плате считает доступ
	                                //   задержанным на тактах 14338..14343; «..######» из разбора
	                                //   Потапова требует 14339..14344 (на такт позже), а его же
	                                //   комментарий про то же измерение тем же тестом
	                                //   (`source/video.v:526`: «real machine contends through
	                                //   14457..14462») даёт НАШУ фазу (14457 = 14337 по модулю 8).
	                                //   Два его утверждения об одном измерении расходятся на 2 T в
	                                //   противоположные стороны. Умолчание 0 = как было.
	                                //   КОГДА ТРОГАТЬ: если софт, синхронизирующийся чтением портов
	                                //   в бумаге (тайминговые демки, ulatest3), показывает окно на
	                                //   такт раньше настоящей машины - поставить 1. Ветвь ПАМЯТИ бит
	                                //   не трогает, поэтому порог stime (14335) остаётся на месте.
	input  wire       pentagon, // 1 = Pentagon: 448x320 raster + NO memory contention (paging stays per `model`)
	input  wire       ula_late, // 1 = requested Sinclair ULA Type 2/Late profile
	input  wire[31:0] ula_tune, // B0157 primary live 48K timing controls
	input  wire[31:0] ula_tune2, // B0157 floating-bus/memory-contention/border-mode controls
	input  wire       warp_nc,  // 1 = CPU-only warp active: suppress memory contention so the 8x CPU is not stalled by 1x-ULA-timed wait-states (fixes WAV/turbo loads on contended 128K; visual during warp is don't-care)
	input  wire[8:0]  pent_int_v, // Pentium INT line (runtime-tunable)
	input  wire[8:0]  pent_int_h, // Pentium INT start hc (runtime-tunable)
	input  wire[8:0]  paper_h,    // live paper h start (left border)
	input  wire[8:0]  paper_v,    // live paper v start (top border)
	input  wire       zc_en,  // B0138: Z-Controller (порты #77/#57)
	input  wire       zc_turbo, // B0143: 1 = Turbo 28 MHz, 0 = Standard 3.5 MHz
	input  wire       mapper, // 0 = off, 1 = on (MACHINE_CFG бит17). B0131: этим же проводом
	                          //     гасится трап 0x3Dxx TR-DOS - решение владельца 13.08
	input  wire[ 3:0] dm_opt,        // B0131 опции DivMMC (MACHINE_CFG 18/23/24/26), НОЛЬ = спека
	input  wire       dm_pagein_off, // B0131 1 = ловушки ленты 04C6/0562 НЕ отдавать DivMMC

	input  wire       reset,  // signals
	input  wire       nmi,

	input  wire       clock,  // clock 56 MHz
	input  wire       pe7M0,
	input  wire       ne7M0,
	input  wire       pe3M5,
	input  wire       ne3M5,

	output wire       blank,  // video
	output wire       hsync,
	output wire       vsync,
	output wire       r,
	output wire       g,
	output wire       b,
	output wire       i,

	input  wire       ear,    // audio
	output wire[10:0] laudio,
	output wire[10:0] raudio,
	output wire       midi,

	input  wire       strb,   // keyboard
	input  wire       make,
	input  wire[ 7:0] code,

	input  wire[ 7:0] joy1,   // joystick
	input  wire[ 7:0] joy2,

	output wire       cs,     // uSD
	output wire       ck,
	input  wire       miso,
	output wire       mosi,

	output wire       vmmCe,  // video memory
	output wire[13:0] vmmA1,
	output wire[13:0] vmmA2,
	input  wire[ 7:0] vmmD,

	output wire       memCe,  // cpu memory
	output wire       memRf,
	output wire       memRd,
	output wire       memWr,
	output wire[18:0] memA,
	output wire[ 5:0] ram_bank, // полный 6-битный банк ОЗУ текущего доступа (для маршрутизации BRAM/DDR)
	output wire[ 7:0] eff7_o,   // живой EFF7 (приборная проверка страничности Пентагона)
	input  wire[ 7:0] memD,
	output wire[ 7:0] memQ,

	input  wire        dirset,        // ARM control plane: register injection + port overrides
	input  wire[211:0] dir,
	output wire[211:0] reg_out,
	input  wire        force_7ffd,
	input  wire[ 5:0]  port7ffd_in,
	input  wire        force_border,
	input  wire[ 2:0]  border_in,

	output wire        tape_sample,       // 1 during an IN from port 0xFE (loader reading the ear) - drives smart warp
	output wire        tape_sample_strobe,// exact CEN_n phase of an IN-FE; T80 latches DI here
	output wire        tape_di_bit,       // actual bit 6 offered to the CPU on an IN-FE
	output wire        cpu_ten,           // contended CPU T-state enable (pc3M5) - the REAL CPU advance rate; tape/sampling lock to this (128K contention-aware)
	output wire        rom_trap,          // ROM-trap (#65): M1 fetch of LD-BREAK (0x056B) with the 48K loader ROM paged -> Fuse-style instant tape load
	output wire [5:0]  p7ffd_live,        // live 128K paging latch (bit4 = 48K ROM paged) - trap condition + ARM IX->bank map
	output wire [7:0]  map_diag_o,        // passive automapper state (B0048 trace only)
	output wire [26:0] ula_diag_o,        // passive raster/IRQ/contention state (B0048 trace only)
	output wire [31:0] int_dbg0_o,        // B0053 passive interrupt trace, exposed through REG4 while ROMTRAP=0
	output wire [31:0] int_dbg1_o,        // B0053 raster/ack trace, REG5
	output wire [31:0] int_dbg2_o,        // B0053 PC/R/address at interrupt acknowledge, REG6
	// BulbuLator screen-mirror tap (raw ZX screen -> fabric BRAM in the top; read via AXI-GP, off the DDR path)
	output wire [12:0] scr_capA,          // ULA fetch address: bitmap 0x0000..0x17FF + attr 0x1800..0x1AFF (6912 bytes)
	output wire [7:0]  scr_capD,          // fetched screen byte (from the displayed bank -> 128K shadow handled for free)
	output wire        scr_capWe,         // strobe: (scr_capA, scr_capD) valid this cycle (parent gates with ne7M0)
	output wire [2:0]  border_o,          // live ULA border colour (parent samples per-scanline for the loading stripes)
	// --- B0071: страничность ПЗУ на 4 страницы + трап входа в TR-DOS ---
	input  wire        trdos_en,          // 1 = трап Beta Disk включён (MACHINE_CFG бит8)
	input  wire        service_en,        // 1 = сервисная страница ПЗУ в окне (MACHINE_CFG бит9)
	input  wire        dos_svc_en,        // B0146: 1 = под TR-DOS страницу задаёт пара {DOS, 7FFD[4]}
	                                     //        (MACHINE_CFG бит25) - вход в менеджер сервисной страницы
	input  wire        svc_nmi_en,       // B0101: 1 = магическая кнопка (MACHINE_CFG бит13):
	input  wire        gs_en,         // General Sound: карта включена (иначе порты не наши)
	input  wire [31:0] gs_ctl,        // от ARM: {en[31], b7[30], b0[29], эхо ev0/ev7/er7[28:26],
	                                  //          B0107: ЗЕРКАЛО состояния эмулятора + dout[7:0]
	input  wire        gs_ctl_we,     //          B0106: ТОГГЛ из домена оболочки, не импульс
	output wire [31:0] gs_stat,       // к ARM:  {ovr7[31], ovr0[30], er7[28], ev0[26], b7[22],
	                                  //          b0[21], outp[20], cmd[15:8], последний байт[7:0]}
	output wire [7:0]  gs_wq_din,     // B0108: байт из #B3 в упругую очередь (см. ниже, зачем)
	output wire        gs_wq_we,
	input  wire        gs_wq_full,    //         НАСТОЯЩАЯ полнота - только для липкого признака потери
	input  wire        gs_wq_afull,   // B0118:   ВЕРХНИЙ ПОРОГ очереди. B0119: это уже НЕ флаг для
	                                  //          машины, а условие ТАКТОВ ОЖИДАНИЯ (см. gs_flow.v)
	input  wire        gs_wq_drain,   // B0119:   оболочка вынула байт - признак жизни для сторожа
	output wire [31:0] gs_stat2,      // B0119:   {потеряно байт[27:16], удержаний шины[11:0]}
	output wire [31:0] gs_stat3,      // B0119:   {сторож[31:30], тактов процессора в ожидании[19:0]}
	                                     //     сервисная страница по NMI, снятие по опкоду RETN
	// --- B0075 ДИСКОВОД: Beta Disk живёт ВНУТРИ машины (как AY/SAA), потому что шина данных
	//     процессора собирается здесь одним мультиплексором; наружу идёт только мост к ARM. ---
	input  wire        fdc_aclk,          // такт ARM (fclk100)
	input  wire [31:0] fdc_ctl,           // 0x164 FDC_CTL
	input  wire        fdc_ctl_we,
	input  wire [7:0]  fdc_data,          // 0x168 FDC_DATA (байт сектора)
	input  wire        fdc_data_we,
	output wire [31:0] fdc_stat,          // 0x160 FDC_STAT
	output wire [31:0] fdc_stat2,         // 0x16C FDC_STAT2 (команда/дорожка/сектор от TR-DOS)
	input  wire        bdi_always,        // B0079 A/B: BDI ports stay visible outside TR-DOS ROM
	input  wire [1:0]  saa_mode,          // B0087: SAA1099 на #FF - 0 AUTO / 1 ON / 2 OFF (MACHINE_CFG [12:11])
	output wire        trdos_o,           // живая защёлка DOS   -> MACH_DBG
	output wire [1:0]  rom_page_o,        // живая страница ПЗУ  -> MACH_DBG
	output wire [31:0] rom_dbg_o,         // B0147 прибор трапа  -> 0x1BC ROM_DBG
	output wire        page3_seen_o,      // B0147 липко: слот 3 был в окне -> MACH_DBG бит12
	output wire [31:0] aud_dbg_o,         // B0088: 0x170 AUD_DBG - пики по источникам звука
	// --- NEMO-IDE (B0112): регистры в фабрике, «диск» на ARM ---
	input  wire        nemo_en,           // интерфейс включён опцией машины
	input  wire [31:0] nemo_ctl,          // от ARM: {буфер: адрес+байт, статус, ошибка, владение}
	input  wire        nemo_ctl_we,       //          тоггл из домена оболочки
	output wire [31:0] nemo_stat,         // к ARM: {строб[31], slave[30], rptr[29:21], cmd[15:8], lba0[7:0]}
	output wire [31:0] nemo_stat2,        // к ARM: {head[31:24], lba2, lba1, lba0} - полный адрес
	// --- МЫШЬ KEMPSTON (B0116): три порта на чтение в фабрике, координаты считает ARM ---
	input  wire        km_en,             // мышь включена опцией машины (бит 31 слова 0x190)
	input  wire [31:0] km_ctl,            // от ARM: {en[31], кнопки[18:16], Y[15:8], X[7:0]}
	input  wire        km_ctl_we          //          тоггл из домена оболочки
);
//-------------------------------------------------------------------------------------------------

wire m1;   // M1_n процессора (АКТИВЕН НИЗКИМ). Объявлен здесь, потому что ниже его
           // читает `vduC_acc` - выбор окна штрафа для выборки команды (B0180).
reg mreqt23iorqtw3;
always @(posedge clock) if(pc3M5) mreqt23iorqtw3 <= mreq & ioFE;

/* B0183 ПРИБОР: ПРИВЯЗКА `cpuck` К СЧЁТЧИКУ ULA (порт эталона MiSTer).
   `cpuck` у нас - СВОБОДНО БЕГУЩИЙ делитель: пока штрафов нет, его фаза относительно растра ничем
   не закреплена. Каждый штраф защёлкивает процессор в сетку окна, поэтому ошибается РОВНО ОДИН
   доступ за кадр - первый занятый после долгого свободного бега по бордюру. Измерено на стенде
   (тест 3 занятый, CMON): он получает штраф 6 при каноническом 4, все остальные 2929 штрафов кадра
   канонические. Эти 2 такта за кадр и дают dR=-1..-2 в тестах 2, 3, 17, 18, 27 занятых.
   Эталон (cores/zx-mister/rtl/ula.sv:255-263):
       wire next_clk = hc_next[0] | (mZX & ulaContend & (memContend | ioContend));
       if(ce_7mn) CPUClk <= next_clk;
   то есть БЕЗ штрафа CPUClk РАВЕН чётности счётчика, а не переключается сам по себе.
   Ручка: ula_tune2[22] = привязка включена, [23] = полярность (эталон берёт hc_next, у нас под рукой
   hCount, поэтому полярность выбирается измерением). Умолчание 0 = поведение прежнее в точности. */
wire[8:0]  vdu_dbg_h, vdu_dbg_v;
wire ck_lock_en = ula_tune2[22];
wire ck_lock_ph = ula_tune2[23];
wire ck_lock_v  = ck_lock_ph ? ~vdu_dbg_h[0] : vdu_dbg_h[0];
reg cpuck;
always @(posedge clock) if(ne7M0) cpuck <= ck_lock_en ? (ck_lock_v | ~contend)
                                                      : !(cpuck && contend);

// B0154: окно занятости шины для ветви ВВОДА-ВЫВОДА можно задержать на такт (две ступени по ne7M0 =
// 2 px = 1 T) независимо от ветви ПАМЯТИ. При io_cont_late = 0 выражение тождественно прежнему -
// этим и проверяется правка (стенд обязан дать те же числа, что до неё).
wire tune_en = ula_tune[31] && !model && !pentagon;
reg [7:0] vduC_io_sr = 8'h00;
always @(posedge clock) if(ne7M0) begin
    vduC_io_sr <= {vduC_io_sr[6:0], vduC};
end
// Historical bit27 contract: 1 = raw/early vduC (B0153), 0 = delayed tap2 (B0154).
// 🥇 B0158: умолчание окна контеншена ПОРТОВ вернулось на такт позже (наша C2, принятая на живой
// машине: CONTP из ulatest3 даёт первый занятый такт 14339, ранняя фаза давала 14338). В B0157
// умолчание было 3'd0 = сырое раннее окно, то есть поведение B0153, и приёмка не выполнялась.
// Бит27 MACHINE_CFG (`io_cont_early`) снова живой: он возвращает раннюю фазу для A/B с хоста -
// именно этим переключателем 31.08 доказали, что регрессию даёт C2, а не C1.
// ⚠ tap = 2, а НЕ 1: одна ступень регистра тактируется по ne7M0, то есть даёт ПОЛТАКТА (1 px).
// У B0154 задержка была двумя ступенями = 2 px = ровно 1 такт. Стенд поймал это до сборки:
// с tap 1 первый занятый такт CONTP совпадал, а длительности стопа - нет (5/2 вместо 6/3).
// B0170: УМОЛЧАНИЕ ОКНА КОНТЕНШЕНА ПОРТОВ ВЕРНУЛОСЬ В НОЛЬ (как было до B0154).
// B0154 сдвинул это окно на такт позже ради приёмочного CONTP (первый занятый такт 14339 вместо
// 14338). Цена вскрылась только 08.09 и оказалась велика: бордюрные строки контеншена не имеют,
// но общий заряд за кадр от этого сдвига меняется, вход в HALT уезжает, а выход из HALT квантован
// по 4 такта - и весь код после него прыгает на 8 пикселей. На экране это верхняя полоса квадратов,
// уехавшая вправо (жалобы владельца по esh1_48 и esh2_48).
// ИЗМЕРЕНО, а не предположено:
//   * бисект по ядрам на карте: B0153 даёт одну пару переходов (правильно), B0154 - две,
//     разошедшиеся на 8 px. Владелец подтвердил глазом: на B0153 esh1 идёт правильно;
//   * A/B битом 27 на живой плате, три цикла подряд: позднее окно = 11 правильных строк + 10
//     сдвинутых, раннее = 21 правильная и НИ ОДНОЙ сдвинутой (число строк сохраняется);
//   * esh2_48 честным кадром против ZEsarUX: позднее окно - 20 расходящихся строк из 304,
//     раннее - 0 из 304, совпадение 100 %;
//   * заряд контеншена при этом остаётся каноническим 6,5,4,3,2,1,0,0 (стенд, по одному доступу
//     в кадре, NT=1, отдельный прогон на каждый такт окна - свипы с NT>1 тут врут).
// ЧЕМ ПОДТВЕРЖДЕНО СНАРУЖИ: у Потапова (vertohod/ep4spectrum, `source/video.v:542-545`) io_base = 0
// на ВСЕХ машинах, а прежние 32 counts на 48K/128K он называет ротацией окна ввода-вывода и убрал
// как дефект. То есть к нулю пришли независимо и с двух сторон.
// ЦЕНА, ЗАПИСАННАЯ ЧЕСТНО: CONTP становится 14338 вместо принятого 14339 (стенд, зонд MODE 1).
// Прежняя фаза осталась переключателем: `io_cont_early = 0` (бит27 MACHINE_CFG снят) даёт tap 2.
// Когда нужна прежняя: если понадобится воспроизвести приёмку CONTP 14339..14344 в том виде,
// в каком она снималась до 08.09. Для демок и для картинки нужен НОЛЬ.
wire [2:0] io_cont_tap = tune_en ? ula_tune[6:4] : (io_cont_early ? 3'd2 : 3'd0);
wire [2:0] mem_cont_tap = tune_en ? ula_tune2[4:2] : 3'd0;
wire vduC_io = (io_cont_tap == 3'd0) ? vduC : vduC_io_sr[io_cont_tap - 1];
// B0179: база для ПАМЯТИ - отдельное окно `cn_mem` со своей фазой (video.v). Ручка
// `mem_cont_tap` осталась дополнительной задержкой поверх него для лаборатории.
reg [7:0] vduC_mem_sr = 8'h00;
always @(posedge clock) if(ne7M0) vduC_mem_sr <= {vduC_mem_sr[6:0], vduC_mem_raw};
wire vduC_mem = (mem_cont_tap == 3'd0) ? vduC_mem_raw : vduC_mem_sr[mem_cont_tap - 1];
wire vduC_m1  = vduC_m1_raw;   // B0180: у выборки команды своя фаза (video.v, ula_tune2[20:16])
/* 🥇 B0180 У ВЫБОРКИ КОМАНДЫ И У ДАННЫХ ФАЗА ШТРАФА РАЗНАЯ.
   Найдено СОСТАВОМ провалов, а не рассуждением: свип фазы окна памяти показал, что при 1 такте
   валятся тесты 3, 5, 13, 14, 20 (`NOP`, `LD r,r`, `EXX`, `BIT b,r`, `SET/RES b,r` - команды почти
   без обращений к данным, один M1) и все с dR = -1, а при 2 тактах валятся 9, 11, 23, 24
   (`LD HL,(nn)`, `PUSH/CALL`, `(IX+n)` - по несколько доступов к данным) и все с dR = +1.
   То есть одна фаза не может удовлетворить обе группы: они тянут в разные стороны.
   `m1` активен НИЗКИМ (`M1_n`), поэтому выборка команды = `~m1`. */
/* ⚠ ПЕТЛЮ РАЗРЫВАЕМ РЕГИСТРОМ. `contend` комбинационно питает `pc3M5` (:247), который тактирует
   процессор, поэтому заводить в `contend` его же выход `m1` напрямую нельзя - получается
   комбинационное кольцо, и xsim роняет элаборацию невнятным «Failed to compile generated C file».
   Берём копию на МАСТЕР-такте: задержка 17 нс против такта в 285 нс, то есть на решение о штрафе
   она не влияет, а кольцо разрывает. */
reg  m1_d = 1'b1;
always @(posedge clock) m1_d <= m1;
wire vduC_acc = (~m1_d) ? vduC_m1 : vduC_mem;
wire contend = (pentagon | warp_nc) ? 1'b1 : !(cpuck && mreqt23iorqtw3 && ((vduC_acc && memC) || (vduC_io && !ioFE)));  // Pentagon: NO contention; warp_nc: suppress it while the CPU-only warp runs 8x (1x-ULA wait-states would misalign and corrupt coarse WAV edges)

// ТАКТЫ ОЖИДАНИЯ ПАМЯТИ. Ложатся ровно туда же, где живёт контеншен ULA: гасится разрешение
// такта ПРОЦЕССОРА (обе фазы - T80 защёлкивает данные на nc3M5), а ULA и видео идут своим
// чередом на pe7M0/ne7M0. Гасить pe3M5_core в топе НЕЛЬЗЯ: он морозит ядро целиком вместе с
// ULA и растр поедет (так работает пауза, и это другое).
/* B0119: сюда же ложится и ожидание на порте данных General Sound - это ровно тот случай, ради
   которого у настоящей шины есть сигнал ожидания: медленная периферия ДЕРЖИТ процессор, а не врёт
   ему флагами. Провод объявлен здесь, а собирается ниже, у ловушки портов GS (gs_flow.v). */
wire gs_hold;
wire cpu_hold = mem_wait | gs_hold;
wire pc3M5 = pe3M5 & contend & ~cpu_hold;
wire nc3M5 = ne3M5 & contend & ~cpu_hold;
wire cpu_ten_raw = pe3M5 & contend & ~mem_wait;   // такт, который БЫЛ БЫ, если бы мы не держали шину

//-------------------------------------------------------------------------------------------------

// Atlas historically re-samples the raw ULA /INT on pc3M5 before presenting it to T80.  Because
// T80 makes its interrupt-acceptance decision on that same master-clock edge, nonblocking semantics
// make the registered path one complete CPU T later than the current raw vduI value.  Keep that
// established path bit-for-bit for Type 1/Early.  For Type 2/Late bypass the resample stage: the
// CPU-visible interrupt is then exactly one T earlier relative to the display/contention phase,
// matching Fuse/Spectrusty late-timing coordinates.  vduI is generated synchronously in this same
// spclk domain; this is a phase selection, not an asynchronous clock-domain crossing.
// B0165: strictly 32 T interrupt duration on 48K / 128K.
// Arrival edge is sampled on pc3M5/nc3M5 (preserving exact legacy entry phase for stime 14335,
// READP 14340..14343, CONTP 14339..14344).
// Deassertion edge is sampled on free-running pe3M5/ne3M5 so that memory/IO contention
// does not artificially stretch /INT input to 46..48 T.
reg irq = 1'b1;
reg irq_ne = 1'b1;
always @(posedge clock) begin
    if(!vduI) begin
        if(pc3M5) irq <= 1'b0;
    end else begin
        if(pe3M5) irq <= 1'b1;
    end
end
always @(posedge clock) begin
    if(!vduI) begin
        if(nc3M5) irq_ne <= 1'b0;
    end else begin
        if(ne3M5) irq_ne <= 1'b1;
    end
end

// 🥇 B0158: умолчание источника прерывания ВЕРНУТО К ОПЦИИ МАШИНЫ. В B0157 здесь стояло жёсткое
// 2'd1 (= Late, сырой vduI без переопроса), и это стоило трёх эталонных чисел сразу: шкала тестов
// Бобровского привязана К ПРЕРЫВАНИЮ, поэтому прерывание на такт раньше читается как «всё на такт
// позже». Измерено стендом /tmp/ula1 по живому коду: порог stime 14335 -> 14336, данные плавающей
// шины 14340..14343 -> 14341..14344, окно контеншена памяти +1 такт. Плюс опция машины
// `ULA timing = EARLY (TYPE 1)` перестала на что-либо влиять - ядро всегда было Late.
// B0162: default Sinclair ULA to irq_ne (2'd2) to eliminate master-clock sampling edge race
/* 🥇 B0175 ПЕРЕОПРОС ПРЕРЫВАНИЯ ТАКТОМ ПРОЦЕССОРА СТОИТ ЧЕТЫРЁХ ТАКТОВ НА ВЫХОДЕ ИЗ HALT.
   Настоящий Z80 опрашивает /INT в ПОСЛЕДНЕМ такте команды, а в HALT команды идут по сетке 4 такта.
   `irq <= vduI` по `pc3M5` отдаёт сигнал на такт позже: если граница сетки приходится ровно на тот
   такт, где /INT только что стал активен, выборка его НЕ ВИДИТ и берётся следующая граница —
   то есть плюс целый цикл NOP. У нас это ровно так и было: /INT активен с T=0, ближайшая граница
   на T=1, подтверждение начиналось на T=5 вместо T=1.
   ИЗМЕРЕНО НА СТЕНДЕ (Timing Tests 48K, живое RTL): с переопросом тело теста стартует на такте 253
   от прерывания, эталон 247..249. Разложение цепочки монитором TMON: подтверждение INT 7,
   обработчик F5F5 24, пусковая C0F3 59, тело DDDD 253; при этом сам обработчик ровно 35 T, а
   пусковая ровно 194 T — то есть весь промах сидел в первом звене.
   БЕЗ переопроса семь тестов из восьми в классе «сдвиг t0» встают на эталон точно
   (3, 5, 12, 15, 19, 20 незанятые и 5 занятый).
   ЧТО ИМЕННО СТОИТ ТЕПЕРЬ: `vduI`, зарегистрированный МАСТЕР-тактом (56.67 МГц), то есть задержка
   1/16 такта процессора вместо целого. Сырой `vduI` — комбинационный (`video.v: assign irq =
   !irqActive` от компараторов счётчиков), и вешать его прямо на вход T80 на закрытом тайминге
   рискованно; регистр мастер-такта снимает этот риск, не возвращая задержку на T-состояние.
   ⚠ ЧТО БЫЛО ЗАПИСАНО ПРОТИВ И ПОЧЕМУ СНЯТО: B0158 вернул переопрос, потому что без него уезжали
   три ОДИНОЧНЫХ приёмочных числа (stime, READP, окно контеншена). Это наши собственные пробы со
   своей шкалой, привязанной к прерыванию; набор из 74 троек с ДВУМЯ независимыми таблицами
   ожиданий — свидетельство сильнее. Тест 0 (детектор Early/Late) при этом отдаёт эталонную тройку
   TYPE1, то есть шкала теста к машине привязывается верно.
   ⚠ И ЗАОДНО РАЗВЯЗАНЫ ДВЕ РАЗНЫЕ ВЕЩИ: вариация Ferranti Early/Late — это сдвиг РАСТРА на такт
   (`ulaShift`, video.v), переопрос прерывания к ней отношения не имеет. Раньше опция машины
   `ULA timing` дёргала оба, теперь только растр.
   Лаборатория (`ula_tune[8:7]`): 0 = регистр мастер-такта (умолчание), 1 = сырой `vduI`,
   2 = `irq_ne` (переопрос по противоположной фазе), 3 = прежний `irq` по `pc3M5`. */
reg vduI_m = 1'b1;
always @(posedge clock) vduI_m <= vduI;
wire[1:0] int_sel = tune_en ? ula_tune[8:7] : 2'd0;
wire cpu_irq = int_sel == 2'd1 ? vduI
             : int_sel == 2'd2 ? irq_ne
             : int_sel == 2'd3 ? irq
             : vduI_m;

wire rfsh;
wire mreq;
wire iorq;
// wire m1; - объявление перенесено ВЫШЕ (см. B0180): его использует `vduC_acc`,
//           а неявная сеть плюс повторное объявление роняли элаборацию xsim.
wire rd;
wire wr;

wire[15:0] a;
wire[ 7:0] d;
wire[ 7:0] q;

cpu Cpu
(
	.clock  (clock  ),
	.pe     (pc3M5  ),
	.ne     (nc3M5  ),
	.reset  (reset  ),
	.rfsh   (rfsh   ),
	.mreq   (mreq   ),
	.iorq   (iorq   ),
	.nmi    (nmi    ),
	.irq    (cpu_irq),
	.m1     (m1     ),
	.rd     (rd     ),
	.wr     (wr     ),
	.a      (a      ),
	.d      (d      ),
	.q      (q      ),
	.dirset (dirset ),
	.dir    (dir    ),
	.reg_out(reg_out)
);

//-------------------------------------------------------------------------------------------------

reg mic;
reg speaker;
reg[2:0] border;

always @(posedge clock)
	if(force_border) border <= border_in;                          // ARM override (raw clock)
	// 🥇 B0174 ЗАПИСЬ В БОРДЮР ЗАЩЁЛКИВАЕТСЯ ПОСЛЕ ОТРАБОТКИ КОНТЕНШЕНА, А НЕ В НАЧАЛЕ ЦИКЛА.
	// Это лечит чёрную чёрточку 8x1 px вплотную слева к бумаге на ПЕРВОЙ строке экрана (esh2_48,
	// строка 54, x 57..64). У настоящего 48K её нет; у FUSE, ZEsarUX и Spectrusty - есть, и у нас
	// была по той же причине.
	// МЕХАНИКА. Цикл ввода-вывода занимает такты [s, s+3+d], где d - штраф контеншена. Эталонное
	// правило настоящей машины (WoS «48K reference»): положение цвета на экране задаётся КОНЦОМ
	// команды минус три, то есть s+d - ПОСЛЕ отработки ожидания. Мы же защёлкивали на s, потому что
	// во время контеншена процессор заморожен, а IORQ/WR держатся весь растянутый цикл, и первый же
	// pe7M0 брал значение. Ошибка ровно на d тактов.
	// ПОЧЕМУ ВИДНО ТОЛЬКО ОДНУ СТРОКУ. Такт 14335 - единственный в строке, где ОДНОВРЕМЕННО
	// красится последняя 8-пиксельная группа бордюра и начисляется максимальный штраф 6. Запись,
	// попавшая на него, у нас ложилась вплотную слева к бумаге, а у настоящей машины уезжает на
	// шесть тактов внутрь бумаги, где бордюра не видно, и бордюр остаётся прежним. Дальше по кадру
	// штрафы сбивают 224-тактовый цикл демки, и попаданий в 14335 больше нет.
	// ПОДТВЕРЖДЕНО ТРЕМЯ НЕЗАВИСИМЫМИ ИСТОЧНИКАМИ:
	//   * FUSE 1.6.0, periph.c:368-373 - `writeport_internal` (красит бордюр) стоит СТРОКОЙ ВЫШЕ,
	//     чем начисление штрафа `ula_contend_port_late`; то же у ZEsarUX (operaciones.c) и Spectrusty;
	//   * правило WoS: «OUT, заканчивающийся на такте 14339..14342, меняет бордюр ровно в позиции
	//     байта 16384» - то есть отсчёт от КОНЦА команды;
	//   * разбор Потапова (ep4spectrum 4f902f7): на первом контендед-такте кадра исполняется второй
	//     байт `ED 71` (OUT (C),0, чёрный), то есть T0+9 = 14335.
	// ЧТО ИМЕННО ИЗМЕНИЛОСЬ: добавлено `contend` - защёлка берёт значение на первом НЕОСТАНОВЛЕННОМ
	// такте цикла записи, то есть на s+d. Вне контеншена d = 0 и момент прежний, поэтому на всём
	// остальном софте правка обязана быть невидимой.
	else if(pe7M0 && contend) if(!ioFE && !wr && !nemo_sup) { speaker, mic, border } <= q[4:0];
	/* B0112: у NEMO все командные порты ЧЁТНЫЕ, то есть попадают в окно #FE. Без подавления
	   `OUT (#10)` мигал бы бордюром на каждом байте сектора - в железе это делает /IORQCE. */

//-------------------------------------------------------------------------------------------------

wire       vduI;
wire       vduC;
wire       vduC_mem_raw;   // B0179: окно занятости для ПАМЯТИ (своя фаза)
wire       vduC_m1_raw;    // B0180: окно занятости для ВЫБОРКИ КОМАНДЫ (своя фаза)
wire[12:0] vduA;
// объявление vdu_dbg_h/vdu_dbg_v поднято ВЫШЕ (к cpuck): его читает ck_lock_v
wire[ 7:0] vduD = vmmD;
wire[ 7:0] vduQ;
wire[ 7:0] vduQattr;                      // B0200: атрибут для порта #FF Пентагона
wire       vdu_scr_we;                    // BulbuLator: ULA screen-fetch strobe (from video)
assign scr_capA  = vduA;                  // raw ZX screen address (native interleaved layout)
assign scr_capD  = vduD;                  // = vmmD: byte from the displayed bank (shadow-aware)
assign scr_capWe = vdu_scr_we;
assign border_o  = border;                // live ULA border colour (declared below at reg[2:0] border)


video Video
(
	.model  (model  ),
	.pentagon(pentagon),
	.ula_late(ula_late),
	.ula_tune(ula_tune),
	.ula_tune2(ula_tune2),
	.pent_int_v(pent_int_v),
	.pent_int_h(pent_int_h),
	.paper_h(paper_h),
	.paper_v(paper_v),
	.clock  (clock  ),
	.ce     (ne7M0  ),
	.border (border ),
	.irq    (vduI   ),
	.cn     (vduC   ),
	.cn_mem (vduC_mem_raw),
	.cn_m1  (vduC_m1_raw),
	.a      (vduA   ),
	.d      (vduD   ),
	.q      (vduQ   ),
	.qattr  (vduQattr),
	.blank  (blank  ),
	.hsync  (hsync  ),
	.vsync  (vsync  ),
	.r      (r      ),
	.g      (g      ),
	.b      (b      ),
	.i      (i      ),
	.scr_we (vdu_scr_we),
	.dbg_h  (vdu_dbg_h),
	.dbg_v  (vdu_dbg_v)
);

//-------------------------------------------------------------------------------------------------

wire[7:0] psgA1;
wire[7:0] psgB1;
wire[7:0] psgC1;

wire[7:0] psgA2;
wire[7:0] psgB2;
wire[7:0] psgC2;

wire[ 7: 0] psgQ;
wire[15:14] psgAh = a[15:14];
wire[ 1: 1] psgAl = a[1];

turbosound Turbosound
(
	.clock  (clock  ),
	.ce     (pe3M5  ),
	.reset  (reset  ),
	.iorq   (iorq   ),
	.wr     (wr     ),
	.rd     (rd     ),
	.d      (q      ),
	.ah     (psgAh  ),
	.al     (psgAl  ),
	.q      (psgQ   ),
	.a1     (psgA1  ),
	.b1     (psgB1  ),
	.c1     (psgC1  ),
	.a2     (psgA2  ),
	.b2     (psgB2  ),
	.c2     (psgC2  ),
	.midi   (midi   )
);

//-------------------------------------------------------------------------------------------------

wire[7:0] spdQ;
wire[7:4] spdA = a[7:4];

specdrum Specdrum
(
	.clock  (clock  ),
	.ce     (pc3M5  ),
	.iorq   (iorq   ),
	.wr     (wr     ),
	.d      (q      ),
	.q      (spdQ   ),
	.a      (spdA   )
);

//-------------------------------------------------------------------------------------------------

// B0088: SAA1099 требует РОВНО 8 МГц (datasheet; на этой же частоте сходится формула тона
// f = 15625*2^oct/(511-freq)). Деление spclk 56.6667/7 давало 8.0952 МГц, то есть чип звучал
// на +1.19 % = +20.3 цента выше нормы. Замерено в xsim: 8 094 500 Гц против эталонных
// 8 000 000. Арифметика САМОГО чипа при этом верна - полупериод в тактах ce совпал с
// datasheet до единицы на freq/oct = 0/3, 255/4, 200/5, 128/2, и темпы шума тоже.
// Фазовый аккумулятор: inc = 8.000e6 / 56.66667e6 * 2^24 = 2368548 -> 7 999 995 Гц (-0.6 ppm).
// Дрожание фронта ±1 такт spclk (17.6 нс) для 8 МГц несущественно.
reg [23:0] saa_acc = 24'd0;
reg        saa_ce  = 1'b0;
always @(posedge clock) {saa_ce, saa_acc} <= {1'b0, saa_acc} + 25'd2368548;

// SAA1099 сидит на #FF, где A8 выбирает адресный регистр (#01FF) или данные (#00FF). Это не
// догадка: в коде E-TUNES 7 стоит OUT #01FF,#1C затем OUT #00FF,#02 - регистр 0x1C SAA1099
// (Sound enable / Reset), каноническая инициализация чипа.
// На машине с Beta Disk тот же младший байт - НАШ системный регистр, поэтому порт делится ПО
// ВРЕМЕНИ, а не отдаётся кому-то навсегда (опция машины, MACHINE_CFG [12:11]):
//   AUTO (0) - SAA не слышит #FF, пока вставлена страница ПЗУ TR-DOS ИЛИ реально идёт обмен с
//              дискетой (bd_busy). Во время загрузки порт у дисковода, и записи TR-DOS не сыплют
//              мусор в регистры SAA (иначе можно случайно поднять 0x1C бит0 и получить визг).
//              Программа загрузилась, дисковод встал - порт у SAA, музыка играет.
//   ON   (1) - SAA слышит #FF всегда: для софта, который лезет к SAA при вставленном TR-DOS.
//   OFF  (2) - SAA не слышит #FF никогда (поведение до B0087).
// ГЛУШИТЬ ПО ЛИПКОЙ СЕССИИ (bd_open) НЕЛЬЗЯ: она держится до сброса машины, и ЛЮБОЙ SAA-пак,
// загруженный с дискеты, молчал бы весь сеанс - а это ровно тот случай, ради которого всё и
// делается. Чтения #FF конфликта не имеют вовсе: SAA write-only, статус INTRQ/DRQ всегда
// достаётся дисководу.
// bd_open/bd_busy/trdos_live объявлены здесь ради лексического порядка - драйверы ниже.
wire       bd_open;
wire       bd_busy;
wire       trdos_live;              // живая защёлка DOS: наружу, в дисковод и в арбитраж #FF
wire saa_deaf = (saa_mode == 2'd1) ? 1'b0
              : (saa_mode == 2'd2) ? 1'b1
              :                      (trdos_live | bd_busy);
wire saaCs = !(!iorq && m1 && !wr && a[7:0] == 8'hFF && !saa_deaf);
wire saaA0 = a[8];

wire[7:0] saaD = q;
wire[7:0] saaL;
wire[7:0] saaR;

saa1099 SAA
(
	.clk_sys(clock  ),
	.ce     (saa_ce ),
	.rst_n  (reset  ),
	.cs_n   (saaCs  ),
	.wr_n   (saaCs  ),
	.a0     (saaA0  ),
	.din    (saaD   ),
	.out_l  (saaL   ),
	.out_r  (saaR   )
);

//-------------------------------------------------------------------------------------------------

audio Audio
(
	.ear    (ear    ),
	.mic    (mic    ),
	.speaker(speaker),
	.a1     (psgA1  ),
	.b1     (psgB1  ),
	.c1     (psgC1  ),
	.a2     (psgA2  ),
	.b2     (psgB2  ),
	.c2     (psgC2  ),
	.spd    (spdQ   ),
	.saaL   (saaL   ),
	.saaR   (saaR   ),
	.laudio (laudio ),
	.raudio (raudio )
);

//-------------------------------------------------------------------------------------------------
// B0088 ТЕЛЕМЕТРИЯ ЗВУКА (0x170 AUD_DBG). Правило владельца: не объявлять музыку рабочей без
// пик-метра. Пики считаются по КАЖДОМУ источнику отдельно, поэтому сразу видно, какой чип
// реально звучит - например, играют ли в паке и SAA, и TurboSound, или только один из них.
// Окно 2^22 такта spclk = ~74 мс: внутри окна набирается максимум, на границе он защёлкивается
// и стоит неподвижно всё следующее окно. Слово меняется раз в 74 мс, то есть между
// обновлениями оно СТАБИЛЬНО - поэтому 2-триггерная синхронизация в оболочке его не рвёт
// (тот же приём и та же оговорка, что у MACH_DBG).
// Бипер однобитный, уровня у него нет - для него мерим факт переключений за окно.
wire [7:0] ay1_now = (psgA1 > psgB1) ? ((psgA1 > psgC1) ? psgA1 : psgC1)
                                     : ((psgB1 > psgC1) ? psgB1 : psgC1);
wire [7:0] ay2_now = (psgA2 > psgB2) ? ((psgA2 > psgC2) ? psgA2 : psgC2)
                                     : ((psgB2 > psgC2) ? psgB2 : psgC2);
wire [7:0] saa_now = (saaL > saaR) ? saaL : saaR;

reg [21:0] aud_win  = 22'd0;
reg [7:0]  run_ay1 = 8'd0, run_ay2 = 8'd0, run_saa = 8'd0, run_spd = 8'd0;
reg [7:0]  pk_ay1  = 8'd0, pk_ay2  = 8'd0, pk_saa  = 8'd0, pk_spd  = 8'd0;
reg        run_beep = 1'b0, pk_beep = 1'b0, spk_d = 1'b0;
always @(posedge clock) begin
	spk_d <= speaker;
	if (speaker != spk_d)  run_beep <= 1'b1;
	if (ay1_now > run_ay1) run_ay1  <= ay1_now;
	if (ay2_now > run_ay2) run_ay2  <= ay2_now;
	if (saa_now > run_saa) run_saa  <= saa_now;
	if (spdQ    > run_spd) run_spd  <= spdQ;
	aud_win <= aud_win + 22'd1;
	if (aud_win == 22'h3FFFFF) begin      // сброс идёт ПОСЛЕ набора -> он и побеждает в этом такте
		pk_ay1  <= run_ay1;  run_ay1  <= 8'd0;
		pk_ay2  <= run_ay2;  run_ay2  <= 8'd0;
		pk_saa  <= run_saa;  run_saa  <= 8'd0;
		pk_spd  <= run_spd;  run_spd  <= 8'd0;
		pk_beep <= run_beep; run_beep <= 1'b0;
	end
end
// {SAA[31:24], AY2[23:16], AY1[15:8], SpecDrum[7:2], бипер[1], 0}
assign aud_dbg_o = {pk_saa, pk_ay2, pk_ay1, pk_spd[7:2], pk_beep, 1'b0};

//-------------------------------------------------------------------------------------------------

wire memC;
wire [7:0] map_diag;
assign trdos_o = trdos_live;

memory Memory
(
	.model  (model  ),
	.pent1024(pent1024),
	.ram_nobit(ram_nobit),
	.snow_off(snow_off),
	.mapper (mapper ),
	.dm_opt (dm_opt ),
	.dm_pagein_off(dm_pagein_off),
	.clock  (clock  ),
	.ce     (pc3M5  ),
	.reset  (reset  ),
	.rfsh   (rfsh   ),
	.mreq   (mreq   ),
	.iorq   (iorq   ),
	.rd     (rd     ),
	.wr     (wr     ),
	.m1     (m1     ),
	.a      (a      ),
	.d      (q      ),
	.cn     (memC   ),
	.va     (vduA   ),
	.vmmA1  (vmmA1  ),
	.vmmA2  (vmmA2  ),
	.memRf  (memRf  ),
	.memRd  (memRd  ),
	.memWr  (memWr  ),
	.memA   (memA   ),
	.ram_bank(ram_bank),
	.eff7_o (eff7_o ),
	.force_7ffd (force_7ffd ),
	.port7ffd_in(port7ffd_in),
	.port7ffd_o (p7ffd_live ),
	.map_diag   (map_diag),
	.trdos_en   (trdos_en   ),   // B0071: трап Beta Disk + 4 страницы ПЗУ
	.service_en (service_en | svc_nmi),   // B0101: та же страница, но по магической кнопке
	.dos_svc_en (dos_svc_en ),   // B0146: под TR-DOS страница = {DOS, 7FFD[4]}
	.trdos_o    (trdos_live ),
	.rom_page_o (rom_page_o ),
	.rom_dbg_o  (rom_dbg_o  ),
	.page3_seen_o(page3_seen_o)
);

// ЛОВУШКА ПОРТОВ GENERAL SOUND: #BB (команда/состояние) и #B3 (данные/вывод).
// Правила из живого апстрима MiSTer (rtl/gs.v:142-157, сверено с ЖИВЫМ файлом - вендоренная копия
// не устарела): со стороны Спектрума запись #BB кладёт команду и ставит бит0; запись #B3 кладёт
// данные и ставит бит7; чтение #B3 отдаёт байт от GS и снимает бит7; чтение #BB отдаёт слово
// состояния {бит7, шесть единиц, бит0}. Со стороны САМОЙ КАРТЫ (у нас это эмулятор на ARM) те же
// биты трогают её внутренние порты: #02 снимает бит7, #03 ставит бит7, #05 снимает бит0 (прошивка
// gs105b делает это записью `OUT (5),A` - 101 раз в ПЗУ, чтения порта 5 в ней нет вовсе).
//
// 🥇 B0107: ФЛАГ ОДИН, И ЕГО ХОЗЯИН - КАРТА. Фабрика не подтверждает ЗА эмулятор (так было в B0106:
// оболочка снимала бит0 сразу, как передала команду, и весь GS-софт вис на каноническом
// `WC: IN A,(#BB) : RRCA : JR C,WC` - по руководству GS бит0 имеет право снять ТОЛЬКО сама карта).
// Оболочка ЗЕРКАЛИТ состояние эмулятора, а фабрика применяет события машины немедленно. Гонка
// «зеркало устарело» закрыта эхом: оболочка возвращает тоггл-биты, которые видела, и зеркало
// применяется только если с тех пор события не было. При совпадении в одном такте побеждает
// МАШИНА - так же ведёт себя и апстрим (его условия уровневые, а окно `CS_n` шире окна GS-IORQ
// примерно в двенадцать раз, поэтому присваивание Спектрума применяется последним).
//
// 🥇 B0108: УПРУГАЯ ОЧЕРЕДЬ ЗАПИСЕЙ #B3 - НЕ УДОБСТВО, А КОРРЕКТНОСТЬ. X-Player заливает сэмплы
// страницами по 256 байт, и на ГРАНИЦЕ СТРАНИЦЫ пишет байт БЕЗ опроса флага: `OUTI` стоит раньше
// проверки, а между `JR Z` -> `DEC E` -> `JP NZ` проходит порядка 24 тактов Z80 (~7 мкс). На
// настоящей карте флаг снимается за микросекунды, поэтому это безопасно; у нас подтверждение идёт
// через ARM и стоит СОТНИ микросекунд, и каждый 256-й байт пропадал - на модуле 22234 Б это 87
// потерянных байт (замерено липким битом переполнения, модуль после заливки был побит). Теперь
// ловушка ПРИНИМАЕТ байт в очередь на 256 позиций и держит флаг данных снятым, пока очередь не
// полна. Протокол от этого не страдает: софт ждёт СНЯТИЯ ФЛАГА, а не задержки, и порядок байтов
// сохраняется. Тайм-аута ни у X-Player, ни у Mod Player, ни у драйвера производителя нет вовсе
// (проверено по распакованному коду), поэтому «медленно» для них законно, а «потеряно» - нет.
//
// 🥇 B0118: ОБРАТНОЕ ДАВЛЕНИЕ. ГЛУБИНОЙ ЭТО НЕ ЗАКРЫТЬ В ПРИНЦИПЕ (оплачено Z-Player 4.1).
// Плеер заливает в карту свой драйвер потоком OUTI: флаг он проверяет ПОСЛЕ записи, а на
// перевороте счётчика делает ДВЕ записи подряд вообще без проверки. Байт у него уходит раз в
// ~4.7 мкс, то есть очередь на 32 байта = 150 мкс запаса, а паузы оболочки измерены до 134 мс
// (наполнение звукового кольца) и 1.25 мс (чтение сектора образа). 134 мс - это 28 тысяч байт:
// такой очереди не будет никогда. Настоящая карта не теряет не из-за буфера, а потому, что её Z80
// забирает байт за микросекунды. Значит, и нам надо не «успевать», а честно говорить «занято»
// ЗАРАНЕЕ - тогда гость притормозит сам, ровно как перед железом, и терять становится нечего.
// Запас мест под те записи, что гость делает слепо, живёт в самой очереди (gs_wq_fifo.v, HDR).
// Липкий gs_ovr7 остаётся и теперь значит ровно одно: гость записал без опроса флага больше,
// чем мы зарезервировали - это дефект, и прошивка обязана о нём сказать вслух.
wire       gs_io     = ~iorq & m1;                 // обращение к порту: IORQ есть, M1 нет
wire       gs_sel_bb = gs_io & (a[7:0] == 8'hBB);
wire       gs_sel_b3 = gs_io & (a[7:0] == 8'hB3);
wire       gs_wr_acc = (gs_sel_bb | gs_sel_b3) & ~wr;
wire       gs_rd_acc = (gs_sel_bb | gs_sel_b3) & ~rd;
reg [7:0]  gs_cmd_r = 8'h00, gs_dat_r = 8'h00, gs_dout_r = 8'h00;
reg        gs_b0 = 1'b0;                           // флаг команд: ставит машина, снимает ЗЕРКАЛО карты
reg        gs_outp = 1'b0;                         // у карты есть непрочитанный байт для машины
reg        gs_wr_d = 1'b0, gs_rd_d = 1'b0;
/* Тоггл на события машины: _i мгновенный (по нему сравниваем эхо внутри фабрики), наружу уходит
   задержанный на два такта. 🥇 Слово состояния читается из AXI БЕЗ синхронизатора вовсе
   (axi_ctl.v: `s_rdata <= gs_stat_in`, домен машины 56 МГц -> домен оболочки 100 МГц), поэтому
   байт обязан быть СТАРШЕ флага: правило CDC из PROJECT_RULES.md - нагрузку держать, флаг отдавать на
   такт-два позже данных. Иначе оболочка прочитает новый флаг со старым байтом. */
reg        gs_ev0_i = 1'b0, gs_er7_i = 1'b0;
reg        gs_ev0_d = 1'b0, gs_er7_d = 1'b0;
reg        gs_ev0   = 1'b0, gs_er7   = 1'b0;
reg        gs_ovr0 = 1'b0, gs_ovr7 = 1'b0;         // липкие: байт машины потерян (очередь полна / флаг стоял)
/* B0106: подтверждение приходит из домена оболочки (100 МГц) в домен машины (56 МГц). Импульс
   шириной в такт быстрого домена медленный может не увидеть вовсе, поэтому оболочка шлёт
   ТОГГЛ, а мы ловим его фронт двумя триггерами. Слово управления при этом держится стабильным,
   так что синхронизировать надо ровно один бит - правило CDC из PROJECT_RULES.md. */
(* ASYNC_REG="TRUE" *) reg [2:0] gs_we_s = 3'b000;
wire       gs_ack_now = gs_we_s[2] ^ gs_we_s[1];   // фронт тоггла = было подтверждение
wire       gs_wr_evt  = gs_en & gs_wr_acc & ~gs_wr_d;              // фронт записи со стороны машины
wire       gs_rd_evt  = gs_en & gs_rd_acc & ~gs_rd_d & gs_sel_b3;  // машина забрала байт из #B3
// байт уходит в очередь ТОЛЬКО если в ней есть место; иначе он потерян и это видно прибором
assign     gs_wq_we  = gs_wr_evt & gs_sel_b3 & ~gs_wq_full;
assign     gs_wq_din = q;
always @(posedge clock) begin
	gs_we_s <= {gs_we_s[1:0], gs_ctl_we};
	gs_wr_d <= gs_wr_acc;
	gs_rd_d <= gs_rd_acc;
	/* тоггл наружу - строго ПОЗЖЕ байта; сброс машины его НЕ трогает, иначе кэш оболочки
	   разъедется с фабрикой и она повторно скормила бы эмулятору старую команду */
	gs_ev0_d <= gs_ev0_i; gs_ev0 <= gs_ev0_d;
	gs_er7_d <= gs_er7_i; gs_er7 <= gs_er7_d;
	if(gs_wr_evt & gs_sel_bb) gs_ev0_i <= ~gs_ev0_i;
	if(gs_rd_evt)             gs_er7_i <= ~gs_er7_i;
	if(!reset) begin gs_b0 <= 1'b0; gs_outp <= 1'b0; gs_ovr0 <= 1'b0; gs_ovr7 <= 1'b0; end
	else begin
		if(gs_ack_now) begin                       // оболочка отдала СОСТОЯНИЕ эмулятора (зеркало)
			gs_dout_r <= gs_ctl[7:0];
			if(gs_ctl[26] == gs_ev0_i) gs_b0   <= gs_ctl[29];
			if(gs_ctl[28] == gs_er7_i) gs_outp <= gs_ctl[30];
			if(gs_ctl[25]) begin gs_ovr0 <= 1'b0; gs_ovr7 <= 1'b0; end
		end
		/* события машины применяем ПОСЛЕ зеркала: при совпадении в одном такте побеждает машина -
		   потерянное событие = зависший протокол, а опоздавшее зеркало починится следующим проходом */
		if(gs_en) begin
			if(gs_wr_acc & ~gs_wr_d) begin
				if(gs_sel_bb) begin gs_cmd_r <= q; gs_b0 <= 1'b1; if(gs_b0) gs_ovr0 <= 1'b1; end
				else          begin gs_dat_r <= q;                if(gs_wq_full) gs_ovr7 <= 1'b1; end
			end
			if(gs_rd_acc & ~gs_rd_d & gs_sel_b3) gs_outp <= 1'b0;   // машина забрала байт
		end
	end
end
/* 🥇 B0119: БИТ7 ПОРТА #BB ЗНАЧИТ РОВНО ОДНО - «У КАРТЫ ЕСТЬ БАЙТ ДЛЯ ТЕБЯ».
   Так он устроен у настоящей карты: это флаг одного двунаправленного регистра данных. В B0118 мы
   подмешивали сюда своё «очередь почти полна» - два разных смысла на одном бите, - и плеер, который
   ждёт единицу циклом IN A,(#BB) / RLCA / JR NC, читал наше «занято» как «пришёл ОТВЕТ»: забирал из
   #B3 протухший байт и продолжал лить дальше. То есть переполнение, от которого мы защищались, мы
   же и провоцировали. Обратное давление теперь живёт там, где ему место, - в тактах ожидания на
   шине (gs_flow.v), и на протокол не влияет вовсе. */
wire       gs_b7_m = gs_outp;
/* Ловушка ожидания: байт в очередь ПРИНИМАЕМ всегда, а цикл записи в #B3 растягиваем, пока очередь
   не опустится ниже нижнего порога. Сторож внутри модуля не даёт мёртвой оболочке заморозить Z80. */
wire       gs_wr_b3_lvl = gs_en & gs_sel_b3 & ~wr;   // УРОВЕНЬ цикла записи в порт данных
gs_flow gs_flow_i (
	.clock    (clock),        .reset_n  (reset),
	.ten      (cpu_ten_raw),
	.wr_acc_b3(gs_wr_b3_lvl), .wr_evt_b3(gs_wr_evt & gs_sel_b3),
	.wq_afull (gs_wq_afull),  .wq_full  (gs_wq_full), .drain(gs_wq_drain),
	.hold     (gs_hold),      .stat2    (gs_stat2),   .stat3(gs_stat3)
);
/* Раскладка сознательно совпадает с эхом в слове управления: тоггл er7/ev0 стоит на тех же
   битах 28/26, что и его эхо в gs_ctl - сдвиг на один бит здесь стоил бы ложного «события». */
assign gs_stat = {gs_ovr7, gs_ovr0, 1'b0, gs_er7, 1'b0, gs_ev0, 3'd0,
                  gs_b7_m, gs_b0, gs_outp, 4'd0, gs_cmd_r, gs_dat_r};
wire       gs_oe   = gs_en & gs_rd_acc;
wire [7:0] gs_dbus = gs_sel_bb ? {gs_b7_m, 6'b111111, gs_b0} : gs_dout_r;

// B0101 МАГИЧЕСКАЯ КНОПКА. Сервисная страница ПЗУ встаёт в окно по NMI и уходит по опкоду RETN
// (ED 45) - так пейджится наружу настоящий Multiface. Ставить защёлку по выборке команды на
// 0x0066 НЕЛЬЗЯ: страница переключилась бы уже ПОСЛЕ этой выборки, машина исполнила бы один
// опкод из обычного ПЗУ (в 48К там PUSH AF), а следующая выборка пришла бы из сервисной
// страницы - в середину чужой инструкции. Импульс же приходит заметно раньше: он держится
// 31 такт 56 МГц, а процессору до 0x0066 нужно дожить текущую инструкцию плюс 11 T-состояний.
// Правило выхода трапа TR-DOS («M1 вне окна ПЗУ») здесь не годится - фризер возвращается тоже
// в ПЗУ, и защёлка не снялась бы никогда.
wire       m1_fetch_svc = ~m1 & ~mreq;             // m1/mreq активны низким уровнем
reg [7:0]  svc_op  = 8'h00;                        // последний байт с шины ЧТЕНИЯ в выборке
reg        svc_fd  = 1'b0;                         // выборка шла в прошлом такте
reg        svc_ed  = 1'b0;                         // предыдущий опкод был префиксом ED
reg        svc_nmi = 1'b0;                         // защёлка: в окне сервисная страница
reg        svc_nd  = 1'b0;                         // NMI в прошлом такте (ловим фронт)
always @(posedge clock) begin
	if(m1_fetch_svc) svc_op <= d;                    // к концу выборки здесь лежит опкод
	if(!reset || !svc_nmi_en) begin svc_nmi <= 1'b0; svc_ed <= 1'b0; end
	else if(nmi & ~svc_nd)    begin svc_nmi <= 1'b1; svc_ed <= 1'b0; end   // вход: нажали кнопку
	else if(svc_fd && !m1_fetch_svc) begin                                 // конец выборки команды
		if(svc_ed && svc_op == 8'h45) begin svc_nmi <= 1'b0; svc_ed <= 1'b0; end  // выход: RETN
		else svc_ed <= (svc_op == 8'hED);
	end
	svc_fd <= m1_fetch_svc;
	svc_nd <= nmi;
end
//-------------------------------------------------------------------------------------------------
// ROM-trap (#65): fire on the M1 opcode fetch of LD-BREAK (0x056B) - by then LD-BYTES has run DI +
// white border + PUSH 0x053F, so the ARM reads the SHADOW A'/F', fills RAM, sets PC=0x05E2 and lets
// the ROM's own LD-RET do EI/border/return. Gate on the 48K loader ROM being paged (48K: always;
// 128/Pentagon: port7FFD bit4=1). The top edge-detects + halts on an M1 boundary.
/* B0132: и НЕ ПОКА ВСТАВЛЕНА СТРАНИЦА DivMMC. Адрес 0x056B лежит внутри окна DivMMC
   0x0000-0x1FFF: при поднятом автомаппере там исполняется код esxDOS, и наш SMART-загрузчик
   взводился бы на чужой инструкции, а ARM вкачивал бы блок ленты в ОЗУ живой машины.
   map_diag[7] = mapForce (CONMEM), map_diag[6] = mapAuto. */
assign rom_trap = ~m1 & ~mreq & (a == 16'h056B) & ((~model) | p7ffd_live[4])
                & ~(mapper & (map_diag[7] | map_diag[6]));   // m1/mreq are M1_n/MREQ_n (active-LOW): opcode fetch = both 0
//-------------------------------------------------------------------------------------------------

wire[7:0] keyA = a[15:8];
wire[4:0] keyQ;

keyboard Keyboard
(
	.clock  (clock  ),
	.ce     (pe7M0  ),
	.strb   (strb   ),
	.make   (make   ),
	.code   (code   ),
	.a      (keyA   ),
	.q      (keyQ   )
);

//-------------------------------------------------------------------------------------------------

wire[7:0] usdQ;
wire[7:0] usdA = a[7:0];

wire usd_zc_sel;
usd_bulb uSD                       /* B0138: форк с поддержкой Z-Controller; гейты внутри модуля */
(
	.clock  (clock  ),
	.cep    (pe7M0  ),
	.cen    (ne7M0  ),
	.turbo  (zc_turbo),          // B0143: 1 = Turbo 28 MHz, 0 = Standard 3.5 MHz
	.en_dm  (mapper ),           // DivMMC: порты #E7/#EB
	.en_zc  (zc_en  ),           // Z-Controller: порты #77/#57
	.sd_cd  (1'b1   ),           // карта у нас виртуальная: пока интерфейс включён, она вставлена
	.iorq   (iorq   ),
	.wr     (wr     ),
	.rd     (rd     ),
	.d      (q      ),
	.q      (usdQ   ),
	.a      (usdA   ),
	.cs     (cs     ),
	.ck     (ck     ),
	.miso   (miso   ),
	.mosi   (mosi   ),
	.zc_sel (usd_zc_sel)
);

//-------------------------------------------------------------------------------------------------

/* 🥇 B0175 ДЖОЙСТИК KEMPSTON - ОПЦИЯ, А НЕ ЧАСТЬ МАШИНЫ. Конус `a[5]=0` накрывает ПОЛОВИНУ портов,
   и без гейта каждое такое чтение получало 0x00 вместо плавающей шины. Измерено на стенде
   (Timing Tests 48K, тест 36, один кадр): из 1659 чтений 831 отдал джойстик, и только 117 - байт
   экрана. Тело тестов 35/36/37 грузит регистр B с шины и делает его старшим байтом порта, поэтому
   подмена меняет класс контеншена порта и валит все три теста. Модель без конуса воспроизводит
   эталонные тройки всех трёх тестов, с конусом - ровно наши числа. Умолчание 0 = интерфейса нет. */
wire ioDF   = !(!iorq && m1 && !a[5] && kj_en);          // kempston (опция MACHINE_CFG бит28)
/* 🥇 B0137 ПОРТ КАРТЫ СУЩЕСТВУЕТ, ТОЛЬКО ПОКА DivMMC ВКЛЮЧЁН. Было без гейта - и модуль uSD
   стоял в ядре безусловно. Последствие поймано владельцем 14.08 на Wild Player: при ВЫКЛЮЧЕННОМ
   DivMMC плеер опрашивал #EB, получал не чистую шину, а остаток сдвигового регистра, решал, что
   карта есть, и заполнял панели мусором. Под включённым DivMMC того же мусора не было.
   Так же гейтуют все живые реализации: MiSTer - mode[1:0], Sizif - en, ZX-UNO - disable_spisd,
   ZX Next - port_spi_io_en. Заодно добавлен терм m1: в цикле подтверждения прерывания порт
   отвечать не должен, иначе вектор IM 2 приходит не с плавающей шины. */
wire ioEB   = !(!iorq && m1 && a[7:0] == 8'hEB && mapper);   // usd
/* B0138: порты Z-Controller. Тот же движок и та же карта, другой транспорт. Терм m1 - по той же
   причине, что и у #EB: в подтверждении прерывания порт отвечать не должен. */
wire ioZC   = !(!iorq && m1 && zc_en && (a[7:0] == 8'h57 || a[7:0] == 8'h77));
wire ioFE   = !(!iorq && m1 && !a[0]);                   // ula
	assign tape_sample = ~ioFE & wr;   // port-FE access that is NOT a write = a READ (loader sampling the ear bit)
	assign tape_sample_strobe = tape_sample & nc3M5; // T80's CEN_n / DI latch phase
	assign tape_di_bit = ear | speaker;              // exact d[6] for the port-FE mux below
	assign cpu_ten = pc3M5;   // = pe3M5 & contend -> on 128K it stalls with the CPU during contention (Pentagon: contend=1, so == pe3M5)
	assign map_diag_o = map_diag;
	assign ula_diag_o = {map_diag, vduA, vduI, vduC, cpuck, contend, cpu_irq, mreqt23iorqtw3};

// B0053 interrupt acceptance observer. The externally visible Z80 interrupt-ack bus cycle
// (!M1_n && !IORQ_n) is used instead of modifying T80. Ages are counted in ne7M0 events, i.e. the
// same 7-MHz half-T unit as the runtime knobs. A settled config/epoch change invalidates and re-arms
// the snapshot; FREEZE retains the first accepted interrupt. Software reads TRACE0/1/2/TRACE0 and
// retries if ACK_SEQ changed, making the three independently synchronized AXI words coherent.
wire int_ack = !m1 && !iorq;
reg int_ack_d = 1'b0, vduI_d = 1'b1, cpu_irq_d = 1'b1;
reg pc3M5_d = 1'b0, nc3M5_d = 1'b0;
reg[6:0] raw_age = 7'h7F, cpu_age = 7'h7F;
reg[7:0] ack_seq = 8'd0, raw_pulse_seq = 8'd0;
reg[31:0] tune_prev = 32'd0;
reg pending = 1'b0, missed_raw_window = 1'b0;
reg raw_fall_seen = 1'b0, selected_fall_seen = 1'b0;
reg trace_valid = 1'b0;
reg[1:0] trace_source = 2'd0;
reg[8:0] trace_irq_delta = 9'd0;
reg[5:0] trace_ula_delta = 6'd0;
reg trace_raw_n = 1'b1, trace_legacy_n = 1'b1, trace_half_n = 1'b1, trace_cpu_n = 1'b1;
reg trace_pc3M5_d = 1'b0, trace_nc3M5_d = 1'b0;
reg trace_raw_seen = 1'b0, trace_selected_seen = 1'b0;
reg[8:0] trace_v = 9'd0, trace_h = 9'd0;
reg[6:0] trace_raw_age = 7'h7F, trace_cpu_age = 7'h7F;
reg[15:0] trace_pc = 16'd0;
reg[7:0] trace_r = 8'd0, trace_raw_seq = 8'd0;
wire trace_frozen = ula_tune[30] && trace_valid;
always @(posedge clock) begin
	int_ack_d <= int_ack;
	vduI_d <= vduI;
	cpu_irq_d <= cpu_irq;
	pc3M5_d <= pc3M5;
	nc3M5_d <= nc3M5;
	if(tune_prev != ula_tune) begin
		tune_prev <= ula_tune;
		trace_valid <= 1'b0;
		pending <= 1'b0;
		missed_raw_window <= 1'b0;
		raw_fall_seen <= 1'b0;
		selected_fall_seen <= 1'b0;
		raw_age <= 7'h7F;
		cpu_age <= 7'h7F;
	end
	else if(!trace_frozen) begin
		if(vduI_d && !vduI) begin
			raw_age <= 7'd0;
			raw_fall_seen <= 1'b1;
			pending <= 1'b1;
			missed_raw_window <= 1'b0;
			raw_pulse_seq <= raw_pulse_seq + 8'd1;
		end
		else if(ne7M0 && raw_fall_seen && raw_age != 7'h7F)
			raw_age <= raw_age + 7'd1;

		if(cpu_irq_d && !cpu_irq) begin
			cpu_age <= 7'd0;
			selected_fall_seen <= 1'b1;
		end
		else if(ne7M0 && selected_fall_seen && cpu_age != 7'h7F)
			cpu_age <= cpu_age + 7'd1;

		if(!vduI_d && vduI && pending) begin
			missed_raw_window <= 1'b1;
			pending <= 1'b0;
		end

		if(tune_en && int_ack && !int_ack_d && pending) begin
			ack_seq <= ack_seq + 8'd1;
			trace_valid <= 1'b1;
			pending <= 1'b0;
			trace_source <= int_sel;
			trace_irq_delta <= ula_tune[23:15];
			trace_ula_delta <= ula_tune[14:9];
			trace_raw_n <= vduI;
			trace_legacy_n <= irq;
			trace_half_n <= irq_ne;
			trace_cpu_n <= cpu_irq;
			trace_pc3M5_d <= pc3M5_d;
			trace_nc3M5_d <= nc3M5_d;
			trace_raw_seen <= raw_fall_seen;
			trace_selected_seen <= selected_fall_seen;
			trace_v <= vdu_dbg_v;
			trace_h <= vdu_dbg_h;
			trace_raw_age <= raw_age;
			trace_cpu_age <= cpu_age;
			trace_pc <= reg_out[79:64];
			trace_r <= reg_out[47:40];
			trace_raw_seq <= raw_pulse_seq;
		end
	end
end
assign int_dbg0_o = {ack_seq, trace_valid, missed_raw_window, trace_source,
                     trace_irq_delta, trace_ula_delta,
                     trace_raw_n, trace_legacy_n, trace_half_n, trace_cpu_n,
                     trace_raw_seen};
assign int_dbg1_o = {trace_v, trace_h, trace_raw_age, trace_cpu_age};
assign int_dbg2_o = {trace_pc, trace_r, trace_raw_seq};
wire ioFFFD = !(!iorq && m1 && a[15] && a[14] && !a[1]); // psg

// B0075 ДИСКОВОД. Приоритет ВЫШЕ встроенных портов, и это не вкусовщина: порт #1F - это И
// джойстик Kempston (ioDF: !a[5]), И регистр состояния контроллера дискет. На настоящей машине их
// разделяет ровно то же условие, что у нас - вставлена ли страница ПЗУ TR-DOS (bd_oe поднимается
// только при ней). Пока TR-DOS не в окне, #1F по-прежнему кемпстоновский.
wire [7:0] bd_dout;
wire       bd_oe;
beta_disk beta (
	.clk (clock), .ce (pc3M5), .reset_n (reset), .trdos_on (trdos_live),
	.bdi_always (bdi_always), .cpu_pc (reg_out[79:64]),
	.iorq_n (iorq), .rd_n (rd), .wr_n (wr), .m1_n (m1), .a (a[7:0]), .din (q),
	.dout (bd_dout), .oe (bd_oe), .bdi_open (bd_open), .bdi_busy (bd_busy),
	.aclk (fdc_aclk), .arm_ctl (fdc_ctl), .arm_ctl_we (fdc_ctl_we),
	.arm_data (fdc_data), .arm_data_we (fdc_data_we), .fdc_stat (fdc_stat), .fdc_stat2 (fdc_stat2)
);

/* B0112 NEMO-IDE. Регистры и буфер сектора - в модуле `nemo_ide.v`, сам «диск» на ARM.
   Слово управления от оболочки: [31:24] байт в буфер, [23:15] адрес в буфере, [14] строб записи,
   [13:6] регистр состояния ATA, [5] «ARM владеет буфером» (машине отдаём BSY), [4] сброс,
   [3:0] код ошибки. Переход в домен машины - тем же тогглом, что у General Sound. */
(* ASYNC_REG="TRUE" *) reg [2:0] nemo_we_s = 3'b000;
reg [31:0] nemo_ctl_l = 32'd0;
/* B0115: строб «слово от ARM пришло» - им блок регистров отличает запись регистра ATA от обычного
   обновления состояния. Отдельного синхронизатора он не требует и не должен требовать: импульс
   защёлкивается ТЕМ ЖЕ фронтом, которым обновляется `nemo_ctl_l`, поэтому флаг физически не может
   обогнать данные (правило проекта: данные держать, флаг публиковать не раньше данных). */
reg nemo_arm_stb = 1'b0;
always @(posedge clock) begin
	nemo_we_s <= {nemo_we_s[1:0], nemo_ctl_we};
	nemo_arm_stb <= nemo_we_s[2] ^ nemo_we_s[1];
	if (nemo_we_s[2] ^ nemo_we_s[1]) nemo_ctl_l <= nemo_ctl;
end
wire       nemo_oe, nemo_sup;
wire [7:0] nemo_dbus;
wire [7:0] nemo_cmd, nemo_feat, nemo_cnt, nemo_lba0, nemo_lba1, nemo_lba2, nemo_head;
wire       nemo_cmd_stb;
wire [8:0] nemo_rptr;
nemo_ide nemo_i (
	.clk (clock), .reset_n (reset), .en (nemo_en), .dos_paged (trdos_live),
	.iorq_n (iorq), .m1_n (m1), .rd_n (rd), .wr_n (wr), .a (a[7:0]), .din (q),
	.dout (nemo_dbus), .oe (nemo_oe), .sup (nemo_sup),
	.ide_cmd (nemo_cmd), .ide_cmd_stb (nemo_cmd_stb),
	.ide_feat (nemo_feat), .ide_cnt (nemo_cnt),
	.ide_lba0 (nemo_lba0), .ide_lba1 (nemo_lba1), .ide_lba2 (nemo_lba2), .ide_head (nemo_head),
	.ide_status (nemo_ctl_l[13:6]), .ide_error ({4'd0, nemo_ctl_l[3:0]}),
	.buf_waddr (nemo_ctl_l[23:15]), .buf_wdata (nemo_ctl_l[31:24]), .buf_we (nemo_ctl_l[14]),
	.buf_raddr (nemo_rptr), .buf_arm_owns (nemo_ctl_l[5]), .dev_slave (nemo_dev_slave),
	.arm_stb (nemo_arm_stb),
	.drq_live (nemo_drq_live), .gap_wait (nemo_gap_wait)   // B0117
);
/* 🥇 B0113: ПОЛЯ ВЫРОВНЕНЫ ЯВНО. Раньше конкатенация была шириной 30 бит и, попав в 32-битный
   провод, уехала на два разряда - прошивка искала строб не там и не видела команд вовсе. Теперь
   ширина ровно 32, и рядом второе слово с полным адресом. */
wire nemo_dev_slave;
wire nemo_drq_live, nemo_gap_wait;   // B0117
/* B0117: два свободных разряда середины слова отданы взгляду ФАБРИКИ на передачу.
   [20] DRQ, которым она распоряжается сама, [19] «блок вычерпан, жду следующий».
   Прошивке этого не хватало физически: она узнавала об окончании блока по указателю, а ноль
   указателя означает и «вычерпано», и «только что записана команда» - отсюда весь хоровод с
   запоминанием максимума и признаком «указатель уже шевелился». Теперь есть прямой факт.
   Оставшиеся [18:16] держим нулями - под следующего желающего. */
assign nemo_stat  = {nemo_cmd_stb, nemo_dev_slave, nemo_rptr[8:0],
                     nemo_drq_live, nemo_gap_wait, 3'd0, nemo_cmd, nemo_lba0};
/* B0115: младший байт отдан СЧЁТЧИКУ СЕКТОРОВ (#50). Раньше он дублировал LBA0, который и так
   лежит в `nemo_stat`, а `r_cnt` наружу не выходил вовсе - без него нечем ни проверить свою же
   запись сигнатуры после 0x90, ни прочитать геометрию, которую хост задаёт командой 0x91.
   Ширина ровно 32 бита (8+8+8+8): на 30-битной конкатенации этот блок уже обжигался. */
assign nemo_stat2 = {nemo_head, nemo_lba2, nemo_lba1, nemo_cnt};

/* B0116 МЫШЬ KEMPSTON. Порты #FADF/#FBDF/#FFDF живут в `kempston_mouse.v`, а координаты считает
   ARM (сейчас их двигает цифровая клавиатура). Слово управления:
   [31] мышь включена, [18:16] кнопки {средняя, правая, левая}, [15:8] Y, [7:0] X.
   Переход в домен машины - тем же тогглом, что у NEMO-IDE и General Sound: нагрузка
   ДЕРЖИТСЯ целиком, синхронизируется ТОЛЬКО флаг, а сам флаг взводится НА ТАКТ ПОЗЖЕ
   данных (`km_arm_stb` регистрируется тем же фронтом, которым обновляется `km_ctl_l`, то есть
   физически не может его обогнать). Это наше правило CDC, оплаченное битой памятью Пентагона. */
(* ASYNC_REG="TRUE" *) reg [2:0] km_we_s = 3'b000;
reg [31:0] km_ctl_l = 32'd0;
reg        km_arm_stb = 1'b0;
always @(posedge clock) begin
	km_we_s <= {km_we_s[1:0], km_ctl_we};
	km_arm_stb <= km_we_s[2] ^ km_we_s[1];
	if (km_we_s[2] ^ km_we_s[1]) km_ctl_l <= km_ctl;
end
wire       km_oe;
wire [7:0] km_dbus;
kempston_mouse km_i (
	.clk (clock), .reset_n (reset), .en (km_en),
	.iorq_n (iorq), .m1_n (m1), .rd_n (rd), .a (a),          // B0132: весь адрес, было a[10:0]
	.dout (km_dbus), .oe (km_oe),
	.arm_x (km_ctl_l[7:0]), .arm_y (km_ctl_l[15:8]), .arm_btn (km_ctl_l[18:16]),
	.arm_stb (km_arm_stb)
);

assign d
	= !mreq ? memD
	: gs_oe ? gs_dbus                               // General Sound отвечает раньше прочих портов
	: nemo_oe ? nemo_dbus                           // NEMO-IDE СТРОГО раньше kempston: тот ловит a[5]=0
	: bd_oe ? bd_dout
	: km_oe ? km_dbus                               /* B0116 МЫШЬ СТРОГО раньше kempston-джойстика: тот
	                                                   ловит одно условие a[5]=0 и проглотил бы #xxDF целиком
	                                                   (та же мина, что у NEMO-IDE выше). После дисковода -
	                                                   пересечений с ним нет, но его приоритет трогать не станем */
	: !ioZC ? usdQ                                  /* 🥇 B0144 Z-CONTROLLER СТРОГО РАНЬШЕ kempston-джойстика.
	                                                   #57 = 0101_0111, то есть a[5]=0, и конус кемпстона
	                                                   (`ioDF`, одно условие) съедал его целиком: команды
	                                                   уходили (запись идёт мимо этого мукса), а на каждое
	                                                   чтение данных машина получала joy1|joy2 = 0x00.
	                                                   Приборно на плате: команд к карте 255 при НУЛЕ чтений,
	                                                   карта вечно на CMD0. #77 = 0111_0111 (a[5]=1) не задет -
	                                                   отсюда и картина «карта видит команды, ответов нет».
	                                                   Та же мина уже поднимала выше кемпстона NEMO-IDE, мышь
	                                                   и дисковод; из четырёх жертв бита 5 забыли ровно ZC.
	                                                   DivMMC (#EB/#E7) уцелел случайно: у него a[5]=1. */
	: !ioDF ? joy1|joy2
	: !ioEB ? usdQ
	: !ioFE ? { 1'b1, ear|speaker, 1'b1, keyQ }
	: !ioFFFD ? psgQ
	: pentagon ? ((ff_attr && a[7:0] == 8'hFF) ? vduQattr : 8'hFF)
	                                               /* Pentagon has NO floating bus: unmapped IN = 0xFF (MiSTer: mZX ? ff_data : 8'hFF).
	                                                  B0200 ff_attr: чтение #xxFF отдаёт атрибут (Sizif-512). Только младший
	                                                  байт #FF, как у Sizif; под TR-DOS порт раньше забирает bd_oe (Beta Disk),
	                                                  у SAA1099 на #FF только запись - ему чтение не мешает. */
	: vduQ;                                        // Sinclair floating bus (video fetch byte)

//-------------------------------------------------------------------------------------------------

assign vmmCe = pe7M0;
assign memCe = pc3M5;
assign memQ = q;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
