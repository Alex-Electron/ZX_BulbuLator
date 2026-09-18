/* divmmc_card_host_test.c - ХОСТОВОЙ СТЕНД для модели карты SD (divmmc_card.c).
 *
 * Зачем. Одна проверка на плате стоит сборку прошивки, синтез битстрима и холодный старт, а
 * ошибиться в протоколе SD можно двадцатью способами, и все они выглядят одинаково: «Disk error».
 * Поэтому роль Спектрума здесь играет ДРАЙВЕР-ДВОЙНИК: его байтовая последовательность списана
 * не с документации на SD, а с дизассемблера настоящей esxDOS 0.8.9
 * (refs/divmmc/disasm/esxdos.asm) - те же метки, тот же порядок, те же холостые чтения порта.
 * Если карта устроит двойника, она устроит и оригинал.
 *
 * Что проверяется:
 *   1. Полная последовательность инициализации esxDOS: CMD0 - CMD8 - CMD55/ACMD41 - CMD58 -
 *      CMD9 - CMD10 - CMD17, с побайтовой сверкой ответов.
 *   2. Ёмкость, посчитанная ИЗ НАШЕГО CSD ровно так, как её считает esxDOS (L1EA3), против
 *      divmmc_fs_sectors().
 *   3. Кадрирование: команда сразу за командой без снятия выбора, и запись, у которой в полезной
 *      нагрузке полно байтов со старшими битами 01 (то есть похожих на начало команды).
 *   4. Десять тысяч случайных секторов - байт в байт против бэкенда.
 *   5. Мелочи, которые всё равно всплывут на плате: неизвестная команда, мультиблочное чтение с
 *      остановкой посреди потока, отказ записи, цена округления ёмкости вниз.
 *   6. 🥇 ОСТАНОВКА МУЛЬТИБЛОКА ВО ВСЕХ ЧЕТЫРЁХ МЕСТАХ, где её может застать CMD12 (тело блока,
 *      пауза между блоками при медленной оболочке, ожидание первого блока, граница блока у
 *      канонического драйвера). Проверяется не «вернулись в IDLE», а то, ради чего команда
 *      посылается: пришёл ли R1, за сколько байт, отпустилась ли линия и слушает ли карта дальше.
 *      Сценарий вырос из виса Z-Player 4.1 (19.08) - см. блок 3г2 ниже.
 *
 * Задержка на байт. Сдвигатель cores/zx/src/spi.v отдаёт процессору байт ПРЕДЫДУЩЕГО обмена, и
 * стенд эту задержку моделирует (spi_io ниже). То есть проверяется не только автомат, но и вся
 * цепочка «порт - сдвигатель - карта» в том виде, в каком она встанет в ПЛИС.
 *
 * Сборка и запуск (плата не нужна):
 *   gcc -O2 -Wall -DDIVMMC_FS_HOST -o dmcard divmmc_card_host_test.c divmmc_fs.c -I. && ./dmcard
 *   ./dmcard /путь/к/папке               - построить том из своей папки
 *   ./dmcard /путь/к/папке card.img      - и выгрузить образ карты (через CMD17!) в файл
 *
 * ------------------------------------------------------------------------------------------
 * ПРОВЕРКА НАСТОЯЩЕЙ esxDOS 0.8.9 (13.08.2026, ThinkPad; всё вне репозитория, потому что
 * прошивку esxDOS класть в репозиторий нельзя по лицензии). Стенд проверяет НАШУ сторону
 * провода, а вторую половину - что настоящая esxDOS понимает наш ТОМ - закрыли отдельно:
 *   образ карты выгружен этим же стендом (третий аргумент, каждый сектор идёт через CMD17) и
 *   подсунут ZEsarUX 13.1 с настоящей ESXMMC.BIN (--enable-divmmc --divmmc-rom ... --enable-mmc
 *   --mmc-file ...), эмулятор без окна (--vo null), управление и снятие результатов по ZRCP.
 * Числа:
 *   - `.ls` по всем шести каталогам: 63 записи, ИМЕНА И РАЗМЕРЫ СОВПАЛИ ПОЛНОСТЬЮ с папкой
 *     (в /BIN 41 файл, в /SYS 12, в /SYS/CONFIG 2, в /GAMES 3, в корне 5, /TMP пуст);
 *   - NMI-браузер (он же грузится с нашего тома, /SYS/NMI.SYS) показал в корне «[1/5]» -
 *     ровно столько, сколько отдал divmmc_fs_build;
 *   - `.cp GAMES/ELITE.TAP TMP/E.TAP`: 43000 байт прочитаны с тома и записаны обратно; файл,
 *     вынутый из образа независимым разборщиком FAT16, совпал с оригиналом БАЙТ В БАЙТ;
 *   - клавиша S в NMI-браузере сохранила SNAP0000.SNA (49179 Б = 27 заголовка + 49152 ОЗУ) -
 *     то есть путь ЗАПИСИ у esxDOS с нашей разметкой работает;
 *   - обе операции тронули 165 секторов: 2 в таблице размещения (по одному в каждой копии),
 *     1 в корневом каталоге, 162 в области данных. Это и есть техзадание на запись для
 *     divmmc_fs.c, который сейчас (строки 799-825) отвергает ВСЕ записи.
 * Вторым заходом ЗАМКНУЛИ ВСЮ ЦЕПЬ: у ZEsarUX собственная модель карты выкинута, а его
 * mmc_read/mmc_write заведены НА ЭТОТ АВТОМАТ (divmmc_card.c) поверх divmmc_fs.c без всякого
 * файла-образа. Настоящая esxDOS с этой связкой поднимается так же: `.ls` печатает те же имена
 * и размеры, NMI-браузер показывает «[1/5]», трасса байтов совпадает с той, что гоняет стенд
 * ниже (CMD0 -> 0x01, CMD8 -> 0x01 + 00 00 01 AA, CMD55/ACMD41, CMD58, CMD9/CMD10, CMD17).
 * Отказ бэкенда в записи доезжает до неё как «ESXDOS error #06» - то есть наш ответ на блок
 * 0x0D она читает и понимает (L1DEA: `and $1f : cp 5` не сошлось -> ошибка 6), а не портит том.
 * ------------------------------------------------------------------------------------------
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "divmmc_fs.h"

/* Модуль включаем целиком: стенду нужны не только внешние вызовы, но и внутренности - CSD, CID,
   счётчики, имя состояния. В прошивке divmmc_card.c собирается обычным отдельным .c. */
