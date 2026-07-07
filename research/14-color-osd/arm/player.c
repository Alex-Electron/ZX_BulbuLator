// player.c - BulbuLator universal ARM music player (Step 14.3b: interrupt-fed, click-free).
//
// Machine-agnostic: the ARM decodes a music file (PSG soft-synth / WAV PCM / MP3 via minimp3) and
// streams stereo signed-16 @ 47996 Hz into the fabric's ARM->HDMI audio FIFO (AXI 0x7C). When the
// player is active the bitstream's audio mux selects this PCM over the fabric core's audio.
//
// ARCHITECTURE (the "make it maximally reliable" rework):
//   PRODUCER (main loop, player_pump): decodes/renders into a large PCM ring (RB, ~2.7 s) in small
//     quanta. Heavy work (SD reads, MP3 frame decodes, ring compaction) happens ONLY here, where a
//     stall no longer matters - the ring bridges it.
//   CONSUMER (1 ms SCU-timer interrupt, player_isr_tick): pops the ring into the 256-deep fabric
//     FIFO whenever it has room - the FIFO's fixed drain rate IS the clock. Runs even while the main
//     loop is stuck in an SD directory scan or an OSD redraw, so the FIFO can no longer starve.
//   FADES (in the consumer, Q8 gain 0..256, 1 step/sample = ~5.3 ms ramp): play start, pause, stop
//     and EOF all ramp instead of stepping -> no more transition clicks.
//   FIFO-CLOCKED, silence on underrun (no wall clock, no slip): the DAC's own 47996 Hz is the only
//     tempo, so there is zero drift and nothing to "catch up" to. If the ring ever runs dry the consumer
//     feeds SILENCE (never a time-jump), so a stall degrades to a brief mute, not a sped-up replay.
// If the interrupt cannot be initialised (player_audio_irq(0)), player_pump calls the consumer
// inline - the polled fallback keeps the exact same behaviour minus the stall immunity.

#include <stdint.h>
#include "ff.h"          // FatFs (already used by the loader)
#include "ayumi.h"
#include "mp3dec.h"      // shared minimp3 source (music + tape)
#include "xtime_l.h"     // XTime / COUNTS_PER_SECOND - real-time pacing (tempo lock)
#include "xil_exception.h"  // brief IRQ-off critical sections around shared 64-bit state
/* Step 14.3d "audiophile" resampler: speexdsp (BSD, polyphase windowed-sinc - the proven embeddable
   standard, WebRTC/PipeWire lineage) replaces the linear interpolator for WAV/MP3 -> 47996 Hz.
   Linear interp images/dulls the top octave; speex at quality 7 is transparent. PSG needs none
   (AYUMI synthesises at PLAYER_SR natively). Falls back to linear if init fails (no heap). */
#include "speex_resampler.h"   /* built with -DOUTSIDE_SPEEX -DFIXED_POINT -DRANDOM_PREFIX=bulb */

#define GP0          0x40000000u
#define AUDIO_CTRL   (*(volatile uint32_t*)(GP0+0x78))  /* bit0 = player active (mux player->HDMI) */
#define AUDIO_FIFO   (*(volatile uint32_t*)(GP0+0x7C))  /* W: push {R[31:16], L[15:0]} signed-16 */
#define AUDIO_STAT   (*(volatile uint32_t*)(GP0+0x80))  /* R: bit0 empty, bit1 full */

#define PLAYER_SR        47996            /* the real HDMI audio rate (top.v clk_audio_r), NOT 48000 */
#define AY_CLOCK         1773400.0        /* ZX-128 AY/YM chip clock ~1.7734 MHz -> sets PITCH */
#define FRAME_HZ         50               /* music interrupt/frame rate -> sets TEMPO */

/* ---------------- PCM ring: single-producer (main loop) / single-consumer (ISR) ---------------- */
#define RB_LEN  524288u                   /* power of 2; stereo samples: ~10.9 s @ 47996. DEEPENED from 2.7s:
                                             a card GC read-stall inside player_pump's f_read blocks the whole
                                             producer, and only THIS ring drains during it -> a >ring-depth stall
                                             underruns (confirmed: g_underruns=3604). 10.9 s absorbs multi-second
                                             SD stalls. 2 MB in DDR. (Definitive fix later = P2 RAM-preload.) */
