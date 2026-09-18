/* divmmc_card.c - КАРТА SD СО СТОРОНЫ ХОСТА: исполняемая спецификация будущего RTL.
 *
 * Зачем отдельный модуль. Синтезатор тома (divmmc_fs.c) уже умеет отдавать «сектор номер N».
 * Не хватает второй половины DivMMC: того, кто разговаривает с Z80 по SPI байтами команд SD.
 * Этот автомат и есть недостающая половина. Он написан так, чтобы его можно было переложить в
 * Verilog построчно: никакой динамической памяти, ни одного вызова стандартной библиотеки в
 * горячем пути, всё состояние - несколько регистров плюс буфер сектора (в ПЛИС это BRAM).
 *
 * ГРАНИЦА ОТВЕТСТВЕННОСТИ. Сборкой битов в байты занимается уже синтезированный сдвигатель
 * cores/zx/src/spi.v, поэтому наш интерфейс БАЙТОВЫЙ:
 *     divmmc_card_cs(sel)              - защёлка выбора карты (порт #E7 у DivMMC);
 *     miso = divmmc_card_xfer(mosi)    - один обмен байтом.
 * Важно понимать, что spi.v отдаёт процессору байт ПРЕДЫДУЩЕГО обмена (`md <= sd` в момент
 * старта нового обмена). Эта задержка на байт живёт в сдвигателе, а НЕ в карте: карта на каждый
 * принятый байт отдаёт свой в том же обмене. Именно поэтому esxDOS перед каждой командой делает
 * холостое чтение порта (L1DE0) - оно выталкивает мусор из конвейера. Наш автомат от задержки не
 * зависит вовсе, а стенд её моделирует, чтобы проверять всю цепочку целиком.
 *
 * ОТКУДА ВЗЯТЫ ТРЕБОВАНИЯ. Всё, что здесь помечено словом «проверено», прочитано в дизассемблере
 * настоящей прошивки esxDOS 0.8.9 (refs/divmmc/disasm/esxdos.asm), ссылки на метки даны по нему.
 * Порты DivMMC оттуда же (esxdosinc.asm): #E3 - страница ОЗУ/управление, #E7 - выбор карты,
 * #EB - данные SPI.
 *
 * Прототипы (пока без заголовка - в arm/ идут параллельные работы, новых файлов ровно два;
 * когда появится divmmc_card.h, этот блок переедет туда без изменений):
 *
 *   typedef int (*divmmc_card_rd_fn)(uint32_t lba, uint8_t* buf);
 *   typedef int (*divmmc_card_wr_fn)(uint32_t lba, const uint8_t* buf);
 *   void     divmmc_card_attach(uint32_t vol_sectors, divmmc_card_rd_fn rd, divmmc_card_wr_fn wr);
 *   void     divmmc_card_detach(void);
 *   void     divmmc_card_power_cycle(void);
 *   void     divmmc_card_cs(int selected);
 *   uint8_t  divmmc_card_xfer(uint8_t mosi);
 *   uint32_t divmmc_card_sectors(void);
 *   uint32_t divmmc_card_dbg(void);
 *   const uint8_t* divmmc_card_csd(void);
 *   const uint8_t* divmmc_card_cid(void);
 *   const char*    divmmc_card_state_name(void);
 *   void     divmmc_card_tune(int ncr, int nac, int acmd41_busy, int write_busy);
 *   void     divmmc_card_tune_shell(int gap_bytes);
 *   void     divmmc_card_round_down(int on);
 *
 * Сборка на хосте: модуль самодостаточен, нужны только <stdint.h> и <string.h>.
 */

#include <stdint.h>
#include <string.h>

/* ============================================================================================ */
/* Параметры карты                                                                              */
/* ============================================================================================ */

#define DMC_SECSZ   512u

/* Токены данных SD в режиме SPI. */
#define DMC_TOK_SINGLE  0xFEu   /* начало блока: чтение любое, запись одиночная */
#define DMC_TOK_MULTI   0xFCu   /* начало блока при мультиблочной ЗАПИСИ */
#define DMC_TOK_STOP    0xFDu   /* конец мультиблочной записи */

/* Ответ на принятый блок данных (младшие 5 бит): 0b00101 принято, 0b01011 ошибка CRC,
   0b01101 ошибка записи. Верхние биты не определены, реальные карты шлют там единицы -
   поэтому esxDOS и делает `and $1f` перед сравнением с 5 (проверено, L1DEA). */
#define DMC_DR_ACCEPT   0x05u
#define DMC_DR_WRERR    0x0Du

typedef int (*divmmc_card_rd_fn)(uint32_t lba, uint8_t* buf);
typedef int (*divmmc_card_wr_fn)(uint32_t lba, const uint8_t* buf);

/* Состояния автомата. Порядок важен только для отладочного слова. */
enum {
    DMC_S_IDLE = 0,   /* ждём стартовый бит команды */
    DMC_S_ARG,        /* добираем 5 байт: аргумент и CRC7 */
    DMC_S_NCR,        /* пауза перед ответом (N_CR у настоящей карты 1..8 байт) */
    DMC_S_RESP,       /* отдаём R1 и хвост R3/R7 */
    DMC_S_NAC,        /* пауза перед токеном блока при чтении */
    DMC_S_TOKEN,      /* отдаём 0xFE */
    DMC_S_TX,         /* отдаём 512 байт сектора */
    DMC_S_TXCRC,      /* отдаём 2 байта CRC16 */
    DMC_S_MBGAP,      /* пауза между блоками мультиблочного чтения */
    DMC_S_RXWAIT,     /* ждём токен блока ОТ ХОСТА */
    DMC_S_RX,         /* принимаем 512 байт */
    DMC_S_RXCRC,      /* принимаем 2 байта CRC (не проверяем, см. ниже) */
    DMC_S_RXRESP,     /* отдаём data response */
    DMC_S_BUSY,       /* держим 0x00 - карта занята записью */
    DMC_S_NCOUNT
};

