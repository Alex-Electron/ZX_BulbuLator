#include <stdint.h>
#include "xil_cache.h"   /* Xil_DCacheEnable / Xil_ICacheEnable */
#include "xil_mmu.h"     /* Xil_SetTlbAttributes + NORM_NONCACHE (carve the fabric-shared DMA window) */
#include "ff.h"          /* FatFs (xilffs) - BSP provides xsdps + ChaN FatFs */
#include "xtime_l.h"     /* XTime / COUNTS_PER_SECOND - long-name marquee timing */

/* universal music player (player.c): machine-agnostic ARM soft-synth -> HDMI audio FIFO */
int  player_play_psg(const char* path);
void player_pump(void);
int  player_active(void);
void player_stop(void);
void player_pause_toggle(void);   /* Space: pause/resume transport */
int  player_paused(void);         /* 1 = paused */
int  player_take_ended(void);     /* consume-once: 1 if the track just reached EOF (auto-advance) */
// loader_main.c - BulbuLator OSD app: snapshot loader (.z80/.sna) + F5 SD file browser + options (Step 12).
// Vitis standalone app: the BSP gives xsdps + FatFs; the OSD/keyboard code is the same GP0 MMIO as
// osd.c. F12 = title overlay, F1 = help, F5 = SD browser, Up/Down scroll, Enter enters a folder
// (".." goes up), Esc closes.
//
// D-cache ON (Step 13 foundation). The cache used to be OFF to dodge an "invalidate-length" SD
// corruption - but the real cause was our OWN unaligned f_read/f_write buffers, not the driver:
// modern xsdps already does all ADMA2 cache maintenance (invalidate/flush + descriptor flush) when
// IsCacheCoherent==0, and Xilinx 32-byte-aligns FatFs's own win/buf. FatFs streams multi-sector I/O
// straight into the CALLER's buffer, so any unaligned caller buffer loses a few bytes on an
// invalidate. Fix = enable D-cache (A9 ~10x faster -> real-time audio synth works) + 32-byte-align
// every DMA buffer (snapbuf/cfgbuf/g_buf/o). Plus a 1 MB-aligned NON-CACHEABLE window at the top of
// DDR (NC_BASE) for future fabric-shared buffers (colour-OSD framebuffer, image preview, SW-emu) -
// same coherency class as SD DMA, solved once, machine-agnostic. See vault STEP_13_14_PLAN.md.

#define GP0        0x40000000u
#define OSD_CTRL   (*(volatile uint32_t*)(GP0+0x48))
#define OSD_ADDR   (*(volatile uint32_t*)(GP0+0x4C))
#define OSD_DATA   (*(volatile uint32_t*)(GP0+0x50))
#define BAN_CTRL   (*(volatile uint32_t*)(GP0+0x84))  /* bit0 = banner panel enable (independent of OSD) */
#define BAN_ADDR   (*(volatile uint32_t*)(GP0+0x88))  /* banner LUTRAM word ptr (auto-inc on DATA write) */
#define BAN_DATA   (*(volatile uint32_t*)(GP0+0x8C))  /* 32 packed 1bpp banner px -> ban_buf[ptr], ptr++ */
#define BAN_POS    (*(volatile uint32_t*)(GP0+0x90))  /* banner window {Y0[26:16],X0[10:0]} */
#define OSD_OP     (*(volatile uint32_t*)(GP0+0x6C))  /* OSD panel opacity alpha 0..255 */
#define OSD_POS    (*(volatile uint32_t*)(GP0+0x70))  /* OSD panel position {Y0[26:16],X0[10:0]} */
#define VOL_REG    (*(volatile uint32_t*)(GP0+0x74))  /* HDMI volume gain 0..255 (PCM * vol / 256) */
#define KBD_DATA   (*(volatile uint32_t*)(GP0+0x54))  /* [9]=release_flag(1=break) [8]=empty [7:0]=code; read pops */
#define KBD_STATUS (*(volatile uint32_t*)(GP0+0x58))  /* bit0 = FIFO empty */
#define KBD_HB     (*(volatile uint32_t*)(GP0+0x5C))  /* any write = deadman heartbeat */
#define MACHINE_ID (*(volatile uint32_t*)(GP0+0x60))  /* loaded-core identity ([15:0]=code) */
/* Step 12.1 snapshot-inject control plane (same registers the Step-7 injector uses) */
#define IJ_CTRL   (*(volatile uint32_t*)(GP0+0x04))  /* bit0 = HALT */
#define IJ_STAT   (*(volatile uint32_t*)(GP0+0x08))  /* bit0 HALT_ACK, bit1 RAM_BUSY */
#define IJ_RAMA   (*(volatile uint32_t*)(GP0+0x10))  /* RAM byte address (auto-inc) */
#define IJ_RAMD   (*(volatile uint32_t*)(GP0+0x14))  /* RAM data byte */
#define IJ_7FFD   (*(volatile uint32_t*)(GP0+0x3C))  /* 128K paging port */
#define IJ_FE     (*(volatile uint32_t*)(GP0+0x40))  /* border */
#define IJ_COMMIT (*(volatile uint32_t*)(GP0+0x44))  /* bit0 PORT_COMMIT, bit1 DIR_COMMIT */
#define IJ_DIR0   0x20u                               /* 0x20..0x38 = DIR0..DIR6 (T80 vector) */
#define OSD_W     256
#define OSD_H     128
#define OSD_WPR   (OSD_W/32)          /* 8 words per row */
#define OSD_WORDS (OSD_WPR*OSD_H)     /* 1024 words (256x128/32) */
#define BAN_W     256
#define BAN_H     64
#define BAN_WPR   (BAN_W/32)          /* 8 words per row, same packing as OSD */
#define BAN_WORDS (BAN_WPR*BAN_H)     /* 512 words (256x64/32) */

/* Non-cacheable DDR window for fabric-shared / DMA buffers (future colour-OSD framebuffer, image
   preview, SW-emu shared framebuffer). 1 MB-aligned at the top of the 256 MB DDR; lscript.ld caps
   ps7_ddr_0 below NC_BASE so the linker never places anything here. Marked NORM_NONCACHE at boot so
   ARM writes are coherent with the PL with no per-frame flush (the MiSTer write-combining pattern). */
#define NC_BASE  0x0F700000u   /* start of the reserved non-cacheable window (1 MB-aligned)       */
#define NC_MB    9u            /* size in 1 MB sections: 0x0F700000..0x0FFFFFFF = top 9 MB of DDR */

/* PS/2 set-2 scancodes for the keys the ARM owns (none of these are in the ZX matrix) */
#define SC_F1   0x05u
#define SC_F5   0x03u
#define SC_F12  0x07u
#define SC_ESC  0x76u
#define SC_UP    0x75u   /* PS/2 set-2: cursor up (E0-prefix stripped by ARM) / numpad 8 */
#define SC_DOWN  0x72u   /* cursor down / numpad 2 */
#define SC_ENTER 0x5Au
#define SC_SPACE 0x29u   /* PS/2 set-2 Space: player pause/resume (while OSD open) */
#define SC_F2    0x06u   /* PS/2 set-2 F2: cycle the music play mode (FOLDER / REPEAT-1 / REPEAT-ALL) */
#define SC_F3    0x04u   /* PS/2 set-2 F3: cycle the browser sort mode (only while browsing) */
#define SC_F9    0x01u   /* PS/2 set-2 F9: open/close the options (settings) menu */
#define SC_LEFT  0x6Bu   /* cursor left  (E0 prefix stripped by ARM) / numpad 4 */
#define SC_RIGHT 0x74u   /* cursor right (E0 prefix stripped by ARM) / numpad 6 */
#define SC_PGUP  0x7Du   /* Page Up   (E0 7D, prefix stripped) / numpad 9 - page scroll in the browser */
#define SC_PGDN  0x7Au   /* Page Down (E0 7A, prefix stripped) / numpad 3 */
#define SC_BACKSPACE 0x66u /* PS/2 set-2 Backspace: stop the player */
#define SC_F10   0x09u   /* Step 13.1 Pause bring-up fallback (not in the ZX matrix) */

