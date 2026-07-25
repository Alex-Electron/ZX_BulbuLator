// mp3dec.c - BulbuLator shared MP3 source (Step 14.3), backed by minimp3 (public domain, CC0).
//
// TWO-STAGE buffering so decode never stalls the consumer:
//   SD --f_read--> [compressed ring M_buf] --minimp3--> [decoded PCM ring D_buf] --mp3_read--> consumer
// mp3_refill() does ALL the heavy work (SD read + frame decode) and is meant to be called AFTER the
// consumer has topped up its own FIFO; mp3_read() only pops decoded samples from RAM (no SD, no decode).
// This is what lets a turbo MP3 cassette keep the shallow tape FIFO fed (its earlier inline-decode
// design stalled mid-drain). Music uses the same path.
#include <stdint.h>
#include "ff.h"                 // FatFs
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
#include "mp3dec.h"

/* P2 whole-file RAM preload: pet the fabric keyboard-gate deadman (axi_ctl 0x5C) during the multi-second
   slurp so a slow-card load can't briefly expire it. Same GP0 base / register as loader_main.c. */
#define GP0        0x40000000u
#define KBD_HB     (*(volatile uint32_t*)(GP0+0x5Cu))         // any write = deadman heartbeat

static FIL       M_f; static int M_open = 0, M_fh_open = 0;   // M_fh_open: the FIL is currently open (0 once preloaded)
static mp3dec_t  M_dec;
static uint8_t   M_buf[65536] __attribute__((aligned(32)));   // compressed SD ring (streaming fallback path only)
static UINT      M_valid = 0, M_pos = 0; static int M_eof = 0;
/* P2 WHOLE-FILE PRELOAD buffer: the ENTIRE compressed audio region is slurped here at open so ZERO SD
   reads occur during playback -> removes the card-GC read-stall that starved the producer (the confirmed
   g_underruns=3604). .bss + 32-byte aligned + cacheable = the exact snapbuf DMA idiom (the xsdps driver
   invalidates each aligned chunk, so the CPU decode reads fresh bytes; no manual flush). 32 MB covers a
   5 min @ 320 kbps track (12 MB) with wide margin (~14 min @ 320 kbps); larger files stream (fallback).
   Placement is linker-managed .bss: current footprint ~6 MB, +32 MB -> _end ~38 MB, far below the reserved
   non-cacheable window (0x0F700000) / OSD canvas (0x0F800000) in the 246 MB DDR region -> zero collision. */
#define M_PRE_CAP   (32u*1024u*1024u)
#define M_PRE_CHUNK (256u*1024u)                              // SD read granularity: 256 KB = the proven g_tapbuf read size,
                                                              // multiple of 512 (sector) & 32 (cache line); frequent deadman pets
static uint8_t   M_pre[M_PRE_CAP] __attribute__((aligned(32)));
static uint8_t*  M_src = M_buf;                               // active compressed source: M_buf (stream) or M_pre (preload)
static int       M_preloaded = 0;                             // 1 = whole file in M_pre: M_fill() is a no-op, no SD in playback
static int       M_background_loading = 0;                    // 1 = background preload in progress
extern int       opt_preload;                                 // 0 = fast SD stream, 1 = whole-file preload to DDR
static int16_t   M_frame[MINIMP3_MAX_SAMPLES_PER_FRAME];      // scratch: one decoded frame

#define DCAP 262144                                           // decoded PCM ring (256K int16 = 512 KB): ~5 s mono @48k
static int16_t   D_buf[DCAP];
static int       D_len = 0, D_pos = 0;                        // valid samples + read cursor (interleaved)

static uint32_t  M_sr = 48000; static int M_ch = 1; static int M_kbps = 128;
static uint32_t  M_data_bytes = 0;                            // whole-file size (progress/duration est)
static uint64_t  M_played = 0;                                // frames popped -> elapsed time
static int       M_vbr = 0, M_kbps0 = 0;                      // VBR flag + first frame's bitrate (frozen, stable estimate)
static uint32_t  M_total_frames = 0, M_spf = 1152;            // Xing/VBRI frame count + samples-per-frame (per channel)
static uint64_t  M_dur_samples = 0;                           // exact total samples/channel (from the VBR header)