#define RB_MASK (RB_LEN-1u)
#define RB_HIGH_WM (RB_LEN*7u/8u)         /* producer tops the ring to ~9.5 s each pump */
static volatile uint32_t rb_buf[RB_LEN];  /* packed {R[31:16], L[15:0]} */
static volatile uint32_t rb_w = 0, rb_r = 0;   /* monotonic indices (wrap via mask); 32-bit = atomic on A9 */
static uint32_t rb_count(void){ return rb_w - rb_r; }
static uint32_t rb_free(void){ return RB_LEN - (rb_w - rb_r); }
static void rb_push(int16_t l, int16_t r){
    rb_buf[rb_w & RB_MASK] = ((uint32_t)(uint16_t)r << 16) | (uint16_t)l;
    rb_w++;                                            /* index bump AFTER the data write (SPSC ordering) */
}

/* ---------------- consumer / transport state ---------------- */
static volatile int  a_gain = 0, a_target = 0;   /* Q8 fade gain, ramps 1 step/sample (~5.3 ms full swing) */
static volatile int  c_on = 0;                   /* consumer enabled (track active) */
static volatile int  pace_hold = 0;              /* paused AND fully faded: freeze consumption + clock */
static int  audio_irq_on = 0;                    /* 1 = the 1 ms timer ISR is live */
static volatile uint64_t g_samples = 0;          /* samples CONSUMED (heard) since track start = elapsed clock */
static int16_t  last_l = 0, last_r = 0;          /* last produced sample (EOF decay tail source) */
volatile uint32_t g_underruns = 0;               /* telemetry: silence samples fed on ring-empty (target ~0) */
volatile uint32_t g_rb_min = 0xFFFFFFFFu;        /* telemetry: lowest rb_count seen while playing (JTAG: 0 => ring emptied) */

static int  g_playing = 0;
static int  g_paused  = 0;
static int  g_ended   = 0;                /* set on natural EOF (consume-once for auto-advance) */
static int  prod_done = 0;                /* producer hit source EOF (decay tail already pushed) */
static volatile int g_idle_muxup = 0;   /* between tracks: source freed but the mux stays engaged (ISR
                                           feeds silence, machine muted) so an auto-advance / next never
                                           crossfades the fabric's idle DC in and out -> no click, no ZX
                                           blip. Cleared by track_arm, or by the grace timer at a true
                                           playlist end. */
static XTime   g_idle_t0;                /* stamp when we entered g_idle_muxup (grace timer) */

/* format */
#define FMT_PSG 0
#define FMT_WAV 1
#define FMT_MP3 2
static int g_fmt = FMT_PSG;

void player_audio_irq(int ok){ audio_irq_on = ok; }

/* ---------------- CONSUMER: called from the 1 ms SCU-timer ISR (or inline in polled fallback) ----------------
   The fabric FIFO IS the clock: push while it has room. The fabric drains it at exactly PLAYER_SR, so the
   DAC's own rate is the one true tempo - no wall clock, no drift, nothing to "catch up" to. On a ring
   underrun we push SILENCE (never a time-jump / stale replay), easing the gain down so the gap edge does
   not click; g_samples (the elapsed clock) counts only REAL emitted samples. Format-agnostic: PCM is PCM,
   so MP3/WAV/PSG and any future lossless codec all drain through this same path. */
void player_isr_tick(void){
    if(!c_on) return;
    if(pace_hold){                                           /* paused & fully faded: hold DAC at silence */
        for(int b=260; b>0 && !(AUDIO_STAT & 0x2u); b--) AUDIO_FIFO = 0;
        return;
    }
    { uint32_t c=rb_count(); if(c<g_rb_min) g_rb_min=c; }    /* telemetry: ring low-water mark */
    int budget = 260;                                        /* hard bound (~FIFO depth 256): never spin on a bad STAT read */
    while(budget-- > 0 && !(AUDIO_STAT & 0x2u)){            /* push while the fabric FIFO has room */
        uint32_t s;
        if(rb_count() != 0u){                                /* real audio available */
            s = rb_buf[rb_r & RB_MASK];
            if(a_gain != a_target) a_gain += (a_gain < a_target) ? 1 : -1;
            if(a_gain != 256){                               /* fade: scale both channels (Q8) */
                int l = (int16_t)(s & 0xFFFFu), r = (int16_t)(s >> 16);
                l = (l * a_gain) >> 8; r = (r * a_gain) >> 8;
                s = ((uint32_t)(uint16_t)r << 16) | (uint16_t)l;
            }
            rb_r++; g_samples++;                             /* advance only on a real sample */
        } else {                                             /* UNDERRUN: feed silence, NO time-jump, no skip */
            if(a_gain > 0) a_gain--;                         /* ease toward 0 so the underrun edge is click-free */
            s = 0;
            if(g_samples && !prod_done) g_underruns++;                     /* ignore the pre-roll before the 1st real sample and EOF drain */
        }
        AUDIO_FIFO = s;
    }
    if(g_paused && a_gain==0) pace_hold = 1;                 /* fade-out finished -> freeze until resume */
}