static const char* const dmc_state_names[DMC_S_NCOUNT] = {
    "IDLE", "ARG", "NCR", "RESP", "NAC", "TOKEN", "TX", "TXCRC",
    "MBGAP", "RXWAIT", "RX", "RXCRC", "RXRESP", "BUSY"
};

/* Счётчики - это прибор, а не украшение: почти каждый отказ такой связки виден именно тут. */
typedef struct {
    uint32_t bytes;            /* всего обменов байтами при выбранной карте */
    uint32_t bytes_idle_cs;    /* обменов при СНЯТОМ выборе (карта их игнорирует) */
    uint32_t cmds;             /* принято полных кадров команд */
    uint32_t cmd_unknown;      /* из них с неизвестным номером */
    uint32_t crc7_bad;         /* кадров с неверным CRC7 (кроме заполнителя 0xFF) */
    uint32_t stray;            /* байтов в кадре команд, которые не 0xFF и не стартовый бит */
    uint32_t blocks_rd, blocks_wr;
    uint32_t rd_err, wr_err;   /* отказы бэкенда */
    uint32_t pad_rd;           /* чтений «хвоста» карты за концом тома */
    uint32_t pre_cmd0_clocks;  /* байтов при снятом CS до самой первой CMD0 (нужно >= 10) */
    uint32_t cmd12_inflight;   /* CMD12, пойманных ПОСРЕДИ потока данных */
    uint32_t last_cmd, last_arg;
} divmmc_card_stat_t;

/* ============================================================================================ */
/* Состояние                                                                                    */
/* ============================================================================================ */

static int      g_attached;
static int      g_cs;                    /* 1 = карта выбрана (у DivMMC это бит 0 порта #E7 в нуле) */
static int      g_state;

static uint32_t g_vol;                   /* сколько секторов реально отдаёт бэкенд */
static uint32_t g_cap;                   /* ёмкость карты: кратна 1024 (см. CSD ниже) */
static int      g_round_down;            /* как округлять ёмкость до кратной 1024 */

static divmmc_card_rd_fn g_rd;
static divmmc_card_wr_fn g_wr;

static uint8_t  g_cmd[6];
static int      g_cmd_n;
static uint8_t  g_crc7;

static uint8_t  g_resp[5];
static int      g_resp_n, g_resp_i;
static int      g_after_resp;            /* что делать, когда ответ дошлётся */

static uint8_t  g_buf[DMC_SECSZ];
static uint16_t g_dat_i;
static uint16_t g_dat_len;               /* длина блока: 512 у сектора и 16 у CSD/CID */
static uint16_t g_crc16;
static uint8_t  g_crc16_out[2];
static int      g_crc16_i;

static uint32_t g_lba;                   /* текущий сектор потока */
static int      g_multi;                 /* идёт мультиблочная операция */
static int      g_stop_after_block;      /* поймали CMD12 посреди потока */
static int      g_wait;                  /* счётчик пауз N_CR / N_AC / busy */

static int      g_spi_mode;              /* была CMD0 */
static int      g_idle;                  /* карта в состоянии idle (бит 0 в R1) */
static int      g_app;                   /* предыдущая команда была CMD55 */
static int      g_acmd41_left;           /* сколько раз ещё ответить «ещё не готова» */
static int      g_seen_cmd0;

static uint8_t  g_csd[16], g_cid[16];

/* Настройки таймингов. Значения по умолчанию - самые «тесные» из допустимых: карта отвечает
   через один байт. Знобить их полезно как раз для проверки того, что драйвер не завязан на
   мгновенный ответ (esxDOS не завязан - он опрашивает порт, L1DD2). */
static int      g_ncr = 1;               /* байтов 0xFF между командой и R1 */
static int      g_nac = 2;               /* байтов 0xFF между R1 и токеном блока */
static int      g_acmd41_busy = 2;       /* сколько ACMD41 ответят 0x01 до готовности */
static int      g_write_busy = 4;        /* байтов 0x00 после приёма блока */
static int      g_fast_ack   = 0;        /* B0150: последний байт занятости = 0x01 вместо 0xFF (см. RTL cfg_fast) */
/* 🥇 ЗАДЕРЖКА ОБОЛОЧКИ - ЭТО ЧАСТЬ СПЕЦИФИКАЦИИ, А НЕ УКРАШЕНИЕ СТЕНДА. В ПЛИС блок приносит
   не память, а главный цикл ARM: в S_NAC и S_MBGAP карта гонит 0xFF, пока не приедет ack (в RTL
   это `else wcnt <= 4'd1`), и ждать может десятки миллисекунд. У модели же fetch_block() мгновенный,
   поэтому пауза мультиблока получалась длиной в ОДИН байт - и целый класс отказов (кадр команды,
   целиком попавший в паузу) стенд увидеть не мог в принципе. Этим числом стенд удлиняет паузу до
   железной. По умолчанию 0 - прежнее поведение. */
static int      g_shell_lat = 0;         /* лишних байтов 0xFF, пока «оболочка думает» */

/* Отладочное слово - ровно то, что в ПЛИС ляжет в регистр диагностики оболочки. */
static uint8_t  g_dbg_last_cmd, g_dbg_last_unknown;
static uint8_t  g_dbg_cnt_unknown, g_dbg_cnt_stray, g_dbg_cnt_crc7;
static uint8_t  g_sticky_rd, g_sticky_wr, g_sticky_frame;

static divmmc_card_stat_t g_st;

/* ============================================================================================ */
/* Контрольные суммы                                                                            */
/* ============================================================================================ */

/* CRC7 (x^7+x^3+1) - подпись команд и последний байт CSD/CID. В ПЛИС это семибитный сдвиговый
   регистр с обратной связью, здесь - его побайтовая развёртка. */
static uint8_t crc7_byte(uint8_t crc, uint8_t b)
{
    int i;
    for(i = 0; i < 8; i++){
        uint8_t bit = (uint8_t)(((crc >> 6) ^ (b >> 7)) & 1u);
        crc = (uint8_t)((crc << 1) & 0x7Fu);
        if(bit) crc ^= 0x09u;
        b = (uint8_t)(b << 1);
    }
    return crc;
}

