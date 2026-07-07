#include <stdint.h>
#include "xil_cache.h"   /* Xil_DCacheEnable / Xil_ICacheEnable */
#include "xil_mmu.h"     /* Xil_SetTlbAttributes + NORM_NONCACHE (carve the fabric-shared DMA window) */
#include "ff.h"          /* FatFs (xilffs) - BSP provides xsdps + ChaN FatFs */
#include "mp3dec.h"      /* shared minimp3 source: MP3 as music (player) AND as cassette (edge-detect) */
#include "xtime_l.h"     /* XTime / COUNTS_PER_SECOND - long-name marquee timing */
#include "xscugic.h"     /* Step 14.3b: GIC + private timer drive the 1 ms audio-consumer interrupt */
#include "xscutimer.h"
#include "xil_exception.h"

static const char* machine_name(void);
static const char* machine_type(void);

/* universal music player (player.c): machine-agnostic ARM soft-synth -> HDMI audio FIFO */
int  player_play_psg(const char* path);
int  player_play_wav(const char* path);   /* Step 14.3: stream a .wav (PCM) as music */
int  player_play_mp3(const char* path);   /* Step 14.3: stream an .mp3 (minimp3) as music */
int  player_fmt(void);                    /* 0=PSG 1=WAV 2=MP3 */
unsigned player_src_sr(void);             /* source sample rate (Hz), 0 for PSG */
unsigned player_src_ch(void);             /* source channels */
unsigned player_bitrate_kbps(void);       /* stream bitrate for the player info line */
void player_pump(void);
void player_isr_tick(void);               /* Step 14.3b: audio consumer (1 ms timer ISR feeds the fabric FIFO) */
void player_audio_irq(int ok);            /* tell the player whether the ISR is live (else it polls inline) */
int  player_active(void);
void player_stop(void);
void player_pause_toggle(void);   /* Space: pause/resume transport */
int  player_paused(void);         /* 1 = paused */
int  player_take_ended(void);     /* consume-once: 1 if the track just reached EOF (auto-advance) */
unsigned player_elapsed_s(void);  /* seconds played so far */
unsigned player_total_s(void);    /* total track duration (pre-scanned, ZXTune method) */
unsigned player_progress(void);   /* 0..100 playback progress */
// loader_main.c - BulbuLator OSD app (Step 13): snapshot loader (.z80/.sna) + F5 SD file browser +
// options + the universal music player (player.c) with a non-blocking pause and an independent status banner.
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
/* Step 14: DDR-backed TRUE-COLOUR OSD (ARGB8888 canvas read by osd_ddr_rd over HP1; OSD_CTRL bit1=EN) */
#define OSD_DDR_BASE (*(volatile uint32_t*)(GP0+0x94))  /* DDR byte address of the ARGB canvas */
#define DDR_OSD_POS  (*(volatile uint32_t*)(GP0+0x98))  /* DDR OSD canvas position {Y0[26:16],X0[10:0]} - independent of the 1bpp OSD_POS (0x70) */
/* Step 14.2 tape station (machine-agnostic PULSE loader) */
#define TAPE_CTRL   (*(volatile uint32_t*)(GP0+0x9C))  /* bit0 run, bit1 ear_mux, bit2 mute */
#define TAPE_FIFO   (*(volatile uint32_t*)(GP0+0xA0))  /* push {level[31], duration[23:0] in T-states} */
#define TAPE_STATUS (*(volatile uint32_t*)(GP0+0xA4))  /* bit0 = FIFO full, bit1 = playing */
#define TAPE_HZ 3546900u   /* ZX128 T-state rate -> tape time in seconds = T_states / TAPE_HZ */
#define VZ_X 24         /* visualiser field (spectrum); reused for the load % (no spectrum during a load) */
#define VZ_Y 43
#define VZ_W 76
#define VZ_H 16
#define OSDC_ADDR 0x0F800000u   /* in the non-cacheable DDR window (NC_BASE+1MB): ARM writes are coherent, no flush */
#define OSDC_W    640   /* Step 14.4: DOS 80x25 canvas (VGA 8x16 font) */
#define OSDC_H    400
#include "vga866.h"             /* Step 14.4: CP866 VGA 8x16 font (ASCII+box-drawing+Cyrillic), Terminus OFL */
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
#define SC_F8    0x0Au   /* Step 14: toggle the DDR-RGB true-colour OSD window (OSD_CTRL bit1) */
#define SC_F6    0x0Bu   /* F6: rename / move */
#define SC_F7    0x83u   /* F7: make directory (mkdir) */
#define SC_INS   0x70u   /* Insert (E0 70, prefix stripped): tag/untag current entry (= Space) */
#define SC_F11   0x78u   /* hard reset (fabric-decoded); ARM taps it to mark the loaded app STOPPED */
#define SC_KPPLUS  0x79u /* numpad + : volume up   (conflict-free; ZX has no numpad) */
#define SC_KPMINUS 0x7Bu /* numpad - : volume down */
#define SC_HOME    0x6Cu /* Home (E0 6C, prefix stripped) */
#define SC_END     0x69u /* End (E0 69, prefix stripped) */

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
static const uint8_t stop_glyph[8]   = {0x00,0x00,0x7E,0x7E,0x7E,0x7E,0x00,0x00};  /* [] stopped (after F11 reset) */
static const uint8_t pend_glyph[8]   = {0x00,0x42,0x62,0x72,0x72,0x62,0x42,0x00};  /* >| FOLDER (play through, stop) */
static const uint8_t loop_glyph[8]   = {0x3C,0x42,0x81,0x81,0x81,0x42,0x3C,0x00};  /* O REPEAT (all / +'1' for one) */
static void draw_glyph(int x,int y,const uint8_t g[8]){
    for(int gy=0;gy<8;gy++) for(int gx=0;gx<8;gx++) if(g[gy]&(0x80u>>gx)) setpix(x+gx,y+gy);
}

/* ============ Step 14: DDR TRUE-COLOUR OSD canvas (ARGB8888) draw layer ============
   Flat CW*CH uint32_t ARGB array in the non-cacheable DDR window; osd_ddr_rd reads it over HP1
   (2 px / 64-bit word) and the fabric alpha-composites it over video. Alpha byte 0 => transparent
   (video shows through). Reuses the ZX 8x8 font for text. Full per-pixel FFFFFF colour. */
static volatile uint32_t* const g_osdc = (volatile uint32_t*)OSDC_ADDR;
#define ARGB(a,r,g,b) (((uint32_t)(a)<<24)|((uint32_t)(r)<<16)|((uint32_t)(g)<<8)|(uint32_t)(b))
static void osdc_clear(uint32_t c){ for(int i=0;i<OSDC_W*OSDC_H;i++) g_osdc[i]=c; }
static void osdc_rect(int x,int y,int w,int h,uint32_t c){
    for(int r=y;r<y+h;r++){ if(r<0||r>=OSDC_H) continue;
        for(int q=x;q<x+w;q++){ if(q<0||q>=OSDC_W) continue; g_osdc[r*OSDC_W+q]=c; } }
}
static void osdc_frame(int x,int y,int w,int h,int t,uint32_t c){
    osdc_rect(x,y,w,t,c); osdc_rect(x,y+h-t,w,t,c); osdc_rect(x,y,t,h,c); osdc_rect(x+w-t,y,t,h,c);
}
static void osdc_char(int x,int y,int sc,uint32_t fg,uint32_t bg,char ch){
    if(ch<32||(unsigned char)ch>127) return;
    const uint8_t* g=zxfont[(int)ch-32];
    for(int gy=0;gy<8;gy++) for(int gx=0;gx<8;gx++){
        uint32_t px=(g[gy]&(0x80u>>gx))?fg:bg;
        if((px>>24)==0) continue;                       /* transparent pixel -> leave canvas as-is */
        for(int dy=0;dy<sc;dy++) for(int dx=0;dx<sc;dx++){
            int qx=x+gx*sc+dx, qy=y+gy*sc+dy;
            if(qx>=0&&qx<OSDC_W&&qy>=0&&qy<OSDC_H) g_osdc[qy*OSDC_W+qx]=px;
        }
    }
}
static void osdc_text(int x,int y,int sc,uint32_t fg,uint32_t bg,const char* s){
    for(;*s;s++){ osdc_char(x,y,sc,fg,bg,*s); x+=8*sc; }
}
static void osdc_textn(int x,int y,int sc,uint32_t fg,uint32_t bg,const char* s,int maxc){  /* clipped to maxc chars */
    for(int i=0;*s&&i<maxc;s++,i++){ osdc_char(x,y,sc,fg,bg,*s); x+=8*sc; }
}
static void osdc_glyph(int x,int y,const uint8_t g[8],uint32_t c){   /* 8x8 mono glyph in colour c (transparent bg) */
    for(int gy=0;gy<8;gy++) for(int gx=0;gx<8;gx++) if(g[gy]&(0x80u>>gx)){
        int qx=x+gx,qy=y+gy; if(qx>=0&&qx<OSDC_W&&qy>=0&&qy<OSDC_H) g_osdc[qy*OSDC_W+qx]=c; }
}
static void osdc_text_scrolled(int x,int y,int sc,uint32_t fg,uint32_t bg,const char* s,int scroll,int maxc){
    for(int i=0;i<scroll && *s;i++) s++;        /* marquee: skip `scroll` chars, then show maxc */
    osdc_textn(x,y,sc,fg,bg,s,maxc);
}
/* Blit an ARGB8888 sprite into the canvas (opaque copy; alpha-key overlay comes with the sprite pack). */
static void osdc_blit(int dx,int dy,int sw,int sh,const uint32_t* src){
    for(int y=0;y<sh;y++){ int qy=dy+y; if(qy<0||qy>=OSDC_H) continue;
        for(int x=0;x<sw;x++){ int qx=dx+x; if(qx<0||qx>=OSDC_W) continue;
            g_osdc[qy*OSDC_W+qx]=src[y*sw+x]; } }
}
/* ============ Step 14.4: DOS Navigator-style OSD (640x400 = 80x25 @ VGA 8x16) ============
   Authentic CP437/CP866 pseudographics + Cyrillic via the Terminus VGA 8x16 font (vga866.h).
   Cells are 8x16, canvas 80x25. Panel backgrounds ~90% opaque (video faintly shows), text opaque.
   Colours ARGB8888. Filenames arrive as CP866 bytes (FatFs FF_CODE_PAGE=866) -> direct glyph index. */
#define DN_COLS 80
#define DN_ROWS 25
/* Canonical DOS 16-colour palette (indices 0-15), opaque ARGB. */
static const uint32_t DOS[16] = {
  0xFF000000u,0xFF0000AAu,0xFF00AA00u,0xFF00AAAAu,0xFFAA0000u,0xFFAA00AAu,0xFFAA5500u,0xFFAAAAAAu,
  0xFF555555u,0xFF5555FFu,0xFF55FF55u,0xFF55FFFFu,0xFFFF5555u,0xFFFF55FFu,0xFFFFFF55u,0xFFFFFFFFu };
static uint32_t g_dn_alpha = 0xCCu;   /* OSD background opacity (0x00..0xFF; adjustable via F9); text stays opaque */
#define FG(i) (DOS[(i)])                                      /* text/lines: 100% opaque */
#define BG(i) ((g_dn_alpha<<24)|(DOS[(i)]&0x00FFFFFFu))       /* background: adjustable alpha (DOS rule: bg = dark 0-7) */
#define DN_SHADOW 0x80000000u                                 /* window drop-shadow: black ~50% */
/* DN element colours = authentic DOS Navigator 1.51 default scheme (dark-gray-on-black, blink OFF,
   traced from the sources): dkgray panels, ltgray files, white dirs, black-on-cyan cursor, yellow
   headers, ltgray chrome + red hotkeys. bg carries the adjustable alpha (g_dn_alpha); text/lines
   opaque. This is ONE skin - retheme here (the ARGB engine takes any colours). */
#define DNK_PANEL_BG BG(8)     /* dark-gray file panel */
#define DNK_FRAME    FG(15)    /* white double frame (active window) */
#define DNK_SEP      FG(15)    /* white column separators / divider */
#define DNK_HEADER   FG(14)    /* yellow column headers */
#define DNK_DIR      FG(15)    /* white directories */
#define DNK_FILE     FG(7)     /* light-gray plain files */
#define DNK_SNAP     FG(11)    /* light-cyan ZX snapshots .z80/.sna (runnable, like DN exe) */
#define DNK_TAPE     FG(10)    /* light-green tape .tap/.tzx (loadable, like DN archive) */
#define DNK_MUSIC    FG(13)    /* light-magenta music .psg/.mp3/.wav */
#define DNK_CUR_BG   BG(3)     /* cyan cursor bar */
#define DNK_CUR_FG   FG(0)     /* black text on the cursor bar */
#define DNK_MENU_BG  BG(7)     /* light-gray top menu + status bar */
#define DNK_MENU_FG  FG(0)     /* black chrome text */
#define DNK_HOTKEY   FG(4)     /* red hot-key letter / F-number */
#define DNK_STATUS   FG(11)    /* accent: button pointers, progress, markers */
/* Modal dialogs are OPAQUE (DN text-mode windows never show the screen through them). FG(i)==DOS[i]
   is already 0xFF-alpha, so using FG() as a background forces full opacity - unlike BG(), which bakes
   in the adjustable OSD alpha (that translucency is only for the always-on browser panel). */
#define DNK_DLG_BG   FG(7)     /* opaque light-gray dialog body (DN gray dialog) */
#define DNK_DLG_FG   FG(0)     /* black body text */
#define DNK_DLG_FRAME FG(15)   /* white active-window frame (DN 0x7F) */
#define DNK_BTN_FACE FG(2)     /* green button face (DN 0x2x) */
#define DNK_BTN_TXT  FG(0)     /* black button label */
#define DNK_BTN_DEF  FG(11)    /* cyan: default/focused button label + ►◄ pointers (DN 0x2B) */
#define DNK_BTN_SHAD FG(8)     /* dark-gray button drop-shadow half-blocks */
#define DNK_FLD_BG   FG(0)     /* opaque BLACK input field (DN input line) */
#define DNK_FLD_FG   FG(15)    /* white field text */
enum { BX_H=0xCD,BX_V=0xBA,BX_TL=0xC9,BX_TR=0xBB,BX_BL=0xC8,BX_BR=0xBC,BX_LT=0xCC,BX_RT=0xB9,BX_TT=0xCB,BX_BT=0xCA,
       SL_H=0xC4,SL_V=0xB3,SL_TL=0xDA,SL_TR=0xBF,SL_BL=0xC0,SL_BR=0xD9, SH_L=0xB0,SH_M=0xB1,SH_D=0xB2,BLK_=0xDB };
static void dn_putc(int cx,int cy,unsigned code,uint32_t fg,uint32_t bg){
    if(cx<0||cy<0||cx>=DN_COLS||cy>=DN_ROWS) return;
    const unsigned char* g=vga866[code&0xFFu];
    for(int r=0;r<16;r++){ unsigned char bits=g[r]; int qy=cy*16+r;
        for(int c=0;c<8;c++) g_osdc[qy*OSDC_W + cx*8+c] = (bits&(0x80u>>c))?fg:bg; }
}
static void dn_puts(int cx,int cy,const char* s,uint32_t fg,uint32_t bg){
    for(; *s && cx<DN_COLS; s++,cx++) dn_putc(cx,cy,(unsigned char)*s,fg,bg); }
static void dn_putsn(int cx,int cy,const char* s,int maxc,uint32_t fg,uint32_t bg){
    for(int i=0;*s&&i<maxc&&cx<DN_COLS;s++,i++,cx++) dn_putc(cx,cy,(unsigned char)*s,fg,bg); }
static void dn_fill(int cx,int cy,int cw,int chh,uint32_t bg){
    for(int y=0;y<chh;y++) for(int x=0;x<cw;x++) dn_putc(cx+x,cy+y,' ',bg,bg); }
static void dn_hpx(int x0,int x1,int y,uint32_t c){ if(y<0||y>=OSDC_H)return; for(int x=x0;x<=x1;x++) if(x>=0&&x<OSDC_W) g_osdc[y*OSDC_W+x]=c; }
static void dn_vpx(int x,int y0,int y1,uint32_t c){ if(x<0||x>=OSDC_W)return; for(int y=y0;y<=y1;y++) if(y>=0&&y<OSDC_H) g_osdc[y*OSDC_W+x]=c; }
/* Frame as cell-aligned pixel lines. Double = two lines with a gap -> an unmistakably-double DOS frame
   (Terminus's ═/║ glyphs are 2px-adjacent and read as a single thick line at OSD scale). */
static void dn_box(int cx,int cy,int cw,int chh,uint32_t fg,uint32_t bg,int dbl){
    for(int x=0;x<cw;x++){ dn_putc(cx+x,cy,' ',bg,bg); dn_putc(cx+x,cy+chh-1,' ',bg,bg); }
    for(int y=0;y<chh;y++){ dn_putc(cx,cy+y,' ',bg,bg); dn_putc(cx+cw-1,cy+y,' ',bg,bg); }
    int ox0=cx*8+2, oy0=cy*16+5, ox1=(cx+cw)*8-3, oy1=(cy+chh)*16-6;   /* outer line */
    dn_hpx(ox0,ox1,oy0,fg); dn_hpx(ox0,ox1,oy1,fg); dn_vpx(ox0,oy0,oy1,fg); dn_vpx(ox1,oy0,oy1,fg);
    if(dbl){ int ix0=ox0+3,iy0=oy0+3,ix1=ox1-3,iy1=oy1-3;               /* inner line -> double */
        dn_hpx(ix0,ix1,iy0,fg); dn_hpx(ix0,ix1,iy1,fg); dn_vpx(ix0,iy0,iy1,fg); dn_vpx(ix1,iy0,iy1,fg); } }
static void dn_bar(int cx,int cy,int w,int frac_pm,uint32_t fg,uint32_t bg){   /* frac_pm 0..1000 */
    int f=w*frac_pm/1000; if(f>w)f=w; if(f<0)f=0;
    for(int i=0;i<w;i++) dn_putc(cx+i,cy, i<f?BLK_:SH_L, fg,bg); }
static void dn_dim_cell(int cx,int cy){                /* darken one 8x16 cell in place: TRANSLUCENT shadow - content shows through, halved brightness */
    if(cx<0||cy<0||cx>=DN_COLS||cy>=DN_ROWS) return;
    for(int r=0;r<16;r++){ int qy=cy*16+r; for(int c=0;c<8;c++){ int qx=cx*8+c;
        uint32_t p=g_osdc[qy*OSDC_W+qx]; g_osdc[qy*OSDC_W+qx]=(p&0xFF000000u)|((p>>1)&0x007F7F7Fu); } } }
static void dn_shadow(int cx,int cy,int cw,int chh){   /* DN translucent drop shadow: dims the backdrop 2 cells right + 1 down */
    for(int y=1;y<=chh;y++){ dn_dim_cell(cx+cw,cy+y); dn_dim_cell(cx+cw+1,cy+y); }
    for(int x=2;x<cw;x++) dn_dim_cell(cx+x,cy+chh); }
/* Turbo-Vision dialog button: [Label] with a 1-cell drop shadow (raised look); the default button is
   flanked by cyan pointers (>[OK]<), as in DN's Image 5. Returns the button width in cells. */
/* Solid triangle pointers for the default/focused button (font 0x10/0x11 render as thin arrows, so
   we draw real filled triangles - the same shape as the play marker). Apex points at the label. */
static const uint8_t GLYPH_TRI_R[16] = {0,0,0x80,0xC0,0xE0,0xF0,0xF8,0xFC,0xFC,0xF8,0xF0,0xE0,0xC0,0x80,0,0};
static const uint8_t GLYPH_TRI_L[16] = {0,0,0x01,0x03,0x07,0x0F,0x1F,0x3F,0x3F,0x1F,0x0F,0x07,0x03,0x01,0,0};
static void dn_put_glyph(int cx,int cy,const uint8_t* g,uint32_t fg,uint32_t bg);   /* fwd (defined with the DN row helpers) */
/* DOS Navigator button: GREEN face, black label; the default/focused button gets a cyan label
   flanked by ◣◢ solid-triangle pointers. A dark-gray drop shadow (▄ right edge, ▀ below) gives the
   raised look. `def` = draw as default/focused. Fully opaque (green face never shows the game). */
static int dn_button(int cx,int cy,const char* lab,int def,int minface){
    int len  = slen((char*)lab);
    int face = len + 4;                                    /* 2-cell pad each side (holds the ►◄ slots) */
    if (face < minface) face = minface;                    /* uniform minimum -> all buttons the same width */
    /* width is INDEPENDENT of `def`: the pointer slots are always reserved, so focus never shifts layout */

    uint32_t bg  = DNK_BTN_FACE;                           /* opaque green face */
    uint32_t txt = def ? DNK_BTN_DEF : DNK_BTN_TXT;        /* default/focused => cyan label, else black */

    for (int i = 0; i < face; i++) dn_putc(cx + i, cy, ' ', txt, bg);   /* green face */

    int lx = cx + (face - len) / 2;
    dn_puts(lx, cy, lab, txt, bg);                         /* label centred */
    if (def) {                                             /* markers at the button EDGES (fixed cols, independent of label width) */
        dn_put_glyph(cx,            cy, GLYPH_TRI_R, DNK_BTN_DEF, bg);   /* ► on the first cell */
        dn_put_glyph(cx + face - 1, cy, GLYPH_TRI_L, DNK_BTN_DEF, bg);   /* ◄ on the last cell */
    }

    dn_putc(cx + face, cy, 0xDC, DNK_BTN_SHAD, DNK_DLG_BG);         /* ▄ right shadow edge */
    for (int i = 1; i <= face; i++) dn_putc(cx + i, cy + 1, 0xDF, DNK_BTN_SHAD, DNK_DLG_BG);   /* ▀ shadow below */
    return face + 1;                                       /* total cells incl. the shadow column */
}
/* TCluster-style widgets: radio "( )/(•)" and checkbox "[ ]/[X]". foc = highlighted (cursor), dis = greyed. */
static void dn_radio(int cx,int cy,const char* lab,int sel,int foc,int dis){
    uint32_t fg=dis?FG(8):(foc?DNK_CUR_FG:DNK_DLG_FG), bg=foc?DNK_CUR_BG:DNK_DLG_BG;
    dn_putc(cx,cy,'(',fg,bg); dn_putc(cx+1,cy, sel?0x07:' ', fg, bg); dn_putc(cx+2,cy,')',fg,bg); dn_putc(cx+3,cy,' ',fg,bg);
    dn_puts(cx+4,cy,lab,fg,bg);
}
static void dn_check(int cx,int cy,const char* lab,int on,int foc,int dis){
    uint32_t fg=dis?FG(8):(foc?DNK_CUR_FG:DNK_DLG_FG), bg=foc?DNK_CUR_BG:DNK_DLG_BG;
    dn_putc(cx,cy,'[',fg,bg); dn_putc(cx+1,cy, on?'X':' ', fg, bg); dn_putc(cx+2,cy,']',fg,bg); dn_putc(cx+3,cy,' ',fg,bg);
    dn_puts(cx+4,cy,lab,fg,bg);
}
/* one-shot self-test screen: proves the 640x400 canvas + CP866 font (ASCII/Cyrillic/box/shades). */
/* Palette check: all 16 DOS colours as labelled swatches (opaque + ~80% over video) to catch a wrong
   colour / R-B swap / alpha wash. Owner reads the row whose bar doesn't match its NAME. */
static void dn_palette_test(void){
    static const char* const nm[16]={"Black","Blue","Green","Cyan","Red","Magenta","Brown","LightGray",
        "DarkGray","BrightBlue","BrightGreen","BrightCyan","BrightRed","BrightMagenta","Yellow","White"};
    static const char* const hx[16]={"000000","0000AA","00AA00","00AAAA","AA0000","AA00AA","AA5500","AAAAAA",
        "555555","5555FF","55FF55","55FFFF","FF5555","FF55FF","FFFF55","FFFFFF"};
    dn_fill(0,0,DN_COLS,DN_ROWS,FG(8));                            /* opaque mid-grey so black & white swatches show */
    dn_box(0,0,DN_COLS,DN_ROWS,FG(15),FG(8),1);
    dn_puts(3,0," DOS 16-COLOUR PALETTE CHECK ",FG(15),FG(8));
    dn_puts(30,1,"opaque",FG(15),FG(8)); dn_puts(44,1,"~80% over video",FG(15),FG(8));
    for(int i=0;i<16;i++){
        int y=2+i; char lab[48]; int p=0;
        if(i<10){lab[p++]=(char)('0'+i);} else {lab[p++]='1';lab[p++]=(char)('0'+(i-10));}
        lab[p++]=' '; for(const char* n=nm[i]; *n; n++) lab[p++]=*n;
        while(p<18) lab[p++]=' '; lab[p++]='#'; for(const char* h=hx[i]; *h; h++) lab[p++]=*h; lab[p]=0;
        dn_puts(2,y,lab,FG(15),FG(8));
        dn_fill(30,y,12,1,FG(i));                                 /* opaque: pure colour */
        dn_fill(44,y,12,1,BG(i));                                 /* ~80% alpha over the video */
    }
    dn_puts(2,19,"Compare each bar to its NAME - tell me any row whose colour is WRONG.",FG(14),FG(8));
}
/* DN mockup rendered with the flexible true-colour DNK_* theme (exact HEX from the owner's Image 3):
   gray panels, silver files, white dirs, yellow headers, teal cursor bar, bright-cyan status. */