/* ---------------- PSG source (AYUMI soft-synth; frame machinery driven by PRODUCED samples) ---------------- */
static struct ayumi g_ay;
static FIL  g_pf;                          /* PSG/WAV file handle (MP3 lives in mp3dec.c) */
static uint8_t  ay_regs[16];
static int      g_r13_written = 0;
static uint64_t p_samples = 0;             /* samples PRODUCED (drives the 50 Hz frame boundary) */
static uint64_t g_frame = 0;
static uint64_t g_total_frames = 1;        /* pre-scanned -> duration */
static uint64_t g_next_frame_at = 0;
static uint64_t g_hold = 0;

/* Stream the .psg straight from SD in 4 KB chunks (32-byte aligned: D-cache-safe DMA target). */
static uint8_t g_buf[4096] __attribute__((aligned(32)));
static UINT g_blen = 0, g_bpos = 0;
static uint8_t psg_byte(int* ok){
    if (g_bpos >= g_blen) {
        if (f_read(&g_pf, g_buf, sizeof(g_buf), &g_blen) != FR_OK || g_blen == 0) { *ok = 0; return 0; }
        g_bpos = 0;
    }
    *ok = 1; return g_buf[g_bpos++];
}
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
    ayumi_set_envelope(&g_ay, (ay_regs[11] | (ay_regs[12] << 8)));
    /* R13 write RETRIGGERS the envelope: apply only on frames that actually write it. */
    if (g_r13_written && ay_regs[13] != 0xFF) ayumi_set_envelope_shape(&g_ay, ay_regs[13] & 0x0F);
}
/* One .psg chunk -> how many 50 Hz frame-periods it lasts (0xFF=1, 0xFE N=4N; ZXTune semantics). */
static int psg_next_frame(void){
    int ok;
    g_r13_written = 0;
    for (;;) {
        uint8_t b = psg_byte(&ok);
        if (!ok) return 0;
        if (b == 0xFF) return 1;
        if (b == 0xFD) return 0;
        if (b == 0xFE) { uint8_t n = psg_byte(&ok); if (!ok) return 0; return n ? (int)n * 4 : 1; }
        if (b <= 0x0F) { uint8_t v = psg_byte(&ok); if (ok) { ay_regs[b] = v; if (b == 13) g_r13_written = 1; } else return 0; }
    }
}
static int render_one_psg(int16_t* lo, int16_t* ro){
    while (p_samples >= g_next_frame_at) {                   /* exact frame boundary, no rounding drift */
        if (g_hold == 0) {
            int periods = psg_next_frame();
            if (periods <= 0) return 0;                      /* natural EOF */
            ay_to_ayumi();
            g_hold = (uint64_t)periods;
        }
        g_hold--; g_frame++;
        g_next_frame_at = ((uint64_t)g_frame * (uint64_t)PLAYER_SR) / (uint64_t)FRAME_HZ;
    }
    ayumi_process(&g_ay);
    ayumi_remove_dc(&g_ay);
    int l = (int)(g_ay.left  * 16384.0), r = (int)(g_ay.right * 16384.0);
    if (l >  32767) l =  32767; else if (l < -32768) l = -32768;
    if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
    *lo = (int16_t)l; *ro = (int16_t)r; return 1;
}

/* ---------------- WAV source + shared linear resampler (source rate -> PLAYER_SR) ---------------- */
static uint32_t g_wav_sr = 44100;
static int      g_wav_ch = 2;
static int      g_wav_bps = 2;            /* bytes per sample per channel (1=u8, 2=s16) */
static uint32_t g_wav_total = 0, g_wav_read = 0;
static double   g_src_sr = 44100.0;
static double   g_rs_frac = 0.0;
static int16_t  g_a_l=0, g_a_r=0, g_b_l=0, g_b_r=0;
static int      g_rs_init = 0, g_src_eof = 0;

