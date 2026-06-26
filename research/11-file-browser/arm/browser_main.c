#include <stdint.h>
#include "xil_cache.h"   /* Xil_DCacheDisable */
#include "ff.h"          /* FatFs (xilffs) - BSP provides xsdps + ChaN FatFs */
#include "xtime_l.h"     /* XTime / COUNTS_PER_SECOND - long-name marquee timing */
// browser_main.c - BulbuLator OSD app + F5 SD file browser (Step 11 MVP, read-only).
// Vitis standalone app: the BSP gives xsdps + FatFs; the OSD/keyboard code is the same GP0 MMIO as
// osd.c. F12 = title overlay, F1 = help, F5 = SD browser, Up/Down scroll, Enter enters a folder
// (".." goes up), Esc closes. D-cache OFF (sidesteps the xsdps invalidate-length corruption class).

#define GP0        0x40000000u
#define OSD_CTRL   (*(volatile uint32_t*)(GP0+0x48))
#define OSD_ADDR   (*(volatile uint32_t*)(GP0+0x4C))
#define OSD_DATA   (*(volatile uint32_t*)(GP0+0x50))
#define OSD_OP     (*(volatile uint32_t*)(GP0+0x6C))  /* OSD panel opacity alpha 0..255 */
#define OSD_POS    (*(volatile uint32_t*)(GP0+0x70))  /* OSD panel position {Y0[26:16],X0[10:0]} */
#define KBD_DATA   (*(volatile uint32_t*)(GP0+0x54))  /* [9]=release_flag(1=break) [8]=empty [7:0]=code; read pops */
#define KBD_STATUS (*(volatile uint32_t*)(GP0+0x58))  /* bit0 = FIFO empty */
#define KBD_HB     (*(volatile uint32_t*)(GP0+0x5C))  /* any write = deadman heartbeat */
#define MACHINE_ID (*(volatile uint32_t*)(GP0+0x60))  /* loaded-core identity ([15:0]=code) */
#define OSD_W     256
#define OSD_H     128
#define OSD_WPR   (OSD_W/32)          /* 8 words per row */
#define OSD_WORDS (OSD_WPR*OSD_H)     /* 1024 words (256x128/32) */

/* PS/2 set-2 scancodes for the keys the ARM owns (none of these are in the ZX matrix) */
#define SC_F1   0x05u
#define SC_F5   0x03u
#define SC_F12  0x07u
#define SC_ESC  0x76u
#define SC_UP    0x75u   /* PS/2 set-2: cursor up (E0-prefix stripped by ARM) / numpad 8 */
#define SC_DOWN  0x72u   /* cursor down / numpad 2 */
#define SC_ENTER 0x5Au
#define SC_F3    0x04u   /* PS/2 set-2 F3: cycle the browser sort mode (only while browsing) */
#define SC_F9    0x01u   /* PS/2 set-2 F9: open/close the options (settings) menu */
#define SC_LEFT  0x6Bu   /* cursor left  (E0 prefix stripped by ARM) / numpad 4 */
#define SC_RIGHT 0x74u   /* cursor right (E0 prefix stripped by ARM) / numpad 6 */

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