static void dn_test(void){
    dn_fill(0,0,DN_COLS,1,DNK_MENU_BG);                                  /* top menu bar */
    dn_putc(1,0,'F',DNK_HOTKEY,DNK_MENU_BG); dn_puts(2,0,"ile",DNK_MENU_FG,DNK_MENU_BG);
    dn_putc(8,0,'C',DNK_HOTKEY,DNK_MENU_BG); dn_puts(9,0,"ommands",DNK_MENU_FG,DNK_MENU_BG);
    dn_putc(18,0,'O',DNK_HOTKEY,DNK_MENU_BG); dn_puts(19,0,"ptions",DNK_MENU_FG,DNK_MENU_BG);
    dn_putc(27,0,'H',DNK_HOTKEY,DNK_MENU_BG); dn_puts(28,0,"elp",DNK_MENU_FG,DNK_MENU_BG);
    dn_fill(0,1,DN_COLS,DN_ROWS-2,DNK_PANEL_BG);                         /* file panel */
    dn_box(0,1,DN_COLS,DN_ROWS-2,DNK_FRAME,DNK_PANEL_BG,1);
    dn_puts(3,1," 0:/loadtest/TurboLoad ",DNK_DIR,DNK_PANEL_BG);
    dn_puts(2,2,"Name",DNK_HEADER,DNK_PANEL_BG); dn_puts(42,2,"Ext",DNK_HEADER,DNK_PANEL_BG); dn_puts(50,2,"Size",DNK_HEADER,DNK_PANEL_BG); dn_puts(64,2,"Date",DNK_HEADER,DNK_PANEL_BG);
    dn_puts(2,4,"..",DNK_DIR,DNK_PANEL_BG);
    dn_puts(2,5,"speedLoad",DNK_DIR,DNK_PANEL_BG);
    dn_fill(1,6,DN_COLS-2,1,DNK_CUR_BG);                                 /* cursor bar */
    dn_puts(2,6,"AlterEgo",DNK_CUR_FG,DNK_CUR_BG); dn_puts(42,6,"wav",DNK_CUR_FG,DNK_CUR_BG); dn_puts(50,6,"128.4K",DNK_CUR_FG,DNK_CUR_BG); dn_puts(64,6,"03.07.26",DNK_CUR_FG,DNK_CUR_BG);
    dn_puts(2,7,"ManicMiner",DNK_FILE,DNK_PANEL_BG); dn_puts(42,7,"tap",DNK_FILE,DNK_PANEL_BG); dn_puts(50,7,"44.0K",DNK_FILE,DNK_PANEL_BG); dn_puts(64,7,"15.05.85",DNK_FILE,DNK_PANEL_BG);
    dn_puts(2,8,"aliens",DNK_FILE,DNK_PANEL_BG); dn_puts(42,8,"mp3",DNK_FILE,DNK_PANEL_BG); dn_puts(50,8,"2.1M",DNK_FILE,DNK_PANEL_BG); dn_puts(64,8,"03.07.26",DNK_FILE,DNK_PANEL_BG);
    { char ru[40]; int p=0; for(unsigned c=0x80;c<0xA0;c++) ru[p++]=(char)c; ru[p]=0; dn_puts(2,10,"Cyr:",DNK_HEADER,DNK_PANEL_BG); dn_puts(7,10,ru,DNK_FILE,DNK_PANEL_BG); }
    { char bx[40]; int p=0; for(unsigned c=0xB0;c<0xD0;c++) bx[p++]=(char)c; bx[p]=0; dn_puts(2,11,"Box:",DNK_HEADER,DNK_PANEL_BG); dn_puts(7,11,bx,DNK_FILE,DNK_PANEL_BG); }
    dn_puts(2,13,"Progress:",DNK_FILE,DNK_PANEL_BG); dn_bar(12,13,40,600,DNK_STATUS,DNK_PANEL_BG); dn_puts(54,13,"60%",DNK_DIR,DNK_PANEL_BG);
    dn_puts(2,DN_ROWS-3,"14 files, 1 dir",DNK_STATUS,DNK_PANEL_BG);
    dn_fill(48,14,27,8,DNK_DLG_BG); dn_box(48,14,27,8,DNK_DLG_FG,DNK_DLG_BG,0); dn_shadow(48,14,27,8);   /* dialog */
    dn_puts(55,14," Settings ",DNK_DLG_FG,DNK_DLG_BG);                    /* title centred in the border */
    dn_puts(50,16,"[X] ULA snow",DNK_DLG_FG,DNK_DLG_BG);
    dn_puts(50,17,"(o) 720p50  ( ) 720p60",DNK_DLG_FG,DNK_DLG_BG);
    dn_button(51,19,"OK",1,8); dn_button(61,19,"Cancel",0,8);            /* TV buttons: default = cyan triangle pointers + shadow */
    dn_fill(0,DN_ROWS-1,DN_COLS,1,DNK_PANEL_BG);                         /* key bar on the panel bg */
    { int x=1; const char* it[6][2]={{"1","Help"},{"3","Sort"},{"4","Info"},{"5","Load"},{"9","Opts"},{"12","Quit"}};
      for(int i=0;i<6;i++){ dn_puts(x,DN_ROWS-1,it[i][0],DNK_DIR,DNK_PANEL_BG); x+=slen((char*)it[i][0]);
                            dn_puts(x,DN_ROWS-1,it[i][1],DNK_STATUS,DNK_PANEL_BG); x+=slen((char*)it[i][1])+2; } }
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
static int browser_on;   /* tentative decl (defined with the other view flags below); needed by the early status helpers */
static void dn_status_msg(const char* s){   /* centred transient on the DN status row (22); the next status tick / list redraw repaints */
    if(!s) return;
    dn_fill(1,22,DN_COLS-2,1,DNK_PANEL_BG);
    int l=slen(s), x=(DN_COLS-l)/2; if(x<1) x=1;
    dn_puts(x,22,s,DNK_HEADER,DNK_PANEL_BG);
}
static void browser_status(const char* s){   /* transient feedback (MOUNT/READ/F2 mode): DN status row when the browser is up, else legacy 1bpp title bar */
    if(browser_on){ dn_status_msg(s); return; }
    titlebar(); g_inv=1; draw_text(OSD_W - slen(s)*8, 0, 1, s); g_inv=0; osd_blit();
}

/* Title screen (shown when the OSD opens with F12): just the name, centred, scale 2. */
/* Firmware build tag shown on the F12 splash (bump per milestone). The PL core VERSION
   (0x4000_0000) is shown live too, so the splash states exactly which firmware + bitstream run. */
#define BULB_FW "v0.14.56"
static char hexnib(uint32_t v){ return (v<10) ? ('0'+v) : ('A'+v-10); }
/* Single source of truth for the version line ("v0.13 core 0xB01B0013"): the ARM firmware tag
   BULB_FW + the live PL core VERSION read from register 0x00. Used by BOTH the F12 splash
   (show_header) and the F1 help page (show_help), so the two can never drift apart. */
static void version_str(char* out){                   /* firmware version vX.Y.Z only - the core ID never changes build-to-build, so it's dropped */
    int p=0; const char* fw = BULB_FW;
    while(*fw) out[p++]=*fw++;
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
    char v[40]; version_str(v);                              /* "v0.13 core 0xB01B0013" */
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
static int kb_alt   = 0;   /* Alt held (for Alt+F3) - mirror of g_kd[0x11] */
static int g_kb_shift = 0; /* Shift held (upper-case + symbols for text entry) - mirror of g_kd[0x12|0x59] */
static void open_osd(void){ show_header(); OSD_CTRL = (OSD_CTRL | 1u) & ~2u; osd_on = 1; browser_on = 0; opt_on = 0; osd_view = 1; }
static void close_osd(void){ OSD_CTRL &= ~3u; osd_on = 0; browser_on = 0; opt_on = 0; osd_view = 0; }  /* DN-only build: clear both OSD layers */

/* ---- F5 SD file browser (read-only) with directory navigation, into the 256x128 OSD panel ---- */
#define MAXFILES 256
#define BROWS    18                       /* file rows visible in the DN 80x25 panel */
#define NAMELEN  96                 /* store the full long name (panel shows VISCH; marquee reveals the rest) */
static char  flist[MAXFILES][NAMELEN+1];
static uint8_t fisdir[MAXFILES];
static uint8_t fhidden[MAXFILES];   /* 1 = hidden/system/dotfile (shown only when opt_showhidden; marked in the list) */
static uint8_t fsel[MAXFILES];      /* 1 = tagged (Space, DN group-select) -> group copy/delete/move */
static void menubar_draw(int cur);
static void draw_topstatus(void);   /* top-right: machine status + volume + version */
static void mkdir_path(const char* path);   /* create missing folders in a "0:/a/b/c" path */
static uint64_t count_tree(char* path);      /* total bytes under a folder (progress denominator) */
static int copy_move_run(char* src, char* dst, int isdir, uint64_t total, int removesrc, const char* title);
static int  selcount(void);                  /* # of tagged (Space) entries, excl ".." */
static void group_copy_move(int removesrc, const char* title);   /* group copy/move to a folder */
static void open_help(void);
static void run_menu_system(void);
static uint32_t fsz[MAXFILES];          /* file size in bytes (0 for dirs / "..") */
static uint32_t fdt[MAXFILES];          /* (FAT date<<16)|time, for chronological sort */
static int   fcount = 0, bcursor = 0, btop = 0, sd_mounted = 0;
static int   sortmode = 0;              /* 0=NAME 1=DATE 2=SIZE 3=EXT */
static int   g_sort_desc = 0;           /* 0=ascending (default), 1=descending; Alt+F3 toggles, F3 (mode change) resets to asc */
static int   g_menu_open = 0;           /* a modal dropdown is on screen: suppress list/marquee redraws beneath it */
static int   g_suppress_browser_draw = 0;  /* a modal/progress window owns the screen: auto-advance may start the next
                                              track but must NOT touch the file list or move the browser cursor */
static int   g_list_dirty = 0;          /* the list was re-sorted under an open menu: redraw it once on menu exit */
static int   g_alpha_dirty = 0;         /* the canvas alpha changed under an open menu: FULL repaint needed */
static int   opt_scroll     = 1;        /* long-name marquee speed: 0=slow 1=med 2=fast */
static int   opt_foldermark = 0;        /* folder tag style: 0=[brackets] 1=icon 2=trailing-slash */
static int   opt_scrdelay    = 1;        /* marquee START delay: 0=0ms 1=300ms 2=500ms 3=1000ms */
static int   opt_dim         = 80;       /* OSD panel dimming/opacity %% (5%% steps) */
static int   opt_vol         = 100;      /* HDMI output volume %% (5%% steps); 100 = unity */
static int   opt_x           = 320;      /* navigator (DN canvas) left X0 in 1280x720 (0..640, step 8) */
static int   opt_y           = 160;      /* navigator top Y0 (0..320, step 8) */
static int   opt_pl_x        = 504;      /* player window left X0 (0..1024, step 8); default centres the 275-wide window */
static int   opt_pl_y        = 256;      /* player window top  Y0 (0..592,  step 8); default leaves room for the playlist below */
static int   opt_playmode    = 0;        /* music auto-play mode: 0=FOLDER(play to end, stop) 1=FILE(one track, stop)
                                            2=FOLDER LOOP 3=FILE LOOP 4=RANDOM(shuffle in folder) */
static const char* const CH_PLAY[] = {"FOLDER","FILE","FOLDER LOOP","FILE LOOP","RANDOM"};   /* shared by F2 / menu / status */
#define N_PLAYMODES 5
static int   playing_idx     = -1;       /* flist index of the currently-playing track (-1 = none) */
static char  play_dir[80]    = "";       /* folder (curpath) where the current playback started (auto-advance scope) */
static int   opt_pausemusic  = 0;        /* 0=NO (game runs in background, audio muted by FIFO mux) 1=YES (HALT when music plays over a game) */
static int   opt_tapesound   = 1;        /* Step 14.2: 1=YES hear the tape loading sound, 0=NO real-time load but muted */
static int   opt_showhidden  = 0;        /* 0=hide hidden/system + dotfiles (macOS .DS_Store/._* junk), 1=show all */
static int   opt_timemode    = 0;        /* upper-window time: 0=remaining (-M:SS), 1=elapsed (M:SS) */
static int   opt_mp3tape     = 0;        /* 1=always treat .mp3 as tape (for turbo digitised collections; bypasses fragile pilot detect), 0=auto-detect */
static int   opt_longleader  = 1;        /* 1=prepend a long clean pilot leader before the file so the ZX always locks; off for rare exact-pilot-count loaders */
int          opt_preload     = 0;        /* 0=NO (stream from SD, instant start) 1=YES (preload whole file to DDR, prevents SD-stalls) */
/* MP3/WAV tape reader: only the comparator hysteresis is user-tunable (exposed as "MP3 SENS" in F9).
   Interpolation is always on (required for turbo). The POWADCR F6 tuner + its 13 dead params were
   removed 2026-07-03 once the real fix (the interp formula) landed - they tuned nothing. */
static int tune_hys_mp3 = 1024;      /* Schmitt hysteresis for MP3 tape (lower = more sensitive) */
static void update_banner(void);     /* fwd */
static void render_browser(void);    /* fwd */
static const char* const CH_NOYES[] = {"NO","YES"};
static const char* const CH_012[] = {"0","1","2"};
/* ---- pause/now-playing BANNER state (independent overlay) ---- */
static char  g_app_path[180] = "";       /* full SD path of the last-loaded snapshot (game/demo) */
static int   g_app_stopped   = 0;        /* 1 = the loaded app was hard-reset (F11): keep the name, show STOP */
static char  g_music_path[180] = ""; /* full path of the currently-playing track */
static void  update_banner(void);        /* fwd (defined after the pause section) */
static void  apply_music_halt(void);     /* fwd (HALT coordination) */
static void  apply_halt(void);           /* fwd (single owner of IJ_CTRL HALT bit) */
static void  sdop_freeze_begin(void);    /* fwd: freeze the machine (tape in lock-step) around a blocking SD op */
static void  sdop_freeze_end(void);
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
/* "less" = a should appear before b. Folders always above files (both directions); then the active
   sort key ASCENDING by default (name/ext A->Z, date oldest first, size smallest first). g_sort_desc
   (Alt+F3) flips the direction. Tie-break always by name. */
static int ent_less(int a, int b){
    if(fisdir[a]!=fisdir[b]) return fisdir[a] > fisdir[b];    /* folders always on top */
    int c=0;                                                 /* ascending comparison: <0 => a before b */
    switch(sortmode){
        case 1: c = (fdt[a]<fdt[b])?-1:(fdt[a]>fdt[b])?1:0; break;      /* DATE (asc = oldest first) */
        case 2: c = (fsz[a]<fsz[b])?-1:(fsz[a]>fsz[b])?1:0; break;      /* SIZE (asc = smallest first) */
        case 3: c = cicmp(fext(flist[a]), fext(flist[b])); break;      /* EXT */
        default: break;                                                /* NAME */
    }
    if(c==0) c = cicmp(flist[a], flist[b]);                  /* tie-break by name */
    return g_sort_desc ? (c > 0) : (c < 0);
}
static void swap_ent(int i, int j){
    char tmp[NAMELEN+1]; for(int k=0;k<=NAMELEN;k++){ tmp[k]=flist[i][k]; flist[i][k]=flist[j][k]; flist[j][k]=tmp[k]; }
    uint8_t  d=fisdir[i]; fisdir[i]=fisdir[j]; fisdir[j]=d;
    uint8_t  h=fhidden[i];fhidden[i]=fhidden[j];fhidden[j]=h;
    uint8_t  g=fsel[i];   fsel[i]=fsel[j];       fsel[j]=g;
    uint32_t s=fsz[i];    fsz[i]=fsz[j];       fsz[j]=s;
    uint32_t t=fdt[i];    fdt[i]=fdt[j];       fdt[j]=t;
}
static void sort_entries(void){                        /* insertion sort; keep ".." pinned at row 0 */
    int base = is_root() ? 0 : 1;
    for(int i=base+1; i<fcount; i++)
        for(int j=i; j>base && ent_less(j, j-1); j--) swap_ent(j, j-1);
}
/* Filename part of a full path (after the last '/'). */
static const char* base_name(const char* path){
    const char* b = path; for(const char* p=path; *p; p++) if(*p=='/') b = p+1; return b;
}
/* sort_entries()/sd_scan physically reorder flist[], so the raw playing_idx no longer points at the
   playing track. Re-find it by name in the current folder. Only meaningful while the playing folder
   is the one on screen (curpath==play_dir); otherwise the autoadvance folder-scope guard handles it. */
static void remap_playing_idx(void){
    if(playing_idx < 0 || !player_active()) return;
    if(cicmp(curpath, play_dir) != 0) return;          /* not the playing folder: index is unused (guarded) */
    const char* nm = base_name(g_music_path);
    for(int i=0;i<fcount;i++) if(!fisdir[i] && cicmp(flist[i], nm)==0){ playing_idx = i; return; }
    playing_idx = -1;                                  /* the playing file vanished from this listing */
}

static void sd_scan(void){               /* mount once + read curpath into flist[] */
    fcount = 0;   /* keep bcursor/btop: only a directory change resets the cursor, so a re-open (F5) lands where you were */
    for(int i=0;i<MAXFILES;i++) fsel[i]=0;   /* a fresh listing invalidates the old tags (indices change) */
    if(!sd_mounted){
        browser_status("MOUNT");                  /* instant status: mount can take ~1s on a flaky/absent card */
        if(f_mount(&g_fs, "0:/", 1) != FR_OK){ sd_unmount(); return; }
        sd_mounted = 1;
    }
    browser_status("READ");
    if(!is_root()){                       /* synthetic ".." to go up */
        flist[0][0]='.'; flist[0][1]='.'; flist[0][2]=0; fisdir[0]=1; fhidden[0]=0;
        fsz[0]=0; fdt[0]=0; fcount=1;
    }
    DIR dir; FILINFO fno; FRESULT rr=FR_OK;
    if(f_opendir(&dir, curpath) != FR_OK){           /* stale mount (card swapped) or gone: try ONE fresh remount */
        sd_unmount();
        if(f_mount(&g_fs,"0:/",1)!=FR_OK){ sd_unmount(); return; }   sd_mounted=1;
        if(f_opendir(&dir, curpath) != FR_OK){ sd_unmount(); return; }   /* really gone -> NO CARD */
    }
    while(fcount < MAXFILES && (rr=f_readdir(&dir, &fno)) == FR_OK && fno.fname[0]){
        if(!opt_showhidden){                                  /* hide hidden/system + dotfiles (macOS .DS_Store, ._x, .Trashes, .Spotlight junk) */
            if(fno.fattrib & (AM_HID|AM_SYS)) continue;
            if(fno.fname[0]=='.') continue;
        }
        int n=0; for(; fno.fname[n] && n<NAMELEN; n++) flist[fcount][n]=fno.fname[n];
        flist[fcount][n]=0;
        fisdir[fcount] = (fno.fattrib & AM_DIR) ? 1 : 0;
        fhidden[fcount]= ((fno.fattrib & (AM_HID|AM_SYS)) || fno.fname[0]=='.') ? 1 : 0;
        fsz[fcount]    = (uint32_t)fno.fsize;
        fdt[fcount]    = ((uint32_t)fno.fdate << 16) | fno.ftime;
        fcount++;
    }
    f_closedir(&dir);
    if(rr != FR_OK){ sd_unmount(); return; }   /* error mid-enumeration -> card gone, don't show a partial list */
    sort_entries();
    remap_playing_idx();                                   /* keep playing_idx on the playing track after the re-sort */
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
__attribute__((unused)) static void render_browser_1bpp(void){
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
/* ============ Step 14.4: file browser one-to-one in DOS Navigator style (colour DDR canvas) ============
   OUR file list (flist/fisdir/fsz/fdt) drawn with DN's visual language: double-frame active panel,
   path in the top border (white-on-cyan), yellow column headers with the active-sort column
   highlighted, per-type file colours, cyan cursor bar, scrollbar, DN key bar. Columns are OURS -
   Name / Ext / Size / Date - matching the four F3 sort modes. Supersedes the 1bpp render_browser. */
#define DNB_NAME  2     /* every column gets 1 space of padding each side -> content never touches frame/separators */
#define DNB_NAMEW 47    /* name cols 2..48; col 49 = trailing space before SEP1@50 (col 1 = leading space) */
#define DNB_SEP1  50    /* ext cell narrowed 1 -> exactly 1 space before the right-aligned ext (3-char z80/tap/wav...) */
#define DNB_EXT   51    /* ext cell: header left here; DATA right-aligned to DNB_EXTE for a clean 1-space right gutter */
#define DNB_EXTE  54    /* ext data right edge -> col 55 stays a space before SEP2 (3- and 4-char ext both get 1 gutter) */
#define DNB_SEP2  56
#define DNB_SIZE  58    /* space(57) | size right-aligned within 58..64 | space(65) */
#define DNB_SIZEE 64    /* size right edge -> col 65 stays a space before SEP3 */
#define DNB_SEP3  66
#define DNB_DATE  68    /* space(67) | date 68..77 (DD.MM.YYYY) | space(78) before the scrollbar */
#define DNB_SCR   79    /* scrollbar sits ON the right frame column, always shown (DN-style) */
#define DNB_LIST0 3
static void fmt_size_dn(uint32_t b, char* o){
    if(b>=1048576u){ uint32_t m10=(b*10u+524288u)/1048576u; itoa_u((int)(m10/10u),o); int n=slen(o); o[n++]='.'; o[n++]=(char)('0'+(m10%10u)); o[n++]='M'; o[n]=0; }
    else if(b>=1024u){ uint32_t k=(b+512u)/1024u; itoa_u((int)k,o); int n=slen(o); o[n++]='K'; o[n]=0; }
    else itoa_u((int)b,o);
}
static void fmt_date_dn(uint32_t dt, char* o){    /* DD.MM.YYYY (full year) */
    uint32_t d=dt>>16; if(d==0u){ o[0]=0; return; }
    int day=(int)(d&31u), mon=(int)((d>>5)&15u), yr=1980+(int)((d>>9)&127u);
    o[0]=(char)('0'+day/10); o[1]=(char)('0'+day%10); o[2]='.';
    o[3]=(char)('0'+mon/10); o[4]=(char)('0'+mon%10); o[5]='.';
    o[6]=(char)('0'+yr/1000); o[7]=(char)('0'+(yr/100)%10); o[8]=(char)('0'+(yr/10)%10); o[9]=(char)('0'+yr%10); o[10]=0;
}
static uint32_t dn_type_fg(int idx){
    if(fisdir[idx]) return DNK_DIR;
    const char* e=fext(flist[idx]);
    if(cicmp(e,"z80")==0||cicmp(e,"sna")==0) return DNK_SNAP;
    if(cicmp(e,"tap")==0||cicmp(e,"tzx")==0) return DNK_TAPE;
    if(cicmp(e,"psg")==0||cicmp(e,"wav")==0||cicmp(e,"mp3")==0) return DNK_MUSIC;
    return DNK_FILE;
}
/* proper transport glyphs (drawn as custom 8x16 bitmaps, not font chars): ► filled play triangle, ‖ two-bar pause */
static const uint8_t GLYPH_PLAY[16]  = {0,0,0x80,0xC0,0xE0,0xF0,0xF8,0xFC,0xFC,0xF8,0xF0,0xE0,0xC0,0x80,0,0};
static const uint8_t GLYPH_PAUSE[16] = {0,0,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0,0};
static void dn_put_glyph(int cx,int cy,const uint8_t* g,uint32_t fg,uint32_t bg){   /* like dn_putc but from a custom 8x16 bitmap */
    if(cx<0||cy<0||cx>=DN_COLS||cy>=DN_ROWS) return;
    for(int r=0;r<16;r++){ unsigned char bits=g[r]; int qy=cy*16+r;
        for(int c=0;c<8;c++) g_osdc[qy*OSDC_W + cx*8+c] = (bits&(0x80u>>c))?fg:bg; }
}
/* Play-mode indicator glyphs (custom 8x16). The 5 modes = {folder,file}x{once,loop} + random, shown
   as TWO cells: a SCOPE glyph (list=folder / single-line=file) + a BEHAVIOUR glyph (arrow=play-once /
   loop=repeat); RANDOM is a single shuffle-cross glyph. Drawn in the status bar after the track name. */
static const uint8_t G_M_LIST [16] = {0,0,0,0x7E,0,0,0,0x7E,0,0,0,0x7E,0,0,0,0};      /* ≡ three lines = folder/list */
static const uint8_t G_M_ONE  [16] = {0,0,0,0,0,0,0,0x7E,0x7E,0,0,0,0,0,0,0};          /* ─ single line = one file    */
static const uint8_t G_M_ARROW[16] = {0,0,0,0,0,0x08,0x0C,0x0E,0xFF,0x0E,0x0C,0x08,0,0,0,0}; /* → play once/sequential */
static const uint8_t G_M_LOOP [16] = {0,0,0,0x3C,0x66,0xC3,0xC3,0xC3,0xC3,0x66,0x3C,0,0,0,0,0}; /* ○ clean ring = loop/repeat */
static const uint8_t G_M_SHUF [16] = {0,0,0,0xC3,0x66,0x3C,0x18,0x18,0x3C,0x66,0xC3,0,0,0,0,0};    /* ⤬ shuffle/random */
static void dn_draw_playmode(int cx,int cy,uint32_t fg,uint32_t bg){   /* 2 cells (random = 1, right cell blanked) */
    dn_putc(cx,cy,' ',fg,bg); dn_putc(cx+1,cy,' ',fg,bg);
    const uint8_t* scope; const uint8_t* beh;
    switch(opt_playmode){
        case 0: scope=G_M_LIST; beh=G_M_ARROW; break;   /* FOLDER      */
        case 1: scope=G_M_ONE;  beh=G_M_ARROW; break;   /* FILE        */
        case 2: scope=G_M_LIST; beh=G_M_LOOP;  break;   /* FOLDER LOOP */
        case 3: scope=G_M_ONE;  beh=G_M_LOOP;  break;   /* FILE LOOP   */
        default: dn_put_glyph(cx,cy,G_M_SHUF,fg,bg); return;   /* RANDOM (single glyph) */
    }
    dn_put_glyph(cx,cy,scope,fg,bg);
    dn_put_glyph(cx+1,cy,beh,fg,bg);
}
/* Is this row on the current playback path? -> the playing track (in its folder), OR any ancestor
   folder that (at any nesting level) contains the playing track. Used to show the > marker. */
static int on_play_path(int idx){
    if(!player_active() || idx<0 || idx>=fcount) return 0;
    if(!fisdir[idx]) return idx==playing_idx && cicmp(curpath,play_dir)==0;    /* the track itself, only in its folder */
    if(flist[idx][0]=='.' && flist[idx][1]=='.' && flist[idx][2]==0) return 0; /* ".." never marked */
    char fp[100]; int p=0;                                                    /* this folder's canonical full path */
    for(int i=0; curpath[i] && p<80; i++) fp[p++]=curpath[i];
    if(p>0 && fp[p-1]!='/') fp[p++]='/';
    for(int i=0; flist[idx][i] && p<98; i++) fp[p++]=flist[idx][i];
    fp[p]=0;
    for(int i=0;i<p;i++){ char a=fp[i], b=play_dir[i]; if(!b) return 0;        /* fp must be a prefix of play_dir (case-insensitive) */
        if(a>='A'&&a<='Z') a=(char)(a+32); if(b>='A'&&b<='Z') b=(char)(b+32); if(a!=b) return 0; }
    return play_dir[p]==0 || play_dir[p]=='/';                                 /* ...ending on a path boundary -> ancestor-or-equal */
}
static void dn_draw_file_row(int idx){          /* draw/refresh ONE file row in place (for fast partial redraw) */
    if(idx<btop || idx>=btop+BROWS || idx>=fcount) return;
    int y=DNB_LIST0+(idx-btop), cur=(idx==bcursor);
    uint32_t bg=cur?DNK_CUR_BG:DNK_PANEL_BG;
    uint32_t fg=fsel[idx] ? FG(14) : (cur?DNK_CUR_FG:dn_type_fg(idx));   /* tagged = yellow (DN group-select) */
    dn_fill(1,y,DNB_SCR-1,1,bg);                 /* erase row bg up to (not over) the scrollbar column */
    const char* src=flist[idx]; const char* e=fext(src); int nl=slen(src);
    int base=(!fisdir[idx] && *e) ? (int)(e-src)-1 : nl; if(base<0) base=0;      /* base-name length (before .ext) */
    int so=(idx==bcursor && sel_scroll>0 && sel_scroll<base) ? sel_scroll : 0;  /* marquee offset - cursor row only */
    int shown=base-so; if(shown>DNB_NAMEW) shown=DNB_NAMEW; if(shown<0) shown=0;
    char nm[64]; int k=0; for(; k<shown && k<63; k++) nm[k]=src[so+k]; nm[k]=0;
    dn_puts(DNB_NAME,y,nm,fg,bg);
    if(!fisdir[idx] && *e){ char ex[6]; int j=0; for(; e[j] && j<4; j++) ex[j]=e[j]; ex[j]=0;
        int exx=DNB_EXTE-j+1; if(exx<DNB_EXT) exx=DNB_EXT; dn_puts(exx,y,ex,fg,bg); }   /* right-aligned: 1-space gutter for any ext length */
    if(fisdir[idx]) dn_puts(DNB_SIZE,y,"<DIR>",fg,bg);
    else { char sz[12]; fmt_size_dn(fsz[idx],sz); int sl2=slen(sz); int sx=DNB_SIZEE-sl2+1; if(sx<DNB_SIZE) sx=DNB_SIZE; dn_puts(sx,y,sz,fg,bg); }
    { char dt[12]; fmt_date_dn(fdt[idx],dt); if(dt[0]) dn_puts(DNB_DATE,y,dt,fg,bg); }
    if(fhidden[idx]) dn_putc(DNB_SEP1-1,y, 0xB0, cur?DNK_CUR_FG:DNK_STATUS, bg);   /* hidden/system marker (░ light shade) at the end of the name */
    dn_putc(DNB_SEP1,y,SL_V,cur?DNK_CUR_FG:DNK_SEP,bg); dn_putc(DNB_SEP2,y,SL_V,cur?DNK_CUR_FG:DNK_SEP,bg); dn_putc(DNB_SEP3,y,SL_V,cur?DNK_CUR_FG:DNK_SEP,bg);
    if(on_play_path(idx)) dn_put_glyph(1,y, player_paused()?GLYPH_PAUSE:GLYPH_PLAY, DNK_STATUS,bg);   /* marker on the track + every ancestor folder of the play path */
}
static int g_status_scroll=0, g_status_started=0; static XTime g_status_last=0;   /* status-bar full-path marquee state */
static void fmt_mmss(unsigned s, char* o){       /* seconds -> "M:SS" / "MM:SS" */
    unsigned m=s/60u, ss=s%60u; if(m>99u)m=99u; int p=0;
    if(m>=10u) o[p++]=(char)('0'+m/10u);
    o[p++]=(char)('0'+m%10u); o[p++]=':';
    o[p++]=(char)('0'+ss/10u); o[p++]=(char)('0'+ss%10u); o[p]=0;
}
/* row 22 status line: DN playback status while music plays (>/|| + name + M:SS/M:SS + progress bar), else file count + sort */
static void dn_draw_status(void){
    dn_fill(1,22,DN_COLS-2,1,DNK_PANEL_BG);
    if(player_active()){
        dn_put_glyph(2,22, player_paused()?GLYPH_PAUSE:GLYPH_PLAY, DNK_MUSIC, DNK_PANEL_BG);
        { const char* mp=g_music_path; int ml=slen(mp), W=40, so=(ml>W)?g_status_scroll:0;
          if(so>ml-W) so=ml-W; if(so<0) so=0;
          dn_putsn(4,22, mp+so, W, DNK_DIR, DNK_PANEL_BG); }             /* FULL path incl filename; marquee via g_status_scroll if long */
        dn_draw_playmode(44,22, DNK_MUSIC, DNK_PANEL_BG);               /* play-mode glyphs: after the name, before the time */
        { unsigned el=player_elapsed_s(), tot=player_total_s(); if(el>5999u)el=5999u; if(tot>5999u)tot=5999u;
          char t1[8],t2[8],tb[18]; fmt_mmss(el,t1); fmt_mmss(tot,t2);
          int p=0; for(int i=0;t1[i];i++)tb[p++]=t1[i]; tb[p++]='/'; for(int i=0;t2[i];i++)tb[p++]=t2[i]; tb[p]=0;
          dn_puts(47,22,tb,DNK_HEADER,DNK_PANEL_BG); }
        { unsigned pct=player_progress(); if(pct>100u)pct=100u; dn_bar(59,22,DNB_SCR-1-59,pct*10u,DNK_STATUS,DNK_PANEL_BG); }
    } else {
        char inf[40]; int n=0; const char* lbl="Files: "; for(int i=0;lbl[i];i++) inf[n++]=lbl[i]; char c[8]; itoa_u(fcount,c); for(int i=0;c[i];i++) inf[n++]=c[i]; inf[n]=0;
        dn_puts(2,22,inf,DNK_STATUS,DNK_PANEL_BG);
        const char* sm=sort_label(); int tw=6+slen(sm)+2; int sx=DN_COLS-2-tw; if(sx<20) sx=20;
        dn_puts(sx,22,"Sort: ",DNK_FILE,DNK_PANEL_BG); dn_puts(sx+6,22,sm,DNK_HEADER,DNK_PANEL_BG);
        dn_putc(sx+6+slen(sm)+1,22,g_sort_desc?0x1Fu:0x1Eu,DNK_HEADER,DNK_PANEL_BG);
    }
}
static void status_scroll_tick(void){            /* marquee the full track path in the status bar when it doesn't fit */
    if(!player_active()){ if(g_status_scroll){ g_status_scroll=0; g_status_started=0; g_status_last=0; } return; }
    int len=slen(g_music_path); if(len<=40){ if(g_status_scroll){ g_status_scroll=0; dn_draw_status(); } return; }
    XTime now; XTime_GetTime(&now);
    if(!g_status_started){ static const int dly[4]={0,300,500,1000};
        if(g_status_last==0){ g_status_last=now; return; }
        if(now-g_status_last < (COUNTS_PER_SECOND/1000u)*(unsigned)dly[opt_scrdelay]) return;
        g_status_started=1; g_status_last=now; }
    static const int sps[3]={2,3,6};
    if(now-g_status_last < (COUNTS_PER_SECOND/sps[opt_scroll])) return;
    g_status_last=now; g_status_scroll++;
    if(g_status_scroll > (len-40)+2){ g_status_scroll=0; g_status_started=0; g_status_last=now; }
    dn_draw_status();
}
static void dn_draw_list(void){                  /* redraw ONLY the dynamic panel content (headers+rows+scrollbar+info) - chrome (menu/path/frame/keybar) untouched -> no flicker on sort/scroll */
    if(!sd_mounted){ dn_puts(3,3,"SD: NO CARD / NOT FAT",DNK_HEADER,DNK_PANEL_BG); return; }
    dn_fill(1,2,DN_COLS-2,1,DNK_PANEL_BG);       /* clear header row (erase the old active-sort highlight) */
    int hn=(sortmode==0),he=(sortmode==3),hs=(sortmode==2),hd=(sortmode==1);
    dn_puts(DNB_NAME,2,"Name", hn?FG(0):DNK_HEADER, hn?BG(14):DNK_PANEL_BG);
    dn_puts(DNB_EXT+1,2,"Ext" , he?FG(0):DNK_HEADER, he?BG(14):DNK_PANEL_BG);  /* +1 = align header with the right-aligned 3-char data (1-space gutter) */
    dn_puts(DNB_SIZE,2,"Size", hs?FG(0):DNK_HEADER, hs?BG(14):DNK_PANEL_BG);
    dn_puts(DNB_DATE,2,"Date", hd?FG(0):DNK_HEADER, hd?BG(14):DNK_PANEL_BG);
    dn_putc(DNB_SEP1,2,SL_V,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP2,2,SL_V,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP3,2,SL_V,DNK_SEP,DNK_PANEL_BG);
    for(int row=0; row<BROWS; row++){ int idx=btop+row, y=DNB_LIST0+row;
        if(idx>=fcount){ dn_fill(1,y,DNB_SCR-1,1,DNK_PANEL_BG); dn_putc(DNB_SEP1,y,SL_V,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP2,y,SL_V,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP3,y,SL_V,DNK_SEP,DNK_PANEL_BG); }
        else dn_draw_file_row(idx); }
    /* scrollbar ON the right frame column, logic per Turbo Vision TScrollBar (VIEWS.PAS): arrows +
       (▒ page with a proportional ■ thumb) when there's range, else ▓ disabled fill (no thumb). */
    dn_putc(DNB_SCR,DNB_LIST0,0x1Eu,DNK_FRAME,DNK_PANEL_BG);                          /* up arrow */
    dn_putc(DNB_SCR,DNB_LIST0+BROWS-1,0x1Fu,DNK_FRAME,DNK_PANEL_BG);                  /* down arrow */
    if(fcount>BROWS){
        int sh=BROWS-2;                                                              /* shaft rows between the arrows */
        int ts=sh*BROWS/fcount; if(ts<1)ts=1; if(ts>sh)ts=sh;                         /* proportional thumb size */
        int tp=(sh-ts)*btop/(fcount-BROWS); if(tp<0)tp=0; if(tp>sh-ts)tp=sh-ts;       /* thumb position */
        for(int r=0;r<sh;r++) dn_putc(DNB_SCR,DNB_LIST0+1+r,0xDBu,(r>=tp&&r<tp+ts)?DNK_FRAME:DNK_FILE,DNK_PANEL_BG);  /* SOLID full block: white thumb over lt-gray track (no dither zebra) */
    } else for(int r=0;r<BROWS-2;r++) dn_putc(DNB_SCR,DNB_LIST0+1+r,0xDBu,DNK_FILE,DNK_PANEL_BG);  /* list fits: shaft/track ALWAYS drawn (lt-gray), just no thumb */
    for(int x=1;x<DN_COLS-1;x++) dn_putc(x,21,SL_H,DNK_SEP,DNK_PANEL_BG);
    dn_putc(DNB_SEP1,21,0xC1,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP2,21,0xC1,DNK_SEP,DNK_PANEL_BG); dn_putc(DNB_SEP3,21,0xC1,DNK_SEP,DNK_PANEL_BG);
    dn_draw_status();                                        /* row 22: music status while playing, else file count + sort */
}
static void sort_changed(void){   /* SORT changed from a menu value-item: re-sort live (F3 parity, else the list goes stale) */
    if(!sd_mounted || !fcount) return;
    sort_entries(); remap_playing_idx();
    bcursor=0; btop=0; sel_scroll=0; last_scroll=0; scroll_started=0;
    if(browser_on && !g_menu_open) dn_draw_list();
    else g_list_dirty=1;              /* under an open dropdown: repaint once the menu closes */
}
/* ---- DN status line (bottom row): always-present active-key hints, DN-style (hotkey red, label gray).
   Context-sensitive: the browser shows its keys, a modal dialog swaps in its own, then restores. ---- */
static void dn_keybar(const char* const items[][2], int n){
    dn_fill(0,DN_ROWS-1,DN_COLS,1,DNK_MENU_BG);
    int iw[16], total=0;                                  /* item widths: key + space + label */
    for(int i=0;i<n && i<16;i++){ iw[i]=slen(items[i][0])+1+slen(items[i][1]); total+=iw[i]; }
    int gaps=n+1, base=(DN_COLS-total)/gaps; if(base<1) base=1;   /* spread the slack across n+1 gaps (edges + between) */
    int extra=(DN_COLS-total)-base*gaps; if(extra<0) extra=0;
    int x=0;
    for(int i=0;i<n && i<16;i++){
        x += base + (i<extra?1:0);                        /* sprinkle the remainder into the first gaps */
        dn_puts(x, DN_ROWS-1, items[i][0], DNK_HOTKEY,  DNK_MENU_BG);
        dn_puts(x+slen(items[i][0])+1, DN_ROWS-1, items[i][1], DNK_MENU_FG, DNK_MENU_BG);
        x += iw[i];
    }
}
static void dn_keybar_browser(void){
    static const char* const it[9][2]={{"F1","Help"},{"F3","Sort"},{"F5","Copy"},{"F6","Ren"},{"F7","Dir"},{"F8","Del"},{"F9","Menu"},{"F12","Hide"},{"Esc","Back"}};
    dn_keybar(it,9);
}
static void render_browser_dn(void){
    /* No full clear: the menu row, panel and key bar below cover the whole 640x400 canvas (no transparent flash). */
    menubar_draw(-1);                                         /* top menu bar - data-driven Menubar draw */
    dn_fill(0,1,DN_COLS,DN_ROWS-2,DNK_PANEL_BG);              /* file panel */
    dn_box(0,1,DN_COLS,DN_ROWS-2,DNK_FRAME,DNK_PANEL_BG,1);   /* double frame = active window */
    { char t[52]; int n=0; for(const char* p=curpath; *p && n<48; p++) t[n++]=*p; t[n]=0;   /* path in top border */
      int px=(DN_COLS-(n+2))/2; if(px<2) px=2;
      dn_putc(px,1,' ',DNK_CUR_FG,DNK_CUR_BG); dn_puts(px+1,1,t,DNK_CUR_FG,DNK_CUR_BG); dn_putc(px+1+n,1,' ',DNK_CUR_FG,DNK_CUR_BG); }
    dn_draw_list();                                          /* dynamic panel content (headers + files + scrollbar + info) */
    dn_keybar_browser();                                     /* bottom status line: always-present key hints */
}
static void render_browser(void){ render_browser_dn(); }   /* single entry point - all call sites now draw DN */
static void open_browser(void){
    sel_scroll=0; last_scroll=0; scroll_started=0; opt_on=0;
    OSD_CTRL=(OSD_CTRL|2u)&~1u; osd_on=1; browser_on=1; osd_view=3;   /* DN browser on the colour layer (bit1); drop the 1bpp plane */
    render_browser();        /* INSTANT window before any SD I/O - a keypress always shows something */
    sdop_freeze_begin();     /* a blocking scan mid-tape-load would underrun the pulse FIFO */
    sd_scan();               /* may block ~1s; shows MOUNT/READ on the title bar */
    sdop_freeze_end();
    render_browser();        /* final listing */
}
static void browser_move(int d){
    if(fcount==0) return;
    int old_cur=bcursor, old_top=btop;
    bcursor += d;
    if(bcursor<0) bcursor=0;
    if(bcursor>=fcount) bcursor=fcount-1;
    if(bcursor<btop) btop=bcursor;
    if(bcursor>=btop+BROWS) btop=bcursor-(BROWS-1);
    sel_scroll=0; last_scroll=0; scroll_started=0;   /* fresh selection: unscrolled, re-arm start delay */
    if(btop==old_top){ dn_draw_file_row(old_cur); dn_draw_file_row(bcursor); }  /* no scroll: repaint only the 2 changed rows */
    else dn_draw_list();                                                        /* scrolled: redraw only the list area (chrome stays -> no flicker) */
}
static void browser_scroll_tick(void){    /* marquee the selected long name - redraws ONLY the cursor row (no window flicker) */
    if(fcount==0 || bcursor>=fcount) return;
    const char* src=flist[bcursor]; const char* e=fext(src); int nl=slen(src);
    int base=(!fisdir[bcursor] && *e) ? (int)(e-src)-1 : nl; if(base<0) base=0;   /* base-name length in the Name column */
    if(base <= DNB_NAMEW){ if(sel_scroll){ sel_scroll=0; dn_draw_file_row(bcursor); } return; }  /* fits: never marquee */
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
    if(sel_scroll > (base - DNB_NAMEW) + 2){ sel_scroll = 0; scroll_started = 0; last_scroll = now; } /* tail pause -> re-delay */
    dn_draw_file_row(bcursor);            /* ONE row only */
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
    for(int i=0;i<16384;i++){ IJ_RAMD = p[i];
        for(volatile uint32_t t=0; (IJ_STAT & 0x2u) && t<1000000u; t++){} }   /* poll RAM_BUSY (bounded: a wedged core must not hang the ARM) */
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
    for(volatile uint32_t t=0; t<8000000u && !(IJ_STAT & 1u); t++){}   /* wait HALT_ACK (bounded) */
}
/* .z80 RLE: 'ED ED cnt val'; clen==0xFFFF -> 16384 raw bytes. `avail` = source bytes remaining in the
   file from src, so a truncated/malformed page can never read past end-of-file (clamps raw + RLE). */
static void z80_unrle(const uint8_t* src,int clen,int avail,uint8_t* dst){
    if(avail<0) avail=0;
    if(clen==0xFFFF){ int n=(avail<16384)?avail:16384,i=0; for(;i<n;i++) dst[i]=src[i]; for(;i<16384;i++) dst[i]=0; return; }
    if(clen>avail) clen=avail;                       /* never read past the bytes actually in the file */
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
            z80_unrle(src,clen,len-(off+3),pagebuf);
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
    char path[180]; int p=0;                                 /* curpath(<=79) + '/' + NAMELEN(96) + NUL */
    for(int i=0;curpath[i] && p<160;i++) path[p++]=curpath[i];
    if(p && path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[bcursor][i] && p<179;i++) path[p++]=flist[bcursor][i];
    path[p]=0;
    if(!sd_mounted) return;
    FIL f; UINT br=0;
    if(f_open(&f,path,FA_READ)!=FR_OK){ sd_unmount(); return; }      /* card gone -> drop, don't retry */
    if(f_read(&f,snapbuf,sizeof(snapbuf),&br)!=FR_OK){ f_close(&f); sd_unmount(); return; }
    f_close(&f);
    if(br<30) return;
    player_stop(); playing_idx=-1; g_music_path[0]=0;           /* loading a game: drop the music + return the audio mux to the fabric (else the demo is silent) */
    OSD_CTRL&=~3u; osd_on=0; browser_on=0; osd_view=0;              /* hand the screen to the game (hide BOTH OSD layers, incl. the DN browser on bit1) */
    { int i=0; for(; path[i] && i<179; i++) g_app_path[i]=path[i]; g_app_path[i]=0; }  /* banner: loaded app full path */
    g_app_stopped=0;                                            /* freshly loaded snapshot -> running */
    apply_music_halt();                                         /* music just stopped -> drop the music-HALT bit */
    update_banner();
    if(cicmp(fext(flist[bcursor]),"sna")==0) load_sna(snapbuf,(int)br);
    else load_z80(snapbuf,(int)br);
    apply_halt();                                               /* inject_finish did IJ_CTRL=0; re-assert HALT if a manual pause is still held */
}

/* ---- music auto-play: playable test, play-by-index (cursor follows), auto-advance on EOF ---- */
static int is_music_ext(int idx){
    if(idx<0 || idx>=fcount || fisdir[idx]) return 0;
    const char* e = fext(flist[idx]);
    return cicmp(e,"psg")==0 || cicmp(e,"wav")==0 || cicmp(e,"mp3")==0;   /* music extensions (extend as more decoders land) */
}
static void play_index(int idx){                  /* play flist[idx], move the cursor onto it, remember the folder */
    if(idx<0 || idx>=fcount || fisdir[idx]) return;
    int oc=bcursor, ot=btop, op=playing_idx;       /* old cursor / scroll / previously-playing row, for a partial redraw */
    char path[180]; int p=0;                                 /* curpath(<=79) + '/' + NAMELEN(96) + NUL */
    for(int i=0;curpath[i] && p<160;i++) path[p++]=curpath[i];
    if(p && path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[idx][i] && p<179;i++) path[p++]=flist[idx][i];
    path[p]=0;
    const char* pe = fext(flist[idx]);
    int ok = (cicmp(pe,"wav")==0) ? player_play_wav(path)
           : (cicmp(pe,"mp3")==0) ? player_play_mp3(path)
           :                        player_play_psg(path);   /* dispatch music decoder by extension */
    if(ok){
        playing_idx = idx;
        g_status_scroll=0; g_status_started=0; g_status_last=0;   /* restart the status-path marquee for the new track */
        /* DN: do NOT surface the Winamp window (it drew posbar/time OVER the DN browser). Keep the DN
           browser = the playlist; the playing track shows the > marker. Progress/time -> DN player status (v0.14.3). */
        int j=0; for(; curpath[j] && j<79; j++) play_dir[j]=curpath[j]; play_dir[j]=0;
        { int i=0; for(; path[i] && i<179; i++) g_music_path[i]=path[i]; g_music_path[i]=0; }  /* banner: track path */
        apply_music_halt();                                    /* music started: if PAUSE-MUS=YES + game loaded, assert HALT */
        if(!g_suppress_browser_draw){                          /* modal/progress owns the screen -> don't hijack the cursor */
            bcursor = idx; sel_scroll=0; last_scroll=0;        /* cursor follows the playing track */
            if(bcursor < btop) btop=bcursor;
            if(bcursor >= btop+BROWS) btop=bcursor-BROWS+1;
            if(btop<0) btop=0;
        }
    }
    update_banner();             /* music started/changed -> refresh the banner */
    if(browser_on && !g_suppress_browser_draw){ if(btop==ot){ dn_draw_file_row(op); dn_draw_file_row(oc); dn_draw_file_row(bcursor); dn_draw_status(); } else dn_draw_list(); }  /* clear the old marker + draw the new; no flicker */
}
static uint32_t g_rand = 0x2A3C1D5Bu;             /* LCG state for RANDOM play; stirred with the timer at each pick */
static void player_autoadvance(void){             /* on EOF: pick the next track per opt_playmode */
    if(playing_idx < 0) return;
    if(sd_mounted && cicmp(curpath, play_dir)==0){          /* still in the playback folder */
        int n = -1;
        switch(opt_playmode){
            case 1: break;                                  /* FILE: one track to its end -> stop */
            case 3: n = playing_idx; break;                 /* FILE LOOP: replay the same track */
            case 4: {                                       /* RANDOM: any music file in the folder */
                int cnt=0; for(int i=0;i<fcount;i++) if(is_music_ext(i)) cnt++;
                if(cnt>0){
                    XTime now; XTime_GetTime(&now); g_rand ^= (uint32_t)now;
                    g_rand = g_rand*1664525u + 1013904223u;
                    int pick = (int)((g_rand>>16) % (unsigned)cnt), seen=0;
                    for(int i=0;i<fcount;i++) if(is_music_ext(i)){ if(seen==pick){ n=i; break; } seen++; }
                    if(n==playing_idx && cnt>1){            /* same track again: take the next one instead */
                        n=-1;
                        for(int i=playing_idx+1;i<fcount;i++) if(is_music_ext(i)){ n=i; break; }
                        if(n<0) for(int i=0;i<playing_idx;i++) if(is_music_ext(i)){ n=i; break; }
                    }
                }
                break; }
            default:                                        /* 0 FOLDER / 2 FOLDER LOOP: next in sorted order */
                for(int i=playing_idx+1;i<fcount;i++) if(is_music_ext(i)){ n=i; break; }
                if(n<0 && opt_playmode==2)                  /* FOLDER LOOP: wrap to the first */
                    for(int i=0;i<fcount;i++) if(is_music_ext(i)){ n=i; break; }
                break;
        }
        if(n>=0){ play_index(n); return; }
    }
    playing_idx=-1; g_music_path[0]=0; apply_music_halt(); update_banner();   /* stop (end of folder / FILE mode / browsed away) */
    if(browser_on && !g_suppress_browser_draw){ dn_draw_list(); dn_draw_status(); }   /* clear markers/status (incremental) */
}
/* Auto-advance safely from a pump path (menu/dialog/progress): start the next track without touching
   the file list or the browser cursor (the modal owns the screen). Music stays continuous during ops. */
static void pump_autoadvance(void){
    if(player_take_ended()){
        g_suppress_browser_draw = 1;
        player_autoadvance();
        g_suppress_browser_draw = 0;
    }
}

/* ===================== Step 14.2: tape station (.tap real-time pulse replay) =====================
   Machine-agnostic PULSE loader: parse the .tap, generate the standard ROM pilot/sync/data pulse
   train (in T-states), push {level,dur} into the fabric tape FIFO with backpressure; the fabric
   replays the edges into the core's ear at exact T-state timing (authentic load, any ROM/turbo/
   custom loader). Progress feeds the player window. See STEP_14_TAPE_DESIGN. */
static uint8_t  g_tapbuf[256*1024];        /* whole .tap in DDR .bss (covers virtually all games) */
static uint32_t g_tap_len = 0;
static int      g_tape_on = 0, g_ear_lvl = 0;
static uint32_t g_blk_ptr = 0, g_blk_len = 0, g_blk_data = 0;
static int      g_phase = 0, g_bit_idx = 7, g_half = 0;
static uint32_t g_pilot_left = 0, g_byte_idx = 0, g_tape_done = 0;
static uint64_t g_tape_total_T = 1, g_tape_elapsed_T = 0;   /* whole-tape duration + played, in T-states (smooth exact progress/time) */
static char     g_tape_name[NAMELEN+1] = "";
static int      g_tape_drain = 0;          /* 1 = no more pulses to push; wait for the FIFO to fully replay, THEN release */
static uint32_t g_tape_last_pct = 999;     /* throttle the status redraw to % changes (no tearing) */
static XTime    g_tape_t0 = 0;             /* load start time -> live "time remaining" estimate */
static uint32_t g_tape_last_sec = 0xFFFFFFFFu;  /* throttle the LCD time redraw to per-second */
static uint32_t g_music_last_pct = 0xFFFFFFFFu, g_music_last_sec = 0xFFFFFFFFu;  /* music progress/time throttle */
/* ---- Step 14.2b: format-agnostic SEGMENT model (TAP standard blocks + TZX turbo/pulse/pause blocks) ---- */
#define TAPE_FMT_TAP 0
#define TAPE_FMT_TZX 1
#define TAPE_FMT_WAV 2          /* Step 14.3: .wav digitised cassette -> edge-detect -> PULSE FIFO */
#define TAPE_FMT_MP3 3          /* Step 14.3: .mp3 digitised cassette (minimp3 -> edge-detect -> PULSE) */
static int      g_tape_fmt = TAPE_FMT_TAP;
static uint32_t g_seg_pilot_len=2168, g_seg_sync1=667, g_seg_sync2=735, g_seg_zero=855, g_seg_one=1710, g_seg_pause_T=1750000;
static int      g_seg_has_sync=1, g_seg_used_bits=8;   /* used_bits = valid bits in the LAST data byte */
static uint32_t g_tzx_loop_ptr=0, g_tzx_loop_cnt=0;
/* WAV-tape (Step 14.3): stream a digitised cassette, threshold to an ear level, emit one PULSE per
   edge -> reuses the whole TAP/TZX PULSE FIFO + progress display. g_tapbuf doubles as the SD ring. */
static FIL      g_wtf; static int g_wt_open=0;
static uint32_t g_wt_sr=44100; static int g_wt_ch=1, g_wt_bps=2;
static uint32_t g_wt_total=0, g_wt_read=0;                 /* data-chunk bytes: total + consumed */
static UINT     g_wt_valid=0, g_wt_pos=0; static int g_wt_eof=0;
static int      g_wt_level=0; static uint32_t g_wt_run=0;  /* edge detector: current level + samples since last edge */
#define WT_HYS 2048                                        /* Schmitt hysteresis (s16 scale): ignore noise near zero */
static uint32_t tp_u16(uint32_t o){ return (o+1u<g_tap_len)?(g_tapbuf[o]|((uint32_t)g_tapbuf[o+1]<<8)):0u; }
static uint32_t tp_u24(uint32_t o){ return (o+2u<g_tap_len)?(g_tapbuf[o]|((uint32_t)g_tapbuf[o+1]<<8)|((uint32_t)g_tapbuf[o+2]<<16)):0u; }
static uint32_t tp_u32(uint32_t o){ return (o+3u<g_tap_len)?(g_tapbuf[o]|((uint32_t)g_tapbuf[o+1]<<8)|((uint32_t)g_tapbuf[o+2]<<16)|((uint32_t)g_tapbuf[o+3]<<24)):0u; }
static void tape_close_src(void){ if(g_wt_open){ f_close(&g_wtf); g_wt_open=0; } if(mp3_is_open()) mp3_close(); }  /* close the streaming tape source (WAV file / MP3 decoder) */
/* ---- Step 14.3c: ISR-fed pulse ring (ultrastable tape delivery) ----
   The hardware FIFO holds only 512 pulses (~21 ms at the densest turbo bits) - one bad main-loop
   pass (MP3 decode burst + ring compaction + OSD redraw) could underrun it mid-load. Producers now
   push pulses into this big software ring; the 1 ms audio ISR tops the hardware FIFO up from it, so
   tape delivery survives ANY main-loop stall (same architecture as the music path). */
/* ---- JTAG-readable self-test instrumentation (read/poke live via xsdb mrd/mwr) ----
   g_dbg[0]=ISR ticks (proves the 1ms timer fires)  [1]=ring STARVATIONS (FIFO had room but pulse
   ring was empty = underrun)  [2]=min pulse-ring free (0 => producer overran)  [3]=pulses produced
   [4]=pulses delivered to fabric  [5]=tape_on  [6]=tape_fmt  [7]=source EOF  [8]=played_T>>10
   [9]=total_T>>10  [10]=decode/refill calls  [11]=guard-maxed passes.
   g_autotrig: poke non-zero via JTAG to auto-start the hard-coded test load (no keypress needed). */
volatile uint32_t g_dbg[16] __attribute__((used)) = {0,0,0xFFFFFFFFu,0,0,0,0,0,0,0,0,0,0,0,0,0};
volatile int      g_autotrig __attribute__((used)) = 0;
volatile char     g_autodir[96]  __attribute__((used)) = "0:/loadtest/TurboLoadmp3";  /* JTAG-pokeable self-test target dir */
volatile char     g_autoname[64] __attribute__((used)) = "aliens.mp3";                /* ...and filename (any .wav/.mp3/.tap) */
#define PR_LEN  32768u                 /* power of 2; ~3-11 s of turbo pulses */
#define PR_MASK (PR_LEN-1u)
static volatile uint32_t pr_buf[PR_LEN];
static volatile uint32_t pr_w = 0, pr_r = 0;      /* monotonic producer/consumer indices */
static volatile int g_tape_feed = 0;              /* gate: the ISR may push ring -> TAPE_FIFO */
static volatile int g_tape_primed = 0;            /* ISR waits for a ring cushion before the first feed (no startup starvation) */
static volatile uint64_t g_tape_played_T = 0;     /* T-states DELIVERED to the fabric: drives the progress
                                                     bar/time (the producer runs seconds ahead of replay,
                                                     so counting at production made the bar jerk) */
static uint32_t pr_free(void){ return PR_LEN - (pr_w - pr_r); }
static uint64_t tape_played_T(void){ Xil_ExceptionDisable(); uint64_t v = g_tape_played_T; Xil_ExceptionEnable(); return v; }
/* DN status row (22) during a tape load: name + M:SS/M:SS + progress bar - same layout as the music
   status, tape-green. Replaces the retired Winamp widgets; updates are throttled by the caller. */
static void dn_draw_tape_status(void){
    uint64_t pt = tape_played_T();
    unsigned pct = (unsigned)((pt*100u)/g_tape_total_T); if(pct>100u) pct=100u;
    unsigned el  = (unsigned)(pt/TAPE_HZ), tot = (unsigned)(g_tape_total_T/TAPE_HZ);
    if(el>5999u) el=5999u; if(tot>5999u) tot=5999u;
    dn_fill(1,22,DN_COLS-2,1,DNK_PANEL_BG);
    dn_put_glyph(2,22, GLYPH_PLAY, DNK_TAPE, DNK_PANEL_BG);
    dn_putsn(4,22, g_tape_name, 42, DNK_TAPE, DNK_PANEL_BG);
    { char t1[8],t2[8],tb[18]; fmt_mmss(el,t1); fmt_mmss(tot,t2);
      int p=0; for(int i=0;t1[i];i++)tb[p++]=t1[i]; tb[p++]='/'; for(int i=0;t2[i];i++)tb[p++]=t2[i]; tb[p]=0;
      dn_puts(47,22,tb,DNK_HEADER,DNK_PANEL_BG); }
    dn_bar(59,22,DNB_SCR-1-59,pct*10u,DNK_TAPE,DNK_PANEL_BG);
}
void tape_isr_feed(void){                         /* called from the 1 ms timer ISR */
    g_dbg[0]++;                                    /* ISR-alive tick (proves the timer fires) */
    if(!g_tape_feed) return;
    if(!g_tape_primed){ if((pr_w - pr_r) < 1024u) return; g_tape_primed=1; }  /* wait for a cushion before the FIRST feed -> no startup starvation */
    if(pr_w == pr_r && !(TAPE_STATUS & 1u)) g_dbg[1]++;   /* STARVED: fabric wants pulses but the ring is empty */
    while((pr_w != pr_r) && !(TAPE_STATUS & 1u)){
        uint32_t e = pr_buf[pr_r & PR_MASK];
        TAPE_FIFO = e; pr_r++;
        g_tape_played_T += (e & 0xFFFFFFu);
        g_dbg[4]++;                                /* pulses delivered to fabric */
    }
    if(g_tape_feed){ uint32_t occ = pr_w - pr_r; if(occ < g_dbg[2]) g_dbg[2]=occ; }  /* min ring occupancy (0 = emptied) */
}
static void tape_stop(void){
    Xil_ExceptionDisable(); g_tape_feed = 0; pr_r = pr_w; Xil_ExceptionEnable();   /* gate the ISR off + flush atomically */
    g_tape_on = 0; g_tape_drain = 0; g_phase = 0; TAPE_CTRL &= ~3u; tape_close_src(); }   /* hard stop (abort): release ear */
static void tape_done(void){ g_phase = 0; g_tape_drain = 1; }   /* end of tape: stop producing; drain ring+FIFO then release */
static void tape_push_pulse(uint32_t dur){
    pr_buf[pr_w & PR_MASK] = ((uint32_t)g_ear_lvl<<31) | (dur & 0xFFFFFFu);
    pr_w++;                                        /* index bump AFTER the data write (SPSC ordering) */
    g_ear_lvl ^= 1; g_tape_elapsed_T += dur;
    g_dbg[3]++;                                    /* pulses produced (min occupancy tracked in the ISR) */
}
/* Prepend a long, clean 2168T pilot leader into the ring before the file's own pulses. The ARM->fabric
   delivery is JTAG-proven starvation-free, so the only remaining load misses were the ZX not yet listening
   when a short file-pilot played out; a ~1.8s synthetic leader guarantees it is. Counted into
   g_tape_total_T so the progress bar stays honest. */
static void tape_preroll_pilot(void){
    if(!opt_longleader) return;
    for(uint32_t k=0;k<3000u;k++) tape_push_pulse(2168u);
    g_tape_total_T += 3000ull*2168ull;
}
/* Set up the NEXT segment's params (pilot/sync/data/pause) + starting g_phase. TAP = one standard block;
   TZX = one block dispatched by ID (metadata blocks skipped, loops handled). tape_done() when finished. */
static void tape_load_seg(void){
    if(g_tape_fmt==TAPE_FMT_TAP){
        if(g_blk_ptr+2u > g_tap_len){ tape_done(); return; }
        uint32_t len=tp_u16(g_blk_ptr), data=g_blk_ptr+2u;
        if(len==0u || data+len>g_tap_len){ tape_done(); return; }
        g_blk_data=data; g_blk_len=len; g_seg_pilot_len=2168u; g_pilot_left=(g_tapbuf[data]<0x80u)?8063u:3223u;
        g_seg_sync1=667u; g_seg_sync2=735u; g_seg_has_sync=1; g_seg_zero=855u; g_seg_one=1710u;
        g_seg_used_bits=8; g_seg_pause_T=1750000u; g_blk_ptr=data+len; g_phase=1; g_byte_idx=0; g_bit_idx=7; g_half=0; return;
    }
    for(;;){                               /* TZX: dispatch by block ID */
        if(g_blk_ptr >= g_tap_len){ tape_done(); return; }
        uint8_t id=g_tapbuf[g_blk_ptr]; uint32_t o=g_blk_ptr+1u;
        if(id==0x10){ uint32_t pause=tp_u16(o), len=tp_u16(o+2), data=o+4;                         /* standard speed data */
            if(data+len>g_tap_len){ tape_done(); return; }
            g_blk_data=data; g_blk_len=len; g_seg_pilot_len=2168u; g_pilot_left=(g_tapbuf[data]<0x80u)?8063u:3223u;
            g_seg_sync1=667u; g_seg_sync2=735u; g_seg_has_sync=1; g_seg_zero=855u; g_seg_one=1710u;
            g_seg_used_bits=8; g_seg_pause_T=pause?pause*3500u:1750000u; g_blk_ptr=data+len; g_phase=1; g_byte_idx=0; g_bit_idx=7; g_half=0; return; }
        if(id==0x11){ uint32_t pl=tp_u16(o),s1=tp_u16(o+2),s2=tp_u16(o+4),z=tp_u16(o+6),on=tp_u16(o+8),pc=tp_u16(o+10); /* turbo data */
            int ub=g_tapbuf[o+12]; uint32_t pause=tp_u16(o+13), len=tp_u24(o+15), data=o+18;
            if(data+len>g_tap_len){ tape_done(); return; }
            g_blk_data=data; g_blk_len=len; g_seg_pilot_len=pl; g_pilot_left=pc; g_seg_sync1=s1; g_seg_sync2=s2; g_seg_has_sync=1;
            g_seg_zero=z; g_seg_one=on; g_seg_used_bits=(ub>=1&&ub<=8)?ub:8; g_seg_pause_T=pause?pause*3500u:0;
            g_blk_ptr=data+len; g_phase=(pc?1:2); g_byte_idx=0; g_bit_idx=7; g_half=0; return; }
        if(id==0x12){ uint32_t pl=tp_u16(o), cnt=tp_u16(o+2);                                       /* pure tone */
            g_seg_pilot_len=pl; g_pilot_left=cnt; g_seg_has_sync=0; g_blk_len=0; g_seg_pause_T=0;
            g_blk_ptr=o+4; g_phase=(cnt?1:5); return; }
        if(id==0x13){ uint32_t cnt=g_tapbuf[o];                                                       /* pulse sequence: cnt individual pulses */
            g_blk_data=o+1; g_blk_len=cnt; g_seg_has_sync=0; g_seg_pause_T=0;
            g_blk_ptr=o+1u+cnt*2u; g_phase=(cnt?6:5); g_byte_idx=0; return; }
        if(id==0x14){ uint32_t z=tp_u16(o),on=tp_u16(o+2); int ub=g_tapbuf[o+4]; uint32_t pause=tp_u16(o+5),len=tp_u24(o+7),data=o+10; /* pure data */
            if(data+len>g_tap_len){ tape_done(); return; }
            g_blk_data=data; g_blk_len=len; g_pilot_left=0; g_seg_has_sync=0; g_seg_zero=z; g_seg_one=on;
            g_seg_used_bits=(ub>=1&&ub<=8)?ub:8; g_seg_pause_T=pause?pause*3500u:0; g_blk_ptr=data+len; g_phase=4; g_byte_idx=0; g_bit_idx=7; g_half=0; return; }
        if(id==0x20){ uint32_t pause=tp_u16(o); g_pilot_left=0; g_seg_has_sync=0; g_blk_len=0;       /* pause / stop */
            g_seg_pause_T=pause?pause*3500u:1750000u; g_blk_ptr=o+2; g_phase=5; return; }
        if(id==0x24){ g_tzx_loop_cnt=tp_u16(o); g_blk_ptr=o+2; g_tzx_loop_ptr=g_blk_ptr; continue; }  /* loop start */
        if(id==0x25){ if(g_tzx_loop_cnt>1){ g_tzx_loop_cnt--; g_blk_ptr=g_tzx_loop_ptr; } else g_blk_ptr=o; continue; }  /* loop end */
        if(id==0x21){ g_blk_ptr=o+1u+g_tapbuf[o]; continue; }        /* group start */
        if(id==0x22){ g_blk_ptr=o; continue; }                       /* group end */
        if(id==0x30){ g_blk_ptr=o+1u+g_tapbuf[o]; continue; }        /* text description */
        if(id==0x31){ g_blk_ptr=o+2u+g_tapbuf[o+1]; continue; }      /* message */
        if(id==0x32){ g_blk_ptr=o+2u+tp_u16(o); continue; }          /* archive info */
        if(id==0x33){ g_blk_ptr=o+1u+3u*g_tapbuf[o]; continue; }     /* hardware type */
        if(id==0x35){ g_blk_ptr=o+16u+4u+tp_u32(o+16); continue; }   /* custom info */
        if(id==0x5A){ g_blk_ptr=o+9u; continue; }                    /* glue */
        if(id==0x2A){ g_blk_ptr=o+4u; continue; }                    /* stop-if-48k */
        if(id==0x2B){ g_blk_ptr=o+5u; continue; }                    /* set signal level */
        if(id==0x23){ g_blk_ptr=o+2u; continue; }                    /* jump (ignored) */
        if(id==0x28){ g_blk_ptr=o+2u+tp_u16(o); continue; }          /* select block */
        tape_done(); return;   /* unknown/unsupported block -> stop safely */
    }
}
/* Pre-compute the whole tape's duration in T-states (same block parsing, summing pulse lengths). */
static uint64_t tape_total_T(void){
    uint64_t tot=0; uint32_t p=(g_tape_fmt==TAPE_FMT_TZX)?10u:0u, lptr=0, lcnt=0; int guard=0;
    for(;;){
        if(++guard > 400000) break;
        if(g_tape_fmt==TAPE_FMT_TAP){
            if(p+2u>g_tap_len) break; uint32_t len=tp_u16(p), data=p+2u; if(len==0u||data+len>g_tap_len) break;
            tot += (uint64_t)((g_tapbuf[data]<0x80u)?8063u:3223u)*2168u + 667u+735u + 1750000u;
            for(uint32_t i=0;i<len;i++){ uint8_t b=g_tapbuf[data+i]; for(int k=0;k<8;k++) tot += 2u*(((b>>k)&1)?1710u:855u); }
            p=data+len; continue;
        }
        if(p>=g_tap_len) break; uint8_t id=g_tapbuf[p]; uint32_t o=p+1u;
        if(id==0x10){ uint32_t pause=tp_u16(o),len=tp_u16(o+2),data=o+4; if(data+len>g_tap_len) break;
            tot += (uint64_t)((g_tapbuf[data]<0x80u)?8063u:3223u)*2168u+667u+735u+(pause?pause*3500u:1750000u);
            for(uint32_t i=0;i<len;i++){ uint8_t b=g_tapbuf[data+i]; for(int k=0;k<8;k++) tot += 2u*(((b>>k)&1)?1710u:855u); }
            p=data+len; continue; }
        if(id==0x11){ uint32_t pl=tp_u16(o),s1=tp_u16(o+2),s2=tp_u16(o+4),z=tp_u16(o+6),on=tp_u16(o+8),pc=tp_u16(o+10);
            int ub=g_tapbuf[o+12]; uint32_t pause=tp_u16(o+13),len=tp_u24(o+15),data=o+18; if(data+len>g_tap_len) break;
            tot += (uint64_t)pc*pl + s1+s2 + (pause?pause*3500u:0);
            for(uint32_t i=0;i<len;i++){ uint8_t b=g_tapbuf[data+i]; int bits=(i==len-1u)?ub:8; for(int k=7;k>=8-bits;k--) tot += 2u*(((b>>k)&1)?on:z); }
            p=data+len; continue; }
        if(id==0x12){ uint32_t pl=tp_u16(o),cnt=tp_u16(o+2); tot += (uint64_t)cnt*pl; p=o+4; continue; }
        if(id==0x13){ uint32_t cnt=g_tapbuf[o]; for(uint32_t i=0;i<cnt;i++) tot += tp_u16(o+1u+i*2u); p=o+1u+cnt*2u; continue; }
        if(id==0x14){ uint32_t z=tp_u16(o),on=tp_u16(o+2); int ub=g_tapbuf[o+4]; uint32_t pause=tp_u16(o+5),len=tp_u24(o+7),data=o+10; if(data+len>g_tap_len) break;
            tot += (pause?pause*3500u:0);
            for(uint32_t i=0;i<len;i++){ uint8_t b=g_tapbuf[data+i]; int bits=(i==len-1u)?ub:8; for(int k=7;k>=8-bits;k--) tot += 2u*(((b>>k)&1)?on:z); }
            p=data+len; continue; }
        if(id==0x20){ uint32_t pause=tp_u16(o); tot += pause?pause*3500u:1750000u; p=o+2; continue; }
        if(id==0x24){ lcnt=tp_u16(o); p=o+2; lptr=p; continue; }
        if(id==0x25){ if(lcnt>1){ lcnt--; p=lptr; } else p=o; continue; }
        if(id==0x21){ p=o+1u+g_tapbuf[o]; continue; }
        if(id==0x22){ p=o; continue; }
        if(id==0x30){ p=o+1u+g_tapbuf[o]; continue; }
        if(id==0x31){ p=o+2u+g_tapbuf[o+1]; continue; }
        if(id==0x32){ p=o+2u+tp_u16(o); continue; }
        if(id==0x33){ p=o+1u+3u*g_tapbuf[o]; continue; }
        if(id==0x35){ p=o+16u+4u+tp_u32(o+16); continue; }
        if(id==0x5A){ p=o+9u; continue; }
        if(id==0x2A){ p=o+4u; continue; }
        if(id==0x2B){ p=o+5u; continue; }
        if(id==0x23){ p=o+2u; continue; }
        if(id==0x28){ p=o+2u+tp_u16(o); continue; }
        break;
    }
    return tot?tot:1;
}
static void tape_start(void){
    char path[180]; int p=0;
    for(int i=0;curpath[i]&&p<160;i++) path[p++]=curpath[i];
    if(p&&path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[bcursor][i]&&p<179;i++) path[p++]=flist[bcursor][i];
    path[p]=0;
    if(!sd_mounted) return;
    tape_close_src();   /* switching source: close any open WAV/MP3 tape stream (g_tapbuf is about to be reused) */
    FIL f; UINT br=0;
    if(f_open(&f,path,FA_READ)!=FR_OK){ sd_unmount(); return; }
    if(f_read(&f,g_tapbuf,sizeof(g_tapbuf),&br)!=FR_OK){ f_close(&f); sd_unmount(); return; }
    f_close(&f);
    if(br < 2) return;
    player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt();   /* loading a program -> stop any background music (no phantom playback after load) */
    g_tape_fmt = TAPE_FMT_TAP;                         /* detect .tzx by its "ZXTape!" magic (robust to a wrong extension) */
    if(br>=10 && g_tapbuf[0]=='Z'&&g_tapbuf[1]=='X'&&g_tapbuf[2]=='T'&&g_tapbuf[3]=='a'&&g_tapbuf[4]=='p'&&g_tapbuf[5]=='e'&&g_tapbuf[6]=='!') g_tape_fmt = TAPE_FMT_TZX;
    g_tap_len=br; g_blk_ptr=(g_tape_fmt==TAPE_FMT_TZX)?10u:0u;   /* TZX: skip the 10-byte "ZXTape!" + version header */
    g_ear_lvl=0; g_tape_done=0; g_tape_on=1; g_tape_last_pct=999; g_tape_last_sec=0xFFFFFFFFu;
    g_tape_elapsed_T=0; g_tape_played_T=0; g_tzx_loop_cnt=0;
    g_tape_total_T = tape_total_T();                   /* exact whole-tape duration in T-states (TAP + TZX turbo/pulse) */
    XTime_GetTime(&g_tape_t0);
    { int i=0; for(; flist[bcursor][i]&&i<NAMELEN; i++) g_tape_name[i]=flist[bcursor][i]; g_tape_name[i]=0; }
    g_app_path[0]=0; g_app_stopped=0;                 /* tape is shown in the upper "now playing" field -> clear the playlist app line */
    pr_r = pr_w; g_tape_feed = 1; g_tape_primed = 0;                     /* fresh pulse ring + arm the ISR feeder */
    TAPE_CTRL = opt_tapesound ? 0x3u : 0x7u;          /* run + ear_mux (+ mute bit2 if TAPE SOUND = NO) */
    tape_load_seg();
    update_banner();        /* tape loading started (Winamp UI removed; DN loading status = v0.14.6) */
}
/* ---- WAV-tape stream ring (g_tapbuf) + zero-cross edge detector ---- */
static void wt_refill(void){
    if(g_wt_eof) return;
    if(g_wt_pos > sizeof(g_tapbuf)/2){ UINT rem=g_wt_valid-g_wt_pos; for(UINT i=0;i<rem;i++) g_tapbuf[i]=g_tapbuf[g_wt_pos+i]; g_wt_valid=rem; g_wt_pos=0; }
    if(sizeof(g_tapbuf)-g_wt_valid >= 32768){ UINT rd=0; if(f_read(&g_wtf,g_tapbuf+g_wt_valid,32768,&rd)!=FR_OK||rd==0) g_wt_eof=1; else g_wt_valid+=rd; }
}
static int wt_byte(uint8_t* b){
    if(g_wt_pos>=g_wt_valid){ if(g_wt_eof) return 0; UINT rd=0; if(f_read(&g_wtf,g_tapbuf,32768,&rd)!=FR_OK||rd==0){g_wt_eof=1;return 0;} g_wt_valid=rd; g_wt_pos=0; }  /* bounded fallback read (32 KB, not 256) so a stall can't be long */
    *b=g_tapbuf[g_wt_pos++]; return 1;
}
static int wt_sample(int* v){       /* next channel-0 sample (s16 scale); consumes every channel */
    if(g_wt_read >= g_wt_total) return 0;
    int s=0;
    for(int c=0;c<g_wt_ch;c++){ int cv;
        if(g_wt_bps==2){ uint8_t lo,hi; if(!wt_byte(&lo)||!wt_byte(&hi)) return 0; cv=(int)(int16_t)(lo|((uint16_t)hi<<8)); g_wt_read+=2; }
        else           { uint8_t b;    if(!wt_byte(&b)) return 0; cv=((int)b-128)<<8; g_wt_read+=1; }
        if(c==0) s=cv; }
    *v=s; return 1;
}
static int32_t g_rd_dc = 0;          /* tape reader state (file-scope so tape_reader_reset can clear it) */
static int     g_rd_prev_v = 0;
static double  g_rd_prev_frac = 0.5;
static void tape_edge(int v){        /* full hardware-reader model: AC-couple + Schmitt + sub-sample interp.
   IDENTICAL path for WAV and MP3. (1) AC-COUPLE (the coupling cap): a leaky-integrator high-pass that
   removes any DC bias but keeps every fast edge. WITHOUT this, an 8-bit cassette WAV with a +2000..+3000
   DC bias (measured: 8/71 speedLoad files) never crosses the -hys threshold -> no edges -> load fails.
   MP3 decodes centered so it seemed fine, but the reader must AC-couple both. (2) Schmitt comparator.
   (3) sub-sample zero-cross interpolation for turbo timing (like fuse audio2tape's interpolator). */
    g_rd_dc += v - (g_rd_dc >> 11); v -= (g_rd_dc >> 11);   /* AC coupling: tau ~43 ms >> pulse, << gaps */
    int hys = (g_tape_fmt == TAPE_FMT_MP3) ? tune_hys_mp3 : WT_HYS;
    int nl = g_wt_level ? (v < -hys ? 0 : 1) : (v > hys ? 1 : 0);
    if(nl != g_wt_level){
        double frac = 0.5;
        if ((g_rd_prev_v - v) != 0) {
            frac = (double)(-g_rd_prev_v) / (double)(v - g_rd_prev_v);   /* sub-sample zero-cross position */
            if (frac < 0.0) frac = 0.0;
            if (frac > 1.0) frac = 1.0;
        }
        /* CORRECT edge-to-edge duration = run + frac_k - frac_{k-1}. The old "run-1+frac" DROPPED the
           previous edge's fraction -> up to +-1 whole sample error per pulse = +-50% on a 2-sample
           turbo pulse (bits misread; checksum fails at block end), only +-5-10% on a long WAV pulse.
           Host-measured: this fix tightens the 0-bit cluster stddev 45T -> 9T. THE load bug. */
        double exact_run = (double)g_wt_run + frac - g_rd_prev_frac;
        if (exact_run < 0.5) exact_run = 0.5;
        uint64_t num = (uint64_t)(exact_run * (double)TAPE_HZ + 0.5);
        uint32_t dur = (uint32_t)(num / (uint64_t)g_wt_sr);
        if (dur == 0) dur = 1;
        g_ear_lvl = g_wt_level; tape_push_pulse(dur);
        g_wt_level = nl; g_wt_run = 0; g_rd_prev_frac = frac;
    }
    g_rd_prev_v = v;
    g_wt_run++;
}
/* Zero the reader state so every load starts identically (no carry-over between files). */
static void tape_reader_reset(int32_t dc_seed){ g_rd_dc = dc_seed; g_rd_prev_v = 0; g_rd_prev_frac = 0.5; }
/* At source EOF the detector still holds an unfinished run - the FINAL pulse. Dropping it loses the
   loader's terminating edge (the classic end-of-tape "loading error"); flush it, capped at 250 ms. */
static void tape_flush_tail(void){
    if(g_wt_run){
        /* use same improved scaling */
        uint64_t num = (uint64_t)g_wt_run * (uint64_t)TAPE_HZ;
        uint32_t dur = (uint32_t)(num / (uint64_t)g_wt_sr);
        if(dur > TAPE_HZ/4u) dur = TAPE_HZ/4u; if(dur==0) dur=1;
        g_ear_lvl=g_wt_level; tape_push_pulse(dur); g_wt_run=0;
    }
}
/* Produce into the big pulse ring first, THEN refill the sample source - the 1 ms ISR keeps the
   hardware FIFO topped from the ring, so source-refill bursts can no longer underrun a load. */
static void wav_tape_pump(void){
    int guard=0;
    while(pr_free() > 8u && guard++ < 8192){
        int v; if(!wt_sample(&v)){ tape_flush_tail(); tape_done(); return; }   /* data exhausted -> final pulse + drain */
        tape_edge(v);
    }
    wt_refill();
}
static void mp3_tape_pump(void){
    /* SOFTWARE MODEL OF THE PHYSICAL TAPE READER (the user's key insight): the Murmulator/ZX EAR
       circuit is just (1) an AC-coupling capacitor = a gentle HIGH-pass that strips DC but keeps
       every fast edge, then (2) a comparator with hysteresis -> the GPIO digital level. That is the
       whole "читалка", and it is what loads a phone's MP3 fine. So we do exactly that and NOTHING
       more: AC-couple here, then the hysteresis comparator (tape_edge). The earlier chain added a
       LOW-pass + lockout + adaptive gain - the opposite of the hardware - which smeared/blocked the
       2-sample turbo pulses. The decoded MP3 is already a clean square, so no other conditioning. */
    int guard=0;
    while(pr_free() > 8u && guard++ < 8192){
        int16_t l,r; if(!mp3_read(&l,&r)){ tape_flush_tail(); tape_done(); return; }
        tape_edge((int)l);                    /* AC-couple + Schmitt now live in tape_edge (shared with WAV) */
    }
    mp3_refill();
}
/* Open a .wav, auto-detect: a sustained ZX pilot tone at the start -> load as a cassette (PULSE tract);
   otherwise -> play as music (PCM stream via the player). Both stream from SD (files are too big for RAM). */
static void wav_start(void){
    char path[180]; int p=0;
    for(int i=0;curpath[i]&&p<160;i++) path[p++]=curpath[i];
    if(p&&path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[bcursor][i]&&p<179;i++) path[p++]=flist[bcursor][i];
    path[p]=0;
    if(!sd_mounted) return;
    if(g_wt_open){ f_close(&g_wtf); g_wt_open=0; }
    if(f_open(&g_wtf,path,FA_READ)!=FR_OK){ sd_unmount(); return; }
    g_wt_open=1;
    uint8_t h[12]; UINT hr=0;
    if(f_read(&g_wtf,h,12,&hr)!=FR_OK||hr<12||h[0]!='R'||h[1]!='I'||h[2]!='F'||h[3]!='F'||h[8]!='W'||h[9]!='A'||h[10]!='V'||h[11]!='E'){ f_close(&g_wtf); g_wt_open=0; return; }
    uint32_t data_off=0, data_len=0, sr=44100; int got=0, ch=1, bps=2;
    for(;;){ uint8_t c8[8]; UINT r=0; if(f_read(&g_wtf,c8,8,&r)!=FR_OK||r<8) break;
        uint32_t clen=c8[4]|((uint32_t)c8[5]<<8)|((uint32_t)c8[6]<<16)|((uint32_t)c8[7]<<24);
        if(c8[0]=='f'&&c8[1]=='m'&&c8[2]=='t'&&c8[3]==' '){ uint8_t fm[40]; UINT fr=0; UINT want=clen>40?40:clen;
            if(f_read(&g_wtf,fm,want,&fr)!=FR_OK||fr<16){ f_close(&g_wtf); g_wt_open=0; return; }
            ch=fm[2]|(fm[3]<<8); sr=fm[4]|((uint32_t)fm[5]<<8)|((uint32_t)fm[6]<<16)|((uint32_t)fm[7]<<24); bps=(fm[14]|(fm[15]<<8))/8; got=1;
            if(clen>want) f_lseek(&g_wtf,f_tell(&g_wtf)+(clen-want)); }
        else if(c8[0]=='d'&&c8[1]=='a'&&c8[2]=='t'&&c8[3]=='a'){ data_off=f_tell(&g_wtf); data_len=clen; break; }
        else f_lseek(&g_wtf,f_tell(&g_wtf)+clen+(clen&1));
    }
    if(!got||data_len==0||ch<1||sr<1||(bps!=1&&bps!=2)){ f_close(&g_wtf); g_wt_open=0; return; }
    /* pilot detect: read the first chunk, edge-detect ch0, find the longest run of in-band (~2168 T) pulses */
    f_lseek(&g_wtf,data_off);
    UINT scan=0; { UINT wantb = data_len < sizeof(g_tapbuf) ? (UINT)data_len : (UINT)sizeof(g_tapbuf); if(f_read(&g_wtf,g_tapbuf,wantb,&scan)!=FR_OK) scan=0; }
    int is_tape=0; int32_t dcd=0;
    { int frame=ch*bps; if(frame<1) frame=1;
      long target=((long)2168*(long)sr)/(long)TAPE_HZ; if(target<2) target=2;
      long lo=target*3/5, hi=target*7/5; if(lo<1) lo=1;
      int lvl=0; long run=0, maxrun=0, since=0; UINT off=0;
      while(off+(UINT)frame <= scan){
          int s0; if(bps==2) s0=(int)(int16_t)(g_tapbuf[off]|((uint16_t)g_tapbuf[off+1]<<8)); else s0=((int)g_tapbuf[off]-128)<<8;
          dcd += s0 - (dcd>>11); int ac = s0 - (dcd>>11);   /* AC-couple - same conditioning the reader uses */
          off+=(UINT)frame; since++;
          int nl = lvl ? (ac < -WT_HYS ? 0:1) : (ac > WT_HYS ? 1:0);
          if(nl!=lvl){ if(since>=lo && since<=hi){ if(++run>maxrun) maxrun=run; } else run=0; lvl=nl; since=0; }
      }
      is_tape = (maxrun >= 200);
    }
    if(is_tape){                          /* --- WAV cassette: stream through the PULSE tract --- */
        player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt();
        /* WARM START: the pilot-detect already read the first chunk into g_tapbuf -> reuse it as a FULL
           ring (~3 s of slack); g_wtf is positioned right after it, so wt_refill just continues from there.
           This (plus fill-FIFO-before-SD-refill) is the fix for the occasional mid-load underrun. */
        g_wt_sr=sr; g_wt_ch=ch; g_wt_bps=bps; g_wt_total=data_len; g_wt_read=0;
        g_wt_valid=scan; g_wt_pos=0; g_wt_eof=0; g_wt_level=0; g_wt_run=0;
        g_tape_fmt=TAPE_FMT_WAV; g_ear_lvl=0; g_tape_on=1; g_tape_drain=0; g_phase=0;
        g_tape_last_pct=999; g_tape_last_sec=0xFFFFFFFFu; g_tape_elapsed_T=0; g_tape_played_T=0;
        { uint32_t fb=(uint32_t)bps*(uint32_t)ch; uint64_t ns=fb?data_len/fb:0; g_tape_total_T = ns?((uint64_t)ns*(uint64_t)TAPE_HZ)/sr:1; }
        XTime_GetTime(&g_tape_t0);
        { int i=0; for(; flist[bcursor][i]&&i<NAMELEN; i++) g_tape_name[i]=flist[bcursor][i]; g_tape_name[i]=0; }
        g_app_path[0]=0; g_app_stopped=0;
        pr_r = pr_w; g_tape_primed = 0;                                  /* fresh pulse ring */
        tape_reader_reset(dcd);                /* seed DC from the pilot-detect -> pilot clean from sample 0 (no 43ms settle) */
        tape_preroll_pilot();                  /* long clean leader queued before the file -> the ZX is always listening */
        g_tape_feed = 1;                       /* arm the ISR feeder (pre-roll already in the ring) */
        TAPE_CTRL = opt_tapesound ? 0x3u : 0x7u;
        update_banner();
    } else {                              /* --- music: PCM stream via the player (dispatched by extension) --- */
        f_close(&g_wtf); g_wt_open=0;
        play_index(bcursor);
    }
}
/* Open an .mp3, auto-detect a ZX pilot at the start -> load as a cassette (decode -> edge -> PULSE),
   otherwise -> play as music. The turbo-loader archives are digitised to MP3, so this is a real load path. */
static void mp3_start(void){
    char path[180]; int p=0;
    for(int i=0;curpath[i]&&p<160;i++) path[p++]=curpath[i];
    if(p&&path[p-1]!='/') path[p++]='/';
    for(int i=0;flist[bcursor][i]&&p<179;i++) path[p++]=flist[bcursor][i];
    path[p]=0;
    if(!sd_mounted) return;
    player_stop(); tape_close_src();
    if(!mp3_open(path)){ sd_unmount(); return; }
    uint32_t sr=mp3_sr();
    int is_tape = opt_mp3tape ? 1 : 0;    /* user force for turbo MP3 collections */
    if(!is_tape){                        /* pilot detect: scan the start, EXIT as soon as a pilot run appears */
      long target=((long)2168*(long)sr)/(long)TAPE_HZ; if(target<2) target=2;
      long lo=target*3/5, hi=target*7/5; if(lo<1) lo=1;
      int lvl=0; long run=0, maxrun=0, since=0, cnt=0, limit=(long)sr;   /* at most ~1 s (music); turbo exits far sooner */
      int16_t a,b;
      while(cnt<limit && mp3_read(&a,&b)){ cnt++; since++;
          int nl = lvl ? (a<-WT_HYS?0:1) : (a>WT_HYS?1:0);
          if(nl!=lvl){ if(since>=lo&&since<=hi){ if(++run>maxrun) maxrun=run; } else run=0; lvl=nl; since=0; }
          if(maxrun>=200){ is_tape=1; break; } 
      /* also accept shorter runs (common in turbo digitised MP3s) */
      if(maxrun >= 80){ is_tape=1; break; }
    }   /* pilot found -> cassette; stop scanning right away (no long block) */
    }
    if(is_tape){                          /* --- MP3 cassette: stream through PULSE tract --- */
        if(!opt_mp3tape){
            mp3_close(); if(!mp3_open(path)){ sd_unmount(); return; }   /* only re-open if we consumed samples during auto-detect */
        }
        playing_idx=-1; g_music_path[0]=0; apply_music_halt();
        g_wt_sr=mp3_sr(); g_wt_level=0; g_wt_run=0;
        g_tape_fmt=TAPE_FMT_MP3; g_ear_lvl=0; g_tape_on=1; g_tape_drain=0; g_phase=0;
        /* reader state is reset inside mp3_tape_pump statics on next call */
        g_tape_last_pct=999; g_tape_last_sec=0xFFFFFFFFu; g_tape_elapsed_T=0; g_tape_played_T=0;
        { unsigned ts=mp3_total_s(); g_tape_total_T = ts?((uint64_t)ts*(uint64_t)TAPE_HZ):1; }
        XTime_GetTime(&g_tape_t0);
        { int i=0; for(; flist[bcursor][i]&&i<NAMELEN; i++) g_tape_name[i]=flist[bcursor][i]; g_tape_name[i]=0; }
        g_app_path[0]=0; g_app_stopped=0;
        pr_r = pr_w; g_tape_primed = 0;                                  /* fresh pulse ring */
        tape_reader_reset(0);                  /* MP3 is centered -> no DC seed needed */
        tape_preroll_pilot();                  /* long clean leader queued before the file -> the ZX is always listening */
        g_tape_feed = 1;                       /* arm the ISR feeder (pre-roll already in the ring) */
        TAPE_CTRL = opt_tapesound ? 0x3u : 0x7u;
        update_banner();
        /* the browser stays LIVE (drawing load is already gated by g_tape_on in the main loop);
           silently dropping browser_on here left a dead on-screen browser needing F5 twice */
    } else {                              /* --- music: PCM stream via the player --- */
        mp3_close();
        play_index(bcursor);
    }
}
static void tape_pump(void){
    if(!g_tape_on) return;
    if(IJ_STAT & 1u) return;                           /* machine HALTed (paused) -> tape frozen in lock-step; don't push/advance */
    if(g_tape_drain){                                  /* end of tape: hold run/earmux until ring+FIFO fully replay */
        if((pr_w == pr_r) && !(TAPE_STATUS & 2u)){     /* ring empty + playing clear -> every queued pulse delivered */
            g_tape_feed = 0;
            TAPE_CTRL &= ~3u; g_tape_on = 0; g_tape_drain = 0;
            tape_close_src();                              /* close the streaming source (WAV file / MP3 decoder) */
            close_osd();                                   /* tape fully loaded -> hide BOTH OSD layers */
        }
        return;
    }
    if(g_tape_fmt==TAPE_FMT_WAV){ wav_tape_pump(); }    /* WAV cassette: sample-stream edge detect -> pulses */
    else if(g_tape_fmt==TAPE_FMT_MP3){ mp3_tape_pump(); }  /* MP3 cassette: decode -> edge detect -> pulses */
    else {
    int guard=0;
    while(!g_tape_drain && pr_free() > 8u && guard++ < 8192){    /* produce into the pulse ring (ISR feeds the FIFO) */
        switch(g_phase){
            case 1: tape_push_pulse(g_seg_pilot_len); if(--g_pilot_left==0) g_phase = g_seg_has_sync?2:(g_blk_len?4:5); break;  /* pilot tone */
            case 2: tape_push_pulse(g_seg_sync1);  g_phase=3; break;                       /* sync pulse 1 */
            case 3: tape_push_pulse(g_seg_sync2);  g_phase=4; break;                       /* sync pulse 2 */
            case 4: { int bit=(g_tapbuf[g_blk_data+g_byte_idx] >> g_bit_idx) & 1;          /* data bit, MSB first */
                      tape_push_pulse(bit ? g_seg_one : g_seg_zero); g_half ^= 1;          /* 2 half-pulses per bit (custom timings for turbo) */
                      if(!g_half){ int minb = (g_byte_idx==g_blk_len-1u) ? (8-g_seg_used_bits) : 0;  /* last byte: only 'used_bits' MSBs */
                                   if(g_bit_idx==minb){ g_bit_idx=7; g_byte_idx++; g_tape_done++;
                                        if(g_byte_idx >= g_blk_len) g_phase=5; }
                                   else g_bit_idx--; }
                    } break;
            case 5: if(g_seg_pause_T) tape_push_pulse(g_seg_pause_T);                      /* inter-block pause (0 = none) */
                    tape_load_seg(); break;                                                /* -> next segment or tape_done() */
            case 6: tape_push_pulse(tp_u16(g_blk_data + g_byte_idx*2u));                   /* TZX pulse sequence: one edge per entry */
                    if(++g_byte_idx >= g_blk_len) g_phase=5; break;
            default: tape_done(); break;
        }
    }
    }
    g_dbg[5]=(uint32_t)g_tape_on; g_dbg[6]=(uint32_t)g_tape_fmt;
    g_dbg[8]=(uint32_t)(tape_played_T()>>10); g_dbg[9]=(uint32_t)(g_tape_total_T>>10);   /* live JTAG progress mirror */
    if(browser_on){       /* DN status row: live load progress from the DELIVERED T-states (ISR-side) -> smooth, no producer jitter */
        uint64_t pt = tape_played_T();
        unsigned pct = (unsigned)((pt*100u)/g_tape_total_T); if(pct>100u) pct=100u;
        unsigned el  = (unsigned)(pt/TAPE_HZ);
        if(pct != g_tape_last_pct || el != g_tape_last_sec){ g_tape_last_pct = pct; g_tape_last_sec = el; dn_draw_tape_status(); }
    }
}

/* JTAG self-test auto-loader: fake a browser selection of <dir>/<name> and run the REAL load path
   (so it exercises the exact production code). Triggered by poking g_autotrig via xsdb - no keypress. */
static void autoload_tape(const char* dir, const char* name){
    int i=0; for(; dir[i] && i<79; i++) curpath[i]=dir[i]; curpath[i]=0;
    int j=0; for(; name[j] && j<NAMELEN; j++) flist[0][j]=name[j]; flist[0][j]=0;
    fisdir[0]=0; bcursor=0; btop=0; fcount=1;
    g_dbg[1]=0; g_dbg[2]=0xFFFFFFFFu; g_dbg[3]=0; g_dbg[4]=0; g_dbg[7]=0;   /* reset per-run counters */
    const char* e=fext(name);
    if(cicmp(e,"mp3")==0){ int sv=opt_mp3tape; opt_mp3tape=1; mp3_start(); opt_mp3tape=sv; }   /* force tape (known cassette) */
    else if(cicmp(e,"wav")==0) wav_start();
    else if(cicmp(e,"tap")==0||cicmp(e,"tzx")==0) tape_start();
}
static void browser_enter(void){
    if(fcount==0 || bcursor>=fcount) return;
    if(!fisdir[bcursor]){                 /* a file: Step 12.1 - load .z80/.sna via AXI inject */
        const char* e=fext(flist[bcursor]);
        if(cicmp(e,"z80")==0 || cicmp(e,"sna")==0) load_snapshot();
        else if(cicmp(e,"psg")==0) play_index(bcursor);   /* music: keep browser OPEN, cursor follows, auto-advances on end */
        else if(cicmp(e,"wav")==0) wav_start();           /* Step 14.3: auto-detect pilot -> tape cassette, else play as music */
        else if(cicmp(e,"mp3")==0) mp3_start();           /* Step 14.3: same auto-detect for MP3 (turbo-loader archives are MP3) */
        else if(cicmp(e,"tap")==0 || cicmp(e,"tzx")==0) tape_start();   /* Step 14.2: real-time tape load (pulse replay); .tzx = turbo/custom loaders */
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
    sdop_freeze_begin();                                      /* dir scan mid-tape-load: freeze the machine (lock-step tape) */
    sd_scan();
    sdop_freeze_end();
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
    else if(!cicmp(k,"osd_x")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>640)d=640; opt_x=(d/8)*8; }
    else if(!cicmp(k,"osd_y")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>320)d=320; opt_y=(d/8)*8; }
    else if(!cicmp(k,"player_x")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>1024)d=1024; opt_pl_x=(d/8)*8; }
    else if(!cicmp(k,"player_y")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>592)d=592; opt_pl_y=(d/8)*8; }
    else if(!cicmp(k,"tape_snd")){ opt_tapesound = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"timemode")){ opt_timemode = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"showhidden")){ opt_showhidden = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"mp3_tape")){ opt_mp3tape = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"longlead")){ opt_longleader = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"preload")){ opt_preload = (v[0]=='1') ? 1 : 0; }
    else if(!cicmp(k,"mp3_hys")){ int v2=0; for(const char*p=v;*p>='0'&&*p<='9';p++) v2=v2*10+(*p-'0'); if(v2<0)v2=0; if(v2>4096)v2=4096; tune_hys_mp3=v2; }
    else if(!cicmp(k,"playmode"))   /* new names + legacy aliases (repeat1 -> FILE LOOP, repeatall -> FOLDER LOOP) */
        opt_playmode = !cicmp(v,"file")?1
                     : (!cicmp(v,"folderloop") || !cicmp(v,"repeatall"))?2
                     : (!cicmp(v,"fileloop")   || !cicmp(v,"repeat1"))?3
                     : !cicmp(v,"random")?4 : 0;
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
    char plxb[8]; itoa_u(opt_pl_x, plxb);
    p=appstr(o,p,"player_x=");     p=appstr(o,p,plxb); o[p++]='\r'; o[p++]='\n';
    char plyb[8]; itoa_u(opt_pl_y, plyb);
    p=appstr(o,p,"player_y=");     p=appstr(o,p,plyb); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"tape_snd=");     o[p++]=opt_tapesound?'1':'0'; o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"timemode=");     o[p++]=opt_timemode?'1':'0'; o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"showhidden=");   o[p++]=opt_showhidden?'1':'0'; o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"mp3_tape=");     o[p++]=opt_mp3tape?'1':'0'; o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"longlead=");     o[p++]=opt_longleader?'1':'0'; o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"preload=");      o[p++]=opt_preload?'1':'0'; o[p++]='\r'; o[p++]='\n';
    { char tb[8]; itoa_u(tune_hys_mp3, tb); p=appstr(o,p,"mp3_hys="); p=appstr(o,p,tb); o[p++]='\r'; o[p++]='\n'; }
    const char* pv = opt_playmode==1?"file":opt_playmode==2?"folderloop":opt_playmode==3?"fileloop":opt_playmode==4?"random":"folder";
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