static uint8_t  g_sbuf[65536] __attribute__((aligned(32)));   /* WAV SD stream ring */
static UINT     g_svalid = 0, g_spos = 0;
static int      g_seof = 0;
static void stream_reset(void){ g_svalid = 0; g_spos = 0; g_seof = 0; }
static void stream_refill(void){
    if (g_seof) return;
    if (g_spos > sizeof(g_sbuf)/2) {                    /* compact: slide the unread tail down */
        UINT rem = g_svalid - g_spos;
        for (UINT i=0;i<rem;i++) g_sbuf[i] = g_sbuf[g_spos+i];
        g_svalid = rem; g_spos = 0;
    }
    if (sizeof(g_sbuf) - g_svalid >= 16384) {
        UINT rd = 0;
        if (f_read(&g_pf, g_sbuf + g_svalid, 16384, &rd) != FR_OK || rd == 0) g_seof = 1;
        else g_svalid += rd;
    }
}
static int stream_byte(uint8_t* b){
    if (g_spos >= g_svalid) {
        if (g_seof) return 0;
        UINT rd = 0;
        if (f_read(&g_pf, g_sbuf, sizeof(g_sbuf), &rd) != FR_OK || rd == 0) { g_seof = 1; return 0; }
        g_svalid = rd; g_spos = 0;
    }
    *b = g_sbuf[g_spos++]; return 1;
}
static uint32_t rd_u16le(const uint8_t* p){ return p[0] | ((uint32_t)p[1]<<8); }
static uint32_t rd_u32le(const uint8_t* p){ return p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
static int wav_take(int16_t* v){
    if (g_wav_read >= g_wav_total) return 0;
    if (g_wav_bps == 2) { uint8_t lo,hi; if(!stream_byte(&lo)||!stream_byte(&hi)) return 0;
                          *v = (int16_t)(lo | ((uint16_t)hi<<8)); g_wav_read += 2; }
    else               { uint8_t b;      if(!stream_byte(&b)) return 0;
                          *v = (int16_t)(((int)b - 128) << 8);   g_wav_read += 1; }
    return 1;
}
static int src_next(int16_t* l, int16_t* r){
    if (g_fmt == FMT_WAV) {
        int16_t a; if (!wav_take(&a)) return 0;
        int16_t b = a;
        if (g_wav_ch >= 2) { if (!wav_take(&b)) return 0; }
        for (int c = 2; c < g_wav_ch; c++) { int16_t junk; if (!wav_take(&junk)) break; }
        *l = a; *r = b; return 1;
    }
    if (g_fmt == FMT_MP3) return mp3_read(l, r);
    return 0;
}
static int render_one_stream(int16_t* lo, int16_t* ro){   /* linear fallback (only if speex init failed) */
    double ratio = g_src_sr / (double)PLAYER_SR;
    if (!g_rs_init) {
        if (!src_next(&g_a_l,&g_a_r)) return 0;
        if (!src_next(&g_b_l,&g_b_r)) { g_b_l=g_a_l; g_b_r=g_a_r; g_src_eof=1; }
        g_rs_init = 1; g_rs_frac = 0.0;
    }
    double f = g_rs_frac;
    *lo = (int16_t)((double)g_a_l + ((double)g_b_l - (double)g_a_l) * f);
    *ro = (int16_t)((double)g_a_r + ((double)g_b_r - (double)g_a_r) * f);
    g_rs_frac += ratio;
    while (g_rs_frac >= 1.0) {
        g_rs_frac -= 1.0;
        g_a_l = g_b_l; g_a_r = g_b_r;
        if (g_src_eof) return 0;
        if (!src_next(&g_b_l,&g_b_r)) { g_b_l=g_a_l; g_b_r=g_a_r; g_src_eof=1; }
    }
    return 1;
}

/* ---- speex block resampler: source frames -> RB, with a carry buffer + EOF sinc-tail flush ---- */
static SpeexResamplerState* g_spx = 0;     /* NULL -> linear fallback path */
static int16_t  rs_in[2048];               /* interleaved carry block (1024 stereo frames) */
static uint32_t rs_in_frames = 0;
static int      g_src_end = 0;             /* source exhausted */
static int      rs_flush = 0;              /* zero-frames still to feed (flush the filter tail) */
static int16_t  rs_out[4096];              /* interleaved output block (2048 stereo frames) */
static int g_bit_direct = 0;               /* source rate ~= output rate: bit-exact 1:1 (no resampler at all) */
static void spx_start(void){
    if (g_spx){ speex_resampler_destroy(g_spx); g_spx = 0; }
    rs_in_frames = 0; g_src_end = 0; rs_flush = 0;
    /* purist path: within 0.1% of the hardware rate (e.g. 48000 -> 47996 = 83 ppm) skip resampling
       entirely - samples pass bit-exact, playing 0.008% slow (far below audibility; ordinary player
       crystals err more). Zero processing = zero colouration. */
    long d = (long)g_src_sr - (long)PLAYER_SR; if (d < 0) d = -d;
    g_bit_direct = (d * 1000L < (long)PLAYER_SR);
    if (g_bit_direct) return;
    int err = 0;
    g_spx = speex_resampler_init(2, (spx_uint32_t)g_src_sr, (spx_uint32_t)PLAYER_SR, 7, &err);
    if (g_spx) speex_resampler_skip_zeros(g_spx);        /* drop the initial filter delay */
}
/* One producer step: top up the carry block from the source, resample into the ring. */
static void stream_produce(void){
    while (rs_in_frames < 1024 && !g_src_end){
        int16_t l, r;
        if (!src_next(&l, &r)) { g_src_end = 1; rs_flush = 256; break; }   /* EOF: flush tail with silence */
        rs_in[2*rs_in_frames] = l; rs_in[2*rs_in_frames+1] = r; rs_in_frames++;
    }
    if (g_src_end && rs_flush > 0 && rs_in_frames < 1024){
        uint32_t add = 1024 - rs_in_frames; if (add > (uint32_t)rs_flush) add = (uint32_t)rs_flush;
        for (uint32_t i = 0; i < add; i++){ rs_in[2*rs_in_frames] = 0; rs_in[2*rs_in_frames+1] = 0; rs_in_frames++; }
        rs_flush -= (int)add;
    }
    if (rs_in_frames){
        uint32_t freef = rb_free(); if (freef <= 260u) return;             /* ring full enough */
        spx_uint32_t in = rs_in_frames;
        spx_uint32_t out = freef - 260u; if (out > 2048u) out = 2048u;
        speex_resampler_process_interleaved_int(g_spx, rs_in, &in, rs_out, &out);
        for (spx_uint32_t i = 0; i < out; i++){
            last_l = rs_out[2*i]; last_r = rs_out[2*i+1];
            rb_push(last_l, last_r); p_samples++;
        }
        if (in < rs_in_frames){                                            /* carry unconsumed input */
            uint32_t rem = rs_in_frames - in;
            for (uint32_t i = 0; i < rem; i++){ rs_in[2*i] = rs_in[2*(in+i)]; rs_in[2*i+1] = rs_in[2*(in+i)+1]; }
            rs_in_frames = rem;
        } else rs_in_frames = 0;
    }
    if (g_src_end && rs_flush == 0 && rs_in_frames == 0){                  /* everything delivered */
        /* Raised-cosine-smooth end declick: fade the held last sample to zero over the FULL 256-sample
           window with a C1 (zero-slope) landing, not a ~1.7 ms geometric spike. w^2 ~ half-Hann; libm-free.
           No music dropped - this tail follows the last real sample. */
        for (int i = 1; i <= 256 && rb_free() > 4u; i++){
            int w = 256 - i;                                               /* 255..0 */
            int wl = (int)(((int64_t)last_l * w * w) >> 16);               /* (w/256)^2 * last */
            int wr = (int)(((int64_t)last_r * w * w) >> 16);
            rb_push((int16_t)wl, (int16_t)wr);
        }
        prod_done = 1;
    }
}

/* ---------------- transport ---------------- */
static void consumer_stop_now(void){        /* IRQ-safe teardown of the consumer + mux */
    Xil_ExceptionDisable();
    c_on = 0; AUDIO_CTRL = 0; pace_hold = 0; a_gain = 0; a_target = 0;
    rb_r = rb_w;                            /* flush unplayed samples */
    g_idle_muxup = 0;                       /* mux released */
    Xil_ExceptionEnable();
}
static void source_close(void){
    if (g_fmt == FMT_MP3) mp3_close(); else f_close(&g_pf);
}
/* Fade out + free the CURRENT source but KEEP the audio mux engaged, so a track change never lets the
   fabric machine audio crossfade in (no ZX blip, no idle-DC thump on either mux edge). The ISR keeps the
   FIFO topped with silence until track_arm() arms the next track (-> gapless) or the grace timer in
   player_pump releases the mux at a true playlist end. No music dropped: the fade finishes first. */
static void source_teardown_muxup(int already_silent){
    if (!already_silent){
        a_target = 0;
        XTime t0, t; XTime_GetTime(&t0);
        while (a_gain > 0){ if(!audio_irq_on) player_isr_tick();
            XTime_GetTime(&t); if ((uint64_t)(t - t0) > (uint64_t)COUNTS_PER_SECOND/50u) break; }  /* 20 ms */
    }
    Xil_ExceptionDisable();
    g_samples = 0;                          /* reset elapsed clock + stop false-underrun counting */
    rb_r = rb_w;                            /* flush any unplayed audio */
    a_gain = 0; a_target = 0; pace_hold = 0;
    Xil_ExceptionEnable();                  /* c_on & AUDIO_CTRL stay 1 -> ISR feeds silence, machine muted */
    g_playing = 0; prod_done = 0;
    source_close();
    if (g_spx){ speex_resampler_destroy(g_spx); g_spx = 0; }
    g_idle_muxup = 1; XTime_GetTime(&g_idle_t0);
}
/* Prepare a NEW track. Playing -> tear down WITHOUT dropping the mux (gapless). Stopped -> nothing to
   fade (track_arm engages the mux normally). Idle-muxup -> mux already up, proceed to track_arm. */
static void player_begin_new(void){
    if (g_playing) source_teardown_muxup(0);
}
/* Fade out (consumer-side, ~5.3 ms) then cut the mux. Bounded: never blocks >20 ms. */
void player_stop(void){
    if (g_idle_muxup){ consumer_stop_now(); return; }   /* EOF-idle: source already freed, only drop the mux */
    if (!g_playing) return;
    a_target = 0;
    XTime t0, t; XTime_GetTime(&t0);
    while (a_gain > 0) {                                     /* consumer ramps down while draining */
        if (!audio_irq_on) player_isr_tick();                /* polled fallback: tick inline */
        XTime_GetTime(&t);
        if ((uint64_t)(t - t0) > (uint64_t)COUNTS_PER_SECOND/50u) break;   /* 20 ms bound */
    }
    /* ANTI-POP 4a: let the faded ramp DRAIN through the 256-deep (5.3 ms) fabric FIFO to the DAC BEFORE
       releasing the mux. The a_gain fade == one FIFO depth, so without this the wire still carries
       full-amplitude audio at the cut and the fabric's HOLD-LAST freezes it as a DC pedestal -> loud
       low-freq pop through the final DC-blocker. Draining also leaves the FIFO EMPTY, so the next
       track_arm can't replay a stale full-amplitude fragment (kills the START pop too). No audio lost. */
    c_on = 0;                                                /* ISR stops refilling; mux stays on so the FIFO drains out */
    XTime_GetTime(&t0);
    while (!(AUDIO_STAT & 0x1u)) {                            /* wait until the fabric FIFO is EMPTY (last drained ~= 0) */
        XTime_GetTime(&t);
        if ((uint64_t)(t - t0) > (uint64_t)COUNTS_PER_SECOND/100u) break;   /* 10 ms bound */
    }
    consumer_stop_now();
    g_playing = 0; prod_done = 0;
    source_close();
    if (g_spx){ speex_resampler_destroy(g_spx); g_spx = 0; }   /* free the resampler heap */
}
static void track_arm(void){                /* common start-of-track state (all formats) */
    Xil_ExceptionDisable();
    rb_r = rb_w;                            /* empty ring */
    g_samples = 0; p_samples = 0; last_l = last_r = 0;
    a_gain = 0; a_target = 256;             /* fade-in from silence */
    pace_hold = 0; prod_done = 0;
    g_idle_muxup = 0;                       /* NEW: mux was already up (gapless) or off (normal start) */
    g_playing = 1; g_paused = 0; g_ended = 0;
    c_on = 1;
    Xil_ExceptionEnable();
    AUDIO_CTRL = 1;                         /* mux to player (ring still silent -> no step) */
}

/* Start playing a .psg file. Returns 1 on success. */
int player_play_psg(const char* path){
    player_begin_new();
    if (f_open(&g_pf, path, FA_READ) != FR_OK) return 0;
    g_blen = g_bpos = 0;
    unsigned bstart = 16;                   /* "PSG" 0x1A hdr; quirk: Version 0xFF -> body at 4 */
    { uint8_t hdr[16] __attribute__((aligned(32))); UINT hr = 0;
      if (f_read(&g_pf, hdr, sizeof(hdr), &hr) != FR_OK || hr < 16) { f_close(&g_pf); return 0; }
      if (hdr[4] == 0xFF) bstart = 4; }
    if (f_lseek(&g_pf, bstart) != FR_OK) { f_close(&g_pf); return 0; }
    g_blen = g_bpos = 0;
    for (int i = 0; i < 16; i++) ay_regs[i] = 0;
    g_total_frames = 0;                     /* pre-scan -> exact duration (ZXTune frame counting) */
    for (;;) { int p = psg_next_frame(); if (p <= 0) break; g_total_frames += (uint64_t)p; }
    if (g_total_frames == 0) g_total_frames = 1;
    if (f_lseek(&g_pf, bstart) != FR_OK) { f_close(&g_pf); return 0; }
    g_blen = g_bpos = 0;
    for (int i = 0; i < 16; i++) ay_regs[i] = 0;
    ayumi_configure(&g_ay, 0, AY_CLOCK, PLAYER_SR);
    ayumi_set_pan(&g_ay, 0, 0.5, 0);
    ayumi_set_pan(&g_ay, 1, 0.5, 0);
    ayumi_set_pan(&g_ay, 2, 0.5, 0);
    g_frame = 0; g_next_frame_at = 0; g_hold = 0;
    g_fmt = FMT_PSG;
    track_arm();
    return 1;
}

/* Start streaming a .wav (PCM 8/16-bit, mono/stereo, any rate). Returns 1 on success. */
int player_play_wav(const char* path){
    player_begin_new();
    if (f_open(&g_pf, path, FA_READ) != FR_OK) return 0;
    uint8_t h[12]; UINT hr = 0;
    if (f_read(&g_pf, h, 12, &hr) != FR_OK || hr < 12 ||
        h[0]!='R'||h[1]!='I'||h[2]!='F'||h[3]!='F'||h[8]!='W'||h[9]!='A'||h[10]!='V'||h[11]!='E') { f_close(&g_pf); return 0; }
    uint32_t data_off = 0, data_len = 0; int got_fmt = 0;
    for (;;) {
        uint8_t ch[8]; UINT r = 0;
        if (f_read(&g_pf, ch, 8, &r) != FR_OK || r < 8) break;
        uint32_t clen = rd_u32le(ch+4);
        if (ch[0]=='f'&&ch[1]=='m'&&ch[2]=='t'&&ch[3]==' ') {
            uint8_t fm[40]; UINT fr = 0; UINT want = clen>40?40:clen;
            if (f_read(&g_pf, fm, want, &fr) != FR_OK || fr < 16) { f_close(&g_pf); return 0; }
            g_wav_ch  = (int)rd_u16le(fm+2);
            g_wav_sr  = rd_u32le(fm+4);
            g_wav_bps = (int)rd_u16le(fm+14) / 8;
            got_fmt = 1;
            if (clen > want) f_lseek(&g_pf, f_tell(&g_pf) + (clen - want));
        } else if (ch[0]=='d'&&ch[1]=='a'&&ch[2]=='t'&&ch[3]=='a') {
            data_off = f_tell(&g_pf); data_len = clen; break;
        } else {
            f_lseek(&g_pf, f_tell(&g_pf) + clen + (clen & 1));
        }
    }
    if (!got_fmt || data_len == 0 || g_wav_ch < 1 || (g_wav_bps != 1 && g_wav_bps != 2)) { f_close(&g_pf); return 0; }
    if (f_lseek(&g_pf, data_off) != FR_OK) { f_close(&g_pf); return 0; }
    stream_reset();
    g_wav_total = data_len; g_wav_read = 0;
    g_src_sr = (double)g_wav_sr;
    g_rs_frac = 0.0; g_rs_init = 0; g_src_eof = 0;
    g_fmt = FMT_WAV;
    spx_start();                       /* polyphase sinc resampler (linear fallback if init fails) */
    track_arm();
    return 1;
}

/* Start streaming an .mp3 (minimp3; duration from the Xing/Info/VBRI header). Returns 1 on success. */
int player_play_mp3(const char* path){
    player_begin_new();
    if (!mp3_open(path)) return 0;
    g_wav_ch = mp3_ch();
    g_src_sr = (double)mp3_sr();
    g_rs_frac = 0.0; g_rs_init = 0; g_src_eof = 0;
    g_fmt = FMT_MP3;
    spx_start();                       /* polyphase sinc resampler (linear fallback if init fails) */
    track_arm();
    return 1;
}

int player_active(void){ return g_playing; }
int player_paused(void){ return g_paused; }
int player_take_ended(void){ int e = g_ended; g_ended = 0; return e; }

/* Pause: fade out in the consumer, then freeze (pace_hold). Resume: fade back in from the held position. */
void player_pause_toggle(void){
    if (!g_playing) return;
    if (!g_paused) { g_paused = 1; a_target = 0; }          /* fade out; ISR freezes (pace_hold) at silence */
    else {                                                  /* resume from the held ring position */
        a_target = 256;                                     /* set the fade-in target FIRST ... */
        g_paused = 0;
        pace_hold = 0;                                      /* ... then release the freeze so the ISR wakes clean */
    }
}

/* ---------------- PRODUCER: main-loop pump (decode into the ring; consumer feeds the fabric) ---------------- */
void player_pump(void){
    if (!audio_irq_on && (g_playing || g_idle_muxup)) player_isr_tick();          /* polled fallback: consume inline too */
    if (g_idle_muxup){                             /* between tracks: mux up, feeding silence */
        XTime now; XTime_GetTime(&now);
        if ((uint64_t)(now - g_idle_t0) > (uint64_t)COUNTS_PER_SECOND/4u)  /* 250 ms grace = playlist end */
            consumer_stop_now();                   /* single clean edge back to the machine (4b = thump-free) */
        return;
    }
    if (!g_playing) return;
    if (prod_done) {                               /* source finished: wait for the ring to drain */
        if (rb_count() == 0) {
            source_teardown_muxup(1);              /* ring incl. decay tail fully played -> free source, mux up */
            g_ended = 1;                           /* natural EOF -> auto-advance */
        }
        return;
    }
    if (g_paused) return;                          /* producer idles; ring keeps its content */
    if (g_fmt == FMT_WAV) stream_refill();         /* cheap top-up (bursts are harmless at producer level) */
    else if (g_fmt == FMT_MP3) mp3_refill();
    if (g_fmt != FMT_PSG && g_spx) {               /* WAV/MP3 via speex: fill the ring to its high watermark */
        int guard = 2;                             /* SMOOTH quanta: keep each pump ultra-short (~ms) so the main loop stays
                                                      instantly responsive to keys (Backspace/Space). The deep ring
                                                      refills over many fast pumps; stall-absorption = ring DEPTH, not
                                                      this cap. (guard=16/256 blocked the loop -> laggy keys.) */
        while (rb_count() < RB_HIGH_WM && !prod_done && guard-- > 0)
            stream_produce();
        return;
    }
    int budget = 2048;                             /* PSG (native-rate synth) or linear fallback: per-sample */
    while (budget-- > 0 && rb_free() > 260u) {     /* keep headroom so rb_w never laps rb_r */
        int16_t l, r;
        int ok = (g_fmt == FMT_PSG) ? render_one_psg(&l, &r) : render_one_stream(&l, &r);
        if (!ok) {                                 /* source EOF: push a short decay tail (kills the end step) */
            /* Raised-cosine-smooth end declick: fade the held last sample to zero over the FULL 256-sample
               window with a C1 (zero-slope) landing, not a ~1.7 ms geometric spike. w^2 ~ half-Hann; libm-free.
               No music dropped - this tail follows the last real sample. */
            for (int i = 1; i <= 256 && rb_free() > 4u; i++){
                int w = 256 - i;
                int wl = (int)(((int64_t)last_l * w * w) >> 16);
                int wr = (int)(((int64_t)last_r * w * w) >> 16);
                rb_push((int16_t)wl, (int16_t)wr);
            }
            prod_done = 1;
            break;
        }
        last_l = l; last_r = r;
        rb_push(l, r);
        p_samples++;
    }
}

/* ---------------- info for the player window ---------------- */
unsigned player_elapsed_s(void){ return (unsigned)(g_samples / (uint64_t)PLAYER_SR); }   /* consumed = heard */
unsigned player_total_s(void){
    if (g_fmt == FMT_PSG) return (unsigned)(g_total_frames / FRAME_HZ);
    if (g_fmt == FMT_MP3) return mp3_total_s();
    { uint32_t fb = (uint32_t)g_wav_bps * (uint32_t)g_wav_ch; if(!fb||!g_wav_sr) return 0; return (unsigned)(g_wav_total / fb / g_wav_sr); }
}
unsigned player_progress(void){
    unsigned t = player_total_s(), e = player_elapsed_s();
    if (!t) return 0; unsigned p = e * 100u / t; return p > 100u ? 100u : p;
}
int      player_fmt(void){ return g_fmt; }                 /* 0=PSG 1=WAV 2=MP3 */
unsigned player_src_sr(void){ if (g_fmt==FMT_PSG) return 0; if (g_fmt==FMT_MP3) return mp3_sr(); return g_wav_sr; }
unsigned player_src_ch(void){ if (g_fmt==FMT_PSG) return 0; if (g_fmt==FMT_MP3) return (unsigned)mp3_ch(); return (unsigned)g_wav_ch; }
unsigned player_bitrate_kbps(void){ if (g_fmt==FMT_MP3) return mp3_bitrate();
    if (g_fmt==FMT_WAV) return (unsigned)(((uint64_t)g_wav_sr*(uint32_t)g_wav_ch*(uint32_t)g_wav_bps*8u)/1000u);
    return 0; }