/* ZX Spectrum 8x8 system font, chars 32..127, extracted from rom128.hex @ 0x7D00 */
static const uint8_t zxfont[96][8] = {
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // ' '
  {0x00,0x10,0x10,0x10,0x10,0x00,0x10,0x00}, // '!'
  {0x00,0x24,0x24,0x00,0x00,0x00,0x00,0x00}, // '"'
  {0x00,0x24,0x7E,0x24,0x24,0x7E,0x24,0x00}, // '#'
  {0x00,0x08,0x3E,0x28,0x3E,0x0A,0x3E,0x08}, // '$'
  {0x00,0x62,0x64,0x08,0x10,0x26,0x46,0x00}, // '%'
  {0x00,0x10,0x28,0x10,0x2A,0x44,0x3A,0x00}, // '&'
  {0x00,0x08,0x10,0x00,0x00,0x00,0x00,0x00}, // '''
  {0x00,0x04,0x08,0x08,0x08,0x08,0x04,0x00}, // '('
  {0x00,0x20,0x10,0x10,0x10,0x10,0x20,0x00}, // ')'
  {0x00,0x00,0x14,0x08,0x3E,0x08,0x14,0x00}, // '*'
  {0x00,0x00,0x08,0x08,0x3E,0x08,0x08,0x00}, // '+'
  {0x00,0x00,0x00,0x00,0x00,0x08,0x08,0x10}, // ','
  {0x00,0x00,0x00,0x00,0x3E,0x00,0x00,0x00}, // '-'
  {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00}, // '.'
  {0x00,0x00,0x02,0x04,0x08,0x10,0x20,0x00}, // '/'
  {0x00,0x3C,0x46,0x4A,0x52,0x62,0x3C,0x00}, // '0'
  {0x00,0x18,0x28,0x08,0x08,0x08,0x3E,0x00}, // '1'
  {0x00,0x3C,0x42,0x02,0x3C,0x40,0x7E,0x00}, // '2'
  {0x00,0x3C,0x42,0x0C,0x02,0x42,0x3C,0x00}, // '3'
  {0x00,0x08,0x18,0x28,0x48,0x7E,0x08,0x00}, // '4'
  {0x00,0x7E,0x40,0x7C,0x02,0x42,0x3C,0x00}, // '5'
  {0x00,0x3C,0x40,0x7C,0x42,0x42,0x3C,0x00}, // '6'
  {0x00,0x7E,0x02,0x04,0x08,0x10,0x10,0x00}, // '7'
  {0x00,0x3C,0x42,0x3C,0x42,0x42,0x3C,0x00}, // '8'
  {0x00,0x3C,0x42,0x42,0x3E,0x02,0x3C,0x00}, // '9'
  {0x00,0x00,0x00,0x10,0x00,0x00,0x10,0x00}, // ':'
  {0x00,0x00,0x10,0x00,0x00,0x10,0x10,0x20}, // ';'
  {0x00,0x00,0x04,0x08,0x10,0x08,0x04,0x00}, // '<'
  {0x00,0x00,0x00,0x3E,0x00,0x3E,0x00,0x00}, // '='
  {0x00,0x00,0x10,0x08,0x04,0x08,0x10,0x00}, // '>'
  {0x00,0x3C,0x42,0x04,0x08,0x00,0x08,0x00}, // '?'
  {0x00,0x3C,0x4A,0x56,0x5E,0x40,0x3C,0x00}, // '@'
  {0x00,0x3C,0x42,0x42,0x7E,0x42,0x42,0x00}, // 'A'
  {0x00,0x7C,0x42,0x7C,0x42,0x42,0x7C,0x00}, // 'B'
  {0x00,0x3C,0x42,0x40,0x40,0x42,0x3C,0x00}, // 'C'
  {0x00,0x78,0x44,0x42,0x42,0x44,0x78,0x00}, // 'D'
  {0x00,0x7E,0x40,0x7C,0x40,0x40,0x7E,0x00}, // 'E'
  {0x00,0x7E,0x40,0x7C,0x40,0x40,0x40,0x00}, // 'F'
  {0x00,0x3C,0x42,0x40,0x4E,0x42,0x3C,0x00}, // 'G'
  {0x00,0x42,0x42,0x7E,0x42,0x42,0x42,0x00}, // 'H'
  {0x00,0x3E,0x08,0x08,0x08,0x08,0x3E,0x00}, // 'I'
  {0x00,0x02,0x02,0x02,0x42,0x42,0x3C,0x00}, // 'J'
  {0x00,0x44,0x48,0x70,0x48,0x44,0x42,0x00}, // 'K'
  {0x00,0x40,0x40,0x40,0x40,0x40,0x7E,0x00}, // 'L'
  {0x00,0x42,0x66,0x5A,0x42,0x42,0x42,0x00}, // 'M'
  {0x00,0x42,0x62,0x52,0x4A,0x46,0x42,0x00}, // 'N'
  {0x00,0x3C,0x42,0x42,0x42,0x42,0x3C,0x00}, // 'O'
  {0x00,0x7C,0x42,0x42,0x7C,0x40,0x40,0x00}, // 'P'
  {0x00,0x3C,0x42,0x42,0x52,0x4A,0x3C,0x00}, // 'Q'
  {0x00,0x7C,0x42,0x42,0x7C,0x44,0x42,0x00}, // 'R'
  {0x00,0x3C,0x40,0x3C,0x02,0x42,0x3C,0x00}, // 'S'
  {0x00,0xFE,0x10,0x10,0x10,0x10,0x10,0x00}, // 'T'
  {0x00,0x42,0x42,0x42,0x42,0x42,0x3C,0x00}, // 'U'
  {0x00,0x42,0x42,0x42,0x42,0x24,0x18,0x00}, // 'V'
  {0x00,0x42,0x42,0x42,0x42,0x5A,0x24,0x00}, // 'W'
  {0x00,0x42,0x24,0x18,0x18,0x24,0x42,0x00}, // 'X'
  {0x00,0x82,0x44,0x28,0x10,0x10,0x10,0x00}, // 'Y'
  {0x00,0x7E,0x04,0x08,0x10,0x20,0x7E,0x00}, // 'Z'
  {0x00,0x0E,0x08,0x08,0x08,0x08,0x0E,0x00}, // '['
  {0x00,0x00,0x40,0x20,0x10,0x08,0x04,0x00}, // '\\'
  {0x00,0x70,0x10,0x10,0x10,0x10,0x70,0x00}, // ']'
  {0x00,0x10,0x38,0x54,0x10,0x10,0x10,0x00}, // '^'
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF}, // '_'
  {0x00,0x1C,0x22,0x78,0x20,0x20,0x7E,0x00}, // '`'
  {0x00,0x00,0x38,0x04,0x3C,0x44,0x3C,0x00}, // 'a'
  {0x00,0x20,0x20,0x3C,0x22,0x22,0x3C,0x00}, // 'b'
  {0x00,0x00,0x1C,0x20,0x20,0x20,0x1C,0x00}, // 'c'
  {0x00,0x04,0x04,0x3C,0x44,0x44,0x3C,0x00}, // 'd'
  {0x00,0x00,0x38,0x44,0x78,0x40,0x3C,0x00}, // 'e'
  {0x00,0x0C,0x10,0x18,0x10,0x10,0x10,0x00}, // 'f'
  {0x00,0x00,0x3C,0x44,0x44,0x3C,0x04,0x38}, // 'g'
  {0x00,0x40,0x40,0x78,0x44,0x44,0x44,0x00}, // 'h'
  {0x00,0x10,0x00,0x30,0x10,0x10,0x38,0x00}, // 'i'
  {0x00,0x04,0x00,0x04,0x04,0x04,0x24,0x18}, // 'j'
  {0x00,0x20,0x28,0x30,0x30,0x28,0x24,0x00}, // 'k'
  {0x00,0x10,0x10,0x10,0x10,0x10,0x0C,0x00}, // 'l'
  {0x00,0x00,0x68,0x54,0x54,0x54,0x54,0x00}, // 'm'
  {0x00,0x00,0x78,0x44,0x44,0x44,0x44,0x00}, // 'n'
  {0x00,0x00,0x38,0x44,0x44,0x44,0x38,0x00}, // 'o'
  {0x00,0x00,0x78,0x44,0x44,0x78,0x40,0x40}, // 'p'
  {0x00,0x00,0x3C,0x44,0x44,0x3C,0x04,0x06}, // 'q'
  {0x00,0x00,0x1C,0x20,0x20,0x20,0x20,0x00}, // 'r'
  {0x00,0x00,0x38,0x40,0x38,0x04,0x78,0x00}, // 's'
  {0x00,0x10,0x38,0x10,0x10,0x10,0x0C,0x00}, // 't'
  {0x00,0x00,0x44,0x44,0x44,0x44,0x38,0x00}, // 'u'
  {0x00,0x00,0x44,0x44,0x28,0x28,0x10,0x00}, // 'v'
  {0x00,0x00,0x44,0x54,0x54,0x54,0x28,0x00}, // 'w'
  {0x00,0x00,0x44,0x28,0x10,0x28,0x44,0x00}, // 'x'
  {0x00,0x00,0x44,0x44,0x44,0x3C,0x04,0x38}, // 'y'
  {0x00,0x00,0x7C,0x08,0x10,0x20,0x7C,0x00}, // 'z'
  {0x00,0x0E,0x08,0x30,0x08,0x08,0x0E,0x00}, // '{'
  {0x00,0x08,0x08,0x08,0x08,0x08,0x08,0x00}, // '|'
  {0x00,0x70,0x10,0x0C,0x10,0x10,0x70,0x00}, // '}'
  {0x00,0x14,0x28,0x00,0x00,0x00,0x00,0x00}, // '~'
  {0x3C,0x42,0x99,0xA1,0xA1,0x99,0x42,0x3C}, // ''
};

static uint32_t osdbuf[OSD_WORDS];
static uint32_t* g_buf    = osdbuf;     /* setpix/draw_* target (OSD panel by default; banner switches it) */
static int       g_bufwpr = OSD_WPR;
static int       g_bufh   = OSD_H;

static int g_inv = 0;   /* 1 = clear pixels instead of set (inverse text on a solid bar) */
static void setpix(int x,int y){
    if(x<0||x>=g_bufwpr*32||y<0||y>=g_bufh) return;
    if(g_inv) g_buf[y*g_bufwpr + (x>>5)] &= ~(1u << (x & 31));
    else      g_buf[y*g_bufwpr + (x>>5)] |=  (1u << (x & 31));
}
static void draw_char(int x,int y,int scale,char c){
    if(c<32 || (unsigned char)c>127) return;
    const uint8_t* g = zxfont[(int)c - 32];
    for(int gy=0; gy<8; gy++)
        for(int gx=0; gx<8; gx++)
            if(g[gy] & (0x80u>>gx))
                for(int dy=0; dy<scale; dy++)
                    for(int dx=0; dx<scale; dx++)
                        setpix(x+gx*scale+dx, y+gy*scale+dy);
}
static void draw_text(int x,int y,int scale,const char* s){
    for(; *s; s++){ draw_char(x,y,scale,*s); x += 8*scale; }
}
static void draw_text_scrolled(int x, int y, int scale, const char* s, int scroll_chars) {
    for(int i = 0; i < scroll_chars && *s; i++) s++;
    draw_text(x, y, scale, s);
}
static int slen(const char* s){ int n=0; while(s[n]) n++; return n; }
static const uint8_t folder_glyph[8] = {0x00,0x70,0xFE,0x82,0x82,0x82,0xFE,0x00};  /* 8x8 folder icon */
static const uint8_t lbr_glyph[8]    = {0x00,0xE0,0x80,0x80,0x80,0x80,0xE0,0x00};  /* '[' flush to cell left edge */
/* ---- player title-bar icons (8x8) ---- */
static const uint8_t play_glyph[8]   = {0x00,0x40,0x60,0x70,0x70,0x60,0x40,0x00};  /* > playing */
static const uint8_t pause_glyph[8]  = {0x00,0x66,0x66,0x66,0x66,0x66,0x66,0x00};  /* || paused */
static const uint8_t pend_glyph[8]   = {0x00,0x42,0x62,0x72,0x72,0x62,0x42,0x00};  /* >| FOLDER (play through, stop) */
static const uint8_t loop_glyph[8]   = {0x3C,0x42,0x81,0x81,0x81,0x42,0x3C,0x00};  /* O REPEAT (all / +'1' for one) */
static void draw_glyph(int x,int y,const uint8_t g[8]){
    for(int gy=0;gy<8;gy++) for(int gx=0;gx<8;gx++) if(g[gy]&(0x80u>>gx)) setpix(x+gx,y+gy);
}

static void osd_clear(void){ for(int i=0;i<OSD_WORDS;i++) osdbuf[i]=0; }
static void osd_blit(void){ OSD_ADDR=0; for(int i=0;i<OSD_WORDS;i++) OSD_DATA=osdbuf[i]; }
static void draw_text_c(int y,int scale,const char* s){     /* horizontally centred line */
    int x0 = (OSD_W - slen(s)*8*scale)/2; if(x0<0) x0=0;
    draw_text(x0,y,scale,s);
}
/* Solid inverse title bar across the top row (y 0..7), shared by every menu/header. Callers draw
   their title text in g_inv mode so it reads as the bg colour on the highlighted bar. New menus get
   a consistent title with zero per-menu drawing code. */
