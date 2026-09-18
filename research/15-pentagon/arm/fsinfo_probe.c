/* fsinfo_probe.c - точечная проверка сектора FSInfo синтезируемого тома FAT32.
 *
 * Зачем: FATALL v0.26 встал на «Find first free cluster», прочитав именно этот сектор, когда мы
 * отдавали в нём 0xFFFFFFFF «неизвестно». Стенд divmmc_fs_host_test.c умеет только FAT16, то есть
 * FSInfo не проверяет вовсе. Здесь читаем сектор глазами чужой стороны: подписи, число свободных
 * кластеров и первый свободный - и сверяем их с тем, что синтезатор сам говорит про том.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "divmmc_fs.h"

static uint32_t rd32(const uint8_t* p){ return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
static uint16_t rd16(const uint8_t* p){ return (uint16_t)(p[0] | (p[1]<<8)); }

int main(int argc, char** argv)
{
    const char* folder = (argc > 1) ? argv[1] : ".";
    uint8_t mbr[512], boot[512], fsi[512];
    const dmfs_info_t* in;
    uint32_t part, rsvd, fsi_lba, root_clus, free_cnt, next_free;
    int fails = 0;

    divmmc_fs_set_format(1);                        /* FAT32 - только у него есть FSInfo */
    if(divmmc_fs_build(folder) < 0){ printf("build failed: %s\n", divmmc_fs_msg()); return 2; }
    in = divmmc_fs_info();

    if(divmmc_fs_read(0, mbr) != 0){ printf("read MBR failed\n"); return 2; }
    part = rd32(mbr + 446 + 8);
    printf("раздел: тип 0x%02X, начало LBA %u, секторов %u\n", mbr[446+4], part, rd32(mbr+446+12));
    if(mbr[446+4] != 0x0C) { printf("  ОТКАЗ: тип раздела не 0x0C (FAT32 LBA)\n"); fails++; }

    if(divmmc_fs_read(part, boot) != 0){ printf("read boot failed\n"); return 2; }
    rsvd      = rd16(boot + 14);
    root_clus = rd32(boot + 44);
    fsi_lba   = part + rd16(boot + 48);
    printf("загрузочный: резерв %u, корень в кластере %u, FSInfo в секторе %u (+%u)\n",
           rsvd, root_clus, fsi_lba, rd16(boot + 48));
    if(root_clus != 2) { printf("  ОТКАЗ: RootClus != 2\n"); fails++; }

    if(divmmc_fs_read(fsi_lba, fsi) != 0){ printf("read FSInfo failed\n"); return 2; }
    free_cnt  = rd32(fsi + 488);
    next_free = rd32(fsi + 492);
    printf("FSInfo: подписи %08X / %08X / хвост %02X%02X\n",
           rd32(fsi + 0), rd32(fsi + 484), fsi[510], fsi[511]);
    printf("        свободных кластеров = %u, следующий свободный = %u\n", free_cnt, next_free);
    printf("том:    всего кластеров = %u, занято = %u (то есть свободно %u, первый свободный %u)\n",
           in->clusters, in->clusters_used, in->clusters - in->clusters_used, in->clusters_used + 2);

    if(rd32(fsi + 0)   != 0x41615252u) { printf("  ОТКАЗ: подпись RRaA\n"); fails++; }
    if(rd32(fsi + 484) != 0x61417272u) { printf("  ОТКАЗ: подпись rrAa\n"); fails++; }
    if(fsi[510] != 0x55 || fsi[511] != 0xAA) { printf("  ОТКАЗ: хвост 55AA\n"); fails++; }
    if(free_cnt == 0xFFFFFFFFu)  { printf("  ОТКАЗ: свободные кластеры всё ещё «неизвестно»\n"); fails++; }
    if(next_free == 0xFFFFFFFFu) { printf("  ОТКАЗ: следующий свободный всё ещё «неизвестно»\n"); fails++; }
    if(free_cnt != in->clusters - in->clusters_used) { printf("  ОТКАЗ: свободных не совпадает с томом\n"); fails++; }
    if(next_free != in->clusters_used + 2)           { printf("  ОТКАЗ: первый свободный не совпадает с томом\n"); fails++; }
    if(next_free < 2 || next_free > in->clusters + 1) { printf("  ОТКАЗ: первый свободный вне диапазона данных\n"); fails++; }

    printf(fails ? "\n==== ОТКАЗОВ: %d ====\n" : "\n==== FSInfo ЧИСТ ====\n", fails);
    divmmc_fs_close();
    return fails ? 1 : 0;
}