static int g_inv = 0;   /* 1 = clear pixels instead of set (inverse text on a solid bar) */
static void setpix(int x,int y){
    if(x<0||x>=OSD_W||y<0||y>=OSD_H) return;
    if(g_inv) osdbuf[y*OSD_WPR + (x>>5)] &= ~(1u << (x & 31));
    else      osdbuf[y*OSD_WPR + (x>>5)] |=  (1u << (x & 31));
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
static int slen(const char* s){ int n=0; while(s[n]) n++; return n; }
static const uint8_t folder_glyph[8] = {0x00,0x70,0xFE,0x82,0x82,0x82,0xFE,0x00};  /* 8x8 folder icon */
static const uint8_t lbr_glyph[8]    = {0x00,0xE0,0x80,0x80,0x80,0x80,0xE0,0x00};  /* '[' flush to cell left edge */
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

/* Title screen (shown when the OSD opens with F12): just the name, centred, scale 2. */
/* Firmware build tag shown on the F12 splash (bump per milestone). The PL core VERSION
   (0x4000_0000) is shown live too, so the splash states exactly which firmware + bitstream run. */
#define BULB_FW "v0.11"
static char hexnib(uint32_t v){ return (v<10) ? ('0'+v) : ('A'+v-10); }
static void show_header(void){
    osd_clear();
    draw_text_c(14, 2, "ZX BulbuLator");
    uint32_t cv = *(volatile uint32_t*)(GP0+0x00);     /* PL core VERSION */
    char v[40]; int p=0; const char* fw = BULB_FW;
    while(*fw) v[p++]=*fw++;
    v[p++]=' '; v[p++]='c'; v[p++]='o'; v[p++]='r'; v[p++]='e'; v[p++]=' '; v[p++]='0'; v[p++]='x';
    for(int i=28;i>=0;i-=4) v[p++]=hexnib((cv>>i)&0xF);
    v[p]=0;
    draw_text_c(46, 1, v);
    osd_blit();
}
/* F1 help page: inverse title bar + grouped key map (GLOBAL / FILE BROWSER / ZX KEYS). */
static void show_help(void){
    osd_clear();
    draw_title_c("HELP");
    draw_text(2, 15, 1, "# GLOBAL:");
    draw_text(2, 23, 1, " F5  FILE BROWSER");
    draw_text(2, 31, 1, " F9  OPTIONS");
    draw_text(2, 39, 1, " F12/ESC  CLOSE MENU");
    draw_text(2, 54, 1, "# FILE BROWSER:");
    draw_text(2, 62, 1, " F3  CHANGE SORT");
    draw_text(2, 77, 1, "# ZX KEYS:");
    draw_text(2, 85, 1, " SHIFT CAPS   CTRL SYMBOL");
    draw_text(2, 93, 1, " ALT  CS+SS (EXTEND)");
    draw_text(2,101, 1, " CTRL+ALT+DEL - SOFT RESET");
    draw_text(2,109, 1, " CTRL+ALT+INS - NMI");
    draw_text(2,117, 1, " F11 - HARD RESET (WIPE RAM)");
    osd_blit();
}

static int osd_on = 0, browser_on = 0, opt_on = 0;
static int osd_view = 0;   /* single view state: 0=none 1=header 2=help 3=browser 4=options */
static int mkey     = 0;   /* scancode of the currently-held menu key (edge-detect); 0=none */
static void open_osd(void){ show_header(); OSD_CTRL = 1; osd_on = 1; browser_on = 0; opt_on = 0; osd_view = 1; }
static void close_osd(void){ OSD_CTRL = 0; osd_on = 0; browser_on = 0; opt_on = 0; osd_view = 0; }

/* ---- F5 SD file browser (read-only) with directory navigation, into the 256x128 OSD panel ---- */
#define MAXFILES 256
#define NAMELEN  96                 /* store the full long name (panel shows VISCH; marquee reveals the rest) */
static char  flist[MAXFILES][NAMELEN+1];
static uint8_t fisdir[MAXFILES];
static uint32_t fsz[MAXFILES];          /* file size in bytes (0 for dirs / "..") */
static uint32_t fdt[MAXFILES];          /* (FAT date<<16)|time, for chronological sort */
static int   fcount = 0, bcursor = 0, btop = 0, sd_mounted = 0;
static int   sortmode = 0;              /* 0=NAME 1=DATE 2=SIZE 3=EXT */
static int   opt_scroll     = 1;        /* long-name marquee speed: 0=slow 1=med 2=fast */
static int   opt_foldermark = 0;        /* folder tag style: 0=[brackets] 1=icon 2=trailing-slash */
static int   opt_scrdelay    = 0;        /* marquee START delay: 0=300ms 1=500ms 2=1000ms */
static int   opt_dim         = 80;       /* OSD panel dimming/opacity %% (5%% steps) */
static int   opt_x           = 512;      /* OSD panel left X0 (0..1024, step 8 px) */
static int   opt_y           = 176;      /* OSD panel top  Y0 (0..592, step 8 px) */
static int   scroll_started  = 0;        /* 0 = still in the pre-scroll start delay for this name */
static char  curpath[80] = "0:/";
static FATFS g_fs;
#define VISCH 30                     /* chars visible in the 256px panel from x=12 */
static int   sel_scroll = 0;         /* marquee offset of the selected (long) name */
static XTime last_scroll = 0;

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
    fcount = 0; bcursor = 0; btop = 0;
    if(!sd_mounted){
        if(f_mount(&g_fs, "0:/", 1) != FR_OK){ sd_mounted = 0; return; }
        sd_mounted = 1;
    }
    if(!is_root()){                       /* synthetic ".." to go up */
        flist[0][0]='.'; flist[0][1]='.'; flist[0][2]=0; fisdir[0]=1;
        fsz[0]=0; fdt[0]=0; fcount=1;
    }
    DIR dir; FILINFO fno;
    if(f_opendir(&dir, curpath) != FR_OK) return;
    while(fcount < MAXFILES && f_readdir(&dir, &fno) == FR_OK && fno.fname[0]){
        if(fno.fattrib & (AM_HID|AM_SYS)) continue;
        int n=0; for(; fno.fname[n] && n<NAMELEN; n++) flist[fcount][n]=fno.fname[n];
        flist[fcount][n]=0;
        fisdir[fcount] = (fno.fattrib & AM_DIR) ? 1 : 0;
        fsz[fcount]    = (uint32_t)fno.fsize;
        fdt[fcount]    = ((uint32_t)fno.fdate << 16) | fno.ftime;
        fcount++;
    }
    f_closedir(&dir);
    sort_entries();
}
static const char* sort_label(void){
    switch(sortmode){ case 1: return "DATE"; case 2: return "SIZE"; case 3: return "EXT"; default: return "NAME"; }
}
static void draw_vline(int x,int y0,int y1){ for(int y=y0;y<y1;y++) setpix(x,y); }
#define BROWS 15                                  /* file rows visible in the 256x128 panel */
static void render_browser(void){
    osd_clear();
    if(!sd_mounted){ draw_title_c("SD: NO CARD / NOT FAT"); osd_blit(); return; }
    char t[40]; int p=0; for(int i=0; curpath[i] && p<13; i++) t[p++]=curpath[i];   /* path (left) */
    t[p++]=' '; char cnt[8]; itoa_u(fcount, cnt); for(int i=0; cnt[i]; i++) t[p++]=cnt[i]; t[p]=0;
    const char* sm = sort_label();                          /* "SORT(F3):NAME" -> hints the F3 hotkey */
    char sl[20]; int q=0; const char* pfx="SORT(F3):";
    for(int i=0; pfx[i]; i++) sl[q++]=pfx[i];
    for(int i=0; sm[i]; i++) sl[q++]=sm[i];
    sl[q]=0;
    titlebar(); g_inv=1;                                    /* inverse title bar: path (left) + sort hint (right) */
    draw_text(2,0,1,t);
    draw_text(OSD_W - q*8, 0, 1, sl);
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
static void open_browser(void){ sel_scroll=0; last_scroll=0; scroll_started=0; opt_on=0; sd_scan(); render_browser(); OSD_CTRL=1; osd_on=1; browser_on=1; osd_view=3; }
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
        static const int dly_ms[3] = {300,500,1000};
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
static void browser_enter(void){
    if(fcount==0 || bcursor>=fcount) return;
    if(!fisdir[bcursor]) return;          /* a file: loading is Step 12 (AXI inject) - not wired here */
    if(flist[bcursor][0]=='.' && flist[bcursor][1]=='.' && flist[bcursor][2]==0){  /* ".." -> parent */
        int n=slen(curpath), cut=-1;                          /* canonical path: never a trailing slash */
        for(int i=0;i<n;i++) if(curpath[i]=='/') cut=i;       /* index of the last '/' */
        if(cut<=2) curpath[3]=0;                              /* one level up from depth 1 -> root "0:/" */
        else       curpath[cut]=0;                            /* "0:/a/b" -> "0:/a" */
    } else {                               /* descend into the folder */
        int n=slen(curpath);
        if(slen(curpath)+1+slen(flist[bcursor]) >= 78){ render_browser(); return; }  /* path too long: stay put */
        if(!(n>0 && curpath[n-1]=='/')) curpath[n++]='/';     /* ensure separator */
        for(int i=0; flist[bcursor][i] && n<79; i++) curpath[n++]=flist[bcursor][i];
        curpath[n]=0;
    }
    sd_scan(); render_browser();
}

/* ---- on-SD config: 0:/bulbulator.ini. Read at boot; written ONLY on explicit Save (live edits
   apply immediately but do not touch the card until you pick Save). Extensible: more [sections]/
   keys can be added later; the parser matches keys globally and ignores comments/section lines. ---- */
static FIL  g_cfg;
static char cfgbuf[512];
static void cfg_set(const char* k, const char* v){
    if(!cicmp(k,"sort"))
        sortmode = !cicmp(v,"date")?1 : !cicmp(v,"size")?2 : !cicmp(v,"ext")?3 : 0;
    else if(!cicmp(k,"scroll_speed"))
        opt_scroll = !cicmp(v,"slow")?0 : !cicmp(v,"fast")?2 : 1;
    else if(!cicmp(k,"folder_mark"))
        opt_foldermark = !cicmp(v,"icon")?1 : !cicmp(v,"slash")?2 : 0;
    else if(!cicmp(k,"scroll_delay"))
        opt_scrdelay = !cicmp(v,"500")?1 : !cicmp(v,"1000")?2 : 0;
    else if(!cicmp(k,"dim")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>100)d=100; opt_dim=(d/5)*5; }
    else if(!cicmp(k,"osd_x")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>1024)d=1024; opt_x=(d/8)*8; }
    else if(!cicmp(k,"osd_y")){ int d=0; for(const char*p=v;*p>='0'&&*p<='9';p++) d=d*10+(*p-'0'); if(d<0)d=0; if(d>592)d=592; opt_y=(d/8)*8; }
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
    const char* dv = opt_scrdelay==1?"500":opt_scrdelay==2?"1000":"300";
    char o[256]; int p=0;
    p=appstr(o,p,"# BulbuLator config\r\n[browser]\r\n");
    p=appstr(o,p,"sort=");         p=appstr(o,p,sv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"scroll_speed="); p=appstr(o,p,cv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"folder_mark=");  p=appstr(o,p,fv); o[p++]='\r'; o[p++]='\n';
    p=appstr(o,p,"scroll_delay="); p=appstr(o,p,dv); o[p++]='\r'; o[p++]='\n';
    char dimb[8]; itoa_u(opt_dim, dimb);
    p=appstr(o,p,"dim=");          p=appstr(o,p,dimb); o[p++]='\r'; o[p++]='\n';
    char xb[8]; itoa_u(opt_x, xb);
    p=appstr(o,p,"osd_x=");        p=appstr(o,p,xb); o[p++]='\r'; o[p++]='\n';
    char yb[8]; itoa_u(opt_y, yb);
    p=appstr(o,p,"osd_y=");        p=appstr(o,p,yb); o[p++]='\r'; o[p++]='\n';
    UINT bw=0;
    if(f_open(&g_cfg,"0:/bulbulator.ini",FA_CREATE_ALWAYS|FA_WRITE)!=FR_OK){ sd_mounted=0; return 0; }
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
static void apply_dim(void){ OSD_OP = ((unsigned)opt_dim*255u)/100u; }  /* %% -> alpha 0..255, live */
static void apply_pos(void){ OSD_POS = ((unsigned)opt_y<<16) | (unsigned)opt_x; }  /* X0/Y0 -> reg, live */
static const char* const CH_SORT[]   = {"NAME","DATE","SIZE","EXT"};
static const char* const CH_SCROLL[] = {"SLOW","MED","FAST"};
static const char* const CH_FOLDER[] = {"BRACKETS","ICON","SLASH"};
static const char* const CH_DELAY[]  = {"300MS","500MS","1S"};
static menu_item opt_items[] = {
    {"SORT",     ITEM_CHOICE, &sortmode,       CH_SORT,   4, 0},
    {"SCROLL",   ITEM_CHOICE, &opt_scroll,     CH_SCROLL, 3, 0},
    {"SCRL DLY", ITEM_CHOICE, &opt_scrdelay,   CH_DELAY,  3, 0},
    {"FOLDERS",  ITEM_CHOICE, &opt_foldermark, CH_FOLDER, 3, 0},
    {"OSD DIM",  ITEM_RANGE,  &opt_dim,        0, 5, 0, apply_dim, 100, "%"},
    {"OSD X",    ITEM_RANGE,  &opt_x,          0, 8, 0, apply_pos, 1024, ""},
    {"OSD Y",    ITEM_RANGE,  &opt_y,          0, 8, 0, apply_pos, 592,  ""},
    {"SAVE",     ITEM_ACTION, 0, 0, 0, act_save},
};
static menu_t opt_menu = { "OPTIONS", opt_items, (int)(sizeof(opt_items)/sizeof(opt_items[0])), 0, 0 };
static void open_options(void){ opt_menu.cursor=0; opt_menu.top=0; menu_render(&opt_menu);
                                OSD_CTRL=1; osd_on=1; browser_on=0; opt_on=1; osd_view=4; }
