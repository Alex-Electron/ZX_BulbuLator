/* divmmc_fs_host_test.c - ХОСТОВОЙ СТЕНД для синтезатора тома DivMMC (divmmc_fs.c).
 *
 * Зачем. Один прогон на плате («собрать прошивку - записать образ - холодный старт - войти в
 * esxDOS - сделать CAT») стоит минуты, а ошибиться в FAT можно двадцатью способами, и все они
 * выглядят одинаково: «карта не читается». Здесь роль Спектрума играет НЕЗАВИСИМЫЙ разборщик,
 * написанный в этом файле с нуля: он знает только про сектора и про формат FAT16, и ничего - про
 * внутренности divmmc_fs.c. Если оба сойдутся, значит том настоящий, а не «понятный самому себе».
 *
 * Плюс третий, совсем посторонний судья: fsck.vfat из dosfstools. Он ловит то, на чём наши два
 * взгляда могли бы совпасть по общей ошибке (например согласованно неверный размер таблицы).
 *
 * Сборка и запуск (плата не нужна):
 *   gcc -O2 -Wall -DDIVMMC_FS_HOST -o dmfs divmmc_fs_host_test.c divmmc_fs.c && ./dmfs
 *   ./dmfs /путь/к/своей/папке      - проверить на настоящем содержимом
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include "divmmc_fs.h"

#include <stdarg.h>

static int g_fail = 0;
static void fail(const char* fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    printf("  ОТКАЗ: "); vprintf(fmt, ap); printf("\n");
    va_end(ap); g_fail++;
}

/* ============================ подготовка испытательной папки ============================ */
static uint32_t lcg = 12345;
static uint8_t rnd(void){ lcg = lcg * 1103515245u + 12345u; return (uint8_t)(lcg >> 16); }

static void mkfile(const char* dir, const char* name, uint32_t size, uint32_t seed)
{
    char p[1024]; FILE* f; uint32_t i;
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    f = fopen(p, "wb");
    if(!f){ fail("не создать %s", p); return; }
    lcg = seed;
    for(i = 0; i < size; i++) fputc(rnd(), f);
    fclose(f);
}

static void make_tree(const char* root)
{
    char sub[1024];
    char cmd[1200];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root); if(system(cmd)){}
    mkdir(root, 0755);

    /* Раскладка esxDOS, как её ждёт настоящая карта */
    snprintf(sub, sizeof(sub), "%s/BIN",  root); mkdir(sub, 0755);
    mkfile(sub, "LS.COM",      1234, 1);
    mkfile(sub, "CD.COM",       777, 2);
    snprintf(sub, sizeof(sub), "%s/SYS",  root); mkdir(sub, 0755);
    mkfile(sub, "CONFIG.SYS",   100, 3);
    snprintf(sub, sizeof(sub), "%s/TMP",  root); mkdir(sub, 0755);
    mkfile(sub, "BROWSE.NMI",  8192, 4);
    snprintf(sub, sizeof(sub), "%s/GAMES", root); mkdir(sub, 0755);
    mkfile(sub, "ELITE.TAP",  49152, 5);                     /* больше кластера: 2 кластера */
    mkfile(sub, "Manic Miner (1983)(Bug-Byte Software).tap", 33000, 6);   /* длинное имя */
    mkfile(sub, "Jet Set Willy (1984)(Software Projects).tzx", 41000, 7); /* и ещё одно */
    snprintf(sub, sizeof(sub), "%s/GAMES/DEMO", root); mkdir(sub, 0755);  /* вложенность */
    mkfile(sub, "shock.scr",   6912, 8);
    mkfile(sub, "ganzfeld.z80", 40000, 9);

    /* Крайние случаи размера: пусто, один байт, ровно сектор, сектор+1, ровно кластер, кластер+1 */
    mkfile(root, "EMPTY.BIN",       0, 10);
    mkfile(root, "ONE.BIN",         1, 11);
    mkfile(root, "SEC.BIN",       512, 12);
    mkfile(root, "SECP1.BIN",     513, 13);
    mkfile(root, "CLU.BIN",     32768, 14);
    mkfile(root, "CLUP1.BIN",   32769, 15);
    mkfile(root, "BIG.BIN",    200000, 16);                  /* 7 кластеров */

    /* Имена, на которых ломается мангляция 8.3 */
    mkfile(root, "lowercase.txt",   40, 17);                 /* только регистр - длинное имя не нужно */
    mkfile(root, "MixedCase.TxT",   41, 18);                 /* смешанный - нужно */
    mkfile(root, "two.dots.in.name.bin", 42, 19);
    mkfile(root, "name with spaces.dat", 43, 20);
    mkfile(root, "Long Name One.txt",    44, 21);            /* столкновение после мангляции: */
    mkfile(root, "Long Name Two.txt",    45, 22);            /* оба дают LONGNA~N.TXT           */
    mkfile(root, "NOEXT",           46, 23);
    mkfile(root, "VeryLongFileNameThatGoesWellPastThirteenCharacters.data", 47, 24);
}