/* CRC16-CCITT блока данных.
   🥇 ПРОВЕРЕНО ПО КОДУ esxDOS: она эти два байта ЧИТАЕТ И ВЫБРАСЫВАЕТ. В L1E51 (чтение сектора)
   после двух `inir` по 256 байт идут два голых `in a,(mmcspi)` и сразу `or a` - результат никуда
   не сохраняется и ни с чем не сравнивается. То есть фиктивный CRC прошёл бы. Мы всё равно
   считаем настоящий: в ПЛИС это 16 триггеров и три XOR, а UnoDOS и самописные драйверы CRC
   проверяют - экономить тут не на чем. */
static uint16_t crc16_byte(uint16_t crc, uint8_t b)
{
    int i;
    crc ^= (uint16_t)((uint16_t)b << 8);
    for(i = 0; i < 8; i++)
        crc = (uint16_t)((crc & 0x8000u) ? ((crc << 1) ^ 0x1021u) : (crc << 1));
    return crc;
}

/* ============================================================================================ */
/* CSD и CID                                                                                    */
/* ============================================================================================ */

/* 🥇 CSD ОБЯЗАН БЫТЬ ВЕРСИИ 2.0 (CCS=1), и вот почему это не вкусовщина.
   esxDOS считает объём в L1EA3: если бит 6 флагов (он же бит 30 регистра OCR, он же CCS) взведён,
   она берёт из CSD байты 7..9, маскирует у седьмого шесть младших бит - это C_SIZE, 22 бита, -
   прибавляет единицу (L081C - 32-битный инкремент) и умножает на 1024 (L1E97 сдвигает на 8 бит,
   затем два раза на один). Никакого другого источника ёмкости у неё нет.
   Отсюда жёсткое следствие: ЁМКОСТЬ КАРТЫ ВЫРАЖАЕТСЯ ТОЛЬКО ЦЕЛЫМ ЧИСЛОМ ПО 1024 СЕКТОРА.
   Размер синтезированного тома таким числом не является (divmmc_fs считает его как
   data_lba + кластеры*64), поэтому округлять приходится нам.

   Округляем ВВЕРХ, и это сознательное отступление от первоначального указания «только вниз».
   Вниз нельзя: в MBR у нас записан раздел длиной vol_sectors - part_lba, и если карта окажется
   КОРОЧЕ тома, раздел будет торчать за её конец. Это не теория: вниз теряется до 1023 секторов,
   а в них лежит хвост последнего файла. Вверх же всё честно - у настоящей карты раздел почти
   всегда короче носителя, и сектора «хвоста» (между концом тома и концом карты) мы отдаём
   нулями, ровно как отдала бы неразмеченная область. Кому нужно поведение «вниз» - есть
   divmmc_card_round_down(1), и стенд печатает, сколько байт настоящих данных при этом
   отрезается. */
static uint32_t cap_from_vol(uint32_t vol)
{
    uint32_t units;
    if(vol == 0) return 1024u;
    if(g_round_down){
        units = vol / 1024u;
        if(units == 0) units = 1u;      /* меньше 512 КБ карта объявить не может */
    } else {
        units = (vol + 1023u) / 1024u;
    }
    return units * 1024u;
}

static void build_csd(void)
{
    uint32_t csize = (g_cap / 1024u) - 1u;      /* обратная формула к esxDOS-овской */
    memset(g_csd, 0, sizeof(g_csd));
    g_csd[0]  = 0x40;              /* CSD_STRUCTURE = 01b -> версия 2.0 */
    g_csd[1]  = 0x0E;              /* TAAC */
    g_csd[2]  = 0x00;              /* NSAC */
    g_csd[3]  = 0x32;              /* TRAN_SPEED = 25 МГц */
    g_csd[4]  = 0x5B;              /* CCC[11:4] */
    g_csd[5]  = 0x59;              /* CCC[3:0] и READ_BL_LEN = 9 (512 Б) */
    g_csd[6]  = 0x00;
    g_csd[7]  = (uint8_t)((csize >> 16) & 0x3Fu);
    g_csd[8]  = (uint8_t)((csize >> 8) & 0xFFu);
    g_csd[9]  = (uint8_t)(csize & 0xFFu);
    g_csd[10] = 0x7F;              /* ERASE_BLK_EN=1, SECTOR_SIZE старшие биты */
    g_csd[11] = 0x80;              /* младший бит SECTOR_SIZE, WP_GRP_SIZE=0 */
    g_csd[12] = 0x0A;              /* R2W_FACTOR=2, WRITE_BL_LEN=9 (старшие биты) */
    g_csd[13] = 0x40;              /* младшие биты WRITE_BL_LEN */
    g_csd[14] = 0x40;              /* COPY=1, защит записи нет */
    {   int i; uint8_t c = 0;
        for(i = 0; i < 15; i++) c = crc7_byte(c, g_csd[i]);
        g_csd[15] = (uint8_t)((c << 1) | 1u);
    }
}

/* CID. Он не украшение: esxDOS в L1C8B склеивает из него ИМЯ ДИСКА, которое показывает в своих
   меню - два байта OID, пробел, пять байт PNM (двойной `ldi` поверх байта MID, потом восемь байт
   в буфер имени). То есть строка «BL BULBU» на экране Спектрума приходит именно отсюда, и это
   удобный признак того, что читается НАША карта, а не чужой образ. */
static void build_cid(void)
{
    memset(g_cid, 0, sizeof(g_cid));
    g_cid[0]  = 0xBB;                      /* MID: за известными производителями не числится */
    g_cid[1]  = 'B'; g_cid[2] = 'L';       /* OID */
    g_cid[3]  = 'B'; g_cid[4] = 'U'; g_cid[5] = 'L'; g_cid[6] = 'B'; g_cid[7] = 'U';  /* PNM */
    g_cid[8]  = 0x15;                      /* PRV 1.5 */
    g_cid[9]  = 0x42; g_cid[10] = 0x55; g_cid[11] = 0x4C; g_cid[12] = 0x42;           /* PSN */
    g_cid[13] = 0x01;                      /* MDT: год 2026 ... */
    g_cid[14] = 0xA8;                      /* ... месяц 8 */
    {   int i; uint8_t c = 0;
        for(i = 0; i < 15; i++) c = crc7_byte(c, g_cid[i]);
        g_cid[15] = (uint8_t)((c << 1) | 1u);
    }
}

