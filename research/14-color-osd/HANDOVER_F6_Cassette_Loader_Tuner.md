# HANDOVER: F6 Cassette Loader Tuner — OSD Freeze Bug

**Date**: 2026-07-03  
**Project**: BulbuLator Step 14 (research/14-color-osd)  
**File**: `BulbuLator/research/14-color-osd/arm/loader_main.c`  
**Symptom**: After F5 (opens browser), F6 causes OSD to "hang/freeze". Nothing updates, F-keys (except F11) stop responding. Only F11 works.

**Reproduction**:
1. Power on / flash.
2. F5 → browser window.
3. F6 → freeze, no display update, other F-keys dead.

---

## Root Causes (from detailed swarm analysis + code traces)

1. **Tuner is a hacky overlay, not a proper view**
   - Uses independent flag `mp3_tuner_on` instead of integrating with `osd_view` / `toggle_view` / `open_*` / `close_osd`.
   - Does not save/restore previous view state (`osd_view`, `browser_on`, `opt_on`, `osd_on`).

2. **Stale `osd_view` left by F5**
   - F5 sets `osd_view=3`, `browser_on=1`.
   - F6 open only stomps `browser_on/opt_on`, does `osd_clear` + `OSD_CTRL |=1u`, but leaves `osd_view=3`.
   - On close: no restore of previous view.
   - Next F5 sees `osd_view==3` → `close_osd()` instead of opening → appears as "no reaction".

3. **Multiple overlapping F6 handlers + aggressive `continue;`**
   - Tuner input block (when `mp3_tuner_on`): consumes arrows/F6 with `continue`.
   - Early F-key handlers (F12/F1/F5/F9/F6): make-only, force `mp3_tuner_on=0`, `continue`.
   - Legacy `case SC_F6` in switch (now mostly dead).
   - Many `continue;` skip mkey updates, release handling, and post-processing.

4. **1bpp tuner vs DDR player layering (bit1)**
   - Tuner draws to 1bpp `osdbuf` + bit0 (`osd_blit`).
   - Player window is DDR true-color (bit1), composited **on top**.
   - If `winamp_on` not hidden, tuner text is invisible or looks frozen.
   - Asymmetric save/restore of `winamp_on` (only in some F6 close paths).

5. **Drawing timing and lack of full cleanup**
   - Tuner draw block is **before** `d = KBD_DATA`.
   - On F6 open: set flag + `continue` → actual `draw_text + osd_blit` deferred to next loop.
   - On close (especially via input block): often no `osd_clear` + `osd_blit` of previous content.
   - No re-render of previous view (browser) on F6 close.
   - Y overflow in tuner draw (starts ~40, 14 lines → > OSD_H=128, clips).

6. **Why only F11 works**
   - F11 is handled **before** early F-block and tuner logic.
   - No `continue`.
   - Forces `update_banner()` (works on color layer).
   - Other F-keys hit the corrupted state machine.

Additional:
- `mkey` can be left stale (early paths bypass normal mkey logic).
- No mutual exclusion with player or banner.
- Drawing every frame (before optimization) caused CPU/visual freeze; now lazy but still no proper restore.

---

## What Was Implemented So Far (as of 2026-07-03)

- `close_tuner_overlay()` helper + `tuner_saved_winamp`.
- Early handlers for F1/F5/F9/F12/F6 now call `close_tuner_overlay()` before toggle.
- On F6 open (turning on): save `prior_*`, set `browser_on=0`, `opt_on=0`, hide player (bit1), `osd_clear()`, `OSD_CTRL |=1u`, `needs_redraw=1`.
- Lazy redraw: `if (mp3_tuner_on && tuner_needs_redraw) { osd_select(); draw...; osd_blit(); needs=0; }`
- Tuner input block only consumes arrows + F6 (others fall through to early handlers).
- Boot force-clean + player stop.
- Fixed Y increments in tuner draw (start y=8, step=8 to fit in 128 lines).
- Added `prior_*` save/restore in `close_tuner_overlay()` (latest).

