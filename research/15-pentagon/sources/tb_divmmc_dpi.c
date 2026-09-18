/* tb_divmmc_dpi.c - мост стенда к ЭТАЛОНУ. Никакой второй реализации здесь нет и быть не должно:
 * файл только оборачивает `arm/divmmc_card.c` в вызовы, которые умеет звать xsim.
 *
 * Почему именно так, а не «переписать модель на SystemVerilog»: переписанная модель - это ВТОРАЯ
 * реализация, и она расходится с первой молча. Сверять RTL надо с тем самым кодом, который уже
 * прошёл 10 000 секторов на хосте и поднял настоящую esxDOS в ZEsarUX.
 *
 * Сборка: xsc tb_divmmc_dpi.c   (файл эталона включён текстом - у него все состояния статические,
 * так что второй единицы трансляции быть не должно).
 */
#include <stdint.h>
#include <string.h>

#include "divmmc_card.c"

/* --- носитель стенда ---------------------------------------------------------------------------
 * Содержимое сектора выводится из его номера, поэтому обе стороны стенда берут байты из ОДНОГО
 * источника: RTL наполняет буфер тем, что отдаёт эта же функция через DPI. Сравнивать «свои» данные
 * с «своими же» - единственный способ не поймать расхождение генераторов вместо расхождения схем.
 */
static uint32_t mix32(uint32_t x)
{
    x ^= x >> 16; x *= 0x7FEB352Du;
    x ^= x >> 15; x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}

static int tb_rd(uint32_t lba, uint8_t* buf)
{
    uint32_t i;
    for (i = 0; i < 512; i++) buf[i] = (uint8_t)(mix32(lba * 0x9E3779B1u + i) >> 13);
    return 0;
}

static uint8_t  g_wr_buf[512];
static uint32_t g_wr_lba;
static int      g_wr_cnt;

static int tb_wr(uint32_t lba, const uint8_t* buf)
{
    memcpy(g_wr_buf, buf, 512);
    g_wr_lba = lba;
    g_wr_cnt++;
    return 0;
}

/* --- то, что зовёт стенд ---------------------------------------------------------------------- */

void dm_attach(int vol_sectors)
{
    divmmc_card_attach((uint32_t)vol_sectors, tb_rd, tb_wr);
}

void dm_cs(int selected)        { divmmc_card_cs(selected); }
void dm_fast_ack(int on)        { divmmc_card_fast_ack(on); }   /* B0150 */
int  dm_xfer(int mosi)          { return (int)divmmc_card_xfer((uint8_t)(mosi & 0xFF)); }
int  dm_sectors(void)           { return (int)divmmc_card_sectors(); }
int  dm_state(void)             { return (int)((divmmc_card_dbg() >> 12) & 0x0F); }
int  dm_csd(int i)              { return divmmc_card_csd()[i & 15]; }
int  dm_cid(int i)              { return divmmc_card_cid()[i & 15]; }
int  dm_sector_byte(int lba, int i)
{
    return (int)(uint8_t)(mix32((uint32_t)lba * 0x9E3779B1u + (uint32_t)i) >> 13);
}
int  dm_wr_count(void)          { return g_wr_cnt; }
int  dm_wr_lba(void)            { return (int)g_wr_lba; }
int  dm_wr_byte(int i)          { return g_wr_buf[i & 511]; }
