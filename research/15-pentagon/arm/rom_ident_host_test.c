/* rom_ident_host_test.c - ХОСТОВОЙ СТЕНД распознавателя страниц ПЗУ (rom_ident.c) и раскладки AUTO.
 *
 * Зачем. Метку страницы владелец УВИДИТ в диалоге «ROM file and banks», и соврать ей нельзя: по ней
 * он решает, что куда кладёт. Проверять это на плате - минуты за прогон и ни одного доказательства
 * (на экране либо поднялось, либо нет). Здесь прогон по НАСТОЯЩИМ файлам занимает секунду и печатает
 * таблицу «файл -> метка каждой страницы -> в какой слот уедет по содержимому».
 *
 * Второй судья, а не только метка: рядом печатается kind от НЕЗАВИСИМОЙ копии rom_page_kind() (те же
 * три строгие подписи, что в прошивке) и результат AUTO-раскладки тем же алгоритмом, что в
 * rom_load_set(). Разойдутся - видно сразу, и видно, что именно разошлось.
 *
 * Сборка и запуск (плата не нужна):
 *   gcc -O2 -Wall -o romident rom_ident_host_test.c rom_ident.c && ./romident [файлы...]
 * Без аргументов берёт корпус по умолчанию (/tmp/romget, /tmp/zcsoft, /tmp/sizif/rom).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "rom_ident.h"

#define PG ROM_PG_SZ
#define ROM_PG_N 4u

/* ---- НЕЗАВИСИМАЯ копия классификатора слотов из прошивки (loader_main.c:rom_page_kind). Копия, а не
   вызов: если она разойдётся с прошивкой, это сразу увидит человек, читающий таблицу. ---- */
static int hs_find(const uint8_t* p, uint32_t n, const char* s){
    size_t m = strlen(s);
    if(!m || m > n) return 0;
    for(uint32_t i=0; i + m <= n; i++){
        size_t k=0; while(k<m && p[i+k]==(uint8_t)s[k]) k++;
        if(k==m) return 1;
    }
    return 0;
}
static int hs_page_kind(const uint8_t* p){
    if(hs_find(p, PG, "TR-DOS Ver"))    return 2;
    if(hs_find(p, PG, "1986 Sinclair")) return 0;
    if(hs_find(p, PG, "1982 Sinclair")) return 1;
    return 3;
}
static const char* SLOTN[4] = {"0 128menu","1 48BASIC","2 TR-DOS","3 service"};

/* AUTO-раскладка - тот же алгоритм, что в rom_load_set() (страница по содержимому, остаток в порядке
   файла, слот 0 - ТОЛЬКО по содержимому). */
static void hs_auto_map(const uint8_t* kinds, uint32_t npg, int* pg){
    int used[ROM_PG_N];
    for(uint32_t s=0; s<ROM_PG_N; s++){ pg[s]=-1; used[s]=0; }
    for(uint32_t p=0; p<npg; p++){
        int k = kinds[p];
        if(k>=0 && k<(int)ROM_PG_N && pg[k] < 0){ pg[k]=(int)p; used[p]=1; }
    }
    if(npg > 1)
        for(uint32_t s=1; s<ROM_PG_N; s++){
            if(pg[s] >= 0) continue;
            for(uint32_t p=0; p<npg; p++) if(!used[p]){ pg[s]=(int)p; used[p]=1; break; }
        }
}

static int fails = 0;

static void one_file(const char* path){
    FILE* f = fopen(path, "rb");
    if(!f){ printf("  -- НЕТ ФАЙЛА: %s\n", path); return; }
    fseek(f,0,SEEK_END); long sz = ftell(f); fseek(f,0,SEEK_SET);
    static uint8_t buf[PG*ROM_PG_N];
    if(sz <= 0 || sz > (long)sizeof(buf) || (sz % (long)PG)){
        printf("%-22s %7ld  РАЗМЕР НЕ КРАТЕН 16 КБ - в список наборов не попадёт\n",
               strrchr(path,'/') ? strrchr(path,'/')+1 : path, sz);
        fclose(f); return;
    }
    if(fread(buf,1,(size_t)sz,f)!=(size_t)sz){ printf("  -- ЧТЕНИЕ ОБОРВАЛОСЬ: %s\n", path); fclose(f); return; }
    fclose(f);
    uint32_t npg = (uint32_t)(sz / (long)PG);
    uint8_t kinds[ROM_PG_N]; int pg[ROM_PG_N];
    for(uint32_t p=0;p<npg;p++) kinds[p] = (uint8_t)hs_page_kind(buf + p*PG);
    hs_auto_map(kinds, npg, pg);

    printf("%-22s %7ld  %u стр.\n", strrchr(path,'/') ? strrchr(path,'/')+1 : path, sz, npg);
    for(uint32_t p=0; p<npg; p++){
        char lbl[20];
        int id = rom_page_ident(buf + p*PG, lbl, sizeof(lbl));
        int zx = rom_page_looks_zx(buf + p*PG);
        /* в какой слот уедет ЭТА страница при AUTO */
        int slot = -1; for(uint32_t s=0;s<ROM_PG_N;s++) if(pg[s]==(int)p) slot=(int)s;
        printf("    стр.%u  %-15s id=%-2d kind=%d  ->  %s%s\n", p, lbl, id, kinds[p],
               slot>=0 ? SLOTN[slot] : "(не грузится)", zx ? "" : "   [не похоже на ПЗУ ZX]");
    }
    for(uint32_t s=0;s<ROM_PG_N;s++)
        if(npg>1 && pg[s] < 0) printf("    ! слот %s останется с ПРЕЖНИМ содержимым\n", SLOTN[s]);
}

