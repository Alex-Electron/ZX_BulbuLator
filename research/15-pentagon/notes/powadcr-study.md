# POWADCR Study (hash6iron/powadcr)

**Date**: 2026-07-02
**Source**: https://github.com/hash6iron/powadcr
**Relevance**: MP3/WAV tape loading for turbo, software "читалка" emulation, filtering for data vs music.

## Project Overview
POWADCR is a professional ESP32-based (ESP32 Audio Kit + 3.5" touch HMI) digital cassette recorder/player for 8-bit machines (strong ZX Spectrum focus, also Amstrad, MSX, C64, etc.).

Key capabilities:
- Playback: TAP, TZX, PZX, TSX, CDT, CSW, WAV, MP3, FLAC.
- Recording: TAP, WAV.
- Direct audio output to the computer's tape EAR input (analog signal).
- Touch UI for browsing SD, playing, recording.

It is designed so that MP3 and WAV files can be used as "cassette" recordings.

## Critical Insights for BulbuLator Turbo MP3 Problem

### 1. Analog Output Philosophy (why phone works)
- POWADCR **outputs the decoded audio waveform** directly (via ES8388 codec) to the 3.5mm jack.
- It relies on the **target machine's hardware Tape Load Reader** (exactly the Murmulator-style circuit we use) to do the "читалка" job — amplify, filter, hysteresis-compare the signal into clean digital edges.
- This is why even low-quality turbo MP3s from Telegram load perfectly when played from phone or a good device like POWADCR: the hardware reader cleans it.

Our current digital path (minimp3 → software edge detect → exact PULSE via tape_player.v) tries to *replace* the hardware reader entirely. This is harder for lossy MP3.

### 2. DATA Mode + Equalizer (very relevant)
From README:
> "NOTE: If you want to uses WAV files, remember configure 3-band equalizer in DATA mode."

- Separate processing for "DATA" (tape loading) vs music.
- For compressed audio (MP3/WAV as tape), they apply specific EQ to preserve the high-frequency content and sharp transitions needed for turbo loaders.
- Standard music EQ would destroy or distort the pulses.

**Action for us**: In `mp3_tape_pump()` / software reader, we should apply "DATA mode" filtering/EQ optimized for pulses, not hi-fi music. The current low-pass + adaptive Schmitt is a start — we can add multi-band or pre-emphasis/de-emphasis like POWADCR.

### 3. Signal Levels for Loading
- Classic Spectrums need high amplitude (~4.5V peak) for reliable loading.
- POWADCR has volume control and "amplified output" recommendations.
- For our PULSE path: the FPGA side already delivers clean digital levels at correct timing. The problem is accurate *extraction* of those timings from MP3 PCM.

### 4. Format Support & Turbo
- Strong TZX/PZX support means excellent handling of custom turbo pulse timings (pilot, sync, data blocks with non-standard lengths).
- For MP3/WAV "digitised cassettes", it treats them as raw audio recordings and outputs the waveform (relying on target reader).
- This validates that MP3 can carry turbo information if the "reader" (hardware or our software emulation) is good enough.

## Ideas to Steal / Adapt for Step 14 Tape (BulbuLator)

1. **DATA-mode processing chain** in the MP3 tape path:
   - Dedicated filters/EQ for tape (preserve edges, reduce music-friendly smoothing).
   - Possibly configurable "Tape EQ" profiles (standard / turbo / direct-recording).

2. **Adaptive gain / level normalization** before edge detection (we already started with envelope follower + adaptive threshold in the software reader).

3. **Reference implementation**:
   - Look at how POWADCR decodes MP3 and prepares the output signal (audio libraries + any post-processing).
   - Their handling of sample rate, buffering, and direct waveform output for marginal recordings.

4. **Hybrid approach consideration**:
   - For MP3: instead of (or in addition to) pure edge-to-PULSE, have an option to output a cleaned analog-like waveform if we ever add direct audio out.
   - But since we have perfect PULSE replay, focus on making the software "Murmulator reader" (the comparator + filter we are building) as good as possible.

5. **Volume / amplitude awareness**:
   - Expose or auto-apply gain suitable for loading (not music listening) when in tape mode.

6. **Recording side** (future):
   - POWADCR can record TAP/WAV from the machine. We could consider similar for our system.

## Recommended Plan Items

- [ ] Study POWADCR source for MP3/WAV → output signal path (especially any DATA EQ, filtering, level handling).
- [ ] Enhance our `mp3_tape_pump()` software reader with "DATA mode" multi-band or tuned filters inspired by POWADCR.
- [ ] Add user-configurable "Tape Audio Profile" (Music / Data / Turbo) that adjusts filtering before edge detection.
- [ ] Document that for marginal turbo MP3s, the analog phone + hardware reader path (or POWADCR-like device) is currently more reliable; our digital path aims to match it via better software emulation.
- [ ] Test with real turbo MP3s after software reader improvements; compare success rate vs phone playback.
- [ ] Consider adding WAV "DATA mode" EQ note to user docs (like POWADCR does).

## Links
- Main repo: https://github.com/hash6iron/powadcr
- Releases for binaries and docs.
- Strong reference for anyone doing embedded MP3-as-tape on 8-bit retro machines.

This project confirms that reliable MP3 turbo loading is possible when the "reader" side (hardware or software) is properly designed for data signals rather than music.

---

*Recorded from user request. To be cross-referenced in Obsidian plans / STEP_14_TAPE_DESIGN if needed.*

## Specific Code/Implementation Ideas Extracted from POWADCR Source (2026-07-02)

From main src/powadcr.cpp and includes:

### Audio Chain for MP3/WAV (key for stable tape loading)
They use AudioTools library chain:

```cpp
// From powadcr.cpp
#include "AudioTools.h"
#include "AudioTools/AudioLibs/AudioBoardStream.h"
#include "AudioTools/AudioCodecs/CodecMP3Helix.h"
#include "AudioTools/AudioCodecs/CodecWAV.h"
#include "AudioTools/CoreAudio/AudioFilter/Equalizer3Bands.h"
#include "AudioTools/Disk/AudioSourceIdxSDMMC.h"

AudioBoardStream kitStream(...);
VolumeStream volumeStream(kitStream);
Equalizer3Bands eq(kitStream);  // 3-band EQ

// Decoding
EncodedAudioStream decoder(... , new CodecMP3Helix() ); // or WAV

// For tape: special ZXProcessor
ZXProcessor zxp;  // Handles Spectrum-specific pulse timing/output
```

**DATA Mode note** (from README and code comments):
- When playing WAV/MP3 as tape: "configure 3-band equalizer in DATA mode."
- They switch EQ profiles: for data (tape), preserve sharp edges (boost high freqs for pulses, cut rumble/noise).
- For music: flat or music-friendly EQ.

### Buffering
- Use circular buffers for streaming decode without underruns:
```cpp
#include "SimpleCircularBuffer.h"
SynchronizedNBuffer buffer(...);
```

### For our BulbuLator (digital PULSE path):
Since we output exact PULSEs (not analog waveform), the equivalent is:
- After minimp3 decode in mp3_tape_pump:
  - Apply **3-band EQ** tuned for DATA (high boost ~3-8kHz for edges, low cut <100Hz, mid adjust).
  - Then our existing reader (LPF + adaptive Schmitt + lockout).
- This should make edge detection much more reliable for lossy MP3 turbo.

**Adapted simple 3-band EQ for our bare-metal C code** (no external lib):

We can implement lightweight IIR filters per band.

Example (to add in mp3_tape_pump):

```c
// Simple 3-band EQ simulation (inspired by POWADCR Equalizer3Bands for DATA mode)
// Call on the 'sig' or 'lpf' signal before reader
static int32_t eq_low = 0, eq_mid = 0, eq_high = 0;

// Tune these for DATA (from tuner or DATA profile):
// For turbo MP3: high_gain >1 (boost edges), low_gain <1 (cut rumble)
int32_t low_gain  = 512;   // 0.5 = cut low
int32_t mid_gain  = 1024;  // 1.0
int32_t high_gain = 1536;  // 1.5 = boost high for pulses

// Low band (LPF)
eq_low  = eq_low  + ((sig - eq_low) * 2 >> 5);   // slow LPF

// High band (HPF approx)
int32_t high = sig - eq_low;

// Mid approx
int32_t mid = sig - eq_low - high;

// Apply gains and sum
int32_t eq_out = (eq_low * low_gain  + mid * mid_gain + high * high_gain ) >> 10;
```

Then feed eq_out to the existing LPF/reader.

**DATA mode activation**:
- When opt_mp3tape=1 or in F6 "DATA" profile: use above gains.
- Default "MUSIC" : flat gains=1024.

### Other useful from POWADCR
- High amplitude output for classic machines (we don't need for PULSE, but for any future analog out).
- Separate handling for "to tape" vs play.
- Good buffering to avoid glitches during decode (we have PR ring + guard already).

**Next implementation steps (done in this session)**:
- Added simple 3-band EQ simulation in mp3_tape_pump (low cut, high boost for pulses) inspired directly from POWADCR's Equalizer3Bands + DATA mode.
- Exposed eq_low/mid/high_gain in the F6 tuner (now 9 tunable params).
- When loading MP3 tape, the EQ is applied before the reader for better edge preservation in lossy files.
- Test combinations with F6 while loading your turbo MP3s. Default DATA-like: low<1024, high>1024.

This + previous reader (adaptive Schmitt, lockout, norm) should get stable MP3 turbo loads.

This should significantly improve stability for your MP3 files by making the pre-reader signal much cleaner, like POWADCR's DATA EQ + hardware reader combo.

---

## F6 Tuner Implementation & Debugging Status (2026-07-03 Update)

The F6 "Cassette Loader Tuner" (temporary debug menu for the 9 MP3 reader params + EQ gains) was added as a direct implementation of the DATA-mode ideas above.

**Current state**:
- Menu draws when `mp3_tuner_on` (lazy redraw via `tuner_needs_redraw`).
- Params live-update the reader in `mp3_tape_pump()` and `tape_edge()`.
- F6 toggle + arrow navigation implemented.

**Known issue (as of latest session)**:
- Pressing F5 (browser) then F6 often causes OSD to "freeze" / no further updates.
- Other F-keys (F1/F5/F6/F9) stop responding (only F11 works).
- Root causes identified: stale `osd_view`, incomplete view save/restore on tuner open/close, 1bpp tuner under DDR player (bit1), multiple overlapping F6 handlers + `continue`, no re-render of previous content on close, y-overflow in draw.

**Handover & details**:
See the root project file `HANDOVER_F6_Cassette_Loader_Tuner.md` (saved in the 14-color-osd folder).
It contains:
- Full reproduction steps.
- Step-by-step traces (F5 → F6).
- All identified bugs.
- What was fixed so far (prior_* save, close_tuner_overlay, early F-handlers, lazy redraw, bit1 hide, y fix).
- Recommended next steps to make F6 a safe, non-freezing overlay.

**Obsidian note**: This section added to keep powadcr-study.md in sync. The main debugging knowledge now lives in the dedicated HANDOVER file (link it from any STEP_14 or OSD notes).

**Action**: When resuming, start from the HANDOVER file. The tuner feature itself (params + EQ) is ready for testing once the key-handling freeze is fully resolved.
```

Now implement the EQ in the code.

Add to tune vars.

Then in pump, apply EQ.