/* (the menu_t dropdown renderer - dn_menu_row/menu_render/menu_move/menu_activate - is gone: the
   data-driven opt_items[] now surface as value-items of the Options > Settings NESTED dropdown,
   rendered by the Menubar engine below. One engine, one look, no buttons in menus.) */

/* ---- options actions (invoked from the Options dropdown leaf items) ---- */
static void act_save(void){
    sdop_freeze_begin();                 /* SD write mid-tape-load would underrun the pulse FIFO -> freeze the machine (bit-exact) */
    int ok = config_save();
    sdop_freeze_end();
    dn_status_msg(ok ? "SAVED" : "SAVE FAILED");               /* transient on the DN status row */
}
static void act_eject(void){           /* safe-eject: unmount so the card can be pulled cleanly (read-only now; add f_sync when writes land) */
    sd_unmount();
    dn_status_msg("SAFE TO REMOVE CARD");
}
static void apply_dim(void){                             /* %% -> alpha 0..255, live */
    uint32_t a = ((unsigned)opt_dim*255u)/100u;
    OSD_OP = a;                                          /* 1bpp plane opacity (help screen) */
    if(a == g_dn_alpha) return;
    g_dn_alpha = a;                                      /* DN canvas: BG() bakes this alpha into every background cell, */
    if(browser_on && !g_menu_open) render_browser();     /* so a change needs a repaint to become visible */
    else if(osd_on) g_alpha_dirty = 1;                   /* under an open menu: menu_value_changed repaints live */
}
static void apply_vol(void){ VOL_REG = ((unsigned)opt_vol*255u)/100u;   /* %% -> gain 0..255, live */
    if(browser_on && !g_menu_open) draw_topstatus(); }   /* live Vol:NN% in the top-right */
