/* gs_gap_bench.c — ХОСТОВОЙ СТЕНД: во что обходятся звуку General Sound наши ДОРОГИЕ ОБМЕНЫ.
 *
 * Зачем. На плате слышны провалы звука на стыках паттернов, и только при открытом окне трекера
 * (Z-Player), а в игре и в TR-DOS тот же модуль играет ровно. Диагноз по исходникам прошивки карты
 * (gs105b): главный цикл карты обслуживает КОМАНДУ раньше звука; `#63`/`#64` отдают по 4 байта, и
 * после каждого стоит `CALL HSEND`, а HSEND КРУТИТСЯ, пока Спектрум байт не заберёт (COM_H.a80).
 * Пока карта висит в HSEND, `CALL ENGINE` не зовётся, кольцо квантов (8×256×4 = 54.6 мс) пустеет,
 * прерывание уходит в QTFAULT (INTTST.a80:160) и кончается `RET` БЕЗ `EI` — прерывания остаются
 * запрещены, сэмплы не защёлкиваются, ЦАП держит уровень. Это и есть слышимая ДЫРА.
 * У настоящей GS круг обмена стоит 2..10 мкс. У нас он идёт через оболочку на ARM: не меньше двух
 * проходов главного цикла (замеренный худший проход — 134 мс).
 *
 * Что делает стенд. Превращает это в ЧИСЛА: цена одного обмена `D` — параметр, дыры — измеряются.
 *   Часы: виртуальные такты карты, 12 МГц (стенд крутит карту квантами по 64 такта).
 *   Прибор: ЗАЩЁЛКИВАНИЯ сэмплов (карта защёлкивает канал ЧТЕНИЕМ окна 0x6000..0x7FFF). Пока карта
 *   играет, защёлки идут 4 штуки на прерывание, 37480 раз в секунду — ~150 тыс/с, то есть в норме
 *   между защёлками не больше ~320 тактов. Разрыв длиннее 1 мс = слышимая дыра.
 *   Звук: эффект (FX), а не модуль — у эффекта нет ни паттернов, ни инструментов, поэтому стенд
 *   меряет ИМЕННО цену обмена, а ничего больше.
 *   Модель Спектрума: раз в кадр (20 мс) окно трекера спрашивает `#63` и `#64`; байт забирается не
 *   сразу — сперва карта крутится `D` мкс (это и есть наша медленная оболочка), потом чтение.
 *
 * ДВА РЕЖИМА:
 *   обычный  — как сейчас: карта висит в HSEND все `D` мкс на каждый байт;
 *   `-q`     — МОДЕЛЬ ПОЧИНКИ: оболочка (ПЛИС) забирает байт у карты СРАЗУ, как только поднялся
 *              бит7, и кладёт в очередь ответов; «Спектрум» вычерпывает очередь со своей задержкой
 *              `D`. Карта не ждёт круга через главный цикл.
 *
 * Как пользоваться (ThinkPad, обычный gcc, плата не нужна):
 *   mkdir -p /tmp/gsgap && cd /tmp/gsgap
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_arm.c .
 *   cp -r ~/bulb-v13/research/15-pentagon/arm/z80emu .
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_z80user.h z80emu/z80user.h
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_gap_bench.c .
 *   cp ~/bulb-v13/research/15-pentagon/assets_gs105b.rom gs105b.rom
 *   gcc -O2 -DGS_HOST_TEST -o gsgap gs_gap_bench.c gs_arm.c z80emu/z80emu.c -I.
 *   ./gsgap                                  # свип обычного режима
 *   ./gsgap -q                               # свип «очереди ответов» (модель починки)
 *   ./gsgap -p                               # проба: играет ли эффект и сколько длится
 *   ./gsgap -d 1000,1500,2000                # свой список цен обмена
 *   ./gsgap -d 25 -x 134000 -X 50            # редкий дорогой проход: раз в 50 кадров обмен по 134 мс
 * Ключи: -r <ПЗУ> -s <секунд на точку> -l <байт в сэмпле> -d <список D, мкс> -x <всплеск, мкс>
 *        -X <период всплеска, кадров> -q -p
 *
 * ⚠ Флаг `-DGS_HOST_TEST` обязателен: без него gs_arm.c не отдаёт отладочные хуки.
 *
 * ============================ ЧТО ЭТИМ СТЕНДОМ УЖЕ ЗАМЕРЕНО (12.08.2026) ============================
 *   1. Обычный режим, эффект: дыр НЕТ при D = 0/25/100/250/1000 мкс; порог между 1800 и 2000 мкс
 *      (при 2000 мкс — 120 дыр за 10 с, худшая 5.2 мс; при 5000 мкс — 218 дыр, худшая 18.5 мс,
 *      39.8 % времени в дырах). Дыра ВСЕГДА сопровождается ростом QTFAULT и «удержанных прерываний»,
 *      то есть это собственный underrun карты, а не наш звуковой тракт.
 *   2. Режим очереди ответов: дыр НЕТ ВООБЩЕ — ни при 5 мс, ни при 134 мс на обмен. Приёмка пройдена.
 *   3. Порог по ОДНОМУ дорогому обмену: дыра = всплеск − 46.8 мс (линейно, четыре точки). То есть
 *      предбуфер карты прощает ровно один тяжёлый проход оболочки короче ~47 мс — это её кольцо
 *      квантов (54.6 мс) минус один незаполненный квант (6.8 мс). Наш худший проход 134 мс даёт
 *      дыру 87 мс, замерено.
 *   4. `#62` карта отдаёт БЕЗ `HSEND` (OUT/OUT/RET) — на нём она не висит вовсе: всплеск 134 мс,
 *      посаженный на `#62`, не даёт ни одной дыры. Блокируют только `#63`/`#64` (по 4 байта).
 *   5. Эффект — САМЫЙ ЛЁГКИЙ случай. Тот же опрос на настоящем модуле (стенд `gs_host_fx_test.c`,
 *      ключ GS_ZP=1, 4 канала + разбор паттернов) ломается уже на ~0.5 мс на обмен. Порог 1.8 мс
 *      здесь — ВЕРХНЯЯ оценка, у музыки запас втрое меньше.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* --- сторона Спектрума и приборы у модели карты (gs_arm.c) --- */
