// player.c - BulbuLator universal ARM music player (Step 13.2 MVP).
//
// Machine-agnostic: the ARM decodes a music file and soft-synthesises the sound chip to PCM, then
// streams stereo signed-16 @ 47996 Hz into the fabric's ARM->HDMI audio FIFO (AXI 0x7C). When the
// player is active the bitstream's audio mux selects this PCM over the fabric core's audio, so it
// plays whatever (or no) machine is loaded - exactly the owner's requirement.
//
// MVP format = .psg (raw AY-3-8910 register dump; AYUMI consumes the 14 regs directly, no tracker
// decoder needed - it proves the whole file->AYUMI->PCM->machine-agnostic-HDMI chain). Tracker
// formats (.pt3 via pt3_lib, etc.) drop in next on the SAME pump path.
//
// AYUMI: MIT (third_party/ayumi). .psg playback is cooperative on core0 from the main loop's
// player_pump(): push samples while the FIFO has room (backpressure), advancing one 50Hz frame
// every 960 (=47996/50) rendered samples - the FIFO drain rate sets the tempo.

#include <stdint.h>
#include "ff.h"          // FatFs (already used by the loader)
#include "ayumi.h"
#include "xtime_l.h"     // XTime / COUNTS_PER_SECOND - real-time playback pacing (tempo lock)

#define GP0          0x40000000u
#define AUDIO_CTRL   (*(volatile uint32_t*)(GP0+0x78))  /* bit0 = player active (mux player->HDMI) */
#define AUDIO_FIFO   (*(volatile uint32_t*)(GP0+0x7C))  /* W: push {R[31:16], L[15:0]} signed-16 */
#define AUDIO_STAT   (*(volatile uint32_t*)(GP0+0x80))  /* R: bit0 empty, bit1 full */

#define PLAYER_SR        47996            /* the real HDMI audio rate (top.v clk_audio_r), NOT 48000 */
#define AY_CLOCK         1773400.0        /* ZX-128 AY/YM chip clock ~1.7734 MHz -> sets PITCH (configurable, TODO) */
#define FRAME_HZ         50               /* music interrupt/frame rate -> sets TEMPO (48K~50.08 / 128K~50.01 / Pentagon~48.83, configurable, TODO) */
#define SAMPLES_PER_FRAME (PLAYER_SR/FRAME_HZ)  /* 959.92 -> 959; one music frame */
#define PLAYER_LEAD      192              /* samples kept ahead of real time = FIFO cushion (depth 256) */

static struct ayumi g_ay;
static FIL  g_pf;
static int  g_playing = 0;
static int  g_paused  = 0;                /* transport: paused (no samples pushed -> silence) */
static int  g_ended   = 0;                /* set when playback stopped because the file reached EOF (not a user stop) */
static uint8_t  ay_regs[16];
static int      g_r13_written = 0;        /* was R13 (env shape) written in the chunk just parsed? (retrigger gate) */
static XTime    g_t0 = 0;                 /* playback start time: the real-time tempo anchor */
static uint64_t g_samples = 0;            /* total samples emitted since start (real-time pace) */
static uint64_t g_frame = 0;              /* music frames consumed so far */
static uint64_t g_next_frame_at = 0;      /* sample index at which the next frame loads (exact boundary) */
static uint64_t g_hold = 0;               /* frame-periods remaining to HOLD the current state (0xFE run-length) */

/* Stream the .psg straight from SD in 4 KB chunks (no big RAM buffer; FatFs sequential read). */
/* 32-byte (A9 cache-line) aligned: FatFs streams the .psg straight into this buffer; with D-cache
   ON an unaligned DMA target would clip bytes on the cache invalidate (the old "cache-off" bug). */
static uint8_t g_buf[4096] __attribute__((aligned(32)));
static UINT g_blen = 0, g_bpos = 0;
static uint8_t psg_byte(int* ok){
    if (g_bpos >= g_blen) {
        if (f_read(&g_pf, g_buf, sizeof(g_buf), &g_blen) != FR_OK || g_blen == 0) { *ok = 0; return 0; }
        g_bpos = 0;
    }
    *ok = 1; return g_buf[g_bpos++];
}