static void apply_pos(void){ DDR_OSD_POS = ((unsigned)opt_y<<16) | (unsigned)opt_x; }  /* Window X/Y -> navigator (DN canvas) position, live */
static void apply_tape_snd(void){ if(g_tape_on){ if(opt_tapesound) TAPE_CTRL &= ~4u; else TAPE_CTRL |= 4u; } }  /* live tape-sound mute */
static void hidden_changed(void){    /* Show-hidden toggled: re-read the directory with the new filter */
    if(!sd_mounted) return;
    bcursor=0; btop=0; sel_scroll=0; last_scroll=0; scroll_started=0;
    sdop_freeze_begin(); sd_scan(); sdop_freeze_end();
    if(browser_on && !g_menu_open) render_browser();   /* direct redraw */
    else g_list_dirty=1;                                /* under an open menu: menu_value_changed repaints */
}
static const char* const CH_SORT[]   = {"NAME","DATE","SIZE","EXT"};
static const char* const CH_SCROLL[] = {"SLOW","MED","FAST"};
static const char* const CH_FOLDER[] = {"BRACKETS","ICON","SLASH"};
static const char* const CH_DELAY[]  = {"0S","300MS","500MS","1S"};
static menu_item opt_items[] = {
    {"SORT",     ITEM_CHOICE, &sortmode,       CH_SORT,   4, 0, sort_changed},   /* live re-sort (menu value-item parity with F3) */
    {"SCROLL",   ITEM_CHOICE, &opt_scroll,     CH_SCROLL, 3, 0},
    {"SCROLL DELAY", ITEM_CHOICE, &opt_scrdelay,   CH_DELAY,  4, 0},
    {"FOLDERS",  ITEM_CHOICE, &opt_foldermark, CH_FOLDER, 3, 0},
    {"PLAY MODE",ITEM_CHOICE, &opt_playmode,   CH_PLAY,   N_PLAYMODES, 0},   /* music auto-play default (F2 cycles live) */
    {"PAUSE MUS",ITEM_CHOICE, &opt_pausemusic, CH_NOYES,  2, 0, music_halt_changed},  /* music over a game: NO=mute/run, YES=halt */
    {"VOLUME",   ITEM_RANGE,  &opt_vol,        0, 5, 0, apply_vol, 100, "%"},
    {"OSD DIM",  ITEM_RANGE,  &opt_dim,        0, 5, 0, apply_dim, 100, "%"},
    {"WINDOW X", ITEM_RANGE,  &opt_x,          0, 8, 0, apply_pos, 640, ""},   /* navigator X (0..1280-640) */
    {"WINDOW Y", ITEM_RANGE,  &opt_y,          0, 8, 0, apply_pos, 320, ""},   /* navigator Y (0..720-400)  */
    {"TAPE SOUND",ITEM_CHOICE,&opt_tapesound,  CH_NOYES,  2, 0, apply_tape_snd},
    {"MP3 TAPE", ITEM_CHOICE, &opt_mp3tape,    CH_NOYES,  2, 0},   /* force .mp3 -> tape path for turbo digitised files */
    {"LONG LEADER",ITEM_CHOICE,&opt_longleader, CH_NOYES,  2, 0},   /* prepend a long clean pilot so the machine always locks (recommended ON) */
    {"MP3 PRELOAD",ITEM_CHOICE,&opt_preload,    CH_NOYES,  2, 0},   /* preload whole MP3 file to RAM (avoids card-GC stalls, adds startup delay) */
    {"MP3 HYS",  ITEM_RANGE,  &tune_hys_mp3,   0, 128, 0, 0, 4096, ""},  /* MP3 tape comparator hysteresis (lower = more sensitive; rarely needs changing) */
    {"EJECT SD", ITEM_ACTION, 0, 0, 0, act_eject},
    {"SAVE",     ITEM_ACTION, 0, 0, 0, act_save},
    {"SHOW HIDDEN",ITEM_CHOICE,&opt_showhidden,CH_NOYES, 2, 0, hidden_changed},   /* [20] re-scan on toggle; appended so earlier indices stay put */
};
/* (no opt_menu instance any more: opt_items[] feed the Options > Settings nested dropdown directly) */