/* ============================================================================================ */
/* Внешний интерфейс                                                                            */
/* ============================================================================================ */

static void reset_card(void)
{
    g_state = DMC_S_IDLE;
    g_cmd_n = 0; g_resp_n = g_resp_i = 0; g_after_resp = DMC_S_IDLE;
    g_dat_i = 0; g_dat_len = DMC_SECSZ; g_crc16 = 0; g_crc16_i = 0;
    g_multi = 0; g_stop_after_block = 0; g_wait = 0;
    g_spi_mode = 0; g_idle = 1; g_app = 0;
    g_acmd41_left = g_acmd41_busy;
    g_seen_cmd0 = 0;
}

void divmmc_card_power_cycle(void)
{
    reset_card();
    memset(&g_st, 0, sizeof(g_st));
    g_sticky_rd = g_sticky_wr = g_sticky_frame = 0;
    g_dbg_last_cmd = g_dbg_last_unknown = 0;
    g_dbg_cnt_unknown = g_dbg_cnt_stray = g_dbg_cnt_crc7 = 0;
    g_cs = 0;
}

void divmmc_card_round_down(int on){ g_round_down = on ? 1 : 0; }

void divmmc_card_attach(uint32_t vol_sectors, divmmc_card_rd_fn rd, divmmc_card_wr_fn wr)
{
    g_vol = vol_sectors;
    g_cap = cap_from_vol(vol_sectors);
    g_rd  = rd;
    g_wr  = wr;
    build_csd();
    build_cid();
    divmmc_card_power_cycle();
    g_attached = 1;
}

void divmmc_card_detach(void){ g_attached = 0; }

void divmmc_card_tune_shell(int gap_bytes)
{
    if(gap_bytes >= 0) g_shell_lat = gap_bytes;
}

void divmmc_card_fast_ack(int on){ g_fast_ack = on ? 1 : 0; }   /* B0150 */
void divmmc_card_tune(int ncr, int nac, int acmd41_busy, int write_busy)
{
    if(ncr >= 0) g_ncr = ncr;
    if(nac >= 0) g_nac = nac;
    if(acmd41_busy >= 0){ g_acmd41_busy = acmd41_busy; g_acmd41_left = acmd41_busy; }
    if(write_busy >= 0) g_write_busy = write_busy;
}

uint32_t divmmc_card_sectors(void){ return g_attached ? g_cap : 0u; }
uint32_t divmmc_card_volume_sectors(void){ return g_vol; }
const uint8_t* divmmc_card_csd(void){ return g_csd; }
const uint8_t* divmmc_card_cid(void){ return g_cid; }
const char* divmmc_card_state_name(void){ return dmc_state_names[g_state]; }
const divmmc_card_stat_t* divmmc_card_stat(void){ return &g_st; }

/* 🥇 Выбор карты - это ЗАЩЁЛКА, а не строб. У DivMMC порт #E7: младший бит в нуле = выбрана
   карта 0 (esxDOS кладёт туда 0xF6 для первого носителя и 0xF5 для второго - L1C80), 0xFF =
   не выбрана ни одна. Пока карта не выбрана, она обязана ОТПУСТИТЬ линию: любой обмен в это
   время - чужой, отвечаем только единицами. */
void divmmc_card_cs(int selected)
{
    if(g_cs && !selected){
        /* Снятие выбора посреди кадра команды - кадр недействителен. Настоящая карта в такой
           ситуации ведёт себя неопределённо; мы выбираем самое предсказуемое: забыть недобранное. */
        if(g_state == DMC_S_ARG){ g_cmd_n = 0; g_state = DMC_S_IDLE; }
    }
    g_cs = selected ? 1 : 0;
}

/* ============================================================================================ */
/* Выполнение команды                                                                           */
/* ============================================================================================ */

static uint8_t r1_base(void){ return (uint8_t)(g_idle ? 0x01u : 0x00u); }

static void resp1(uint8_t r1, int after)
{
    g_resp[0] = r1; g_resp_n = 1; g_resp_i = 0;
    g_after_resp = after;
    g_wait = g_ncr;
    g_state = (g_ncr > 0) ? DMC_S_NCR : DMC_S_RESP;
}

static void resp5(uint8_t r1, uint32_t tail, int after)
{
    g_resp[0] = r1;
    g_resp[1] = (uint8_t)(tail >> 24);
    g_resp[2] = (uint8_t)(tail >> 16);
    g_resp[3] = (uint8_t)(tail >> 8);
    g_resp[4] = (uint8_t)tail;
    g_resp_n = 5; g_resp_i = 0;
    g_after_resp = after;
    g_wait = g_ncr;
    g_state = (g_ncr > 0) ? DMC_S_NCR : DMC_S_RESP;
}

/* Подать блок в буфер. Возвращает 0, если блок есть. */
static int fetch_block(uint32_t lba)
{
    if(lba >= g_cap) return -1;
    if(lba >= g_vol){
        /* Хвост карты за концом тома. Настоящая неразмеченная область читается нулями -
           отдаём нули и НЕ дёргаем бэкенд: он про эти сектора ничего не знает. */
        memset(g_buf, 0, DMC_SECSZ);
        g_st.pad_rd++;
        return 0;
    }
    if(!g_rd) return -1;
    if(g_rd(lba, g_buf) != 0){ g_st.rd_err++; g_sticky_rd = 1; return -1; }
    return 0;
}

static void start_tx_block(void)
{
    g_dat_i = 0; g_dat_len = DMC_SECSZ; g_crc16 = 0; g_crc16_i = 0;
    g_wait = g_nac + g_shell_lat;        /* в ПЛИС здесь ждут ОБОЛОЧКУ, а не память */
    g_state = (g_nac > 0) ? DMC_S_NAC : DMC_S_TOKEN;
}