/* Map the 14 AY registers into AYUMI for one frame. */
static void ay_to_ayumi(void){
    ayumi_set_tone(&g_ay, 0, (ay_regs[0] | ((ay_regs[1] & 0x0F) << 8)));
    ayumi_set_tone(&g_ay, 1, (ay_regs[2] | ((ay_regs[3] & 0x0F) << 8)));
    ayumi_set_tone(&g_ay, 2, (ay_regs[4] | ((ay_regs[5] & 0x0F) << 8)));
    ayumi_set_noise(&g_ay, ay_regs[6] & 0x1F);
    ayumi_set_mixer(&g_ay, 0,  ay_regs[7]       & 1, (ay_regs[7] >> 3) & 1, (ay_regs[8]  >> 4) & 1);
    ayumi_set_mixer(&g_ay, 1, (ay_regs[7] >> 1) & 1, (ay_regs[7] >> 4) & 1, (ay_regs[9]  >> 4) & 1);
    ayumi_set_mixer(&g_ay, 2, (ay_regs[7] >> 2) & 1, (ay_regs[7] >> 5) & 1, (ay_regs[10] >> 4) & 1);
    ayumi_set_volume(&g_ay, 0, ay_regs[8]  & 0x0F);
    ayumi_set_volume(&g_ay, 1, ay_regs[9]  & 0x0F);
    ayumi_set_volume(&g_ay, 2, ay_regs[10] & 0x0F);
    ayumi_set_envelope(&g_ay, (ay_regs[11] | (ay_regs[12] << 8)));   /* period: safe to re-apply (no retrigger) */
    /* Envelope SHAPE write RETRIGGERS the AY envelope. Apply ONLY on frames where R13 is actually
       written in the stream - re-applying the persisted value every frame restarts the envelope
       50x/s = buzzy/dirty envelope + clicks on every change (exactly the owner's symptom). */
    if (g_r13_written && ay_regs[13] != 0xFF) ayumi_set_envelope_shape(&g_ay, ay_regs[13] & 0x0F);
}

/* Parse one .psg chunk: accumulate register writes into ay_regs[] until a frame terminator, and
   RETURN how many 50 Hz frame-periods this state lasts. 0xFF = 1 period; 0xFE N = HOLD for 4*N
   periods (run-length compression of repeated frames - the old code wrongly collapsed this to 1,
   which raced the 0xFE-dense intro); 0xFD / EOF = 0 (stop). Semantics verified against ZXTune
   src/formats/chiptune/aym/psg.cpp (INT_BEGIN -> AddChunks(1); INT_SKIP -> AddChunks(4*N)). */
static int psg_next_frame(void){
    int ok;
    g_r13_written = 0;                           /* track whether R13 (env shape) is written THIS chunk */
    for (;;) {
        uint8_t b = psg_byte(&ok);
        if (!ok) return 0;
        if (b == 0xFF) return 1;                 /* one frame period */
        if (b == 0xFD) return 0;                 /* end of file */
        if (b == 0xFE) { uint8_t n = psg_byte(&ok); if (!ok) return 0; return n ? (int)n * 4 : 1; }  /* hold 4*N periods */
        if (b <= 0x0F) { uint8_t v = psg_byte(&ok); if (ok) { ay_regs[b] = v; if (b == 13) g_r13_written = 1; } else return 0; }
        /* any other byte: ignore (robustness) */
    }
}

void player_stop(void){
    if (!g_playing) return;
    AUDIO_CTRL = 0;            /* mux back to fabric audio */
    f_close(&g_pf);
    g_playing = 0;
}

/* Start playing a .psg file. Returns 1 on success. */
int player_play_psg(const char* path){
    player_stop();
    if (f_open(&g_pf, path, FA_READ) != FR_OK) return 0;
    g_blen = g_bpos = 0;
    /* 16-byte header: "PSG" 0x1A Version + reserved. Quirk (ZXTune): if Version (byte 4) == 0xFF the
       body starts at offset 4 (some emulators wrote a short header then a 0xFF frame); else at 16. */
    { uint8_t hdr[16] __attribute__((aligned(32))); UINT hr = 0;
      if (f_read(&g_pf, hdr, sizeof(hdr), &hr) != FR_OK || hr < 16) { f_close(&g_pf); return 0; }
      if (hdr[4] == 0xFF && f_lseek(&g_pf, 4) != FR_OK) { f_close(&g_pf); return 0; }
      g_blen = g_bpos = 0; }                /* read the body fresh from the chosen offset */
    for (int i = 0; i < 16; i++) ay_regs[i] = 0;
    ayumi_configure(&g_ay, 0 /*AY, not YM*/, AY_CLOCK, PLAYER_SR);
    ayumi_set_pan(&g_ay, 0, 0.5, 0);   /* ABC stereo: A centre-left, B centre, C centre-right */
    ayumi_set_pan(&g_ay, 1, 0.5, 0);
    ayumi_set_pan(&g_ay, 2, 0.5, 0);
    g_samples = 0;
    g_frame = 0;
    g_next_frame_at = 0;       /* first frame loads at sample 0 */
    g_playing = 1;
    g_paused  = 0;
    g_ended   = 0;
    AUDIO_CTRL = 1;            /* player active -> mux PCM to HDMI */
    XTime_GetTime(&g_t0);      /* anchor the real-time tempo clock at the moment playback starts */
    return 1;
}