/* Ожидания по пяти наборам PentoGraf: [0] менеджер/сервис, [1] TR-DOS, [2] 128-меню, [3] 48 BASIC. */
static void expect(const char* path, const int* want_id, const char* trdos_ver){
    FILE* f=fopen(path,"rb"); if(!f) return;
    static uint8_t buf[PG*ROM_PG_N];
    size_t got = fread(buf,1,sizeof(buf),f); fclose(f);
    if(got != sizeof(buf)) return;
    for(uint32_t p=0;p<ROM_PG_N;p++){
        char lbl[20]; int id = rom_page_ident(buf+p*PG, lbl, sizeof(lbl));
        if(want_id[p] >= 0 && id != want_id[p]){
            printf("  ОТКАЗ %s стр.%u: ожидали id=%d, получили id=%d (%s)\n",
                   path, p, want_id[p], id, lbl); fails++;
        }
        if(p==1 && trdos_ver){
            char want[24]; snprintf(want,sizeof(want),"TR-DOS %s",trdos_ver);
            if(strcmp(lbl,want)){ printf("  ОТКАЗ %s стр.1: ожидали «%s», получили «%s»\n",path,want,lbl); fails++; }
        }
    }
}

/* РУЧНАЯ РАСКЛАДКА - тот же контракт, что у rom_manual_map() в прошивке: rommap[слот] = номер страницы
   В ФАЙЛЕ, -1 = слот не грузить, страница за пределами файла = «не грузить». */
static void hs_manual_map(const int* rommap, uint32_t npg, int* pg){
    for(uint32_t s=0; s<ROM_PG_N; s++){
        int v = rommap[s];
        pg[s] = (v >= 0 && v < (int)npg) ? v : -1;
    }
}
static void manual_demo(const char* path, const int* rommap){
    FILE* f = fopen(path, "rb"); if(!f){ printf("  -- НЕТ ФАЙЛА: %s\n", path); return; }
    static uint8_t buf[PG*ROM_PG_N];
    fseek(f,0,SEEK_END); long sz = ftell(f); fseek(f,0,SEEK_SET);
    if(sz <= 0 || sz > (long)sizeof(buf) || fread(buf,1,(size_t)sz,f) != (size_t)sz){ fclose(f); return; }
    fclose(f);
    uint32_t npg = (uint32_t)(sz / (long)PG);
    int pg[ROM_PG_N]; hs_manual_map(rommap, npg, pg);
    printf("%s   MANUAL rommap = ", strrchr(path,'/') ? strrchr(path,'/')+1 : path);
    for(uint32_t s=0;s<ROM_PG_N;s++){ if(s) printf(","); if(pg[s]>=0) printf("%d",pg[s]); else printf("-"); }
    printf("\n");
    for(uint32_t s=0; s<ROM_PG_N; s++){
        if(pg[s] < 0){ printf("    слот %s  <- НЕ ГРУЗИТСЯ (останется прежнее содержимое)\n", SLOTN[s]); continue; }
        char lbl[20]; rom_page_ident(buf + (uint32_t)pg[s]*PG, lbl, sizeof(lbl));
        printf("    слот %s  <- стр.%d  %s\n", SLOTN[s], pg[s], lbl);
    }
}

