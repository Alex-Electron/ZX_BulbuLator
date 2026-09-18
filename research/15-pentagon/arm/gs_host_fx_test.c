/* gs_host_fx_test.c - ХОСТОВОЙ СТЕНД: заставить эмулируемый General Sound ЗВУЧАТЬ без плеера.
 *
 * Зачем. На плате один прогон «включить карту - смонтировать образ - войти в TR-DOS - запустить
 * плеер - выбрать модуль» стоит около пяти минут, а плеер при этом делает десятки шагов, каждый из
 * которых может быть виноват. Здесь роль Спектрума играю я сам, и цикл занимает секунды.
 *
 * Что проверяется: САМАЯ КОРОТКАЯ дорога к звуку по руководству (FULGSCOM.TXT) - эффект, а не
 * модуль, потому что у эффекта нет ни паттернов, ни инструментов, ни пересчёта сэмплов:
 *     SC #38 / WC / GD -> номер сэмпла
 *     SC #D1 (Open Stream) / WC
 *     SD байты / WD ...
 *     SC #D2 (Close Stream) / WC
 *     SD номер / SC #39 (Play FX) / WC
 * После загрузки у сэмпла по умолчанию Note=60, Volume=#40, SeekFirst=SeekLast=#0F, Priority=#80.
 *
 * 🥇 Прибор здесь тот же, что доказал ошибку на плате: ЧИСЛО ЗАЩЁЛКИВАНИЙ сэмплов. У GS сэмпл
 * защёлкивается ЧТЕНИЕМ окна 0x6000..0x7FFF, поэтому «карта играет» = счётчик растёт (~150 тыс/с
 * при четырёх каналах на 37480 Гц). Пик микшера сам по себе не доказывает НИЧЕГО: залипший
 * постоянный уровень даёт такой же положительный отсчёт, и я уже принял его за музыку.
 *
 * Сборка (на ThinkPad, обычным gcc - плата не нужна):
 *   mkdir -p /tmp/gsbuild && cd /tmp/gsbuild
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_arm.c .
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_host_fx_test.c .
 *   cp -r ~/bulb-v13/research/15-pentagon/arm/z80emu .
 *   cp ~/bulb-v13/research/15-pentagon/arm/gs_z80user.h z80emu/z80user.h
 *   cp ~/bulb-v13/research/15-pentagon/assets_gs105b.rom gs105b.rom
 *   gcc -O2 -DGS_HOST_TEST -o gsfx gs_host_fx_test.c gs_arm.c z80emu/z80emu.c -I. && ./gsfx
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* --- сторона Спектрума у модели карты (gs_arm.c) --- */
extern void     gs_reset(void);
extern uint32_t gs_run(uint32_t cycles);
extern int      gs_dbg_load_rom(const void* p, unsigned n);
extern int      gs_dbg_seed_stale_query(uint8_t data, uint8_t cmd);
extern unsigned gs_dbg_b0(void);
extern void     gs_zx_write_cmd (uint8_t v);
extern void     gs_zx_write_data(uint8_t v);
extern uint8_t  gs_zx_read_data (void);
extern uint8_t  gs_zx_read_stat (void);
extern uint8_t  gs_dout_get(void);
extern void     gs_mix(int16_t* l, int16_t* r);
extern unsigned gs_inq_room(void);
extern unsigned gs_inq_used(void);
extern unsigned gs_latch_get(void);
extern unsigned gs_vols_get(void);
extern unsigned gs_chans_get(void);
extern unsigned gs_pgsel_get(void);
extern unsigned gs_ram4(unsigned addr);
extern unsigned gs_pc_get(void);
extern unsigned gs_int_get(void);
extern unsigned gs_intheld_get(void);
extern void     gs_render(int16_t* l, int16_t* r);
extern void     gs_latch_diag_take(uint32_t out[5]);

/* Один «квант» жизни карты. На плате темп задаёт ЦАП: сэмпл на каждые 250 тактов. Здесь так же,
   иначе легко обмануть себя прогоном в миллион тактов, которого на плате не бывает. */