int player_active(void){ return g_playing; }
int player_paused(void){ return g_paused; }
/* Consume-once "track reached its natural end" signal (for auto-advance). Returns 1 only after an
   EOF stop, not after a user stop / snapshot load. */
int player_take_ended(void){ int e = g_ended; g_ended = 0; return e; }

/* Transport: pause/resume. While paused, player_pump pushes nothing -> the FIFO drains -> silence.
   On resume we RE-ANCHOR the real-time clock (g_t0) to the current g_samples so the player does NOT
   sprint to "catch up" the paused wall-clock gap. */
void player_pause_toggle(void){
    if (!g_playing) return;
    g_paused = !g_paused;
    if (!g_paused) {
        XTime now; XTime_GetTime(&now);
        g_t0 = now - (XTime)((g_samples * (uint64_t)COUNTS_PER_SECOND) / (uint64_t)PLAYER_SR);
    }
}

/* Cooperative pump: call every main-loop pass. Pushes samples while the FIFO has room; advances one
   .psg frame every SAMPLES_PER_FRAME samples. FIFO drain (47996 Hz) sets the tempo (backpressure). */
/* Cooperative pump, REAL-TIME paced: the tempo is locked to wall-clock (XTime) at PLAYER_SR, NOT to
   how fast the A9 can render. Each call renders exactly the samples that "should" have been produced
   by now (due - g_samples), plus a small PLAYER_LEAD cushion that keeps the FIFO partly filled. This
   is CPU-speed independent: the D-cache speed-up made the old "render until the FIFO reports full"
   loop sprint far ahead of real time (music way too fast) - pacing by the clock fixes that and does
   not depend on the fabric's FIFO-full flag. We still skip a push if the FIFO is somehow full. */
void player_pump(void){
    if (!g_playing || g_paused) return;        /* paused: push nothing -> FIFO drains -> silence */
    XTime now; XTime_GetTime(&now);
    uint64_t due = (uint64_t)PLAYER_LEAD
                 + ((uint64_t)(now - g_t0) * (uint64_t)PLAYER_SR) / (uint64_t)COUNTS_PER_SECOND;
    if (due <= g_samples) return;                          /* not time for the next sample yet */
    uint64_t want = due - g_samples;
    if (want > 8192) { g_samples = due - 8192; want = 8192; }  /* big gap (long stall): resync, don't sprint */
    for (uint64_t i = 0; i < want; i++) {
        /* EXACT frame boundary: frame F loads at sample floor(F*PLAYER_SR/FRAME_HZ). No 959.92->959
           rounding drift -> frames advance at EXACTLY FRAME_HZ in real time (PLAYER_SR cancels out,
           so the tempo is independent of the audio clock's exact value). */
        while (g_samples >= g_next_frame_at) {
            if (g_hold == 0) {                       /* current state exhausted -> fetch next chunk */
                int periods = psg_next_frame();
                if (periods <= 0) { g_ended = 1; player_stop(); return; }   /* natural EOF -> signal auto-advance */
                ay_to_ayumi();
                g_hold = (uint64_t)periods;          /* 1 for 0xFF, 4*N for 0xFE N (run-length hold) */
            }
            g_hold--;                                /* consume one 50 Hz frame-period of this state */
            g_frame++;
            g_next_frame_at = ((uint64_t)g_frame * (uint64_t)PLAYER_SR) / (uint64_t)FRAME_HZ;
        }
        /* Backpressure: if the FIFO is full, stop this pass WITHOUT consuming the sample. Do NOT
           advance g_samples on a non-push - a dropped-but-counted sample would creep the song clock
           ahead of the audio actually delivered. XTime re-presents the same `due` next pass; the
           FIFO drains a slot in ~21 us. (With correct pacing the FIFO is rarely full anyway.) */
        if (AUDIO_STAT & 0x2u) return;
        ayumi_process(&g_ay);
        ayumi_remove_dc(&g_ay);
        int l = (int)(g_ay.left  * 16384.0);
        int r = (int)(g_ay.right * 16384.0);
        if (l >  32767) l =  32767; else if (l < -32768) l = -32768;
        if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
        AUDIO_FIFO = ((uint32_t)(r & 0xFFFF) << 16) | (uint32_t)(l & 0xFFFF);
        g_samples++;
    }
}