enum {
    K_NONE=0, K_BACK=8, K_TAB=9, K_ENTER=13, K_ESC=27, K_SPACE=32,
    K_UP=0x100, K_DOWN, K_LEFT, K_RIGHT, K_PGUP, K_PGDN, K_F1, K_F2, K_F3, K_F9,
    K_HOME, K_END
};

typedef struct Menu Menu;
typedef struct {
  const char* name;         /* "~F~iles"; NULL = separator */
  uint16_t    cmd;          /* leaf command; 0 if submenu or value-item */
  uint16_t    key;          /* global accelerator keysym (K_F6…), 0=none */
  const char* param;        /* right-aligned shortcut label ("F6"), or NULL */
  const Menu* sub;          /* submenu (cmd==0 && sub!=NULL), or NULL */
  menu_item*  value;        /* OPTIONAL inline value-item -> reuses the settings engine */
  uint8_t     disabled;
} MenuItem;
struct Menu { const MenuItem* items; int count; int deflt; };   /* deflt = remembered cursor */
typedef struct { const char* title; Menu* menu; } BarItem; /* title carries ~hotkey~ */

enum { /* app commands (loader) */
  cmFileLoad = 100, cmFileUp, cmFileRename, cmFileMkdir, cmFileDelete, cmFileCopy, cmFileSort, cmFileRev,
  cmPlayStart, cmPlayStop, cmPlayPause, cmPlayMode,
  cmTapePlay, cmTapeStop,
  cmOptSettings, cmOptSave, cmOptEject,
  cmHelpAbout, cmHelpKeys
};

static const MenuItem mi_files[] = {
  {"~L~oad / Run", cmFileLoad,  0, "Enter"},
  {"~U~p one dir", cmFileUp,    0, NULL},              /* also the ".." row + Enter */
  {NULL},                                                   /* separator */
  {"~R~ename...",  cmFileRename,0, "F6"},              /* modal DN rename dialog */
  {"~C~opy...",    cmFileCopy,  0, "F5"},              /* copy file to another folder (creates missing dirs) */
  {"~D~elete...",  cmFileDelete,0, "F8"},             /* delete (recursive w/ double confirm for non-empty folders) */
  {"~M~ake dir...",cmFileMkdir, 0, "F7"},              /* create directory (chain) */
  {NULL},
  {"~S~ort mode",  0,           0, "F3", NULL, &opt_items[0]},  /* value-item: SORT (index 0) */
  {"Re~v~erse",    cmFileRev,   0, "Alt+F3"},
};
static Menu m_files = { mi_files, 10, 0 };

static const MenuItem mi_play[] = {
  {"~S~tart",   cmPlayStart, 0, "Space"},
  {"S~t~op",    cmPlayStop,  0, "BkSp"},
  {"~P~ause",   cmPlayPause, 0, "Space"},
  {NULL},
  {"~M~ode",    cmPlayMode,  0, "F2"},
};
static Menu m_play = { mi_play, 5, 0 };

static const MenuItem mi_tape[] = {
  {"~P~lay tape", cmTapePlay, 0, NULL},
  {"S~t~op tape", cmTapeStop, 0, "BkSp"},
  {NULL},
  {"~S~ound",     0,0,NULL,NULL,&opt_items[10]},            /* value-item: TAPE SOUND (index 10) */
  {"~M~P3 as tape",0,0,NULL,NULL,&opt_items[11]},            /* value-item: MP3 TAPE (index 11) */
  {"~L~ong leader",0,0,NULL,NULL,&opt_items[12]},            /* value-item: LONG LEADER (index 12) */
};
static Menu m_tape = { mi_tape, 6, 0 };

/* Settings = a NESTED dropdown (owner: second-level menu, no buttons - buttons belong to modal
   dialogs only). Every row wraps an opt_items[] value-item verbatim: Enter/Right cycles forward,
   Left cycles back / steps a RANGE down, all changes apply live. */
static const MenuItem mi_settings[] = {
  /* (no "Sort" here: sorting lives in the Files menu - Sort mode + Reverse) */
  /* (Play mode + Folders/Player X-Y/Time display removed; Play mode lives in the Play menu) */
  {"Show hidden",    0,0,NULL, NULL, &opt_items[17]},   /* macOS .DS_Store/._* junk toggle */
  {"Scroll speed",   0,0,NULL, NULL, &opt_items[1]},
  {"Scroll delay",   0,0,NULL, NULL, &opt_items[2]},
  {"Pause on music", 0,0,NULL, NULL, &opt_items[5]},
  {"Volume",         0,0,NULL, NULL, &opt_items[6]},
  {"OSD dim",        0,0,NULL, NULL, &opt_items[7]},
  {"Window X",       0,0,NULL, NULL, &opt_items[8]},    /* navigator (DN canvas) position */
  {"Window Y",       0,0,NULL, NULL, &opt_items[9]},
  {"Tape sound",     0,0,NULL, NULL, &opt_items[10]},
  {"MP3 as tape",    0,0,NULL, NULL, &opt_items[11]},
  {"Long leader",    0,0,NULL, NULL, &opt_items[12]},
  {"MP3 preload",    0,0,NULL, NULL, &opt_items[13]},
  {"MP3 sens",       0,0,NULL, NULL, &opt_items[14]},
};
static Menu m_settings = { mi_settings, 13, 0 };

static const MenuItem mi_opts[] = {
  {"~S~ettings",     0,           0, NULL, &m_settings},    /* nested dropdown (DN-style, no buttons) */
  {NULL},
  {"Sa~v~e config",  cmOptSave,   0, NULL},                 /* act_save()  */
  {"~E~ject SD",     cmOptEject,  0, NULL},                 /* act_eject() */
};
static Menu m_opts = { mi_opts, 4, 0 };

static const MenuItem mi_help[] = {
  {"~A~bout...",  cmHelpAbout, 0, "F1"},
  {"~K~eys...",   cmHelpKeys,  0, NULL},
};
static Menu m_help = { mi_help, 2, 0 };

static BarItem g_bar[] = {                                  /* order == LEFT/RIGHT order */
  {"~F~iles",   &m_files}, {"~P~lay", &m_play}, {"~T~ape", &m_tape},
  {"~O~ptions", &m_opts},  {"~H~elp", &m_help} };
static const int g_bar_n = 5;

static void kbd_flush(void) {
    /* Pop until the FIFO reports empty (bit8). NEVER compare the whole word against a sentinel:
       an empty read returns {stale head, empty=1, garbage code} - see axi_ctl.v. Bounded: the
       FIFO is 32 deep, so 64 pops always clears it even if keys arrive mid-flush. */
    for (int i = 0; i < 64 && !(KBD_DATA & 0x100u); i++) { }
}

static void bg_pump(void) {
    /* Background work while a modal loop waits for a key: the producers must never starve.
       Machine-agnostic by design: pumps + UI ticks only, nothing here knows about the ZX. */
    tape_pump();                                                 /* an open menu must not kill a running tape load */
    if (g_tape_on && g_tape_fmt == TAPE_FMT_MP3) tape_pump();    /* heavier decode path: main-loop parity */
    pump_autoadvance();                                          /* track ended while a menu/dialog is open -> play next */
    if (!g_tape_on && browser_on) {
        if (player_active()) {                                   /* keep the row-22 music status live under the menu */
            unsigned pct = player_progress(); if (pct > 100u) pct = 100u;
            unsigned el = player_elapsed_s();
            if (pct != g_music_last_pct || el != g_music_last_sec) { g_music_last_pct = pct; g_music_last_sec = el; dn_draw_status(); }
        }
        if (!g_menu_open) browser_scroll_tick();                 /* marquee only when no dropdown covers the list */
        status_scroll_tick();                                    /* row 22 sits below every dropdown - always safe */
    }
}