extern void     gs_reset(void);
extern uint32_t gs_run(uint32_t cycles);
extern int      gs_dbg_load_rom(const void* p, unsigned n);
extern void     gs_zx_write_cmd (uint8_t v);
extern void     gs_zx_write_data(uint8_t v);
extern uint8_t  gs_zx_read_data (void);
extern uint8_t  gs_zx_read_stat (void);
extern void     gs_mix(int16_t* l, int16_t* r);
extern unsigned gs_inq_room(void);
extern unsigned gs_inq_used(void);
extern unsigned gs_latch_get(void);
extern unsigned gs_pc_get(void);
extern unsigned gs_int_get(void);
extern unsigned gs_intheld_get(void);
extern unsigned gs_hits_get(unsigned i);      /* 0 HSEND, 1 HGET, 2 HTAIL2, 3 QTFAULT, 4 QTPLAY */
extern void     gs_diag2_reset(void);
extern unsigned gs_ram4(unsigned addr);
extern unsigned gs_vols_get(void);

#define CARD_HZ    12000000LL                 /* такт карты */
#define QUANT      64                         /* квант прогона, тактов (5.3 мкс) */
#define FRAME_CYC  240000LL                   /* кадр Спектрума, 20 мс */
#define HOLE_CYC   12000LL                    /* «дыра» = разрыв защёлок длиннее 1 мс */
#define US(x)      ((long long)(x) * 12LL)    /* мкс -> такты карты */

/* ---------------- часы и прибор дыр ---------------- */
static long long g_cyc;                       /* виртуальные такты карты, монотонно */
static unsigned  g_lat_prev;                  /* прошлое значение счётчика защёлок */
static long long g_lat_cyc;                   /* такт последней защёлки */
static int       g_meas;                      /* меряем (стартовый всплеск отсечён) */
static long long g_gap_max, g_gap_sum;
static unsigned  g_gap_n;
static unsigned  g_lat_base;                  /* защёлок на начало измерения */
static int       g_peak;                      /* пик микшера за точку */
static unsigned  g_hole_ticks, g_hole_hsend;  /* где карта проводит время ВНУТРИ дыры */
static unsigned  g_to;                        /* тайм-аутов стенда (модель врёт, если > 0) */