static void titlebar(void){ for(int y=0;y<8;y++) for(int w=0;w<OSD_WPR;w++) osdbuf[y*OSD_WPR+w]=0xFFFFFFFFu; }
static void draw_title(const char* s){   titlebar(); g_inv=1; draw_text(2,0,1,s); g_inv=0; }
static void draw_title_c(const char* s){ titlebar(); int x0=(OSD_W-slen(s)*8)/2; if(x0<0)x0=0; g_inv=1; draw_text(x0,0,1,s); g_inv=0; }
static void browser_status(const char* s){   /* repaint the title bar, then show a status word right-aligned (no overlap with path/sort hint) */
    titlebar(); g_inv=1; draw_text(OSD_W - slen(s)*8, 0, 1, s); g_inv=0; osd_blit();
}

/* Title screen (shown when the OSD opens with F12): just the name, centred, scale 2. */
/* Firmware build tag shown on the F12 splash (bump per milestone). The PL core VERSION
   (0x4000_0000) is shown live too, so the splash states exactly which firmware + bitstream run. */
#define BULB_FW "v0.13"
static char hexnib(uint32_t v){ return (v<10) ? ('0'+v) : ('A'+v-10); }
/* Single source of truth for the version line ("v0.12 core 0xB01B0009"): the ARM firmware tag
   BULB_FW + the live PL core VERSION read from register 0x00. Used by BOTH the F12 splash
   (show_header) and the F1 help page (show_help), so the two can never drift apart. */
static void version_str(char* out){
    uint32_t cv = *(volatile uint32_t*)(GP0+0x00);     /* PL core VERSION */
    int p=0; const char* fw = BULB_FW;
    while(*fw) out[p++]=*fw++;
    out[p++]=' '; out[p++]='c'; out[p++]='o'; out[p++]='r'; out[p++]='e'; out[p++]=' '; out[p++]='0'; out[p++]='x';
    for(int i=28;i>=0;i-=4) out[p++]=hexnib((cv>>i)&0xF);
    out[p]=0;
}
static void show_header(void){
    osd_clear();
    draw_text_c(14, 2, "ZX BulbuLator");
    char v[40]; version_str(v);
    draw_text_c(46, 1, v);
    osd_blit();
}
/* F1 help page: inverse title bar + grouped key map (GLOBAL / FILE BROWSER / ZX KEYS). */
static void show_help(void){
    osd_clear();
    char v[40]; version_str(v);                              /* "v0.12 core 0xB01B0009" */
    titlebar(); g_inv=1;                                     /* inverse title bar: HELP (left) + version/build (right), like the other OSD views */
    draw_text(2, 0, 1, "HELP");
    draw_text(OSD_W - slen(v)*8, 0, 1, v);
    g_inv=0;
    draw_text(2, 10, 1, "# GLOBAL: F5 BROWSER F9 OPTS");
    draw_text(2, 18, 1, "  F1 HELP  F12/ESC CLOSE");
    draw_text(2, 30, 1, "# MUSIC (in browser):");
    draw_text(2, 38, 1, "  ENTER/SPACE = PLAY/PAUSE");
    draw_text(2, 46, 1, "  ESC STOP   UP/DN PREV/NEXT");
    draw_text(2, 54, 1, "  F2 PLAY MODE   F3 SORT");
    draw_text(2, 66, 1, "# ZX KEYS:");
    draw_text(2, 74, 1, "  SHIFT CAPS   CTRL SYMBOL");
    draw_text(2, 82, 1, "  ALT  CS+SS (EXTEND)");
    draw_text(2, 90, 1, "  CTRL+ALT+DEL - SOFT RESET");
    draw_text(2, 98, 1, "  CTRL+ALT+INS - NMI");
    draw_text(2,106, 1, "  F11 - HARD RESET (WIPE RAM)");
    osd_blit();
}

static int osd_on = 0, browser_on = 0, opt_on = 0;
static int osd_view = 0;   /* single view state: 0=none 1=header 2=help 3=browser 4=options */
static int mkey     = 0;   /* scancode of the currently-held menu key (edge-detect); 0=none */
static void open_osd(void){ show_header(); OSD_CTRL = 1; osd_on = 1; browser_on = 0; opt_on = 0; osd_view = 1; }
static void close_osd(void){ OSD_CTRL = 0; osd_on = 0; browser_on = 0; opt_on = 0; osd_view = 0; }

/* ---- F5 SD file browser (read-only) with directory navigation, into the 256x128 OSD panel ---- */
#define MAXFILES 256
#define BROWS    15                       /* file rows visible in the 256x128 panel */
#define NAMELEN  96                 /* store the full long name (panel shows VISCH; marquee reveals the rest) */
static char  flist[MAXFILES][NAMELEN+1];
static uint8_t fisdir[MAXFILES];
static uint32_t fsz[MAXFILES];          /* file size in bytes (0 for dirs / "..") */
static uint32_t fdt[MAXFILES];          /* (FAT date<<16)|time, for chronological sort */
static int   fcount = 0, bcursor = 0, btop = 0, sd_mounted = 0;
static int   sortmode = 0;              /* 0=NAME 1=DATE 2=SIZE 3=EXT */
static int   opt_scroll     = 1;        /* long-name marquee speed: 0=slow 1=med 2=fast */
static int   opt_foldermark = 0;        /* folder tag style: 0=[brackets] 1=icon 2=trailing-slash */
static int   opt_scrdelay    = 1;        /* marquee START delay: 0=0ms 1=300ms 2=500ms 3=1000ms */
static int   opt_dim         = 80;       /* OSD panel dimming/opacity %% (5%% steps) */
static int   opt_vol         = 100;      /* HDMI output volume %% (5%% steps); 100 = unity */
static int   opt_x           = 512;      /* OSD panel left X0 (0..1024, step 8 px) */
static int   opt_y           = 176;      /* OSD panel top  Y0 (0..592, step 8 px) */
static int   opt_playmode    = 0;        /* music auto-play mode: 0=FOLDER(stop at end) 1=REPEAT-1 2=REPEAT-ALL(loop) */
static const char* const CH_PLAY[] = {"FOLDER","REPEAT 1","REPEAT ALL"};   /* shared by F2 / F9 menu / title indicator */
static int   playing_idx     = -1;       /* flist index of the currently-playing track (-1 = none) */
static char  play_dir[80]    = "";       /* folder (curpath) where the current playback started (auto-advance scope) */
static int   opt_pausemusic  = 0;        /* 0=NO (game runs in background, audio muted by FIFO mux) 1=YES (HALT when music plays over a game) */
static const char* const CH_NOYES[] = {"NO","YES"};
/* ---- pause/now-playing BANNER state (independent overlay) ---- */
static char  g_app_path[100] = "";       /* full SD path of the last-loaded snapshot (game/demo) */
static char  g_music_path[100] = ""; /* full path of the currently-playing track */
static void  update_banner(void);        /* fwd (defined after the pause section) */
static void  apply_music_halt(void);     /* fwd (HALT coordination) */
static void  apply_halt(void);           /* fwd (single owner of IJ_CTRL HALT bit) */
static void  music_halt_changed(void);   /* fwd (F9 PAUSE-MUS onchange) */
static int   scroll_started  = 0;        /* 0 = still in the pre-scroll start delay for this name */
static char  curpath[80] = "0:/";
static FATFS g_fs;
/* SD robustness: EBAZ4205 has NO routed card-detect, so presence can't be cheaply polled. Instead
   any FatFs error drops the volume (sd_unmount) and F5 remounts - so a yanked card can no longer
   wedge the non-blocking OSD loop in a stuck SD op. EJECT SD (F9) unmounts cleanly before removal. */
static void sd_unmount(void){ f_mount(0, "0:/", 0); sd_mounted = 0; }
#define VISCH 30                     /* chars visible in the 256px panel from x=12 */
static int   sel_scroll = 0;         /* marquee offset of the selected (long) name */
static XTime last_scroll = 0;
static XTime last_probe  = 0;   /* throttle the no-card-detect remount poll (EBAZ has no CD line) */

static void itoa_u(int v, char* o){ char t[8]; int q=0; if(!v){o[0]='0';o[1]=0;return;}
    while(v&&q<7){t[q++]='0'+v%10;v/=10;} int p=0; while(q)o[p++]=t[--q]; o[p]=0; }
static int  is_root(void){ return curpath[0]=='0'&&curpath[1]==':'&&curpath[2]=='/'&&curpath[3]==0; }

static int cicmp(const char* a, const char* b){      /* case-insensitive string compare */
    for(;;){
        int x=(unsigned char)*a++, y=(unsigned char)*b++;
        if(x>='A'&&x<='Z') x+=32;
        if(y>='A'&&y<='Z') y+=32;
        if(x!=y) return x-y;
        if(!x) return 0;
    }
}
static const char* fext(const char* s){               /* suffix after the last '.', or "" */
    const char* e=""; for(const char* p=s; *p; p++) if(*p=='.') e=p+1; return e;
}
/* "less" = a should appear before b. Folders always above files; then the active sort key, with the
   smart order: name/ext A->Z, date newest first, size largest first. */
static int ent_less(int a, int b){
    if(fisdir[a]!=fisdir[b]) return fisdir[a] > fisdir[b];
    switch(sortmode){
        case 1: if(fdt[a]!=fdt[b]) return fdt[a] > fdt[b]; break;       /* DATE: newest first */
        case 2: if(fsz[a]!=fsz[b]) return fsz[a] > fsz[b]; break;       /* SIZE: largest first */
        case 3: { int c=cicmp(fext(flist[a]), fext(flist[b])); if(c) return c<0; break; } /* EXT, then name */
        default: break;                                                /* NAME */
    }
    return cicmp(flist[a], flist[b]) < 0;
}
static void swap_ent(int i, int j){
    char tmp[NAMELEN+1]; for(int k=0;k<=NAMELEN;k++){ tmp[k]=flist[i][k]; flist[i][k]=flist[j][k]; flist[j][k]=tmp[k]; }
    uint8_t  d=fisdir[i]; fisdir[i]=fisdir[j]; fisdir[j]=d;
    uint32_t s=fsz[i];    fsz[i]=fsz[j];       fsz[j]=s;
    uint32_t t=fdt[i];    fdt[i]=fdt[j];       fdt[j]=t;
}
static void sort_entries(void){                        /* insertion sort; keep ".." pinned at row 0 */
    int base = is_root() ? 0 : 1;
    for(int i=base+1; i<fcount; i++)
        for(int j=i; j>base && ent_less(j, j-1); j--) swap_ent(j, j-1);
}