#include "divmmc_card.c"

static int g_fail = 0;
static void fail(const char* fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    printf("  ОТКАЗ: "); vprintf(fmt, ap); printf("\n");
    va_end(ap); g_fail++;
}
static void okline(const char* fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    printf("  "); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}

/* ============================================================================================ */
/* Двойник драйвера esxDOS. Метки в скобках - из refs/divmmc/disasm/esxdos.asm                   */
/* ============================================================================================ */

static uint8_t g_lag = 0xFF;      /* тот самый байт задержки сдвигателя spi.v */
static uint32_t g_spi_bytes = 0;

/* Один обмен: порт отдаёт байт ПРЕДЫДУЩЕГО обмена и тут же запускает новый (spi.v: md <= sd). */
static uint8_t spi_io(uint8_t out)
{
    uint8_t prev = g_lag;
    g_lag = divmmc_card_xfer(out);
    g_spi_bytes++;
    return prev;
}
static void    spi_out(uint8_t b){ (void)spi_io(b); }      /* out (#EB),a */
static uint8_t spi_in(void){ return spi_io(0xFF); }        /* in  a,(#EB) */

/* L1D5E: «выбрать все карты» = 0xFF в порт #E7 = не выбрана ни одна. */
static void mmc_deselect(void){ divmmc_card_cs(0); }
/* L1DE0: холостое чтение порта данных, затем запись кода выбора в #E7 (0xF6 = карта 0). */
static void mmc_select(void){ (void)spi_in(); divmmc_card_cs(1); }

/* L1DD2: опрашивать порт, пока не придёт что-нибудь кроме 0xFF (до 50*256 раз). */
static uint32_t g_poll_bytes = 0;
static uint8_t poll_nonff(void)
{
    int i;
    for(i = 0; i < 50 * 256; i++){
        uint8_t a = spi_in();
        g_poll_bytes++;
        if(a != 0xFF) return a;
    }
    return 0xFF;
}

/* L1D9A: выбрать карту, выдать 6 байт кадра, вернуть первый не-0xFF ответ.
   CRC7 честный только у CMD0 и CMD8 - ровно так и написано в оригинале (cp '@' / cp 'H'). */
static uint8_t mmc_cmd(uint8_t cmd, uint32_t arg)
{
    mmc_select();
    spi_out(cmd);
    spi_out((uint8_t)(arg >> 24));
    spi_out((uint8_t)(arg >> 16));
    spi_out((uint8_t)(arg >> 8));
    spi_out((uint8_t)arg);
    spi_out(cmd == 0x40 ? 0x95 : (cmd == 0x48 ? 0x87 : 0xFF));
    return poll_nonff();
}

/* L1D81: команда + четыре ДОПОЛНИТЕЛЬНЫХ опроса (ответы R3 и R7). */
static uint8_t mmc_cmd_r37(uint8_t cmd, uint32_t arg, uint8_t tail[4])
{
    uint8_t r1 = mmc_cmd(cmd, arg);
    int i;
    for(i = 0; i < 4; i++) tail[i] = poll_nonff();
    return r1;
}

/* L1DC4: до десяти подходов ждать байт-токен 0xFE. */
static int mmc_wait_token(void)
{
    int b;
    for(b = 0; b < 10; b++){
        uint8_t a = poll_nonff();
        if(a == 0xFE) return 0;
    }
    return -1;
}

/* L1D2F: команда, требующая ответа РОВНО 0x00, затем токен и `ld b,$12 : inir` = 18 байт. */
static int mmc_read_reg16(uint8_t cmd, uint8_t out[18])
{
    int i;
    if(mmc_cmd(cmd, 0) != 0x00){ mmc_deselect(); return -1; }
    if(mmc_wait_token() != 0){ mmc_deselect(); return -2; }
    for(i = 0; i < 18; i++) out[i] = spi_in();
    mmc_deselect();
    return 0;
}

/* L1E51: чтение сектора. Аргумент - НОМЕР блока (CCS=1); при CCS=0 esxDOS умножила бы его на 512
   (L1E97), это проверено по коду - но мы объявляем себя картой большой ёмкости. */
static int mmc_read_block(uint32_t lba, uint8_t out[512])
{
    int i;
    if(mmc_cmd(0x51, lba) != 0x00){ mmc_deselect(); return -1; }
    if(mmc_wait_token() != 0){ mmc_deselect(); return -2; }
    for(i = 0; i < 512; i++) out[i] = spi_in();
    (void)spi_in(); (void)spi_in();          /* CRC16 читается и выбрасывается - см. L1E75 */
    mmc_deselect();
    return 0;
}

/* L1DEA: запись сектора. Возвращает младшие 5 бит ответа на блок (esxDOS сверяет их с 5). */
static int mmc_write_block(uint32_t lba, const uint8_t* data)
{
    int i; uint8_t r;
    if(mmc_cmd(0x58, lba) != 0x00){ mmc_deselect(); return -1; }
    spi_out(0xFE);
    for(i = 0; i < 512; i++) spi_out(data[i]);
    spi_out(0xFF); spi_out(0xFF);
    r = poll_nonff();
    /* Ожидание занятости: esxDOS крутит L1DD2, пока ответ равен нулю. */
    for(i = 0; i < 64; i++){ if(poll_nonff() != 0x00) break; }
    mmc_deselect();
    return r & 0x1F;
}

/* ============================================================================================ */
/* Двойник драйвера, КОТОРЫЙ ЖДЁТ ОТВЕТ НА CMD12                                                 */
/*                                                                                               */
/* esxDOS мультиблочного чтения не умеет вовсе, поэтому её двойник выше эту половину протокола не */
/* проверяет. А Z-Player 4.1, NedoOS и u-boot (drivers/mmc/mmc_spi.c: CMD12 = R1B) её используют:  */
/* шлют CMD12 и ждут байт с нулевым старшим битом. Ждут БЕЗ ТАЙМАУТА - у Z-Player это `in a,(#57)`*/
/* в цикле, - поэтому любое молчание карты у них не «ошибка», а вис. Вот этого двойника здесь и    */
/* не хватало.                                                                                   */
/* ============================================================================================ */