/* ---------------- режим «очередь ответов» ---------------- */
static int       g_qmode;
#define QLEN 65536u
static uint8_t   g_q[QLEN];
static unsigned  g_qw, g_qr, g_qmax;

static void qpush(uint8_t b){
    if((g_qw - g_qr) < QLEN){ g_q[g_qw & (QLEN-1u)] = b; g_qw++; }
    if((g_qw - g_qr) > g_qmax) g_qmax = g_qw - g_qr;
}
static int qpop(uint8_t* b){ if(g_qw == g_qr) return 0; *b = g_q[g_qr & (QLEN-1u)]; g_qr++; return 1; }
static void qflush(void){ g_qw = g_qr = 0; }

/* Один квант жизни карты. ВСЁ время стенда течёт только здесь — иначе прибор врёт. */
static void tick(void)
{
    uint32_t did = gs_run(QUANT);
    if(did == 0u){ printf("!! gs_run вернул 0 — ПЗУ не загружено\n"); exit(3); }
    g_cyc += (long long)did;

    /* Модель починки: оболочка снимает байт с карты в тот же квант, в котором он появился. */
    if(g_qmode && (gs_zx_read_stat() & 0x80u)) qpush(gs_zx_read_data());

    { int16_t L, R; gs_mix(&L, &R);
      int a = L < 0 ? -L : L, b = R < 0 ? -R : R;
      if(a > g_peak) g_peak = a;
      if(b > g_peak) g_peak = b; }

    { unsigned l = gs_latch_get();
      if(l != g_lat_prev){
          long long gap = g_cyc - g_lat_cyc;
          if(g_meas && gap > HOLE_CYC){ g_gap_n++; g_gap_sum += gap; if(gap > g_gap_max) g_gap_max = gap; }
          g_lat_prev = l; g_lat_cyc = g_cyc;
      } else if(g_meas && (g_cyc - g_lat_cyc) > HOLE_CYC){
          unsigned pc = gs_pc_get();
          g_hole_ticks++;
          if(pc >= 0xC24Du && pc <= 0xC27Fu) g_hole_hsend++;   /* HSEND/HGET/HTAIL2 */
      }
    }
}

static void run_cyc(long long n){ long long e = g_cyc + n; while(g_cyc < e) tick(); }

/* --- канонические ожидания протокола, но с тайм-аутом: стенд обязан не висеть, а СКАЗАТЬ, где --- */
static int wait_cmd_clear(const char* who){
    long long lim = g_cyc + CARD_HZ;                       /* 1 виртуальная секунда */
    while(gs_zx_read_stat() & 0x01u){
        if(g_cyc > lim){ g_to++; printf("  !! ТАЙМ-АУТ WC (%s)\n", who); return 0; }
        tick();
    }
    return 1;
}
static int wait_room(const char* who){
    long long lim = g_cyc + CARD_HZ;
    while(gs_inq_room() == 0u){
        if(g_cyc > lim){ g_to++; printf("  !! ТАЙМ-АУТ WD (%s)\n", who); return 0; }
        tick();
    }
    return 1;
}
static int wait_out_byte(const char* who, long long limcyc){
    long long lim = g_cyc + limcyc;
    while(!(gs_zx_read_stat() & 0x80u)){
        if(g_cyc > lim){ g_to++; if(who) printf("  !! ТАЙМ-АУТ WN (%s)\n", who); return 0; }
        tick();
    }
    return 1;
}
static int sc(uint8_t cmd, const char* who){
    if(!wait_cmd_clear(who)) return 0;
    gs_zx_write_cmd(cmd);
    return wait_cmd_clear(who);
}
static int sd(uint8_t v, const char* who){
    if(!wait_room(who)) return 0;
    gs_zx_write_data(v);
    return 1;
}

/* ---------------- окно трекера: одна команда, N байт ответа ---------------- */
static long long g_lat_cyc_cost;              /* цена одного обмена, тактов карты */