static void sd_scan(void){               /* mount once + read curpath into flist[] */
    fcount = 0;   /* keep bcursor/btop: only a directory change resets the cursor, so a re-open (F5) lands where you were */
    if(!sd_mounted){
        browser_status("MOUNT");                  /* instant status: mount can take ~1s on a flaky/absent card */
        if(f_mount(&g_fs, "0:/", 1) != FR_OK){ sd_unmount(); return; }
        sd_mounted = 1;
    }
    browser_status("READ");
    if(!is_root()){                       /* synthetic ".." to go up */
        flist[0][0]='.'; flist[0][1]='.'; flist[0][2]=0; fisdir[0]=1;
        fsz[0]=0; fdt[0]=0; fcount=1;
    }
    DIR dir; FILINFO fno; FRESULT rr=FR_OK;
    if(f_opendir(&dir, curpath) != FR_OK){           /* stale mount (card swapped) or gone: try ONE fresh remount */
        sd_unmount();
        if(f_mount(&g_fs,"0:/",1)!=FR_OK){ sd_unmount(); return; }   sd_mounted=1;
        if(f_opendir(&dir, curpath) != FR_OK){ sd_unmount(); return; }   /* really gone -> NO CARD */
    }
    while(fcount < MAXFILES && (rr=f_readdir(&dir, &fno)) == FR_OK && fno.fname[0]){
        if(fno.fattrib & (AM_HID|AM_SYS)) continue;
        int n=0; for(; fno.fname[n] && n<NAMELEN; n++) flist[fcount][n]=fno.fname[n];
        flist[fcount][n]=0;
        fisdir[fcount] = (fno.fattrib & AM_DIR) ? 1 : 0;
        fsz[fcount]    = (uint32_t)fno.fsize;
        fdt[fcount]    = ((uint32_t)fno.fdate << 16) | fno.ftime;
        fcount++;
    }
    f_closedir(&dir);
    if(rr != FR_OK){ sd_unmount(); return; }   /* error mid-enumeration -> card gone, don't show a partial list */
    sort_entries();
    if(bcursor>=fcount) bcursor = fcount ? fcount-1 : 0;   /* keep the remembered cursor in range if the dir shrank */
    if(btop>bcursor) btop=bcursor;
    if(bcursor>=btop+BROWS) btop=bcursor-(BROWS-1);
    if(btop<0) btop=0;
}
static const char* sort_label(void){
    switch(sortmode){ case 1: return "DATE"; case 2: return "SIZE"; case 3: return "EXT"; default: return "NAME"; }
}
static void draw_vline(int x,int y0,int y1){ for(int y=y0;y<y1;y++) setpix(x,y); }
/* (BROWS is defined up near MAXFILES) */
static void render_browser(void){
    osd_clear();
    if(!sd_mounted){ draw_title_c("SD: NO CARD / NOT FAT"); osd_blit(); return; }
    char t[40]; int p=0; for(int i=0; curpath[i] && p<13; i++) t[p++]=curpath[i];   /* path (left) */
    t[p++]=' '; char cnt[8]; itoa_u(fcount, cnt); for(int i=0; cnt[i]; i++) t[p++]=cnt[i]; t[p]=0;
    const char* sm = sort_label();                          /* current sort value: NAME/DATE/SIZE/EXT */
    char sl[20]; int q=0; const char* pfx="SORT:";          /* compact (F3 hotkey is in F1 help) so the play icons fit too */
    for(int i=0; pfx[i]; i++) sl[q++]=pfx[i];
    for(int i=0; sm[i]; i++) sl[q++]=sm[i];
    sl[q]=0;
    titlebar(); g_inv=1;                                    /* inverse title bar: path+count (left); play icons + SORT label (right) */
    draw_text(2,0,1,t);
    int rx = OSD_W - q*8;                                   /* SORT label, right-aligned (always visible) */
    draw_text(rx, 0, 1, sl);
    if(player_active()){                                    /* playback indicator = ICONS just left of the SORT label: state + mode */
        int iw = 8 + 8 + (opt_playmode==1 ? 8 : 0);         /* state glyph + mode glyph (+ '1' for REPEAT-1) */
        int ix = rx - iw - 6;
        draw_glyph(ix, 0, player_paused()?pause_glyph:play_glyph); ix+=8;
        if(opt_playmode==0) draw_glyph(ix,0,pend_glyph);                                       /* FOLDER: play-through */
        else { draw_glyph(ix,0,loop_glyph); ix+=8; if(opt_playmode==1) draw_char(ix,0,1,'1'); } /* REPEAT-1 / REPEAT-ALL */
    }
    g_inv=0;
    for(int row=0; row<BROWS; row++){
        int idx = btop+row; if(idx>=fcount) break;
        int y = 8 + row*8;
        draw_char(2, y, 1, idx==bcursor ? '>' : ' ');
        int so = (idx==bcursor && sel_scroll <= slen(flist[idx])) ? sel_scroll : 0;
        int nx = 12;
        if(fisdir[idx]){                                       /* opening mark ALWAYS (fixed nx, no jump) */
            if(opt_foldermark==0){ draw_glyph(13,y,lbr_glyph); nx=18; }       /* [brackets] flush-left */
            else if(opt_foldermark==1){ draw_glyph(12,y,folder_glyph); nx=22; } /* folder icon */
        }
        draw_text(nx, y, 1, flist[idx] + so);
        if(fisdir[idx] && so==0){
            int ex = nx + slen(flist[idx])*8;
            if(opt_foldermark==0) draw_char(ex,y,1,']');
            else if(opt_foldermark==2) draw_char(ex,y,1,'/');
        }
    }
    if(fcount > BROWS){                            /* scroll indicator down the right edge */
        int ty0 = 8, tyh = OSD_H - ty0;            /* track spans the list rows (y 8..127) */
        int th  = tyh * BROWS / fcount; if(th < 4) th = 4;
        int tt  = ty0 + (tyh - th) * btop / (fcount - BROWS);
        for(int y=ty0; y<OSD_H; y+=2) setpix(OSD_W-1, y);                /* dotted track */
        draw_vline(OSD_W-2, tt, tt+th); draw_vline(OSD_W-1, tt, tt+th);  /* solid thumb */
    }
    osd_blit();
}
static void open_browser(void){
    sel_scroll=0; last_scroll=0; scroll_started=0; opt_on=0;
    OSD_CTRL=1; osd_on=1; browser_on=1; osd_view=3;
    render_browser();        /* INSTANT window before any SD I/O - a keypress always shows something */
    sd_scan();               /* may block ~1s; shows MOUNT/READ on the title bar */
    render_browser();        /* final listing */
}
static void browser_move(int d){
    if(fcount==0) return;
    bcursor += d;
    if(bcursor<0) bcursor=0;
    if(bcursor>=fcount) bcursor=fcount-1;
    if(bcursor<btop) btop=bcursor;
    if(bcursor>=btop+BROWS) btop=bcursor-(BROWS-1);
    sel_scroll=0; last_scroll=0; scroll_started=0;   /* fresh selection: unscrolled, re-arm start delay */
    render_browser();
}
static void browser_scroll_tick(void){    /* marquee the selected long name (after a start delay) */
    if(fcount==0 || bcursor>=fcount) return;
    int nx = 12;                          /* match render's folder-mark left offset for the visible width */
    if(fisdir[bcursor]){ if(opt_foldermark==0) nx=18; else if(opt_foldermark==1) nx=22; }
    int vis = (OSD_W - nx) / 8;           /* chars that fit from nx to the right edge */
    int len = slen(flist[bcursor]);
    if(len <= vis){ if(sel_scroll){ sel_scroll=0; render_browser(); } return; }
    XTime now; XTime_GetTime(&now);
    if(!scroll_started){                  /* hold the name still for the configured delay first */
        static const int dly_ms[4] = {0,300,500,1000};
        if(last_scroll==0){ last_scroll = now; return; }                 /* stamp the selection time */
        if(now - last_scroll < (COUNTS_PER_SECOND/1000u)*(unsigned)dly_ms[opt_scrdelay]) return;
        scroll_started = 1; last_scroll = now;
    }
    static const int sps[3] = {2,3,6};                 /* marquee steps/sec for slow/med/fast */
    if(now - last_scroll < (COUNTS_PER_SECOND / sps[opt_scroll])) return;
    last_scroll = now;
    sel_scroll++;
    if(sel_scroll > (len - vis) + 2){ sel_scroll = 0; scroll_started = 0; last_scroll = now; } /* tail pause -> re-delay at start */
    render_browser();
}
/* ====== Step 12.1: .z80 / .sna snapshot loader =====================================
   Enter on a snapshot -> read it off the card, parse it, inject RAM + ports + the Z80
   registers into the Atlas core over the Step-7 control plane (HALT, RAM_ADDR/DATA,
   7FFD/FE, the 212-bit T80 DIR vector), then resume. The running machine is replaced
   (a deliberate load). Covers .z80 v1/v2/v3 (48K+128K) and .sna 48K/128K. */
/* 32-byte (A9 cache-line) aligned: FatFs streams multi-sector f_read straight into this buffer, so
   with D-cache ON it MUST be cache-line aligned or the invalidate clips a few bytes (the old bug). */
static uint8_t snapbuf[160*1024] __attribute__((aligned(32)));   /* whole snapshot file (128K .sna ~131 KB) */
static uint8_t pagebuf[16384];      /* one decompressed .z80 page */
static uint8_t ram48[49152];        /* decompressed 48K image (v1 / 48K) */

static void wr_bank(int bank, const uint8_t* p){
    IJ_RAMA = (uint32_t)bank << 14;
    for(int i=0;i<16384;i++){ IJ_RAMD = p[i]; while(IJ_STAT & 0x2u){} }   /* poll RAM_BUSY */
}
/* Full machine RESET + RAM wipe before inject (Step 12, VERSION 0xB01B0009+): pulse CONTROL bit2
   (RESET+wipe), wait STATUS bit2 to assert then clear. The hardware sweep-wipes all 128 KB and
   cold-resets the Z80 + ALL peripherals (AY/ULA/paging) - reusing the core's F11 cold-reset path -
   so leftover state from the previous program can't corrupt the new one (fixes aeon-over-a-demo)
   and the AY stops squealing. Then HALT + wait HALT_ACK to take the bus. (Per the CDC review:
   wait busy 0->1->0, never treat the first busy==0 as done - the wipe must not race the inject.)
   On an older bitstream (no bit2) this degrades to a brief delay + HALT (no reset). */
