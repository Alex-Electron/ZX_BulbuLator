/* esx_loop_bench.c - ЦИКЛ ОЖИДАНИЯ esxDOS 0.8.9 ПРОТИВ МОДЕЛИ КАРТЫ (B0150, диагноз .mkdir 35 с).
 *
 * Зачем. После записи сектора esxDOS ждёт конца занятости карты подпрограммой 1E55 (ESXMMC.ROM):
 *   LD BC,#0032 / IN A,(#EB) / CP #FF / RET NZ / DJNZ / DEC C / JR NZ  - «первый байт ≠ FF, иначе
 *   12 800 чтений», а вызывающий 1EC2 крутит её, пока возвращается 0 (OR A / JR Z).
 * Карта по спеке SD после data-response отдаёт 0x00 (занята), затем 0xFF - байта ≠FF не будет никогда,
 * и цикл всегда доходит до таймаута: 12 800 × 36 тактов Z80 = 132 мс на КАЖДЫЙ сектор.
 * Здесь тот же цикл исполняется против C-эталона карты (arm/divmmc_card.c) в двух режимах:
 *   SPEC - как настоящая карта; FAST (B0150, DMMC_CTL[15]) - последний байт занятости 0x01.
 * Результат при написании: SPEC=12807 чтений/сектор, FAST=7. Сборка и запуск (ThinkPad):
 *   gcc -O2 -o /tmp/esxloop esx_loop_bench.c && /tmp/esxloop
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#define DIVMMC_FS_HOST 1
#include "divmmc_card.c"
static int be_rd(uint32_t l, uint8_t* b){ (void)l; memset(b,0,512); return 0; }
static int be_wr(uint32_t l, const uint8_t* b){ (void)l;(void)b; return 0; }
static uint32_t reads;
static uint8_t inp(void){ reads++; return divmmc_card_xfer(0xFF); }
static void out(uint8_t v){ divmmc_card_xfer(v); }
/* 1E55: LD BC,#0032 ; loop: IN A,(EB) ; CP FF ; RET NZ ; DJNZ ; DEC C ; JR NZ */
static uint8_t sub_1e55(void){ uint8_t a=0xFF; int b=0, c=0x32; do{ do{ a=inp(); if(a!=0xFF) return a; b=(b-1)&255; }while(b); c--; }while(c); return a; }
static void cmd(uint8_t c, uint32_t arg, uint8_t crc){ out(c); out(arg>>24); out(arg>>16); out(arg>>8); out(arg); out(crc); }
static uint32_t one_sector(int fast){
    divmmc_card_fast_ack(fast);
    reads = 0;
    divmmc_card_cs(1);
    cmd(0x58, 0x1000, 0xFF);                 /* CMD24 */
    uint8_t r1 = sub_1e55();
    out(0xFE); for(int i=0;i<512;i++) out(0x00); out(0xFF); out(0xFF);
    uint8_t dr = sub_1e55();                 /* 1EB6: data response */
    if((dr & 0x1F) != 0x05) printf("  data-response %02X (R1=%02X)\n", dr, r1);
    uint8_t a; do { a = sub_1e55(); } while(a == 0);   /* 1EC2: OR A ; JR Z */
    divmmc_card_cs(0);
    return reads;
}
int main(void){
    divmmc_card_attach(65536, be_rd, be_wr);
    /* инициализация как esxDOS: CMD0, CMD8, CMD55+ACMD41 до готовности */
    divmmc_card_cs(1); for(int i=0;i<10;i++) out(0xFF); cmd(0x40,0,0x95); sub_1e55(); divmmc_card_cs(0);
    divmmc_card_cs(1); cmd(0x48,0x1AA,0x87); sub_1e55(); for(int i=0;i<4;i++) inp(); divmmc_card_cs(0);
    for(int k=0;k<8;k++){ divmmc_card_cs(1); cmd(0x77,0,1); sub_1e55(); cmd(0x69,0x40000000,1); uint8_t r=sub_1e55(); divmmc_card_cs(0); if(r==0) break; }
    uint32_t s = one_sector(0), f = one_sector(1);
    printf("чтений порта на один записанный сектор:  SPEC=%u  FAST=%u\n", s, f);
    printf("при 10.3 мкс на итерацию: SPEC=%.1f мс  FAST=%.2f мс; .mkdir 264 сектора: SPEC=%.1f с FAST=%.2f с\n",
           s*10.3/1000, f*10.3/1000, s*10.3*264/1e6, f*10.3*264/1e6);
    return 0;
}