static void open_help(void){ browser_on=0; opt_on=0; show_help(); OSD_CTRL=1; osd_on=1; osd_view=2; }
static void open_view(int v){ if(v==1) open_osd(); else if(v==2) open_help(); else if(v==3) open_browser(); else if(v==4) open_options(); }
static void toggle_view(int v){ if(osd_view==v) close_osd(); else open_view(v); }

void main(void){
    Xil_DCacheDisable();              /* SD path is ADMA2 DMA; cache-off kills the invalidate-len bug */
    osd_clear(); osd_blit();          /* clean buffer, overlay starts off */
    close_osd();                      /* F12 opens it */
    config_load();                    /* mount SD + read 0:/bulbulator.ini (defaults if absent) */
    apply_dim();                      /* push the loaded dimming level to OSD_OP */
    apply_pos();                      /* push the loaded OSD position to OSD_POS */

    /* Flush scancodes buffered before this controller came up (keys pressed during PL config /
       ARM reload), so the OSD always starts closed regardless of pre-boot key activity. */
    while(!(KBD_DATA & 0x100u)) { /* pop+discard until empty */ }

    /* Drain + heartbeat loop. Keep it non-blocking: exactly ONE KBD_HB write per pass (the fabric
       deadman edge-detector would miss a tight burst of kicks) and no blocking I/O on this path. */
    /* menu keys (F1/F5/F9/F12) are edge-detected + toggled uniformly via mkey + osd_view */
    for(;;){
        KBD_HB = 1;                   /* pet the deadman every iteration (single write per pass) */
        if(browser_on) browser_scroll_tick();   /* marquee the selected long name while browsing */
        uint32_t d = KBD_DATA;        /* atomic pop+read */
        if(d & 0x100u) continue;      /* bit8 = empty */
        uint32_t code = d & 0xFFu;
        if(code==0xF0u || code==0xE0u) continue;   /* break / extended prefix frames */
        int release = (d & 0x200u) != 0;           /* bit9: this code is a release */
        switch(code){
            case SC_F12:  if(release){ if(mkey==SC_F12) mkey=0; } else if(mkey!=SC_F12){ mkey=SC_F12; toggle_view(1); } break; /* header */
            case SC_F1:   if(release){ if(mkey==SC_F1)  mkey=0; } else if(mkey!=SC_F1){  mkey=SC_F1;  toggle_view(2); } break; /* help */
            case SC_F5:   if(release){ if(mkey==SC_F5)  mkey=0; } else if(mkey!=SC_F5){  mkey=SC_F5;  toggle_view(3); } break; /* browser */
            case SC_UP:    if(!release){ if(opt_on) menu_move(&opt_menu,-1); else if(browser_on) browser_move(-1); } break;
            case SC_DOWN:  if(!release){ if(opt_on) menu_move(&opt_menu,+1); else if(browser_on) browser_move(+1); } break;
            case SC_ENTER: if(!release){ if(opt_on) menu_activate(&opt_menu,+1); else if(browser_on) browser_enter(); } break;
            case SC_F3:    if(!release && browser_on){ sortmode=(sortmode+1)&3; sort_entries();
                              bcursor=0; btop=0; sel_scroll=0; last_scroll=0; render_browser(); } break;
            case SC_F9:   if(release){ if(mkey==SC_F9)  mkey=0; } else if(mkey!=SC_F9){  mkey=SC_F9;  toggle_view(4); } break; /* options */
            case SC_LEFT:  if(!release && opt_on) menu_activate(&opt_menu,-1); break;
            case SC_RIGHT: if(!release && opt_on) menu_activate(&opt_menu,+1); break;
            case SC_ESC: if(!release && osd_on) close_osd();  break;   /* Esc also closes the menu */
            default: break;           /* every other key belongs to the Z80 */
        }
    }
}