/* Parse the duration UP FRONT the way mpg123/ffmpeg/foobar do: skip an ID3v2 tag, then find the
   Xing/Info (LAME) or VBRI header in the first frame and read its exact frame count. That is the ONLY
   reliable way to time a VBR file without scanning the whole thing. Falls back to a CBR estimate. */
static void mp3_parse_duration(void){
    M_vbr = 0; M_kbps0 = 0; M_total_frames = 0; M_dur_samples = 0;
    UINT p = 0;
    /* reads M_src[] (== M_pre when preloaded, == M_buf when streaming); lim caps the scan to ~1900 bytes */
    if (M_valid >= 10 && M_src[0]=='I'&&M_src[1]=='D'&&M_src[2]=='3') {   /* skip ID3v2 (syncsafe size) */
        uint32_t sz = ((uint32_t)(M_src[6]&0x7f)<<21)|((uint32_t)(M_src[7]&0x7f)<<14)|((uint32_t)(M_src[8]&0x7f)<<7)|(uint32_t)(M_src[9]&0x7f);
        p = 10 + sz;
    }
    UINT lim = M_valid; if (lim > p+1900) lim = p+1900;
    for (UINT i=p; i+12<lim; i++) {
        if ((M_src[i]=='X'&&M_src[i+1]=='i'&&M_src[i+2]=='n'&&M_src[i+3]=='g') ||
            (M_src[i]=='I'&&M_src[i+1]=='n'&&M_src[i+2]=='f'&&M_src[i+3]=='o')) {   /* Xing=VBR, Info=CBR (LAME) */
            M_vbr = (M_src[i]=='X');
            uint32_t flags = ((uint32_t)M_src[i+4]<<24)|((uint32_t)M_src[i+5]<<16)|((uint32_t)M_src[i+6]<<8)|M_src[i+7];
            if (flags & 1u) M_total_frames = ((uint32_t)M_src[i+8]<<24)|((uint32_t)M_src[i+9]<<16)|((uint32_t)M_src[i+10]<<8)|M_src[i+11];
            return;
        }
        if (M_src[i]=='V'&&M_src[i+1]=='B'&&M_src[i+2]=='R'&&M_src[i+3]=='I') {      /* Fraunhofer VBRI */
            M_vbr = 1;
            if (i+18<lim) M_total_frames = ((uint32_t)M_src[i+14]<<24)|((uint32_t)M_src[i+15]<<16)|((uint32_t)M_src[i+16]<<8)|M_src[i+17];
            return;
        }
    }
}

static void M_fill(void){                                     // top up the COMPRESSED ring from SD
    if (M_preloaded || M_src == M_pre) return;                                  // P2/P3: whole file already in RAM or preloading -> NEVER touch SD during playback
    if (M_eof) return;
    if (M_pos > sizeof(M_buf)/2) { UINT rem = M_valid - M_pos;
        for (UINT i=0;i<rem;i++) M_buf[i] = M_buf[M_pos+i]; M_valid = rem; M_pos = 0; }
    if (sizeof(M_buf) - M_valid >= 16384) { UINT rd = 0;
        if (f_read(&M_f, M_buf + M_valid, 16384, &rd) != FR_OK || rd == 0) M_eof = 1; else M_valid += rd; }
}
/* Decode ONE frame into M_frame[]; returns interleaved sample count (0 at EOF/garbage). */
static int M_decode(void){
    for (;;) {
        M_fill();
        int avail = (int)(M_valid - M_pos);
        if (avail <= 0) { if (M_eof) return 0; continue; }
        mp3dec_frame_info_t info;
        int samples = mp3dec_decode_frame(&M_dec, M_src + M_pos, avail, M_frame, &info);
        M_pos += info.frame_bytes;
        if (info.frame_bytes == 0) { if (M_eof || avail >= 8192) return 0; M_fill(); continue; }
        if (samples > 0) {
            M_ch = info.channels ? info.channels : 1; M_sr = info.hz ? info.hz : 44100;
            if (info.bitrate_kbps) {                        /* frozen first bitrate + detect variation (VBR w/o header) */
                if (!M_kbps0) M_kbps0 = info.bitrate_kbps; else if (info.bitrate_kbps != M_kbps0) M_vbr = 1;
                M_kbps = info.bitrate_kbps;
            }
            return samples * M_ch;
        }
        /* samples==0 with bytes consumed = skipped ID3/junk -> keep scanning */
    }
}