static long long g_cyc;
static int  g_peak;                       /* пик микшера за прогон, 0..32767 */
static void step(unsigned samples)
{
    for (unsigned i = 0; i < samples; i++) {
        g_cyc += gs_run(250);
        int16_t l, r;
        gs_mix(&l, &r);
        int a = l < 0 ? -l : l;
        int b = r < 0 ? -r : r;
        if (a > g_peak) g_peak = a;
        if (b > g_peak) g_peak = b;
    }
}

static void report(const char* tag)
{
    unsigned v = gs_vols_get(), c = gs_chans_get();
    printf("  %-26s PC=0x%04X защёлок=%-9u прерываний=%-8u громкости=%02X/%02X/%02X/%02X "
           "каналы=%08X пик=%d страниц=%u\n",
           tag, gs_pc_get(), gs_latch_get(), gs_int_get(),
           v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF,
           c, g_peak, gs_pgsel_get());
}

/* --- канонические ожидания из руководства, но с ТАЙМ-АУТОМ: у настоящего софта его нет, а стенд
       обязан не висеть, а СКАЗАТЬ, где именно не дождался --- */
#define WAIT_SAMPLES 48000u               /* одна виртуальная секунда */

static int wait_cmd_clear(const char* who)     /* WC: карта сняла флаг команд */
{
    for (unsigned i = 0; i < WAIT_SAMPLES; i++) {
        if (!(gs_zx_read_stat() & 0x01u)) return 1;
        step(1);
    }
    printf("  !! ТАЙМ-АУТ WC (%s): карта не сняла флаг команд за 1 с\n", who);
    return 0;
}
static int wait_data_room(const char* who)     /* WD: в очереди есть место (у нас это и есть флаг данных) */
{
    for (unsigned i = 0; i < WAIT_SAMPLES; i++) {
        if (gs_inq_room() > 0u) return 1;
        step(1);
    }
    printf("  !! ТАЙМ-АУТ WD (%s): очередь данных не освободилась за 1 с\n", who);
    return 0;
}
static int wait_out_byte(const char* who)      /* WN: карта положила байт для Спектрума */
{
    for (unsigned i = 0; i < WAIT_SAMPLES; i++) {
        if (gs_zx_read_stat() & 0x80u) return 1;
        step(1);
    }
    printf("  !! ТАЙМ-АУТ WN (%s): карта не отдала байт за 1 с\n", who);
    return 0;
}

static int sc(uint8_t cmd, const char* who)    /* послать команду и дождаться подтверждения */
{
    if (!wait_cmd_clear(who)) return 0;
    gs_zx_write_cmd(cmd);
    return wait_cmd_clear(who);
}
static int sd(uint8_t d, const char* who)      /* послать байт данных */
{
    if (!wait_data_room(who)) return 0;
    gs_zx_write_data(d);
    return 1;
}


/* ================= v0.15.332 ИМИТАЦИЯ ОКНА ТРЕКЕРА Z-PLAYER =================
   Зачем. На плате доказано (A/B владельца 11.08): тот же модуль в игре ZYNAP и в TR-DOS играет
   ровно, а стоит загрузить Z-Player — на стыке паттернов появляются провалы. Здесь проверяется
   ПРИЧИНА этого, и проверяется без платы.

   Что делает окно трекера, по исходникам прошивки карты (COM_H.a80):
     #62 — одна команда, один байт ответа, `OUT (OUTRG),A : OUT (RSCOM),A : RET` — карта НЕ ждёт;
     #63 Get Channel Notes и #64 Get Channel Volumes — по ЧЕТЫРЕ байта, и после каждого стоит
         `CALL HSEND` (COM_H.a80:873-878), а HSEND крутится, пока Спектрум байт не заберёт.
   Итого 8 блокирующих ожиданий на кадр. Пока карта в HSEND, её главный цикл не зовёт ENGINE,
   то есть кольцо квантов (54.6 мс) не пополняется.

   Чем мы отличаемся от настоящей карты. У настоящей GS круг «карта выставила байт -> Спектрум его
   забрал -> карта об этом узнала» занимает 2..10 мкс: Спектрум крутится в `WN: IN A,(#BB)`. У нас
   этот круг проходит через оболочку на ARM: байт становится виден машине только когда `gs_flags_pump`
   отзеркалит состояние в фабрику, а о том, что машина байт забрала, эмулятор узнаёт только на
   СЛЕДУЮЩЕМ вызове того же насоса. Насос вызывается раз за проход главного цикла, у которого
   замеренный хвост — 1077 проходов длиннее 1 мс и худший 134 мс.

   Поэтому здесь цена круга — ПАРАМЕТР. Свип по нему отвечает на вопрос «это вообще наша латентность
   или нет» цифрой, а не рассуждением. Часы — сэмплы ЦАП (47996/с), как на плате. */
