/* =================================================================================================
 * rom_ident.c - v0.15.384 РАСПОЗНАВАТЕЛЬ СТРАНИЦЫ ПЗУ. Подписи не придуманы, а СНЯТЫ С ФАЙЛОВ:
 * пять наборов PentoGraf (PGFATALL / PGPROTEU / PGGLUK66 / PGCLASSC / PENTGLUK), четыре одиночных
 * ПЗУ с карты Z-Controller (PROTEUS / FATALL26 / WDC126 / MINIBOOT) и корпус Sizif-512
 * (128-0, 128-1, 48, lg18alt, opense, negluk, zcen3e0..3, zxdiag, DiagROMv.171, ESXMMC.BIN).
 * Таблица прогона - в rom_ident_host_test.c, его вывод и есть доказательство.
 *
 * 🥇 ГОЧА, КОТОРАЯ СТОИЛА БЫ ПОЛОВИНЫ ПОДПИСЕЙ: у строк в ПЗУ Спектрума ПОСЛЕДНИЙ знак слова помечен
 * БИТОМ 7 (так у Sinclair устроены таблицы токенов и сообщений), а сервисные ПЗУ печатают собственные
 * строки то так, то так. Поэтому сравнение байт-в-байт ловит подпись через раз - ищем с ДОПУСКОМ на
 * старший бит в любом знаке. Ложные срабатывания этим не покупаются: подписи длинные (от 4 знаков),
 * а вероятность случайно собрать «GLUK» из кода - около 2e-9 на позицию.
 * ================================================================================================= */
#include "rom_ident.h"

static int ri_slen(const char* s){ int n=0; if(s) while(s[n]) n++; return n; }

static void ri_put(char* out, int outn, const char* s){
    if(!out || outn<=0) return;
    int i=0; for(; s[i] && i<outn-1; i++) out[i]=s[i];
    out[i]=0;
}

/* Поиск подписи с допуском на бит 7 (см. гочу в шапке). at != 0 - вернуть смещение находки. */
static int ri_find(const uint8_t* p, uint32_t n, const char* s, uint32_t* at){
    int m = ri_slen(s);
    if(m<=0 || (uint32_t)m > n) return 0;
    for(uint32_t i=0; i + (uint32_t)m <= n; i++){
        int k=0;
        while(k<m){
            uint8_t c = p[i+(uint32_t)k], w = (uint8_t)s[k];
            if(c != w && c != (uint8_t)(w | 0x80u)) break;
            k++;
        }
        if(k==m){ if(at) *at = i; return 1; }
    }
    return 0;
}

/* Дописать в метку «версию»: печатаемые знаки от позиции `at`, пока они печатаемые и не разделитель.
   Именно так вынимается «6.11Q» из баннера «* TR-DOS Ver 6.11Q*» и «v0.26» из «FATALL v0.26!». */
static void ri_append_ver(char* out, int outn, const uint8_t* p, uint32_t at, uint32_t lim, int maxv){
    if(!out || outn<=0) return;
    int o = ri_slen(out);
    if(o >= outn-2) return;
    int n = 0;
    while(at < lim && n < maxv && o < outn-1){
        uint8_t c = (uint8_t)(p[at] & 0x7Fu);
        if(c < 0x21u || c > 0x7Eu) break;                  /* пробел и управляющие = конец версии */
        if(c=='*' || c=='!' || c==',' || c=='#') break;     /* обрамление баннеров */
        out[o++] = (char)c; at++; n++;
    }
    out[o] = 0;
}

/* Сколько раз страница обращается к порту ULA #FE (`IN A,(#FE)` = DB FE, `OUT (#FE),A` = D3 FE).
   Тот же признак и тот же порог 2, что у rom_page_is_zx() в прошивке (см. комментарий v0.15.305:
   у прошивки ЧУЖОЙ карты (General Sound) их ровно ноль). */
static int ri_fe_ops(const uint8_t* p){
    int n = 0;
    for(uint32_t i=0; i+1 < ROM_PG_SZ; i++)
        if((p[i]==0xDBu || p[i]==0xD3u) && p[i+1]==0xFEu) n++;
    return n;
}

int rom_page_looks_zx(const uint8_t* p){
    if(ri_find(p, ROM_PG_SZ, "1986 Sinclair", 0)) return 1;
    if(ri_find(p, ROM_PG_SZ, "1982 Sinclair", 0)) return 1;
    if(ri_find(p, ROM_PG_SZ, "TR-DOS Ver", 0))    return 1;
    return (ri_fe_ops(p) >= 2) ? 1 : 0;
}