static void exec_cmd(void)
{
    uint8_t idx = (uint8_t)(g_cmd[0] & 0x3Fu);
    uint32_t arg = ((uint32_t)g_cmd[1] << 24) | ((uint32_t)g_cmd[2] << 16) |
                   ((uint32_t)g_cmd[3] << 8)  |  (uint32_t)g_cmd[4];
    int app = g_app;

    g_app = 0;
    g_st.cmds++;
    g_st.last_cmd = idx; g_st.last_arg = arg;
    g_dbg_last_cmd = idx;

    /* CRC7 команд в режиме SPI карта не проверяет (кроме CMD0/CMD8 на некоторых картах), и
       esxDOS честно шлёт 0xFF везде, кроме CMD0 ($95) и CMD8 ($87) - это видно в L1D9A. Мы тоже
       не отказываем, но СЧИТАЕМ несовпадения: если в железе поедет битность сдвигателя, счётчик
       вспыхнет раньше, чем что-нибудь развалится. */
    if(g_cmd[5] != 0xFFu){
        uint8_t want = (uint8_t)((g_crc7 << 1) | 1u);
        if(g_cmd[5] != want){
            g_st.crc7_bad++;
            if(g_dbg_cnt_crc7 < 7) g_dbg_cnt_crc7++;
        }
    }

    /* Пока не было CMD0, карта в SPI-режим не переведена. Настоящая карта на шину бы вовсе не
       ответила; мы отвечаем «idle + недопустимая команда», чтобы драйвер не завис навсегда. */
    if(!g_spi_mode && idx != 0){
        resp1((uint8_t)(0x01u | 0x04u), DMC_S_IDLE);
        return;
    }

    if(app){
        /* Прикладные команды: номер тот же, смысл другой. У esxDOS их ровно одна - ACMD41. */
        switch(idx){
        case 41:   /* SD_SEND_OP_COND: аргумент 0x40000000 = хост понимает карты большой ёмкости */
            if(g_acmd41_left > 0){ g_acmd41_left--; resp1(0x01u, DMC_S_IDLE); }
            else { g_idle = 0; resp1(0x00u, DMC_S_IDLE); }
            return;
        default:
            break;      /* прочие ACMD трактуем как обычные команды */
        }
    }

    switch(idx){
    case 0:     /* GO_IDLE_STATE */
        g_spi_mode = 1; g_seen_cmd0 = 1; g_idle = 1;
        g_acmd41_left = g_acmd41_busy;
        resp1(0x01u, DMC_S_IDLE);
        return;

    case 1:     /* SEND_OP_COND - путь для карт версии 1, у esxDOS запасной (L1D00, hl=$1D65) */
        if(g_acmd41_left > 0){ g_acmd41_left--; resp1(0x01u, DMC_S_IDLE); }
        else { g_idle = 0; resp1(0x00u, DMC_S_IDLE); }
        return;

    case 55:    /* APP_CMD: следующая команда - прикладная.
                   esxDOS шлёт его перед каждой ACMD41 и ОТВЕТ НЕ ПРОВЕРЯЕТ (L1D20: `ld a,$77 :
                   call L1D67` - возвращённый флаг переноса выбрасывается). Ответ 0x01 в idle -
                   норма, а не ошибка. */
        g_app = 1;
        resp1(r1_base(), DMC_S_IDLE);
        return;

    case 8: {   /* SEND_IF_COND: ответ R7 - эхо младших 12 бит аргумента */
        uint32_t echo = arg & 0x00000FFFu;
        resp5(r1_base(), echo, DMC_S_IDLE);
        return;
    }

    case 9:     /* SEND_CSD */
    case 10:    /* SEND_CID */
        /* 🥇 САМОЕ ЧАСТОЕ МЕСТО ОШИБКИ. Это не «R1 и следом 16 байт», а НАСТОЯЩИЙ БЛОК ДАННЫХ:
           R1, потом токен 0xFE, потом 16 байт, потом два байта CRC16. Проверено в esxdos.asm:
           L1D2F после команды зовёт L1DC4 (ждать байт 0xFE, десять подходов) и только затем
           `ld b,$12 : inir` - восемнадцать байт, то есть 16 полезных плюс CRC. Ответ без токена
           упрёт инициализацию в те самые десять подходов по 12800 опросов и вернёт «Disk error». */
        if(g_idle){ resp1(r1_base(), DMC_S_IDLE); return; }   /* до готовности карта их не отдаёт */
        memcpy(g_buf, (idx == 9) ? g_csd : g_cid, 16);
        g_multi = 0;
        resp1(0x00u, DMC_S_TOKEN);        /* дальше - блок ДЛИНОЙ 16 байт, а не 512 */
        return;

    case 12:    /* STOP_TRANSMISSION - в esxDOS её нет вовсе, держим ради UnoDOS и самописных */
        g_multi = 0; g_stop_after_block = 0;
        resp1(r1_base(), DMC_S_IDLE);
        return;

    case 13:    /* SEND_STATUS: R2 - два байта */
        resp5(r1_base(), 0x00000000u, DMC_S_IDLE);
        g_resp_n = 2;
        return;

    case 16:    /* SET_BLOCKLEN. При CCS=1 бессмысленна, и esxDOS её шлёт ТОЛЬКО при CCS=0
                   (L1C8B: `and %01000000 : call z,L1CF7`, а L1CF7 = CMD16 с аргументом 0x200). */
        resp1((uint8_t)(r1_base() | ((arg == DMC_SECSZ) ? 0x00u : 0x40u)), DMC_S_IDLE);
        return;

    case 17:    /* READ_SINGLE_BLOCK */
    case 18:    /* READ_MULTIPLE_BLOCK */
        if(g_idle){ resp1(r1_base(), DMC_S_IDLE); return; }
        if(arg >= g_cap){ resp1((uint8_t)(r1_base() | 0x40u), DMC_S_IDLE); return; }
        g_lba = arg;
        g_multi = (idx == 18);
        g_stop_after_block = 0;
        if(fetch_block(g_lba) != 0){
            /* Ошибка чтения носителя. Настоящая карта отдаёт R1=0 и токен ошибки; мы отвечаем
               признаком «параметр» в R1 - его esxDOS увидит сразу (L1D6C требует ровно ноль). */
            resp1((uint8_t)(r1_base() | 0x40u), DMC_S_IDLE);
            return;
        }
        g_st.blocks_rd++;
        resp1(0x00u, DMC_S_NAC);
        return;

    case 24:    /* WRITE_BLOCK */
    case 25:    /* WRITE_MULTIPLE_BLOCK */
        if(g_idle){ resp1(r1_base(), DMC_S_IDLE); return; }
        if(arg >= g_cap){ resp1((uint8_t)(r1_base() | 0x40u), DMC_S_IDLE); return; }
        g_lba = arg;
        g_multi = (idx == 25);
        resp1(0x00u, DMC_S_RXWAIT);
        return;

    case 58: {  /* READ_OCR: ответ R3 = R1 и четыре байта регистра условий питания.
                   Бит 31 - «включение завершено», бит 30 - CCS («карта большой ёмкости»). Именно
                   бит 30 esxDOS кладёт себе во флаги (L1C8B: `and %01000000 : or %00000011`) и по
                   нему потом решает, считать ли объём по формуле CSD 2.0 и слать ли CMD16.
                   🥇 Побочный факт, проверенный по коду: четыре байта OCR esxDOS читает той же
                   подпрограммой «ждать не-0xFF» (L1D81 -> L1DD2), поэтому байт 0xFF ВНУТРИ OCR она
                   пропускает. У нас это второй байт (окно напряжений 0xFF8000, как у всех карт),
                   и на итог это не влияет - используется только первый байт, - но один опрос
                   уходит вхолостую. Менять окно напряжений ради этого не стали: врать в OCR
                   дороже, чем потерять сотую долю секунды один раз за монтирование. */
        uint32_t ocr = 0x00FF8000u | (g_idle ? 0u : 0x80000000u) | 0x40000000u;
        resp5(r1_base(), ocr, DMC_S_IDLE);
        return;
    }

    case 59:    /* CRC_ON_OFF - вежливо соглашаемся */
        resp1(r1_base(), DMC_S_IDLE);
        return;

    default:
        /* 🥇 Неизвестная команда обязана быть ВИДНА. Ответ - «недопустимая команда» (бит 2), а
           номер уезжает в отладочное слово: без этого прибора отладка сводится к гаданию, кто
           именно из драйверов чего попросил. */
        g_st.cmd_unknown++;
        g_dbg_last_unknown = idx;
        if(g_dbg_cnt_unknown < 7) g_dbg_cnt_unknown++;
        resp1((uint8_t)(r1_base() | 0x04u), DMC_S_IDLE);
        return;
    }
}

