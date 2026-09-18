/* nes_rom.c - iNES / NES 2.0 header parser + MiSTer-contract mapper_flags builder for BulbuLator.
 *
 * Drops into the ARM loader (Step 5 of the NES port). Parses the 16-byte header of a .nes file,
 * computes mapper/submapper/PRG/CHR sizes/mirroring/battery/region, and packs the 64-bit
 * mapper_flags word in the EXACT bit layout the vendored NESTang/MiSTer cart.sv decodes.
 *
 * Host-test build (validate against a real ROM corpus):
 *     gcc -DNES_ROM_TEST -O2 -o nes_rom nes_rom.c && ./nes_rom <dir-of-.nes>
 * In the firmware the header comes from f_read(); here from fread().
 */
#include <stdint.h>
#include <string.h>

typedef struct {
    int      valid;
    int      is_nes20;
    uint32_t mapper;        /* up to 12-bit (NES2.0) */
    uint32_t submapper;     /* NES2.0 */
    uint32_t prg_bytes;     /* PRG-ROM size in bytes */
    uint32_t chr_bytes;     /* CHR-ROM size in bytes (0 => CHR-RAM) */
    int      has_chr_ram;
    int      mirroring;     /* 0=horizontal(vert arrangement), 1=vertical; see note */
    int      four_screen;
    int      battery;
    int      trainer;       /* 512-byte trainer present before PRG */
    int      region;        /* 0 NTSC, 1 PAL, 2 multi, 3 Dendy (NES2.0 byte12) */
    uint32_t prg_ram;       /* bytes */
    uint32_t prg_nvram;     /* bytes (battery) */
    uint64_t flags;         /* packed mapper_flags for the fabric */
} nes_hdr_t;

/* NES2.0 size-shift: size = 64 << n */
static uint32_t ram_shift(uint8_t n){ return n ? (64u << n) : 0u; }