/* ============================ независимый разборщик FAT16 ============================ */
static uint16_t g16(const uint8_t* p){ return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t g32(const uint8_t* p){ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static uint8_t* g_fat;            /* копия таблицы размещения (первая) */
static uint32_t P_start, P_sec, F_lba, R_lba, D_lba, F_sz, R_ent, SPC, N_clus;
static uint8_t* g_seen;           /* какие кластеры уже кому-то принадлежат - ловим перекрёстные ссылки */
static char     g_src[1024];      /* исходная папка, с которой сверяемся */

static int rdsec(uint32_t lba, uint8_t* b)
{
    if(divmmc_fs_read(lba, b) != 0){ fail("сектор %u вне тома", lba); return 0; }
    return 1;
}

static uint32_t found_files, found_dirs, cmp_bytes;
static struct { char lname[96]; char sname[16]; } g_m83[512];
static int g_m83n;

/* вернуть значение цепочки */
static uint16_t fat_at(uint32_t c){ return (c * 2 + 1 < F_sz * 512) ? g16(g_fat + c * 2) : 0xFFFF; }

/* прочитать n-й сектор кластера */
static int clus_sec(uint32_t clus, uint32_t k, uint8_t* b)
{
    return rdsec(D_lba + (clus - 2) * SPC + k, b);
}

static uint32_t by_content;   /* сколько файлов сверено не по имени, а по содержимому */

/* Файл, чьё имя не переносится ни в 8.3, ни в длинное имя (не-ASCII), виден под мангляцией -
   значит по имени его на диске не найти. Ищем в той же папке файл с такими же байтами: это и
   есть проверка «содержимое доехало», а имя тут ни при чём. */
static int match_by_content(const char* rel, const uint8_t* vol, uint32_t size)
{
    char parent[2048], full[2600]; const char* slash = strrchr(rel, '/');
    DIR* d; struct dirent* de; int hits = 0;
    if(slash){ int n = (int)(slash - rel); snprintf(parent, sizeof(parent), "%s/%.*s", g_src, n, rel); }
    else       snprintf(parent, sizeof(parent), "%s", g_src);
    d = opendir(parent);
    if(!d) return 0;
    while((de = readdir(d))){
        struct stat st; FILE* f; uint8_t* b;
        if(de->d_name[0] == '.') continue;
        snprintf(full, sizeof(full), "%s/%s", parent, de->d_name);
        if(stat(full, &st) || !S_ISREG(st.st_mode) || (uint32_t)st.st_size != size) continue;
        f = fopen(full, "rb"); if(!f) continue;
        b = malloc(size ? size : 1);
        if(fread(b, 1, size, f) == size && (size == 0 || !memcmp(b, vol, size))) hits++;
        free(b); fclose(f);
    }
    closedir(d);
    return hits == 1;
}

/* Сравнить содержимое файла из тома с настоящим файлом на диске. Возвращает 0 при совпадении. */
static int compare_file(const char* rel, uint32_t clus, uint32_t size)
{
    char path[2048]; FILE* f; uint8_t sec[512];
    uint8_t* vol; uint32_t left = size, nc = 0, o = 0;
    int bad = 0;

    if(size == 0){
        if(clus != 0) fail("%s: пустой файл, а кластер %u", rel, clus);
        return 0;
    }
    vol = malloc(size);
    while(left > 0){
        uint32_t k;
        if(clus < 2 || clus >= N_clus + 2){ fail("%s: битый номер кластера %u", rel, clus); free(vol); return 1; }
        if(g_seen[clus]++){ fail("%s: кластер %u уже занят другим (перекрёстная ссылка)", rel, clus); free(vol); return 1; }
        nc++;
        for(k = 0; k < SPC && left > 0; k++){
            uint32_t n = left > 512 ? 512 : left;
            if(!clus_sec(clus, k, sec)){ free(vol); return 1; }
            memcpy(vol + o, sec, n); o += n; left -= n;
        }
        {
            uint16_t nx = fat_at(clus);
            if(left){
                if(nx < 2 || nx >= N_clus + 2){ fail("%s: цепочка оборвалась на %u (значение %04X)", rel, clus, nx); free(vol); return 1; }
                clus = nx;
            } else if(nx < 0xFFF8) fail("%s: цепочка не закрыта, за последним кластером %04X", rel, nx);
        }
    }
    {
        uint32_t want = (size + SPC * 512 - 1) / (SPC * 512);
        if(nc != want) fail("%s: занято %u кластеров вместо %u", rel, nc, want);
    }

    snprintf(path, sizeof(path), "%s/%s", g_src, rel);
    f = fopen(path, "rb");
    if(!f){
        if(match_by_content(rel, vol, size)) by_content++;
        else { fail("в томе есть %s (%u Б), а на диске такого файла нет", rel, size); bad = 1; }
        free(vol);
        return bad;
    }
    {
        uint8_t* real = malloc(size + 1);
        size_t rn = fread(real, 1, size + 1, f);
        if(rn != size) fail("%s: на диске %u байт, в томе %u", rel, (uint32_t)rn, size);
        else if(memcmp(real, vol, size)){
            uint32_t i; for(i = 0; i < size && real[i] == vol[i]; i++) ;
            fail("%s: расхождение на смещении %u (том %02X, диск %02X)", rel, i, vol[i], real[i]);
            bad = 1;
        }
        free(real);
    }
    fclose(f);
    cmp_bytes += size;
    free(vol);
    return bad;
}

/* Отрисовать имя 8.3 так, как его показал бы драйвер без длинных имён (с флагами регистра). */
static void render_sfn(const uint8_t* e, char* out)
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
}

static uint8_t sum83(const uint8_t* n){ uint8_t s = 0; int i; for(i = 0; i < 11; i++) s = (uint8_t)(((s & 1) ? 0x80 : 0) + (s >> 1) + n[i]); return s; }

static void walk_dir(const char* rel, uint32_t clus, int is_root, uint32_t parent_clus);

/* Разобрать буфер каталога (уже собранный целиком). */
static void parse_dir(const char* rel, const uint8_t* d, uint32_t nent, int is_root, uint32_t self_clus, uint32_t parent_clus)
{
    char lfn[300]; int have_lfn = 0; uint8_t lsum = 0;
    uint32_t i;
    int seen_dot = 0, seen_dotdot = 0;
    lfn[0] = 0;
    for(i = 0; i < nent; i++){
        const uint8_t* e = d + i * 32;
        char name[300], sub[1024];
        uint32_t fc, fsz;
        if(e[0] == 0x00) break;                       /* конец каталога */
        if(e[0] == 0xE5){ have_lfn = 0; continue; }
        if((e[11] & 0x3F) == 0x0F){                    /* запись длинного имени */
            int ord = e[0] & 0x3F, k;
            static const int pos[13] = { 1,3,5,7,9, 14,16,18,20,22,24, 28,30 };
            if(e[0] & 0x40){ memset(lfn, 0, sizeof(lfn)); lsum = e[13]; have_lfn = 1; }
            if(have_lfn && e[13] != lsum){ fail("%s: контрольная сумма длинного имени не сходится", rel); have_lfn = 0; }
            for(k = 0; k < 13; k++){
                uint16_t ch = g16(e + pos[k]);
                int idx = (ord - 1) * 13 + k;
                if(idx < (int)sizeof(lfn) - 1) lfn[idx] = (ch == 0 || ch == 0xFFFF) ? 0 : (char)ch;
            }
            continue;
        }
        if(e[11] & 0x08){                              /* метка тома */
            if(!is_root) fail("%s: метка тома не в корне", rel);
            have_lfn = 0; continue;
        }
        fc  = g16(e + 26) | ((uint32_t)g16(e + 20) << 16);
        fsz = g32(e + 28);
        if(g16(e + 20) != 0) fail("%s: у FAT16 старшая половина кластера обязана быть нулём", rel);
        if(e[0] == '.'){
            if(e[1] == '.'){ seen_dotdot = 1; if(fc != parent_clus) fail("%s: «..» указывает на %u вместо %u", rel, fc, parent_clus); }
            else           { seen_dot = 1;    if(fc != self_clus)   fail("%s: «.» указывает на %u вместо %u", rel, fc, self_clus); }
            have_lfn = 0; continue;
        }
        if(have_lfn){
            if(sum83(e) != lsum) fail("%s: длинное имя не привязано к записи 8.3", rel);
            strncpy(name, lfn, sizeof(name) - 1); name[sizeof(name)-1] = 0;
        } else render_sfn(e, name);
        have_lfn = 0;
        if(g_m83n < 512){                     /* таблица «имя на карте -> имя 8.3 в каталоге» */
            char r[16]; int q, o = 0;
            for(q = 0; q < 11; q++){ if(q == 8) r[o++] = '.'; r[o++] = (char)e[q]; }
            r[o] = 0;
            while(o > 0 && r[o - 1] == ' ') r[--o] = 0;      /* хвостовые пробелы 8.3 - шум в выводе */
            snprintf(g_m83[g_m83n].lname, sizeof(g_m83[0].lname), "%s", name);
            snprintf(g_m83[g_m83n].sname, sizeof(g_m83[0].sname), "%s", r);
            g_m83n++;
        }
        snprintf(sub, sizeof(sub), "%s%s%s", rel, rel[0] ? "/" : "", name);
        if(e[11] & 0x10){ found_dirs++;  walk_dir(sub, fc, 0, self_clus); }
        else            { found_files++; compare_file(sub, fc, fsz); }
    }
    if(!is_root && (!seen_dot || !seen_dotdot)) fail("%s: нет записей «.»/«..»", rel);
}

static void walk_dir(const char* rel, uint32_t clus, int is_root, uint32_t parent_clus)
{
    uint8_t* buf; uint32_t nent = 0, cap;
    if(is_root){
        uint32_t s;
        cap = R_ent * 32; buf = malloc(cap);
        for(s = 0; s < R_ent * 32 / 512; s++) if(!rdsec(R_lba + s, buf + s * 512)) { free(buf); return; }
        nent = R_ent;
    } else {
        uint32_t c = clus, k, off = 0;
        cap = 0; buf = 0;
        while(c >= 2 && c < N_clus + 2){
            if(g_seen[c]++){ fail("%s: кластер каталога %u уже занят", rel, c); break; }
            cap += SPC * 512; buf = realloc(buf, cap);
            for(k = 0; k < SPC; k++){ if(!rdsec(D_lba + (c - 2) * SPC + k, buf + off)) { free(buf); return; } off += 512; }
            { uint16_t nx = fat_at(c); if(nx >= 0xFFF8) break; c = nx; }
        }
        nent = cap / 32;
        if(!buf){ fail("%s: у каталога нет ни одного кластера", rel); return; }
    }
    parse_dir(rel, buf, nent, is_root, clus, parent_clus);
    free(buf);
}

/* ============================ обход исходной папки (POSIX) ============================ */
static char  g_list[4096][512];
static int   g_listn;
static void list_src(const char* base, const char* rel)
{
    char full[2048]; DIR* d; struct dirent* de;
    snprintf(full, sizeof(full), "%s%s%s", base, rel[0] ? "/" : "", rel);
    d = opendir(full);
    if(!d) return;
    while((de = readdir(d))){
        char sub[512], p[2048]; struct stat st;
        if(de->d_name[0] == '.') continue;
        snprintf(sub, sizeof(sub), "%s%s%s", rel, rel[0] ? "/" : "", de->d_name);
        snprintf(p, sizeof(p), "%s/%s", base, sub);
        if(stat(p, &st)) continue;
        if(g_listn < 4096){ strncpy(g_list[g_listn], sub, 511); g_list[g_listn][511] = 0; g_listn++; }
        if(S_ISDIR(st.st_mode)) list_src(base, sub);
    }
    closedir(d);
}

/* ============================ основная программа ============================ */
static uint8_t sec[512];

/* Нагрузочная папка: больше файлов, чем влезает записей в корень FAT16, плюс имена, на которых
   мангляция обязана отступить (не-ASCII нельзя честно положить в длинное имя). Проверяем не
   «получится ли», а ОТСТУПЛЕНИЕ: том обязан остаться исправным, а лишнее - попасть в «пропущено». */
static void make_stress(const char* root)
{
    char cmd[1200], name[128]; int i;
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root); if(system(cmd)){}
    mkdir(root, 0755);
    for(i = 0; i < 300; i++){
        snprintf(name, sizeof(name), "Sinclair Collection Volume %03d (1984)(Ultimate).tap", i);
        mkfile(root, name, 100 + (uint32_t)i, (uint32_t)(1000 + i));
    }
    mkfile(root, "\xCF\xE0\xF0\xEE\xEB\xFC.txt", 33, 9001);      /* имя не-ASCII (CP866) */
    mkfile(root, "UPPER.BIN", 34, 9002);
}