static void machine_reset(void){
    IJ_CTRL = 0x4;                                              /* request RESET+wipe (CONTROL bit2) */
    for(volatile uint32_t t=0; t<500000u;  t++) if(  IJ_STAT & 0x4u) break;   /* wait busy asserted */
    for(volatile uint32_t t=0; t<8000000u; t++) if(!(IJ_STAT & 0x4u)) break;  /* wait wipe+reset done */
    IJ_CTRL = 1;                                                /* HALT - take the memory bus */
    while(!(IJ_STAT & 1u)){}                                    /* wait HALT_ACK */
}
/* .z80 RLE: 'ED ED cnt val'; clen==0xFFFF -> 16384 raw bytes. */
static void z80_unrle(const uint8_t* src,int clen,uint8_t* dst){
    if(clen==0xFFFF){ for(int i=0;i<16384;i++) dst[i]=src[i]; return; }
    int o=0,i=0;
    while(o<16384 && i<clen){
        if(src[i]==0xED && i+3<clen && src[i+1]==0xED){ int c=src[i+2]; uint8_t v=src[i+3]; i+=4; while(c-->0 && o<16384) dst[o++]=v; }
        else dst[o++]=src[i++];
    }
    while(o<16384) dst[o++]=0;
}
typedef struct { uint32_t A,F,Ap,Fp,I,R,SP,PC,BC,DE,HL,IX,BCp,DEp,HLp,IY,IM,IFF1,IFF2,border,p7ffd; } zregs;
static void inject_finish(const zregs* z){
    IJ_7FFD = z->p7ffd; IJ_FE = z->border; IJ_COMMIT = 0x1u;     /* paging + border */
    uint32_t dir[7];                                             /* T80 DIR (IX before the prime set) */
    dir[0]=z->A|(z->F<<8)|(z->Ap<<16)|(z->Fp<<24);
    dir[1]=z->I|(z->R<<8)|(z->SP<<16);
    dir[2]=z->PC|(z->BC<<16);
    dir[3]=z->DE|(z->HL<<16);
    dir[4]=z->IX|(z->BCp<<16);
    dir[5]=z->DEp|(z->HLp<<16);
    dir[6]=z->IY|(z->IM<<16)|(z->IFF1<<18)|(z->IFF2<<19);
    for(int k=0;k<7;k++) *(volatile uint32_t*)(GP0+IJ_DIR0+4u*k)=dir[k];
    IJ_COMMIT = 0x2u;                                            /* DIRSet pulse */
    IJ_CTRL = 0;                                                 /* resume */
}
static void load_z80(const uint8_t* d,int len){
    zregs z = {0};
    z.A=d[0]; z.F=d[1]; z.BC=d[2]|(d[3]<<8); z.HL=d[4]|(d[5]<<8); z.SP=d[8]|(d[9]<<8);
    z.I=d[10]; z.R=(d[11]&0x7F)|((d[12]&1)<<7); z.border=(d[12]>>1)&7;
    z.DE=d[13]|(d[14]<<8); z.BCp=d[15]|(d[16]<<8); z.DEp=d[17]|(d[18]<<8); z.HLp=d[19]|(d[20]<<8);
    z.Ap=d[21]; z.Fp=d[22]; z.IY=d[23]|(d[24]<<8); z.IX=d[25]|(d[26]<<8);
    z.IFF1=d[27]?1:0; z.IFF2=d[28]?1:0; z.IM=d[29]&3;
    uint32_t pc0=d[6]|(d[7]<<8);
    machine_reset();                                             /* full reset + wipe, then HALT */
    if(pc0){                                                     /* --- v1: 48K, one RLE block @30 --- */
        z.PC=pc0; z.p7ffd=0x30;
        if(d[12]&0x20){
            int o=0,i=30;
            while(o<49152 && i<len){
                if(d[i]==0xED && i+3<len && d[i+1]==0xED){ int c=d[i+2]; uint8_t v=d[i+3]; i+=4; while(c-->0 && o<49152) ram48[o++]=v; }
                else ram48[o++]=d[i++];
            }
            while(o<49152) ram48[o++]=0;
        } else { for(int i=0;i<49152 && 30+i<len;i++) ram48[i]=d[30+i]; }
        wr_bank(5,ram48); wr_bank(2,ram48+16384); wr_bank(0,ram48+32768);
    } else {                                                     /* --- v2/v3 --- */
        int extlen=d[30]|(d[31]<<8); z.PC=d[32]|(d[33]<<8);
        int hw=d[34]; int is128=(extlen==23)?(hw>=3):(hw>=4);
        z.p7ffd=is128?(d[35]&0x3F):0x30;
        int off=32+extlen;
        while(off+3<=len){
            int clen=d[off]|(d[off+1]<<8); int pg=d[off+2]; const uint8_t* src=d+off+3;
            int fb=(clen==0xFFFF)?16384:clen;
            z80_unrle(src,clen,pagebuf);
            int bank=-1;
            if(is128){ if(pg>=3&&pg<=10) bank=pg-3; }
            else { if(pg==5)bank=5; else if(pg==4)bank=2; else if(pg==8)bank=0; }
            if(bank>=0) wr_bank(bank,pagebuf);
            off+=3+fb;
        }
    }
    inject_finish(&z);
}
static void load_sna(const uint8_t* d,int len){
    zregs z = {0};
    z.I=d[0]; z.HLp=d[1]|(d[2]<<8); z.DEp=d[3]|(d[4]<<8); z.BCp=d[5]|(d[6]<<8);
    z.Fp=d[7]; z.Ap=d[8]; z.HL=d[9]|(d[10]<<8); z.DE=d[11]|(d[12]<<8); z.BC=d[13]|(d[14]<<8);
    z.IY=d[15]|(d[16]<<8); z.IX=d[17]|(d[18]<<8);
    z.IFF2=(d[19]&0x04)?1:0; z.IFF1=z.IFF2;
    z.R=d[20]; z.F=d[21]; z.A=d[22]; z.SP=d[23]|(d[24]<<8); z.IM=d[25]&3; z.border=d[26]&7;
    machine_reset();                                             /* full reset + wipe, then HALT */
    const uint8_t* ram=d+27;
    if(len<131000){                                              /* --- 48K .sna (49179) --- */
        wr_bank(5,ram); wr_bank(2,ram+16384); wr_bank(0,ram+32768);
        uint32_t sp=z.SP, pcl=0,pch=0;                           /* PC via the stack trick */
        if(sp>=0x4000 && sp<=0xFFFE){ pcl=ram[sp-0x4000]; pch=ram[sp-0x4000+1]; }
        z.PC=pcl|(pch<<8); z.SP=(sp+2)&0xFFFF; z.p7ffd=0x30;
    } else {                                                     /* --- 128K .sna --- */
        uint32_t pc=ram[49152]|(ram[49153]<<8); uint32_t p7=ram[49154]; int paged=p7&7;
        wr_bank(5,ram); wr_bank(2,ram+16384); wr_bank(paged,ram+32768);
        const uint8_t* ex=d+27+49152+4;                          /* remaining banks, skip 5/2/paged */
        const uint8_t* end=d+len;                                /* never read past EOF: guards paged in {2,5} (147487) + short/malformed files */
        for(int b=0;b<8;b++){ if(b==5||b==2||b==paged) continue; if(ex+16384>end) break; wr_bank(b,ex); ex+=16384; }
        z.PC=pc; z.p7ffd=p7&0x3F;
    }
    inject_finish(&z);
}
static void load_snapshot(void){
    char path[100]; int p=0;
    for(int i=0;curpath[i] && p<90;i++) path[p++]=curpath[i];
    if(p && path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[bcursor][i] && p<99;i++) path[p++]=flist[bcursor][i];
    path[p]=0;
    if(!sd_mounted) return;
    FIL f; UINT br=0;
    if(f_open(&f,path,FA_READ)!=FR_OK){ sd_unmount(); return; }      /* card gone -> drop, don't retry */
    if(f_read(&f,snapbuf,sizeof(snapbuf),&br)!=FR_OK){ f_close(&f); sd_unmount(); return; }
    f_close(&f);
    if(br<30) return;
    player_stop(); playing_idx=-1; g_music_path[0]=0;           /* loading a game: drop the music + return the audio mux to the fabric (else the demo is silent) */
    OSD_CTRL=0; osd_on=0; browser_on=0; osd_view=0;              /* hand the screen to the game */
    { int i=0; for(; path[i] && i<99; i++) g_app_path[i]=path[i]; g_app_path[i]=0; }  /* banner: loaded app full path */
    apply_music_halt();                                         /* music just stopped -> drop the music-HALT bit */
    update_banner();
    if(cicmp(fext(flist[bcursor]),"sna")==0) load_sna(snapbuf,(int)br);
    else load_z80(snapbuf,(int)br);
    apply_halt();                                               /* inject_finish did IJ_CTRL=0; re-assert HALT if a manual pause is still held */
}

/* ---- music auto-play: playable test, play-by-index (cursor follows), auto-advance on EOF ---- */
static int is_music_ext(int idx){
    if(idx<0 || idx>=fcount || fisdir[idx]) return 0;
    return cicmp(fext(flist[idx]),"psg")==0;      /* music extensions (extend as more decoders land) */
}
static void play_index(int idx){                  /* play flist[idx], move the cursor onto it, remember the folder */
    if(idx<0 || idx>=fcount || fisdir[idx]) return;
    char path[100]; int p=0;
    for(int i=0;curpath[i] && p<90;i++) path[p++]=curpath[i];
    if(p && path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[idx][i] && p<99;i++) path[p++]=flist[idx][i];
    path[p]=0;
    if(player_play_psg(path)){
        playing_idx = idx;
        int j=0; for(; curpath[j] && j<79; j++) play_dir[j]=curpath[j]; play_dir[j]=0;
        { int i=0; for(; path[i] && i<99; i++) g_music_path[i]=path[i]; g_music_path[i]=0; }  /* banner: track path */
        apply_music_halt();                                    /* music started: if PAUSE-MUS=YES + game loaded, assert HALT */
        bcursor = idx; sel_scroll=0; last_scroll=0;            /* cursor follows the playing track */
        if(bcursor < btop) btop=bcursor;
        if(bcursor >= btop+BROWS) btop=bcursor-BROWS+1;
        if(btop<0) btop=0;
    }
    update_banner();             /* music started/changed -> refresh the banner */
    render_browser();
}
static void player_autoadvance(void){             /* on EOF: pick the next track per opt_playmode (FOLDER/REPEAT-1/REPEAT-ALL) */
    if(playing_idx < 0) return;
    if(!sd_mounted || cicmp(curpath, play_dir)!=0){ playing_idx=-1; g_music_path[0]=0; apply_music_halt(); update_banner(); return; }  /* browsed away -> stop */
    if(opt_playmode==1){ play_index(playing_idx); return; }                     /* REPEAT-1: replay the same track */
    int n=-1;
    for(int i=playing_idx+1;i<fcount;i++) if(is_music_ext(i)){ n=i; break; }     /* next music file (sorted order) */
    if(n<0 && opt_playmode==2)                                                   /* REPEAT-ALL: wrap to the first */
        for(int i=0;i<fcount;i++) if(is_music_ext(i)){ n=i; break; }
    if(n>=0) play_index(n);
    else { playing_idx=-1; g_music_path[0]=0; apply_music_halt(); update_banner(); render_browser(); }  /* FOLDER past last -> stop */
}