/* ================= unified key-state layer (single source of truth) =============================
   The renewed "fuzzy keys / F6 takes 3 tries" bug is architectural: the main loop AND the modal
   get_keysym_blocking() were SEPARATE keyboard consumers, each with its own per-key "held" booleans.
   When a modal ate a key's break frame, the other consumer's latch stayed stuck. Fix: BOTH feed every
   popped FIFO entry through kbd_note(), which owns the one key-down table. A break seen anywhere clears
   it; typematic auto-repeat is de-duplicated (rising-edge return) so single-shot keys fire exactly once;
   a >1.5 s silence auto-releases a key (self-heals a genuinely lost break). Machine-agnostic ARM layer. */
static uint8_t g_kd[256];
static XTime   g_kd_t[256];
#define KD_STALE (COUNTS_PER_SECOND*3u/2u)     /* 1.5 s: longer than any typematic gap, so only a real
                                                  re-press (or a lost break) re-arms a held key */
static int kbd_note(uint32_t code, int release){
    if(code==0xF0u || code==0xE0u || code==0xE1u) return 0;   /* prefix bytes are not keys */
    if(release){ g_kd[code]=0; return 0; }
    XTime now; XTime_GetTime(&now);
    int was = g_kd[code] && ((uint64_t)(now - g_kd_t[code]) < (uint64_t)KD_STALE);
    g_kd[code]=1; g_kd_t[code]=now;
    return !was;                               /* 1 = rising edge (fresh press, not typematic repeat) */
}
/* PS/2 set-2 scancode -> printable ASCII (US layout) for dialog text entry. 0 = not a text key.
   Machine-agnostic: this is the ARM keyboard layer, no core knows about it. */
static char sc_to_ascii(uint32_t code, int shift){
    switch(code){
        case 0x1Cu: return shift?'A':'a'; case 0x32u: return shift?'B':'b'; case 0x21u: return shift?'C':'c';
        case 0x23u: return shift?'D':'d'; case 0x24u: return shift?'E':'e'; case 0x2Bu: return shift?'F':'f';
        case 0x34u: return shift?'G':'g'; case 0x33u: return shift?'H':'h'; case 0x43u: return shift?'I':'i';
        case 0x3Bu: return shift?'J':'j'; case 0x42u: return shift?'K':'k'; case 0x4Bu: return shift?'L':'l';
        case 0x3Au: return shift?'M':'m'; case 0x31u: return shift?'N':'n'; case 0x44u: return shift?'O':'o';
        case 0x4Du: return shift?'P':'p'; case 0x15u: return shift?'Q':'q'; case 0x2Du: return shift?'R':'r';
        case 0x1Bu: return shift?'S':'s'; case 0x2Cu: return shift?'T':'t'; case 0x3Cu: return shift?'U':'u';
        case 0x2Au: return shift?'V':'v'; case 0x1Du: return shift?'W':'w'; case 0x22u: return shift?'X':'x';
        case 0x35u: return shift?'Y':'y'; case 0x1Au: return shift?'Z':'z';
        case 0x16u: return shift?'!':'1'; case 0x1Eu: return shift?'@':'2'; case 0x26u: return shift?'#':'3';
        case 0x25u: return shift?'$':'4'; case 0x2Eu: return shift?'%':'5'; case 0x36u: return shift?'^':'6';
        case 0x3Du: return shift?'&':'7'; case 0x3Eu: return shift?'(':'8'; case 0x46u: return shift?')':'9';
        case 0x45u: return shift?')':'0';
        case 0x4Eu: return shift?'_':'-';   /* minus / underscore: both valid 8.3 chars */
        case 0x49u: return shift?'>':'.';   /* period = the 8.3 name/ext separator */
        case 0x4Au: return shift?'?':'/';   /* slash = path separator (Copy-to-folder needs it) */
        default:    return 0;
    }
}
static int get_keysym_blocking(void) {
    while (1) {
        KBD_HB = 1;                             /* deadman heartbeat: the PS/2 gate must stay up while we own the keyboard */
        player_pump();                          /* keep audio pumped and non-blocking! */
        uint32_t d = KBD_DATA;
        if (d & 0x100u) {                       /* bit8 = FIFO empty (the code bits are then stale garbage - no sentinel exists) */
            bg_pump();
            continue;
        }
        uint32_t code = d & 0xFFu;
        int release = (d & 0x200u) != 0;
        int rising = kbd_note(code, release);   /* update the shared key-down table (also seen by the main loop) */
        if (code == 0xF0u || code == 0xE0u) continue;   /* prefix frames */
        kb_alt     = g_kd[0x11];                /* modifiers derived from the one table */
        g_kb_shift = g_kd[0x12] || g_kd[0x59];
        if (release) continue;

        /* single-shot keys: fire only on the rising edge (typematic auto-repeat is ignored) */
        if (code == SC_F9)    { if (rising) return K_F9;    continue; }
        if (code == SC_ENTER) { if (rising) return K_ENTER; continue; }
        if (code == SC_ESC)   { if (rising) return K_ESC;   continue; }
        if (code == 0x0Du)    { if (rising) return K_TAB;   continue; }

        /* navigation + text: fire on every make (typematic repeat is desirable here) */
        switch (code) {
            case SC_UP:    return K_UP;
            case SC_DOWN:  return K_DOWN;
            case SC_LEFT:  return K_LEFT;
            case SC_RIGHT: return K_RIGHT;
            case SC_PGUP:  return K_PGUP;
            case SC_PGDN:  return K_PGDN;
            case SC_HOME:  return K_HOME;
            case SC_END:   return K_END;
            case SC_F3:    return K_F3;
            case SC_F2:    return K_F2;
            case SC_SPACE: return K_SPACE;
            case 0x66u:    return K_BACK;
            default: {
                char ch = sc_to_ascii(code, g_kb_shift);   /* full printable set (letters/digits/symbols) for text fields + menu hotkeys */
                if (ch) return (int)(unsigned char)ch;
            }
        }
    }
}

static void put_cstr(int cx, int cy, const char* s, uint32_t fg, uint32_t bg, uint32_t hot_fg) {
    int x = cx;
    int is_hot = 0;
    for (; *s && x < DN_COLS; s++) {
        if (*s == '~') {
            is_hot = !is_hot;
            continue;
        }
        dn_putc(x++, cy, (unsigned char)*s, is_hot ? hot_fg : fg, bg);
    }
}

static int cstrlen(const char* s) {
    int len = 0;
    for (; *s; s++) {
        if (*s != '~') len++;
    }
    return len;
}

static int g_bar_x0[5], g_bar_w[5];
/* Top-right status on the menu-bar row (right-to-left): version, Vol:NN%, machine type + run/pause
   glyph. Always visible while the navigator is up; refreshed on pause/volume changes too. */
static void draw_topstatus(void){
    dn_fill(45,0,DN_COLS-45,1,DNK_MENU_BG);   /* clear the right zone (past the menu items) - no stale chars when Vol% shrinks */
    int x = DN_COLS - 1;
    char v[40]; version_str(v); int vl=slen(v); x -= vl;
    dn_puts(x,0,v,DNK_MENU_FG,DNK_MENU_BG); x -= 2;
    char vb[16]; int p=0; const char* vp="Vol:"; for(int i=0;vp[i];i++) vb[p++]=vp[i];
    char nb[8]; itoa_u(opt_vol,nb); for(int i=0;nb[i];i++) vb[p++]=nb[i]; vb[p++]='%'; vb[p]=0;
    int bl=slen(vb); x -= bl; dn_puts(x,0,vb,DNK_MENU_FG,DNK_MENU_BG); x -= 2;
    const char* mt=machine_type(); int ml=slen(mt); x -= ml;
    dn_puts(x,0,mt,DNK_MENU_FG,DNK_MENU_BG); x -= 2;
    int halted = (IJ_STAT & 1u);   /* HALT_ACK: machine frozen (manual pause / pause-on-music / SD freeze) */
    dn_put_glyph(x,0, halted?GLYPH_PAUSE:GLYPH_PLAY, halted?FG(4):FG(2), DNK_MENU_BG);   /* red=paused, green=running */
}
static void menubar_draw(int cur){
    dn_fill(0,0,DN_COLS,1, DNK_MENU_BG);
    int x=2;
    for(int i=0;i<g_bar_n;i++){
        int len=cstrlen(g_bar[i].title);
        g_bar_x0[i]=x; g_bar_w[i]=len;
        int sel=(i==cur);
        uint32_t fg=sel?DNK_CUR_FG:DNK_MENU_FG, bg=sel?DNK_CUR_BG:DNK_MENU_BG;
        if(sel) dn_fill(x-1,0,len+2,1,bg);
        put_cstr(x,0,g_bar[i].title, fg,bg, DNK_HOTKEY);
        x += len + 2;
    }
    draw_topstatus();
}

static void menuitem_value_cycle(const MenuItem* it, int dir){
    menu_item* vit = it->value;
    if(!vit) return;
    if(vit->kind==ITEM_CHOICE && vit->val && vit->nchoices>0){
        int nv=(*vit->val + dir + vit->nchoices*100) % vit->nchoices;
        *vit->val = nv;
        if(vit->onchange) vit->onchange();
    }
    else if(vit->kind==ITEM_RANGE && vit->val){
        int step = (vit->rmax>200u?16:vit->rmax>100u?8:vit->rmax>50u?5:1);
        int nv=*vit->val + dir*step;
        if(nv<0) nv=0; if(nv>vit->rmax) nv=vit->rmax;
        *vit->val = nv;
        if(vit->onchange) vit->onchange();
    }
}

static void menubox_size(Menu* m, int* W, int* H){
    int w=10;
    for(int i=0;i<m->count;i++){
        const MenuItem* it=&m->items[i];
        if(!it->name) continue;
        int L=cstrlen(it->name)+6;
        if(it->sub) L+=3;
        else if(it->param) L+=cstrlen(it->param)+2;
        else if(it->value) L+=8;
        if(L>w) w=L;
    }
    *W=w; *H=2+m->count;
}

static void menubox_draw_row(Menu* m, int cur, int left, int top, int W, int row) {
    if (row < 0 || row >= m->count) return;
    const MenuItem* it = &m->items[row];
    int ry = top + 1 + row;
    int is_cur = (row == cur);
    uint32_t bg = is_cur ? DNK_CUR_BG : DNK_MENU_BG;
    uint32_t fg = is_cur ? DNK_CUR_FG : (it->disabled ? FG(8) : DNK_MENU_FG);
    
    if (!it->name) {
        dn_fill(left + 1, ry, W - 2, 1, DNK_MENU_BG);             /* erase backdrop under the separator row! */
        dn_hpx(left*8 + 8, (left+W-1)*8 - 8, ry*16 + 8, DNK_MENU_FG);
        return;
    }
    
    dn_fill(left + 1, ry, W - 2, 1, bg);
    put_cstr(left + 2, ry, it->name, fg, bg, DNK_HOTKEY);
    
    if (it->sub) {
        dn_put_glyph(left + W - 3, ry, GLYPH_TRI_R, DNK_STATUS, bg);   /* solid ► triangle: submenu indicator */
    } else if (it->param) {
        int plen = cstrlen(it->param);
        put_cstr(left + W - 2 - plen, ry, it->param, fg, bg, DNK_HOTKEY);
    } else if (it->value) {
        menu_item* vit = it->value;
        char vb[24]; vb[0] = 0;
        if (vit->kind == ITEM_CHOICE && vit->val && vit->choices) {
            const char* vs = vit->choices[(*vit->val) % vit->nchoices];
            int q = 0; for (; vs[q] && q < 23; q++) vb[q] = vs[q]; vb[q] = 0;
        } else if (vit->kind == ITEM_RANGE && vit->val) {
            itoa_u(*vit->val, vb);
            int n = slen(vb);
            if (vit->unit) {
                for (int j = 0; vit->unit[j] && n < 20; j++) vb[n++] = vit->unit[j];
            }
            vb[n] = 0;
        }
        int vlen = slen(vb);
        dn_puts(left + W - 2 - vlen, ry, vb, is_cur ? DNK_CUR_FG : DNK_HEADER, bg);
    }
}

static void menubox_render(Menu* m, int cur, int left, int top, int W, int H) {
    dn_shadow(left, top, W, H);
    dn_box(left, top, W, H, DNK_MENU_FG, DNK_MENU_BG, 0);
    for (int i = 0; i < m->count; i++) {
        menubox_draw_row(m, cur, left, top, W, i);
    }
}

typedef struct { Menu* menu; int bar, cur, left, top, W, H; } MenuState;

/* ---- dropdown backdrop save/restore: closing or switching a menu costs one small blit, not a
   full 640x400 redraw (the anti-flicker rule). Two levels: bar dropdown + one nested submenu;
   LIFO restore (child first) keeps overlapping boxes consistent. Sized for the tallest submenu
   (Settings: 18 rows) + the DN shadow. ---- */
#define BOXSAVE_W (48*8)               /* widest overlay (rename dialog 44 + shadow) */
#define BOXSAVE_H (22*16)              /* tallest overlay (Settings submenu 18 rows + borders) */
typedef struct { int x, y, w, h, valid; uint32_t px[BOXSAVE_W*BOXSAVE_H]; } BoxSave;
static BoxSave g_bs[2];
static void box_backup(BoxSave* b, int cx, int cy, int cw, int chh){   /* region in cells, incl. the shadow margin */
    b->x = cx*8; b->y = cy*16; b->w = cw*8; b->h = chh*16;
    if (b->x < 0) b->x = 0;
    if (b->y < 0) b->y = 0;
    if (b->w > BOXSAVE_W) b->w = BOXSAVE_W;
    if (b->h > BOXSAVE_H) b->h = BOXSAVE_H;
    if (b->x + b->w > OSDC_W) b->w = OSDC_W - b->x;
    if (b->y + b->h > OSDC_H) b->h = OSDC_H - b->y;
    for (int y = 0; y < b->h; y++)
        for (int x = 0; x < b->w; x++) b->px[y*b->w + x] = g_osdc[(b->y+y)*OSDC_W + b->x + x];
    b->valid = 1;
}
static void box_restore(BoxSave* b){
    if (!b->valid) return;
    for (int y = 0; y < b->h; y++)
        for (int x = 0; x < b->w; x++) g_osdc[(b->y+y)*OSDC_W + b->x + x] = b->px[y*b->w + x];
    b->valid = 0;
}

static int menubar_exec(int start); /* fwd */

/* Reusable modal-window frame (TWindow/TFrame-style): translucent shadow, opaque gray body, white
   double frame, centred title in the top border. Every DN dialog draws its chrome through this. */
static void dn_win_draw(int left,int top,int W,int H,const char* title){
    dn_shadow(left,top,W,H);
    dn_fill(left,top,W,H,DNK_DLG_BG);                          /* opaque body (dn_box paints only the border) */
    dn_box(left,top,W,H,DNK_DLG_FRAME,DNK_DLG_BG,1);           /* white double frame = active window */
    int tl=slen(title), tx=left+(W-tl-2)/2;                    /* title colour == frame (DN active: 0x7F) */
    dn_putc(tx,top,' ',DNK_DLG_FRAME,DNK_DLG_BG);
    dn_puts(tx+1,top,title,DNK_DLG_FRAME,DNK_DLG_BG);
    dn_putc(tx+1+tl,top,' ',DNK_DLG_FRAME,DNK_DLG_BG);
}

/* ================= modal DN dialog: text input with OK / Cancel =================================
   Buttons live HERE (in modal dialogs), never in menus - per the owner's design. Returns 1=OK (out
   holds the edited text), 0=Cancel. Reuses get_keysym_blocking, so audio + tape keep pumping via
   bg_pump while the dialog is up. Machine-agnostic: pure ARM UI over the DN canvas. */
#define DLG_W  44
#define DLG_H  9
#define DLG_FW 34                        /* input-field width in cells */
static void rn_draw_field(int fx,int fy,const char* buf,int len,int cur,int foff,int focused){
    for(int i=0;i<DLG_FW;i++){
        int idx=foff+i;
        unsigned ch = (idx<len)?(unsigned char)buf[idx]:' ';
        int is_cur = focused && idx==cur;               /* cursor cell = inverse (blue glyph on white) */
        dn_putc(fx+i,fy, ch, is_cur?DNK_FLD_BG:DNK_FLD_FG, is_cur?DNK_FLD_FG:DNK_FLD_BG);
    }
}
static void rn_draw_buttons(int left,int brow,int focus){
    dn_fill(left+1,brow,DLG_W-2,2,DNK_DLG_BG);           /* erase old button faces + pointers */
    int bw = 10, gap = 4;                                /* equal-width buttons (DN dialogs pad to a common width) */
    int total = (bw+1) + gap + (bw+1);
    int bx = left + (DLG_W - total)/2;                   /* centre the OK/Cancel pair */
    dn_button(bx,               brow, "OK",     focus!=2, bw);   /* OK = default: marked unless Cancel is focused */
    dn_button(bx + bw+1 + gap,  brow, "Cancel", focus==2, bw);
}
static int dn_input_dialog(const char* title,const char* prompt,char* buf,int maxlen){
    int left=(DN_COLS-DLG_W)/2, top=(DN_ROWS-DLG_H)/2;
    int fx=left+3, fy=top+4, brow=top+6;
    int len=slen(buf), cur=len, foff=0, focus=0, result=-1;
    box_backup(&g_bs[0], left, top, DLG_W+2, DLG_H+1);   /* save the backdrop -> restore on close, no full redraw */
    dn_win_draw(left,top,DLG_W,DLG_H,title);
    dn_puts(left+3,top+2,prompt,DNK_DLG_FG,DNK_DLG_BG);
    { static const char* const kb[3][2]={{"Enter","OK"},{"Tab","Next"},{"Esc","Cancel"}}; dn_keybar(kb,3); }  /* dialog's active keys on the bottom status line */
    while(result<0){
        if(cur<foff) foff=cur;
        if(cur>=foff+DLG_FW) foff=cur-DLG_FW+1;
        if(foff<0) foff=0;
        rn_draw_field(fx,fy,buf,len,cur,foff,focus==0);
        rn_draw_buttons(left,brow,focus);
        int k=get_keysym_blocking();
        if(k==K_ESC){ result=0; break; }
        if(k==K_TAB){ focus=(focus+1)%3; continue; }
        if(k==K_ENTER){ result=(focus==2)?0:1; break; }        /* Enter = OK (default), unless on Cancel */
        if(focus==0){                                          /* editing the field */
            if(k==K_LEFT){ if(cur>0) cur--; continue; }
            if(k==K_RIGHT){ if(cur<len) cur++; continue; }
            if(k==K_HOME){ cur=0; continue; }
            if(k==K_END){ cur=len; continue; }
            if(k==K_DOWN){ focus=1; continue; }
            if(k==K_BACK){ if(cur>0){ for(int i=cur-1;i<len;i++) buf[i]=buf[i+1]; len--; cur--; } continue; }
            if(k>=0x20 && k<0x7F && len<maxlen-1){             /* printable: insert at cursor */
                for(int i=len;i>=cur;i--) buf[i+1]=buf[i];
                buf[cur]=(char)k; len++; cur++; }
        } else {                                               /* on a button */
            if(k==K_UP)    { focus=0; continue; }
            if(k==K_LEFT)  { focus=1; continue; }
            if(k==K_RIGHT) { focus=2; continue; }
            if(k==K_SPACE) { result=(focus==2)?0:1; break; }
        }
    }
    box_restore(&g_bs[0]);       /* restore the backdrop under the dialog */
    dn_keybar_browser();         /* restore the browser's status line (row 24 is outside the saved box) */
    return result==1;
}
/* Build "0:/dir/name" into out from curpath + a leaf name. */
static int path_of(char* out,const char* nm){
    int p=0; for(int i=0;curpath[i]&&p<190;i++) out[p++]=curpath[i];
    if(p && out[p-1]!='/') out[p++]='/';
    for(int i=0;nm[i]&&p<199;i++) out[p++]=nm[i];
    out[p]=0; return p;
}
/* F6 (Total Commander style): the input line is PRE-FILLED with the full path of the selected entry.
   Edit only the name -> rename in place; edit the folder part -> move; clear it and type a bare name
   -> rename in the current folder. Same-folder change = instant f_rename; different folder = move with
   a progress bar (copy + remove source). Missing destination folders are created first. */
static void rename_selected(void){
    if(fcount==0 || bcursor<0 || bcursor>=fcount) return;
    if(selcount()>1){ group_copy_move(1, "Move"); return; }    /* multiple tagged -> group MOVE, not rename */
    const char* nm=flist[bcursor];
    if(nm[0]=='.'&&nm[1]=='.'&&nm[2]==0) return;               /* never ".." */
    if(g_tape_on){ dn_status_msg("BUSY - TAPE LOADING"); return; }
    char oldp[220]; path_of(oldp, nm);
    char buf[220]; { int i=0; for(; oldp[i]&&i<219;i++) buf[i]=oldp[i]; buf[i]=0; }   /* pre-fill the FULL path */
    if(!dn_input_dialog("Rename or move", "To:", buf, (int)sizeof(buf))) return;
    { int l=slen(buf); while(l>0 && buf[l-1]==' ') buf[--l]=0; }
    if(buf[0]==0) return;
    /* normalise the edited text -> newp "0:/..." : has drive -> as-is; leading '/' -> under root;
       otherwise (a bare name, no slash) -> in the current folder */
    char newp[240]; int p=0;
    if(buf[1]==':'){ for(int i=0;buf[i]&&p<239;i++) newp[p++]=buf[i]; }
    else if(buf[0]=='/'){ newp[p++]='0'; newp[p++]=':'; for(int i=0;buf[i]&&p<239;i++) newp[p++]=buf[i]; }
    else { for(int i=0;curpath[i]&&p<200;i++) newp[p++]=curpath[i]; if(p&&newp[p-1]!='/') newp[p++]='/'; for(int i=0;buf[i]&&p<239;i++) newp[p++]=buf[i]; }
    while(p>3 && newp[p-1]=='/') p--;                          /* trailing "/" (folder given) -> keep original name */
    if(p>0 && (newp[p-1]=='/' || buf[slen(buf)-1]=='/')){ for(int i=0;nm[i]&&p<239;i++) newp[p++]=nm[i]; }
    newp[p]=0;
    { int eq=1; for(int i=0;;i++){ if(oldp[i]!=newp[i]){ eq=0; break; } if(!oldp[i]) break; } if(eq) return; }  /* EXACT (case-sensitive) equal -> unchanged */
    int caseonly = (cicmp(oldp,newp)==0);                      /* differs ONLY by letter case */
    /* destination folder = parent of newp */
    char newdir[220]; { int c=-1; for(int i=0;newp[i];i++) if(newp[i]=='/') c=i;
        if(c<=2){ newdir[0]='0';newdir[1]=':';newdir[2]='/';newdir[3]=0; }
        else { int i=0; for(; i<c && i<219; i++) newdir[i]=newp[i]; newdir[i]=0; } }
    int in_place = (cicmp(newdir, curpath)==0);                /* same folder -> pure rename */
    if(player_active() && playing_idx==bcursor){ player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt(); }
    int isdir=fisdir[bcursor];
    if(in_place){                                              /* rename in place: instant, no progress */
        sdop_freeze_begin();
        FRESULT r;
        if(caseonly){                                          /* FAT is case-insensitive: renaming to the same name in a
                                                                  different case hits "target exists" -> go via a temp name */
            char tmp[240]; int t=0; for(int i=0;newdir[i]&&t<230;i++) tmp[t++]=newdir[i];
            if(t&&tmp[t-1]!='/') tmp[t++]='/'; { const char* tn="_BLBTMP_"; for(int i=0;tn[i]&&t<239;i++) tmp[t++]=tn[i]; } tmp[t]=0;
            r = f_rename(oldp, tmp);
            if(r==FR_OK) r = f_rename(tmp, newp);
        } else {
            r = f_rename(oldp, newp);
        }
        sdop_freeze_end();
        if(r!=FR_OK){ dn_status_msg(r==FR_EXIST?"NAME EXISTS":"FAILED"); return; }
    } else {                                                   /* move to another folder: copy + remove source, with a bar */
        mkdir_path(newdir);
        uint64_t total = isdir ? count_tree(oldp) : (uint64_t)fsz[bcursor];
        path_of(oldp, nm);                                     /* count_tree mutated oldp -> rebuild */
        int rc = copy_move_run(oldp, newp, isdir, total, 1, "Move");
        if(rc<=0){ sd_scan(); if(browser_on) render_browser(); dn_status_msg(rc<0?"CANCELLED":"MOVE FAILED"); return; }
    }
    int is_move = !in_place;
    sd_scan(); sort_entries(); remap_playing_idx();
    const char* bn=base_name(newp);
    for(int i=0;i<fcount;i++) if(cicmp(flist[i],bn)==0){ bcursor=i; break; }   /* keep cursor if still here (rename) */
    if(bcursor>=fcount) bcursor=fcount?fcount-1:0;
    if(bcursor<btop) btop=bcursor;
    if(bcursor>=btop+BROWS) btop=bcursor-BROWS+1;
    if(btop<0) btop=0;
    render_browser();
    dn_status_msg(is_move?"MOVED":"RENAMED");
}

/* ---- modal Yes/No confirmation (msgbox). Returns 1=Yes. Default focus = No (safe for destructive ops).
   A message longer than the box scrolls (marquee) instead of spilling over the frame. Non-blocking loop
   (so the marquee animates and background music keeps advancing). ---- */