**Remaining gaps** (see recommended fixes):
- Full view save/restore using `osd_view`.
- Symmetric cleanup on **all** close paths (including when other F pressed while tuner on).
- Ensure re-render of previous content on close.
- Remove vestigial switch case for SC_F6.
- Possibly move tuner draw or add force-redraw on close.

---

## Current Code Locations (key excerpts)

**Globals (around line 442+):**
```c
static int mp3_tuner_on = 0;
static int tuner_sel = 0;
static int tuner_needs_redraw = 0;
static int tuner_saved_winamp = 0;
static int prior_osd_view = 0;
static int prior_browser_on = 0;
static int prior_opt_on = 0;
static int prior_osd_on = 0;

static void close_tuner_overlay(void){
    if(!mp3_tuner_on) return;
    mp3_tuner_on = 0; tuner_sel=0; tuner_needs_redraw=0;
    osd_clear(); osd_blit(); OSD_CTRL &= ~1u;
    if(tuner_saved_winamp){ winamp_on=1; OSD_CTRL |= 2u; update_banner(); }
    tuner_saved_winamp = 0;
    browser_on = prior_browser_on;
    opt_on = prior_opt_on;
    osd_on = prior_osd_on;
    osd_view = prior_osd_view;
    if(browser_on){ render_browser(); }
    // ... (see full function)
}
```

**Tuner drawing (before KBD_DATA read):**
```c
if (mp3_tuner_on && tuner_needs_redraw) {
    osd_select();
    int y = 8;
    draw_text(10, y, 1, "=== CASSETTE LOADER TUNER (F6=close) ===");
    y += 8;
    ... (14 param lines with itoa_u + draw_text, y+=8)
    draw_text(...);
    osd_blit();
    tuner_needs_redraw = 0;
}
```

**Tuner input block (after d = KBD_DATA):**
```c
if (mp3_tuner_on && !(d & 0x100u)) {
    ... code, release, is_arrow ...
    if (!release) {
        if (code == SC_F6) {
            close_tuner_overlay();
            continue;
        }
        if (is_arrow) {
            ... update values ...
            tuner_needs_redraw = 1;
            continue;
        }
    }
    /* non-arrow, non-F6 fall through */
}
```

**Early F6 handler (after F11):**
```c
if(code==SC_F6 && !(d & 0x200u)){
    if(!mp3_tuner_on){
        prior_osd_view = osd_view;
        prior_browser_on = browser_on;
        prior_opt_on = opt_on;
        prior_osd_on = osd_on;
        browser_on = 0;
        opt_on = 0;
        tuner_saved_winamp = winamp_on;
        if (winamp_on) { winamp_on = 0; OSD_CTRL &= ~2u; }
        osd_clear();
        OSD_CTRL |= 1u;
        mp3_tuner_on = 1; tuner_sel=0; tuner_needs_redraw = 1; continue;
    } else {
        close_tuner_overlay();
        continue;
    }
}
```

**Early F5 etc. (now call close):**
```c
if(code==SC_F5 && !(d & 0x200u)){ close_tuner_overlay(); toggle_view(3); continue; }
```

**Legacy switch (still has old case):**
```c
case SC_F6:   if(!release){ mp3_tuner_on = !mp3_tuner_on; tuner_sel=0; } break;
```

**Boot reset (around 1986):**
```c
mp3_tuner_on = 0;
tuner_sel = 0;
tuner_needs_redraw = 0;
tuner_saved_winamp = 0;
prior_osd_view = 0;
... 
winamp_on = 0;
...
```

---

## Recommended Next Steps (to continue)

1. **Make tuner a real view**:
   - Use or extend `osd_view` (e.g. 5 for tuner).
   - Save full prior state on open.
   - On close: restore `osd_view`, flags, and force re-render of previous view.