static void browser_enter(void){
    if(fcount==0 || bcursor>=fcount) return;
    if(!fisdir[bcursor]){                 /* a file: Step 12.1 - load .z80/.sna via AXI inject */
        const char* e=fext(flist[bcursor]);
        if(cicmp(e,"z80")==0 || cicmp(e,"sna")==0) load_snapshot();
        else if(cicmp(e,"psg")==0) play_index(bcursor);   /* music: keep browser OPEN, cursor follows, auto-advances on end */
        return;
    }
    char came_from[NAMELEN+1]; came_from[0]=0;                 /* on ".." remember the folder we exit -> restore cursor onto it */
    if(flist[bcursor][0]=='.' && flist[bcursor][1]=='.' && flist[bcursor][2]==0){  /* ".." -> parent */
        int n=slen(curpath), cut=-1;                          /* canonical path: never a trailing slash */
        for(int i=0;i<n;i++) if(curpath[i]=='/') cut=i;       /* index of the last '/' */
        { int j=0; for(int i=cut+1; i<n && j<NAMELEN; i++) came_from[j++]=curpath[i]; came_from[j]=0; }  /* exited folder name */
        if(cut<=2) curpath[3]=0;                              /* one level up from depth 1 -> root "0:/" */
        else       curpath[cut]=0;                            /* "0:/a/b" -> "0:/a" */
    } else {                               /* descend into the folder */
        int n=slen(curpath);
        if(slen(curpath)+1+slen(flist[bcursor]) >= 78){ render_browser(); return; }  /* path too long: stay put */
        if(!(n>0 && curpath[n-1]=='/')) curpath[n++]='/';     /* ensure separator */
        for(int i=0; flist[bcursor][i] && n<79; i++) curpath[n++]=flist[bcursor][i];
        curpath[n]=0;
    }
    bcursor=0; btop=0; sel_scroll=0; last_scroll=0;           /* default: top of the new listing */
    sd_scan();
    if(came_from[0]){                                         /* went UP: put the cursor back on the folder we came from */
        for(int i=0;i<fcount;i++) if(fisdir[i] && cicmp(flist[i],came_from)==0){ bcursor=i; break; }
        if(bcursor >= btop+BROWS) btop = bcursor-BROWS+1;     /* scroll it into view */
        if(btop<0) btop=0;
    }
    render_browser();
}

/* ---- on-SD config: 0:/bulbulator.ini. Read at boot; written ONLY on explicit Save (live edits
   apply immediately but do not touch the card until you pick Save). Extensible: more [sections]/
   keys can be added later; the parser matches keys globally and ignores comments/section lines. ---- */
static FIL  g_cfg;
static char cfgbuf[512] __attribute__((aligned(32)));   /* DMA target of f_read (cache-line aligned) */
static void cfg_set(const char* k, const char* v){
    if(!cicmp(k,"sort"))
        sortmode = !cicmp(v,"date")?1 : !cicmp(v,"size")?2 : !cicmp(v,"ext")?3 : 0;
    else if(!cicmp(k,"scroll_speed"))
        opt_scroll = !cicmp(v,"slow")?0 : !cicmp(v,"fast")?2 : 1;
    else if(!cicmp(k,"folder_mark"))
        opt_foldermark = !cicmp(v,"icon")?1 : !cicmp(v,"slash")?2 : 0;
    else if(!cicmp(k,"scroll_delay"))
        opt_scrdelay = !cicmp(v,"0")?0 : !cicmp(v,"300")?1 : !cicmp(v,"500")?2 : !cicmp(v,"1000")?3 : 1;
    else if(!cicmp(k,"dim")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>100)d=100; opt_dim=(d/5)*5; }
    else if(!cicmp(k,"vol")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>100)d=100; opt_vol=(d/5)*5; }
    else if(!cicmp(k,"osd_x")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>1024)d=1024; opt_x=(d/8)*8; }
    else if(!cicmp(k,"osd_y")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>592)d=592; opt_y=(d/8)*8; }
    else if(!cicmp(k,"playmode"))
        opt_playmode = !cicmp(v,"repeat1")?1 : !cicmp(v,"repeatall")?2 : 0;
    else if(!cicmp(k,"pause_on_music")) opt_pausemusic = !cicmp(v,"yes")?1:0;
}
static void config_load(void){
    if(!sd_mounted){ if(f_mount(&g_fs,"0:/",1)!=FR_OK) return; sd_mounted=1; }
    UINT br=0;
    if(f_open(&g_cfg,"0:/bulbulator.ini",FA_READ)!=FR_OK) return;     /* no file -> keep defaults */
    f_read(&g_cfg,cfgbuf,sizeof(cfgbuf)-1,&br); f_close(&g_cfg); cfgbuf[br]=0;
    int i=0;
    while(i<(int)br){
        while(i<(int)br && (cfgbuf[i]=='\n'||cfgbuf[i]=='\r'||cfgbuf[i]==' '||cfgbuf[i]=='\t')) i++;
        int ls=i; while(i<(int)br && cfgbuf[i]!='\n' && cfgbuf[i]!='\r') i++;
        int le=i;
        if(le<=ls || cfgbuf[ls]=='#' || cfgbuf[ls]==';' || cfgbuf[ls]=='[') continue;
        int eq=-1; for(int j=ls;j<le;j++) if(cfgbuf[j]=='='){ eq=j; break; }
        if(eq<0) continue;
        char key[24], val[24]; int n;
        n=0; for(int j=ls;j<eq   && n<23;j++) if(cfgbuf[j]!=' '&&cfgbuf[j]!='\t') key[n++]=cfgbuf[j]; key[n]=0;
        n=0; for(int j=eq+1;j<le && n<23;j++) if(cfgbuf[j]!=' '&&cfgbuf[j]!='\t') val[n++]=cfgbuf[j]; val[n]=0;
        cfg_set(key,val);
    }
}
static int appstr(char* d,int p,const char* s){ for(int i=0;s[i];i++) d[p++]=s[i]; return p; }
static int config_save(void){                  /* 1 = written OK, 0 = failed (card RO/full/removed) */
    if(!sd_mounted) return 0;
    const char* sv = sortmode==1?"date":sortmode==2?"size":sortmode==3?"ext":"name";
    const char* cv = opt_scroll==0?"slow":opt_scroll==2?"fast":"med";
    const char* fv = opt_foldermark==1?"icon":opt_foldermark==2?"slash":"brackets";
    const char* dv = opt_scrdelay==0?"0":opt_scrdelay==2?"500":opt_scrdelay==3?"1000":"300";
    char o[256] __attribute__((aligned(32))); int p=0;   /* DMA source of f_write (cache-line aligned) */
    p=appstr(o,p,"# BulbuLator config\r\n[browser]\r\n");
    p=appstr(o,p,"sort=");         p=appstr(o,p,sv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"scroll_speed="); p=appstr(o,p,cv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"folder_mark=");  p=appstr(o,p,fv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"scroll_delay="); p=appstr(o,p,dv); o[p++]='\r'; o[p++]='\n';
    char dimb[8]; itoa_u(opt_dim, dimb);
    p=appstr(o,p,"dim=");          p=appstr(o,p,dimb); o[p++]='\r'; o[p++]='\n';
    char volb[8]; itoa_u(opt_vol, volb);
    p=appstr(o,p,"vol=");          p=appstr(o,p,volb); o[p++]='\r'; o[p++]='\n';
    char xb[8]; itoa_u(opt_x, xb);
    p=appstr(o,p,"osd_x=");        p=appstr(o,p,xb); o[p++]='\r'; o[p++]='\n';
    char yb[8]; itoa_u(opt_y, yb);
    p=appstr(o,p,"osd_y=");        p=appstr(o,p,yb); o[p++]='\r'; o[p++]='\n';
    const char* pv = opt_playmode==1?"repeat1":opt_playmode==2?"repeatall":"folder";
    p=appstr(o,p,"playmode=");     p=appstr(o,p,pv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"pause_on_music="); p=appstr(o,p, opt_pausemusic?"yes":"no"); o[p++]='\r'; o[p++]='\n';
    UINT bw=0;
    if(f_open(&g_cfg,"0:/bulbulator.ini",FA_CREATE_ALWAYS|FA_WRITE)!=FR_OK){ sd_unmount(); return 0; }
    FRESULT wr = f_write(&g_cfg,o,p,&bw);
    f_close(&g_cfg);
    return (wr==FR_OK && (int)bw==p) ? 1 : 0;
}

/* ---- reusable, data-driven OSD menu engine (decl. menu = title + items; generic render with
   cursor + scrollbar, generic navigation). CHOICE items cycle an int through a string list and
   apply live; ACTION items call a function on Enter. New menus are declared as data, not drawn by
   hand. (See vault note: declarative OSD menu engine.) ---- */
typedef enum { ITEM_CHOICE, ITEM_ACTION, ITEM_RANGE } item_kind;
typedef struct {
    const char*        label;
    item_kind          kind;
    int*               val;            /* CHOICE: index into choices[] (mutated live) */
    const char* const* choices;
    int                nchoices;
    void              (*action)(void); /* ACTION: invoked on Enter */
    void              (*onchange)(void);/* CHOICE/RANGE: called after a value change (e.g. write a reg) */
    int                rmax;            /* RANGE: clamp maximum (minimum is 0) */
    const char*        unit;            /* RANGE: value suffix, e.g. "%" or "" */
} menu_item;
typedef struct { const char* title; menu_item* items; int count; int cursor; int top; } menu_t;