static unsigned g_stale;                      /* сколько «залежавшихся» байт пришлось слить */

/* Слить байт, оставшийся от прошлого обмена: иначе счёт байт ответа уезжает на единицу и стенд
   ждёт несуществующий пятый байт. Оплачено ложным замером «#63 отдал 5 байт». */
static void drain_stale(void)
{
    if(g_qmode){ while(g_qw != g_qr){ g_qr++; g_stale++; } return; }
    for(int k = 0; k < 16 && (gs_zx_read_stat() & 0x80u); k++){ (void)gs_zx_read_data(); g_stale++; tick(); }
}

/* 🥇 РЕДКИЙ ДОРОГОЙ ПРОХОД. На плате главный цикл оболочки обычно быстрый, но хвост у него тяжёлый:
   замерено 1077 проходов длиннее 1 мс и худший 134 мс. Один такой проход стоит одного обмена, а
   ждать его карта будет в HSEND. Ключи -x (цена всплеска, мкс) и -X (раз в сколько кадров). */
static long long g_spike_cyc;                 /* цена всплеска, тактов (0 = всплесков нет) */
static unsigned  g_spike_per = 50;            /* период всплеска в кадрах */
static int       g_spike_arm;                 /* всплеск взведён на этот кадр */
static unsigned  g_spike_n;                   /* сколько всплесков реально выдано */

static long long exchange_cost(int spike_ok)
{
    if(spike_ok && g_spike_arm && g_spike_cyc){ g_spike_arm = 0; g_spike_n++; return g_spike_cyc; }
    return g_lat_cyc_cost;
}

/* spike_ok=0 у #62: по разбору прошивки этот запрос отдаёт байт БЕЗ `CALL HSEND` (OUT/OUT/RET),
   то есть карта на нём не висит вовсе, и всплеск на нём ничего не доказывает. Проверено опытом:
   всплеск 134 мс, посаженный на #62, дыр не даёт совсем, а тот же всплеск на #63 даёт 79 мс. */
static void poll_cmd(uint8_t cmd, int nbytes, int spike_ok)
{
    drain_stale();
    if(!wait_cmd_clear("опрос")) return;
    gs_zx_write_cmd(cmd);
    for(int i = 0; i < nbytes; i++){
        if(g_qmode){
            uint8_t b;
            run_cyc(exchange_cost(spike_ok));              /* «Спектрум» платит свою цену */
            if(!qpop(&b)){                                 /* байта ещё нет — ждём, карта не висит */
                long long lim = g_cyc + CARD_HZ / 4;
                for(;;){
                    if(qpop(&b)) break;
                    if(g_cyc > lim){ g_to++; return; }
                    tick();
                }
            }
            (void)b;
        } else {
            if(!wait_out_byte(0, CARD_HZ)){ g_to++; return; }
            run_cyc(exchange_cost(spike_ok));              /* карта ВИСИТ в HSEND всё это время */
            (void)gs_zx_read_data();
        }
    }
}

/* ---------------- сэмпл эффекта ---------------- */
static uint8_t* make_sample(unsigned len)
{
    uint8_t* s = (uint8_t*)malloc(len);
    if(!s){ printf("нет памяти под сэмпл\n"); exit(2); }
    /* Беззнаковая пила (PC type) периодом 64 байта: слышимый тон, ненулевой пик микшера. */
    for(unsigned i = 0; i < len; i++) s[i] = (uint8_t)(0x20u + ((i & 63u) << 2));
    return s;
}

/* Дождаться КОНЦА эффекта: защёлки перестали расти на 20 мс подряд. Нужно затем, чтобы на каждой
   точке свипа играл РОВНО ОДИН экземпляр эффекта — иначе строки несопоставимы между собой.
   Замер: сэмпл 16.4 КБ на виртуальную секунду (проба `-p`), то есть 256 КБ = 16 с звука. */
static void wait_fx_end(void)
{
    long long cap = g_cyc + 25LL * CARD_HZ;
    unsigned prev = gs_latch_get();
    long long quiet = g_cyc;
    while(g_cyc < cap){
        tick();
        unsigned l = gs_latch_get();
        if(l != prev){ prev = l; quiet = g_cyc; }
        else if(g_cyc - quiet > FRAME_CYC) return;         /* 20 мс без единой защёлки = тишина */
    }
    printf("  !! эффект не кончился за 25 с — точки свипа могут накладываться\n");
}