int main(int argc, char** argv){
    static const char* corpus[] = {
        "/tmp/romget/PGFATALL.ROM", "/tmp/romget/PGPROTEU.ROM", "/tmp/romget/PGGLUK66.ROM",
        "/tmp/romget/PGCLASSC.ROM", "/tmp/romget/PENTGLUK.ROM",
        "/tmp/zcsoft/PROTEUS.ROM", "/tmp/zcsoft/FATALL26.ROM", "/tmp/zcsoft/WDC126.ROM",
        "/tmp/zcsoft/MINIBOOT.ROM",
        "/tmp/sizif/rom/128-0.rom", "/tmp/sizif/rom/128-1.rom", "/tmp/sizif/rom/128p-0.rom",
        "/tmp/sizif/rom/48.rom", "/tmp/sizif/rom/lg18alt.rom", "/tmp/sizif/rom/opense.rom",
        "/tmp/sizif/rom/negluk.rom", "/tmp/sizif/rom/zcen3e0.rom", "/tmp/sizif/rom/zcen3e1.rom",
        "/tmp/sizif/rom/zcen3e2.rom", "/tmp/sizif/rom/zcen3e3.rom", "/tmp/sizif/rom/zxdiag.rom",
        "/tmp/sizif/rom/DiagROMv.171", "/tmp/sizif/rom/S128_ZX80_ROM.bin",
        "/tmp/sizif/rom/ESXMMC.BIN", 0 };

    printf("=== РАСПОЗНАВАНИЕ СТРАНИЦ ПЗУ (rom_ident.c) =====================================\n");
    if(argc > 1) for(int i=1;i<argc;i++) one_file(argv[i]);
    else         for(int i=0; corpus[i]; i++) one_file(corpus[i]);

    if(argc <= 1){
        printf("\n=== СИНТЕТИКА ==================================================================\n");
        static uint8_t pg[PG]; char lbl[20]; int id;
        memset(pg,0xFF,PG); id = rom_page_ident(pg,lbl,sizeof(lbl));
        printf("    все 0xFF        %-15s id=%d\n", lbl, id);
        if(id != RID_EMPTY_FF){ printf("  ОТКАЗ: страница 0xFF не опознана как пустая\n"); fails++; }
        memset(pg,0x00,PG); id = rom_page_ident(pg,lbl,sizeof(lbl));
        printf("    все 0x00        %-15s id=%d\n", lbl, id);
        if(id != RID_EMPTY_00){ printf("  ОТКАЗ: страница 0x00 не опознана как пустая\n"); fails++; }

        printf("\n=== ОЖИДАНИЯ ПО НАБОРАМ PentoGraf ==============================================\n");
        { int w[4] = {RID_FATALL,  RID_TRDOS, RID_128MENU, RID_48BASIC};
          expect("/tmp/romget/PGFATALL.ROM", w, "6.11Q"); }
        { int w[4] = {RID_PROTEUS, RID_TRDOS, RID_128MENU, RID_48BASIC};
          expect("/tmp/romget/PGPROTEU.ROM", w, "6.11Q"); }
        { int w[4] = {RID_GLUK,    RID_TRDOS, RID_128MENU, RID_48BASIC};
          expect("/tmp/romget/PGGLUK66.ROM", w, "6.11Q"); }
        { int w[4] = {RID_GLUK,    RID_TRDOS, RID_128MENU, RID_48BASIC};
          expect("/tmp/romget/PENTGLUK.ROM", w, "6.11Q"); }
        { int w[4] = {-1,          RID_TRDOS, RID_128MENU, RID_48BASIC};   /* стр.0 без единой строки */
          expect("/tmp/romget/PGCLASSC.ROM", w, "5.03"); }
        printf("\n=== РУЧНАЯ РАСКЛАДКА (то, что делает MANUAL в диалоге) ========================\n");
        { int map1[ROM_PG_N] = { 2, 3, 1, 0 };      /* «как есть»: ровно то, что даёт AUTO у PentoGraf */
          manual_demo("/tmp/romget/PGPROTEU.ROM", map1); }
        { int map2[ROM_PG_N] = { 3, 2, 1, 0 };      /* переставить местами: 48 BASIC в слот 0 */
          manual_demo("/tmp/romget/PGPROTEU.ROM", map2); }
        { int map3[ROM_PG_N] = { -1, -1, -1, 0 };   /* одностраничный файл В ЛЮБОЙ слот - этого AUTO не умеет */
          manual_demo("/tmp/zcsoft/WDC126.ROM", map3); }
        { int map4[ROM_PG_N] = { 0, -1, -1, -1 };   /* тот же файл, но в загрузочный слот 0 */
          manual_demo("/tmp/zcsoft/FATALL26.ROM", map4); }
        printf(fails ? "\nИТОГ: ОТКАЗОВ %d\n" : "\nИТОГ: ожидания сошлись\n", fails);
    }
    return fails ? 1 : 0;
}