#define MROWS 15
static void menu_render(menu_t* m){
    osd_clear();
    draw_title(m->title);
    for(int row=0; row<MROWS; row++){
        int idx=m->top+row; if(idx>=m->count) break;
        int y=8+row*8;
        draw_char(2,y,1, idx==m->cursor?'>':' ');
        menu_item* it=&m->items[idx];
        draw_text(12,y,1,it->label);
        if(it->kind==ITEM_CHOICE && it->val && it->choices){
            const char* vs=it->choices[(*it->val) % it->nchoices];
            draw_text(OSD_W - slen(vs)*8, y, 1, vs);              /* value, right-aligned */
        } else if(it->kind==ITEM_RANGE && it->val){
            char vb[12]; itoa_u(*it->val, vb); int n=slen(vb);
            if(it->unit) for(int i=0; it->unit[i]; i++) vb[n++]=it->unit[i];
            vb[n]=0;
            draw_text(OSD_W - n*8, y, 1, vb);                     /* value + unit, right-aligned */
        }
    }
    if(m->count>MROWS){                                          /* scrollbar (shared with browser) */
        int ty0=8, tyh=OSD_H-ty0, th=tyh*MROWS/m->count; if(th<4) th=4;
        int tt=ty0+(tyh-th)*m->top/(m->count-MROWS);
        for(int y=ty0;y<OSD_H;y+=2) setpix(OSD_W-1,y);
        draw_vline(OSD_W-2,tt,tt+th); draw_vline(OSD_W-1,tt,tt+th);
    }
    osd_blit();
}
static void menu_move(menu_t* m,int d){
    if(m->count==0) return;
    m->cursor+=d; if(m->cursor<0) m->cursor=0; if(m->cursor>=m->count) m->cursor=m->count-1;
    if(m->cursor<m->top) m->top=m->cursor;
    if(m->cursor>=m->top+MROWS) m->top=m->cursor-(MROWS-1);
    menu_render(m);
}
static void menu_activate(menu_t* m,int d){           /* d=+1 Enter/Right, d=-1 Left */
    if(m->count==0) return;
    menu_item* it=&m->items[m->cursor];
    if(it->kind==ITEM_CHOICE && it->val){
        *it->val = (*it->val + it->nchoices + (d>=0?1:-1)) % it->nchoices;   /* cycle, live-apply */
        if(it->onchange) it->onchange();
        menu_render(m);
    } else if(it->kind==ITEM_RANGE && it->val){
        int nv = *it->val + (d>=0?it->nchoices:-it->nchoices);   /* nchoices = step */
        if(nv<0) nv=0; if(nv>it->rmax) nv=it->rmax; *it->val = nv;
        if(it->onchange) it->onchange();
        menu_render(m);
    } else if(it->kind==ITEM_ACTION && d>0 && it->action){
        it->action();
    }
}

/* ---- options menu, declared as data ---- */
static void act_save(void){
    if(config_save()){ g_inv=1; draw_text(OSD_W-5*8,0,1,"SAVED"); g_inv=0; }
    else             { g_inv=1; draw_text(OSD_W-4*8,0,1,"FAIL");  g_inv=0; }
    osd_blit();
}
static void act_eject(void){           /* safe-eject: unmount so the card can be pulled cleanly (read-only now; add f_sync when writes land) */
    sd_unmount();
    g_inv=1; draw_text(OSD_W-14*8,0,1,"SAFE TO REMOVE"); g_inv=0;   /* right-aligned on the titlebar, like SAVED */
    osd_blit();
}
static void apply_dim(void){ OSD_OP = ((unsigned)opt_dim*255u)/100u; }  /* %% -> alpha 0..255, live */
static void apply_vol(void){ VOL_REG = ((unsigned)opt_vol*255u)/100u; }  /* %% -> gain 0..255, live */
static void apply_pos(void){ OSD_POS = ((unsigned)opt_y<<16) | (unsigned)opt_x; }  /* X0/Y0 -> reg, live */
static const char* const CH_SORT[]   = {"NAME","DATE","SIZE","EXT"};
static const char* const CH_SCROLL[] = {"SLOW","MED","FAST"};
static const char* const CH_FOLDER[] = {"BRACKETS","ICON","SLASH"};
static const char* const CH_DELAY[]  = {"0S","300MS","500MS","1S"};
static menu_item opt_items[] = {
    {"SORT",     ITEM_CHOICE, &sortmode,       CH_SORT,   4, 0},
    {"SCROLL",   ITEM_CHOICE, &opt_scroll,     CH_SCROLL, 3, 0},
    {"SCROLL DELAY", ITEM_CHOICE, &opt_scrdelay,   CH_DELAY,  4, 0},
    {"FOLDERS",  ITEM_CHOICE, &opt_foldermark, CH_FOLDER, 3, 0},
    {"PLAY MODE",ITEM_CHOICE, &opt_playmode,   CH_PLAY,   3, 0},   /* music auto-play default (F2 cycles live) */
    {"PAUSE MUS",ITEM_CHOICE, &opt_pausemusic, CH_NOYES,  2, 0, music_halt_changed},  /* music over a game: NO=mute/run, YES=halt */
    {"VOLUME",   ITEM_RANGE,  &opt_vol,        0, 5, 0, apply_vol, 100, "%"},
    {"OSD DIM",  ITEM_RANGE,  &opt_dim,        0, 5, 0, apply_dim, 100, "%"},
    {"OSD X",    ITEM_RANGE,  &opt_x,          0, 8, 0, apply_pos, 1024, ""},
    {"OSD Y",    ITEM_RANGE,  &opt_y,          0, 8, 0, apply_pos, 592,  ""},
    {"EJECT SD", ITEM_ACTION, 0, 0, 0, act_eject},
    {"SAVE",     ITEM_ACTION, 0, 0, 0, act_save},
};
static menu_t opt_menu = { "OPTIONS", opt_items, (int)(sizeof(opt_items)/sizeof(opt_items[0])), 0, 0 };
static void open_options(void){ opt_menu.cursor=0; opt_menu.top=0; menu_render(&opt_menu);
                                OSD_CTRL=1; osd_on=1; browser_on=0; opt_on=1; osd_view=4; }
static void open_help(void){ browser_on=0; opt_on=0; show_help(); OSD_CTRL=1; osd_on=1; osd_view=2; }
static void open_view(int v){ if(v==1) open_osd(); else if(v==2) open_help(); else if(v==3) open_browser(); else if(v==4) open_options(); }
static void toggle_view(int v){ if(osd_view==v) close_osd(); else open_view(v); }

/* ---- Step 13.1: full pause -------------------------------------------------------------------
   Pause asserts HALT (CONTROL bit0). HALT gates pe3M5_core, which freezes the Z80 AND the AY /
   beeper clock-enables, so the whole machine stops mid-sample; the bitstream forces the PCM to
   silence while halted (bulbulator_zx_ddr_top.v). Resume deasserts HALT: the frozen AY continues
   bit-exact - registers, envelope phase and the noise LFSR all survive the freeze - so there is no
   save/restore and no resume click. Modal: while paused only Pause (or the F10 fallback) is live. */
static int paused = 0, pst = 0, f10_h = 0;
static int halt_src = 0;     /* bitmask: bit0=manual Pause, bit1=auto pause-on-music. HALT held while nonzero. */
static void apply_halt(void){            /* single owner of IJ_CTRL bit0 (HALT) */
    if(halt_src){ IJ_CTRL = 1; while(!(IJ_STAT & 1u)){} }   /* assert + wait HALT_ACK (idempotent) */
    else IJ_CTRL = 0;                                       /* release only when no source remains */
}
static void apply_music_halt(void){      /* music start/stop or PAUSE-MUS option change */
    int want = opt_pausemusic && player_active() && !player_paused() && g_app_path[0];
    if(want) halt_src |= 2; else halt_src &= ~2;
    apply_halt();
}
static void music_halt_changed(void){ apply_music_halt(); update_banner(); }   /* F9 onchange */
/* Non-blocking pause: HALT the machine but DON'T take over the screen - the PAUSE marker lives on the
   independent banner, so menu + music stay usable while paused. */
static void pause_toggle(void){
    if(halt_src){ paused = 0; halt_src = 0; apply_halt(); }   /* drop ALL halts (manual or music) */
    else        { paused = 1; halt_src = 1; apply_halt(); }   /* manual pause -> assert HALT (+ HALT_ACK) */
    update_banner();
}

/* ---- independent status BANNER: own buffer, drawn via the retargetable g_buf, blitted over AXI ---- */
static uint32_t banbuf[BAN_WORDS];
static int ban_scroll = 0;
static XTime ban_last_scroll = 0;
static int ban_scroll_started = 0;
static void ban_select(void){ g_buf=banbuf; g_bufwpr=BAN_WPR; g_bufh=BAN_H; }
static void osd_select(void){ g_buf=osdbuf; g_bufwpr=OSD_WPR; g_bufh=OSD_H; }
static void ban_clear(void){ for(int i=0;i<BAN_WORDS;i++) banbuf[i]=0; }
static void ban_blit(void){ BAN_ADDR=0; for(int i=0;i<BAN_WORDS;i++) BAN_DATA=banbuf[i]; }
static void render_banner(void){         /* shown when (music playing) OR (paused); content = PAUSE / track / app+path */
    int app_is_paused = (halt_src != 0);
    int show_music = player_active();
    if(!app_is_paused && !show_music){ BAN_CTRL = 0; return; }   /* nothing to show -> hide the banner */
    ban_select(); ban_clear();
    int y = 0;
    if(show_music){ draw_glyph(2,y, player_paused()?pause_glyph:play_glyph);
                    draw_text_scrolled(12,y,1, g_music_path[0]?g_music_path:"(MUSIC)", ban_scroll); y+=8; }
    if(app_is_paused || g_app_path[0]){
        draw_glyph(2,y, app_is_paused ? pause_glyph : play_glyph);
        draw_text_scrolled(12,y,1, g_app_path[0]?g_app_path:"PAUSE", ban_scroll); y+=8;
    }
    osd_select();                                            /* restore OSD as the default draw target */
    ban_blit();
    BAN_CTRL = 1;
}
static void update_banner(void){         /* on state change: reset scroll and draw */
    ban_scroll = 0;
    ban_last_scroll = 0;
    ban_scroll_started = 0;
    render_banner();
}
static void banner_scroll_tick(void){
    if(BAN_CTRL == 0) return;            /* banner not visible */
    int vis = (BAN_W - 12) / 8;          /* max characters visible in the text area (256-12)/8 = 30 chars */
    int len_m = slen(g_music_path);
    int len_a = slen(g_app_path);
    int len = len_m > len_a ? len_m : len_a; /* longest visible string determines scroll cycle */
    if(len <= vis){ if(ban_scroll){ ban_scroll=0; render_banner(); } return; }
    XTime now; XTime_GetTime(&now);
    if(!ban_scroll_started){                  /* hold the name still for the configured delay first */
        static const int dly_ms[4] = {0,300,500,1000};
        if(ban_last_scroll==0){ ban_last_scroll = now; return; }                 /* stamp the start time */
        if(now - ban_last_scroll < (COUNTS_PER_SECOND/1000u)*(unsigned)dly_ms[opt_scrdelay]) return;
        ban_scroll_started = 1; ban_last_scroll = now;
    }
    static const int sps[3] = {2,3,6};                 /* marquee steps/sec for slow/med/fast */
    if(now - ban_last_scroll < (COUNTS_PER_SECOND / sps[opt_scroll])) return;
    ban_last_scroll = now;
    ban_scroll++;
    if(ban_scroll > (len - vis) + 2){ ban_scroll = 0; ban_scroll_started = 0; ban_last_scroll = now; } /* tail pause -> re-delay at start */
    render_banner();
}