static void reset_point(void)
{
    gs_diag2_reset();
    g_gap_max = g_gap_sum = 0; g_gap_n = 0;
    g_hole_ticks = g_hole_hsend = 0;
    g_peak = 0; g_to = 0; g_qmax = 0; g_stale = 0;
    g_lat_base = gs_latch_get();
    g_lat_prev = gs_latch_get();
    g_lat_cyc  = g_cyc;
}

int main(int argc, char** argv)
{
    const char* rompath = "gs105b.rom";
    unsigned secs = 10, slen = 262144u;    /* 16.4 КБ на секунду звука -> 256 КБ = 16 с, точке хватает */
    int probe = 0;

    static int lat_us[64] = { -1, 0, 25, 100, 250, 1000, 2000, 5000 };   /* -1 = контроль без опроса */
    int nlat = 8;

    for(int i = 1; i < argc; i++){
        if(!strcmp(argv[i], "-q")) g_qmode = 1;
        else if(!strcmp(argv[i], "-p")) probe = 1;
        else if(!strcmp(argv[i], "-r") && i + 1 < argc) rompath = argv[++i];
        else if(!strcmp(argv[i], "-s") && i + 1 < argc) secs = (unsigned)atoi(argv[++i]);
        else if(!strcmp(argv[i], "-l") && i + 1 < argc) slen = (unsigned)atoi(argv[++i]);
        else if(!strcmp(argv[i], "-x") && i + 1 < argc) g_spike_cyc = US(atoi(argv[++i]));
        else if(!strcmp(argv[i], "-X") && i + 1 < argc) g_spike_per = (unsigned)atoi(argv[++i]);
        else if(!strcmp(argv[i], "-d") && i + 1 < argc){       /* свой список цен обмена, через запятую */
            char* s = argv[++i]; nlat = 0;
            for(char* t = strtok(s, ","); t && nlat < 64; t = strtok(0, ",")) lat_us[nlat++] = atoi(t);
        }
        else { printf("ключи: -r ПЗУ -s секунд -l байт_сэмпла -d список_D_мкс -x всплеск_мкс "
                      "-X период_всплеска_кадров -q (очередь ответов) -p (проба)\n"); return 2; }
    }

    static uint8_t rom[0x10000];
    FILE* f = fopen(rompath, "rb");
    if(!f){ printf("нет файла ПЗУ %s\n", rompath); return 2; }
    unsigned n = (unsigned)fread(rom, 1, sizeof rom, f);
    fclose(f);
    if(!gs_dbg_load_rom(rom, n)){ printf("ПЗУ не принято (%u байт)\n", n); return 2; }
    gs_reset();

    printf("=== СТЕНД ДЫР GENERAL SOUND ===  ПЗУ %u байт, режим: %s\n",
           n, g_qmode ? "ОЧЕРЕДЬ ОТВЕТОВ (модель починки)" : "обычный (карта висит в HSEND)");

    /* 1. Инициализация карты: 6 виртуальных секунд, как в проверенных стендах. */
    run_cyc(6LL * CARD_HZ);
    printf("после инициализации: PC=0x%04X NUMPG=%u защёлок=%u\n",
           gs_pc_get(), gs_ram4(0x4080u) & 0xFFu, gs_latch_get());

    /* 2. Эффект: самая короткая дорога к звуку (FULGSCOM.TXT). */
    int qsave = g_qmode; g_qmode = 0;             /* в настройке байты читаем сами, очередь не трогаем */
    if(!sc(0x38, "#38 Load FX")) return 1;
    uint8_t handle = gs_zx_read_data();           /* ответ читается СРАЗУ после WC, без WN */
    printf("#38 Load FX -> номер сэмпла %u\n", handle);
    if(!sc(0xD1, "#D1 Open Stream")) return 1;
    uint8_t* smp = make_sample(slen);
    for(unsigned i = 0; i < slen; i++){
        if(!sd(smp[i], "байт сэмпла")) return 1;
        if((i & 255u) == 255u) run_cyc(2000);     /* дать карте вычерпать очередь */
    }
    while(gs_inq_used()) tick();
    if(!sc(0xD2, "#D2 Close Stream")) return 1;
    run_cyc(CARD_HZ / 2);
    printf("сэмпл %u байт залит, очередь пуста, PC=0x%04X\n", slen, gs_pc_get());

    /* 3. Проба: сколько длится эффект и растут ли защёлки без всякого опроса. */
    if(probe){
        if(!sd(handle, "номер для #39")) return 1;
        if(!sc(0x39, "#39 Play FX")) return 1;
        printf("\nПРОБА: по секунде виртуального времени, опроса НЕТ\n");
        printf("%4s %10s %8s %8s %9s %9s %7s\n", "с", "защёлок/с", "пик", "QTFAULT", "прерыв.", "удержано", "PC");
        for(unsigned s = 0; s < 30u; s++){
            unsigned l0 = gs_latch_get(), i0 = gs_int_get(), h0 = gs_intheld_get(), q0 = gs_hits_get(3);
            g_peak = 0;
            run_cyc(CARD_HZ);
            printf("%4u %10u %8d %8u %9u %9u  0x%04X\n", s + 1, gs_latch_get() - l0, g_peak,
                   gs_hits_get(3) - q0, gs_int_get() - i0, gs_intheld_get() - h0, gs_pc_get());
            fflush(stdout);
        }
        return 0;
    }

    /* 4. Сколько байт РЕАЛЬНО отдают #63 и #64 в этой прошивке — меряем, а не предполагаем. */
    if(!sd(handle, "номер для #39")) return 1;
    if(!sc(0x39, "#39 Play FX")) return 1;
    run_cyc(CARD_HZ / 2);
    int nb62 = 0, nb63 = 0, nb64 = 0;
    { int qs = g_qmode; g_qmode = 0;
      drain_stale();
      if(wait_cmd_clear("проба #62")){
          gs_zx_write_cmd(0x62);
          for(int i = 0; i < 12; i++){ if(!wait_out_byte(0, CARD_HZ / 100)) break; (void)gs_zx_read_data(); nb62++; }
      }
      drain_stale();
      if(wait_cmd_clear("проба #63")){
          gs_zx_write_cmd(0x63);
          for(int i = 0; i < 12; i++){ if(!wait_out_byte(0, CARD_HZ / 100)) break; (void)gs_zx_read_data(); nb63++; }
      }
      drain_stale();
      if(wait_cmd_clear("проба #64")){
          gs_zx_write_cmd(0x64);
          for(int i = 0; i < 12; i++){ if(!wait_out_byte(0, CARD_HZ / 100)) break; (void)gs_zx_read_data(); nb64++; }
      }
      g_qmode = qs; }
    g_to = 0;
    printf("ЗАМЕР ЧИСЛА БАЙТ ОТВЕТА: #62 -> %d, #63 -> %d, #64 -> %d (ожидалось 1/4/4), слито залежавшихся %u\n",
           nb62, nb63, nb64, g_stale);
    if(nb62 == 0) nb62 = 1;
    if(nb63 == 0) nb63 = 4;
    if(nb64 == 0) nb64 = 4;
    g_qmode = qsave;

    /* 5. Свип по цене обмена. -1 = контроль: опроса нет вовсе (случай игры и TR-DOS). */
    if(g_spike_cyc)
        printf("ВСПЛЕСК: раз в %u кадров один обмен стоит %.1f мс (модель тяжёлого прохода оболочки)\n",
               g_spike_per, g_spike_cyc / 12000.0);
    printf("\nОпрос = окно трекера: #62 (%d) + #63 (%d) + #64 (%d) байт — 50 раз в секунду.\n", nb62, nb63, nb64);
    printf("Каждая строка — %u виртуальных секунд игры; первые 2 с после запуска эффекта отсечены\n", secs);
    printf("(там разбор сэмпла картой и стартовый всплеск, к делу не относится).\n\n");
    printf("%11s %8s %7s %8s %9s %10s %7s %9s %8s %10s %8s %6s %6s\n",
           "D,мкс", "прошло,с", "опросов", "дыр>1мс", "макс,мс", "сумма,мс", "%дыр",
           "защёлок", "QTFAULT", "удержано", "в HSEND", "переб.", "залеж.");

    for(int li = 0; li < nlat; li++){
        int lat = lat_us[li];
        g_lat_cyc_cost = (lat > 0) ? US(lat) : 0;

        /* Перезапуск эффекта на каждую точку: сэмпл конечен, а мерить надо ЗВУЧАЩУЮ карту. */
        g_meas = 0;
        wait_fx_end();
        { int sv = g_qmode; g_qmode = 0;
          if(!sd(handle, "номер для #39")) return 1;
          if(!sc(0x39, "#39 Play FX")) return 1;
          g_qmode = sv; }
        qflush();
        run_cyc(2LL * CARD_HZ);                    /* отсечка стартового всплеска */
        qflush();
        reset_point();
        unsigned i0 = gs_int_get(), h0 = gs_intheld_get();
        g_meas = 1;

        /* Длительность точки задана ВИРТУАЛЬНЫМ ВРЕМЕНЕМ, а не числом кадров: при дорогом обмене
           опрос сам по себе длиннее кадра, и «500 кадров» растянулись бы на разное время — строки
           стали бы несопоставимы. Опрос идёт по границам кадров, но не быстрее, чем успевает. */
        long long t0 = g_cyc, tend = g_cyc + (long long)secs * CARD_HZ;
        unsigned over = 0, polls = 0;
        g_spike_n = 0; g_spike_arm = 0;
        while(g_cyc < tend){
            long long fend = g_cyc + FRAME_CYC;
            if(g_spike_cyc && g_spike_per && (polls % g_spike_per) == 0u) g_spike_arm = 1;
            if(lat >= 0){
                poll_cmd(0x62, nb62, 0);
                poll_cmd(0x63, nb63, 1);
                poll_cmd(0x64, nb64, 1);
                polls++;
            }
            if(g_cyc < fend) run_cyc(fend - g_cyc); else over++;
        }
        double elapsed = (double)(g_cyc - t0) / (double)CARD_HZ;
        g_meas = 0;
        unsigned lat_tot = gs_latch_get() - g_lat_base;
        char lab[32];
        if(lat < 0) snprintf(lab, sizeof lab, "БЕЗ ОПРОСА"); else snprintf(lab, sizeof lab, "%d", lat);
        (void)i0;
        printf("%11s %8.1f %7u %8u %9.1f %10.1f %6.1f%% %9u %8u %10u %7.0f%% %6u %6u%s\n",
               lab, elapsed, polls, g_gap_n, g_gap_max / 12000.0, g_gap_sum / 12000.0,
               100.0 * (g_gap_sum / 12000.0) / (elapsed * 1000.0),
               lat_tot, gs_hits_get(3), gs_intheld_get() - h0,
               g_hole_ticks ? 100.0 * g_hole_hsend / g_hole_ticks : 0.0, over, g_stale,
               g_to ? "  !! тайм-ауты" : (g_spike_n ? "" : ""));
        if(g_spike_cyc) printf("%11s всплесков выдано: %u\n", "", g_spike_n);
        fflush(stdout);
    }
    printf("\n«залеж.» — сколько байт пришлось слить перед опросом. Ровно 1 на строку (и НЕ зависит от\n");
    printf("числа опросов) — это байт, который карта оставляет после `#39 Play FX` при перезапуске\n");
    printf("эффекта; будь он от #63/#64, число росло бы вместе с числом опросов.\n");
    printf("\nКАК ЧИТАТЬ. «Дыра» — разрыв между защёлкиваниями сэмплов длиннее 1 мс: сэмплы не\n");
    printf("защёлкиваются, ЦАП держит уровень, это слышно. QTFAULT — сколько раз у карты кончились\n");
    printf("кванты и прерывание вернулось БЕЗ EI. «в HSEND» — доля времени дыры, когда карта висела\n");
    printf("в ожидании, пока Спектрум заберёт байт. Строка БЕЗ ОПРОСА — контроль (игра, TR-DOS).\n");
    free(smp);
    return 0;
}