/* Decode ahead into the PCM ring, keeping UNREAD samples (D_len-D_pos) up to a high watermark so an SD
   read-stall is invisible AND recovery is one pass. (The old "<=4 frames/call" cap added only ~100 ms per
   pump, so after a stall the ring dribbled back and briefly underran -> the ~0.5 s "speed-up" glitch. And
   gating on D_len alone would false-EOF, since D_len is a monotonic write cursor - the watermark must be on
   UNREAD samples.) Compact the unread tail to the front only when there's no room for another frame:
   amortised, one bounded copy per ~28 frames of audio, not the old always-copy CPU burst. */
#define D_HIGH_WM (DCAP*3/4)                                  /* keep ~2.2 s stereo / ~4 s mono decoded ahead */
void mp3_refill(void){
    if (!M_open) return;
    
    /* Cooperative background loader: read the next 64 KB chunk of the file into DDR.
       Takes ~6 ms per pass, totally imperceptible, and runs on the same thread so no locks are needed! */
    if (M_background_loading) {
        UINT want = (M_data_bytes - M_valid) > 65536u ? 65536u : (UINT)(M_data_bytes - M_valid);
        if (want > 0) {
            UINT rd = 0;
            if (f_read(&M_f, M_pre + M_valid, want, &rd) == FR_OK && rd > 0) {
                M_valid += rd;
            } else {                                        /* SD error: abort preload, stay with what we have */
                M_background_loading = 0;
            }
        }
        if (M_valid >= M_data_bytes) {
            M_background_loading = 0;
            M_preloaded = 1; M_eof = 1;
            f_close(&M_f); M_fh_open = 0;
        }
    }

    int guard = 32;                                           /* Q-bound caps worst-case pump to ~12 ms. MUST stay >= ~27 to prevent false-EOF underfeed. */
    while ((D_len - D_pos) < D_HIGH_WM && guard-- > 0) {
        if (D_len + MINIMP3_MAX_SAMPLES_PER_FRAME > DCAP) {   /* no room for a frame: compact, or bail if full */
            if (D_pos == 0) break;
            int rem = D_len - D_pos; for (int i=0;i<rem;i++) D_buf[i] = D_buf[D_pos+i]; D_len = rem; D_pos = 0;
        }
        int n = M_decode();
        if (n <= 0) break;
        for (int i=0;i<n;i++) D_buf[D_len++] = M_frame[i];
    }
}