extern unsigned gs_hits_get(unsigned i);
extern unsigned gs_holes_get(void);
extern unsigned gs_holemax_get(void);
extern unsigned gs_holesum_get(void);
extern unsigned gs_smpout_get(void);
extern void     gs_diag2_reset(void);

static unsigned g_lat2 = 0;        /* ПОЛНЫЙ круг зеркала, в сэмплах ЦАП (20.8 мкс на сэмпл) */
static unsigned g_zp_to = 0;       /* сколько раз стенд не дождался — признак, что модель врёт */

static void rstep(unsigned n)      /* прогон карты через тот же gs_render, что и на плате */
{
    for (unsigned i = 0; i < n; i++) { int16_t L, R; gs_render(&L, &R); }
}
static void zp_cmd(uint8_t c)      /* послать команду, как это делает машина: дождаться WC */
{
    unsigned g = 0;
    while (gs_zx_read_stat() & 0x01u) { if (++g > 96000u) { g_zp_to++; return; } rstep(1); }
    if (g_lat2) rstep(g_lat2);     /* карта сняла флаг -> зеркало -> машина увидела */
    gs_zx_write_cmd(c);
}
static uint8_t zp_take(void)       /* забрать байт ответа: WN, потом IN A,(#B3) */
{
    unsigned g = 0;
    while (!(gs_zx_read_stat() & 0x80u)) { if (++g > 96000u) { g_zp_to++; return 0xFFu; } rstep(1); }
    /* Полный круг: флаг карты уходит наружу зеркалом, и только следующий проход насоса приносит
       эмулятору событие «машина забрала». В модели байт снимается мгновенно, поэтому вся цена
       круга оплачивается ДО чтения — так же, как её оплачивает карта, вися в HSEND. */
    if (g_lat2) rstep(g_lat2);
    return gs_zx_read_data();
}
static void zp_frame(void)         /* один кадр окна трекера: позиция + ноты + громкости */
{
    zp_cmd(0x62); (void)zp_take();
    zp_cmd(0x63); for (int i = 0; i < 4; i++) (void)zp_take();
    zp_cmd(0x64); for (int i = 0; i < 4; i++) (void)zp_take();
}

