/* divmmc_fs.c - том FAT16, синтезированный из папки на карте (проброс папки в DivMMC).
 *
 * Читать вместе с divmmc_fs.h. Здесь только «файловая» половина: папка -> сектора. Сторона
 * фабрики (SPI-автомат карты, divmmc_card.c) дёргает ровно две функции: divmmc_fs_read() на
 * CMD17/18 и divmmc_fs_write() на CMD24/25.
 *
 * Устройство тома (всё, кроме содержимого файлов, вычисляется на лету, ничего не хранится):
 *
 *   LBA 0                 MBR: один раздел типа 0x06 (FAT16), начало g_i.part_lba
 *   ...                   пропуск до начала раздела (нули)
 *   part_lba              загрузочный сектор с BPB
 *   fat_lba               таблица размещения, копия 1
 *   fat_lba + fat_sectors таблица размещения, копия 2 (побайтно равна первой)
 *   root_lba              корневой каталог, DMFS_ROOTENT записей (фиксированная область)
 *   data_lba              данные: кластер 2 и далее
 *
 * ПОЧЕМУ ТАК ДЁШЕВО ЧИТАЕТСЯ. Кластеры при сборке раздаём сами и подряд: файл получает пробег.
 * Значит «сектор -> кусок файла» = двоичный поиск пробега плюс вычитание, а таблица размещения
 * генерируется из тех же пробегов, а не хранится.
 *
 * ============================== ЗАПИСЬ ==============================
 *
 * Чужой драйвер FAT (esxDOS, mtools, что угодно) видит обычный том и работает с ним как с
 * носителем: сам ищет свободные кластеры, сам строит цепочки, сам кладёт записи каталога. Наша
 * задача - НЕ хранить эти сектора, а ПОНЯТЬ их и повторить смысл на настоящей папке.
 *
 * Что с чем сопоставляется:
 *   таблица размещения -> цепочка кластеров узла (пробеги g_ext);
 *   запись каталога    -> имя, размер, первый кластер, флаг папки, живая/удалённая;
 *   сектор данных      -> смещение внутри файла (по пробегу, которому кластер принадлежит).
 *
 * 🥇 ПОРЯДОК СЕКТОРОВ НЕ ГАРАНТИРОВАН, поэтому сборка отложенная. Наблюдение (стенд на mtools и
 * трасса настоящей esxDOS) показывает обычный порядок «таблица -> каталог -> данные», но
 * закладываться на него нельзя. Правило, которое закрывает оба конца:
 *
 *   1. Файл МАТЕРИАЛИЗУЕТСЯ (создаётся на карте) в тот момент, когда стали известны имя, первый
 *      кластер и размер, то есть по приходу записи каталога. Данных к этому моменту может ещё
 *      не быть - файл создаётся нужной длины, дырки заполнены нулями.
 *   2. КАЖДЫЙ последующий сектор данных, попавший в кластер этого файла, дописывается в него
 *      по вычисленному смещению. То есть «данные после имени» - обычная дозапись.
 *   3. Данные, пришедшие РАНЬШЕ имени, некуда положить: владельца кластера ещё нет. Их
 *      складываем в буфер отложенных данных (файл DMWRSPL.TMP в той же папке, невидимый для
 *      тома) и при материализации вынимаем оттуда. То есть «данные до имени» - тоже дозапись,
 *      только источник другой.
 *
 * Именно из-за пункта 3 нельзя было ограничиться «пишем сразу»: получился бы файл правильной
 * длины с мусором внутри, и заметить это можно было бы только сверкой байт-в-байт.
 *
 * 🥇 РАСКЛАДКА КАТАЛОГА СТАНОВИТСЯ ЖЁСТКОЙ. До записи каталог рисовался по дереву в алфавитном
 * порядке, и номер слота записи ни на что не влиял. Как только чужой драйвер положил свою запись
 * в слот 42, номер слота стал ЧАСТЬЮ ДОГОВОРА: пересортируй мы каталог - и всё, что драйвер уже
 * прочитал, уехало бы. Поэтому у каждого узла есть постоянный номер слота (поле ent), удалённый
 * узел остаётся НАДГРОБИЕМ (первый байт записи 0xE5), а не исчезает, и слоты никогда не
 * сдвигаются. Ноль в первом байте записи означает «каталог кончился», поэтому дырки внутри
 * каталога рисуются именно 0xE5, а не нулём.
 *
 * ЧТО ОТВЕРГАЕТСЯ. Запись в таблицу разделов, в загрузочный сектор и в зазор перед разделом -
 * это переразметка: тома как носителя не существует, есть папка, и форматировать её нельзя.
 * Первая же такая попытка ЗАПИРАЕТ том до перемонтирования (divmmc_fs_build) - потому что
 * mformat после загрузочного сектора продолжает затирать таблицу, корень и данные, и принимать
 * от него что-либо дальше означало бы своими руками стереть папку. Пока том заперт, причина
 * отказа называется по области, как и раньше.
 *
 * Сборка на хосте (плата не нужна):
 *   gcc -O2 -DDIVMMC_FS_HOST -o dmfs divmmc_fs_host_test.c divmmc_fs.c && ./dmfs
 */

#include <string.h>
#include <stdint.h>

#include "divmmc_fs.h"

#ifdef DIVMMC_FS_HOST
  #include <stdio.h>
  #include <stdlib.h>
  #include <dirent.h>
  #include <sys/stat.h>
  #include <unistd.h>
  #include <time.h>
#else
  #include "ff.h"
#endif

/* Имя буфера отложенных данных. Лежит в проброшенной папке (писать больше некуда - другой
   каталог нам не обещан), но в томе не показывается: сканер пропускает его по имени. */
#define DMFS_SPOOLNAME "DMWRSPL.TMP"

/* ------------------------------------------------------------------------------------------- */
/* Узел дерева. Имя длинное (как на карте) лежит в общем пуле, в узле только смещение - иначе на  */
/* тысячу узлов ушло бы 256 КБ статики на одни имена.                                            */
/* ------------------------------------------------------------------------------------------- */
enum {
    DMFS_NF_DEAD  = 1,   /* надгробие: запись каталога помечена удалённой, файла на карте нет */
    DMFS_NF_MAT   = 2,   /* узел материализован - на карте есть настоящий файл или папка */
    DMFS_NF_GREW  = 4    /* в файл писали за объявленный размер: усечь, когда размер уточнят */
};

typedef struct {
    uint16_t name_off;      /* смещение имени в g_pool */
    uint8_t  name_len;
    uint8_t  isdir;
    uint32_t size;          /* размер файла (у папки 0) */
    int16_t  ext;           /* первый пробег кластеров, -1 = кластеров нет */
    uint32_t nclus;         /* всего кластеров у узла. FAT32-ready: 32-битные номера кластеров */
    int16_t  parent;        /* -1 у корня */
    int16_t  child;         /* первый ребёнок (список по возрастанию слота) */
    int16_t  sib;           /* следующий брат */
    uint16_t nent;          /* ПАПКА: сколько 32-байтных слотов занято (высшая отметка) */
    uint16_t ent;           /* слот записи 8.3 в каталоге отца */
    uint8_t  nlfn;          /* сколько записей длинного имени идёт перед ней */
    uint8_t  ntcase;        /* флаги регистра 8.3 (0x08 имя, 0x10 расширение) */
    uint8_t  attr;          /* байт атрибутов записи каталога */
    uint8_t  flags;         /* DMFS_NF_* */
    uint8_t  sfn[11];       /* имя 8.3 без точки, ровно как в записи каталога */
    uint16_t fdate, ftime;  /* метка времени файла, как её отдаёт носитель */
} dmfs_node_t;

/* Пробег кластеров: n подряд идущих кластеров, начиная с clus, покрывающих кластеры файла с
   порядковым номером first по first+n-1. Соседние пробеги одного узла сливаются, поэтому у
   нефрагментированного файла пробег ровно один - как и было до появления записи. */
typedef struct {
    uint32_t clus;          /* FAT32-ready: 32-битные номера кластеров */
    uint32_t n;
    uint32_t first;
    int16_t  node;
    int16_t  next;          /* следующий пробег ТОГО ЖЕ узла (и цепочка свободных) */
} dmfs_ext_t;

/* ------------------------- формат тома: FAT16 или FAT32 ------------------------------------
   Разница сведена к четырём величинам и трём макросам - отдельного модуля для FAT32 не заводим:
   у нас всё и так выражено пробегами кластеров, а различается только их запись на носителе. */
static uint8_t  g_f32;                         /* 0 = FAT16 (умолчание), 1 = FAT32 */
static uint32_t g_spc     = DMFS_SPC;          /* секторов в кластере, всегда степень двойки */
static uint8_t  g_spc_sh  = DMFS_SPC_SH;       /* log2(g_spc): у Cortex-A9 деления НЕТ, а
                                                  «сектор -> кластер» стоит в горячем пути */
static uint32_t g_rsvd    = 1;                 /* зарезервированных секторов: 1 у FAT16, 32 у FAT32 */

#define FAT_EOC      (g_f32 ? 0x0FFFFFFFu : 0x0000FFFFu)
#define FAT_ISEOC(v) ((uint32_t)(v) >= (g_f32 ? 0x0FFFFFF8u : 0x0000FFF8u))
#define FAT_ENTPS    (g_f32 ? (DMFS_SECSZ/4u) : (DMFS_SECSZ/2u))   /* ячеек в секторе таблицы */

static uint32_t g_rootent = DMFS_ROOTENT;      /* v355: см. шапку divmmc_fs.h */
void divmmc_fs_set_format(int fat32){
    g_f32    = fat32 ? 1 : 0;
    g_spc    = g_f32 ? DMFS_SPC32 : DMFS_SPC;
    g_spc_sh = g_f32 ? DMFS_SPC32_SH : DMFS_SPC_SH;
    g_rsvd   = g_f32 ? 32u : 1u;
}
void divmmc_fs_set_rootent(unsigned n){ g_rootent = (n == DMFS_ROOTENT_LFN) ? DMFS_ROOTENT_LFN
                                                                            : DMFS_ROOTENT_ESX; }

static dmfs_node_t g_nodes[DMFS_MAXNODES];
static int         g_nnodes;
static char        g_pool[DMFS_NAMEPOOL];
static uint32_t    g_pool_n;
static dmfs_ext_t  g_ext[DMFS_MAXEXT];
static int16_t     g_esort[DMFS_MAXEXT];    /* индексы пробегов по возрастанию clus */
static int         g_next, g_nesort;
static int16_t     g_efree = -1;
static int         g_ready;
static dmfs_info_t g_i;
static dmfs_wstat_t g_w;
static int         g_lock;                  /* том заперт после попытки форматирования */
static char        g_root[DMFS_MAXPATH];
static char        g_path[DMFS_MAXPATH];    /* рабочий путь при обходе и при чтении файла */
static char        g_wpath[DMFS_MAXPATH];   /* путь для записи (нельзя мешать с g_path) */
static char        g_wpath2[DMFS_MAXPATH];
static const char* g_msg = "";

/* Отложенные значения таблицы размещения: то, что драйвер написал, а мы ещё не смогли выразить
   пробегами (цепочка строится до записи каталога). Держим по возрастанию кластера. */
static struct { uint32_t clus, val; } g_fatd[DMFS_MAXFATD];
static int g_nfatd;

/* Буфер отложенных данных: индекс в ОЗУ, сами байты - в файле DMWRSPL.TMP. Смещение сектора в
   файле равно номеру слота * 512, поэтому хранить нужно только LBA. */
static uint32_t g_spool[DMFS_SPOOLSEC];
static uint32_t g_spool_n;                  /* высшая отметка занятых слотов */
static uint32_t g_spool_live;

/* Записи длинного имени приходят ПЕРЕД записью 8.3 и могут оказаться в предыдущем секторе,
   поэтому их приходится придерживать между вызовами. Кольцо на 32 записи - больше одного
   длинного имени (максимум 20 записей) сюда и не нужно. */
#define DMFS_LSTASH 32
static struct { int16_t dir; uint16_t slot; uint8_t e[32]; } g_lstash[DMFS_LSTASH];
static int g_lstash_w;

/* Приговорённые узлы (см. condemn_node ниже): запись каталога уже погашена, но файл на карте
   ещё цел - вдруг это переименование. Объявлены здесь, потому что чтение тоже их «досуживает». */
static struct { int16_t node; uint16_t clus; uint32_t size; uint32_t seq; } g_cond[DMFS_CONDEMNED];
static int      g_ncond;
static uint32_t g_wcall;
static void cond_settle(uint32_t keep_seq);

/* Разбор сектора каталога умеет вызвать сам себя (создали папку -> в неё сразу лёг придержанный
   сектор с её содержимым), поэтому сгенерированный для сверки сектор живёт на стеке, а не в
   статике: общий буфер второй заход затёр бы, и первый доразбирал бы уже чужие записи. */

/* ------------------------------------------------------------------------------------------- */
/* Бэкенд носителя: на плате FatFs, на хосте обычный POSIX. Различие - обход каталога, чтение и  */
/* запись куска файла, плюс четыре операции над именами.                                         */
/* ------------------------------------------------------------------------------------------- */
#define DMFS_FCACHE 3

#ifdef DIVMMC_FS_HOST

typedef struct { DIR* d; } dmfs_dh_t;

static int bk_opendir(const char* p, dmfs_dh_t* h){ h->d = opendir(p); return h->d ? 0 : -1; }
static void bk_closedir(dmfs_dh_t* h){ if(h->d) closedir(h->d); h->d = 0; }

static void bk_stamp(time_t t, uint16_t* fdate, uint16_t* ftime)
{
    struct tm tmv; localtime_r(&t, &tmv);
    int y = tmv.tm_year + 1900; if(y < 1980) y = 1980;
    *fdate = (uint16_t)(((y - 1980) << 9) | ((tmv.tm_mon + 1) << 5) | tmv.tm_mday);
    *ftime = (uint16_t)((tmv.tm_hour << 11) | (tmv.tm_min << 5) | (tmv.tm_sec / 2));
}