/* Parse the 16-byte iNES/NES2.0 header. Returns 0 on OK, nonzero on bad magic. */
int nes_parse_header(const uint8_t h[16], nes_hdr_t *o)
{
    memset(o, 0, sizeof(*o));
    if(!(h[0]==0x4E && h[1]==0x45 && h[2]==0x53 && h[3]==0x1A)) return 1;  /* "NES\x1A" */
    o->valid = 1;

    o->is_nes20 = ((h[7] & 0x0C) == 0x08);

    /* mapper: low nibble = h6[7:4], high nibble = h7[7:4]; NES2.0 adds h8[3:0] as bits 11:8 */
    uint32_t mapper = ((uint32_t)(h[6] >> 4)) | ((uint32_t)(h[7] & 0xF0));
    /* DIRTY-HEADER GUARD: pre-NES2.0 dumps with junk in bytes 9..15 -> zero the high nibble */
    if(!o->is_nes20){
        int dirty = 0; for(int i=9;i<16;i++) if(h[i]) dirty = 1;
        if(dirty) mapper &= 0x0Fu;
    } else {
        mapper |= ((uint32_t)(h[8] & 0x0F)) << 8;      /* bits 11:8 */
        o->submapper = (h[8] >> 4) & 0x0F;
    }
    o->mapper = mapper;

    o->mirroring   = h[6] & 0x01;
    o->battery     = (h[6] >> 1) & 0x01;
    o->trainer     = (h[6] >> 2) & 0x01;
    o->four_screen = (h[6] >> 3) & 0x01;

    /* PRG size */
    uint32_t prg_lsb = h[4], chr_lsb = h[5];
    if(o->is_nes20){
        uint32_t prg_msb = h[9] & 0x0F, chr_msb = (h[9] >> 4) & 0x0F;
        if(prg_msb == 0x0F){ /* exponent form: 2^(mm) * (2*ee+1) */
            uint32_t mm = (prg_lsb >> 2) & 0x3F, ee = prg_lsb & 0x03;
            o->prg_bytes = (1u << mm) * (2u*ee + 1u);
        } else {
            o->prg_bytes = ((prg_msb << 8) | prg_lsb) * 16384u;
        }
        if(chr_msb == 0x0F){
            uint32_t mm = (chr_lsb >> 2) & 0x3F, ee = chr_lsb & 0x03;
            o->chr_bytes = (1u << mm) * (2u*ee + 1u);
        } else {
            o->chr_bytes = ((chr_msb << 8) | chr_lsb) * 8192u;
        }
        o->prg_ram   = ram_shift(h[10] & 0x0F);
        o->prg_nvram = ram_shift((h[10] >> 4) & 0x0F);
        o->region    = h[12] & 0x03;           /* 0 NTSC / 1 PAL / 2 multi / 3 Dendy */
    } else {
        o->prg_bytes = prg_lsb * 16384u;
        o->chr_bytes = chr_lsb * 8192u;
        o->region    = (h[9] & 0x01) ? 1 : 0;  /* iNES1.0 byte9 bit0: 0 NTSC, 1 PAL */
        o->prg_ram   = 8192u;                  /* iNES has no RAM sizing; assume 8K if used */
    }
    o->has_chr_ram = (o->chr_bytes == 0);

    /* PRG/CHR size CLASS (power-of-two "units" the fabric masks against). MiSTer packs a class code;
       here we pass the log2 of 16K/8K unit counts, clamped, matching cart.sv's [10:8]/[13:11] use. */
    uint32_t prg_units = o->prg_bytes ? (o->prg_bytes + 16383u)/16384u : 1u;
    uint32_t chr_units = o->chr_bytes ? (o->chr_bytes + 8191u)/8192u  : 1u;
    uint32_t prg_cls=0, chr_cls=0;
    while((1u<<prg_cls) < prg_units && prg_cls<7) prg_cls++;
    while((1u<<chr_cls) < chr_units && chr_cls<7) chr_cls++;

    /* Pack mapper_flags (NESTang/MiSTer contract, subset used by cart_top):
       [7:0]=mapper[7:0] [10:8]=prg_cls [13:11]=chr_cls [14]=mirroring [15]=has_chr_ram
       [16]=four_screen [24:17]=mapper[11:8]|submapper<<4 hi bits [25]=battery
       [35]=is_nes20 [37:36]=region */
    uint64_t f = 0;
    f |= (uint64_t)(o->mapper & 0xFF);
    f |= (uint64_t)(prg_cls & 7) << 8;
    f |= (uint64_t)(chr_cls & 7) << 11;
    f |= (uint64_t)(o->mirroring & 1) << 14;
    f |= (uint64_t)(o->has_chr_ram & 1) << 15;
    f |= (uint64_t)(o->four_screen & 1) << 16;
    f |= (uint64_t)(((o->mapper >> 8) & 0x0F) | ((o->submapper & 0x0F) << 4)) << 17;
    f |= (uint64_t)(o->battery & 1) << 25;
    f |= (uint64_t)(o->is_nes20 & 1) << 35;
    f |= (uint64_t)(o->region & 3) << 36;
    o->flags = f;
    return 0;
}

#ifdef NES_ROM_TEST
#include <stdio.h>
#include <dirent.h>
#include <stdlib.h>
static int hist[4096];
static int walk(const char *dir){
    DIR *d = opendir(dir); if(!d) return 0;
    struct dirent *e; int n=0, bad=0;
    char path[2048];
    while((e = readdir(d))){
        if(e->d_name[0]=='.') continue;
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        /* recurse into subdirs */
        DIR *sub = opendir(path);
        if(sub){ closedir(sub); n += walk(path); continue; }
        size_t L = strlen(e->d_name);
        if(L<4 || strcasecmp(e->d_name+L-4, ".nes")) continue;
        FILE *f = fopen(path, "rb"); if(!f) continue;
        uint8_t h[16]; size_t got = fread(h,1,16,f); fclose(f);
        if(got<16) continue;
        nes_hdr_t o;
        if(nes_parse_header(h,&o)){ bad++; continue; }
        hist[o.mapper & 0xFFF]++;
        n++;
    }
    closedir(d);
    if(bad) fprintf(stderr, "  (%d files with bad magic in %s)\n", bad, dir);
    return n;
}
int main(int argc, char**argv){
    const char *dir = argc>1 ? argv[1] : ".";
    int total = walk(dir);
    printf("parsed %d .nes files\n", total);
    printf("mapper histogram (mapper: count):\n");
    for(int m=0;m<4096;m++) if(hist[m]) printf("  m%-4d : %d\n", m, hist[m]);
    /* spot-check a couple of well-known headers by re-parsing if present */
    return 0;
}
#endif