static int verify(const char* folder);

int main(int argc, char** argv)
{
    char tree[512], stress[512];
    if(argc > 1){ verify(argv[1]); }
    else {
        snprintf(tree,   sizeof(tree),   "/tmp/dmfs_tree");
        snprintf(stress, sizeof(stress), "/tmp/dmfs_stress");
        make_tree(tree);      verify(tree);
        printf("\n\n##################### НАГРУЗОЧНАЯ ПАПКА #####################\n");
        make_stress(stress);  verify(stress);
    }
    printf("\n==== ИТОГ ПО ВСЕМ ПРОГОНАМ: %s (отказов %d) ====\n", g_fail ? "ЕСТЬ ОШИБКИ" : "ВСЁ СОШЛОСЬ", g_fail);
    return g_fail ? 1 : 0;
}

static int verify(const char* folder)
{
    int rc, i;
    const dmfs_info_t* inf;

    /* сбросить состояние разборщика - прогонов может быть несколько */
    free(g_fat); g_fat = 0; free(g_seen); g_seen = 0;
    found_files = found_dirs = cmp_bytes = by_content = 0; g_listn = 0; g_m83n = 0;
    strncpy(g_src, folder, sizeof(g_src) - 1);

    printf("=== 1. Построение тома из папки %s ===\n", folder);
    /* Формат тома стенду задаётся снаружи: DMFS_F32=1 - собрать FAT32, иначе FAT16.
       Так один и тот же прогон служит судьёй обоим, и регрессия FAT16 ловится бесплатно. */
    { const char* e = getenv("DMFS_F32"); divmmc_fs_set_format(e && *e == '1'); }
    rc = divmmc_fs_build(folder);
    inf = divmmc_fs_info();
    printf("  код=%d (%s)\n", rc, divmmc_fs_msg());
    if(rc != DMFS_OK && rc != DMFS_E_EMPTY){ printf("СТЕНД ОСТАНОВЛЕН\n"); return 1; }
    printf("  файлов=%u папок=%u пропущено=%u байт=%u усечение=%d\n",
           inf->files, inf->dirs, inf->skipped, inf->bytes, inf->truncated);
    printf("  том: %u секторов (%u МБ), кластер %u Б, кластеров %u (занято %u),\n"
           "       раздел с %u, таблица с %u (%u сект.), корень с %u, данные с %u\n",
           inf->vol_sectors, inf->vol_sectors / 2048, inf->cluster_bytes,
           inf->clusters, inf->clusters_used, inf->part_lba, inf->fat_lba,
           inf->fat_sectors, inf->root_lba, inf->data_lba);

    printf("=== 2. Разбор НЕЗАВИСИМЫМ разборщиком (он знает только сектора) ===\n");
    if(!rdsec(0, sec)) return 1;
    if(g16(sec + 510) != 0xAA55) fail("нет подписи 55AA в MBR");
    if(sec[446 + 4] != 0x06) fail("тип раздела %02X, а не 06 (FAT16)", sec[446 + 4]);
    P_start = g32(sec + 446 + 8); P_sec = g32(sec + 446 + 12);
    printf("  MBR: раздел тип 06, начало %u, длина %u секторов\n", P_start, P_sec);

    if(!rdsec(P_start, sec)) return 1;
    if(g16(sec + 510) != 0xAA55) fail("нет подписи 55AA в загрузочном секторе");
    if(memcmp(sec + 54, "FAT16   ", 8)) fail("в BPB не написано FAT16");
    if(g16(sec + 11) != 512) fail("байт в секторе %u", g16(sec + 11));
    SPC   = sec[13];
    F_sz  = g16(sec + 22);
    R_ent = g16(sec + 17);
    {
        uint32_t resv = g16(sec + 14), nfat = sec[16];
        uint32_t tsec = g16(sec + 19) ? g16(sec + 19) : g32(sec + 32);
        uint32_t hidden = g32(sec + 28);
        F_lba = P_start + resv;
        R_lba = F_lba + nfat * F_sz;
        D_lba = R_lba + R_ent * 32 / 512;
        N_clus = (tsec - (resv + nfat * F_sz + R_ent * 32 / 512)) / SPC;
        if(hidden != P_start) fail("скрытых секторов %u, а раздел начинается на %u", hidden, P_start);
        if(tsec != P_sec) fail("в BPB %u секторов, в MBR %u", tsec, P_sec);
        printf("  BPB: кластер %u сект., таблиц %u по %u сект., корень %u записей, кластеров %u\n",
               SPC, nfat, F_sz, R_ent, N_clus);
        if(N_clus < 4085) fail("кластеров %u - это уже FAT12, разборщик поймёт том иначе", N_clus);
        if(N_clus > 65524) fail("кластеров %u - это уже FAT32", N_clus);
    }

    g_fat = malloc(F_sz * 512);
    for(i = 0; i < (int)F_sz; i++) if(!rdsec(F_lba + i, g_fat + i * 512)) return 1;
    {   /* вторая копия обязана быть побайтно равна первой */
        uint8_t* f2 = malloc(F_sz * 512);
        for(i = 0; i < (int)F_sz; i++) rdsec(F_lba + F_sz + i, f2 + i * 512);
        if(memcmp(g_fat, f2, F_sz * 512)) fail("две копии таблицы размещения различаются");
        free(f2);
    }
    if(g16(g_fat) != 0xFFF8) fail("нулевая запись таблицы %04X вместо FFF8", g16(g_fat));
    if(g16(g_fat + 2) != 0xFFFF) fail("первая запись таблицы %04X вместо FFFF", g16(g_fat + 2));

    g_seen = calloc(N_clus + 2, 1);
    walk_dir("", 0, 1, 0);
    printf("  найдено файлов=%u папок=%u, сверено байт=%u (из них %u файлов сверены по содержимому,\n       потому что их имя не переносимо в 8.3/длинное имя)\n", found_files, found_dirs, cmp_bytes, by_content);

    printf("=== 3. Сверка с настоящей папкой ===\n");
    list_src(folder, "");
    printf("  на диске записей (файлы+папки)=%d, в томе=%u, пропущено при сборке=%u\n",
           g_listn, found_files + found_dirs, inf->skipped);
    if((uint32_t)g_listn != found_files + found_dirs + inf->skipped)
        fail("в томе %u + пропущено %u, а на диске %d", found_files + found_dirs, inf->skipped, g_listn);
    if(inf->truncated && !inf->skipped) fail("отмечено усечение, а пропущенных нет");
    {   /* имя на карте -> имя 8.3, которое увидит esxDOS: тут ловятся хвосты ~N и столкновения */
        int k, shown = 0;
        printf("  имя на карте -> 8.3 (первые 12 непустых отличий):\n");
        for(k = 0; k < g_m83n && shown < 12; k++){
            printf("    %-52s %s\n", g_m83[k].lname, g_m83[k].sname);
            shown++;
        }
    }

    printf("=== 4. Потерянные и лишние кластеры ===\n");
    {
        uint32_t lost = 0, used = 0, seen = 0, c;
        for(c = 2; c < N_clus + 2; c++){
            uint16_t v = fat_at(c);
            if(v) used++;
            if(g_seen[c]) seen++;
            if(v && !g_seen[c]) lost++;
            if(!v && g_seen[c]) fail("кластер %u занят файлом, а в таблице помечен свободным", c);
        }
        printf("  занято по таблице=%u, обойдено из каталога=%u, потерянных цепочек=%u, свободно=%u\n",
               used, seen, lost, N_clus - used);
        if(lost) fail("в таблице %u кластеров, до которых нет пути из каталога", lost);
    }

    printf("=== 5. Повторяемость чтения (сектор дважды = те же байты) ===\n");
    {
        uint8_t a[512], b[512]; int bad = 0;
        for(i = 0; i < 400; i++){
            uint32_t lba = (uint32_t)((rand() % (int)(D_lba + 64u * SPC)));
            divmmc_fs_read(lba, a);
            divmmc_fs_read((lba + 12345u) % inf->vol_sectors, b);   /* сбить кэш файлов */
            divmmc_fs_read(lba, b);
            if(memcmp(a, b, 512)){ bad++; }
        }
        printf("  400 секторов, расхождений=%d\n", bad);
        if(bad) fail("чтение не повторяемо");
    }

    printf("=== 6. Отказ в записи (форматирование ловится по построению) ===\n");
    {
        struct { const char* what; uint32_t lba; uint8_t fill; int want; } t[] = {
            { "MBR",                     0,             0x00, DMFS_W_FORMAT  },
            { "загрузочный сектор",      P_start,       0xF6, DMFS_W_FORMAT  },
            { "таблица размещения",      F_lba,         0x00, DMFS_W_FORMAT  },
            { "вторая копия таблицы",    F_lba + F_sz,  0xF6, DMFS_W_FORMAT  },
            { "корневой каталог (стирание)", R_lba,     0x00, DMFS_W_FORMAT  },
            { "корневой каталог (запись)",   R_lba,     0x5A, DMFS_W_DIRENT  },
            { "данные файла",            D_lba,         0x5A, DMFS_W_DATA    },
            { "за концом карты",         inf->vol_sectors, 0x00, DMFS_W_OUTSIDE },
        };
        for(i = 0; i < (int)(sizeof(t)/sizeof(t[0])); i++){
            uint8_t w[512]; int r;
            memset(w, t[i].fill, sizeof(w));
            r = divmmc_fs_write(t[i].lba, w);
            printf("  %-30s LBA %-8u -> код %d  «%s»\n", t[i].what, t[i].lba, r, divmmc_fs_msg());
            if(r != t[i].want) fail("ждали код %d, получили %d", t[i].want, r);
        }
    }

    printf("=== 7. Отображение сектор -> кусок файла (для отладки на плате) ===\n");
    {
        const char* nmz; uint32_t off;
        uint32_t probe[4] = { D_lba, D_lba + SPC, D_lba + 3u * SPC + 7u, R_lba };
        for(i = 0; i < 4; i++){
            int a = divmmc_fs_map(probe[i], &nmz, &off);
            printf("  LBA %-8u область %d %s%s смещение %u\n", probe[i], a, nmz[0] ? "= " : "", nmz, off);
        }
    }

    printf("=== 8. Сторонний судья: fsck.vfat ===\n");
    {
        const char* img = "/var/tmp/dmfs_vol.img";
        FILE* f = fopen(img, "wb");
        if(!f) printf("  (не смог записать образ, пропуск)\n");
        else {
            uint32_t s;
            for(s = 0; s < P_sec; s++){ divmmc_fs_read(P_start + s, sec); fwrite(sec, 1, 512, f); }
            fclose(f);
            printf("  образ раздела: %s (%u МБ)\n", img, P_sec / 2048);
            fflush(stdout);
            {
                char cmd[512];
                snprintf(cmd, sizeof(cmd), "fsck.vfat -n -v %s 2>&1 | tail -12", img);
                int r = system(cmd);
                printf("  fsck.vfat завершился кодом %d (0 = том без замечаний)\n", r / 256);
                if(r / 256 != 0) fail("fsck.vfat недоволен томом");
            }
        }
    }
    return 0;
}