static int bk_readdir(dmfs_dh_t* h, const char* dirpath, char* name, int nmax,
                      uint32_t* size, int* isdir, uint16_t* fdate, uint16_t* ftime)
{
    struct dirent* de;
    while((de = readdir(h->d)) != 0){
        char full[DMFS_MAXPATH * 2];
        struct stat st;
        if(de->d_name[0] == '.') continue;                 /* «.», «..» и точка-файлы не пробрасываем */
        if((int)strlen(de->d_name) >= nmax) continue;
        snprintf(full, sizeof(full), "%s/%s", dirpath, de->d_name);
        if(stat(full, &st) != 0) continue;
        if(!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) continue;
        strcpy(name, de->d_name);
        *isdir = S_ISDIR(st.st_mode) ? 1 : 0;
        *size  = *isdir ? 0 : (uint32_t)st.st_size;
        bk_stamp(st.st_mtime, fdate, ftime);
        return 1;
    }
    return 0;
}

typedef FILE* dmfs_fh_t;
static int  fh_open(dmfs_fh_t* f, const char* p, int wr)
{
    *f = wr ? fopen(p, "r+b") : fopen(p, "rb");
    if(!*f && wr) *f = fopen(p, "w+b");
    return *f ? 0 : -1;
}
static void fh_close(dmfs_fh_t* f){ if(*f) fclose(*f); *f = 0; }
static uint32_t fh_size(dmfs_fh_t* f){ long c = ftell(*f), n; fseek(*f, 0, SEEK_END); n = ftell(*f); fseek(*f, c, SEEK_SET); return (uint32_t)n; }
static int  fh_seek(dmfs_fh_t* f, uint32_t off){ return fseek(*f, (long)off, SEEK_SET) == 0 ? 0 : -1; }
static int  fh_read(dmfs_fh_t* f, uint8_t* b, uint32_t n){ return (int)fread(b, 1, n, *f); }
static int  fh_write(dmfs_fh_t* f, const uint8_t* b, uint32_t n){ int r = (int)fwrite(b, 1, n, *f); fflush(*f); return r; }
static int  fh_trunc(dmfs_fh_t* f, uint32_t sz){ fflush(*f); return ftruncate(fileno(*f), (off_t)sz) == 0 ? 0 : -1; }
static int  fh_sync(dmfs_fh_t* f){ return fflush(*f) == 0 ? 0 : -1; }

static int bk_mkdir(const char* p){ return mkdir(p, 0755) == 0 ? 0 : -1; }
static int bk_unlink(const char* p)
{
    struct stat st;
    if(stat(p, &st) != 0) return -1;
    return (S_ISDIR(st.st_mode) ? rmdir(p) : unlink(p)) == 0 ? 0 : -1;
}
static int bk_rename(const char* a, const char* b){ return rename(a, b) == 0 ? 0 : -1; }
static int bk_stat(const char* p, uint32_t* sz, int* isdir)
{
    struct stat st;
    if(stat(p, &st) != 0) return -1;
    if(sz) *sz = (uint32_t)st.st_size;
    if(isdir) *isdir = S_ISDIR(st.st_mode) ? 1 : 0;
    return 0;
}

#else   /* ---------------- плата: FatFs ---------------- */

typedef struct { DIR d; } dmfs_dh_t;
static FILINFO g_fi;    /* большой (длинное имя до 255) - держим статикой, не на стеке рекурсии */

static int bk_opendir(const char* p, dmfs_dh_t* h){ return (f_opendir(&h->d, p) == FR_OK) ? 0 : -1; }
static void bk_closedir(dmfs_dh_t* h){ f_closedir(&h->d); }

static int bk_readdir(dmfs_dh_t* h, const char* dirpath, char* name, int nmax,
                      uint32_t* size, int* isdir, uint16_t* fdate, uint16_t* ftime)
{
    (void)dirpath;
    for(;;){
        if(f_readdir(&h->d, &g_fi) != FR_OK || g_fi.fname[0] == 0) return 0;
        if(g_fi.fname[0] == '.') continue;
        if((int)strlen(g_fi.fname) >= nmax) continue;      /* имя длиннее нашего буфера - пропуск */
        strcpy(name, g_fi.fname);
        *isdir = (g_fi.fattrib & AM_DIR) ? 1 : 0;
        *size  = *isdir ? 0 : (uint32_t)g_fi.fsize;
        *fdate = g_fi.fdate; *ftime = g_fi.ftime;
        return 1;
    }
}

typedef FIL dmfs_fh_t;
static int  fh_open(dmfs_fh_t* f, const char* p, int wr)
{
    BYTE m = wr ? (FA_READ | FA_WRITE | FA_OPEN_ALWAYS) : FA_READ;
    return (f_open(f, p, m) == FR_OK) ? 0 : -1;
}
static void fh_close(dmfs_fh_t* f){ f_close(f); }
static uint32_t fh_size(dmfs_fh_t* f){ return (uint32_t)f_size(f); }
static int  fh_seek(dmfs_fh_t* f, uint32_t off){ return (f_lseek(f, (FSIZE_t)off) == FR_OK) ? 0 : -1; }
static int  fh_read(dmfs_fh_t* f, uint8_t* b, uint32_t n){ UINT br = 0; if(f_read(f, b, (UINT)n, &br) != FR_OK) return 0; return (int)br; }
static int  fh_write(dmfs_fh_t* f, const uint8_t* b, uint32_t n){ UINT bw = 0; if(f_write(f, b, (UINT)n, &bw) != FR_OK) return 0; return (int)bw; }
static int  fh_trunc(dmfs_fh_t* f, uint32_t sz){ if(f_lseek(f, (FSIZE_t)sz) != FR_OK) return -1; return (f_truncate(f) == FR_OK) ? 0 : -1; }
static int  fh_sync(dmfs_fh_t* f){ return (f_sync(f) == FR_OK) ? 0 : -1; }

static int bk_mkdir(const char* p){ return (f_mkdir(p) == FR_OK) ? 0 : -1; }
static int bk_unlink(const char* p){ return (f_unlink(p) == FR_OK) ? 0 : -1; }
static int bk_rename(const char* a, const char* b){ return (f_rename(a, b) == FR_OK) ? 0 : -1; }
static int bk_stat(const char* p, uint32_t* sz, int* isdir)
{
    if(f_stat(p, &g_fi) != FR_OK) return -1;
    if(sz) *sz = (uint32_t)g_fi.fsize;
    if(isdir) *isdir = (g_fi.fattrib & AM_DIR) ? 1 : 0;
    return 0;
}

#endif

/* Кэш открытых файлов: на карте открытие стоит дорого, а сектора приходят пачками по одному
   файлу. Ключ - путь, потому что узел о своём пути не знает (путь собирается из отцов). */
static struct { char path[DMFS_MAXPATH]; dmfs_fh_t f; int open; int wr; uint32_t age; } g_fc[DMFS_FCACHE];
static uint32_t g_fc_age;

static void fc_closeall(void)
{
    int i;
    for(i = 0; i < DMFS_FCACHE; i++){ if(g_fc[i].open) fh_close(&g_fc[i].f); g_fc[i].open = 0; g_fc[i].wr = 0; g_fc[i].path[0] = 0; }
}

/* Выкинуть из кэша путь (и всё, что под ним) - после удаления и переименования держать открытым
   старое имя нельзя: FatFs отдал бы байты уже несуществующего объекта. */
static void fc_drop(const char* path)
{
    int i; size_t pl = strlen(path);
    for(i = 0; i < DMFS_FCACHE; i++){
        if(!g_fc[i].open) continue;
        if(strncmp(g_fc[i].path, path, pl)) continue;
        if(g_fc[i].path[pl] != 0 && g_fc[i].path[pl] != '/') continue;
        fh_close(&g_fc[i].f); g_fc[i].open = 0; g_fc[i].wr = 0; g_fc[i].path[0] = 0;
    }
}

static int fc_get(const char* path, int wr)
{
    int i, slot = -1;
    for(i = 0; i < DMFS_FCACHE; i++) if(g_fc[i].open && !strcmp(g_fc[i].path, path)){ slot = i; break; }
    if(slot >= 0){
        if(!wr || g_fc[slot].wr){ g_fc[slot].age = ++g_fc_age; return slot; }
        fh_close(&g_fc[slot].f); g_fc[slot].open = 0;          /* был открыт только на чтение */
    } else {
        slot = 0;
        for(i = 1; i < DMFS_FCACHE; i++) if(!g_fc[i].open || g_fc[i].age < g_fc[slot].age) slot = i;
        if(g_fc[slot].open) fh_close(&g_fc[slot].f);
        g_fc[slot].open = 0;
    }
    if(fh_open(&g_fc[slot].f, path, wr) != 0){ g_fc[slot].path[0] = 0; return -1; }
    g_fc[slot].open = 1; g_fc[slot].wr = wr ? 1 : 0;
    {   /* strncpy тут только соблазн: он не кладёт ноль при точном совпадении длины */
        size_t pl = strlen(path); if(pl > DMFS_MAXPATH - 1) pl = DMFS_MAXPATH - 1;
        memcpy(g_fc[slot].path, path, pl); g_fc[slot].path[pl] = 0;
    }
    g_fc[slot].age = ++g_fc_age;
    return slot;
}

static int bk_read(const char* path, uint32_t off, uint8_t* buf, uint32_t n)
{
    int slot = fc_get(path, 0);
    if(slot < 0) return 0;
    /* Быстрого поиска (CREATE_LINKMAP) в нашем xilffs нет: FF_USE_FASTSEEK = 0. Зато f_lseek
       ВПЕРЁД идёт от текущего кластера, а сектора карта просит по возрастанию, так что обычный
       поток файла обходится дёшево. Если станет узким местом - включать FF_USE_FASTSEEK в BSP. */
    if(fh_seek(&g_fc[slot].f, off) != 0) return 0;
    return fh_read(&g_fc[slot].f, buf, n);
}

static int bk_write(const char* path, uint32_t off, const uint8_t* buf, uint32_t n)
{
    int slot = fc_get(path, 1);
    if(slot < 0) return -1;
    if(fh_seek(&g_fc[slot].f, off) != 0) return -1;
    if((uint32_t)fh_write(&g_fc[slot].f, buf, n) != n) return -1;
    return 0;
}

/* Довести файл ровно до размера size: короткий дорастить нулями, длинный усечь. */
static int bk_setsize(const char* path, uint32_t size)
{
    int slot = fc_get(path, 1);
    uint32_t cur;
    if(slot < 0) return -1;
    cur = fh_size(&g_fc[slot].f);
    if(cur == size) return 0;
    if(cur > size) return fh_trunc(&g_fc[slot].f, size);
    if(fh_seek(&g_fc[slot].f, cur) != 0) return -1;
    {
        static uint8_t z[DMFS_SECSZ];
        uint32_t left = size - cur;
        memset(z, 0, sizeof(z));
        while(left){
            uint32_t k = left > DMFS_SECSZ ? DMFS_SECSZ : left;
            if((uint32_t)fh_write(&g_fc[slot].f, z, k) != k) return -1;
            left -= k;
        }
    }
    return 0;
}

static int bk_sync(const char* path)
{
    int i;
    for(i = 0; i < DMFS_FCACHE; i++) if(g_fc[i].open && g_fc[i].wr && !strcmp(g_fc[i].path, path)) return fh_sync(&g_fc[i].f);
    return 0;
}