static int dn_confirm(const char* title, const char* msg){
    int W=DLG_W, H=8, left=(DN_COLS-W)/2, top=(DN_ROWS-H)/2, brow=top+5;
    int focus=0, result=-1;                        /* focus: 0=No, 1=Yes */
    box_backup(&g_bs[0], left, top, W+2, H+1);
    dn_win_draw(left,top,W,H,title);
    { static const char* const kb[2][2]={{"Enter","OK"},{"Esc","Cancel"}}; dn_keybar(kb,2); }
    int bw=8, gap=4, total=(bw+1)+gap+(bw+1), bx=left+(W-total)/2;
    dn_button(bx,          brow, "Yes", focus==1, bw);
    dn_button(bx+bw+1+gap, brow, "No",  focus==0, bw);
    int mlen=slen(msg), innerW=W-4, mx=left+2, scroll=(mlen>innerW), off=0, drawn=-999;
    XTime last=0;
    while(result<0){
        if(off!=drawn){                                            /* redraw the message ONLY when the marquee moved (no flicker) */
            drawn=off;
            dn_fill(left+1, top+2, W-2, 1, DNK_DLG_BG);
            if(scroll){ int show=off; if(show>mlen-innerW) show=mlen-innerW; dn_putsn(mx, top+2, msg+show, innerW, DNK_DLG_FG, DNK_DLG_BG); }
            else        dn_puts(left+(W-mlen)/2, top+2, msg, DNK_DLG_FG, DNK_DLG_BG);
        }
        KBD_HB=1; player_pump(); pump_autoadvance();               /* keep audio going while the box is up */
        uint32_t d=KBD_DATA;
        if(d&0x100u){                                              /* idle: advance the marquee on a timer */
            if(scroll){ XTime now; XTime_GetTime(&now); if(last==0) last=now;
                if((uint64_t)(now-last) > (uint64_t)COUNTS_PER_SECOND/4){ last=now; off++; if(off > mlen-innerW+4) off=0; } }
            continue;
        }
        uint32_t code=d&0xFFu; int rel=(d&0x200u)!=0; int rising=kbd_note(code,rel);
        if(code==0xF0u||code==0xE0u || rel) continue;
        if(code==SC_ESC){ if(rising) result=0; continue; }
        if(code==SC_ENTER||code==SC_SPACE){ if(rising) result=focus; continue; }
        if(code==SC_LEFT||code==SC_RIGHT||code==0x0Du){            /* Left/Right/Tab: toggle Yes/No */
            focus^=1; dn_button(bx,brow,"Yes",focus==1,bw); dn_button(bx+bw+1+gap,brow,"No",focus==0,bw); continue; }
        { char ch=sc_to_ascii(code, g_kb_shift); if(ch=='y'){ result=1; } else if(ch=='n'){ result=0; } }
    }
    box_restore(&g_bs[0]);
    dn_keybar_browser();
    return result==1;
}
static int dn_confirm_delete(const char* title, const char* prefix, const char* filename){
    int W=DLG_W, H=9, left=(DN_COLS-W)/2, top=(DN_ROWS-H)/2, brow=top+6;
    int focus=0, result=-1;                        /* focus: 0=No, 1=Yes */
    box_backup(&g_bs[0], left, top, W+2, H+1);
    dn_win_draw(left,top,W,H,title);
    { static const char* const kb[2][2]={{"Enter","OK"},{"Esc","Cancel"}}; dn_keybar(kb,2); }
    int bw=8, gap=4, total=(bw+1)+gap+(bw+1), bx=left+(W-total)/2;
    dn_button(bx,          brow, "Yes", focus==1, bw);
    dn_button(bx+bw+1+gap, brow, "No",  focus==0, bw);
    int pre_len=slen(prefix), fn_len=slen(filename), innerW=W-4, mx=left+2, scroll=(fn_len>innerW), off=0, drawn=-999;
    XTime last=0;
    dn_puts(left+(W-pre_len)/2, top+2, prefix, DNK_DLG_FG, DNK_DLG_BG);
    while(result<0){
        if(off!=drawn){
            drawn=off;
            dn_fill(left+1, top+4, W-2, 1, DNK_DLG_BG);
            if(scroll){ int show=off; if(show>fn_len-innerW) show=fn_len-innerW; dn_putsn(mx, top+4, filename+show, innerW, DNK_DLG_FG, DNK_DLG_BG); }
            else        dn_puts(left+(W-fn_len)/2, top+4, filename, DNK_DLG_FG, DNK_DLG_BG);
        }
        KBD_HB=1; player_pump(); pump_autoadvance();               /* keep audio going while the box is up */
        uint32_t d=KBD_DATA;
        if(d&0x100u){                                              /* idle: advance the marquee on a timer */
            if(scroll){ XTime now; XTime_GetTime(&now); if(last==0) last=now;
                if((uint64_t)(now-last) > (uint64_t)COUNTS_PER_SECOND/4){ last=now; off++; if(off > fn_len-innerW+4) off=0; } }
            continue;
        }
        uint32_t code=d&0xFFu; int rel=(d&0x200u)!=0; int rising=kbd_note(code,rel);
        if(code==0xF0u||code==0xE0u || rel) continue;
        if(code==SC_ESC){ if(rising) result=0; continue; }
        if(code==SC_ENTER||code==SC_SPACE){ if(rising) result=focus; continue; }
        if(code==SC_LEFT||code==SC_RIGHT||code==0x0Du){            /* Left/Right/Tab: toggle Yes/No */
            focus^=1; dn_button(bx,brow,"Yes",focus==1,bw); dn_button(bx+bw+1+gap,brow,"No",focus==0,bw); continue; }
        { char ch=sc_to_ascii(code, g_kb_shift); if(ch=='y'){ result=1; } else if(ch=='n'){ result=0; } }
    }
    box_restore(&g_bs[0]);
    dn_keybar_browser();
    return result==1;
}
/* Append a leaf name to a "0:/dir" buffer in place -> "0:/dir/leaf" (returns new length). */
static int path_join(char* buf, int len, const char* leaf){
    buf[len]='/'; int k=0; for(; leaf[k] && len+1+k<198; k++) buf[len+1+k]=leaf[k]; buf[len+1+k]=0;
    return len+1+k;
}
/* ===== DN-style progress dialog for long file ops (copy / recursive delete) =====================
   Bar (done/total bytes) + current item + [Pause]/[Cancel]; pumps audio + deadman; polls P/Space
   (pause) and Esc (cancel). PG_W+2 <= 48 so box_backup fits. */
#define PG_W 46
#define PG_H 9
static uint64_t g_pg_total, g_pg_done;
static int g_pg_pct, g_pg_abort, g_pg_paused, g_pg_left, g_pg_top;
static void pg_draw_bar(void){
    int pct = g_pg_total ? (int)((g_pg_done*100u)/g_pg_total) : 100; if(pct>100)pct=100;
    dn_bar(g_pg_left+3, g_pg_top+5, PG_W-6, pct*10, DNK_STATUS, DNK_DLG_BG);
    char pb[6]; int p=0; if(pct>=100){pb[p++]='1';pb[p++]='0';pb[p++]='0';} else { if(pct>=10)pb[p++]='0'+pct/10; pb[p++]='0'+pct%10; } pb[p++]='%'; pb[p]=0;
    dn_puts(g_pg_left+(PG_W-slen(pb))/2, g_pg_top+5, pb, DNK_DLG_FRAME, DNK_DLG_BG);
}
static void pg_draw_buttons(void){
    int brow=g_pg_top+7, bw=8, gap=4, total=(bw+1)+gap+(bw+1), bx=g_pg_left+(PG_W-total)/2;
    dn_fill(g_pg_left+1,brow,PG_W-2,2,DNK_DLG_BG);
    dn_button(bx, brow, g_pg_paused?"Resume":"Pause", g_pg_paused, bw);
    dn_button(bx+bw+1+gap, brow, "Cancel", 0, bw);
}
static void pg_set_item(const char* name){
    int y=g_pg_top+3; dn_fill(g_pg_left+1,y,PG_W-2,1,DNK_DLG_BG);
    dn_putsn(g_pg_left+3,y,name,PG_W-6,DNK_DLG_FG,DNK_DLG_BG);
}
static void pg_open(const char* title){
    g_pg_left=(DN_COLS-PG_W)/2; g_pg_top=(DN_ROWS-PG_H)/2;
    g_pg_pct=-1; g_pg_abort=0; g_pg_paused=0;
    box_backup(&g_bs[0], g_pg_left, g_pg_top, PG_W+2, PG_H+1);
    dn_win_draw(g_pg_left,g_pg_top,PG_W,PG_H,title);
    pg_draw_bar(); pg_draw_buttons();
    { static const char* const kb[2][2]={{"P","Pause"},{"Esc","Cancel"}}; dn_keybar(kb,2); }
}
static void pg_close(void){ box_restore(&g_bs[0]); dn_keybar_browser(); }
static void pg_tick(void){
    int pct = g_pg_total ? (int)((g_pg_done*100u)/g_pg_total) : 100; if(pct>100)pct=100;
    if(pct!=g_pg_pct){ g_pg_pct=pct; pg_draw_bar(); }
    do {                                              /* one pass normally; loops while paused */
        KBD_HB=1; player_pump(); pump_autoadvance();  /* keep music continuous (next track) during the file op */
        uint32_t d=KBD_DATA;
        if(!(d&0x100u)){
            uint32_t code=d&0xFFu; int rel=(d&0x200u)!=0; kbd_note(code,rel);
            if(!rel){
                if(code==SC_ESC){ g_pg_abort=1; g_pg_paused=0; }
                else if(code==0x4Du || code==SC_SPACE){ g_pg_paused=!g_pg_paused; pg_draw_buttons(); }   /* P / Space */
            }
        }
    } while(g_pg_paused && !g_pg_abort);
}
/* Total bytes under a folder (progress denominator); metadata-only, so quick. `path` is a mutable buffer. */
static uint64_t count_tree(char* path){
    DIR d; FILINFO fi; uint64_t tot=0;
    if(f_opendir(&d,path)!=FR_OK) return 0;
    int len=slen(path);
    while(f_readdir(&d,&fi)==FR_OK && fi.fname[0]){
        if(fi.fname[0]=='.'&&(fi.fname[1]==0||(fi.fname[1]=='.'&&fi.fname[2]==0))) continue;
        KBD_HB=1; player_pump();                          /* keep the audio ring fed during the pre-count walk (else music drains to silence) */
        if(fi.fattrib&AM_DIR){ path_join(path,len,fi.fname); tot+=count_tree(path); path[len]=0; }
        else tot += (uint64_t)fi.fsize;
    }
    f_closedir(&d);
    return tot;
}
static int copy_file_pg(const char* src, const char* dst){   /* 1=ok, 0=fail, -1=abort; drives the progress bar */
    FIL fs, fd; UINT br, bw; int rc=1;
    if(f_open(&fs, src, FA_READ)!=FR_OK) return 0;
    if(f_open(&fd, dst, FA_CREATE_ALWAYS|FA_WRITE)!=FR_OK){ f_close(&fs); return 0; }
    for(;;){
        pg_tick(); if(g_pg_abort){ rc=-1; break; }
        if(f_read(&fs, snapbuf, sizeof(snapbuf), &br)!=FR_OK){ rc=0; break; }
        if(br==0) break;
        if(f_write(&fd, snapbuf, br, &bw)!=FR_OK || bw!=br){ rc=0; break; }
        g_pg_done += bw;
    }
    f_close(&fs); f_close(&fd);
    return rc;
}
/* Recursively copy a file or folder. src/dst are mutable "0:/..." buffers (>=200). 1=ok,0=fail,-1=abort. */
static int copy_entry(char* src, char* dst, int isdir){
    if(!isdir){ pg_set_item(base_name(src)); return copy_file_pg(src,dst); }
    f_mkdir(dst);                                     /* FR_EXIST ignored */
    DIR d; FILINFO fi;
    if(f_opendir(&d,src)!=FR_OK) return 0;
    int sl=slen(src), dl=slen(dst), rc=1;
    while(f_readdir(&d,&fi)==FR_OK && fi.fname[0]){
        if(fi.fname[0]=='.'&&(fi.fname[1]==0||(fi.fname[1]=='.'&&fi.fname[2]==0))) continue;
        path_join(src,sl,fi.fname); path_join(dst,dl,fi.fname);
        rc = copy_entry(src,dst,(fi.fattrib&AM_DIR)?1:0);
        src[sl]=0; dst[dl]=0;
        if(rc<=0) break;
    }
    f_closedir(&d);
    return rc;
}
/* Recursively delete a folder + contents; drives the progress bar; honours Cancel. 1=ok,0=fail,-1=abort. */
static int rmdir_recursive(char* path){
    DIR d; FILINFO fi;
    if(f_opendir(&d, path) != FR_OK) return 0;
    int len = slen(path);
    while(f_readdir(&d, &fi) == FR_OK && fi.fname[0]){
        if(fi.fname[0]=='.' && (fi.fname[1]==0 || (fi.fname[1]=='.'&&fi.fname[2]==0))) continue;
        path_join(path,len,fi.fname);
        pg_set_item(fi.fname); pg_tick();
        if(g_pg_abort){ path[len]=0; f_closedir(&d); return -1; }
        int rc;
        if(fi.fattrib & AM_DIR){ rc = rmdir_recursive(path); }
        else { rc = (f_unlink(path)==FR_OK); g_pg_done += (uint64_t)fi.fsize; pg_tick(); }
        path[len]=0;
        if(rc<=0){ f_closedir(&d); return rc; }
    }
    f_closedir(&d);
    return (f_unlink(path)==FR_OK);                    /* the now-empty dir itself */
}
/* Shared copy/move worker: copy src->dst with the progress dialog; if removesrc, delete the source
   after (= move). src/dst are mutable "0:/..." buffers (>=220); total = pre-counted bytes. 1=ok,0=fail,-1=abort. */
static int copy_move_run(char* src, char* dst, int isdir, uint64_t total, int removesrc, const char* title){
    g_pg_total = total?total:1; g_pg_done=0;
    char save[220]; { int i=0; for(; src[i]&&i<219;i++) save[i]=src[i]; save[i]=0; }   /* copy_entry mutates src */
    pg_open(title);
    int rc = copy_entry(src, dst, isdir);
    if(rc>0 && removesrc){                              /* move = copy, then remove the source */
        { int i=0; for(; save[i]&&i<219;i++) src[i]=save[i]; src[i]=0; }
        pg_set_item("Removing source...");
        rc = isdir ? rmdir_recursive(src) : (f_unlink(src)==FR_OK);
    }
    pg_close();
    return rc;
}
/* ===== group selection (Space tags) -> snapshot for copy/delete/move ============================
   Snapshot is taken by NAME (indices shift as files are deleted / the list re-scans). If nothing is
   tagged, the cursor entry is used. ".." is never included. */
static int is_dotdot(int i){ return flist[i][0]=='.'&&flist[i][1]=='.'&&flist[i][2]==0; }
static int selcount(void){ int n=0; for(int i=0;i<fcount;i++) if(fsel[i] && !is_dotdot(i)) n++; return n; }
static char     g_snm[MAXFILES][NAMELEN+1];   /* snapshot: names */
static uint8_t  g_sdir[MAXFILES];             /* snapshot: is-dir */
static uint32_t g_ssz[MAXFILES];              /* snapshot: size */
static int      g_snc;                         /* snapshot count */
static int snapshot_sel(void){
    g_snc=0;
    for(int i=0;i<fcount && g_snc<MAXFILES;i++){
        if(is_dotdot(i) || !fsel[i]) continue;
        int k=0; for(; flist[i][k]&&k<NAMELEN;k++) g_snm[g_snc][k]=flist[i][k]; g_snm[g_snc][k]=0;
        g_sdir[g_snc]=fisdir[i]; g_ssz[g_snc]=fsz[i]; g_snc++;
    }
    if(g_snc==0 && bcursor>=0 && bcursor<fcount && !is_dotdot(bcursor)){   /* nothing tagged -> the cursor entry */
        int k=0; for(; flist[bcursor][k]&&k<NAMELEN;k++) g_snm[0][k]=flist[bcursor][k]; g_snm[0][k]=0;
        g_sdir[0]=fisdir[bcursor]; g_ssz[0]=fsz[bcursor]; g_snc=1;
    }
    return g_snc;
}
/* stop the player if one of the snapshot entries is the track currently playing (about to be moved/deleted) */
static void stop_if_playing_snapshot(void){
    if(!player_active() || !g_music_path[0]) return;
    const char* pn = base_name(g_music_path);
    for(int i=0;i<g_snc;i++) if(cicmp(g_snm[i], pn)==0 && cicmp(curpath, play_dir)==0){
        player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt(); return; }
}
/* Group copy (removesrc=0) or move (removesrc=1) of the snapshot to a destination folder, one bar for all. */
static void group_copy_move(int removesrc, const char* title){
    if(g_tape_on){ dn_status_msg("BUSY - TAPE LOADING"); return; }
    if(snapshot_sel()==0) return;
    char dstdir[80]; { int j=0; for(; curpath[j]&&j<79;j++) dstdir[j]=curpath[j]; dstdir[j]=0; }
    if(!dn_input_dialog(removesrc?"Move to folder":"Copy to folder", "Folder:", dstdir, (int)sizeof(dstdir))) return;
    { int l=slen(dstdir); while(l>0&&dstdir[l-1]==' ') dstdir[--l]=0; }
    if(dstdir[0]==0) return;
    char dfold[200]; int p=0;
    if(dstdir[1]==':'){ for(int i=0;dstdir[i]&&p<190;i++) dfold[p++]=dstdir[i]; }
    else { dfold[p++]='0'; dfold[p++]=':'; if(dstdir[0]!='/') dfold[p++]='/'; for(int i=0;dstdir[i]&&p<190;i++) dfold[p++]=dstdir[i]; }
    while(p>3 && dfold[p-1]=='/') p--; dfold[p]=0;
    uint64_t total=0;                                    /* progress denominator over the whole group */
    for(int i=0;i<g_snc;i++){ if(g_sdir[i]){ char cc[220]; path_of(cc,g_snm[i]); total+=count_tree(cc); } else total+=g_ssz[i]; }
    if(total==0) total=1;
    stop_if_playing_snapshot();
    mkdir_path(dfold);
    g_pg_total=total; g_pg_done=0;
    pg_open(title);
    int okall=1, aborted=0;
    for(int i=0;i<g_snc;i++){
        char src[220]; path_of(src, g_snm[i]);
        char dst[240]; int q=0; for(int k=0;dfold[k]&&q<200;k++) dst[q++]=dfold[k];
        if(q==0||dst[q-1]!='/') dst[q++]='/'; for(int k=0;g_snm[i][k]&&q<239;k++) dst[q++]=g_snm[i][k]; dst[q]=0;
        if(cicmp(src,dst)==0) continue;                  /* same place -> skip */
        pg_set_item(g_snm[i]);
        int rc = copy_entry(src, dst, g_sdir[i]);
        if(rc<0){ aborted=1; break; }
        if(rc==0){ okall=0; continue; }
        if(removesrc){ char s2[220]; path_of(s2,g_snm[i]); if(g_sdir[i]) rmdir_recursive(s2); else f_unlink(s2); }
    }
    pg_close();
    sd_scan();                                           /* clears fsel (fresh listing) */
    if(browser_on) render_browser();
    dn_status_msg(aborted?"CANCELLED": okall?(removesrc?"MOVED":"COPIED"):"SOME FAILED");
}
static void delete_selected(void){
    if(fcount==0||bcursor<0||bcursor>=fcount) return;
    if(g_tape_on){ dn_status_msg("BUSY - TAPE LOADING"); return; }
    int nc = selcount();
    if(nc>1){                                            /* ---- group delete ---- */
        snapshot_sel();
        char msg[40]; int p=0; const char* a="Delete "; for(int i=0;a[i];i++) msg[p++]=a[i];
        { char nb[8]; itoa_u(nc,nb); for(int i=0;nb[i];i++) msg[p++]=nb[i]; } { const char* b=" items?"; for(int i=0;b[i];i++) msg[p++]=b[i]; } msg[p]=0;
        if(!dn_confirm("Delete", msg)) return;
        stop_if_playing_snapshot();
        uint64_t total=0; for(int i=0;i<g_snc;i++){ if(g_sdir[i]){ char cc[220]; path_of(cc,g_snm[i]); total+=count_tree(cc); } else total+=g_ssz[i]; }
        if(total==0) total=1;
        g_pg_total=total; g_pg_done=0;
        pg_open("Delete");
        int aborted=0;
        for(int i=0;i<g_snc;i++){
            char pth[220]; path_of(pth, g_snm[i]);
            pg_set_item(g_snm[i]);
            int rc = g_sdir[i] ? rmdir_recursive(pth) : (f_unlink(pth)==FR_OK);
            if(!g_sdir[i]){ g_pg_done += g_ssz[i]; pg_tick(); }
            if(rc<0 || g_pg_abort){ aborted=1; break; }
        }
        pg_close();
        if(bcursor>0) bcursor--;
        sd_scan();
        if(bcursor>=fcount) bcursor = fcount?fcount-1:0;
        render_browser();
        dn_status_msg(aborted?"CANCELLED":"DELETED");
        return;
    }
    const char* nm=flist[bcursor];
    if(nm[0]=='.'&&nm[1]=='.'&&nm[2]==0) return;               /* never ".." */
    if(g_tape_on){ dn_status_msg("BUSY - TAPE LOADING"); return; }
    const char* pre = fisdir[bcursor]?"Delete folder?":"Delete file?";
    if(!dn_confirm_delete("Delete", pre, nm)) return;
    if(player_active() && playing_idx==bcursor){ player_stop(); playing_idx=-1; g_music_path[0]=0; apply_music_halt(); }
    char path[200]; path_of(path, nm);
    sdop_freeze_begin();
    FRESULT r=f_unlink(path);                                  /* quick path: a file or an EMPTY folder */
    sdop_freeze_end();
    int rc = (r==FR_OK);
    if(r==FR_DENIED && fisdir[bcursor]){                        /* folder not empty -> second confirm, then recurse with a progress bar */
        if(!dn_confirm("Folder NOT empty", "Delete ALL its contents?")) return;
        { char cc[200]; int i=0; for(; path[i]&&i<199;i++) cc[i]=path[i]; cc[i]=0; g_pg_total=count_tree(cc); }
        if(g_pg_total==0) g_pg_total=1; g_pg_done=0;
        pg_open("Delete");
        path_of(path, nm);                                     /* rebuild (count/rmdir mutate the buffer) */
        rc = rmdir_recursive(path);
        pg_close();
    }
    if(rc>0){
        if(bcursor>0) bcursor--;
        sd_scan();
        if(bcursor>=fcount) bcursor = fcount?fcount-1:0;
        render_browser();
        dn_status_msg("DELETED");
    } else {
        sd_scan(); if(browser_on) render_browser();            /* partial delete on cancel/fail: refresh */
        dn_status_msg(rc<0?"CANCELLED":"DELETE FAILED");
    }
}
static void mkdir_path(const char* path){          /* create every missing component of "0:/a/b/c" (FR_EXIST ignored) */
    char t[200]; int n=0; for(; path[n] && n<199; n++) t[n]=path[n]; t[n]=0;
    int i=0; if(n>2 && t[1]==':' && t[2]=='/') i=3;   /* skip drive "0:/" */
    for(; i<n; i++){ if(t[i]=='/'){ t[i]=0; if(slen(t)>3) f_mkdir(t); t[i]='/'; } }
    if(slen(t)>3) f_mkdir(t);                         /* final component */
}
static void copy_selected(void){                       /* F5: copy the tagged group (or the cursor entry) to a folder */
    group_copy_move(0, "Copy");
}
/* F7: make directory. Accepts a bare name (under the current folder) or a full/relative path with
   slashes -> mkdir_path creates the whole missing chain. */
static void mkdir_selected(void){
    if(g_tape_on){ dn_status_msg("BUSY - TAPE LOADING"); return; }
    char buf[80]; buf[0]=0;
    if(!dn_input_dialog("Make directory", "Name or path:", buf, (int)sizeof(buf))) return;
    { int l=slen(buf); while(l>0&&buf[l-1]==' ') buf[--l]=0; }
    if(buf[0]==0) return;
    char np[220];
    if(buf[1]==':'){ int p=0; for(int i=0;buf[i]&&p<219;i++) np[p++]=buf[i]; np[p]=0; }          /* "0:/..." given */
    else if(buf[0]=='/'){ int p=0; np[p++]='0'; np[p++]=':'; for(int i=0;buf[i]&&p<219;i++) np[p++]=buf[i]; np[p]=0; }  /* "/from-root" */
    else path_of(np, buf);                                                                       /* bare name -> under current folder */
    sdop_freeze_begin();
    mkdir_path(np);
    sdop_freeze_end();
    sd_scan();
    { const char* bn=base_name(np); for(int i=0;i<fcount;i++) if(fisdir[i]&&cicmp(flist[i],bn)==0){ bcursor=i; break; } }  /* cursor onto the new dir */
    if(bcursor<btop) btop=bcursor; if(bcursor>=btop+BROWS) btop=bcursor-BROWS+1; if(btop<0) btop=0;
    render_browser();
    dn_status_msg("CREATED");
}
/* ---- DN help window (replaces the legacy 1bpp help screen). Any key / Esc closes. ---- */
static void dn_help(void){
    int W=56, H=20, left=(DN_COLS-W)/2, top=(DN_ROWS-H)/2;   /* wider than the box-save buffer -> repaint browser on close */
    dn_win_draw(left,top,W,H," ZX-BulboNavigator - Keys ");
    static const char* const HL[][2] = {
        {"Up/Down","Move the cursor"},
        {"PgUp/PgDn","Scroll a page"},
        {"Enter","Open folder / load program / play music"},
        {"BkSp","Stop playback / stop tape load"},
        {"Space/Ins","Tag file/folder (group select) + down"},
        {"F2","Cycle music play mode"},
        {"F3","Sort mode   (Alt+F3 = reverse)"},
        {"F5","Copy file/folder"},
        {"F6","Rename or move"},
        {"F7","Make directory"},
        {"F8","Delete"},
        {"F9","Open the menu bar"},
        {"F12","Hide / show the navigator"},
        {"+ / -","Volume up / down  (numpad)"},
        {"F10","Pause the machine"},
        {"F11","Hard-reset the machine"},
        {"Esc","Back / close"},
    };
    int n=(int)(sizeof(HL)/sizeof(HL[0])), y=top+2, x=left+3;
    for(int i=0;i<n;i++){ dn_puts(x,y+i,HL[i][0],DNK_HOTKEY,DNK_DLG_BG); dn_puts(x+10,y+i,HL[i][1],DNK_DLG_FG,DNK_DLG_BG); }
    { char v[40]; version_str(v); dn_puts(left+W-slen(v)-3,top+H-1,v,DNK_DLG_FRAME,DNK_DLG_BG); }   /* firmware version in the bottom border */
    { static const char* const kb[1][2]={{"Esc","Close"}}; dn_keybar(kb,1); }
    (void)get_keysym_blocking();   /* any key closes */
    render_browser();              /* repaint the browser over the help window (wider than the box-save buffer) */
}

static void browser_up_one_dir(void){
    if (is_root()) return;
    char came_from[NAMELEN+1]; came_from[0]=0;
    int n=slen(curpath), cut=-1;
    for(int i=0;i<n;i++) if(curpath[i]=='/') cut=i;
    { int j=0; for(int i=cut+1; i<n && j<NAMELEN; i++) came_from[j++]=curpath[i]; came_from[j]=0; }
    if(cut<=2) curpath[3]=0;
    else       curpath[cut]=0;
    sd_scan();
    sort_entries();
    remap_playing_idx();
    bcursor = 0;
    if (came_from[0]) {
        for(int i=0; i<fcount; i++) {
            if (fisdir[i] && cicmp(flist[i], came_from) == 0) {
                bcursor = i;
                break;
            }
        }
    }
    btop = bcursor - BROWS/2;
    if (btop > fcount - BROWS) btop = fcount - BROWS;
    if (btop < 0) btop = 0;
    render_browser_dn();
}

static void pause_toggle(void);   /* fwd (defined in the pause section below) */
/* Shared transport actions: the SAME behaviour whether invoked from a hotkey (Space/BkSp) or from
   the Play menu - halt coordination, banner and browser play-markers always stay in sync. */