int rom_page_ident(const uint8_t* p, char* out, int outn){
    if(out && outn>0) out[0]=0;
    if(!p) { ri_put(out,outn,"NO DATA"); return RID_NOTZX; }

    /* --- 1. ПУСТАЯ СТРАНИЦА. Дешевле любой подписи и объясняет владельцу «а почему тут ничего»:
           в 64-КБ наборах пустое место встречается (лишняя страница добита 0xFF). --- */
    { uint32_t i=0; while(i<ROM_PG_SZ && p[i]==0xFFu) i++;
      if(i==ROM_PG_SZ){ ri_put(out,outn,"EMPTY (FF)"); return RID_EMPTY_FF; } }
    { uint32_t i=0; while(i<ROM_PG_SZ && p[i]==0x00u) i++;
      if(i==ROM_PG_SZ){ ri_put(out,outn,"EMPTY (00)"); return RID_EMPTY_00; } }

    uint32_t at = 0;
    /* --- 2. TR-DOS. Подпись СТРОГАЯ («TR-DOS Ver»), и это принципиально: слово «TR-DOS» без «Ver»
           живёт и в сервисных ПЗУ (сообщения «No disk»), и в 128-меню (строка пункта «TR-DOS»).
           Проверено на файлах: у PGFATALL слабое «TR-DOS» есть на страницах 0 и 2, а настоящий
           дисковод - только на 1. --- */
    if(ri_find(p, ROM_PG_SZ, "TR-DOS Ver", &at)){
        ri_put(out, outn, "TR-DOS ");
        uint32_t v = at + 10u;                                  /* сразу за «TR-DOS Ver» */
        while(v < ROM_PG_SZ && (p[v] & 0x7Fu) == ' ') v++;       /* пробелы баннера */
        ri_append_ver(out, outn, p, v, ROM_PG_SZ, 6);
        return RID_TRDOS;
    }
    /* --- 3. esxDOS (ПЗУ DivMMC). У ESXMMC.BIN подпись «ESXDOS» рядом с «[ERROR]»/«[OK]». --- */
    if(ri_find(p, ROM_PG_SZ, "ESXDOS", 0) || ri_find(p, ROM_PG_SZ, "esxDOS", 0)){
        ri_put(out,outn,"esxDOS"); return RID_ESXDOS;
    }
    /* --- 4. ДВЕ ПОДПИСИ SINCLAIR - ВЫШЕ СЕРВИСНЫХ. Порядок здесь не косметика: у PGPROTEU страница
           128-меню содержит и «Proteus» (пункт меню сервисного ПЗУ), и «1986 Sinclair». Если сначала
           спросить про Proteus, 128-меню будет названо сервисным ПЗУ. --- */
    if(ri_find(p, ROM_PG_SZ, "1986 Sinclair", 0)){ ri_put(out,outn,"128 MENU");  return RID_128MENU; }
    if(ri_find(p, ROM_PG_SZ, "1982 Sinclair", 0)){ ri_put(out,outn,"48 BASIC");  return RID_48BASIC; }

    /* --- 5. ИМЕНОВАННЫЕ СЕРВИСНЫЕ ПЗУ И МЕНЕДЖЕРЫ. --- */
    if(ri_find(p, ROM_PG_SZ, "FATALL", &at)){
        ri_put(out,outn,"FATALL ");
        uint32_t v = at + 6u, lim = at + 40u; if(lim > ROM_PG_SZ) lim = ROM_PG_SZ;
        while(v < lim && (p[v] & 0x7Fu) != 'v') v++;             /* «FATALLx v0.25!» / «FATALL v0.26!» */
        ri_append_ver(out, outn, p, v, lim, 6);
        return RID_FATALL;
    }
    if(ri_find(p, ROM_PG_SZ, "PROTEUS", 0) || ri_find(p, ROM_PG_SZ, "Proteus", 0)){
        ri_put(out,outn,"PROTEUS SVC"); return RID_PROTEUS;
    }
    if(ri_find(p, ROM_PG_SZ, "GLUK", 0) || ri_find(p, ROM_PG_SZ, "Gluk", 0)){
        ri_put(out,outn,"GLUK SERVICE"); return RID_GLUK;
    }
    if(ri_find(p, ROM_PG_SZ, "WDCSETUP", 0)){ ri_put(out,outn,"WDC SETUP"); return RID_WDC; }
    if(ri_find(p, ROM_PG_SZ, "DiagROM", 0) || ri_find(p, ROM_PG_SZ, "ZX-Diags", 0)
       || ri_find(p, ROM_PG_SZ, "Diagnostics", 0)){
        ri_put(out,outn,"DIAG ROM"); return RID_DIAG;
    }
    if(ri_find(p, ROM_PG_SZ, "SD_BOOT", 0)){ ri_put(out,outn,"SD BOOT"); return RID_SDBOOT; }

    /* --- 6. ОТПЕЧАТОК ТОЧКИ ВХОДА. Подписи может не быть вовсе (переделанные ПЗУ: zcen3e3 - это
           правленый 48 BASIC, у него строку Sinclair вырезали). Первые байты страницы при этом
           остаются: у 48 BASIC это `DI : XOR A : LD DE,#FFFF`, у 128-меню - `DI : LD BC,xxxx ... `
           с `DEC BC : LD A,B` на пятом-шестом байте. ⚠ Раскладку по слотам этим догадкам НЕ отдаём
           (rom_page_kind их не знает) - это только метка для владельца. --- */
    if(p[0]==0xF3u && p[1]==0xAFu && p[2]==0x11u && p[3]==0xFFu && p[4]==0xFFu){
        ri_put(out,outn,"48 BASIC (MOD)"); return RID_48MOD;
    }
    if(p[0]==0xF3u && p[1]==0x01u && p[4]==0x0Bu && p[5]==0x78u){
        ri_put(out,outn,"128 MENU (MOD)"); return RID_128MOD;
    }

    /* --- 7. Ничего не узнали. Отделяем «ПЗУ Спектрума, но незнакомое» (законный случай: сервисная
           страница набора PGCLASSC не содержит ни одной строки вовсе) от «это не ПЗУ Спектрума». --- */
    if(ri_fe_ops(p) >= 2){ ri_put(out,outn,"ZX ROM (?)"); return RID_UNKNOWN; }
    ri_put(out,outn,"NOT ZX ROM"); return RID_NOTZX;
}