/* ---- CRC32 + hex helpers for the cache/SD self-test ---- */
static uint32_t crc32_buf(const uint8_t* p, uint32_t n){
    uint32_t c = 0xFFFFFFFFu;
    for(uint32_t i=0;i<n;i++){
        c ^= p[i];
        for(int k=0;k<8;k++) c = (c>>1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1u)));
    }
    return ~c;
}
static void hex8(uint32_t v, char* o){
    for(int i=0;i<8;i++){ uint32_t nib=(v>>((7-i)*4))&0xFu; o[i]=(char)(nib<10u?('0'+nib):('A'+nib-10u)); }
    o[8]=0;
}

/* Opt-in cache/SD readback self-test. Runs ONLY if 0:/CACHETEST.BIN exists (drop any large file there
   to verify a flash; absent -> normal boot, zero cost). Reads the file MANY times into the 32-byte-
   aligned snapbuf using three chunk patterns (whole-file / 512 B / odd multi-sector) and checks the
   CRC32 is identical every pass. With D-cache ON + an UNaligned buffer the multi-sector f_read clips a
   few bytes intermittently -> a CRC mismatch. Shows PASS xN / FAIL on the OSD; any key or ~8 s
   continues. This is the recommended gate before trusting the D-cache change on real hardware. */
static void cache_selftest(void){
    FIL f;
    if(f_open(&f,"0:/CACHETEST.BIN",FA_READ)!=FR_OK) return;     /* not present -> skip silently */
    const uint32_t cap = (uint32_t)sizeof(snapbuf);
    const UINT pat[3] = { 0u /*whole*/, 512u, 4096u+32u };       /* whole-file, 1 sector, odd multi-sector */
    uint32_t ref=0, n0=0; int ok=1, passes=0;
    for(int pass=0; pass<192; pass++){
        if(f_lseek(&f,0)!=FR_OK){ ok=0; break; }
        UINT cs=pat[pass%3]; uint32_t tot=0; UINT br=0;
        if(cs==0u){
            if(f_read(&f,snapbuf,cap,&br)!=FR_OK){ ok=0; break; } tot=br;
        } else {
            while(tot<cap){ UINT want=cs; if(tot+want>cap) want=cap-tot;
                if(f_read(&f,snapbuf+tot,want,&br)!=FR_OK){ ok=0; break; }
                tot+=br; if(br<want) break; }                    /* short read = EOF */
            if(!ok) break;
        }
        uint32_t crc=crc32_buf(snapbuf,tot);
        if(pass==0){ ref=crc; n0=tot; }
        else if(crc!=ref || tot!=n0){ ok=0; passes=pass; break; }
        passes=pass+1;
    }
    f_close(&f);
    /* report on the OSD */
    char line[40]; int p; char nb[12];
    osd_clear();
    draw_text_c(6, 2, "CACHE / SD SELFTEST");
    if(ok){ p=appstr(line,0,"PASS  "); itoa_u(passes,nb); p=appstr(line,p,nb); p=appstr(line,p,"x"); }
    else  { p=appstr(line,0,"** FAIL @ pass "); itoa_u(passes,nb); p=appstr(line,p,nb); p=appstr(line,p," **"); }
    line[p]=0; draw_text_c(40,1,line);
    { char h[9]; hex8(ref,h); p=appstr(line,0,"CRC="); p=appstr(line,p,h); line[p]=0; draw_text_c(56,1,line); }
    draw_text_c(96,1,"ANY KEY = CONTINUE");
    osd_blit(); OSD_CTRL=1;
    /* dismiss: any key make, or ~8 s timeout (keep petting the deadman so the fabric stays alive) */
    XTime t0; XTime_GetTime(&t0);
    for(;;){
        KBD_HB=1;
        uint32_t d=KBD_DATA;
        if(!(d&0x100u) && !(d&0x200u)) break;            /* FIFO non-empty + not a release = a make */
        XTime now; XTime_GetTime(&now);
        if((now-t0) > (XTime)8*COUNTS_PER_SECOND) break;
    }
    osd_clear(); osd_blit(); OSD_CTRL=0;
}

void main(void){
    /* D-cache ON. boot.S enables caches+MMU; assert them here (the old code disabled D-cache to
       dodge an unaligned-buffer SD bug - now every DMA buffer is 32-byte aligned instead). The fast
       cached A9 is what lets the audio synth keep up in real time. */
    Xil_DCacheEnable();
    Xil_ICacheEnable();
    /* Carve the reserved top-of-DDR window as NON-CACHEABLE for future fabric-shared / DMA buffers.
       Each call re-attributes one 1 MB section and (this BSP) flushes D-cache + invalidates the TLB
       itself; boot-time one-off. The rest of DDR stays NORM_WB_CACHE (the boot default) = full speed. */
    for(uint32_t i=0;i<NC_MB;i++) Xil_SetTlbAttributes(NC_BASE + i*0x100000u, NORM_NONCACHE);

    osd_clear(); osd_blit();          /* clean buffer, overlay starts off */
    close_osd();                      /* F12 opens it */
    config_load();                    /* mount SD + read 0:/bulbulator.ini (defaults if absent) */
    apply_dim();                      /* push the loaded dimming level to OSD_OP */
    apply_vol();                      /* push the loaded volume level to VOL_REG */
    apply_pos();                      /* push the loaded OSD position to OSD_POS */
    BAN_POS = (640u<<16) | 512u;      /* banner bottom-centre strip, clear of the OSD */
    cache_selftest();                 /* opt-in (0:/CACHETEST.BIN): verify D-cache+SD reads are clean */

    /* Flush scancodes buffered before this controller came up (keys pressed during PL config /
       ARM reload), so the OSD always starts closed regardless of pre-boot key activity. */
    while(!(KBD_DATA & 0x100u)) { /* pop+discard until empty */ }

    /* Drain + heartbeat loop. Keep it non-blocking: exactly ONE KBD_HB write per pass (the fabric
       deadman edge-detector would miss a tight burst of kicks) and no blocking I/O on this path. */
    /* menu keys (F1/F5/F9/F12) are edge-detected + toggled uniformly via mkey + osd_view */
    for(;;){
        KBD_HB = 1;                   /* pet the deadman every iteration (single write per pass) */
        player_pump();                /* feed the audio FIFO when a music file is playing (no-op otherwise) */
        if(player_take_ended()) player_autoadvance();   /* track finished -> next per play mode (cursor follows) */
        if(browser_on) browser_scroll_tick();   /* marquee the selected long name while browsing */
        banner_scroll_tick();                   /* marquee the banner text if shown */
        uint32_t d = KBD_DATA;        /* atomic pop+read */
        if(d & 0x100u){               /* bit8 = empty FIFO (idle) -> keys are always handled before any probe */
            if(browser_on && !sd_mounted){   /* no HW card-detect: while NO CARD is shown, poll for an inserted card */
                XTime now; XTime_GetTime(&now);
                if((now - last_probe) > (COUNTS_PER_SECOND + COUNTS_PER_SECOND/2)){   /* ~1.5s throttle */
                    if(f_mount(&g_fs,"0:/",1)==FR_OK){ sd_mounted=1; sd_scan(); render_browser(); }  /* silent poll: NO CARD stays steady; on insert -> MOUNT/READ -> files */
                    else sd_unmount();
                    XTime_GetTime(&last_probe);
                }
            }
            continue;
        }
        uint32_t code = d & 0xFFu;
        /* Pause key: PS/2 set-2 sends its make as the byte run E1 14 77 (the key has no auto-repeat).
           Match on code bytes only - robust against the make/break flag - and the break burst
           E1 F0 14 F0 77 self-cancels (F0 follows E1, not 14, so the matcher just resets). */
        if(pst==1){ if(code==0x14u){ pst=2; continue; } pst=0; }
        else if(pst==2){ pst=0; if(code==0x77u){ pause_toggle(); continue; } }
        if(code==0xE1u){ pst=1; continue; }
        /* F10 = bring-up fallback for Pause (edge-detected; lives above the modal gate so it can resume too) */
        if(code==SC_F10){ if(d & 0x200u) f10_h=0; else if(!f10_h){ f10_h=1; pause_toggle(); } continue; }
        if(code==0xF0u || code==0xE0u) continue;   /* break / extended prefix frames */
        /* pause is NON-blocking: menu + music stay usable while the machine is HALTed (banner shows PAUSE) */
        int release = (d & 0x200u) != 0;           /* bit9: this code is a release */
        switch(code){
            case SC_F12:  if(release){ if(mkey==SC_F12) mkey=0; } else if(mkey!=SC_F12){ mkey=SC_F12; toggle_view(1); } break; /* header */
            case SC_F1:   if(release){ if(mkey==SC_F1)  mkey=0; } else if(mkey!=SC_F1){  mkey=SC_F1;  toggle_view(2); } break; /* help */
            case SC_F5:   if(release){ if(mkey==SC_F5)  mkey=0; } else if(mkey!=SC_F5){  mkey=SC_F5;  toggle_view(3); } break; /* browser */
            case SC_UP:    if(!release){ if(opt_on) menu_move(&opt_menu,-1); else if(browser_on) browser_move(-1); } break;
            case SC_DOWN:  if(!release){ if(opt_on) menu_move(&opt_menu,+1); else if(browser_on) browser_move(+1); } break;
            case SC_PGUP:  if(!release && browser_on) browser_move(-BROWS); break;   /* fast page scroll */
            case SC_PGDN:  if(!release && browser_on) browser_move(+BROWS); break;
            case SC_ENTER: if(!release){ if(opt_on) menu_activate(&opt_menu,+1); else if(browser_on) browser_enter(); } break;
            case SC_F3:    if(!release && browser_on){ sortmode=(sortmode+1)&3; sort_entries();
                              bcursor=0; btop=0; sel_scroll=0; last_scroll=0; render_browser(); } break;
            case SC_F2:    if(!release && browser_on){ opt_playmode=(opt_playmode+1)%3;   /* cycle play mode; reflect in the status line */
                              if(player_active()) render_browser(); else browser_status(CH_PLAY[opt_playmode]); } break;
            case SC_F9:   if(release){ if(mkey==SC_F9)  mkey=0; } else if(mkey!=SC_F9){  mkey=SC_F9;  toggle_view(4); } break; /* options */
            case SC_LEFT:  if(!release && opt_on) menu_activate(&opt_menu,-1); break;
            case SC_RIGHT: if(!release && opt_on) menu_activate(&opt_menu,+1); break;
            case SC_SPACE: if(!release){ if(player_active()){ player_pause_toggle(); apply_music_halt(); update_banner(); if(browser_on) render_browser(); }  /* playing -> pause/resume */
                                         else if(browser_on) browser_enter(); } break;                                  /* stopped -> start the selected track (like Enter) */
            case SC_BACKSPACE: if(!release){ if(player_active()){ player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt(); update_banner(); if(browser_on) render_browser(); } } break;
            case SC_ESC: if(!release && osd_on) close_osd(); break;   /* Esc: close the current view; music keeps playing (Space=pause) */
            default: break;           /* every other key belongs to the Z80 */
        }
    }
}