/* Приём байта в кадр команды. Возвращает 1, если байт «съеден» кадром. */
static int rx_cmd_byte(uint8_t b)
{
    if(g_cmd_n == 0){
        /* 🥇 КАДРИРОВАНИЕ ИДЁТ ПО СТАРТОВОМУ БИТУ, А НЕ ПО ФРОНТУ ВЫБОРА КАРТЫ. esxDOS не снимает
           #E7 между командами: L1DE0 перед каждой командой лишь ЗАПИСЫВАЕТ туда тот же самый код
           выбора, а снимается выбор только на ошибках и в конце операции (L1D5E). Значит автомат,
           который ищет начало команды по фронту CS, увидит первую команду и потеряет все
           следующие. Ищем два старших бита 01. */
        if((b & 0xC0u) != 0x40u){
            if(b != 0xFFu){ g_st.stray++; if(g_dbg_cnt_stray < 7) g_dbg_cnt_stray++; }
            return 0;
        }
        g_cmd[0] = b; g_cmd_n = 1;
        g_crc7 = crc7_byte(0, b);
        g_state = DMC_S_ARG;
        return 1;
    }
    g_cmd[g_cmd_n++] = b;
    if(g_cmd_n < 6){ g_crc7 = crc7_byte(g_crc7, b); return 1; }
    g_cmd_n = 0;
    exec_cmd();
    return 1;
}

/* Отдельный приёмник команд, работающий ПАРАЛЛЕЛЬНО передаче данных. Нужен ровно для одного:
   мультиблочное чтение останавливают командой CMD12, которую хост посылает ПОСРЕДИ потока -
   паузы между блоками у карты нет. Ложных срабатываний тут быть не может: пока карта отдаёт
   данные, хост обязан держать на линии 0xFF.
   🥇 И наоборот: в состояниях ПРИЁМА данных (CMD24/CMD25) этот сниффер обязан молчать, иначе
   байт полезной нагрузки со старшими битами 01 - а это каждый четвёртый байт - будет принят за
   команду и кадрирование рассыплется. Разделение по направлению линии - и есть правило. */
static void sniff_cmd12(uint8_t b)
{
    if(g_cmd_n == 0){
        if((b & 0xC0u) != 0x40u) return;
        g_cmd[0] = b; g_cmd_n = 1; g_crc7 = crc7_byte(0, b);
        return;
    }
    g_cmd[g_cmd_n++] = b;
    if(g_cmd_n < 6){ g_crc7 = crc7_byte(g_crc7, b); return; }
    g_cmd_n = 0;
    if((g_cmd[0] & 0x3Fu) == 12u){
        g_stop_after_block = 1;
        g_st.cmd12_inflight++;
    } else {
        /* Команда не CMD12 посреди потока - это уже подозрение на рассинхрон. Метим липким битом. */
        g_sticky_frame = 1;
    }
}

/* ============================================================================================ */
/* Один обмен байтом                                                                            */
/* ============================================================================================ */