/* Только кадр команды, без ожидания ответа: нужно уметь послать CMD12 в точно выбранное место
   потока (в тело блока, в паузу между блоками, до первого блока). */
static void mmc_cmd_frame(uint8_t cmd, uint32_t arg)
{
    spi_out(cmd);
    spi_out((uint8_t)(arg >> 24));
    spi_out((uint8_t)(arg >> 16));
    spi_out((uint8_t)(arg >> 8));
    spi_out((uint8_t)arg);
    spi_out(0xFF);
}

/* Сколько байт от конца кадра до первого байта с НУЛЕВЫМ старшим битом (это и есть R1);
   -1 = ответа не было вовсе. Данные в этих проверках набиты так, что у каждого байта старший бит
   единица, поэтому спутать полезную нагрузку с ответом невозможно. */
static int scan_r1(int limit, uint8_t* r1)
{
    int n;
    *r1 = 0xFF;
    for(n = 0; n < limit; n++){
        uint8_t b = spi_in();
        if((b & 0x80u) == 0u){ *r1 = b; return n; }
    }
    return -1;
}

/* R1b - это ответ ПЛЮС занятость: карта держит 0x00, пока не отпустит линию. Драйвер обязан
   дождаться 0xFF, прежде чем послать следующую команду, - иначе кадр уедет в занятую карту.
   Возвращает число байтов занятости, -1 если линия так и не отпущена. */
static int wait_busy_release(int limit)
{
    int n;
    for(n = 0; n < limit; n++) if(spi_in() == 0xFFu) return n;
    return -1;
}

/* Есть ли в следующих limit байтах токен данных 0xFE. Нужно, чтобы доказать: после остановки
   карта НЕ досылает блок, который уже никому не нужен. */
static int scan_data_token(int limit)
{
    int n;
    for(n = 0; n < limit; n++) if(spi_in() == 0xFEu) return 1;
    return 0;
}

/* L1EA3/L1EBC: ёмкость ИЗ CSD глазами esxDOS. Считаем восьмибитными шагами, как Z80, чтобы не
   подменить арифметику своей. */
static uint32_t esx_capacity_from_csd(const uint8_t* csd, int ccs)
{
    if(ccs){
        uint8_t b = 0, c = (uint8_t)(csd[7] & 0x3F), d = csd[8], e = csd[9];
        int k;
        /* L081C: 32-битный инкремент BCDE */
        if(++e == 0){ if(++d == 0){ if(++c == 0){ ++b; } } }
        /* L1E97: b=c, c=d, d=e, e=0 - сдвиг на 8 бит */
        b = c; c = d; d = e; e = 0;
        /* L1E9C дважды: сдвиг ещё на два бита */
        for(k = 0; k < 2; k++){
            uint8_t cy = (uint8_t)(d >> 7); d = (uint8_t)(d << 1);
            { uint8_t n = (uint8_t)((c << 1) | cy); cy = (uint8_t)(c >> 7); c = n; }
            { uint8_t n = (uint8_t)((b << 1) | cy); b = n; }
        }
        /* Итог лежит в паре регистров BCDE как одно 32-битное число: младший байт E остаётся
           нулевым, и забыть его - значит недосчитаться ровно в 256 раз (проверено на себе). */
        return ((uint32_t)b << 24) | ((uint32_t)c << 16) | ((uint32_t)d << 8) | e;
    }
    return 0;   /* путь CSD 1.0 нам не нужен: мы объявляем карту большой ёмкости */
}

/* ============================================================================================ */
/* Бэкенды                                                                                      */
/* ============================================================================================ */

/* Настоящий: синтезатор тома из папки. */
static int be_fs_rd(uint32_t lba, uint8_t* buf){ return divmmc_fs_read(lba, buf); }
static int be_fs_wr(uint32_t lba, const uint8_t* buf){ return divmmc_fs_write(lba, buf); }

/* Оперативный: нужен там, где проверяется ЗАПИСЬ - синтезатор её пока не принимает. */
#define RAMDISK_SEC 2048u
static uint8_t* g_ram;
static int be_ram_rd(uint32_t lba, uint8_t* buf)
{
    if(lba >= RAMDISK_SEC) return -1;
    memcpy(buf, g_ram + (size_t)lba * 512u, 512);
    return 0;
}
static int be_ram_wr(uint32_t lba, const uint8_t* buf)
{
    if(lba >= RAMDISK_SEC) return -1;
    memcpy(g_ram + (size_t)lba * 512u, buf, 512);
    return 0;
}

/* ============================================================================================ */
/* Испытательная папка (если своей не дали)                                                     */
/* ============================================================================================ */

static uint32_t lcg = 2463534242u;
static uint32_t rnd32(void){ lcg ^= lcg << 13; lcg ^= lcg >> 17; lcg ^= lcg << 5; return lcg; }

static void mkfile(const char* dir, const char* name, uint32_t size, uint32_t seed)
{
    char p[1024]; FILE* f; uint32_t i;
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    f = fopen(p, "wb"); if(!f){ fail("не создать %s", p); return; }
    lcg = seed ? seed : 1;
    for(i = 0; i < size; i++) fputc((int)(rnd32() >> 16) & 0xFF, f);
    fclose(f);
}

static void make_tree(const char* root)
{
    char sub[1024], cmd[1200];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root); if(system(cmd)){}
    mkdir(root, 0755);
    snprintf(sub, sizeof(sub), "%s/BIN", root); mkdir(sub, 0755);
    mkfile(sub, "LS.COM", 1234, 1);
    mkfile(sub, "CD.COM",  777, 2);
    snprintf(sub, sizeof(sub), "%s/SYS", root); mkdir(sub, 0755);
    mkfile(sub, "CONFIG.SYS", 100, 3);
    snprintf(sub, sizeof(sub), "%s/GAMES", root); mkdir(sub, 0755);
    mkfile(sub, "ELITE.TAP", 49152, 5);
    mkfile(sub, "Manic Miner (1983)(Bug-Byte Software).tap", 33000, 6);
    mkfile(root, "ONE.BIN", 1, 11);
    mkfile(root, "CLUP1.BIN", 32769, 15);
    mkfile(root, "BIG.TAP", 700000, 16);
}