2. **Strengthen close_tuner_overlay**:
   - Always do full `osd_clear(); osd_blit(); OSD_CTRL &= ~1u;`
   - Restore priors + call `render_browser()` / appropriate re-open.
   - Call it from **all** paths that should close tuner (early F*, input F6, perhaps close_osd).

3. **Clean up duplication**:
   - Remove or neutralize legacy `case SC_F6` in switch.
   - Ensure early handlers + tuner-input are the canonical paths.

4. **Layer hygiene**:
   - On tuner open: hide bit1 (player) if active.
   - On close: restore bit1 state.
   - Consider drawing tuner into the color canvas (osdc) for future-proofing.

5. **Drawing robustness**:
   - Targeted clear before tuner text (prevent ghosts).
   - Keep y safe (already fixed to start 8 / +8).
   - Optional: force redraw on close if previous view needs it.

6. **Test matrix**:
   - F5 → F6 (show tuner) → arrows → F6 (close) → F5 (should reopen browser cleanly).
   - F5 → F6 → F1/F9/F12/F5.
   - F6 twice.
   - During MP3 tape load.
   - After F11.

7. **Build/Flash**:
   ```bash
   cd /home/lavrinovich/bulb-v13/research/14-color-osd
   ./arm/build_loader.sh
   cp .../loader.elf arm/
   ./loader_run.sh
   ```

---

## Obsidian / Notes Check (2026-07-03)

- Notes live in `BulbuLator/research/14-color-osd/notes/`
- Only relevant file: `powadcr-study.md`
- It contains good history on:
  - POWADCR ideas for DATA mode / 3-band EQ.
  - Introduction of the 9 tunable params (alpha, lockout, ..., eq_high_gain).
  - F6 as live tuner for turbo MP3 testing.
  - Some code snippets and "Test with F6 while loading".
- **Status**: Partially up-to-date for the *feature* (tuner params and POWADCR inspiration), but **missing**:
  - The F6 key-handling freeze bug.
  - State machine issues (stale osd_view, view integration).
  - Layering problems (1bpp vs bit1).
  - Fixes applied (prior_* save/restore, close_tuner_overlay, early handlers, lazy redraw).
  - Exact reproduction, traces, and remaining TODOs.
- **Recommendation**: 
  - Create or update a dedicated note: `F6_Tuner_Debugger.md` or append a "Known Issues & Handover" section to powadcr-study.md or a new `OSD_Key_Handling.md`.
  - Cross-link this HANDOVER file.
  - Keep the POWADCR study focused on EQ/filter ideas; move debug history here.

**Suggested Obsidian update snippet** (add to relevant note):
> **2026-07-03 Update**: F6 tuner (debug overlay) has key-handling bugs causing freeze after F5. See [[HANDOVER_F6_Cassette_Loader_Tuner]] or the root HANDOVER file. Main issues: stale osd_view, incomplete close paths, 1bpp under player layer. Fixes in progress: prior state save, close_tuner_overlay, view integration.

---

## Quick Commands for Next Developer

```bash
# On thinkpad (build + flash)
cd /home/lavrinovich/bulb-v13/research/14-color-osd
./arm/build_loader.sh
cp /home/lavrinovich/sdboot/ws/loader/Debug/loader.elf arm/
./loader_run.sh

# On Mac (sync changes)
rsync -av BulbuLator/research/14-color-osd/arm/loader_main.c thinkpad:/home/lavrinovich/bulb-v13/research/14-color-osd/arm/

# Test sequence on board
F5 (browser)
F6 (tuner)
arrows (should update values)
F6 (close)
F5 (should work again)
```

---

**End of Handover**. Everything needed to continue is here or in the linked code + subagent traces. The core is making the tuner a first-class, state-safe view with proper open/close semantics and layer management.

If starting a new session: copy this file + the current `loader_main.c` and pick up from "Recommended Next Steps".