int main(int argc, char** argv)
{
    static uint8_t rom[0x10000];
    const char* rompath = (argc > 1) ? argv[1] : "gs105b.rom";
    FILE* f = fopen(rompath, "rb");
    if (!f) { printf("нет файла ПЗУ %s\n", rompath); return 2; }
    unsigned n = (unsigned)fread(rom, 1, sizeof rom, f);
    fclose(f);
    if (!gs_dbg_load_rom(rom, n)) { printf("ПЗУ не принято (%u байт)\n", n); return 2; }
    gs_reset();

    /* Exact live-board queue regression. Do not run the firmware here: the
       assertion isolates ARM queue arbitration from all Z80 timing. */
    if (!gs_dbg_seed_stale_query(0xBFu, 0x20u)) {
        printf("  !! не удалось задать очередь регрессии\n");
        return 1;
    }
    (void)gs_run(0);
    if (gs_inq_used() != 0u || !gs_dbg_b0()) {
        printf("  !! REGRESSION stale-query: used=%u b0=%u (ожидалось 0/1)\n",
               gs_inq_used(), gs_dbg_b0());
        return 1;
    }
    printf("  PASS stale-query: [BF, marker, #20] -> [#20], очередь пуста\n");
    gs_reset();

    printf("ПЗУ %u байт. Даю карте 6 виртуальных секунд на инициализацию и замер памяти:\n", n);
    for (int s = 0; s < 6; s++) { step(48000); }
    unsigned numpg = gs_ram4(0x4080u) & 0xFFu;
    printf("  NUMPG (страниц ОЗУ, замер САМОЙ карты) = %u\n", numpg);
    report("после инициализации");

    /* #20 is the command on which Z-Player hung after the first byte. Verify
       all three HSEND handshakes, not merely command acknowledgement. */
    if (!sc(0x20, "#20 объём памяти")) return 1;
    {
        unsigned mem = 0;
        for (unsigned i = 0; i < 3; i++) {
            if (!wait_out_byte("#20 следующий байт")) return 1;
            mem |= (unsigned)gs_zx_read_data() << (8u * i);
            step(1);
        }
        printf("  PASS #20: получены все три байта, объём=0x%06X\n", mem);
    }

    /* ================= РЕЖИМ «МОДУЛЬ»: повтор ТРАССЫ, снятой с X-Player на плате =================
       Последовательность (трасса протокола, прошивка v0.15.277, фильтр опроса):
         #F4 холодный сброс -> #23 (ответ 15 страниц) -> #21 (свободно 0x07C000)
         -> #F3 тёплый сброс -> #30 Load Module -> #D1 поток -> байты модуля -> #D2 -> #31 + байт 00
       Запуск: ./gsfx gs105b.rom wizardry.mod */
    if (argc > 2) {
        FILE* mf = fopen(argv[2], "rb");
        if (!mf) { printf("нет файла модуля %s\n", argv[2]); return 2; }
        static uint8_t mod[1u<<20]; unsigned mlen = (unsigned)fread(mod, 1, sizeof mod, mf); fclose(mf);
        printf("модуль %s: %u байт\n", argv[2], mlen);
        if (!sc(0xF4, "#F4 холодный сброс")) return 1;
        /* 🥇 СКОЛЬКО ДЛИТСЯ ПЕРЕИНИЦИАЛИЗАЦИЯ И ОТВЕЧАЕТ ЛИ КАРТА, ПОКА МЕРИТ ПАМЯТЬ. Плеер на плате
           спрашивает #23 сразу после #F4; если карта отвечает недосчитанным NUMPG, весь дальнейший
           разбор модуля уезжает. Печатаем NUMPG каждые 100 мс. */
        for (int t = 0; t < 60; t++) {
            step(4800);
            if (t < 10 || (t % 10) == 9)
                printf("  +%4d мс после #F4: NUMPG=%u PC=0x%04X\n",
                       (t + 1) * 100, gs_ram4(0x4080u) & 0xFFu, gs_pc_get());
        }
        if (!sc(0x23, "#23 число страниц")) return 1;
        printf("  #23 -> %u страниц\n", gs_zx_read_data());
        if (!sc(0x21, "#21 свободно")) return 1;
        { unsigned a = gs_zx_read_data(); step(4); unsigned b = gs_zx_read_data(); step(4);
          unsigned c = gs_zx_read_data();
          printf("  #21 -> свободно 0x%02X%02X%02X\n", c, b, a); }
        if (!sc(0xF3, "#F3 тёплый сброс")) return 1;
        for (int s = 0; s < 2; s++) step(48000);
        if (!sc(0x30, "#30 Load Module")) return 1;
        if (!sc(0xD1, "#D1 Open Stream")) return 1;
        for (unsigned i = 0; i < mlen; i++) {
            if (!sd(mod[i], "байт модуля")) return 1;
            if ((i & 255u) == 0u) step(64);
        }
        printf("  модуль отдан, в очереди осталось %u\n", gs_inq_used());
        if (!sc(0xD2, "#D2 Close Stream")) return 1;
        for (int s = 0; s < 2; s++) step(48000);
        report("после закрытия потока");
        printf("  SMPS = адрес 0x%04X, страница-индекс %u\n",
               gs_ram4(0x419Bu) & 0xFFFFu, (gs_ram4(0x419Bu) >> 16) & 0xFFu);
        if (!sd(0x00, "параметр #31")) return 1;
        if (!sc(0x31, "#31 Play module")) return 1;
        /* ---- ОПЫТ: что именно доводит карту до её собственного underrun (GS_ZP=1) ----
           Разводятся ДВА механизма, оба наши:
             (A) ЦЕНА КРУГА РУКОПОЖАТИЯ. У настоящей GS «байт ушёл — Спектрум забрал — карта узнала»
                 занимает 2..10 мкс. У нас круг идёт через оболочку: байт становится виден машине
                 только когда gs_flags_pump отзеркалит состояние, а о том, что машина его забрала,
                 эмулятор узнаёт только на СЛЕДУЮЩЕМ вызове того же насоса.
             (Б) ЗАЛИПШИЙ БИТ «РЕГИСТР ЗАНЯТ». У карты бит7 её порта #04 значит «регистр данных
                 занят», и HSEND ждёт его СНЯТИЯ. У нас он собран как `gs_inq_head_is_data() ||
                 gs_outp` (gs_arm.c), то есть ЛЮБОЙ невычерпанный байт во входной очереди держит
                 его поднятым. Тогда HSEND выходит не по «байт забрали», а по аварийному выходу
                 «пришла новая команда» — то есть карта стоит до следующего кадра плеера.
           Обе дороги ведут в одно место: главный цикл карты не зовёт ENGINE, кольцо квантов
           (54.6 мс) пустеет, прерывание уходит в QTFAULT и возвращается БЕЗ EI. */
        if (getenv("GS_ZP")) {
            /* -1 = КОНТРОЛЬ: опроса нет вовсе (так ведут себя игра ZYNAP и TR-DOS). */
            static const int LAT_US[] = { -1, 25, 50, 100, 250, 500, 1000, 2000, 5000 };
            const unsigned SECS = 10u;
            const unsigned stale = (unsigned)(getenv("GS_STALE") ? atoi(getenv("GS_STALE")) : 0);

            printf("\n  в очереди после заливки модуля: %u байт, даю карте вычерпать...\n", gs_inq_used());
            for (unsigned g = 0; g < 96000u && gs_inq_used(); g++) rstep(1);
            printf("  в очереди перед опытом: %u байт%s\n", gs_inq_used(),
                   gs_inq_used() ? "  !! НЕ ВЫЧЕРПАНА" : " (чисто)");
            if (stale) {
                for (unsigned i = 0; i < stale; i++) gs_zx_write_data(0xA5u);
                printf("  НАРОЧНО положено %u невзятых байт данных (проверка залипшего бита7)\n", stale);
            }
            printf("\n=== ЧТО ДОВОДИТ КАРТУ ДО СОБСТВЕННОГО UNDERRUN ===\n");
            printf("Опрос = окно трекера Z-Player 50 раз в секунду: #62 (1 байт) + #63 (4 байта через\n");
            printf("HSEND) + #64 (4 байта через HSEND). Каждая строка — %u виртуальных секунд игры.\n", SECS);
            printf("Круг 0 не берём: шаг стенда — один сэмпл ЦАП (20.8 мкс), а у настоящей GS круг\n");
            printf("стоит 2..10 мкс — ближайшая к живому железу строка здесь — 25 мкс.\n\n");
            printf("%10s %8s %7s %6s %10s %9s %9s %8s %8s %7s\n",
                   "круг,мкс", "прошло,с", "QTFAULT", "дыр", "дыра max,мс", "в дырах,%",
                   "HSEND", "HGET", "HTAIL2", "очередь");
            for (unsigned li = 0; li < sizeof LAT_US / sizeof LAT_US[0]; li++) {
                int lat = LAT_US[li];
                g_lat2 = (lat > 0) ? (unsigned)((double)lat * 2.0 * 47.996 / 1000.0 + 0.5) : 0u;
                gs_diag2_reset(); g_zp_to = 0;
                unsigned s0 = gs_smpout_get();
                for (unsigned fr = 0; fr < SECS * 50u; fr++) {
                    unsigned b = gs_smpout_get();
                    if (lat >= 0) zp_frame();
                    unsigned spent = gs_smpout_get() - b;
                    if (spent < 960u) rstep(960u - spent);   /* добить кадр до 20 мс */
                }
                unsigned total = gs_smpout_get() - s0;
                char lab[24];
                if (lat < 0) snprintf(lab, sizeof lab, "БЕЗ ОПРОСА"); else snprintf(lab, sizeof lab, "%d", lat);
                printf("%10s %8.1f %7u %6u %10.1f %8.1f%% %9u %8u %8u %7u%s\n",
                       lab, total / 47996.0, gs_hits_get(3), gs_holes_get(),
                       gs_holemax_get() / 47.996,
                       total ? 100.0 * gs_holesum_get() / total : 0.0,
                       gs_hits_get(0), gs_hits_get(1), gs_hits_get(2), gs_inq_used(),
                       g_zp_to ? "  !! тайм-ауты" : "");
                fflush(stdout);
            }
            printf("\nКАК ЧИТАТЬ. QTFAULT — сколько раз у карты кончились кванты и прерывание вернулось\n");
            printf("БЕЗ EI: сэмплы не защёлкиваются, ЦАП держит уровень, слышна ДЫРА. Строка БЕЗ ОПРОСА —\n");
            printf("контроль: это случай игры ZYNAP и TR-DOS, где владелец стыков НЕ слышит.\n");
            return 0;
        }

        unsigned l0 = gs_latch_get(); g_peak = 0;
        /* Offline: gs_render + lgap (same instruments as board). */
        uint32_t max_gap = 0, max_pc = 0, max_pos0 = 0, max_pos1 = 0, max_irq = 0;
        unsigned spikes = 0;
        for (int s = 0; s < 30; s++) {
            for (int k = 0; k < 10; k++) {
                for (int i = 0; i < 4800; i++) {
                    int16_t L, R;
                    gs_render(&L, &R);
                    int aa = L < 0 ? -L : L, bb = R < 0 ? -R : R;
                    if (aa > g_peak) g_peak = aa;
                    if (bb > g_peak) g_peak = bb;
                }
                uint32_t lg[5];
                gs_latch_diag_take(lg);
                if (lg[0] > max_gap && lg[0] < 12000000u) {
                    max_gap = lg[0]; max_pc = lg[1];
                    max_pos0 = lg[2]; max_pos1 = lg[3]; max_irq = lg[4];
                }
                if (lg[0] > 50000u) {
                    spikes++;
                    printf("  SPIKE +%d.%ds lgap=%u (~%.1fms) pc=%04X/%04X pos %08X->%08X held=%u ints=%u\n",
                           s, k, lg[0], lg[0]/12000.0,
                           (unsigned)((lg[1]>>16)&0xFFFF), (unsigned)(lg[1]&0xFFFF),
                           lg[2], lg[3],
                           (unsigned)((lg[4]>>16)&0xFFFF), (unsigned)(lg[4]&0xFFFF));
                }
            }
            if (s == 0 || s == 4 || s == 9 || s == 19 || s == 29) {
                char tag[40];
                snprintf(tag, sizeof tag, "play +%ds", s + 1);
                report(tag);
                printf("    pos=%08X int=%u held=%u max_gap=%u spikes=%u\n",
                       gs_ram4(0x415Au), gs_int_get(), gs_intheld_get(), max_gap, spikes);
            }
        }
        printf("\nMOD RESULT: latches=%u peak=%d\n", gs_latch_get() - l0, g_peak);
        printf("WORST lgap=%u (~%.1f ms) pc %04X->%04X pos %08X->%08X held=%u ints=%u spikes=%u\n",
               max_gap, max_gap/12000.0,
               (unsigned)((max_pc>>16)&0xFFFF), (unsigned)(max_pc&0xFFFF),
               max_pos0, max_pos1,
               (unsigned)((max_irq>>16)&0xFFFF), (unsigned)(max_irq&0xFFFF), spikes);
        printf("SMPS after: addr 0x%04X page %u\n",
               gs_ram4(0x419Bu) & 0xFFFFu, (gs_ram4(0x419Bu) >> 16) & 0xFFu);
        return 0;
    }

    /* --- 1. Load FX: карта возвращает номер сэмпла --- */
    if (!sc(0x38, "#38 Load FX")) return 1;
    /* 🥇 Ответный байт читается СРАЗУ после WC, БЕЗ ожидания флага данных: руководство помечает это
       место «(Command bit=0, Data bit=0)», и X-Player делает именно так (`IN A,(#B3)` без WN).
       Ожидание флага здесь висит вечно - карта его не поднимает. */
    uint8_t handle = gs_zx_read_data();
    printf("  #38 Load FX: карта выдала номер сэмпла %u\n", handle);

    /* --- 2. Open Stream и сам сэмпл. Беззнаковый (PC type), как требует руководство:
           меандр 100 Гц - его пик и период видно и в микшере, и на слух. --- */
    if (!sc(0xD1, "#D1 Open Stream")) return 1;
    const unsigned LEN = 4096;
    for (unsigned i = 0; i < LEN; i++) {
        uint8_t v = ((i / 64u) & 1u) ? 0xE0u : 0x20u;      /* беззнаковый меандр вокруг 0x80 */
        if (!sd(v, "байт сэмпла")) return 1;
        if ((i & 63u) == 0u) step(8);                      /* дать карте вычерпать очередь */
    }
    printf("  сэмпл отдан: %u байт, в очереди осталось %u\n", LEN, gs_inq_used());
    /* Трасса вокруг закрытия потока: карта уходила исполнять код по 0xC57D, то есть В ДАННЫЕ.
       Печатаем PC через каждые 10 мс виртуального времени, пока не станет видно, откуда прыжок. */
    printf("  трасса до #D2:  ");
    for (int i = 0; i < 8; i++) { printf("%04X ", gs_pc_get()); step(480); }
    printf("\n  очередь перед #D2: %u\n", gs_inq_used());
    if (!sc(0xD2, "#D2 Close Stream")) return 1;
    printf("  трасса после #D2: ");
    for (int i = 0; i < 16; i++) { printf("%04X ", gs_pc_get()); step(480); }
    printf("\n");
    report("после загрузки эффекта");

    /* --- 3. Play FX: сначала данные (номер), потом команда --- */
    if (!sd(handle, "номер для #39")) return 1;
    if (!sc(0x39, "#39 Play FX")) return 1;

    unsigned lat0 = gs_latch_get();
    g_peak = 0;
    for (int s = 0; s < 3; s++) {
        step(48000);
        char t[40]; snprintf(t, sizeof t, "играет, +%d с", s + 1);
        report(t);
    }
    unsigned dlat = gs_latch_get() - lat0;

    printf("\nИТОГ: защёлкиваний за 3 с = %u (ожидание ~150 тыс/с при четырёх каналах), пик = %d\n",
           dlat, g_peak);
    if (dlat > 10000u && g_peak > 256)
        printf("ЗВУК ЕСТЬ: карта читает окно сэмплов и микшер даёт сигнал.\n");
    else if (dlat > 10000u)
        printf("КАРТА ЧИТАЕТ СЭМПЛЫ, НО МИКШЕР МОЛЧИТ: смотреть громкости и путь ch->микшер.\n");
    else
        printf("КАРТА НЕ ЧИТАЕТ ОКНО СЭМПЛОВ: эффект не запустился. Смотреть заголовок сэмпла и #39.\n");
    printf("исполнено тактов: %lld (%.2f виртуальных секунд)\n", g_cyc, g_cyc / 12000000.0);
    return 0;
}