/* ------------------------------------------------------------------------------------------- */
/* Мелочи                                                                                        */
/* ------------------------------------------------------------------------------------------- */
static void put16(uint8_t* p, uint16_t v){ p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t* p, uint32_t v){ p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
                                           p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static uint16_t get16(const uint8_t* p){ return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t get32(const uint8_t* p){ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static char up(char c){ return (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c; }
static int  icmp(const char* a, const char* b)
{
    for(;; a++, b++){ char x = up(*a), y = up(*b); if(x != y) return (unsigned char)x - (unsigned char)y; if(!x) return 0; }
}
static const char* nm(const dmfs_node_t* n){ return g_pool + n->name_off; }
static uint32_t divup(uint32_t a, uint32_t b){ return (a + b - 1) / b; }

/* Собрать путь к узлу от корня проброшенной папки. Идём от узла вверх, потому что вниз ссылок
   на «полный путь» мы не храним - это было бы 512 * 256 байт статики ни за чем. */
static int node_path(int idx, char* out, int omax)
{
    int stack[DMFS_MAXDEPTH + 2], sp = 0, len;
    while(idx > 0 && sp < (int)(sizeof(stack)/sizeof(stack[0]))){ stack[sp++] = idx; idx = g_nodes[idx].parent; }
    len = (int)strlen(g_root);
    if(len >= omax) return -1;
    memcpy(out, g_root, (size_t)len);
    while(sp > 0){
        const char* s = nm(&g_nodes[stack[--sp]]);
        int sl = (int)strlen(s);
        if(len + 1 + sl >= omax) return -1;
        out[len++] = '/';
        memcpy(out + len, s, (size_t)sl); len += sl;
    }
    out[len] = 0;
    return len;
}

/* ------------------------------------------------------------------------------------------- */
/* Пробеги кластеров                                                                             */
/* ------------------------------------------------------------------------------------------- */
static int esort_find(uint32_t c)          /* -> индекс в g_esort или -1 */
{
    int lo = 0, hi = g_nesort - 1;
    while(lo <= hi){
        int mid = (lo + hi) / 2;
        const dmfs_ext_t* e = &g_ext[g_esort[mid]];
        if(c < e->clus) hi = mid - 1;
        else if(c >= (uint32_t)e->clus + e->n) lo = mid + 1;
        else return mid;
    }
    return -1;
}

static int ext_by_cluster(uint32_t c){ int k = esort_find(c); return k < 0 ? -1 : g_esort[k]; }

static void esort_ins(int ei)
{
    int lo = 0, hi = g_nesort;
    while(lo < hi){ int mid = (lo + hi) / 2; if(g_ext[g_esort[mid]].clus < g_ext[ei].clus) lo = mid + 1; else hi = mid; }
    memmove(&g_esort[lo + 1], &g_esort[lo], (size_t)(g_nesort - lo) * sizeof(g_esort[0]));
    g_esort[lo] = (int16_t)ei;
    g_nesort++;
}

static void esort_del(int ei)
{
    int k = esort_find(g_ext[ei].clus);
    if(k < 0 || g_esort[k] != ei) return;
    memmove(&g_esort[k], &g_esort[k + 1], (size_t)(g_nesort - k - 1) * sizeof(g_esort[0]));
    g_nesort--;
}

static int ext_alloc(void)
{
    int ei;
    if(g_efree >= 0){ ei = g_efree; g_efree = g_ext[ei].next; }
    else if(g_next < DMFS_MAXEXT) ei = g_next++;
    else return -1;
    memset(&g_ext[ei], 0, sizeof(g_ext[ei]));
    g_ext[ei].next = -1;
    return ei;
}

static void ext_release(int ei){ g_ext[ei].node = -1; g_ext[ei].next = g_efree; g_efree = (int16_t)ei; }

/* Присоединить кластер clus к узлу как порядковый ord. Кластер обязан быть ничей. */
static int ext_attach(int node, uint32_t clus, uint32_t ord)
{
    dmfs_node_t* n = &g_nodes[node];
    int ei = n->ext, last = -1, ne;
    while(ei >= 0){ last = ei; ei = g_ext[ei].next; }
    if(last >= 0){
        dmfs_ext_t* e = &g_ext[last];
        if((uint32_t)e->clus + e->n == clus && (uint32_t)e->first + e->n == ord){
            e->n++;                                 /* соседний кластер - просто растянули пробег */
            n->nclus++;
            return 0;
        }
    }
    ne = ext_alloc();
    if(ne < 0) return -1;
    g_ext[ne].clus = (uint16_t)clus; g_ext[ne].n = 1;
    g_ext[ne].first = (uint16_t)ord; g_ext[ne].node = (int16_t)node; g_ext[ne].next = -1;
    if(last >= 0) g_ext[last].next = (int16_t)ne; else n->ext = (int16_t)ne;
    n->nclus++;
    esort_ins(ne);
    return 0;
}

static void ext_free_all(int node)
{
    dmfs_node_t* n = &g_nodes[node];
    int ei = n->ext;
    while(ei >= 0){ int nx = g_ext[ei].next; esort_del(ei); ext_release(ei); ei = nx; }
    n->ext = -1; n->nclus = 0;
}

/* Отцепить один кластер. Освобождение цепочки идёт по возрастанию, то есть почти всегда снимаем
   голову пробега - это делается на месте и новых пробегов не требует. */
static int ext_detach(uint32_t clus)
{
    int ei = ext_by_cluster(clus), prev, node;
    dmfs_ext_t* e;
    if(ei < 0) return 0;
    e = &g_ext[ei];
    node = e->node;
    if(clus == e->clus){
        esort_del(ei);
        e->clus++; e->first++; e->n--;
        if(e->n) esort_ins(ei);
    } else if(clus == (uint32_t)e->clus + e->n - 1){
        e->n--;
    } else {
        int ne = ext_alloc();                       /* разрыв внутри пробега - нужен второй */
        if(ne < 0) return -1;
        g_ext[ne].clus  = (uint16_t)(clus + 1);
        g_ext[ne].n     = (uint16_t)((uint32_t)e->clus + e->n - clus - 1);
        g_ext[ne].first = (uint16_t)(e->first + (clus + 1 - e->clus));
        g_ext[ne].node  = (int16_t)node;
        g_ext[ne].next  = e->next;
        e->next = (int16_t)ne;
        e->n    = (uint16_t)(clus - e->clus);
        esort_ins(ne);
    }
    if(g_ext[ei].n == 0){                           /* пробег кончился - выкинуть из списка узла */
        int p = g_nodes[node].ext;
        if(p == ei) g_nodes[node].ext = g_ext[ei].next;
        else { prev = p; while(prev >= 0 && g_ext[prev].next != ei) prev = g_ext[prev].next;
               if(prev >= 0) g_ext[prev].next = g_ext[ei].next; }
        ext_release(ei);
    }
    if(g_nodes[node].nclus) g_nodes[node].nclus--;
    return 0;
}

/* Обрубить цепочку узла сразу после кластера clus. */
static void ext_truncate_after(int node, uint32_t clus)
{
    int ei = g_nodes[node].ext;
    while(ei >= 0){
        dmfs_ext_t* e = &g_ext[ei];
        if(clus >= e->clus && clus < (uint32_t)e->clus + e->n){
            uint32_t keep = clus - e->clus + 1;
            int nx = e->next;
            g_nodes[node].nclus = (uint16_t)(e->first + keep);
            e->n = (uint16_t)keep;
            e->next = -1;
            while(nx >= 0){ int q = g_ext[nx].next; esort_del(nx); ext_release(nx); nx = q; }
            return;
        }
        ei = e->next;
    }
}

/* Порядковый номер кластера в файле (или 0xFFFFFFFF, если кластер узлу не принадлежит). */
static uint32_t ext_ordinal(int ei, uint32_t clus){ return (uint32_t)g_ext[ei].first + (clus - g_ext[ei].clus); }

/* ------------------------------------------------------------------------------------------- */
/* Отложенные значения таблицы размещения                                                        */
/* ------------------------------------------------------------------------------------------- */
static uint32_t fat_value(uint32_t c);

static int fatd_find(uint32_t c)
{
    int lo = 0, hi = g_nfatd - 1;
    while(lo <= hi){ int mid = (lo + hi) / 2;
        if(c < g_fatd[mid].clus) hi = mid - 1; else if(c > g_fatd[mid].clus) lo = mid + 1; else return mid; }
    return -1;
}

static void fatd_del(uint32_t c)
{
    int k = fatd_find(c);
    if(k < 0) return;
    memmove(&g_fatd[k], &g_fatd[k + 1], (size_t)(g_nfatd - k - 1) * sizeof(g_fatd[0]));
    g_nfatd--;
}

/* Положить значение как есть, не сверяясь с пробегами. Нужно там, где пробеги вот-вот снимут:
   иначе «равно вычисленному» сработало бы ДО снятия и связь потерялась бы. */
static int fatd_put(uint32_t c, uint32_t v)
{
    int k = fatd_find(c), lo = 0, hi = g_nfatd;
    if(k >= 0){ g_fatd[k].val = v; return 0; }
    if(g_nfatd >= DMFS_MAXFATD) return -1;
    while(lo < hi){ int mid = (lo + hi) / 2; if(g_fatd[mid].clus < c) lo = mid + 1; else hi = mid; }
    memmove(&g_fatd[lo + 1], &g_fatd[lo], (size_t)(g_nfatd - lo) * sizeof(g_fatd[0]));
    g_fatd[lo].clus = c; g_fatd[lo].val = v;
    g_nfatd++;
    return 0;
}

static int fatd_set(uint32_t c, uint32_t v)
{
    if(v == fat_value(c)){ fatd_del(c); return 0; }   /* пробеги уже сказали то же самое */
    return fatd_put(c, v);
}

static uint32_t fat_get(uint32_t c)
{
    int k = fatd_find(c);
    return (k >= 0) ? g_fatd[k].val : fat_value(c);
}

/* ------------------------------------------------------------------------------------------- */
/* Буфер отложенных данных                                                                       */
/* ------------------------------------------------------------------------------------------- */
static void spool_path(char* out)
{
    int l = (int)strlen(g_root);
    memcpy(out, g_root, (size_t)l);
    out[l] = '/';
    memcpy(out + l + 1, DMFS_SPOOLNAME, sizeof(DMFS_SPOOLNAME));
}

static void spool_reset(int erase)
{
    char p[DMFS_MAXPATH];
    g_spool_n = g_spool_live = 0;
    if(!g_root[0]) return;
    spool_path(p);
    fc_drop(p);
    if(erase) bk_unlink(p);
}

static int spool_put(uint32_t lba, const uint8_t* buf)
{
    char p[DMFS_MAXPATH];
    uint32_t i, slot = 0xFFFFFFFFu;
    for(i = 0; i < g_spool_n; i++) if(g_spool[i] == lba){ slot = i; break; }
    if(slot == 0xFFFFFFFFu){
        if(g_spool_n >= DMFS_SPOOLSEC) return -1;
        slot = g_spool_n++;
        g_spool[slot] = lba;
        g_spool_live++;
    }
    spool_path(p);
    if(bk_write(p, slot * DMFS_SECSZ, buf, DMFS_SECSZ) != 0){ return -1; }
    g_w.spooled++;
    return 0;
}

/* Взять сектор из буфера; take = 1 «съесть» (слот освобождается под повторное использование). */
static int spool_get(uint32_t lba, uint8_t* buf, int take)
{
    char p[DMFS_MAXPATH];
    uint32_t i;
    for(i = 0; i < g_spool_n; i++){
        if(g_spool[i] != lba) continue;
        spool_path(p);
        if(bk_read(p, i * DMFS_SECSZ, buf, DMFS_SECSZ) != (int)DMFS_SECSZ) return 0;
        if(take){ g_spool[i] = 0xFFFFFFFFu; if(g_spool_live) g_spool_live--; }
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------------------------------- */
/* Имя 8.3. Правило простое: если имя не укладывается в 8.3 без потерь, оно получает хвост ~N, а  */
/* настоящее имя уходит в записи длинного имени. Различие только в регистре потерей НЕ считается: */
/* для него в записи каталога есть два флага (байт 12), их и ставим - экономит записи каталога.   */
/* ------------------------------------------------------------------------------------------- */
static int sfn_ok_char(char c)
{
    if(c >= 'A' && c <= 'Z') return 1;
    if(c >= '0' && c <= '9') return 1;
    return strchr("$%'-_@~`!(){}^#&", c) != 0;
}

static void mk_sfn(const char* name, uint8_t* sfn, uint8_t* ntcase, int* lossy, int* lfnable)
{
    int len = (int)strlen(name), dot = -1, i, b = 0, e = 0;
    int lo_b = 0, up_b = 0, lo_e = 0, up_e = 0;

    *lossy = 0; *ntcase = 0; *lfnable = 1;
    memset(sfn, ' ', 11);

    for(i = 0; i < len; i++){
        unsigned char c = (unsigned char)name[i];
        if(c < 0x20 || c > 0x7E) *lfnable = 0;   /* не ASCII - в длинное имя честно не переложить */
        if(c == '.') dot = i;                     /* расширение отделяет ПОСЛЕДНЯЯ точка */
    }
    if(dot == 0) dot = -1;                        /* имя вида ".cfg" сюда не попадает, но пусть */

    for(i = 0; i < (dot < 0 ? len : dot); i++){
        char c = name[i];
        if(c == ' ' || c == '.'){ *lossy = 1; continue; }
        if(c >= 'a' && c <= 'z') lo_b = 1; else if(c >= 'A' && c <= 'Z') up_b = 1;
        c = up(c);
        if(!sfn_ok_char(c)){ c = '_'; *lossy = 1; }
        if(b < 8) sfn[b++] = (uint8_t)c; else *lossy = 1;
    }
    if(dot >= 0){
        for(i = dot + 1; i < len; i++){
            char c = name[i];
            if(c == ' ' || c == '.'){ *lossy = 1; continue; }
            if(c >= 'a' && c <= 'z') lo_e = 1; else if(c >= 'A' && c <= 'Z') up_e = 1;
            c = up(c);
            if(!sfn_ok_char(c)){ c = '_'; *lossy = 1; }
            if(e < 3) sfn[8 + e++] = (uint8_t)c; else *lossy = 1;
        }
    }
    if(b == 0){ sfn[0] = '_'; *lossy = 1; }
    if(sfn[0] == 0xE5) sfn[0] = 0x05;             /* 0xE5 в первом байте означает «запись удалена» */
    if(!*lossy){
        if(lo_b && !up_b) *ntcase |= 0x08;
        if(lo_e && !up_e) *ntcase |= 0x10;
        if((lo_b && up_b) || (lo_e && up_e)) *lossy = 1;   /* СмешанныйРегистр флагами не выразить */
    }
}

/* Хвост ~N при потере или при столкновении с братом. */
static void sfn_tail(uint8_t* sfn, int n)
{
    char t[8]; int tl = 0, base = 0, i;
    t[tl++] = '~';
    if(n >= 10) t[tl++] = (char)('0' + n / 10);
    t[tl++] = (char)('0' + n % 10);
    for(i = 0; i < 8; i++) if(sfn[i] != ' ') base = i + 1;
    if(base > 8 - tl) base = 8 - tl;
    for(i = 0; i < tl; i++) sfn[base + i] = (uint8_t)t[i];
    for(i = base + tl; i < 8; i++) sfn[i] = ' ';
}

/* 🥇 Хвоста ~1..~99 НЕ ХВАТАЕТ, и это не теория: у TOSEC-имён первые восемь знаков совпадают у
   сотен файлов («Sinclair Collection Volume NNN…»), сотый получал бы ЧУЖОЕ имя 8.3. Стенд поймал
   это сразу: fsck.vfat увидел «Duplicate directory entry». Поэтому после нескольких попыток
   переходим на приём Windows NT - два первых знака основы плюс четыре шестнадцатеричных знака
   хэша имени плюс «~1»; при столкновении хэш просто наращиваем. */
static void sfn_hash_tail(uint8_t* sfn, uint32_t h)
{
    static const char hx[16] = { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
    if(sfn[0] == ' ') sfn[0] = '_';
    if(sfn[1] == ' ') sfn[1] = '_';
    sfn[2] = (uint8_t)hx[(h >> 12) & 15];
    sfn[3] = (uint8_t)hx[(h >>  8) & 15];
    sfn[4] = (uint8_t)hx[(h >>  4) & 15];
    sfn[5] = (uint8_t)hx[ h        & 15];
    sfn[6] = '~';
    sfn[7] = '1';
}

static uint32_t name_hash(const char* s)
{
    uint32_t h = 2166136261u;
    while(*s){ h ^= (uint8_t)*s++; h *= 16777619u; }
    return h;
}

static int sfn_taken(int parent, const uint8_t* sfn, int self)
{
    int c;
    for(c = g_nodes[parent].child; c >= 0; c = g_nodes[c].sib)
        if(c != self && !(g_nodes[c].flags & DMFS_NF_DEAD) && !memcmp(g_nodes[c].sfn, sfn, 11)) return 1;
    return 0;
}

static uint8_t sfn_sum(const uint8_t* s)
{
    uint8_t sum = 0; int i;
    for(i = 0; i < 11; i++) sum = (uint8_t)(((sum & 1) ? 0x80 : 0) + (sum >> 1) + s[i]);
    return sum;
}

/* ------------------------------------------------------------------------------------------- */
/* Обход папки                                                                                   */
/* ------------------------------------------------------------------------------------------- */
static int new_node(int parent, const char* name, int isdir, uint32_t size, uint16_t fd, uint16_t ft)
{
    int idx, nl = (int)strlen(name), lossy = 0, lfnable = 1, tries;
    dmfs_node_t* n;

    if(g_nnodes >= DMFS_MAXNODES){ g_i.skipped++; g_i.truncated = 1; return -1; }
    if(g_pool_n + (uint32_t)nl + 1 > DMFS_NAMEPOOL){ g_i.skipped++; g_i.truncated = 1; return -1; }

    idx = g_nnodes++;
    n = &g_nodes[idx];
    memset(n, 0, sizeof(*n));
    n->name_off = (uint16_t)g_pool_n;
    n->name_len = (uint8_t)nl;
    memcpy(g_pool + g_pool_n, name, (size_t)nl + 1);
    g_pool_n += (uint32_t)nl + 1;
    n->isdir = (uint8_t)isdir;
    n->size  = size;
    n->parent = (int16_t)parent;
    n->child = n->sib = -1;
    n->ext = -1;
    n->attr = (uint8_t)(isdir ? 0x10 : 0x20);
    n->flags = DMFS_NF_MAT;                      /* всё, что нашёл сканер, на карте уже есть */
    n->fdate = fd; n->ftime = ft;
    n->nent  = isdir ? 2 : 0;                    /* у папки первыми идут «.» и «..» */

    {
        uint8_t base[11], nc = 0;
        int tailed = 0;
        mk_sfn(name, base, &nc, &lossy, &lfnable);
        if(!lossy && !sfn_taken(parent, base, idx)){
            memcpy(n->sfn, base, 11); n->ntcase = nc;
        } else {
            n->ntcase = 0;                        /* с хвостом ~N флаги регистра не применяют */
            tailed = 1;
            for(tries = 1; tries <= 4; tries++){
                memcpy(n->sfn, base, 11);
                sfn_tail(n->sfn, tries);
                if(!sfn_taken(parent, n->sfn, idx)) break;
            }
            if(tries > 4){
                uint32_t h = name_hash(name), probe;
                for(probe = 0; probe < 65536u; probe++){
                    memcpy(n->sfn, base, 11);
                    sfn_hash_tail(n->sfn, h + probe);
                    if(!sfn_taken(parent, n->sfn, idx)) break;
                }
            }
        }
        /* Длинное имя нужно ровно тогда, когда 8.3 не воспроизводит настоящее имя. Не-ASCII не
           кладём: честного отображения кодовой страницы карты в UCS-2 у нас нет, а соврать -
           значит показать в каталоге мусор. Такие файлы видны под именем 8.3. */
        n->nlfn = (uint8_t)(((lossy || tailed) && lfnable) ? ((nl + 12) / 13) : 0);
    }

    /* вставка к отцу по алфавиту: так каталог выглядит предсказуемо, а порядок записей у нас
       детерминированный - это важно, иначе один и тот же сектор дважды дал бы разное */
    {
        int16_t* link = &g_nodes[parent].child;
        while(*link >= 0 && icmp(nm(&g_nodes[*link]), name) < 0) link = &g_nodes[*link].sib;
        n->sib = *link; *link = (int16_t)idx;
    }

    /* место в каталоге отца: длинное имя + сама запись */
    {
        uint32_t need = 1u + n->nlfn;
        uint32_t cap  = (parent == 0) ? g_rootent : 0xFFFFu;
        if(g_nodes[parent].nent + need > cap){    /* корень фиксированного размера - больше некуда */
            int16_t* link = &g_nodes[parent].child;
            while(*link >= 0 && *link != idx) link = &g_nodes[*link].sib;
            if(*link == idx) *link = n->sib;
            g_nnodes--; g_pool_n = n->name_off;
            g_i.skipped++; g_i.truncated = 1;
            return -1;
        }
        g_nodes[parent].nent = (uint16_t)(g_nodes[parent].nent + need);
    }

    if(isdir) g_i.dirs++; else { g_i.files++; g_i.bytes += size; }
    return idx;
}

/* 🥇 «Не влезло» ОБЯЗАНО быть посчитано. Стенд поймал это на настоящей папке репозитория: за
   пределом вложенности осталось десять записей, а счётчик пропущенных показывал ноль - то есть
   оболочка бодро доложила бы «проброшено всё». Поэтому у предела глубины поддерево не просто
   бросаем, а ПЕРЕСЧИТЫВАЕМ. */
static uint32_t count_subtree(char* path, int plen, int depth)
{
    dmfs_dh_t h;
    char name[DMFS_MAXPATH];
    uint32_t size, n = 0; int isdir; uint16_t fd, ft;
    if(depth > 16) return 0;                       /* защита от кольца ссылок на носителе */
    path[plen] = 0;
    if(bk_opendir(path, &h) != 0) return 0;
    while(bk_readdir(&h, path, name, (int)sizeof(name), &size, &isdir, &fd, &ft)){
        int nl = (int)strlen(name);
        n++;
        if(isdir && plen + 1 + nl < DMFS_MAXPATH){
            path[plen] = '/';
            memcpy(path + plen + 1, name, (size_t)nl);
            n += count_subtree(path, plen + 1 + nl, depth + 1);
            path[plen] = 0;
        }
    }
    bk_closedir(&h);
    return n;
}

static void scan_dir(int dnode, int plen, int depth)
{
    dmfs_dh_t h;
    char name[DMFS_MAXPATH];
    uint32_t size; int isdir; uint16_t fd, ft;

    g_path[plen] = 0;
    if(bk_opendir(g_path, &h) != 0) return;
    while(bk_readdir(&h, g_path, name, (int)sizeof(name), &size, &isdir, &fd, &ft)){
        int nl = (int)strlen(name), sub;
        if(!icmp(name, DMFS_SPOOLNAME)) continue;   /* наш буфер отложенных данных - не файл тома */
        if(plen + 1 + nl >= DMFS_MAXPATH){ g_i.skipped++; g_i.truncated = 1; continue; }
        sub = new_node(dnode, name, isdir, size, fd, ft);
        if(sub < 0) continue;
        if(isdir){
            g_path[plen] = '/';
            memcpy(g_path + plen + 1, name, (size_t)nl);
            if(depth + 1 >= DMFS_MAXDEPTH){
                g_i.skipped += count_subtree(g_path, plen + 1 + nl, 0);   /* честно посчитать брошенное */
                g_i.truncated = 1;
            } else scan_dir(sub, plen + 1 + nl, depth + 1);
            g_path[plen] = 0;
        }
    }
    bk_closedir(&h);
}

/* 🥇 Слоты записей каталога назначаем ОТДЕЛЬНЫМ проходом, уже после обхода. Во время обхода
   порядок появления узлов - это порядок носителя, а показываем мы каталог по алфавиту; если
   назначать слот на месте, номер слота и порядок отрисовки разошлись бы, и чужая запись,
   положенная драйвером в слот 42, встала бы не туда. Здесь же список детей уже отсортирован,
   и слоты ложатся в том же порядке, в каком каталог рисуется. */
static void assign_slots(int dnode)
{
    uint16_t next = (uint16_t)(dnode == 0 ? 1 : 2);   /* метка тома / «.» и «..» */
    int c;
    for(c = g_nodes[dnode].child; c >= 0; c = g_nodes[c].sib){
        next = (uint16_t)(next + g_nodes[c].nlfn);
        g_nodes[c].ent = next++;
        if(g_nodes[c].isdir) assign_slots(c);
    }
    g_nodes[dnode].nent = next;
}

/* ------------------------------------------------------------------------------------------- */
/* Построение тома                                                                               */
/* ------------------------------------------------------------------------------------------- */
int divmmc_fs_build(const char* folder)
{
    uint32_t cbytes = g_spc * DMFS_SECSZ;
    uint32_t next, tot, fatsz, rootsz;
    int i, rl;

    divmmc_fs_close();
    if(!folder || !*folder){ g_msg = "DIVMMC: NO FOLDER SET"; return DMFS_E_PATH; }
    rl = (int)strlen(folder);
    while(rl > 1 && (folder[rl-1] == '/' || folder[rl-1] == '\\')) rl--;   /* хвостовой слэш убрать */
    if(rl >= DMFS_MAXPATH - 32){ g_msg = "DIVMMC: FOLDER PATH TOO LONG"; return DMFS_E_PATH; }
    memcpy(g_root, folder, (size_t)rl); g_root[rl] = 0;

    /* корень дерева */
    memset(&g_nodes[0], 0, sizeof(g_nodes[0]));
    g_nodes[0].parent = -1; g_nodes[0].child = -1; g_nodes[0].sib = -1;
    g_nodes[0].ext = -1;
    g_nodes[0].isdir = 1;
    g_nodes[0].attr = 0x10;
    g_nodes[0].flags = DMFS_NF_MAT;
    g_nodes[0].nent  = 1;                    /* первой записью корня идёт метка тома */
    g_nnodes = 1; g_pool_n = 0;

    memcpy(g_path, g_root, (size_t)rl + 1);
    {
        dmfs_dh_t probe;
        if(bk_opendir(g_path, &probe) != 0){ g_msg = "DIVMMC: FOLDER NOT FOUND"; return DMFS_E_OPEN; }
        bk_closedir(&probe);
    }
    /* Буфер отложенных данных от прошлого сеанса смысла не имеет: LBA в нём указывали на другую
       раскладку кластеров. Стираем ДО обхода, чтобы он не попал в дерево. */
    spool_reset(1);
    scan_dir(0, rl, 0);
    assign_slots(0);

    /* Раздача кластеров. Идём по узлам в порядке появления, поэтому первые кластеры возрастают
       вместе с номером узла - двоичный поиск потом работает по тому же массиву без сортировки. */
    /* 🥇 У FAT32 корень - ОБЫЧНЫЙ УЗЕЛ и обязан получить кластер ПЕРВЫМ: в BPB мы объявляем
       RootClus = 2, и это же число ждёт от нас любой чужой разборщик. Поэтому обход начинается
       с узла 0, а не с первого ребёнка. */
    next = 2;
    for(i = g_f32 ? 0 : 1; i < g_nnodes; i++){
        dmfs_node_t* n = &g_nodes[i];
        uint32_t need = n->isdir ? divup((uint32_t)n->nent * 32u, cbytes) : divup(n->size, cbytes);
        uint32_t k;
        if(n->isdir && need == 0) need = 1;
        if(need == 0) continue;                                   /* пустой файл: кластера нет */
        if(next + need > (g_f32 ? 0x0FFFFFF0u : 65525u)){ n->size = 0; g_i.truncated = 1; continue; }
        for(k = 0; k < need; k++) if(ext_attach(i, next + k, k) != 0){ g_i.truncated = 1; break; }
        next += need;
    }
    g_i.clusters_used = next - 2;

    /* Общее число кластеров. Нижняя граница у FAT16 жёсткая: меньше 4085 кластеров - это уже
       FAT12, и разборщик на той стороне поймёт том иначе, чем мы его написали. Сверху 65524.
       🥇 Свободного места даём 1024 кластера (32 МБ), а не «немного»: том теперь ПИШУЩИЙ, и
       упереться в нехватку места при сохранении снапшота - худший способ об этом узнать. */
    tot = g_i.clusters_used + 1024u;
    if(g_f32){
        /* 🥇 Нижняя граница у FAT32 такая же жёсткая, только с другой стороны: МЕНЬШЕ 65525
           кластеров - и разборщик обязан прочитать том как FAT16. Берём с запасом. */
        if(tot < 65600u) tot = 65600u;
        if(tot > 0x0FFFFFF0u) tot = 0x0FFFFFF0u;
    } else {
        if(tot < 4200u)  tot = 4200u;
        if(tot > 65524u) tot = 65524u;
    }

    fatsz  = divup((tot + 2u) * (g_f32 ? 4u : 2u), DMFS_SECSZ);
    rootsz = g_f32 ? 0u : (g_rootent * 32u) / DMFS_SECSZ;   /* у FAT32 корень живёт в данных */

    g_i.part_lba      = 2048;                      /* выравнивание на мегабайт, как у нормальных карт */
    g_i.fat_lba       = g_i.part_lba + g_rsvd;      /* за загрузочным у FAT32 ещё FSInfo и копии */
    g_i.root_lba      = g_i.fat_lba + 2 * fatsz;
    g_i.data_lba      = g_i.root_lba + rootsz;
    g_i.fat_sectors   = fatsz;
    g_i.clusters      = tot;
    g_i.cluster_bytes = cbytes;
    g_i.vol_sectors   = g_i.data_lba + tot * g_spc;

    g_ready = 1;
    g_msg = "DIVMMC: FOLDER MOUNTED";
    return (g_i.files || g_i.dirs) ? DMFS_OK : DMFS_E_EMPTY;      /* пустая папка тоже том, но скажем */
}

void divmmc_fs_close(void)
{
    if(g_ncond) cond_settle(0xFFFFFFFFu);
    spool_reset(1);
    fc_closeall();
    g_ready = 0; g_nnodes = 0; g_pool_n = 0;
    g_next = 0; g_nesort = 0; g_efree = -1; g_nfatd = 0;
    g_lstash_w = 0; g_lock = 0; g_ncond = 0; g_wcall = 0;
    memset(g_lstash, 0, sizeof(g_lstash));
    memset(&g_i, 0, sizeof(g_i));
    memset(&g_w, 0, sizeof(g_w));
    g_root[0] = 0;
    g_msg = "";
}

int      divmmc_fs_ready(void){ return g_ready; }
uint32_t divmmc_fs_sectors(void){ return g_ready ? g_i.vol_sectors : 0; }
const char* divmmc_fs_msg(void){ return g_msg; }
const dmfs_info_t*  divmmc_fs_info(void){ return &g_i; }
const dmfs_wstat_t* divmmc_fs_wstat(void){ return &g_w; }

int divmmc_fs_flush(void)
{
    int i, bad = 0;
    if(g_ncond) cond_settle(0xFFFFFFFFu);
    for(i = 0; i < DMFS_FCACHE; i++) if(g_fc[i].open && g_fc[i].wr && fh_sync(&g_fc[i].f) != 0) bad++;
    return bad;
}

/* ------------------------------------------------------------------------------------------- */
/* Генерация секторов                                                                            */
/* ------------------------------------------------------------------------------------------- */
static void chs(uint32_t lba, uint8_t* out)
{
    uint32_t c = lba / (255u * 63u), h = (lba / 63u) % 255u, s = lba % 63u + 1;
    if(c > 1023){ c = 1023; h = 254; s = 63; }
    out[0] = (uint8_t)h;
    out[1] = (uint8_t)(s | ((c >> 2) & 0xC0));
    out[2] = (uint8_t)c;
}

static void sec_mbr(uint8_t* b)
{
    uint8_t* p = b + 446;
    p[0] = 0x00;                                   /* не загрузочный: с этой карты никто не грузится */
    chs(g_i.part_lba, p + 1);
    /* Тип раздела обязан соответствовать содержимому: 0x06 = FAT16 больше 32 МБ (его ищет
       esxDOS), 0x0C = FAT32 с адресацией LBA (его ищут Wild Player и Z-Player). */
    p[4] = g_f32 ? 0x0C : 0x06;
    chs(g_i.vol_sectors - 1, p + 5);
    put32(p + 8,  g_i.part_lba);
    put32(p + 12, g_i.vol_sectors - g_i.part_lba);
    b[510] = 0x55; b[511] = 0xAA;
}

/* FSInfo (только FAT32, сектор 1 резерва).
   🥇 v0.15.384 ЧИСЛА ЗДЕСЬ ОБЯЗАНЫ БЫТЬ НАСТОЯЩИМИ, а не 0xFFFFFFFF «неизвестно».
   Прежний комментарий утверждал, что «считать свободные кластеры на синтезируемом томе честно
   нечем» - это неверно ровно наоборот: кластеры файлам раздаём МЫ и раздаём ПОДРЯД, поэтому
   первый свободный и их число известны точно (`clusters_used`, `clusters`). Спецификация
   0xFFFFFFFF разрешает, но чужая сторона обязана тогда искать свободный кластер САМА - и FATALL
   v0.26 на этом встал насмерть: приборно (19.08, ядро B0144) карта отдала 30 секторов, последним
   FSInfo (LBA 2049), после чего машина не запросила НИ ОДНОГО сектора за три секунды, а на экране
   осталось «Find first free cluster Please wait...». То есть вис не в транспорте и не в ожидании
   карты, а в разборе этих двух слов.
   Первый свободный кластер = 2 + clusters_used (нумерация данных начинается с двойки). */
static void sec_fsinfo(uint8_t* b)
{
    uint32_t used = (g_i.clusters_used <= g_i.clusters) ? g_i.clusters_used : g_i.clusters;
    put32(b + 0,   0x41615252u);                   /* «RRaA» */
    put32(b + 484, 0x61417272u);                   /* «rrAa» */
    put32(b + 488, g_i.clusters - used);           /* свободных кластеров - настоящее число */
    put32(b + 492, used + 2u);                     /* следующий свободный - первый за занятыми */
    b[510] = 0x55; b[511] = 0xAA;
}

static void sec_boot_bpb(uint8_t* b)
{
    uint32_t tsec = g_i.vol_sectors - g_i.part_lba;
    b[0] = 0xEB; b[1] = 0x3C; b[2] = 0x90;
    memcpy(b + 3, "BULBULAT", 8);
    put16(b + 11, DMFS_SECSZ);
    b[13] = (uint8_t)g_spc;
    put16(b + 14, (uint16_t)g_rsvd);               /* зарезервированных секторов: 1 / 32 */
    b[16] = 2;                                     /* копий таблицы */
    put16(b + 17, g_f32 ? 0 : (uint16_t)g_rootent);/* у FAT32 корень - цепочка, поле обязано быть 0 */
    put16(b + 19, (!g_f32 && tsec < 0x10000u) ? (uint16_t)tsec : 0);
    b[21] = 0xF8;                                  /* «несъёмный носитель» */
    put16(b + 22, g_f32 ? 0 : (uint16_t)g_i.fat_sectors);
    put16(b + 24, 63);                             /* секторов на дорожку  */
    put16(b + 26, 255);                            /* головок              */
    put32(b + 28, g_i.part_lba);                   /* скрытых секторов до раздела */
    put32(b + 32, (!g_f32 && tsec < 0x10000u) ? 0 : tsec);
    if(g_f32){
        put32(b + 36, g_i.fat_sectors);            /* размер таблицы, 32 бита */
        put16(b + 40, 0);                          /* обе копии активны и зеркалятся */
        put16(b + 42, 0);                          /* версия файловой системы */
        put32(b + 44, 2);                          /* кластер корня */
        put16(b + 48, 1);                          /* сектор FSInfo */
        put16(b + 50, 6);                          /* запасной загрузочный */
        b[64] = 0x80; b[65] = 0; b[66] = 0x29;
        put32(b + 67, 0x42554C42u);
        memcpy(b + 71, "BULB DIVMMC", 11);
        memcpy(b + 82, "FAT32   ", 8);
    } else {
        b[36] = 0x80; b[37] = 0; b[38] = 0x29;
        put32(b + 39, 0x42554C42u);                /* серийный номер тома, он же «BULB» */
        memcpy(b + 43, "BULB DIVMMC", 11);
        memcpy(b + 54, "FAT16   ", 8);
    }
    b[510] = 0x55; b[511] = 0xAA;
}

/* Резервная область целиком: у FAT16 это один загрузочный сектор, у FAT32 - ещё FSInfo и копии
   обоих, объявленные в самом BPB (поля 48 и 50). Смещение считается ОТ начала раздела. */
static void sec_boot(uint32_t off, uint8_t* b)
{
    if(off == 0)               { sec_boot_bpb(b); return; }
    if(!g_f32)                   return;                       /* у FAT16 резерва больше нет */
    if(off == 1 || off == 7)   { sec_fsinfo(b);  return; }
    if(off == 6)               { sec_boot_bpb(b); return; }
}

/* Значение таблицы размещения, вытекающее ИЗ ПРОБЕГОВ (без учёта отложенных значений). */
static uint32_t fat_value(uint32_t c)
{
    int ei;
    if(c == 0) return g_f32 ? 0x0FFFFFF8u : 0xFFF8u;   /* медиа-байт, дополненный единицами */
    if(c == 1) return FAT_EOC;
    if(c >= g_i.clusters + 2u) return 0;
    ei = ext_by_cluster(c);
    if(ei < 0) return 0;                           /* свободный кластер */
    {
        const dmfs_ext_t* e = &g_ext[ei];
        if(c + 1 < e->clus + e->n) return c + 1;
        return (e->next >= 0) ? g_ext[e->next].clus : FAT_EOC;
    }
}

/* Сектор таблицы размещения. У FAT32 ячейка 4 байта, и старший ниббл принадлежит НЕ нам -
   спецификация требует его сохранять; мы том синтезируем, поэтому пишем там нули. */
static void sec_fat(uint32_t fsec, uint8_t* b)
{
    uint32_t first = fsec * FAT_ENTPS, i;
    for(i = 0; i < FAT_ENTPS; i++){
        uint32_t v = fat_get(first + i);
        if(g_f32) put32(b + i * 4, v & 0x0FFFFFFFu);
        else      put16(b + i * 2, (uint16_t)v);
    }
}

/* Первый кластер узла - именно он лежит в записи каталога. */
static uint32_t node_clus(const dmfs_node_t* n){ return (n->ext >= 0) ? g_ext[n->ext].clus : 0; }

/* Одна запись каталога 8.3 */
static void ent_sfn(uint8_t* e, const dmfs_node_t* n)
{
    memcpy(e, n->sfn, 11);
    e[11] = n->attr;
    e[12] = n->ntcase;
    e[13] = 0;
    put16(e + 14, n->ftime); put16(e + 16, n->fdate);
    put16(e + 18, n->fdate);
    put16(e + 20, 0);                              /* у FAT16 старшая половина кластера всегда 0 */
    put16(e + 22, n->ftime); put16(e + 24, n->fdate);
    put16(e + 26, node_clus(n));
    put32(e + 28, n->isdir ? 0 : n->size);
}

/* Запись длинного имени: ord, 5 символов, 0x0F, 0, контрольная сумма 8.3, 6 символов, 0, 2 символа */
static void ent_lfn(uint8_t* e, const dmfs_node_t* n, int part, uint8_t sum)
{
    static const int pos[13] = { 1,3,5,7,9, 14,16,18,20,22,24, 28,30 };
    const char* s = nm(n);
    int len = n->name_len, i, base = (part - 1) * 13;
    memset(e, 0, 32);
    e[0]  = (uint8_t)(part | ((part == n->nlfn) ? 0x40 : 0));
    e[11] = 0x0F; e[13] = sum;
    for(i = 0; i < 13; i++){
        int k = base + i;
        uint16_t ch;
        if(k < len)       ch = (uint8_t)s[k];
        else if(k == len) ch = 0x0000;
        else              ch = 0xFFFF;
        put16(e + pos[i], ch);
    }
}

/* Сектор каталога: dnode - папка, k - номер её сектора. Записи не хранятся, а перебираются
   заново по постоянным номерам слотов - так каталог всегда согласован с деревом, и хранить
   нечего, а раскладка при этом не «плывёт». */
static void dir_sector(int dnode, uint32_t k, uint8_t* b)
{
    uint32_t lo = k * (DMFS_SECSZ / 32), hi = lo + (DMFS_SECSZ / 32), i;
    uint16_t filled = 0;
    int c;
    uint8_t e[32];

    memset(b, 0, DMFS_SECSZ);

    #define DMFS_SLOT(s, src) do { uint32_t s_ = (uint32_t)(s); \
        if(s_ >= lo && s_ < hi){ memcpy(b + (s_ - lo) * 32, (src), 32); filled |= (uint16_t)(1u << (s_ - lo)); } } while(0)

    if(dnode == 0){
        memset(e, 0, 32); memcpy(e, "BULB DIVMMC", 11); e[11] = 0x08;   /* метка тома */
        DMFS_SLOT(0u, e);
    } else {
        const dmfs_node_t* d = &g_nodes[dnode];
        memset(e, ' ', 11); e[0] = '.';  e[11] = 0x10; memset(e + 12, 0, 20);
        put16(e + 22, d->ftime); put16(e + 24, d->fdate); put16(e + 26, node_clus(d));
        DMFS_SLOT(0u, e);
        memset(e, ' ', 11); e[0] = '.'; e[1] = '.'; e[11] = 0x10; memset(e + 12, 0, 20);
        put16(e + 22, d->ftime); put16(e + 24, d->fdate);
        put16(e + 26, (uint16_t)(d->parent > 0 ? node_clus(&g_nodes[d->parent]) : 0));  /* «..» корня = 0 */
        DMFS_SLOT(1u, e);
    }

    for(c = g_nodes[dnode].child; c >= 0; c = g_nodes[c].sib){
        const dmfs_node_t* n = &g_nodes[c];
        uint32_t s0 = (uint32_t)n->ent - n->nlfn;
        int p;
        /* Дети идут по возрастанию слота записи 8.3; запас в 32 слота - на длинное имя, чей
           набор записей начинается левее (максимум 20) и мог бы обрезать перебор раньше срока. */
        if((uint32_t)n->ent >= hi + 32u) break;
        if((uint32_t)n->ent < lo || s0 >= hi) continue;         /* весь набор записей вне сектора */
        if(n->nlfn){
            uint8_t sum = sfn_sum(n->sfn);
            for(p = n->nlfn; p >= 1; p--){
                ent_lfn(e, n, p, sum);
                if(n->flags & DMFS_NF_DEAD) e[0] = 0xE5;
                DMFS_SLOT((uint32_t)n->ent - p, e);
            }
        }
        memset(e, 0, 32); ent_sfn(e, n);
        if(n->flags & DMFS_NF_DEAD) e[0] = 0xE5;
        DMFS_SLOT((uint32_t)n->ent, e);
    }

    /* 🥇 Ноль в первом байте записи означает для драйвера «каталог кончился». Поэтому слот,
       который никому не принадлежит, но лежит ЛЕВЕЕ высшей отметки, обязан быть помечен как
       удалённая запись (0xE5), а не оставлен нулём - иначе всё, что дальше, пропадёт из виду. */
    for(i = lo; i < hi && i < g_nodes[dnode].nent; i++)
        if(!(filled & (1u << (i - lo)))) b[(i - lo) * 32] = 0xE5;
    #undef DMFS_SLOT
}

int divmmc_fs_area(uint32_t lba)
{
    if(!g_ready) return DMFS_A_OUT;
    if(lba >= g_i.vol_sectors) return DMFS_A_OUT;
    if(lba == 0) return DMFS_A_MBR;
    if(lba <  g_i.part_lba) return DMFS_A_GAP;
    /* Резервная область (у FAT16 ровно один сектор, у FAT32 тридцать два) относится к
       загрузочной: там же FSInfo и запасной загрузочный, и запись туда - это форматирование. */
    if(lba <  g_i.fat_lba)  return DMFS_A_BOOT;
    if(lba <  g_i.root_lba) return DMFS_A_FAT;
    if(lba <  g_i.data_lba) return DMFS_A_ROOT;   /* у FAT32 этой области нет: root_lba == data_lba */
    return DMFS_A_DATA;
}

int divmmc_fs_read(uint32_t lba, uint8_t* buf)
{
    int a = divmmc_fs_area(lba);
    /* Драйвер перешёл к чтению - значит пачка записи кончилась и ждать переименования больше
       незачем: приговор исполняется, удалённый файл исчезает с карты сразу. */
    if(g_ncond) cond_settle(0xFFFFFFFFu);
    memset(buf, 0, DMFS_SECSZ);
    switch(a){
      case DMFS_A_OUT:  return -1;
      case DMFS_A_MBR:  sec_mbr(buf);  return 0;
      case DMFS_A_GAP:  return 0;                               /* пусто - так и есть на карте */
      case DMFS_A_BOOT: sec_boot(lba - g_i.part_lba, buf); return 0;
      case DMFS_A_FAT: {
          uint32_t off = lba - g_i.fat_lba;
          if(off >= g_i.fat_sectors) off -= g_i.fat_sectors;    /* вторая копия равна первой */
          sec_fat(off, buf);
          return 0;
      }
      case DMFS_A_ROOT: dir_sector(0, lba - g_i.root_lba, buf); return 0;
      default: break;
    }
    {
        uint32_t dsec = lba - g_i.data_lba;
        uint32_t clus = 2u + (dsec >> g_spc_sh);
        int ei = ext_by_cluster(clus);
        const dmfs_node_t* n;
        uint32_t off;
        if(ei < 0){
            /* Кластер ничей. Если драйвер уже успел что-то в него записать, а имя ещё не
               прислал, честно вернуть ему ЕГО ЖЕ байты: том обязан быть сам себе согласован. */
            spool_get(lba, buf, 0);
            return 0;
        }
        n = &g_nodes[g_ext[ei].node];
        off = ext_ordinal(ei, clus) * g_i.cluster_bytes + ((dsec & (g_spc - 1u))) * DMFS_SECSZ;
        if(n->isdir){ dir_sector(g_ext[ei].node, off / DMFS_SECSZ, buf); return 0; }
        if(off >= n->size) return 0;                            /* хвост последнего кластера */
        {
            uint32_t want = n->size - off; if(want > DMFS_SECSZ) want = DMFS_SECSZ;
            if(node_path(g_ext[ei].node, g_path, DMFS_MAXPATH) < 0) return 0;
            bk_read(g_path, off, buf, want);
        }
        return 0;
    }
}

int divmmc_fs_map(uint32_t lba, const char** name, uint32_t* off)
{
    int a = divmmc_fs_area(lba);
    if(name) *name = "";
    if(off)  *off  = 0;
    if(a != DMFS_A_DATA) return a;
    {
        uint32_t dsec = lba - g_i.data_lba;
        uint32_t clus = 2u + (dsec >> g_spc_sh);
        int ei = ext_by_cluster(clus);
        if(ei < 0) return a;
        if(name) *name = nm(&g_nodes[g_ext[ei].node]);
        if(off)  *off  = ext_ordinal(ei, clus) * g_i.cluster_bytes + ((dsec & (g_spc - 1u))) * DMFS_SECSZ;
    }
    return a;
}

/* ------------------------------------------------------------------------------------------- */
/* ЗАПИСЬ                                                                                        */
/* ------------------------------------------------------------------------------------------- */
static int wipe_like(const uint8_t* b)
{
    /* Форматирование узнаётся по заливке однородным байтом: 0x00 у ядра Linux, 0xF6 у DOS и
       у самого esxDOS. Ловим это не ради решения (решает область), а ради ЧЕСТНОГО текста. */
    uint8_t f = b[0]; uint32_t i;
    if(f != 0x00 && f != 0xF6 && f != 0xFF) return 0;
    for(i = 1; i < DMFS_SECSZ; i++) if(b[i] != f) return 0;
    return 1;
}

static void lock_volume(void)
{
    g_lock = 1;
    g_w.locked = 1;
    g_msg = "DIVMMC: FORMAT REFUSED - REMOUNT TO WRITE";
}

/* Пока том заперт, причину отказа называем по области - ровно тем же разбором, каким модуль
   отвечал, когда записи не было вовсе. */
static int refuse_locked(int a, uint32_t lba, const uint8_t* buf)
{
    if(a == DMFS_A_MBR || a == DMFS_A_GAP || a == DMFS_A_BOOT || a == DMFS_A_FAT) return DMFS_W_FORMAT;
    if(a == DMFS_A_ROOT) return wipe_like(buf) ? DMFS_W_FORMAT : DMFS_W_DIRENT;
    {
        uint32_t dsec = lba - g_i.data_lba;
        int ei = ext_by_cluster(2u + (dsec >> g_spc_sh));
        if(ei >= 0 && g_nodes[g_ext[ei].node].isdir) return wipe_like(buf) ? DMFS_W_FORMAT : DMFS_W_DIRENT;
    }
    return DMFS_W_DATA;
}

/* --------------------------- материализация файла на карте --------------------------------- */

/* 🥇 Снять пробеги узла, СНАЧАЛА переписав его цепочку в отложенные значения.
   Оплачено разбором «удалить файл и тут же занять его кластеры соседним»: чужой драйвер правит
   в таблице размещения ровно одно звено (у нас это было 5:FFFF -> 0006), а остальные звенья
   обеих цепочек не переписывает - они и так стоят правильно. Если просто выбросить пробеги,
   эти НЕ ПЕРЕПИСАННЫЕ звенья исчезнут из таблицы, и файл соберётся из одного кластера вместо
   трёх. Поэтому цепочка сначала уходит в отложенные значения и только потом снимается. */
static int chain_disown(int node)
{
    int ei;
    if(node <= 0) return 0;
    for(ei = g_nodes[node].ext; ei >= 0; ei = g_ext[ei].next){
        uint32_t j;
        for(j = 0; j < g_ext[ei].n; j++){
            uint32_t c = (uint32_t)g_ext[ei].clus + j;
            if(fatd_put(c, fat_value(c)) != 0) return -1;
        }
    }
    ext_free_all(node);
    return 0;
}

/* Пройти по цепочке от first и присвоить узлу все её кластеры. Значение «следующий» берём ДО
   присоединения: после него fat_get() начнёт отвечать уже по пробегам, которые мы и строим. */
static int chain_attach(int idx, uint32_t first)
{
    dmfs_node_t* n = &g_nodes[idx];
    uint32_t c = first, ord = 0, guard = 0;
    if(first < 2 || first >= g_i.clusters + 2u) return (first == 0) ? 0 : -1;
    if(node_clus(n) != first && chain_disown(idx) != 0) return -1;   /* цепочку перенесли */
    while(c >= 2 && c < g_i.clusters + 2u && guard++ <= g_i.clusters){
        uint16_t nx = fat_get(c);
        int ei = ext_by_cluster(c);
        if(ei >= 0 && g_ext[ei].node != idx){
            /* Кластер числится за другим узлом. Запись каталога, которую драйвер только что
               написал, свежее нашего дерева: скорее всего прежний владелец уже удалён, а его
               запись каталога придёт следующим сектором. Отдаём кластеры новому хозяину и
               СЧИТАЕМ такие случаи - настоящая перекрёстная ссылка выглядит так же. */
            if(chain_disown(g_ext[ei].node) != 0) return -1;
            g_w.stolen++;
            ei = -1;
        }
        if(ei < 0){
            if(ext_attach(idx, c, ord) != 0) return -1;
            fatd_del(c);                              /* теперь то же самое говорят пробеги */
        }
        ord++;
        if(FAT_ISEOC(nx) || nx < 2u) break;
        c = nx;
    }
    return 0;
}

static int wr_dir(int dnode, uint32_t k, const uint8_t* buf);

/* Разложить по месту всё, что легло в буфер отложенных данных раньше, чем нашёлся владелец
   кластера. Для файла это дозапись по смещению, для папки - обычный разбор сектора каталога.
   Вызывается дважды: при материализации узла (имя пришло после данных) и при подцепке нового
   кластера из таблицы размещения (цепочка пришла после данных). */
static void drain_cluster(int idx, uint32_t clus, uint32_t ord)
{
    uint8_t sec[DMFS_SECSZ];
    uint32_t k;
    if(!g_spool_live) return;
    for(k = 0; k < g_spc; k++){
        uint32_t lba = g_i.data_lba + (clus - 2u) * g_spc + k;
        uint32_t off, n;
        if(!spool_get(lba, sec, 1)) continue;
        if(g_nodes[idx].isdir){ wr_dir(idx, ord * g_spc + k, sec); continue; }
        off = (ord * g_i.cluster_bytes) + k * DMFS_SECSZ;
        if(off >= g_nodes[idx].size) continue;
        n = g_nodes[idx].size - off; if(n > DMFS_SECSZ) n = DMFS_SECSZ;
        if(node_path(idx, g_wpath2, DMFS_MAXPATH) >= 0) bk_write(g_wpath2, off, sec, n);
    }
    /* Разобрали всё - убрать сам буфер с карты. Он лежит в проброшенной папке, и оставлять его
       там на глазах у владельца незачем: настоящая esxDOS пишет данные РАНЬШЕ записи каталога,
       так что через буфер проходит каждая копия файла, и файл-мусор появлялся бы после каждой.
       🥇 Проверка живёт именно здесь, а не в drain_spool: последний кластер файла чаще всего
       подцепляется ПОЗЖЕ, из записи в таблицу размещения, и разбирается тоже отсюда. */
    if(!g_spool_live && g_spool_n) spool_reset(1);
}

static void drain_spool(int idx)
{
    int ei;
    if(!g_spool_live) return;
    for(ei = g_nodes[idx].ext; ei >= 0; ei = g_ext[ei].next){
        uint32_t j;
        for(j = 0; j < g_ext[ei].n; j++) drain_cluster(idx, (uint32_t)g_ext[ei].clus + j, (uint32_t)g_ext[ei].first + j);
    }
}

/* Создать (или довести до объявленного размера) настоящий файл узла. */
static int materialize(int idx)
{
    dmfs_node_t* n = &g_nodes[idx];
    if(node_path(idx, g_wpath, DMFS_MAXPATH) < 0) return DMFS_W_FULL;
    if(n->isdir){
        if(!(n->flags & DMFS_NF_MAT)){
            if(bk_mkdir(g_wpath) != 0 && bk_stat(g_wpath, 0, 0) != 0) return DMFS_W_MEDIA;
            n->flags |= DMFS_NF_MAT;
        }
        drain_spool(idx);
        return DMFS_W_OK;
    }
    if(bk_setsize(g_wpath, n->size) != 0) return DMFS_W_MEDIA;
    n->flags |= DMFS_NF_MAT;
    n->flags &= (uint8_t)~DMFS_NF_GREW;
    drain_spool(idx);
    bk_sync(g_wpath);
    return DMFS_W_OK;
}

/* --------------------------- удаление и «переименование = удалить + создать» ---------------- */
/* 🥇 Чужой драйвер переименовывает файл НЕ на месте: mtools (и это видно в трассе) гасит старую
   запись каталога и пишет новую в другой слот - иногда прямо в слот, где лежала запись длинного
   имени. Если удалять файл сразу, от переименования остался бы пустой файл с новым именем, а
   данные пропали бы. Поэтому удаление ПРИГОВАРИВАЕТ узел: в томе он мгновенно становится
   надгробием, а на карте живёт ещё немного - ровно до конца разбора текущего сектора каталога.
   Появилась в том же секторе запись с ТЕМ ЖЕ первым кластером и размером - это переименование,
   и файл просто переезжает под новое имя. Не появилась - файл удаляется. */
/* Физически убрать узел с карты (вместе с поддеревом) и пометить всё поддерево надгробиями. */
static void purge_node(int idx)
{
    int c;
    for(c = g_nodes[idx].child; c >= 0; c = g_nodes[c].sib) purge_node(c);
    if(g_nodes[idx].flags & DMFS_NF_MAT){
        if(node_path(idx, g_wpath2, DMFS_MAXPATH) >= 0){ fc_drop(g_wpath2); bk_unlink(g_wpath2); }
    }
    ext_free_all(idx);
    g_nodes[idx].flags = DMFS_NF_DEAD;
    g_nodes[idx].nlfn  = 0;
    g_nodes[idx].size  = 0;
}

static void cond_drop(int k)
{
    memmove(&g_cond[k], &g_cond[k + 1], (size_t)(g_ncond - k - 1) * sizeof(g_cond[0]));
    g_ncond--;
}

static void cond_purge(int k){ purge_node(g_cond[k].node); cond_drop(k); }

/* Привести приговор в исполнение для всего, что приговорено раньше текущего вызова. */
static void cond_settle(uint32_t keep_seq)
{
    int k = 0;
    while(k < g_ncond){ if(g_cond[k].seq != keep_seq) cond_purge(k); else k++; }
}

/* Освободить имя в каталоге: если его держит приговорённый узел, исполнить приговор сейчас. */
static void cond_free_name(int dnode, const char* name)
{
    int k;
    for(k = 0; k < g_ncond; k++){
        int idx = g_cond[k].node;
        if(g_nodes[idx].parent != (int16_t)dnode) continue;
        if(icmp(nm(&g_nodes[idx]), name)) continue;
        cond_purge(k);
        return;
    }
}

/* 🥇 Приговорённый узел ОБЯЗАН отпустить свой слот в каталоге. Оплачено тремя потерянными
   цепочками, которые нашёл fsck: чужой драйвер уплотняет каталог и кладёт запись переехавшего
   файла ровно в слот удалённого. Если надгробие продолжает считать слот своим, при отрисовке
   каталога оно затирает запись нового хозяина нулём-с-0xE5, и файл пропадает из виду, а его
   кластеры остаются занятыми и недостижимыми. Дырка в каталоге и так рисуется как 0xE5 (см.
   dir_sector), поэтому надгробию слот держать не нужно. */
static int condemn_node(int idx)
{
    dmfs_node_t* n = &g_nodes[idx];
    uint32_t first;
    if(n->flags & DMFS_NF_DEAD) return DMFS_W_OK;
    first = node_clus(n);
    if(chain_disown(idx) != 0) return DMFS_W_FULL;
    if(n->parent >= 0){
        int16_t* link = &g_nodes[n->parent].child;
        while(*link >= 0 && *link != (int16_t)idx) link = &g_nodes[*link].sib;
        if(*link == (int16_t)idx) *link = n->sib;
    }
    n->ent   = 0xFFFF;
    n->flags = (uint8_t)((n->flags & DMFS_NF_MAT) | DMFS_NF_DEAD);
    n->nlfn  = 0;
    g_w.deleted++;
    if(g_ncond >= DMFS_CONDEMNED) cond_purge(0);
    g_cond[g_ncond].node = (int16_t)idx;
    g_cond[g_ncond].clus = first;
    g_cond[g_ncond].size = n->size;
    g_cond[g_ncond].seq  = g_wcall;
    g_ncond++;
    return DMFS_W_OK;
}

/* Найти приговорённый узел, который на самом деле переименовывают: совпали первый кластер,
   размер и род (файл/папка). Нулевой кластер (пустой файл) для опознания не годится. */
static int cond_match(uint32_t clus, uint32_t size, int isdir)
{
    int k;
    if(!clus) return -1;
    for(k = 0; k < g_ncond; k++)
        if(g_cond[k].clus == clus && g_cond[k].size == size &&
           g_nodes[g_cond[k].node].isdir == (uint8_t)isdir) return k;
    return -1;
}

/* --------------------------- запись в таблицу размещения ----------------------------------- */
static int apply_fat(uint32_t c, uint32_t v)
{
    int ei = ext_by_cluster(c);

    if(v == 0){                                      /* кластер освободили */
        if(ei >= 0 && ext_detach(c) != 0) return DMFS_W_FULL;
        fatd_del(c);
        return DMFS_W_OK;
    }
    if(FAT_ISEOC(v)){                                /* цепочка кончается здесь */
        if(ei >= 0) ext_truncate_after(g_ext[ei].node, c);
        return (fatd_set(c, v) == 0) ? DMFS_W_OK : DMFS_W_FULL;
    }
    if(v < 2u || v >= g_i.clusters + 2u){ g_msg = "DIVMMC: BAD FAT ENTRY"; return DMFS_W_DIRENT; }

    {
        int e2 = ext_by_cluster(v);
        /* Дозапись в конец файла - самый частый случай, и его берём напрямую: кластер v свободен,
           а c - последний кластер цепочки узла. Так длинные файлы не растят таблицу отложенных. */
        if(ei >= 0 && e2 < 0 && c == (uint32_t)g_ext[ei].clus + g_ext[ei].n - 1u && g_ext[ei].next < 0){
            int node = g_ext[ei].node;
            uint32_t ord = g_nodes[node].nclus;
            if(ext_attach(node, v, ord) != 0) return DMFS_W_FULL;
            fatd_del(v);
            if(g_nodes[node].flags & DMFS_NF_MAT) drain_cluster(node, v, ord);
            return DMFS_W_OK;
        }
        /* Всё остальное - перекройка размещения (удалили файл, его кластеры отдали другому).
           Разбираться, кто чей, сейчас нельзя: записи каталога, объясняющие перекройку, придут
           ПОЗЖЕ (у них больший LBA). Поэтому просто снимаем устаревшие пробеги с обеих сторон,
           сохранив их связи в отложенных значениях, а хозяев расставит запись каталога. */
        if(ei >= 0 && chain_disown(g_ext[ei].node) != 0) return DMFS_W_FULL;
        if(e2 >= 0 && chain_disown(g_ext[e2].node) != 0) return DMFS_W_FULL;
        return (fatd_set(c, v) == 0) ? DMFS_W_OK : DMFS_W_FULL;
    }
}

static int wr_fat(uint32_t lba, const uint8_t* buf)
{
    uint32_t off = (lba - g_i.fat_lba) % g_i.fat_sectors;
    uint32_t first = off * FAT_ENTPS, k;
    int worst = DMFS_W_OK;

    if(off == 0){
        /* 🥇 Нулевая и первая записи таблицы - это признак носителя (FFF8) и «том закрыт
           штатно» (FFFF, у некоторых драйверов старшие биты гасятся). Обнулить их может только
           форматирование: ни одна файловая операция сюда не лезет. */
        /* 🥇 У FAT32 старшие два бита ячейки 1 - это флаги ClnShut/HrdErr, их законно гасит
           чужой драйвер при монтировании. Сравнивать надо ПО МАСКЕ, иначе первая же «грязная»
           отметка Windows или esxDOS была бы принята за форматирование и заперла бы том. */
        uint32_t e0 = g_f32 ? (get32(buf)     & 0x0FFFFFFFu) : get16(buf);
        uint32_t e1 = g_f32 ? (get32(buf + 4) & 0x0FFFFFFFu) : get16(buf + 2);
        uint32_t m0 = g_f32 ? 0x0FFFFFF8u : 0xFFF8u;
        uint32_t e1m = g_f32 ? (e1 | 0x0C000000u) : e1;
        int bad1 = g_f32 ? (e1m != 0x0FFFFFFFu)
                         : (e1 != 0xFFFFu && e1 != 0x7FFFu && e1 != 0xBFFFu && e1 != 0x3FFFu);
        if(e0 != m0 || bad1){
            lock_volume();
            return DMFS_W_FORMAT;
        }
    }
    for(k = 0; k < FAT_ENTPS; k++){
        uint32_t c = first + k;
        uint32_t v = g_f32 ? (get32(buf + k * 4) & 0x0FFFFFFFu) : get16(buf + k * 2);
        int rc;
        if(c < 2 || c >= g_i.clusters + 2u) continue;
        if(v == fat_get(c)) continue;
        rc = apply_fat(c, v);
        if(rc != DMFS_W_OK && worst == DMFS_W_OK) worst = rc;
    }
    if(worst == DMFS_W_OK){ g_w.w_fat++; g_msg = "DIVMMC: FAT UPDATED"; }
    else g_msg = (worst == DMFS_W_CROSS) ? "DIVMMC: CLUSTER ALREADY OWNED" : "DIVMMC: WRITE TABLES FULL";
    return worst;
}

/* --------------------------- запись в каталог ---------------------------------------------- */

/* Кто занимает слот: возвращает узел, у которого этот слот - запись 8.3 или одна из записей
   длинного имени. Надгробия тоже считаются: их слоты по-прежнему заняты. */
static int slot_owner(int dnode, uint32_t slot, int* is_sfn)
{
    int c;
    for(c = g_nodes[dnode].child; c >= 0; c = g_nodes[c].sib){
        const dmfs_node_t* n = &g_nodes[c];
        if(slot == (uint32_t)n->ent){ if(is_sfn) *is_sfn = 1; return c; }
        if(n->nlfn && slot >= (uint32_t)n->ent - n->nlfn && slot < (uint32_t)n->ent){ if(is_sfn) *is_sfn = 0; return c; }
    }
    return -1;
}

static void lstash_put(int dnode, uint32_t slot, const uint8_t* e)
{
    g_lstash[g_lstash_w].dir  = (int16_t)dnode;
    g_lstash[g_lstash_w].slot = (uint16_t)slot;
    memcpy(g_lstash[g_lstash_w].e, e, 32);
    g_lstash_w = (g_lstash_w + 1) % DMFS_LSTASH;
}

static const uint8_t* lstash_find(int dnode, uint32_t slot)
{
    int i;
    for(i = 0; i < DMFS_LSTASH; i++)
        if(g_lstash[i].dir == (int16_t)dnode && g_lstash[i].slot == (uint16_t)slot && g_lstash[i].e[11] == 0x0F)
            return g_lstash[i].e;
    return 0;
}

/* Имя из записи 8.3 с учётом флагов регистра - именно так его показал бы драйвер без длинных имён. */
static int name_from_sfn(const uint8_t* e, char* out)
{
    int i, o = 0;
    for(i = 0; i < 8 && e[i] != ' '; i++){
        char c = (char)e[i];
        if((e[12] & 0x08) && c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        out[o++] = c;
    }
    if(e[8] != ' '){
        out[o++] = '.';
        for(i = 8; i < 11 && e[i] != ' '; i++){
            char c = (char)e[i];
            if((e[12] & 0x10) && c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            out[o++] = c;
        }
    }
    out[o] = 0;
    return o;
}

/* Собрать длинное имя из придержанных записей, лежащих перед слотом записи 8.3. */
static int name_from_lfn(int dnode, uint32_t slot, uint8_t sum, char* out, int omax, int* nlfn)
{
    static const int pos[13] = { 1,3,5,7,9, 14,16,18,20,22,24, 28,30 };
    int part, done = 0, maxlen = 0;
    *nlfn = 0;
    memset(out, 0, (size_t)omax);
    for(part = 1; part <= 20 && (uint32_t)part <= slot; part++){
        const uint8_t* e = lstash_find(dnode, slot - part);
        int k;
        if(!e || (e[0] & 0x3F) != part || e[13] != sum) break;
        for(k = 0; k < 13; k++){
            uint16_t ch = get16(e + pos[k]);
            int idx = (part - 1) * 13 + k;
            if(idx >= omax - 1) break;
            if(ch == 0 || ch == 0xFFFF){ if(!done && ch == 0) done = 1; continue; }
            /* Кодовую страницу карты мы не знаем, а врать в имени файла нельзя: всё, что вне
               печатного ASCII, заменяем подчёркиванием (то же правило, что и при чтении). */
            out[idx] = (ch >= 0x20 && ch <= 0x7E) ? (char)ch : '_';
            if(idx + 1 > maxlen) maxlen = idx + 1;
        }
        *nlfn = part;
        if(e[0] & 0x40) return maxlen;               /* последняя запись набора */
    }
    *nlfn = 0;
    return 0;
}

/* Создать узел из записи каталога, которую написал чужой драйвер. */
static int node_from_ent(int dnode, uint32_t slot, const uint8_t* e, const char* name, int nlfn)
{
    int idx, nl = (int)strlen(name);
    dmfs_node_t* n;
    int16_t* link;

    if(g_nnodes >= DMFS_MAXNODES) return -1;
    if(g_pool_n + (uint32_t)nl + 1 > DMFS_NAMEPOOL) return -1;
    idx = g_nnodes++;
    n = &g_nodes[idx];
    memset(n, 0, sizeof(*n));
    n->name_off = (uint16_t)g_pool_n;
    n->name_len = (uint8_t)nl;
    memcpy(g_pool + g_pool_n, name, (size_t)nl + 1);
    g_pool_n += (uint32_t)nl + 1;
    n->isdir  = (e[11] & 0x10) ? 1 : 0;
    n->attr   = (uint8_t)(e[11] & 0x3F);
    n->ntcase = e[12];
    n->size   = n->isdir ? 0 : get32(e + 28);
    n->parent = (int16_t)dnode;
    n->child  = n->sib = -1;
    n->ext    = -1;
    n->ent    = (uint16_t)slot;
    n->nlfn   = (uint8_t)nlfn;
    n->ftime  = get16(e + 22); n->fdate = get16(e + 24);
    memcpy(n->sfn, e, 11);
    n->flags  = 0;
    if(n->isdir) n->nent = 2;

    /* список детей держим по возрастанию слота: рисование каталога идёт по нему */
    link = &g_nodes[dnode].child;
    while(*link >= 0 && g_nodes[*link].ent < slot) link = &g_nodes[*link].sib;
    n->sib = *link; *link = (int16_t)idx;
    if(slot + 1 > g_nodes[dnode].nent) g_nodes[dnode].nent = (uint16_t)(slot + 1);
    return idx;
}

/* Перевесить узел в другой слот (и, если надо, в другой каталог) - файл на карте при этом не
   трогается, ему меняет имя вызывающий. */
static void move_node(int idx, int dnode, uint32_t slot, int nlfn)
{
    int16_t* link = &g_nodes[g_nodes[idx].parent].child;
    while(*link >= 0 && *link != idx) link = &g_nodes[*link].sib;
    if(*link == idx) *link = g_nodes[idx].sib;
    g_nodes[idx].parent = (int16_t)dnode;
    g_nodes[idx].ent    = (uint16_t)slot;
    g_nodes[idx].nlfn   = (uint8_t)nlfn;
    link = &g_nodes[dnode].child;
    while(*link >= 0 && (uint32_t)g_nodes[*link].ent < slot) link = &g_nodes[*link].sib;
    g_nodes[idx].sib = *link; *link = (int16_t)idx;
    if(slot + 1u > g_nodes[dnode].nent) g_nodes[dnode].nent = (uint16_t)(slot + 1u);
}

/* Задать узлу новое имя (пул имён общий, короткое имя перетираем на месте). */
static int set_name(int idx, const char* name, int nl)
{
    dmfs_node_t* n = &g_nodes[idx];
    if((uint32_t)n->name_len >= (uint32_t)nl){
        memcpy(g_pool + n->name_off, name, (size_t)nl + 1);
    } else {
        if(g_pool_n + (uint32_t)nl + 1 > DMFS_NAMEPOOL) return -1;
        n->name_off = (uint16_t)g_pool_n;
        memcpy(g_pool + g_pool_n, name, (size_t)nl + 1);
        g_pool_n += (uint32_t)nl + 1;
    }
    n->name_len = (uint8_t)nl;
    return 0;
}

/* 🥇 ЗАПИСЬ КАТАЛОГА ОПОЗНАЁТСЯ ПО ПЕРВОМУ КЛАСТЕРУ, А НЕ ПО НОМЕРУ СЛОТА.
   Оплачено десятью переименованиями, которые дали файлы правильной длины с ЧУЖИМ содержимым.
   Чужой драйвер каталог УПЛОТНЯЕТ: mtools удалил тридцать файлов и разложил десять новых записей
   по освободившимся местам, поэтому слот, где лежал BULK000, в следующем же состоянии тома держит
   уже запись переименованного «Game Number 001» - без всякого 0xE5 между ними. Если считать, что
   слот принадлежит одному и тому же файлу, получится «переименовали BULK000», то есть содержимое
   одного файла под именем другого. Признак, который не врёт, - ПЕРВЫЙ КЛАСТЕР: он у файла свой,
   и запись каталога описывает именно того, чей это кластер, в каком бы слоте она ни лежала. */
static int handle_dirent(int dnode, uint32_t slot, const uint8_t* nw)
{
    char name[DMFS_MAXPATH];
    int own, is_sfn = 0, nlfn = 0, nl, rc, fresh = 0, isdir, src = -1;
    uint32_t clus, size;

    own = slot_owner(dnode, slot, &is_sfn);

    /* --- слот освобождают --- */
    if(nw[0] == 0x00 || nw[0] == 0xE5){
        if(own >= 0 && is_sfn) return condemn_node(own);
        return DMFS_W_OK;                            /* записи длинного имени гасятся вместе с 8.3 */
    }

    /* --- запись длинного имени: придержать до прихода записи 8.3 --- */
    if((nw[11] & 0x3F) == 0x0F){ lstash_put(dnode, slot, nw); return DMFS_W_OK; }

    /* --- «.», «..» и метка тома --- */
    if(nw[0] == '.') return DMFS_W_OK;               /* их рисуем сами, менять нечего */
    if(nw[11] & 0x08){
        /* Метку тома синтезируем мы. Переименовать том = переименовать проброшенную папку;
           такого договора нет, поэтому отказ (и это же ловит стирание корня форматированием). */
        g_msg = "DIVMMC: VOLUME LABEL IS OURS";
        return DMFS_W_DIRENT;
    }

    isdir = (nw[11] & 0x10) ? 1 : 0;
    clus  = get16(nw + 26) | ((uint32_t)get16(nw + 20) << 16);
    size  = isdir ? 0 : get32(nw + 28);
    if(clus && (clus < 2u || clus >= g_i.clusters + 2u)){ g_msg = "DIVMMC: BAD FIRST CLUSTER"; return DMFS_W_DIRENT; }

    nl = name_from_lfn(dnode, slot, sfn_sum(nw), name, (int)sizeof(name), &nlfn);
    if(nl <= 0){ nl = name_from_sfn(nw, name); nlfn = 0; }
    if(nl <= 0){ g_msg = "DIVMMC: EMPTY NAME"; return DMFS_W_DIRENT; }

    if(own >= 0 && (!is_sfn || (g_nodes[own].flags & DMFS_NF_DEAD))) own = -1;

    /* Кого описывает запись: хозяина её первого кластера. */
    if(clus){
        int ei = ext_by_cluster(clus);
        if(ei >= 0){
            int x = g_ext[ei].node;
            if(!(g_nodes[x].flags & DMFS_NF_DEAD) && g_nodes[x].isdir == (uint8_t)isdir) src = x;
        }
    }
    if(src >= 0 && src != own){
        /* Файл переехал в этот слот. Прежнего хозяина слота приговариваем: его собственная
           запись каталога либо уже погашена, либо придёт следующим сектором. */
        if(own >= 0){ rc = condemn_node(own); if(rc != DMFS_W_OK) return rc; }
        own = src;
    }

    if(own < 0){
        int mv = cond_match(clus, size, isdir);
        if(mv >= 0 && node_path(g_cond[mv].node, g_wpath, DMFS_MAXPATH) < 0) mv = -1;
        own = node_from_ent(dnode, slot, nw, name, nlfn);
        if(own < 0){ g_msg = "DIVMMC: TOO MANY FILES"; return DMFS_W_FULL; }
        fresh = 1;
        if(mv >= 0){
            /* Переименование, распознанное по совпадению первого кластера и размера с только что
               приговорённым узлом: файл на карте не пересоздаём, а переносим под новое имя -
               иначе от него остались бы одни нули. */
            int old = g_cond[mv].node;
            cond_drop(mv);
            cond_free_name(dnode, name);
            if(node_path(own, g_wpath2, DMFS_MAXPATH) < 0) return DMFS_W_FULL;
            fc_drop(g_wpath);
            if((g_nodes[old].flags & DMFS_NF_MAT) && icmp(g_wpath, g_wpath2)){
                if(bk_rename(g_wpath, g_wpath2) != 0){ g_msg = "DIVMMC: RENAME FAILED"; return DMFS_W_MEDIA; }
            }
            g_nodes[old].flags &= (uint8_t)~DMFS_NF_MAT;   /* файл теперь у нового узла */
            g_nodes[own].flags |= DMFS_NF_MAT;
            if(g_w.deleted) g_w.deleted--;
            g_w.renamed++;
        } else {
            cond_free_name(dnode, name);             /* имя могло висеть за приговорённым узлом */
            g_w.created++;
        }
    } else {
        dmfs_node_t* n = &g_nodes[own];
        int moved = 0;
        if(node_path(own, g_wpath, DMFS_MAXPATH) < 0) return DMFS_W_FULL;   /* путь ДО правки */
        if(n->parent != (int16_t)dnode || (uint32_t)n->ent != slot || n->nlfn != (uint8_t)nlfn){
            move_node(own, dnode, slot, nlfn);
            moved = (n->parent != (int16_t)dnode) ? 1 : moved;
        }
        if(icmp(nm(n), name)){
            if(set_name(own, name, nl) != 0){ g_msg = "DIVMMC: NAME POOL FULL"; return DMFS_W_FULL; }
            moved = 1;
        }
        if(moved){
            if(node_path(own, g_wpath2, DMFS_MAXPATH) < 0) return DMFS_W_FULL;
            if(strcmp(g_wpath, g_wpath2)){
                fc_drop(g_wpath);
                cond_free_name(dnode, name);         /* новое имя мог держать приговорённый узел */
                if(n->flags & DMFS_NF_MAT){
                    if(bk_rename(g_wpath, g_wpath2) != 0){ g_msg = "DIVMMC: RENAME FAILED"; return DMFS_W_MEDIA; }
                }
                g_w.renamed++;
            }
        }
        memcpy(n->sfn, nw, 11);
        n->ntcase = nw[12];
        n->attr   = (uint8_t)(nw[11] & 0x3F);
        n->ftime  = get16(nw + 22); n->fdate = get16(nw + 24);
        if(!n->isdir && n->size != size){ n->size = size; g_w.resized++; }
    }

    /* цепочка кластеров: то, что уже пришло в таблицу размещения, привязываем к узлу */
    if(clus){
        int cr = chain_attach(own, clus);
        if(cr == -2){ g_msg = "DIVMMC: CLUSTER ALREADY OWNED"; return DMFS_W_CROSS; }
        if(cr != 0){ g_msg = "DIVMMC: WRITE TABLES FULL"; return DMFS_W_FULL; }
    } else if(!fresh) ext_free_all(own);

    rc = materialize(own);
    if(rc != DMFS_W_OK){ g_msg = "DIVMMC: CARD WRITE FAILED"; return rc; }
    g_msg = fresh ? "DIVMMC: FILE CREATED" : "DIVMMC: FILE UPDATED";
    return DMFS_W_OK;
}

static int wr_dir(int dnode, uint32_t k, const uint8_t* buf)
{
    uint8_t gen[DMFS_SECSZ];
    uint32_t lo = k * (DMFS_SECSZ / 32), s;
    int worst = DMFS_W_OK, pass;
    dir_sector(dnode, k, gen);
    /* 🥇 ДВА ПРОХОДА, и удаления первыми. Переименование чужой драйвер пишет как «погасить
       старую запись + положить новую», причём новая может лечь в слот с МЕНЬШИМ номером (mtools
       кладёт её на место записи длинного имени). Разбирай мы слоты подряд, создание пришло бы
       раньше удаления: старый узел ещё держал бы кластеры, и вместо переезда получился бы
       конфликт с потерей файла. */
    for(pass = 0; pass < 2; pass++){
        for(s = 0; s < DMFS_SECSZ / 32; s++){
            const uint8_t* e = buf + s * 32;
            int gone = (e[0] == 0x00 || e[0] == 0xE5), rc;
            if(gone != (pass == 0)) continue;
            if(!memcmp(e, gen + s * 32, 32)) continue;
            rc = handle_dirent(dnode, lo + s, e);
            if(rc != DMFS_W_OK && worst == DMFS_W_OK) worst = rc;
        }
    }
    if(worst == DMFS_W_OK) g_w.w_dir++;
    return worst;
}

/* --------------------------- запись данных -------------------------------------------------- */
static int wr_data(uint32_t lba, const uint8_t* buf)
{
    uint32_t dsec = lba - g_i.data_lba;
    uint32_t clus = 2u + (dsec >> g_spc_sh);
    int ei = ext_by_cluster(clus);
    dmfs_node_t* n;
    uint32_t off, want;

    if(ei < 0){
        /* Владельца ещё нет: имя не пришло. Складываем сектор и разберём при материализации. */
        if(spool_put(lba, buf) != 0){ g_msg = "DIVMMC: WRITE SPOOL FULL"; return DMFS_W_FULL; }
        g_msg = "DIVMMC: DATA HELD FOR NAME";
        return DMFS_W_OK;
    }
    n = &g_nodes[g_ext[ei].node];
    if(n->isdir) return wr_dir(g_ext[ei].node, ext_ordinal(ei, clus) * g_spc + ((dsec & (g_spc - 1u))), buf);
    if(n->flags & DMFS_NF_DEAD){ g_msg = "DIVMMC: WRITE TO DELETED FILE"; return DMFS_W_DATA; }

    off = ext_ordinal(ei, clus) * g_i.cluster_bytes + ((dsec & (g_spc - 1u))) * DMFS_SECSZ;
    if(node_path(g_ext[ei].node, g_wpath, DMFS_MAXPATH) < 0) return DMFS_W_FULL;
    if(!(n->flags & DMFS_NF_MAT)){
        int rc = materialize(g_ext[ei].node);
        if(rc != DMFS_W_OK) return rc;
    }
    if(off >= n->size){
        /* 🥇 Запись ЗА объявленный размер отбрасывать нельзя: драйвер вправе сначала налить
           данные, а размер поставить потом (esxDOS так и делает - создаёт запись нулевой длины
           и дописывает). Пишем целиком, а лишний хвост срежет ближайшее обновление записи
           каталога - оно приносит настоящий размер. */
        n->flags |= DMFS_NF_GREW;
        want = DMFS_SECSZ;
    } else {
        want = n->size - off; if(want > DMFS_SECSZ) want = DMFS_SECSZ;
    }
    if(bk_write(g_wpath, off, buf, want) != 0){ g_msg = "DIVMMC: CARD WRITE FAILED"; return DMFS_W_MEDIA; }
    g_w.w_data++;
    g_msg = "DIVMMC: DATA WRITTEN";
    return DMFS_W_OK;
}

int divmmc_fs_write(uint32_t lba, const uint8_t* buf)
{
    int a, rc;

    if(!g_ready){ g_msg = "DIVMMC: NO CARD"; return DMFS_W_NOTREADY; }
    g_w.w_total++;
    /* Приговорённые узлы живут ровно до конца ОДНОГО сектора каталога: если переименования не
       случилось, файл удаляется тут же, а не когда-нибудь потом. */
    g_wcall++;
    if(g_ncond) cond_settle(g_wcall);
    a = divmmc_fs_area(lba);
    if(a == DMFS_A_OUT){ g_msg = "DIVMMC: WRITE BEYOND CARD END"; g_w.w_rej++; return DMFS_W_OUTSIDE; }

    if(a == DMFS_A_MBR || a == DMFS_A_GAP || a == DMFS_A_BOOT){
        /* 🥇 Таблицу разделов и загрузочный сектор синтезируем МЫ - настоящего носителя за ними
           нет. Пишет туда только форматирование, а оно после загрузочного сектора идёт затирать
           таблицу, корень и данные. Поэтому первая же такая попытка ЗАПИРАЕТ том до
           перемонтирования: иначе mformat стёр бы папку нашими же руками. */
        lock_volume();
        g_w.w_rej++;
        return DMFS_W_FORMAT;
    }
    if(g_lock){ g_w.w_rej++; return refuse_locked(a, lba, buf); }

    switch(a){
      case DMFS_A_FAT:  rc = wr_fat(lba, buf); break;
      case DMFS_A_ROOT: rc = wr_dir(0, lba - g_i.root_lba, buf); break;
      default:          rc = wr_data(lba, buf); break;
    }
    if(rc == DMFS_W_OK) g_w.w_ok++; else g_w.w_rej++;
    g_w.spool_live = g_spool_live;
    g_w.orphan = g_spool_live;
    return rc;
}
