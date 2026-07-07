// mp3dec.h - BulbuLator shared MP3 source (Step 14.3).
// One minimp3 (public-domain) instance behind a simple "next sample" API. Feeds BOTH the music
// player (player.c: decode -> resample -> HDMI FIFO) AND the cassette station (loader_main.c: decode
// -> edge-detect -> tape PULSE FIFO), which are mutually exclusive, so a single decoder is enough.
#ifndef MP3DEC_H
#define MP3DEC_H
#include <stdint.h>

int      mp3_open(const char* path);          /* open + probe the first frame (sr/ch/bitrate); 1 on success */
int      mp3_read(int16_t* l, int16_t* r);    /* next SOURCE-rate stereo sample (mono is duplicated); 0 at EOF */
void     mp3_refill(void);                     /* top up the SD ring - call once per pump pass */
void     mp3_close(void);
int      mp3_is_open(void);
uint32_t mp3_sr(void);                         /* source sample rate (Hz) */
int      mp3_ch(void);                         /* source channels (1/2) */
uint32_t mp3_bitrate(void);                    /* stream bitrate (kbps), frozen to the first frame */
int      mp3_is_vbr(void);                     /* 1 = variable bitrate -> show "VBR" instead of a number */
unsigned mp3_progress(void);                   /* 0..100 by bytes consumed */
unsigned mp3_total_s(void);                    /* estimated duration (CBR: bytes*8/bitrate) */
unsigned mp3_elapsed_s(void);
#endif