uint8_t divmmc_card_xfer(uint8_t mosi)
{
    uint8_t miso = 0xFFu;
    int sniff_on, stop_now;

    if(!g_attached) return 0xFFu;        /* слота нет - линия подтянута, драйвер увидит «нет карты» */

    if(!g_cs){
        g_st.bytes_idle_cs++;
        /* 🥇 Настоящая карта требует не меньше 74 тактов при снятом CS перед первой CMD0, и
           esxDOS их даёт: L1D40 шлёт десять байт 0xFF после L1D5E. Считаем их - это дешёвая
           проверка того, что чужой драйвер соблюдает включение питания. */
        if(!g_seen_cmd0) g_st.pre_cmd0_clocks++;
        return 0xFFu;
    }

    g_st.bytes++;

    /* Сниффер кадра CMD12 работает ПОСЛЕ шага автомата и по СТАРЫМ state/multi - ровно так он
       стоит в RTL (за `case`, на старых значениях регистров). Если звать его раньше, стоп
       срабатывает на байт раньше железа, и модель перестаёт быть спецификацией. */
    sniff_on = g_multi && (g_state == DMC_S_NAC   || g_state == DMC_S_TOKEN ||
                           g_state == DMC_S_TX    || g_state == DMC_S_TXCRC ||
                           g_state == DMC_S_MBGAP);

    /* 🥇 ЕДИНСТВЕННАЯ ТОЧКА ИСПОЛНЕНИЯ CMD12, ПОЙМАННОЙ В ПОТОКЕ ЧТЕНИЯ.
       Их было две, и вели они себя по-разному: из S_TXCRC карта досылала R1 и занятость, а из
       S_MBGAP (пауза между блоками) уходила в IDLE МОЛЧА. Драйвер, который ждёт R1b на стоп-команду
       (Z-Player 4.1, NedoOS, u-boot mmc_spi), опрашивал порт вечно - это и есть вис, снятый с платы
       19.08 (state=IDLE, last_cmd=18, card_busy=0, нулевая дельта счётчиков за 4 с). И пауза - не
       узкое окно: она длится столько, сколько думает оболочка, а канонический драйвер шлёт CMD12
       РОВНО на границе блока, вычитав и оба байта CRC (elm-chan, u-boot drivers/mmc/mmc.c:425).
       Спека: SD Physical Layer 6.00, Figure 7-5 (после стоп-команды идёт response) и §7.2.8 «in
       the SPI mode, the card will always respond to a command».
       Заодно стоп больше не ждёт конца текущего блока: раньше R1 приходил через остаток блока плюс
       два байта CRC (до 515 байт), а если CMD12 попадала в S_NAC - после ЦЕЛОГО ненужного блока, и
       драйвер, ищущий первый байт с нулевым старшим битом, законно принимал за R1 байт ДАННЫХ. */
    stop_now = sniff_on && g_stop_after_block;

    /* ⚠ ОСТАНОВКА МЕНЯЕТ ПЕРЕХОД, А НЕ БАЙТ ЭТОГО ОБМЕНА. В ПЛИС байт, который машина получает
       сейчас, был загружен в конвейер на ПРЕДЫДУЩЕМ байте (`nxt_byte`), поэтому он принадлежит ещё
       потоку и уедет независимо от нашего решения. Если модель ответит на байт раньше железа,
       расхождение поймает DPI-стенд `sources/tb_divmmc_card.sv` (у меня и поймал: RTL отдавал
       байт данных 0x23 там, где модель уже отдала 0xFF).
       Исключение - S_NAC и S_MBGAP: там карта и так гонит 0xFF, и тело состояния можно не
       исполнять вовсе. Это ещё и правильнее: незачем тащить у оболочки блок, который уже никому не
       нужен (в RTL общая точка остановки стоит ПЕРЕД разбором состояний и тела тоже не исполняет). */
    if(!(stop_now && (g_state == DMC_S_NAC || g_state == DMC_S_MBGAP)))
    switch(g_state){

    case DMC_S_IDLE:
    case DMC_S_ARG:
        rx_cmd_byte(mosi);
        break;

    case DMC_S_NCR:
        if(--g_wait <= 0) g_state = DMC_S_RESP;
        break;

    case DMC_S_RESP:
        miso = g_resp[g_resp_i++];
        if(g_resp_i >= g_resp_n){
            if(g_after_resp == DMC_S_BUSY) g_wait = g_write_busy > 0 ? g_write_busy : 1;
            if(g_after_resp == DMC_S_NAC)         start_tx_block();
            else if(g_after_resp == DMC_S_TOKEN){ /* короткий блок CSD/CID, без паузы N_AC */
                g_dat_i = 0; g_dat_len = 16u; g_crc16 = 0; g_crc16_i = 0;
                g_state = DMC_S_TOKEN;
            }
            else                                   g_state = g_after_resp;
            if(g_state == DMC_S_IDLE) g_cmd_n = 0;
        }
        break;

    case DMC_S_NAC:
        if(--g_wait <= 0) g_state = DMC_S_TOKEN;
        break;

    case DMC_S_TOKEN:
        miso = DMC_TOK_SINGLE;
        g_crc16 = 0;
        g_state = DMC_S_TX;
        break;

    case DMC_S_TX:
        miso = g_buf[g_dat_i];
        g_crc16 = crc16_byte(g_crc16, miso);
        if(++g_dat_i >= g_dat_len){
            g_crc16_out[0] = (uint8_t)(g_crc16 >> 8);
            g_crc16_out[1] = (uint8_t)g_crc16;
            g_crc16_i = 0;
            g_state = DMC_S_TXCRC;
        }
        break;

    case DMC_S_TXCRC:
        miso = g_crc16_out[g_crc16_i++];
        if(g_crc16_i >= 2){
            if(g_multi){
                /* `g_stop_after_block` здесь всегда 0: пойманную CMD12 исполняет общая точка ПЕРЕД
                   разбором состояний. Остаётся один случай - кадр, закончившийся РОВНО на этом
                   байте: пауза начнётся, стоп сработает следующим байтом, и блок, который оболочка
                   уже готовит, окажется никому не нужен (в ПЛИС это и есть наблюдаемый
                   DMMC_LBA = аргумент CMD18 + 1). */
                g_wait = 1 + g_shell_lat;
                g_state = DMC_S_MBGAP;
            } else {
                g_multi = 0; g_stop_after_block = 0;
                g_cmd_n = 0;
                g_state = DMC_S_IDLE;
            }
        }
        break;

    case DMC_S_MBGAP:
        if(--g_wait <= 0){
            /* Ветки g_stop_after_block здесь больше нет: остановку исполняет общая точка выше, и
               делает она это НА СЛЕДУЮЩЕМ ЖЕ байте после кадра, не дожидаясь блока. */
            if(fetch_block(++g_lba) != 0){
                g_multi = 0; g_cmd_n = 0; g_state = DMC_S_IDLE;   /* конец носителя - поток обрывается */
            } else {
                g_st.blocks_rd++;
                g_dat_i = 0; g_dat_len = DMC_SECSZ; g_crc16 = 0;
                g_state = DMC_S_TOKEN;
            }
        }
        break;

    case DMC_S_RXWAIT:
        /* Ждём токен ОТ ХОСТА. Всё, что до него, - заполнитель. */
        if(mosi == DMC_TOK_SINGLE || mosi == DMC_TOK_MULTI){
            g_dat_i = 0; g_crc16 = 0;
            g_state = DMC_S_RX;
        } else if(mosi == DMC_TOK_STOP){
            g_multi = 0;
            g_wait = g_write_busy;
            g_state = DMC_S_BUSY;
        }
        break;

    case DMC_S_RX:
        g_buf[g_dat_i] = mosi;
        g_crc16 = crc16_byte(g_crc16, mosi);
        if(++g_dat_i >= DMC_SECSZ){ g_crc16_i = 0; g_state = DMC_S_RXCRC; }
        break;

    case DMC_S_RXCRC:
        /* Принятый CRC складываем, но решение по нему не принимаем: обе половины связки его не
           считают (esxDOS шлёт два 0xFF - L1DEA), а рвать запись из-за этого нельзя. */
        if(++g_crc16_i >= 2){
            int ok;
            g_st.blocks_wr++;
            ok = (g_wr && g_wr(g_lba, g_buf) == 0);
            if(!ok){ g_st.wr_err++; g_sticky_wr = 1; }
            g_resp[0] = (uint8_t)(0xE0u | (ok ? DMC_DR_ACCEPT : DMC_DR_WRERR));
            g_resp_n = 1; g_resp_i = 0;
            g_state = DMC_S_RXRESP;
        }
        break;

    case DMC_S_RXRESP:
        miso = g_resp[0];
        g_wait = g_write_busy;
        g_state = (g_write_busy > 0) ? DMC_S_BUSY : (g_multi ? DMC_S_RXWAIT : DMC_S_IDLE);
        if(g_state == DMC_S_IDLE) g_cmd_n = 0;
        if(g_multi && g_state != DMC_S_BUSY) g_lba++;
        break;

    case DMC_S_BUSY:
        miso = 0x00u;                     /* карта занята: держит линию в нуле */
        if(g_wait == 1 && g_fast_ack) miso = 0x01u;   /* B0150: FAST - последний байт занятости 0x01 */
        if(--g_wait <= 0){
            if(g_multi){ g_lba++; g_state = DMC_S_RXWAIT; }
            else { g_cmd_n = 0; g_state = DMC_S_IDLE; }
        }
        break;

    default:
        g_state = DMC_S_IDLE;
        break;
    }

    if(stop_now){
        g_multi = 0; g_stop_after_block = 0; g_cmd_n = 0;
        resp1(r1_base(), DMC_S_BUSY);      /* R1 уедет через N_CR, дальше байты занятости */
    }

    /* Сниффер кадра CMD12 стоит ЗА автоматом - как в RTL, где он написан после `case` и потому
       видит старые значения state/multi. Следствие важно: стоп срабатывает НА СЛЕДУЮЩЕМ байте
       после кадра, а не на самом кадре, и модель совпадает с железом байт в байт. */
    if(sniff_on) sniff_cmd12(mosi);

    return miso;
}