static void do_player_stop(void){
    if(g_tape_on){ tape_stop(); update_banner();
                   if(browser_on) dn_draw_status(); return; }   /* Backspace semantics: abort a tape load; status row back to Files/Sort */
    if(player_active()){
        player_stop(); playing_idx = -1; g_music_path[0] = 0;
        apply_music_halt(); update_banner();
        if(browser_on) dn_draw_list();                          /* clear all play-path markers + reset the status line */
    }
}
static void do_player_pause(void){
    if(g_tape_on){ pause_toggle(); return; }                    /* tape: freeze the machine (tape pauses in lock-step) */
    if(player_active()){
        player_pause_toggle(); apply_music_halt(); update_banner();
        if(browser_on){                                          /* repaint the play-path rows + the status glyph */
            for(int r=0;r<BROWS;r++){ int i=btop+r; if(i<fcount && on_play_path(i)) dn_draw_file_row(i); }
            dn_draw_status();
        }
    }
}
static void choose_play_mode(void){
    int W=46, H=11, left=(DN_COLS-W)/2, top=(DN_ROWS-H)/2, brow=top+8;
    int choice=opt_playmode;        /* choice: the currently focused row (where the cursor bar is) */
    int temp_mode=opt_playmode;     /* temp_mode: the currently checked radio button (where the (*) is) */
    int focus=0, result=-1;         /* focus: 0=RadioGroup, 1=OK, 2=Cancel */
    box_backup(&g_bs[0], left, top, W+2, H+1);
    dn_win_draw(left,top,W,H,"Play Mode");
    { static const char* const kb[3][2]={{"Enter","OK"},{"Tab","Next"},{"Esc","Cancel"}}; dn_keybar(kb,3); }
    static const char* const modes[5][2] = {
        {"FOLDER",      "Play folder once"},
        {"FILE",        "Play track once"},
        {"FOLDER LOOP", "Repeat folder"},
        {"FILE LOOP",   "Repeat track"},
        {"RANDOM",      "Random shuffle"}
    };
    int old_choice = -1, old_temp = -1, old_focus = -1;
    while(result<0){
        if(choice != old_choice || temp_mode != old_temp || focus != old_focus){
            old_choice = choice; old_temp = temp_mode; old_focus = focus;
            for(int i=0;i<5;i++){
                int ry = top+2+i;
                int is_cur = (focus == 0 && i == choice);
                uint32_t fg = is_cur ? FG(0) : DNK_DLG_FG;
                /* Dialog cursor must be 100% opaque -> use FG(3) (solid Cyan) instead of BG(3) */
                uint32_t bg = is_cur ? FG(3) : DNK_DLG_BG;
                dn_fill(left+1, ry, W-2, 1, bg);
                const char* radio = (i == temp_mode) ? "(*)" : "( )";
                dn_puts(left+3, ry, radio, fg, bg);
                dn_puts(left+8, ry, modes[i][0], fg, bg);
                dn_puts(left+21, ry, modes[i][1], is_cur ? fg : FG(8), bg);
            }
            dn_fill(left+1, brow, W-2, 2, DNK_DLG_BG);
            int bw = 10, gap = 4, total = (bw+1) + gap + (bw+1);
            int bx = left + (W - total)/2;
            dn_button(bx,              brow, "OK",     focus==1 || (focus==0), bw);
            dn_button(bx + bw+1 + gap, brow, "Cancel", focus==2, bw);
        }
        KBD_HB=1; player_pump(); pump_autoadvance();
        uint32_t d=KBD_DATA;
        if(d&0x100u){
            bg_pump();
            continue;
        }
        uint32_t code=d&0xFFu; int rel=(d&0x200u)!=0; int rising=kbd_note(code,rel);
        if(code==0xF0u||code==0xE0u || rel) continue;
        if(code==SC_ESC){ if(rising) result=0; continue; }
        if(code==SC_ENTER){
            if(rising){
                if(focus == 2) result=0;
                else { opt_playmode=temp_mode; result=1; }
            }
            continue;
        }
        if(code==SC_SPACE){
            if(rising){
                if(focus == 0){
                    temp_mode = choice;
                } else if(focus == 1) {
                    opt_playmode = temp_mode; result = 1;
                } else if(focus == 2) {
                    result = 0;
                }
            }
            continue;
        }
        if(code==0x0Du){   /* Tab key: move focus */
            if(rising) focus = (focus+1)%3;
            continue;
        }
        if(code==SC_UP){
            if(rising){
                if(focus == 0){ choice--; if(choice<0) choice=4; }
                else { focus=0; }
            }
            continue;
        }
        if(code==SC_DOWN){
            if(rising){
                if(focus == 0){ choice++; if(choice>4) choice=0; }
                else { focus=0; }
            }
            continue;
        }
        if(code==SC_LEFT){
            if(rising){
                if(focus == 2) focus=1;
                else if(focus == 1) focus=2;
            }
            continue;
        }
        if(code==SC_RIGHT){
            if(rising){
                if(focus == 1) focus=2;
                else if(focus == 2) focus=1;
            }
            continue;
        }
    }
    box_restore(&g_bs[0]);
    dn_keybar_browser();
    if(result==1){
        g_music_last_pct=0xFFFFFFFFu; g_music_last_sec=0xFFFFFFFFu;
        dn_status_msg(CH_PLAY[opt_playmode]);
    }
}
static void app_dispatch(int cmd){
    switch(cmd){
        case cmFileLoad:
        case cmPlayStart:
            browser_enter();
            break;
        case cmFileUp:
            browser_up_one_dir();
            break;
        case cmFileRename:
            rename_selected();
            break;
        case cmFileCopy:
            copy_selected();
            break;
        case cmFileDelete:
            delete_selected();
            break;
        case cmFileMkdir:
            mkdir_selected();
            break;
        case cmFileRev:                                          /* Reverse: Alt+F3 parity */
            if(sd_mounted && fcount){
                g_sort_desc = !g_sort_desc;
                sort_entries(); remap_playing_idx();
                bcursor=0; btop=0; sel_scroll=0; last_scroll=0; scroll_started=0;
                if(browser_on) dn_draw_list();
            }
            break;
        case cmOptSave:
            act_save();
            break;
        case cmOptEject:
            act_eject();
            break;
        case cmPlayStop:
            do_player_stop();
            break;
        case cmPlayPause:
            do_player_pause();
            break;
        case cmPlayMode:
            choose_play_mode();
            break;
        case cmTapeStop:
            tape_stop();
            break;
        case cmTapePlay:
            if (bcursor >= 0 && bcursor < fcount && !fisdir[bcursor]) {
                const char* e = fext(flist[bcursor]);
                if (cicmp(e, "tap") == 0 || cicmp(e, "tzx") == 0) {
                    tape_start();
                }
            }
            break;
        case cmHelpAbout:
        case cmHelpKeys:
            dn_help();
            break;
        default:
            break;
    }
}

/* Open a nested submenu box to the right of the parent's cursor row (DN geometry). */
static void menu_open_sub(MenuState* st, int* lvl){
    MenuState* p = &st[0];
    MenuState* c = &st[1];
    c->menu = (Menu*)st[0].menu->items[p->cur].sub;
    c->cur = c->menu->deflt;
    menubox_size(c->menu, &c->W, &c->H);
    c->left = p->left + p->W - 2;
    c->top  = p->top + 1 + p->cur;                 /* aligned with the parent item row */
    if (c->left + c->W > DN_COLS - 2) c->left = DN_COLS - 2 - c->W;
    if (c->top + c->H > DN_ROWS - 1)  c->top  = DN_ROWS - 1 - c->H;
    if (c->top < 1) c->top = 1;
    box_backup(&g_bs[1], c->left, c->top, c->W + 2, c->H + 1);
    menubox_render(c->menu, c->cur, c->left, c->top, c->W, c->H);
    *lvl = 1;
}
/* A value-item changed: if it re-sorted the list (SORT), show the new order live UNDER the open
   boxes - invalidate the stale snapshots, redraw the list, re-capture + re-render every level.
   Otherwise repaint just the changed row. */
static void menu_value_changed(MenuState* st, int lvl){
    if (g_list_dirty || g_alpha_dirty) {
        int full = g_alpha_dirty;                /* alpha touches EVERY background cell -> full browser repaint */
        g_list_dirty = 0; g_alpha_dirty = 0;
        g_bs[0].valid = 0; g_bs[1].valid = 0;
        if (full) render_browser(); else dn_draw_list();
        for (int L = 0; L <= lvl; L++) {
            box_backup(&g_bs[L], st[L].left, st[L].top, st[L].W + 2, st[L].H + 1);
            menubox_render(st[L].menu, st[L].cur, st[L].left, st[L].top, st[L].W, st[L].H);
        }
    } else {
        MenuState* s = &st[lvl];
        menubox_draw_row(s->menu, s->cur, s->left, s->top, s->W, s->cur);
    }
}

static int menubar_exec(int start){
    int bar = start < 0 ? 0 : start;
    int done = 0;
    int ret = 0;

    g_menu_open = 1;                       /* suppress marquee/list redraws beneath the dropdowns */

    while (!done) {
        MenuState st[2];                   /* level 0 = bar dropdown, level 1 = nested submenu */
        int lvl = 0;
        st[0].menu = g_bar[bar].menu;
        st[0].cur = st[0].menu->deflt;
        st[0].bar = bar;
        menubar_draw(bar);                 /* highlight FIRST: it also lays out g_bar_x0[] */
        menubox_size(st[0].menu, &st[0].W, &st[0].H);
        st[0].left = g_bar_x0[bar] - 1;
        st[0].top = 1;
        if (st[0].left + st[0].W > DN_COLS - 2) st[0].left = DN_COLS - 2 - st[0].W;   /* keep box + shadow on-canvas */
        if (st[0].left < 0) st[0].left = 0;
        box_backup(&g_bs[0], st[0].left, st[0].top, st[0].W + 2, st[0].H + 1);
        menubox_render(st[0].menu, st[0].cur, st[0].left, st[0].top, st[0].W, st[0].H);

        int in_menu = 1;
        while (in_menu) {
            MenuState* s = &st[lvl];
            int k = get_keysym_blocking();
            switch (k) {
                case K_LEFT:
                    if (lvl > 0) {
                        const MenuItem* it = &s->menu->items[s->cur];
                        if (it->name && it->value && !it->disabled) {   /* submenu: Left steps the value BACK (RANGE down / CHOICE prev) */
                            menuitem_value_cycle(it, -1);
                            menu_value_changed(st, lvl);
                        } else { box_restore(&g_bs[1]); lvl = 0; }      /* non-value row: back to the parent */
                    } else {
                        bar = (bar - 1 + g_bar_n) % g_bar_n;            /* top level: previous bar menu */
                        in_menu = 0;
                    }
                    break;
                case K_RIGHT:
                    if (lvl > 0) {
                        const MenuItem* it = &s->menu->items[s->cur];
                        if (it->name && it->value && !it->disabled) {   /* submenu: Right steps the value FORWARD */
                            menuitem_value_cycle(it, +1);
                            menu_value_changed(st, lvl);
                        }
                    } else {
                        const MenuItem* it = &s->menu->items[s->cur];
                        if (it->name && it->sub && !it->disabled) menu_open_sub(st, &lvl);   /* DN: Right opens the submenu */
                        else { bar = (bar + 1) % g_bar_n; in_menu = 0; }                     /* else: next bar menu */
                    }
                    break;
                case K_UP:
                case K_DOWN: {
                    int old_cur = s->cur;
                    int next = s->cur;
                    do {
                        next = (next + (k == K_DOWN ? 1 : s->menu->count - 1)) % s->menu->count;
                    } while (!s->menu->items[next].name && next != s->cur);
                    s->cur = next;
                    s->menu->deflt = next;
                    menubox_draw_row(s->menu, s->cur, s->left, s->top, s->W, old_cur);
                    menubox_draw_row(s->menu, s->cur, s->left, s->top, s->W, s->cur);
                    break;
                }
                case K_ENTER: {
                    const MenuItem* it = &s->menu->items[s->cur];
                    if (it->disabled || !it->name) break;
                    if (it->sub && lvl == 0) { menu_open_sub(st, &lvl); break; }   /* Enter opens the nested dropdown */
                    if (it->value) {                        /* inline value-item: cycle + repaint (live list refresh if it re-sorts) */
                        menuitem_value_cycle(it, +1);
                        menu_value_changed(st, lvl);
                        break;
                    }
                    ret = it->cmd;
                    done = 1;
                    in_menu = 0;
                    break;
                }
                case K_ESC:                                 /* DN semantics: one level up; at the top - close to the browser */
                    if (lvl > 0) { box_restore(&g_bs[1]); lvl = 0; }
                    else { ret = 0; done = 1; in_menu = 0; }
                    break;
                case K_F9:                                  /* repeated F9 closes the whole menu bar */
                    ret = 0;
                    done = 1;
                    in_menu = 0;
                    break;
                default: {
                    int uk = (k >= 'a' && k <= 'z') ? k - 32 : k;   /* hotkeys are case-insensitive */
                    if (uk >= 'A' && uk <= 'Z') {           /* ~X~ item hotkey (current level): jump the cursor + activate */
                        for (int i = 0; i < s->menu->count; i++) {
                            const MenuItem* it = &s->menu->items[i];
                            if (!it->name || it->disabled) continue;
                            char h = 0;
                            for (int j = 0; it->name[j]; j++) if (it->name[j] == '~') { h = it->name[j+1]; break; }
                            if (h >= 'a' && h <= 'z') h -= 32;
                            if (h != (char)uk) continue;
                            int old_cur = s->cur;
                            s->cur = i; s->menu->deflt = i;
                            menubox_draw_row(s->menu, s->cur, s->left, s->top, s->W, old_cur);
                            menubox_draw_row(s->menu, s->cur, s->left, s->top, s->W, s->cur);
                            if (it->sub && lvl == 0) menu_open_sub(st, &lvl);
                            else if (it->value) { menuitem_value_cycle(it, +1); menu_value_changed(st, lvl); }
                            else if (it->cmd) { ret = it->cmd; done = 1; in_menu = 0; }
                            break;
                        }
                    }
                    break;
                }
            }
        }
        box_restore(&g_bs[1]);             /* LIFO: erase the submenu (if open), then the bar dropdown */
        box_restore(&g_bs[0]);
    }
    g_list_dirty = 0; g_alpha_dirty = 0;
    g_menu_open = 0;
    if (browser_on) render_browser();      /* full repaint on menu close: guarantees no dropdown/shadow residue on the frame */
    /* No latch sync / flush: the shared key-down table (g_kd) tracks held state across both consumers,
       so a key still held on exit is de-duplicated by its own rising-edge check in the main loop. */
    return ret;
}

static void run_menu_system(void) {
    if (!osd_on || !browser_on) {
        open_browser();                 /* the menu needs the live browser backdrop */
    }
    int cmd = menubar_exec(3); /* owner: F9 lands on the OPEN Options dropdown (bar slot 3) */

    if (cmd > 0) app_dispatch(cmd);     /* dispatch onto the VISIBLE browser (never onto a hidden canvas) */
    /* cancelled (Esc / repeated F9): the NAVIGATOR STAYS on screen (owner 2026-07-06) -
       only the menu goes away; Esc from the browser is what returns to the machine. */
}

/* (the legacy modal Options dialog is gone: settings live in the Options > Settings nested dropdown) */
static void open_help(void){ browser_on=0; opt_on=0; show_help(); OSD_CTRL=(OSD_CTRL|1u)&~2u; osd_on=1; osd_view=2; }
static void open_view(int v){ if(v==1) open_osd(); else if(v==2) open_help(); else if(v==3) open_browser(); }
static void toggle_view(int v){ if(osd_view==v) close_osd(); else open_view(v); }

/* ---- Step 13.1: full pause -------------------------------------------------------------------
   Pause asserts HALT (CONTROL bit0). HALT gates pe3M5_core, which freezes the Z80 AND the AY /
   beeper clock-enables, so the whole machine stops mid-sample; the bitstream forces the PCM to
   silence while halted (bulbulator_zx_ddr_top.v). Resume deasserts HALT: the frozen AY continues
   bit-exact - registers, envelope phase and the noise LFSR all survive the freeze - so there is no
   save/restore and no resume click. Modal: while paused only Pause (or the F10 fallback) is live. */
static int paused = 0, pst = 0;   /* paused: banner flag; pst: E1-run pause-key matcher state */
static int halt_src = 0;     /* bitmask: bit0=manual Pause, bit1=auto pause-on-music. HALT held while nonzero. */
static void apply_halt(void){            /* single owner of IJ_CTRL bit0 (HALT) */
    if(halt_src){ IJ_CTRL = 1;
        for(volatile uint32_t t=0; t<8000000u && !(IJ_STAT & 1u); t++){} }   /* assert + wait HALT_ACK (bounded: no ACK must not wedge the ARM) */
    else IJ_CTRL = 0;                                       /* release only when no source remains */
}
static void apply_music_halt(void){      /* music start/stop or PAUSE-MUS option change */
    int want = opt_pausemusic && player_active() && !player_paused() && g_app_path[0];
    if(want) halt_src |= 2; else halt_src &= ~2;
    apply_halt();
}
static void music_halt_changed(void){ apply_music_halt(); update_banner(); }   /* F9 onchange */
/* Blocking SD ops (config SAVE, directory scans) stall the main loop long enough to underrun the
   512-deep tape FIFO and corrupt a running load. The tape replays in LOCK-STEP with the machine
   (pe3M5_core is halt-gated), so freezing the machine for the op's duration is bit-exact: the tape
   pauses mid-pulse and resumes seamlessly - same mechanism as the user's Space-pause during a load. */
static void sdop_freeze_begin(void){ if(g_tape_on && !(halt_src & 4u)){ halt_src |= 4u; apply_halt(); } }
static void sdop_freeze_end(void){ if(halt_src & 4u){ halt_src &= ~4u; apply_halt(); } }
/* Non-blocking pause (user request 2026-07-02): HALT the machine and show ONLY a pause sign on the
   independent banner plane - the player window is NOT summoned (F8 opens it explicitly). */
static void pause_toggle(void){
    if(halt_src){ paused = 0; halt_src = 0; apply_halt(); }    /* resume the machine (drop all halts) */
    else        { paused = 1; halt_src = 1; apply_halt(); }    /* pause the machine (assert HALT + HALT_ACK) */
    update_banner();                                           /* refreshes the banner pause sign too */
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
/* Compact PAUSE sign on the independent banner plane - shown whenever the machine is user-visibly
   paused: manual Pause (halt_src bit0) OR the PAUSE-MUS auto-halt when a track starts (bit1). NOT the
   transient SD-op tape freeze (bit2). (v0.14.15: bit1 added - music-pause now raises the plashka.) */
static void render_pause_sign(void){
    if(halt_src & 3u){
        ban_select(); ban_clear();
        draw_glyph(2, 0, pause_glyph);
        draw_text_scrolled(12, 0, 1, "PAUSE", 0);
        osd_select();
        ban_blit();
        BAN_CTRL = 1;
    } else BAN_CTRL = 0;
}
static const char* machine_name(void){ switch(MACHINE_ID & 0xFFFFu){ default: return "ZX SPECTRUM 128K"; } }
static const char* machine_type(void){ switch(MACHINE_ID & 0xFFFFu){ default: return "ZX 128K"; } }
static void update_banner(void){         /* on state change: refresh ALL dynamic player-window regions */
    ban_scroll = 0; ban_last_scroll = 0; ban_scroll_started = 0;
    render_pause_sign();                   /* banner plane = machine-pause sign only (track/app info live in the DDR windows) */
    if(browser_on && !g_menu_open) draw_topstatus();   /* refresh the top-right machine run/pause glyph */
}
static void banner_scroll_tick(void){}

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
    osd_blit(); OSD_CTRL|=1u;
    /* dismiss: any key make, or ~8 s timeout (keep petting the deadman so the fabric stays alive) */
    XTime t0; XTime_GetTime(&t0);
    for(;;){
        KBD_HB=1;
        uint32_t d=KBD_DATA;
        if(!(d&0x100u) && !(d&0x200u)) break;            /* FIFO non-empty + not a release = a make */
        XTime now; XTime_GetTime(&now);
        if((now-t0) > (XTime)8*COUNTS_PER_SECOND) break;
    }
    osd_clear(); osd_blit(); OSD_CTRL&=~1u;
}

/* ---- Step 14.3b: 1 ms audio-consumer interrupt (SCU private timer -> player_isr_tick) ----
   The consumer feeds the 256-deep (5.3 ms) fabric audio FIFO from the player's big PCM ring even
   while the main loop is blocked in SD scans / OSD redraws - that is what makes music click-free.
   The ISR never touches SD/FatFs (polled xsdps is not reentrant); it only moves RAM -> FIFO. */
static XScuGic   g_gic;
static XScuTimer g_stmr;
void tape_isr_feed(void);   /* defined in the tape section: pulse ring -> hardware tape FIFO */
static void audio_timer_isr(void* ref){
    (void)ref;
    XScuTimer_ClearInterruptStatus(&g_stmr);
    player_isr_tick();      /* music: PCM ring -> audio FIFO */
    tape_isr_feed();        /* tape: pulse ring -> tape FIFO (ultrastable delivery) */
}
static int audio_irq_init(void){
    XScuGic_Config* gc = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if(!gc || XScuGic_CfgInitialize(&g_gic, gc, gc->CpuBaseAddress) != XST_SUCCESS) return 0;
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, &g_gic);
    XScuTimer_Config* tc = XScuTimer_LookupConfig(XPAR_XSCUTIMER_0_DEVICE_ID);
    if(!tc || XScuTimer_CfgInitialize(&g_stmr, tc, tc->BaseAddr) != XST_SUCCESS) return 0;
    if(XScuGic_Connect(&g_gic, XPAR_SCUTIMER_INTR, (Xil_InterruptHandler)audio_timer_isr, 0) != XST_SUCCESS) return 0;
    XScuGic_Enable(&g_gic, XPAR_SCUTIMER_INTR);
    XScuTimer_LoadTimer(&g_stmr, XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ/2u/1000u);   /* private timer @ CPU/2 -> 1 ms */
    XScuTimer_EnableAutoReload(&g_stmr);
    XScuTimer_EnableInterrupt(&g_stmr);
    XScuTimer_Start(&g_stmr);
    Xil_ExceptionEnable();
    return 1;
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
    /* Step 14 DDR true-colour OSD bring-up: draw the Winamp-classic canvas + enable the layer. */
    OSD_DDR_BASE = OSDC_ADDR;
    /* Winamp window removed (DN-only build): no boot draw - the DN browser fills the colour canvas. */
    apply_pos();                      /* navigator (DN canvas) position from the loaded Window X/Y */
    OSD_CTRL = 0;                             /* both OSD layers off at boot: player window hidden by default (F8 / machine pause surfaces it) */
    BAN_POS = (640u<<16) | 512u;      /* banner bottom-centre strip, clear of the OSD */
    player_audio_irq(audio_irq_init());   /* Step 14.3b: 1 ms audio-consumer ISR (0 = polled fallback) */
    cache_selftest();                 /* opt-in (0:/CACHETEST.BIN): verify D-cache+SD reads are clean */

    /* Flush scancodes buffered before this controller came up (keys pressed during PL config /
       ARM reload), so the OSD always starts closed regardless of pre-boot key activity. */
    while(!(KBD_DATA & 0x100u)) { /* pop+discard until empty */ }

    /* Force clean state for tuner and player after reflash (prevents stuck tuner or auto-play) */
    OSD_CTRL &= ~2u;
    player_stop();
    playing_idx = -1;
    g_music_path[0] = 0;
    apply_music_halt();

    /* Step 14.4: real DN-style file browser on the colour canvas at boot (640x400 @ 80x25, CP866). */
    apply_pos();                                 /* navigator position from Window X/Y (default 320,160 = centred) */
    browser_on = 1; osd_on = 1; opt_on = 0; osd_view = 3;
    sd_scan();                                   /* mount + read 0:/ into flist[] (shows NO CARD if none) */
    render_browser();                            /* draw the DN browser to the canvas */
    OSD_CTRL = 2u;                               /* bit1 = colour OSD (DN) on; bit0 (1bpp) off */

    /* Drain + heartbeat loop. Keep it non-blocking: exactly ONE KBD_HB write per pass (the fabric
       deadman edge-detector would miss a tight burst of kicks) and no blocking I/O on this path. */
    /* All keys route through the shared key-down table (kbd_note): single-shot keys fire on the
       rising edge, nav keys repeat on every make; the same table backs the modal get_keysym_blocking. */
    for(;;){
        KBD_HB = 1;                   /* pet the deadman every iteration (single write per pass) */
        if(g_autotrig){ g_autotrig=0; autoload_tape((const char*)g_autodir, (const char*)g_autoname); }  /* JTAG self-test (pokeable path) */
        player_pump();                /* feed the audio FIFO when a music file is playing (no-op otherwise) */
        if(player_active() && !g_tape_on && browser_on){    /* music: DN status line (name / M:SS/M:SS / progress bar), updated on change */
            unsigned pct = player_progress(); if(pct>100u) pct=100u;
            unsigned el = player_elapsed_s();
            if(pct != g_music_last_pct || el != g_music_last_sec){ g_music_last_pct = pct; g_music_last_sec = el; dn_draw_status(); }
        }
        tape_pump();                  /* feed the tape pulse FIFO while a .tap is loading (no-op otherwise) */
        if(g_tape_on && g_tape_fmt == 3) tape_pump(); /* extra pump for heavier MP3 decode path */
        if(player_take_ended()) player_autoadvance();   /* track finished -> next per play mode (cursor follows) */
        /* During tape load (especially MP3), reduce drawing load so the pump + decode can keep the pulse ring fed.
           WAV is fast direct reads; MP3 decode + SD is heavier. */
        if(!g_tape_on){
            if(browser_on){ browser_scroll_tick(); status_scroll_tick(); }
            banner_scroll_tick();
        }

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
        int release = (d & 0x200u) != 0;           /* bit9: this code is a release */

        /* Pause key: PS/2 set-2 sends its make as the byte run E1 14 77 (no auto-repeat). Match on
           code bytes - robust to the make/break flag; the break burst E1 F0 14 F0 77 self-cancels. */
        if(pst==1){ if(code==0x14u){ pst=2; continue; } pst=0; }
        else if(pst==2){ pst=0; if(code==0x77u){ pause_toggle(); continue; } }
        if(code==0xE1u){ pst=1; continue; }

        int rising = kbd_note(code, release);      /* THE key-state update (shared with get_keysym_blocking) */
        if(code==0xF0u || code==0xE0u) continue;   /* prefix frames */
        kb_alt = g_kd[0x11];                        /* Alt held (for Alt+F3) - from the one table */

        /* single-shot action keys (rising edge only -> immune to typematic + to a modal eating the break) */
        if(code==SC_F10){ if(rising) pause_toggle(); continue; }                       /* Pause fallback */
        if(code==SC_F8){ if(rising && browser_on) delete_selected(); continue; }       /* F8: delete (DN-style) */
        if(code==SC_F6){ if(rising && browser_on) rename_selected(); continue; }       /* F6: rename / move */
        if(code==SC_F7){ if(rising && browser_on) mkdir_selected(); continue; }         /* F7: make directory */
        if(code==SC_F11){ if(rising){ g_app_stopped=1; update_banner(); } continue; }  /* hard reset marker */
        if(code==SC_KPPLUS ){ if(!release){ opt_vol+=5; if(opt_vol>100)opt_vol=100; apply_vol(); } continue; }  /* volume up (hold ramps) */
        if(code==SC_KPMINUS){ if(!release){ opt_vol-=5; if(opt_vol<0)  opt_vol=0;   apply_vol(); } continue; }  /* volume down */

        if(release) continue;                       /* below: makes only */
        switch(code){
            case SC_F1:    if(rising){ if(!browser_on) open_browser(); dn_help(); } break;   /* DN help window */
            case SC_F5:    if(rising && browser_on) copy_selected(); break;  /* F5: copy (navigator open) */
            case SC_F12:   if(rising) toggle_view(3); break;                 /* F12: hide / show the navigator */
            case SC_UP:    if(browser_on) browser_move(-1); break;           /* nav: typematic auto-repeat wanted */
            case SC_DOWN:  if(browser_on) browser_move(+1); break;
            case SC_PGUP:  if(browser_on) browser_move(-BROWS); break;       /* fast page scroll */
            case SC_PGDN:  if(browser_on) browser_move(+BROWS); break;
            case SC_HOME:  if(browser_on) browser_move(-fcount); break;      /* Home: jump to first item */
            case SC_END:   if(browser_on) browser_move(fcount); break;       /* End: jump to last item */
            case SC_ENTER: if(rising && browser_on) browser_enter(); break;  /* single-shot: load/enter */
            case SC_F3:    if(rising && browser_on){
                              if(kb_alt) g_sort_desc = !g_sort_desc;                /* Alt+F3: reverse direction */
                              else { sortmode=(sortmode+1)&3; g_sort_desc=0; }      /* F3: next sort mode, asc */
                              sort_entries(); remap_playing_idx();
                              bcursor=0; btop=0; sel_scroll=0; last_scroll=0; dn_draw_list(); } break;
            case SC_F2:    if(rising && browser_on){ opt_playmode=(opt_playmode+1)%N_PLAYMODES;   /* cycle play mode */
                              dn_status_msg(CH_PLAY[opt_playmode]);
                              g_music_last_pct=0xFFFFFFFFu; g_music_last_sec=0xFFFFFFFFu; } break;
            case SC_F9:    if(rising) run_menu_system(); break;              /* DN menu bar (single-shot) */
            case SC_SPACE: if(rising && osd_on) do_player_pause(); break;        /* Space: pause/resume transport */
            case SC_INS:   if(rising && browser_on && fcount){                   /* DN: Insert tag current entry + move down */
                                 if(!(flist[bcursor][0]=='.'&&flist[bcursor][1]=='.'&&flist[bcursor][2]==0)){
                                     fsel[bcursor] = !fsel[bcursor];
                                     dn_draw_file_row(bcursor);
                                 }
                                 browser_move(+1);
                             } break;
            case SC_BACKSPACE: if(rising && osd_on) do_player_stop(); break;   /* BkSp: single function = stop playback / stop tape load (up-dir is via "..") */
            case SC_ESC:   if(rising){                                       /* single-shot */
                                 if(osd_on) close_osd();                      /* browser/help -> machine */
                             } break;
            default: break;           /* every other key belongs to the Z80 */
        }
    }
}
