//-------------------------------------------------------------------------------------------------
module video
//-------------------------------------------------------------------------------------------------
(
	input  wire       model,
	input  wire       pentagon, // 1 = Pentagon raster (448x320; sources: MiSTer ula.sv / ZX-Uno / Speccy2010)
	input  wire       ula_late, // 1 = Sinclair Type 2/Late: raster/contention 1T later relative to CPU-facing /INT
	input  wire[31:0] ula_tune, // B0053 native-48 sweep: EN[31], FREEZE[30], EPOCH[29:24], IRQ_D9[23:15], ULA_D6[14:9], SRC[8:7]
	input  wire[8:0]  pent_int_v, // Pentium INT line (runtime-tunable; reference default 239)
	input  wire[8:0]  pent_int_h, // Pentium INT start hc (runtime-tunable; reference default 326)
	input  wire[8:0]  paper_h,    // live from ARM: h start of paper (left border offset)
	input  wire[8:0]  paper_v,    // live from ARM: v start of paper (top border offset)

	input  wire       clock,
	input  wire       ce,

	input  wire[ 2:0] border,
	output wire       irq,
	output wire       cn,
	output reg [12:0] a,
	input  wire[ 7:0] d,
	output reg [ 7:0] q,

	output wire       blank,
	output wire       hsync,
	output wire       vsync,
	output wire       r,
	output wire       g,
	output wire       b,
	output wire       i,
	output wire       scr_we,  // BulbuLator screen-mirror tap: 1 on the cycle a fetched bitmap/attr byte (d) is valid for address a
	output wire[8:0]  dbg_h,
	output wire[8:0]  dbg_v
);
//-------------------------------------------------------------------------------------------------

// Pentagon: 448 clk/line (224 T, like 48K) x 320 lines = 71680 T/frame; INT on line 239 late in the
// line (hc 326..397, 36 T) - constants cross-checked against MiSTer ula.sv, ZX-Uno pal_sync_generator
// and Speccy2010 (all agree). 128K keeps 456x311, 48K keeps 448x312.
wire[8:0] hCountEnd = pentagon ? 9'd448 : (model ? 9'd456 : 9'd448);
wire[8:0] vCountEnd = pentagon ? 9'd320 : (model ? 9'd311 : 9'd312);

wire tune_en = ula_tune[31] && !model && !pentagon;
wire[8:0] irqLine = pentagon ? pent_int_v : 9'd248;                     // Pentagon INT position is runtime-TUNABLE
// Raw /INT remains the frame-counter reference. main.v preserves the historical Atlas pc3M5
// re-sampling stage for Type 1 and bypasses it for Type 2, making the CPU-visible interrupt one T
// earlier relative to the delayed display phase. This matters independently of the picture: the
// original timing detector spins JP (HL) in uncontended RAM and samples R in its IM2 handler.
// The tuner is a signed +/-32 half-T displacement from the established native-48 start (h=2).
// Keep pulse width independent of phase and use modular membership so negative deltas that wrap to
// the end of the preceding line remain valid. Normal widths are unchanged: 48K=64, 128K=72 and
// Pentagon=72 7-MHz ticks.
wire signed [9:0] tune_irq_sum = 10'sd2 + {ula_tune[23],ula_tune[23:15]};
wire[8:0] tune_irq_beg = tune_irq_sum[9]
                       ? tune_irq_sum + 10'sd448
                       : tune_irq_sum[8:0];