/* ============================================================================================ */
/* Отладочное слово - то же, что уедет в регистр диагностики                                     */
/* ============================================================================================ */
/*  [5:0]   номер последней команды
    [11:6]  номер последней НЕИЗВЕСТНОЙ команды
    [15:12] состояние автомата
    [18:16] счётчик неизвестных команд (насыщается на 7)
    [21:19] счётчик чужих байтов в кадре команд
    [24:22] счётчик несовпадений CRC7
    [25]    был CMD0 (карта в режиме SPI)
    [26]    карта в idle
    [27]    CCS (у нас всегда 1 - карта большой ёмкости)
    [28]    выбор карты активен
    [29]    липкий: отказ бэкенда на чтении
    [30]    липкий: отказ бэкенда на записи
    [31]    липкий: посреди потока данных пришла команда, не равная CMD12                        */
uint32_t divmmc_card_dbg(void)
{
    return  ((uint32_t)(g_dbg_last_cmd & 0x3Fu))
         | ((uint32_t)(g_dbg_last_unknown & 0x3Fu) << 6)
         | ((uint32_t)(g_state & 0x0Fu) << 12)
         | ((uint32_t)(g_dbg_cnt_unknown & 7u) << 16)
         | ((uint32_t)(g_dbg_cnt_stray & 7u) << 19)
         | ((uint32_t)(g_dbg_cnt_crc7 & 7u) << 22)
         | ((uint32_t)(g_spi_mode ? 1u : 0u) << 25)
         | ((uint32_t)(g_idle ? 1u : 0u) << 26)
         | ((uint32_t)1u << 27)
         | ((uint32_t)(g_cs ? 1u : 0u) << 28)
         | ((uint32_t)(g_sticky_rd ? 1u : 0u) << 29)
         | ((uint32_t)(g_sticky_wr ? 1u : 0u) << 30)
         | ((uint32_t)(g_sticky_frame ? 1u : 0u) << 31);
}