int mp3_open(const char* path){
    mp3_close();
    if (f_open(&M_f, path, FA_READ) != FR_OK) return 0;
    M_open = 1; M_fh_open = 1;
    M_valid = 0; M_pos = 0; M_eof = 0; D_len = 0; D_pos = 0; M_played = 0;
    M_preloaded = 0; M_src = M_buf;                         /* default: stream the compressed ring from SD */
    uint32_t fsz = (uint32_t)f_size(&M_f), astart = 0;
    /* SKIP ID3v2 up front (it can be 100 KB+ of album art, which would bury the Xing header). Read the
       10-byte ID3 header, compute the syncsafe tag size, and seek straight to the first audio frame. */
    { uint8_t hb[10]; UINT hr = 0;
      if (f_read(&M_f, hb, 10, &hr) == FR_OK && hr == 10 && hb[0]=='I'&&hb[1]=='D'&&hb[2]=='3') {
          uint32_t sz = ((uint32_t)(hb[6]&0x7f)<<21)|((uint32_t)(hb[7]&0x7f)<<14)|((uint32_t)(hb[8]&0x7f)<<7)|(uint32_t)(hb[9]&0x7f);
          astart = 10 + sz;
      } }
    M_data_bytes = (fsz > astart) ? (fsz - astart) : fsz;   /* audio-only size -> correct CBR estimate */
    f_lseek(&M_f, astart);                                  /* start reading at the first audio frame */
    M_valid = 0; M_pos = 0; M_eof = 0;

    /* ---- P2 WHOLE-FILE PRELOAD: slurp the whole audio region into DDR so playback touches ZERO SD ----
       Reads in 256 KB, 32-byte-aligned chunks (the snapbuf/g_tapbuf DMA idiom: the xsdps driver invalidates
       each aligned chunk, so the decode below reads fresh bytes - no manual cache maintenance). Nothing is
       playing here (player_stop() ran before this open), so a card-GC stall during this load only
       lengthens the one-time open - it can NOT starve the ring. Files bigger than M_PRE_CAP fall through
       to the original streaming path unchanged. */
    M_background_loading = 0;
    if (opt_preload && M_data_bytes > 0 && M_data_bytes <= M_PRE_CAP) {
        /* CDJ-STYLE FAST START: slurp only the first chunk (256 KB, ~25 ms read time) synchronously.
           This primes the start of the track instantly, then we continue loading the rest of the file
           cooperatively in the background inside mp3_refill() while the music is already playing! */
        UINT want = M_data_bytes > M_PRE_CHUNK ? (UINT)M_PRE_CHUNK : (UINT)M_data_bytes;
        UINT rd = 0;
        if (f_read(&M_f, M_pre, want, &rd) == FR_OK && rd > 0) {
            M_src = M_pre; M_valid = rd; M_pos = 0;
            if (rd >= M_data_bytes) {                       /* whole file was small enough to fit in 1st chunk */
                M_eof = 1; M_preloaded = 1;
                f_close(&M_f); M_fh_open = 0;
            } else {                                        /* start background cooperative load */
                M_eof = 0; M_preloaded = 0; M_background_loading = 1;
            }
        } else {                                            /* read error -> clean streaming fallback */
            f_lseek(&M_f, astart); M_valid = 0; M_pos = 0; M_eof = 0; M_src = M_buf; M_preloaded = 0;
        }
    }
    if (!M_preloaded) M_fill();                /* streaming fallback: prime the compressed ring from SD */

    mp3dec_init(&M_dec);
    mp3_parse_duration();                      /* exact duration from Xing/Info/VBRI (reads M_src, up front) */
    /* prime: decode the first frame (sets sr/ch/bitrate + samples-per-frame), then fill the ring */
    { int n = M_decode(); if (n <= 0) { mp3_close(); return 0; }
      M_spf = M_ch ? (uint32_t)(n / M_ch) : 1152;
      if (M_total_frames) M_dur_samples = (uint64_t)M_total_frames * M_spf;
      for (int i=0;i<n;i++) D_buf[D_len++] = M_frame[i]; }
    while (D_len < 24000 && D_len + MINIMP3_MAX_SAMPLES_PER_FRAME <= DCAP) { int n = M_decode(); if (n<=0) break;
        for (int i=0;i<n;i++) D_buf[D_len++] = M_frame[i]; }   /* small prime (~0.25 s) so open never blocks long; mp3_refill tops up during playback */
    return 1;
}

int mp3_read(int16_t* l, int16_t* r){
    if (!M_open) return 0;
    if (D_pos >= D_len) { mp3_refill(); if (D_pos >= D_len) return 0; }   /* empty: one refill, else EOF */
    if (M_ch >= 2) { *l = D_buf[D_pos]; *r = D_buf[D_pos+1]; D_pos += 2; }
    else           { int16_t v = D_buf[D_pos++]; *l = v; *r = v; }
    M_played++;
    return 1;
}

void mp3_close(void){
    M_background_loading = 0;
    if (M_open) { if (M_fh_open) { f_close(&M_f); M_fh_open = 0; } M_open = 0; }
}
int  mp3_is_open(void){ return M_open; }
uint32_t mp3_sr(void){ return M_sr; }
int      mp3_ch(void){ return M_ch; }
uint32_t mp3_bitrate(void){ return (uint32_t)(M_kbps0 ? M_kbps0 : M_kbps); }   /* frozen (stable) bitrate for the CBR display */
int      mp3_is_vbr(void){ return M_vbr; }
unsigned mp3_total_s(void){
    if (M_dur_samples && M_sr) return (unsigned)(M_dur_samples / M_sr);          /* exact (Xing/VBRI frame count) */
    if (M_kbps0) return (unsigned)(((uint64_t)M_data_bytes*8u)/((uint32_t)M_kbps0*1000u));  /* CBR estimate (frozen) */
    return 0;
}
unsigned mp3_elapsed_s(void){ if (!M_sr) return 0; return (unsigned)(M_played / M_sr); }   /* M_played = frames popped */
unsigned mp3_progress(void){ unsigned t=mp3_total_s(), e=mp3_elapsed_s(); if(!t) return 0; unsigned p=e*100u/t; return p>100?100:p; }
