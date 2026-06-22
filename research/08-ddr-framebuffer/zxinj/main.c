// main.c - bare-metal Cortex-A9 .z80 v3 (128K) snapshot injector for BulbuLator.
// Embeds a .z80 snapshot, parses it, and injects RAM+ports+Z80-registers into the running
// Atlas Spectrum core over the AXI GP0 control plane, then resumes the Z80.
#include <stdint.h>

#define GP0      0x40000000u
#define REG(o)   (*(volatile uint32_t*)(GP0+(o)))
#define CONTROL  0x04   // bit0 = HALT
#define STATUS   0x08   // bit0 = HALT_ACK, bit1 = RAM_BUSY
#define RAMADDR  0x10
#define RAMDATA  0x14
#define DIR0     0x20   // 0x20..0x38 = DIR0..DIR6
#define P7FFD    0x3C
#define PFE      0x40
#define COMMIT   0x44   // bit0 = PORT_COMMIT, bit1 = DIR_COMMIT

extern unsigned char z80_data[];      // the embedded snapshot (from xxd -i)
extern unsigned int  z80_data_len;

static uint8_t pagebuf[16384];

// Decompress one .z80 page payload (clen bytes, RLE 'ED ED count value') -> exactly 16384 bytes.
// clen == 0xFFFF means the page is stored uncompressed (16384 raw bytes).
static void decompress_page(const unsigned char *src, int clen, uint8_t *dst) {
    if (clen == 0xFFFF) { for (int i = 0; i < 16384; i++) dst[i] = src[i]; return; }
    int o = 0, i = 0;
    while (o < 16384 && i < clen) {
        if (src[i] == 0xED && (i + 1) < clen && src[i + 1] == 0xED) {
            int cnt = src[i + 2]; uint8_t val = src[i + 3]; i += 4;
            while (cnt-- > 0 && o < 16384) dst[o++] = val;
        } else {
            dst[o++] = src[i++];
        }
    }
    while (o < 16384) dst[o++] = 0;
}

static void wr_ram(uint32_t addr, const uint8_t *p, int n) {
    REG(RAMADDR) = addr;
    for (int i = 0; i < n; i++) { REG(RAMDATA) = p[i]; while (REG(STATUS) & 0x2) {} }  // poll RAM_BUSY
}

int main(void) {
    const unsigned char *d = z80_data;

    // --- registers from the base (30B) + v3 extended header ---
    uint32_t A = d[0], F = d[1];
    uint32_t BC = d[2] | (d[3] << 8);
    uint32_t HL = d[4] | (d[5] << 8);
    uint32_t SP = d[8] | (d[9] << 8);
    uint32_t I  = d[10];
    uint32_t R  = (d[11] & 0x7F) | ((d[12] & 1) << 7);
    uint32_t border = (d[12] >> 1) & 7;
    uint32_t DE  = d[13] | (d[14] << 8);
    uint32_t BCp = d[15] | (d[16] << 8);
    uint32_t DEp = d[17] | (d[18] << 8);
    uint32_t HLp = d[19] | (d[20] << 8);
    uint32_t Ap = d[21], Fp = d[22];
    uint32_t IY = d[23] | (d[24] << 8);
    uint32_t IX = d[25] | (d[26] << 8);
    uint32_t IFF1 = d[27] ? 1 : 0, IFF2 = d[28] ? 1 : 0;
    uint32_t IM = d[29] & 3;
    int      extlen = d[30] | (d[31] << 8);          // 54 = v3
    uint32_t PC = d[32] | (d[33] << 8);              // real PC (v2/v3)
    uint32_t p7ffd = d[35] & 0x3F;                   // 128K paging
    int off = 32 + extlen;                           // first data block (=86 here)

    // --- HALT the Z80 and wait until frozen ---
    REG(CONTROL) = 1;
    while (!(REG(STATUS) & 1)) {}

    // --- stream the 8 RAM pages (page N -> 128K bank N-3) ---
    while (off + 3 <= (int)z80_data_len) {
        int clen = d[off] | (d[off + 1] << 8);
        int pg   = d[off + 2];
        const unsigned char *src = d + off + 3;
        int filebytes = (clen == 0xFFFF) ? 16384 : clen;
        decompress_page(src, clen, pagebuf);
        int bank = pg - 3;
        if (bank >= 0 && bank < 8) wr_ram((uint32_t)bank << 14, pagebuf, 16384);
        off += 3 + filebytes;
    }

    // --- machine ports: 7FFD paging + border ---
    REG(P7FFD) = p7ffd;
    REG(PFE)   = border;
    REG(COMMIT) = 0x1;                               // PORT_COMMIT

    // --- Z80 registers: pack the 212-bit DIR vector and pulse DIRSet ---
    // T80 DIR layout (LSB->MSB): A,F,A',F',I,R,SP,PC,BC,DE,HL,IX,BC',DE',HL',IY,IM@208,IFF1@210,IFF2@211.
    // NOTE: IX sits between HL and the prime set (BC'/DE'/HL'), per T80.vhd / T80_Reg.vhd.
    uint32_t dir[7];
    dir[0] = A | (F << 8) | (Ap << 16) | (Fp << 24);
    dir[1] = I | (R << 8) | (SP << 16);
    dir[2] = PC | (BC << 16);
    dir[3] = DE | (HL << 16);
    dir[4] = IX  | (BCp << 16);                      // DIR[143:128]=IX,  [159:144]=BC'
    dir[5] = DEp | (HLp << 16);                      // DIR[175:160]=DE', [191:176]=HL'
    dir[6] = IY | (IM << 16) | (IFF1 << 18) | (IFF2 << 19);
    for (int k = 0; k < 7; k++) REG(DIR0 + 4 * k) = dir[k];
    REG(COMMIT) = 0x2;                               // DIR_COMMIT (one DIRSet pulse)

    // --- hold the loaded screen ~3 s before running (snapshot pause). It is already visible from
    //     the shadow buffer while the Z80 stays halted, so this just delays the resume. Kept in the
    //     ARM so it carries to the SD loader (M3) as-is; later this and the snow option move to a
    //     settings menu / hotkey. Busy-wait tuned to ~3 s on the A9. ---
    for (volatile uint32_t hold = 0; hold < 25000000u; hold++) { }  // ~1.5 s (250M≈15s, 50M≈3s, 25M≈1.5s)

    // --- resume: drop HALT, the Z80 continues from the injected PC ---
    REG(CONTROL) = 0;
    for (;;) {}
    return 0;
}