wire[8:0] irqBeg   = pentagon ? pent_int_h : (tune_en ? tune_irq_beg : (model ? 9'd6 : 9'd2));
wire[8:0] irqWidth = pentagon ? 9'd72 : (model ? 9'd72 : 9'd64);
// A negative delta from native h=2 belongs to the PREVIOUS raster line. The IRQ pulse can then
// continue through h=0 of irqLine. Track the start line explicitly; an h-only modular comparator
// would incorrectly start such a pulse at h=0 of line 248 and collapse all deltas below -2.
wire[8:0] irqStartLine = (tune_en && tune_irq_sum[9])
                       ? (irqLine - 9'd1)
                       : irqLine;

// Pentagon paper window shift for correct wider border and logo position (to match reference boot screen).
// Now live from ARM menu (PAPER H/V OFF). Default 64/24 gives wider real-Pentagon look + correct logo height.
wire[8:0] h_paper_start = pentagon ? paper_h : 9'd0;
wire[8:0] v_paper_start = pentagon ? paper_v : 9'd0;

//-------------------------------------------------------------------------------------------------

reg[8:0] hc, hCount;
wire hCountReset = hc >= (hCountEnd-1);
always @(posedge clock) if(hCountReset) hCount <= 1'd0; else hCount <= hc+1'd1;
always @(posedge clock) if(ce) hc <= hCount;

reg[8:0] vc, vCount;
wire vCountReset = vc >= (vCountEnd-1);
always @(posedge clock) begin vCount <= vc; if(hCountReset) if(vCountReset) vCount <= 1'd0; else vCount <= vc+1'd1; end
always @(posedge clock) if(ce) vc <= vCount;

// Sinclair Type 2/Late ULA phase. hCount is a 7 MHz coordinate, hence two counts are exactly one
// 3.5 MHz CPU T-state. B0053 can sweep this delay from JTAG on native 48K without another synthesis.
// Use a wrapped raster coordinate delayed by the selected count for EVERY ULA event,
// while the physical frame counter and /INT above remain fixed.  At hCount 0/1 the delayed beam is
// still on the previous raster line, so vUla must wrap too.  Pentagon has no Ferranti ULA Early/Late
// variation and the top-level suppresses ula_late for that machine.
// Signed ULA phase: +2 preserves B004D "Late" semantics (events occur one CPU T later);
// a negative value advances the ULA coordinate and carries into the next raster line.
wire       tune_ula_negative = tune_en && ula_tune[14];
wire[5:0] tune_ula_magnitude = ula_tune[14]
                             ? (~ula_tune[14:9] + 6'd1)
                             : ula_tune[14:9];
wire[8:0] ulaShift = tune_en ? {3'd0,tune_ula_magnitude} : (ula_late ? 9'd2 : 9'd0);
wire[9:0] hUlaAdvance = {1'b0,hCount} + {1'b0,ulaShift};
wire      ulaAdvanceWrap = tune_ula_negative && (hUlaAdvance >= {1'b0,hCountEnd});
wire      ulaDelayWrap = !tune_ula_negative && (ulaShift != 0) && (hCount < ulaShift);
wire[8:0] hUla = tune_ula_negative
               ? (ulaAdvanceWrap ? (hUlaAdvance - {1'b0,hCountEnd}) : hUlaAdvance[8:0])
               : ((ulaShift != 0)
                  ? ((hCount >= ulaShift) ? (hCount - ulaShift) : (hCount + hCountEnd - ulaShift))
                  : hCount);
wire[8:0] vUla = ulaAdvanceWrap
               ? ((vCount >= (vCountEnd - 9'd1)) ? 9'd0 : (vCount + 9'd1))
               : (ulaDelayWrap
                  ? ((vCount == 9'd0) ? (vCountEnd - 9'd1) : (vCount - 9'd1))
                  : vCount);

reg[4:0] fc, fCount;
always @(posedge clock) begin fCount <= fc; if(hCountReset) if(vCountReset) fCount <= fc+1'd1; end
always @(posedge clock) if(ce) fc <= fCount;

//-------------------------------------------------------------------------------------------------

reg dataEnable;
// 🥇 B0127 PAN X / PAN Y РАБОТАЮТ В ОБЕ СТОРОНЫ. Жалоба владельца 12.08: «Pan X нужно было
// подвинуть ниже нуля, но не вышло», и следом — «основной экран немного смещён вправо относительно
// бордюра, разрыв виден на границе, INT H не помогает». Это одно и то же: INT H двигает момент
// прерывания, то есть бумагу И бордюр ВМЕСТЕ, а разъехались они ОТНОСИТЕЛЬНО друг друга. Двигать
// бумагу внутри растра умеет только paper_h, и он стоял в упоре на нуле.
// Раньше окно бумаги задавалось прямым сравнением, которое не заворачивается через край строки:
// при h_paper_start близком к концу строки h_paper_start+256 переполняло разрядность, окно
// схлопывалось в пустоту и бумага исчезала совсем. Поэтому «минус» был не запрещён, а НЕВОЗМОЖЕН.
// Теперь положение считается ОТНОСИТЕЛЬНО начала бумаги по модулю ДЛИНЫ СТРОКИ (hCountEnd), а не по
// модулю разрядности: 9-битное вычитание завернулось бы по 512, а строка у Пентагона 448 - это разные
// числа, и наивный вариант дал бы бумагу в двух местах сразу.
// Так paper_h становится КРУГОВЫМ: значение 447 это «минус один пиксель», 440 - «минус восемь».
// То же самое по вертикали, по модулю vCountEnd.
wire [9:0] h_rel_s = {1'b0, hUla} - {1'b0, h_paper_start};
wire [8:0] h_rel   = h_rel_s[9] ? (h_rel_s[8:0] + hCountEnd) : h_rel_s[8:0];
wire [9:0] v_rel_s = {1'b0, vUla} - {1'b0, v_paper_start};
wire [8:0] v_rel   = v_rel_s[9] ? (v_rel_s[8:0] + vCountEnd) : v_rel_s[8:0];
wire de = (h_rel < 9'd256) && (v_rel < 9'd192);
always @(posedge clock) if(ce) dataEnable <= de;

reg videoEnable;
// 🥇 РАЗРЕШЕНИЕ ВЫВОДА ЗАЩЁЛКИВАЕТСЯ ПО БУМАЖНОЙ КООРДИНАТЕ, А НЕ ПО РАСТРОВОЙ.
// Было `hUla[3]`. У нетронутого Atlas разницы не существовало вовсе - там hCount был
// ОДНОВРЕМЕННО и растром, и бумагой. Расхождение приехало вместе с paper_h (B0127): окно бумаги
// (:134), адреса (:261,:262), оба входных строба (:173,:177) и оба выходных (:186,:190) считаются
// по КРУГОВОЙ h_rel, а разрешение вывода - единственное во всём тракте - оставалось по СЫРОЙ
// hUla. Эталон держит ОДНУ координату на всё: MiSTer rtl/ula.sv:187 `if(hc_next[3]) VidEN <= ~Border;`.
// ЧТО ЛОМАЛОСЬ (свип в xsim на этом самом файле, растр 448x320, сверка полным кадром 143360 px).
// Окно защёлки шло по hUla mod 16 = 8..15, то есть по h_rel mod 16 = (8-p)..(15-p), где
// p = paper_h mod 16 (мод-16 арифметика чистая: 448 = 28*16). При p = 5..14 окно уезжало так, что
//   * последняя защёлка перед h_rel = 260 попадала уже за край бумаги и брала dataEnable = 0 -
//     ПОСЛЕДНЯЯ знакоместная клетка строки не грузилась в сдвигатель: бумага 248 px вместо 256;
//   * зато появлялась защёлка на h_rel = 1..3, где dataEnable с начала строки ещё 1, и на
//     h_rel = 4 сдвигатель ЛОЖНО грузился протухшим байтом ПРОШЛОЙ строки.
// Тонкая ветка бордюра (:226,:257-259) прячет 7 мусорных пикселей из 8 - кладёт цвет в оба поля, -
// наружу вылезал ровно один: тот, что попадает на строб attrOutputLoad с приоритетом. Итого ровно
// 9 расходящихся пикселей в каждой из 192 строк бумаги = 1728 за кадр.
// ГРАНИЦЫ ЗОНЫ (уточнение к разбору, там стояло «p >= 5»): сломано ровно p = 5..14. При p = 15 оба
// края сходятся снова - в окно попадает h_rel = 256 (даёт разрешение последней клетке) и h_rel = 0
// (снимает его на краю строки, dataEnable там уже 0). Поэтому кламп ini в 127 (p = 15), в отличие
// от 440 (p = 8), в сломанную зону НЕ попадал.
// РАБОЧИЕ ЧИСЛА ВЛАДЕЛЬЦА НЕ ЗАТРОНУТЫ: при PAPER H OFF = 0..4 и 15 выход совпадает с прежним
// БИТ-В-БИТ (0 расхождений на полном кадре 143360 px по всему набору выходов модуля, включая
// PAPER H OFF = 2). PENT INT H = 326 - другой провод целиком (:306-314), в нём videoEnableLoad не
// участвует; ширина импульса /INT в стенде 72 тика 7 МГц до и после правки.
wire videoEnableLoad = h_rel[3];
always @(posedge clock) if(ce) if(videoEnableLoad) videoEnable <= dataEnable;

//-------------------------------------------------------------------------------------------------

// B0127: адреса берутся из того же кругового относительного положения, что и окно бумаги -
// иначе при завороте они разъехались бы с `de` и экран посыпался бы.
wire [8:0] h_addr = h_rel;
wire [8:0] v_addr = v_rel;

reg[7:0] dataInput;
wire dataInputLoad = (h_addr[3:0] ==  9 || h_addr[3:0] == 13) && dataEnable;
always @(posedge clock) if(ce) if(dataInputLoad) dataInput <= d;

reg[7:0] attrInput;
wire attrInputLoad = (h_addr[3:0] == 11 || h_addr[3:0] == 15) && dataEnable;
always @(posedge clock) if(ce) if(attrInputLoad) attrInput <= d;

// BulbuLator screen-mirror tap: at dataInputLoad `a` holds the bitmap address + `d` the bitmap byte;
// at attrInputLoad `a` holds the attribute address (0x1800+) + `d` the attr byte. The parent samples
// (a,d) on this strobe (gated by ce) into a 6912-byte fabric mirror = the raw ZX screen "as it lands".
assign scr_we = dataInputLoad | attrInputLoad;

reg[7:0] dataOutput;
wire dataOutputLoad = h_addr[2:0] == 4 && videoEnable;
always @(posedge clock) if(ce) if(dataOutputLoad) dataOutput <= dataInput; else dataOutput <= { dataOutput[6:0], 1'b0 };

reg[7:0] attrOutput;
wire attrOutputLoad = h_addr[2:0] == 4;
// 🥇 B0121 БОРДЮР У ПЕНТАГОНА ОБНОВЛЯЕТСЯ КАЖДЫЙ ПИКСЕЛЬ, А НЕ РАЗ В ВОСЕМЬ.
// Atlas - ядро СИНКЛЕРОВСКОЕ, и у него цвет бордюра защёлкивается вместе с атрибутом, раз в 8
// пикселей (4 такта Z80). Для Синклера это верно - там бордюр действительно квантуется цепочкой
// выборки атрибутов. У Пентагона ULA так НЕ делает, и на нашей сетке любой бордюрный эффект
// рассыпается на блоки по 8 пикселей: волна, которая должна ползти на 1-2 такта в строке, ложится
// на грубую сетку и выглядит лесенкой из квадратов (жалоба владельца 12.08 по Across the Edge).
// Два независимых эталона говорят одно и то же:
//   MiSTer   rtl/ula.sv:184-185  - отдельная ветка с комментарием «1T update for border in Pentagon mode»
//   Sizif-512 cpld/rtl/video.sv:186 - border_update = screen_update || (machine == MACHINE_PENT && ck7)
// Цвет кладём в ОБА поля (бумага И чернила), как оба эталона: иначе на переходе бумага->бордюр
// dataOutput ещё до восьми пикселей досдвигается нулями, и в этом окне светится протухшая краска
// из attrInput[2:0].
// Одно присваивание с ЯВНЫМ разрешением, а не два подряд с расчётом на «последнее побеждает»:
// так синтезатору виден обычный триггер с разрешением и мультиплексором. Два присваивания подряд
// дали разводку с недотрассированной цепью питания (VCC -> SLICE.CLK, DRC RTSTAT-9) в двух прогонах
// B0121 подряд, а у B0120 такого не было ни в одном из трёх - то есть корень был в форме записи.
// 🥇 B0122 ГЕЙТ ТОНКОГО БОРДЮРА — ПО КЛЕТКЕ, А НЕ ПО ФЛАГУ videoEnable.
// В B0121 тонкая ветка гейтилась `~videoEnable`, а этот флаг обновляется только по hUla[3],
// то есть падает на 3-4 пикселя РАНЬШЕ, чем сдвигатель домалывает последний байт бумаги
// (загрузка на h_addr[2:0]==4, вывод — следующие восемь тактов). Результат: последние 3-4
// пиксельных столбца БУМАГИ в КАЖДОЙ строке красились цветом бордюра. Владелец увидел это как
// «непонятный сдвиг бордюра вправо, и INT H его не лечит» — и правильно, INT H двигает программу,
// а тут ехал наш собственный край картинки.
// Оба эталона гейтят по КООРДИНАТЕ отображаемой бумаги: MiSTer rtl/ula.sv:185
// (`hc_next<12 | hc_next>267 | vc>=192`), Sizif cpld/rtl/video.sv:184,264-267 (окно screen_show).
// Здесь то же самое, но без магических чисел и без зависимости от живой настройки paper_h:
// признак «эта знакоместная клетка — БУМАГА» защёлкивается ТЕМ ЖЕ стробом attrOutputLoad, что и
// сама клетка, поэтому окно совпадает с выводом сдвигателя такт-в-такт по построению.
// Вариант без лишнего триггера: окно берём КООРДИНАТАМИ, буквально как MiSTer
// (`hc_next<12 | hc_next>267 | vc>=192`). Бумага ПОКАЗЫВАЕТСЯ на h_addr 12..267 (загрузка
// сдвигателя на h_addr[2:0]==4, вывод — следующие восемь тактов), по вертикали окно v_addr < 192.
// Разности h_addr/v_addr модульные, поэтому «до начала бумаги» само попадает в ветку бордюра.
// Регистр paperShown из первой редакции убран: на 91 % LUT он столкнул схему с обрыва —
// ExtraTimingOpt перестал РАЗМЕЩАТЬ, а Explore разместил, но развести не удалось (перекрытия
// колебались 25..49 тысяч вместо схождения к нулю).
wire borderFine = pentagon & ((v_addr >= 9'd192) | (h_addr < 9'd12) | (h_addr > 9'd267));
// 🥇 НА СОВПАДЕНИИ СТРОБОВ ПОБЕЖДАЕТ БОРДЮР, КАК У ЭТАЛОНА (было наоборот).
// Прежний текст объяснял приоритет через регистр paperShown, которого в этой редакции уже НЕТ
// (выброшен, сказано выше) - объяснение через несуществующий сигнал.
// Эталон: MiSTer пишет атрибут (rtl/ula.sv:178) и следом ПЕРЕТИРАЕТ его бордюрной веткой
// (rtl/ula.sv:185) - при совпадении побеждает БОРДЮР. У нас одно присваивание (форма выбрана
// из-за DRC RTSTAT-9, см. выше), поэтому порядок задаётся ЯВНО термом ~borderFine.
// СЕГОДНЯ ЭТО NO-OP, И ЭТО ДОКАЗАНО, А НЕ ОБЕЩАНО: комбинация attrOutputLoad & videoEnable &
// borderFine НЕДОСТИЖИМА ни при каком paper_h. После правки videoEnableLoad (:162) разрешение на
// такте L = dataEnable с последнего строба h_rel[3] перед L: для строба h_addr = 16n+4 это
// de(16n-2), для h_addr = 16n+12 - de(16n+10). В окне borderFine эти выборки дают ноль всегда:
// h_addr = 4 -> de(446) (конец строки, h_rel >= 256); h_addr >= 268 -> de(>= 266); v_addr >= 192 ->
// de = 0 всей строкой. Стенд подтверждает числом: 0 расхождений с прежней формой на полном кадре
// 143360 px во ВСЕХ конфигурациях (paper_h 0..4 / 5..14 / 15 / 127 / 440 / 447, Пентагон и
// Синклер), при том что сам регистр attrOutput в этих же прогонах меняется десятки тысяч тактов за
// кадр - то есть стимул до места доходит, а наружу не выходит.
// ЗАЧЕМ ТОГДА ПРАВИТЬ: недостижимость - свойство ТАЙМИНГА videoEnable, а не структуры записи.
// Сдвинется точка выборки ещё раз - и мы разойдёмся с эталоном МОЛЧА, цветом первой клетки.
// 🥇 БОРДЮР КЛАДЁТСЯ В ОБА ПОЛЯ И В ГРУБОЙ ВЕТКЕ ТОЖЕ (догнали эталон).
// Было `{ 2'b00, border, attrInput[2:0] }`: при videoEnable = 0 в чернилах оставалась ПРОТУХШАЯ
// краска последнего атрибута, и до восьми пикселей на переходе бумага->бордюр она могла светиться
// (сдвигатель в этом окне ещё домалывает последний байт, единицы в нём выбирают именно чернила).
// Оба эталона пишут цвет бордюра в ОБА поля одним присваиванием: MiSTer rtl/ula.sv:178,
// Sizif-512 cpld/rtl/video.sv:267. Тонкая ветка (Пентагон) так делала с самого B0121 - теперь обе.
// Форма записи прежняя и по той же причине: ОДНО присваивание с явным разрешением, а не два
// подряд с расчётом на «последнее побеждает» (см. DRC RTSTAT-9 выше).
// Проверено стендом: сам регистр attrOutput при этом РАЗНЫЙ (11776 тактов за кадр у Пентагона,
// 92664 у Синклера), а видимый выход - НЕТ: 0 расхождений на полном кадре по всему набору выходов
// модуля, и в Пентагоне (тонкая ветка перетирает следующим тиком), и в 48/128 (в этих тактах
// сдвигатель уже вымыт нулями, dataOutput[7] = 0, то есть чернила не выбираются). То есть правка
// каноническая и заведомо безопасная, а не косметика «на глазок».
always @(posedge clock) if(ce) if(attrOutputLoad | borderFine)
    attrOutput <= (attrOutputLoad & videoEnable & ~borderFine) ? attrInput
                                                               : { 2'b00, border, border };

wire addrLoad = dataEnable && h_addr[3] && !h_addr[0];
always @(posedge clock) if(ce) if(addrLoad) a <= { !h_addr[1] ? { v_addr[7:6], v_addr[2:0] } : { 3'b110, v_addr[7:6] }, v_addr[5:3], h_addr[7:4], h_addr[2] };

wire fbLoad = dataEnable && h_addr[3] && h_addr[0];
wire fbReset = h_addr[3:0] == 1;
// B0154: ПЛАВАЮЩАЯ ШИНА ОТДАЁТСЯ НА ТАКТ ПОЗЖЕ - две ступени по пиксельному разрешению (1 T = 2 px).
// Эталон снят с НАСТОЯЩЕГО 48K тестом ulatest3 (Потапов, ep4spectrum `beedeb5`): в восьмитактовой
// группе идёт `FF FF FF битмап атрибут битмап атрибут FF`, байты читаются как 00 40 01 41. У нас на
// плате тем же тестом (`0:/test/measure/ULAT3ORG.TAP`, и он же ulatest2) данные стояли на тактах
// 14339..14342 вместо 14340..14343 - ровно на такт раньше.
// ПОЧЕМУ ЗДЕСЬ, А НЕ В САМОЙ ВЫБОРКЕ: строб `fbLoad` - это ТОТ ЖЕ строб, что `dataInputLoad` (9,13)
// объединённый с `attrInputLoad` (11,15), поэтому «подвинуть шину, не тронув выборку» условием строба
// нельзя в принципе. А порог теста stime (последний такт, на котором запись в 16384 ещё видна в этом
// кадре) держится ОКНОМ КОНТЕНШЕНА, а не выборкой, и имеет запас 1.75 T - измерено стендом: с этой
// правкой порог остаётся ровно 14335, как на настоящей машине, а окно контеншена не шевелится.
// ЧЕСТНАЯ ОГОВОРКА: наблюдаемое приведено к эталону, но этим НЕ доказано, что сама выборка ULA теперь
// стоит правильно - у Потапова та же разница вылечена сдвигом `fetch_start`. Различить два механизма
// может только прибор, видящий момент ВЫБОРКИ (снег: `snow_off=0`, узор порчи зависит от фазы).
reg[7:0] fb_lat = 8'hFF;
always @(posedge clock) if(ce) if(fbLoad) fb_lat <= d; else if(fbReset) fb_lat <= 8'hFF;
reg[7:0] fb_d1 = 8'hFF;
always @(posedge clock) if(ce) begin fb_d1 <= fb_lat; q <= fb_d1; end

//-------------------------------------------------------------------------------------------------

// 🥇 B0126 ГАШЕНИЕ СДВИНУТО НА ЗАДЕРЖКУ КОНВЕЙЕРА ULA — РОВНО НА +12 — КАРТИНКА ВСТАЁТ ПО ЦЕНТРУ.
// (Заголовок раньше врал «+13», хотя в коде и в теле комментария всегда стояло 12; исправлено,
// чтобы никто не «дочинил» константы до 13 по заголовку.)
// Жалоба владельца 12.08: «если разделить экран на три части по вертикали, всё сдвинуто вправо,
// левый бордюр шире правого». Измерено по кадру в DDR: бумага лежит на столбцах 77..332, то есть
// слева 77 пикселей бордюра, справа 51 — картинка на 13 px правее середины, и справа срезается
// около 2 px того, что настоящий Пентагон показывает.
// Причина не в настройках: между растровой координатой и ВЫВОДОМ пикселя лежит конвейер выборки
// (адрес на h_addr 8, байт на 9, защёлка сдвигателя на 12 — бумага ВЫВОДИТСЯ на hUla 12..267, это
// же окно у тонкого бордюра MiSTer, ula.sv:185 `hc_next<12 | hc_next>267`), а гашение стояло по
// СЫРОЙ координате, без компенсации. Sizif предкомпенсирует то же самое явной константой
// SCREEN_DELAY (cpld/rtl/video.sv:68,92-93).
// ПОЧЕМУ ИМЕННО +12, А НЕ SCREEN_DELAY = 13 КАК У SIZIF. Число задаётся ГЕОМЕТРИЕЙ строки, а не
// «правильной» глубиной конвейера, и геометрия у нас с ними разная:
//   у нас  видимых 384, бумага 256 -> остаток 128, ЧЁТНЫЙ -> ровные 64/64 достижимы. До сдвига
//          было 76 слева и 52 справа; уравнение 76-s = 52+s даёт РОВНО s = 12, целое. Подставь
//          сюда чужую 13 - получишь 63/65, то есть перекос в пиксель на ровном месте;
//   у Sizif видимых 363, бумага 256 -> остаток 107, НЕЧЁТНЫЙ: сойтись в ноль там нельзя в принципе,
//          и константы 54-SCREEN_DELAY / 53+SCREEN_DELAY честно дают 54 слева и 53 справа
//          (cpld/rtl/video.sv:92-93). Вдобавок SCREEN_DELAY входит у них И в окно бумаги (:184), И
//          в ширины бордюров, поэтому подстановка SCREEN_DELAY = 0 даёт ту же геометрию на экране -
//          это ИХ обозначение задержки выборки, которое сокращается, а не наша поправка гашения.
//          У нас сокращаться нечему: окно бумаги прибито стробами выборки (12..267), двигается
//          только гашение, поэтому 12 - это измеренная величина, а не переписанная константа.
// Ширина гашения НЕ меняется (64 и 32), поэтому в строку по-прежнему набирается ровно 384 видимых
// пикселя (447-396+1 = 52, плюс 0..331 = 332, итого 384) и контракт захвата CAP_W=384 не трогается.
// После правки слева от бумаги 52+12 = 64 пикселя, справа 268..331 = 64 — ИДЕАЛЬНАЯ симметрия.
// ⚠ На HDMI картинка уедет ВЛЕВО примерно на 26 точек (при двукратном увеличении). Это ожидаемо.
wire hBlank = pentagon ? (hUla >= 332 && hUla < 396)   // Pentagon: 64-clk hblank, сдвинут на задержку конвейера (было 320..383)
                       : (hUla >= 320 && hUla < 416);  // Sinclair: 96-clk (proven)
wire vBlank = pentagon ? (vUla >= 296 && vUla < 304) : (vUla >= 248 && vUla < 256);  // Pentagon vblank around vsync for small top border

wire dataSelect = dataOutput[7] ^ (fCount[4] & attrOutput[7]);

//-------------------------------------------------------------------------------------------------

wire[9:0] irqStopSum = {1'b0,irqBeg} + {1'b0,irqWidth};
wire      irqWrap = irqStopSum >= {1'b0,hCountEnd};
wire[8:0] irqStopH = irqWrap ? (irqStopSum - {1'b0,hCountEnd}) : irqStopSum[8:0];
wire[8:0] irqNextLine = irqStartLine >= (vCountEnd - 9'd1) ? 9'd0 : (irqStartLine + 9'd1);
wire      irqActive = irqWrap
                    ? ((vCount == irqStartLine && hCount >= irqBeg) ||
                       (vCount == irqNextLine && hCount < irqStopH))
                    : (vCount == irqStartLine && hCount >= irqBeg && hCount < irqStopH);
assign irq = !irqActive;
// ⚠️ МИНА ДЛЯ СЛЕДУЮЩЕГО: `cn` СТОИТ НА СЫРОЙ hUla, И ЭТО ВЕРНО. НЕ «ПРИВОДИТЬ К h_rel».
// Выборка ULA после B0127 считается по КРУГОВОЙ h_rel, а узор контеншена - по РАСТРОВОЙ hUla, и
// системы отсчёта у них разные НЕ СЛУЧАЙНО.
// 1. Само выражение трогать нельзя ни в какой форме: оно тождественно всем трём эталонам -
//    Atlas (наш апстрим) src/video.v:119 `cn = dataEnable && (hCount[3] || hCount[2])`,
//    Sizif-512 cpld/rtl/video.sv:291 `contention = (vc<V_AREA) && (hc<H_AREA) && (hc[2]||hc[3])`
//    (сверено с ЖИВЫМ апстримом 13.08), MiSTer rtl/ula.sv:250-251 `clkwait_next = hc_next[2] |
//    hc_next[3]` в `ulaContend`. Поворот узора «для единообразия» сдвинет первый контендящийся
//    такт относительно /INT, а это прямо меряется софтом (классические тесты 14335/14336).
// 2. Сегодня вопрос вообще пуст, и это проверяется по коду: у Синклера h_paper_start прибит к нулю
//    (:68), то есть h_rel и hUla там ОДИН И ТОТ ЖЕ провод; у Пентагона контеншена нет вовсе -
//    main.v:148 `contend = (pentagon | warp_nc) ? 1'b1 : ...`, и `cn` в уравнение не входит.
//    Значит правка была бы NO-OP по логике и при этом лишним риском по таймингу.
// 3. Почему именно ОШИБКА, а не «всё равно»: /INT считается от СЫРЫХ hCount/vCount (:310-313).
//    Переведи `cn` на h_rel - и PAN X, чисто ЭКРАННАЯ ручка центровки, начнёт двигать узор
//    контеншена относительно /INT: один и тот же код в ПЗУ будет насчитывать разное число тактов
//    в зависимости от того, как владелец отцентровал картинку. Косметическая настройка не имеет
//    права менять тайминги машины.
// 4. Если PAN X когда-нибудь откроют для 48/128 (сейчас закрыт тем же :68) - это решение
//    ВЛАДЕЛЬЦА, а не рефакторинг мимоходом: надо решить, ручка двигает только окно показа или
//    вместе с ним и слот выборки ULA. По правилу проекта такое спорное идёт в ОПЦИЮ МАШИНЫ с
//    записанным «когда её трогать», а не в молчаливую унификацию координат. Тогда же придётся
//    честно посмотреть и на ПЕРВЫЙ терм: у Sizif оба терма стоят на сырой hc, у нас же dataEnable
//    уже живёт в бумажной системе - то есть выражение гибридное, и решать надо про всё сразу.
assign cn = dataEnable && (hUla[3] || hUla[2]);

assign blank = hBlank | vBlank;
assign hsync = pentagon ? (hUla >= 332 && hUla < 364) : (hUla >= 344 && hUla < 376);  // B0126: Pentagon hsync сдвинут вместе с гашением на +12 (было 320..351); 332 = 320+12, ширина 32 не менялась
assign vsync = pentagon ? (vUla >= 300 && vUla < 304) : (vUla >= 248 && vUla < 252);  // move vsync later for small top border after vsync -> logo higher in frame like reference

// B0156: Live-tunable border & paper pipeline
wire [3:0] b_phase   = tune_en ? ula_tune[3:0]   : 4'd5;
wire [1:0] b_delay   = tune_en ? ula_tune[25:24] : 2'd0;
wire [3:0] pap_delay = tune_en ? ula_tune[29:26] : 4'd0;

// Border latching: quantized to b_phase on Sinclair, 1-pixel on Pentagon
wire border_update = pentagon ? 1'b1 : (hUla[3:0] == b_phase);
reg [2:0] border_lat = 3'b000;
reg [2:0] border_d1 = 3'b000, border_d2 = 3'b000, border_d3 = 3'b000;
always @(posedge clock) if(ce) begin
    if(border_update) border_lat <= border;
    border_d1 <= border_lat;
    border_d2 <= border_d1;
    border_d3 <= border_d2;
end
wire [2:0] border_live = (b_delay == 2'd3) ? border_d3 :
                         (b_delay == 2'd2) ? border_d2 :
                         (b_delay == 2'd1) ? border_d1 : border_lat;

// Paper delay pipeline (0..15 pixels)
reg [14:0] pipe_act = 15'd0;
reg [14:0] pipe_r   = 15'd0;
reg [14:0] pipe_g   = 15'd0;
reg [14:0] pipe_b   = 15'd0;
reg [14:0] pipe_i   = 15'd0;

wire raw_act = (videoEnable & ~borderFine);
wire raw_r   = dataSelect ? attrOutput[1] : attrOutput[4];
wire raw_g   = dataSelect ? attrOutput[2] : attrOutput[5];
wire raw_b   = dataSelect ? attrOutput[0] : attrOutput[3];
wire raw_i   = videoEnable ? attrOutput[6] : 1'b0;

always @(posedge clock) if(ce) begin
    pipe_act <= {pipe_act[13:0], raw_act};
    pipe_r   <= {pipe_r[13:0],   raw_r};
    pipe_g   <= {pipe_g[13:0],   raw_g};
    pipe_b   <= {pipe_b[13:0],   raw_b};
    pipe_i   <= {pipe_i[13:0],   raw_i};
end

wire is_paper = (pap_delay == 4'd0) ? raw_act : pipe_act[pap_delay - 1];
wire dot_r    = (pap_delay == 4'd0) ? raw_r   : pipe_r[pap_delay - 1];
wire dot_g    = (pap_delay == 4'd0) ? raw_g   : pipe_g[pap_delay - 1];
wire dot_b    = (pap_delay == 4'd0) ? raw_b   : pipe_b[pap_delay - 1];
wire dot_i    = (pap_delay == 4'd0) ? raw_i   : pipe_i[pap_delay - 1];

assign r = is_paper ? dot_r : border_live[1];
assign g = is_paper ? dot_g : border_live[2];
assign b = is_paper ? dot_b : border_live[0];
assign i = is_paper ? dot_i : 1'b0;
assign dbg_h = hCount;
assign dbg_v = vCount;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