/* ============================================================================================ */

static uint8_t sec_card[512], sec_be[512];

int main(int argc, char** argv)
{
    const char* folder = "/tmp/dmcard_tree";
    const char* image  = 0;
    const dmfs_info_t* inf;
    uint8_t csd[18], cid[18], tail[4];
    uint8_t r1;
    int ccs = 0, i;
    uint32_t cap_esx = 0;

    if(argc > 1) folder = argv[1]; else make_tree("/tmp/dmcard_tree");
    if(argc > 2) image = argv[2];

    printf("=== 0. Том из папки %s ===\n", folder);
    if(divmmc_fs_build(folder) != DMFS_OK && !divmmc_fs_ready()){
        printf("СТЕНД ОСТАНОВЛЕН: том не построен (%s)\n", divmmc_fs_msg());
        return 2;
    }
    inf = divmmc_fs_info();
    okline("файлов=%u папок=%u байт=%u; том %u секторов (%u МБ)",
           inf->files, inf->dirs, inf->bytes, inf->vol_sectors, inf->vol_sectors / 2048);

    divmmc_card_attach(divmmc_fs_sectors(), be_fs_rd, be_fs_wr);
    okline("карта: %u секторов (%u МБ), C_SIZE=%u, добавлено хвоста %u секторов",
           divmmc_card_sectors(), divmmc_card_sectors() / 2048,
           ((uint32_t)(divmmc_card_csd()[7] & 0x3F) << 16) |
           ((uint32_t)divmmc_card_csd()[8] << 8) | divmmc_card_csd()[9],
           divmmc_card_sectors() - divmmc_fs_sectors());

    /* -------------------------------------------------------------------------------------- */
    printf("=== 1. Инициализация: байт в байт по esxDOS 0.8.9 ===\n");

    /* L1D40: снять выбор, дать десять байт 0xFF (те самые «74 такта»), выбрать карту, CMD0 */
    mmc_deselect();
    for(i = 0; i < 10; i++) spi_out(0xFF);
    {
        const divmmc_card_stat_t* st = divmmc_card_stat();
        okline("байтов при снятом выборе до первой CMD0: %u (карта требует >= 10)", st->pre_cmd0_clocks);
        if(st->pre_cmd0_clocks < 10) fail("esxDOS дала меньше десяти холостых байтов");
    }
    r1 = 0xFF;
    for(i = 0; i < 8; i++){                    /* L1D50: до восьми попыток */
        r1 = mmc_cmd(0x40, 0);
        if((r1 & 0xFE) == 0) break;
    }
    okline("CMD0  -> R1=0x%02X (ждали 0x01), попыток %d", r1, i + 1);
    if(r1 != 0x01) fail("CMD0 обязан вернуть ровно 0x01 (idle)");

    /* L1D00: CMD8 с аргументом 0x000001AA - ответ R7 */
    r1 = mmc_cmd_r37(0x48, 0x000001AA, tail);
    okline("CMD8  -> R1=0x%02X, эхо %02X %02X %02X %02X (ждали 00 00 01 AA)",
           r1, tail[0], tail[1], tail[2], tail[3]);
    if((r1 & 0xFE) != 0) fail("CMD8 отвергнута - esxDOS ушла бы на путь карт версии 1 (CMD1)");
    if(tail[2] != 0x01 || tail[3] != 0xAA) fail("эхо CMD8 не совпало: карта не подтвердила напряжение");

    /* L1D20: CMD55 + ACMD41 в цикле (до 30720 подходов). */
    {
        int tries = 0;
        for(;;){
            uint8_t r55 = mmc_cmd(0x77, 0);          /* CMD55: 0x01 - НОРМА, esxDOS его игнорирует */
            uint8_t r41;
            if(tries == 0) okline("CMD55 -> R1=0x%02X (ждали 0x01; esxDOS ответ не проверяет)", r55);
            r41 = mmc_cmd(0x69, 0x40000000);
            tries++;
            if(r41 == 0x00){ okline("ACMD41-> R1=0x00 на %d-й попытке (до этого 0x01)", tries); break; }
            if(r41 != 0x01) { fail("ACMD41 ответила 0x%02X - ни готовность, ни ожидание", r41); break; }
            if(tries > 100){ fail("ACMD41 так и не вернула 0x00"); break; }
        }
    }

    /* CMD58: OCR. Бит 30 = CCS. */
    r1 = mmc_cmd_r37(0x7A, 0, tail);
    ccs = (tail[0] & 0x40) ? 1 : 0;
    okline("CMD58 -> R1=0x%02X, первый байт OCR=0x%02X, CCS=%d", r1, tail[0], ccs);
    if(r1 != 0x00) fail("CMD58 после готовности обязана вернуть 0x00");
    if(!ccs) fail("CCS=0: esxDOS перешла бы на байтовую адресацию и CMD16");
    okline("(побочно: esxDOS читает байты OCR той же 'ждать не-0xFF' подпрограммой, поэтому байт "
           "0xFF ВНУТРИ OCR она пропускает - на нашем 0xC0FF8000 значащий первый байт она "
           "получает верно, а лишний опрос стоит ей около 0.1 с; это её свойство, не наше)");

    /* CMD9/CMD10 - блоки с токеном. */
    if(mmc_read_reg16(0x49, csd) != 0) fail("CMD9 не отдала блок (нет 0x00 или нет токена 0xFE)");
    else {
        okline("CMD9  -> токен 0xFE + 18 байт; CSD %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X ...",
               csd[0], csd[1], csd[2], csd[3], csd[4], csd[5], csd[6], csd[7], csd[8], csd[9]);
        if((csd[0] >> 6) != 1) fail("CSD не версии 2.0 - esxDOS посчитает объём по чужой формуле");
        if(memcmp(csd, divmmc_card_csd(), 16) != 0) fail("байты CSD по проводу разошлись с нашими");
        {   uint8_t c = 0; for(i = 0; i < 15; i++) c = crc7_byte(c, csd[i]);
            if(csd[15] != (uint8_t)((c << 1) | 1)) fail("CRC7 в CSD неверен"); }
    }
    if(mmc_read_reg16(0x4A, cid) != 0) fail("CMD10 не отдала блок");
    else {
        char nm[9];
        nm[0] = (char)cid[1]; nm[1] = (char)cid[2]; nm[2] = ' ';
        for(i = 0; i < 5; i++) nm[3 + i] = (char)cid[3 + i];
        nm[8] = 0;
        okline("CMD10 -> имя диска, которое покажет esxDOS: «%s» (L1C8B склеивает OID+' '+PNM)", nm);
        if(memcmp(cid, divmmc_card_cid(), 16) != 0) fail("байты CID по проводу разошлись с нашими");
    }

    /* CMD17: первый сектор. */
    if(mmc_read_block(0, sec_card) != 0) fail("CMD17 сектора 0 не прошла");
    else {
        divmmc_fs_read(0, sec_be);
        okline("CMD17 -> сектор 0: подпись %02X%02X, тип раздела %02X, начало %u",
               sec_card[511], sec_card[510], sec_card[446 + 4],
               (uint32_t)sec_card[446+8] | ((uint32_t)sec_card[446+9] << 8) |
               ((uint32_t)sec_card[446+10] << 16) | ((uint32_t)sec_card[446+11] << 24));
        if(sec_card[510] != 0x55 || sec_card[511] != 0xAA) fail("нет подписи 55AA в первом секторе");
        if(memcmp(sec_card, sec_be, 512) != 0) fail("сектор 0 по SPI разошёлся с бэкендом");
    }
    okline("обменов байтами за всю инициализацию: %u (из них %u - опросы 'ждать не-0xFF')",
           g_spi_bytes, g_poll_bytes);

    /* -------------------------------------------------------------------------------------- */
    printf("=== 2. Ёмкость: как её считает esxDOS ===\n");
    cap_esx = esx_capacity_from_csd(csd, ccs);
    okline("C_SIZE=%u -> (C_SIZE+1)*1024 = %u секторов = %u МБ",
           ((uint32_t)(csd[7] & 0x3F) << 16) | ((uint32_t)csd[8] << 8) | csd[9],
           cap_esx, cap_esx / 2048);
    okline("divmmc_fs_sectors() = %u; ёмкость карты = %u; хвост = %u секторов",
           divmmc_fs_sectors(), divmmc_card_sectors(), divmmc_card_sectors() - divmmc_fs_sectors());
    if(cap_esx != divmmc_card_sectors()) fail("esxDOS насчитает %u, а карта объявляет %u", cap_esx, divmmc_card_sectors());
    if(cap_esx % 1024u) fail("ёмкость не кратна 1024 - такое из CSD 2.0 просто не выражается");
    if(cap_esx < divmmc_fs_sectors()) fail("карта КОРОЧЕ тома: раздел в MBR торчит за её конец");
    {   /* цена округления вниз - в секторах и в байтах настоящих данных */
        uint32_t down = (divmmc_fs_sectors() / 1024u) * 1024u;
        uint32_t lost = (down < divmmc_fs_sectors()) ? divmmc_fs_sectors() - down : 0;
        okline("округление ВНИЗ дало бы %u секторов и отрезало бы %u секторов (%u КБ) хвоста тома",
               down, lost, lost / 2);
    }
    {   /* хвост карты обязан читаться нулями, а не отказом */
        uint32_t t = divmmc_fs_sectors();
        if(t < divmmc_card_sectors()){
            static uint8_t z[512];
            if(mmc_read_block(t, sec_card) != 0) fail("сектор хвоста карты не прочитался");
            else if(memcmp(sec_card, z, 512) != 0) fail("хвост карты не нулевой");
            else okline("хвост карты (LBA %u) читается нулями, как неразмеченная область", t);
        }
    }
    {   /* за концом карты - отказ */
        uint8_t r = mmc_cmd(0x51, divmmc_card_sectors());
        mmc_deselect();
        okline("CMD17 за концом карты (LBA %u) -> R1=0x%02X (ждали бит 0x40 'параметр')",
               divmmc_card_sectors(), r);
        if(!(r & 0x40)) fail("карта не отвергла чтение за своим концом");
    }

    /* -------------------------------------------------------------------------------------- */
    printf("=== 3. Кадрирование ===\n");
    {
        /* 3а. Четыре команды подряд, ВЫБОР НЕ СНИМАЕТСЯ ВООБЩЕ. Именно так ведёт себя esxDOS:
               L1DE0 перед каждой командой лишь повторно пишет тот же код в #E7. */
        uint32_t lbas[4]; int bad = 0;
        lbas[0] = 0; lbas[1] = inf->part_lba; lbas[2] = inf->root_lba; lbas[3] = inf->data_lba;
        divmmc_card_cs(1);
        for(i = 0; i < 4; i++){
            int k;
            if(mmc_cmd(0x51, lbas[i]) != 0x00){ bad++; continue; }
            if(mmc_wait_token() != 0){ bad++; continue; }
            for(k = 0; k < 512; k++) sec_card[k] = spi_in();
            (void)spi_in(); (void)spi_in();
            divmmc_fs_read(lbas[i], sec_be);
            if(memcmp(sec_card, sec_be, 512) != 0) bad++;
            /* НИКАКОГО mmc_deselect() между командами - в этом весь смысл проверки */
        }
        okline("4 команды подряд без снятия выбора: расхождений %d", bad);
        if(bad) fail("автомат теряет команды, когда выбор карты не дёргается");
        mmc_deselect();
    }
    {
        /* 3б. Полезная нагрузка CMD24, набитая байтами 0x40..0x7F - каждый из них похож на начало
               команды. Если сниффер команд работает в потоке ПРИЁМА, кадрирование здесь рассыплется. */
        static uint8_t pat[512];
        int k, r;
        uint8_t r1 = 0xFF;
        g_ram = (uint8_t*)calloc(RAMDISK_SEC, 512);
        divmmc_card_attach(RAMDISK_SEC, be_ram_rd, be_ram_wr);
        /* карту нужно снова довести до готовности - двойник делает это тем же путём */
        mmc_deselect(); for(i = 0; i < 10; i++) spi_out(0xFF);
        mmc_cmd(0x40, 0); mmc_cmd_r37(0x48, 0x000001AA, tail);
        for(i = 0; i < 8; i++){ mmc_cmd(0x77, 0); if(mmc_cmd(0x69, 0x40000000) == 0) break; }

        for(k = 0; k < 512; k++) pat[k] = (uint8_t)(0x40 + (k & 0x3F));   /* сплошь «стартовые биты» */
        r = mmc_write_block(7, pat);
        okline("CMD24 с нагрузкой из одних 0x40..0x7F -> ответ на блок 0x%02X (ждали 0x05)", r);
        if(r != 0x05) fail("запись не принята - кадрирование сорвалось на полезной нагрузке");
        if(memcmp(g_ram + 7 * 512, pat, 512) != 0) fail("записанные байты не совпали с посланными");
        /* и сразу следующая команда - автомат обязан снова слушать команды */
        if(mmc_read_block(7, sec_card) != 0) fail("после записи карта не приняла следующую команду");
        else if(memcmp(sec_card, pat, 512) != 0) fail("прочитали не то, что записали");
        else okline("следующая команда принята, сектор прочитан обратно байт в байт");

        /* 3в. Ещё злее: нагрузка = все 256 значений байта дважды, включая 0x40 в самом начале */
        for(k = 0; k < 512; k++) pat[k] = (uint8_t)(k & 0xFF);
        r = mmc_write_block(8, pat);
        if(r != 0x05 || memcmp(g_ram + 8 * 512, pat, 512) != 0) fail("нагрузка 00..FF сорвала кадр");
        else okline("нагрузка из всех 256 значений байта: принята и совпала");

        /* 3г. Мультиблочное чтение с остановкой CMD12 ПОСРЕДИ потока - тут сниффер, наоборот, обязан
               работать, потому что паузы между блоками у карты нет. */
        {
            int blocks = 0, k2;
            if(mmc_cmd(0x52, 0) != 0x00) fail("CMD18 не принята");
            else {
                for(blocks = 0; blocks < 3; blocks++){
                    if(mmc_wait_token() != 0){ fail("в мультиблочном потоке пропал токен блока"); break; }
                    for(k2 = 0; k2 < 512; k2++) sec_card[k2] = spi_in();
                    (void)spi_in(); (void)spi_in();
                    if(memcmp(sec_card, g_ram + (size_t)blocks * 512, 512) != 0)
                        fail("блок %d мультиблочного чтения не совпал", blocks);
                }
                /* CMD12 отправляем прямо в поток - паузы между блоками у карты нет */
                (void)mmc_cmd(0x4C, 0);
                /* Карта обязана ДОСЛАТЬ текущий блок, ответить R1 и отпустить линию. Хост не знает,
                   где он в потоке, поэтому просто дотактовывает с запасом. */
                for(k2 = 0; k2 < 1024; k2++) (void)spi_in();
                okline("CMD18: три блока совпали, CMD12 посреди потока поймана (счётчик %u), "
                       "автомат вернулся в %s",
                       divmmc_card_stat()->cmd12_inflight, divmmc_card_state_name());
                if(divmmc_card_stat()->cmd12_inflight == 0) fail("CMD12 в потоке не распознана");
                if(strcmp(divmmc_card_state_name(), "IDLE") != 0) fail("после CMD12 карта не вернулась в IDLE");
            }
            mmc_deselect();
        }

        /* 🥇 3г2. ОСТАНОВКА МУЛЬТИБЛОЧНОГО ЧТЕНИЯ ОБЯЗАНА ОТВЕЧАТЬ R1b, ГДЕ БЫ CMD12 НИ ПОЙМАЛИ.
               Оплачено висом Z-Player 4.1 (19.08): «диск увидел, прочитать не смог, подвис, и
               определил не сразу, со второго раза». Приборы с живого виса: DMMC_STAT = 0x00049808
               (state = IDLE, last_cmd = 18, card_busy = 0), DMMC_LBA = 2049, DMMC_DBG = 0x50480004
               (команд 80, чтений 72, desync 4), дельта всех счётчиков за 4 с НУЛЕВАЯ.
               Причина была в том, что у одной команды CMD12 было ДВА разных исполнения: пойманная
               в теле блока получала R1 (но через остаток блока, до 515 байт), а пойманная в ПАУЗЕ
               между блоками не получала НИЧЕГО - карта молча уходила в IDLE и до конца сеанса
               гнала 0xFF. Драйвер, который ждёт R1b (а его ждут все, кто CMD12 вообще посылает),
               на этом висит вечно. А выбор ветки решала ГОНКА с главным циклом оболочки - отсюда и
               «то определяет, то нет».
               Эталон: SD Physical Layer Simplified Spec 6.00, Figure 7-5 (после стоп-команды идёт
               response) и §7.2.8 «in the SPI mode, the card will always respond to a command».
               Живой апстрим: u-boot drivers/mmc/mmc_spi.c помечает CMD12 как R1B и тактует линию
               до ненулевого ответа, а drivers/mmc/mmc.c посылает её ПОСЛЕ того, как забран
               последний блок ВМЕСТЕ с обоими байтами CRC, - то есть ровно в паузу.
               ⚠ Без задержки оболочки этот класс отказов на модели не воспроизводится вовсе: у
               неё fetch_block() мгновенный, и пауза мультиблока длиной в один байт. Поэтому
               divmmc_card_tune_shell() - часть проверки, а не украшение. */
        {
            int pos, busy, tok, blk;
            uint32_t base_lba = 100;
            /* Полезная нагрузка: у КАЖДОГО байта старший бит = 1. Тогда «первый байт с нулевым
               старшим битом» - это заведомо ответ карты, а не данные. Без этой набивки проверка
               была бы неотличима от гадания: сектор из нулей выглядит как R1 = 0x00. */
            for(k = 0; k < 512 * 8; k++)
                g_ram[base_lba * 512 + k] = (uint8_t)(0x80u | (k & 0x7Fu));

            /* --- (а) CMD12 в ПАУЗЕ между блоками, оболочка медлит: снимок с виса ------------- */
            divmmc_card_tune_shell(40);
            if(mmc_cmd(0x52, base_lba) != 0x00) fail("CMD18 не принята");
            else if(mmc_wait_token() != 0) fail("токен первого блока не пришёл");
            else {
                for(k = 0; k < 512; k++) sec_card[k] = spi_in();
                (void)spi_in(); (void)spi_in();     /* оба байта CRC - как канонический драйвер */
                if(memcmp(sec_card, g_ram + base_lba * 512, 512) != 0)
                    fail("блок мультиблочного чтения не совпал с бэкендом");
                mmc_cmd_frame(0x4C, 0);             /* кадр CMD12 целиком попадает в паузу */
                pos = scan_r1(64, &r1);
                okline("CMD12 в паузе между блоками: ответ %s, позиция %d, состояние %s",
                       pos < 0 ? "НЕ ПРИШЁЛ" : "пришёл", pos, divmmc_card_state_name());
                if(pos < 0)
                    fail("CMD12 в паузе между блоками осталась БЕЗ ОТВЕТА - драйвер, ждущий R1b, "
                         "будет опрашивать порт вечно (это и есть вис Z-Player)");
                else if(pos > 8) fail("ответ на CMD12 опоздал на %d байт", pos);
                if(pos >= 0 && r1 != 0x00) fail("ответ на CMD12 = 0x%02X, ждали R1 = 0x00", r1);
                busy = wait_busy_release(16);
                okline("после R1 карта держала занятость %d байт и отпустила линию", busy);
                if(busy < 0) fail("после CMD12 линия не отпущена - карта осталась занятой навсегда");
                if(mmc_read_block(base_lba + 1, sec_card) != 0)
                    fail("после остановки карта не приняла следующую команду (CMD17)");
                else if(memcmp(sec_card, g_ram + (base_lba + 1) * 512, 512) != 0)
                    fail("сектор после остановки прочитан неверно");
                else okline("после остановки одиночное чтение прошло байт в байт");
            }
            mmc_deselect();

            /* --- (б) CMD12 ПОСРЕДИ ТЕЛА блока: ответ не должен ждать конца блока ------------- */
            divmmc_card_tune_shell(0);
            if(mmc_cmd(0x52, base_lba) != 0x00) fail("CMD18 (б) не принята");
            else if(mmc_wait_token() != 0) fail("токен блока (б) не пришёл");
            else {
                for(k = 0; k < 100; k++) (void)spi_in();   /* стоим в середине тела блока */
                mmc_cmd_frame(0x4C, 0);
                pos = scan_r1(700, &r1);
                okline("CMD12 посреди тела блока: ответ %s, позиция %d",
                       pos < 0 ? "НЕ ПРИШЁЛ" : "пришёл", pos);
                if(pos < 0) fail("CMD12 посреди блока осталась без ответа");
                else if(pos > 8)
                    fail("ответ на CMD12 пришёл только через %d байт: карта досылает остаток блока, "
                         "и драйвер принимает за R1 байт ДАННЫХ", pos);
                if(pos >= 0 && r1 != 0x00) fail("ответ на CMD12 (б) = 0x%02X, ждали 0x00", r1);
                if(wait_busy_release(16) < 0) fail("после CMD12 (б) линия не отпущена");
                if(mmc_read_block(base_lba, sec_card) != 0)
                    fail("после остановки (б) карта не приняла CMD17");
            }
            mmc_deselect();

            /* --- (в) CMD12 ДО первого блока: карта ждёт оболочку, данных в полёте нет -------- */
            divmmc_card_tune_shell(40);
            if(mmc_cmd(0x52, base_lba) != 0x00) fail("CMD18 (в) не принята");
            else {
                mmc_cmd_frame(0x4C, 0);             /* кадр попадает в ожидание блока */
                pos = scan_r1(64, &r1);
                okline("CMD12 до первого блока: ответ %s, позиция %d",
                       pos < 0 ? "НЕ ПРИШЁЛ" : "пришёл", pos);
                if(pos < 0) fail("CMD12 до первого блока осталась без ответа");
                else if(pos > 8)
                    fail("ответ на CMD12 (в) пришёл через %d байт: карта досылает ненужный блок", pos);
                if(pos >= 0 && r1 != 0x00) fail("ответ на CMD12 (в) = 0x%02X, ждали 0x00", r1);
                (void)wait_busy_release(16);
                tok = scan_data_token(600);
                okline("после остановки токен данных 0xFE %s", tok ? "ПОЯВИЛСЯ" : "не появлялся");
                if(tok) fail("остановленная карта всё равно выдала блок, который никому не нужен");
                if(mmc_read_block(base_lba, sec_card) != 0)
                    fail("после остановки (в) карта не приняла CMD17");
            }
            mmc_deselect();

            /* --- (г) КАНОНИЧЕСКИЙ ДРАЙВЕР (форма Wild Player и u-boot): три блока подряд,
                   CMD12 на границе. Данные обязаны остаться теми же байтами, что и были. ------ */
            divmmc_card_tune_shell(4);
            if(mmc_cmd(0x52, base_lba) != 0x00) fail("CMD18 (г) не принята");
            else {
                for(blk = 0; blk < 3; blk++){
                    if(mmc_wait_token() != 0){ fail("в потоке (г) пропал токен блока %d", blk); break; }
                    for(k = 0; k < 512; k++) sec_card[k] = spi_in();
                    (void)spi_in(); (void)spi_in();
                    if(memcmp(sec_card, g_ram + (base_lba + blk) * 512, 512) != 0)
                        fail("блок %d потока (г) не совпал с бэкендом", blk);
                }
                mmc_cmd_frame(0x4C, 0);
                pos = scan_r1(64, &r1);
                okline("канонический драйвер: три блока совпали, ответ на CMD12 %s, позиция %d",
                       pos < 0 ? "НЕ ПРИШЁЛ" : "пришёл", pos);
                if(pos < 0) fail("канонический драйвер не получил ответа на CMD12");
                else if(pos > 8) fail("ответ на CMD12 (г) опоздал на %d байт", pos);
                if(pos >= 0 && r1 != 0x00) fail("ответ на CMD12 (г) = 0x%02X, ждали 0x00", r1);
                if(wait_busy_release(16) < 0) fail("после CMD12 (г) линия не отпущена");
                if(mmc_read_block(base_lba + 2, sec_card) != 0)
                    fail("после остановки (г) карта не приняла CMD17");
                else if(memcmp(sec_card, g_ram + (base_lba + 2) * 512, 512) != 0)
                    fail("сектор после остановки (г) прочитан неверно");
            }
            mmc_deselect();
            divmmc_card_tune_shell(0);
        }

        /* 3д. Неизвестная команда обязана быть видна в отладочном слове. */
        {
            uint8_t r2 = mmc_cmd(0x40 + 40, 0);      /* CMD40 - её не поддерживает никто */
            uint32_t d = divmmc_card_dbg();
            mmc_deselect();
            okline("CMD40 -> R1=0x%02X (ждали 0x04); отладочное слово 0x%08X, номер в поле [11:6] = %u",
                   r2, d, (d >> 6) & 0x3F);
            if(r2 != 0x04) fail("неизвестная команда обязана давать ровно 0x04");
            if(((d >> 6) & 0x3F) != 40) fail("номер неизвестной команды не попал в отладочное слово");
        }
        free(g_ram); g_ram = 0;
    }

    /* -------------------------------------------------------------------------------------- */
    printf("=== 4. Десять тысяч случайных секторов через CMD17 ===\n");
    divmmc_card_attach(divmmc_fs_sectors(), be_fs_rd, be_fs_wr);
    mmc_deselect(); for(i = 0; i < 10; i++) spi_out(0xFF);
    mmc_cmd(0x40, 0); mmc_cmd_r37(0x48, 0x000001AA, tail);
    for(i = 0; i < 8; i++){ mmc_cmd(0x77, 0); if(mmc_cmd(0x69, 0x40000000) == 0) break; }
    {
        uint32_t n = 10000, bad = 0, k;
        lcg = 20260813u;
        for(k = 0; k < n; k++){
            uint32_t lba = rnd32() % divmmc_fs_sectors();
            if(mmc_read_block(lba, sec_card) != 0){ bad++; continue; }
            if(divmmc_fs_read(lba, sec_be) != 0){ bad++; continue; }
            if(memcmp(sec_card, sec_be, 512) != 0) bad++;
        }
        okline("прочитано %u секторов, расхождений %u", n, bad);
        if(bad) fail("чтение по SPI не совпадает с бэкендом");
    }

    /* -------------------------------------------------------------------------------------- */
    printf("=== 5. Запись в НАСТОЯЩИЙ том (бэкенд её пока отвергает) ===\n");
    {
        static uint8_t w[512];
        int r;
        memset(w, 0xA5, sizeof(w));
        r = mmc_write_block(inf->data_lba, w);
        okline("CMD24 в область данных -> ответ на блок 0x%02X (0x05 принято, 0x0D отказ), «%s»",
               r, divmmc_fs_msg());
        /* 🥇 Проверка ПЕРЕПИСАНА, когда бэкенд научился писать. Раньше здесь стояло `r != 0x0D`,
           то есть тест ЗАКРЕПЛЯЛ отказ как правильное поведение - и после реализации записи он
           начал падать на исправном коде. Тест, кодирующий временное ограничение как требование,
           превращается в тормоз ровно в тот день, когда ограничение снимают. Теперь проверяем
           СМЫСЛ: легальная запись в область данных ПРИНИМАЕТСЯ (0x05), а попытка переразметки
           отвергается (0x0D). Отказ от бэкенда по-прежнему обязан доезжать до хоста - это и
           проверяет вторая половина. */
        if(r != 0x05) fail("легальная запись в область данных обязана приниматься ответом 0x05");
        r = mmc_write_block(0, w);
        okline("CMD24 в MBR -> 0x%02X, «%s»", r, divmmc_fs_msg());
        if(r != 0x0D) fail("попытка переразметки обязана отвергаться");
        okline("вывод: запись доходит до бэкенда и принимается им; переразметка тома отвергается");
    }

    /* -------------------------------------------------------------------------------------- */
    printf("=== 6. Итоговые счётчики карты ===\n");
    {
        const divmmc_card_stat_t* st = divmmc_card_stat();
        okline("обменов %u, команд %u (неизвестных %u), блоков прочитано %u, записано %u",
               st->bytes, st->cmds, st->cmd_unknown, st->blocks_rd, st->blocks_wr);
        okline("чужих байтов в кадре команд %u, ошибок CRC7 %u, отказов бэкенда чтение/запись %u/%u",
               st->stray, st->crc7_bad, st->rd_err, st->wr_err);
        okline("отладочное слово 0x%08X, состояние %s", divmmc_card_dbg(), divmmc_card_state_name());
        if(st->stray) fail("в кадре команд встречались посторонние байты - подозрение на рассинхрон");
    }

    /* -------------------------------------------------------------------------------------- */
    if(image){
        FILE* f = fopen(image, "wb");
        uint32_t k, n = divmmc_card_sectors();
        printf("=== 7. Выгрузка образа карты ЧЕРЕЗ CMD17 в %s ===\n", image);
        if(!f) fail("не открыть %s", image);
        else {
            uint32_t bad = 0;
            for(k = 0; k < n; k++){
                if(mmc_read_block(k, sec_card) != 0){ bad++; memset(sec_card, 0, 512); }
                fwrite(sec_card, 1, 512, f);
            }
            fclose(f);
            okline("записано %u секторов (%u МБ), отказов %u", n, n / 2048, bad);
            if(bad) fail("часть секторов не отдалась");
        }
    }

    printf("\n==== ИТОГ: %s (отказов %d) ====\n", g_fail ? "ЕСТЬ ОШИБКИ" : "ВСЁ СОШЛОСЬ", g_fail);
    return g_fail ? 1 : 0;
}
