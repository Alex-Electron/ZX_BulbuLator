# Handover: Sinclair 48K Video Pipeline & SHOK Megademo Investigation (2026-09-03)

## 1. Executive Summary

During this session, we addressed the video and timing discrepancies on the Sinclair 48K machine model in BulbuLator. We resolved several visual bugs (black horizontal stripe, 9-pixel font tearing, 8-pixel border staircase), synced and analyzed 116 commits from Sergey Potapov's reference project (`ep4spectrum`), implemented the canonical Sinclair contention pattern `6,5,4,3,2,1,0,0`, masked contention during Z80 refresh cycles, and eliminated port 0xFE latch latency.

Bitstreams **B0161** and **B0162** were synthesized, packaged into `BOOT.BIN`, flashed to the SD card, and tested on live hardware with the authentic **SHOK Megademo Part 2 `.TAP`**.

---

## 2. Completed & Verified Fixes

### 2.1 System Boot & OSD Navigator Stability
- Recovered system from an uncoordinated PL swap that had caused Cortex-A9 AXI bus aborts and PS/2 parity errors.
- Flashed clean `BOOT.BIN` via mailbox command 2; clean reboot verified from SD card. OSD Navigator (F12) and PS/2 keyboard are 100% operational.

### 2.2 Horizontal Black Stripe (Bottom Border)
- **Root Cause**: `vUla >= 248 && vUla < 256` blanking in `video.v` cut an 8-scanline solid black bar across the lower border.
- **Fix**: Removed vertical blanking from RGB mux in `video.v`. Border color is now continuous across all 302 HDMI captured lines.

### 2.3 Font Tearing & Double Pixels
- **Root Cause**: An artificial `pap_delay = 9` taken from Potapov's 28 MHz domain was improperly applied as 9 full 7 MHz pixels in Atlas, smearing text across character boundaries.
- **Fix**: Removed `pap_delay`. Boot text (`© 1982 Sinclair Research Ltd`) and scroller text are now razor-sharp, 1-pixel wide, and distortion-free (`b161_screen.png`).

### 2.4 Unquantized Fine Border on Sinclair 48K
- **Root Cause**: Sinclair 48K border updates were quantized to 8-pixel character cells (`h_addr[2:0] == b_phase`), causing staircases on diagonal stripes.
- **Fix**: Extended `borderFine` to Sinclair 48K (`pentagon || !model`). Border stripes update on every 7-MHz pixel clock.
- **Verified**: On lines 70..84 of SHOK Part 2, left border, paper field, and right border match in color **100%** with zero gap or misalignment.

---

## 3. Bitstream B0162 Implementation & Live Test

### 3.1 Changes Implemented in B0162
1. **Canonical Sinclair Contention Sequence (`6,5,4,3,2,1,0,0`)**:
   - Atlas previously used `cn = dataEnable && (hUla[3] || hUla[2])` (inherited from Sizif), which placed the free pair at the *start* of the 8-count group (`0,0,6,5,4,3,2,1` - rotated by 2 T-states).
   - Replaced in `video.v` with:
     ```verilog
     wire [8:0] h_cn = hUla + 9'd2; // 1 T-state lead (charges against cycle T1)
     assign cn = dataEnable && (h_cn[3:1] < 3'd6); // held while index < 6
     ```
2. **Refresh Masking on Contention**:
   - In `memory.v`:
     ```verilog
     assign cn = rfsh && (addr01 || (model && addr11 && ramPage[0]));
     ```
     Prevents false contention during Z80 refresh cycles when register `I` is in range `0x40..0x7F`.
3. **Unclocked Port 0xFE Border Latch**:
   - In `main.v`:
     ```verilog
     else if(!ioFE && !wr && !nemo_sup) { speaker, mic, border } <= q[4:0];
     ```
     Removed `pe7M0` gating so port 0xFE updates immediately on CPU write assertion.
4. **Stable Interrupt Latching (`irq_ne`)**:
   - Set default Sinclair interrupt latching to falling edge (`nc3M5`) to eliminate master-clock edge sampling races.

### 3.2 Live Board Test Result
- The user loaded **SHOK Megademo Part 2 from authentic `.TAP`** on live hardware with B0162.
- **User observation**: *"запустил - все равно бордюр мерцает"* (border still flickers).

---

## 4. In-Depth Root-Cause Analysis for Next Session

### 4.1 Discovery: T80pa Dual-Phase Clock Enable Contention Bug
In `sources/atlas_core/main.v`:
```verilog
wire pc3M5 = pe3M5 & contend & ~cpu_hold;
wire nc3M5 = ne3M5;
```
`T80pa` (VHDL core) uses **two complementary clock enables**:
- `CEN_p` (rising edge phase)
- `CEN_n` (falling edge phase)
- Inside `T80pa.vhd`:
  ```vhdl
  CEN <= CEN_p and not CEN_pol;
  -- on CEN_p: sets CEN_pol <= '1';
  -- on CEN_n: clears CEN_pol <= '0';
  ```
**CRITICAL FLAW**: When `contend` goes low, `pc3M5` (`CEN_p`) is withheld, **BUT `nc3M5` (`CEN_n`) CONTINUES TO FIRE**!
- Because `CEN_n` fires while `CEN_p` is suppressed, `CEN_pol` gets cleared prematurely.
- When `contend` is released, `T80pa` sees an illegal half-clock pulse and corrupted internal state.
- In contrast, Sergey Potapov's `ep4spectrum` uses `T80se`, which has a **single clock enable (`CLKEN`)**:
  ```verilog
  assign cpu_clken_gated = cpu_clken & ~contention;
  ```
  In `T80se`, suppressing `CLKEN` holds the entire CPU cleanly with zero internal phase skew.

### 4.2 Discovery: Contention Hold Mechanism (`cpuck`)
In `main.v`:
```verilog
always @(posedge clock) if(ne7M0) cpuck <= !(cpuck && contend);
```
- In Atlas, `cpuck` is a 3.5 MHz toggle. When `contend` is low, `cpuck` stays high.
- The interaction between `cpuck`, `mreqt23iorqtw3`, and `vduC_mem` was designed for coarse wait states and does not reliably hold memory cycles for back-to-back writes (`PUSH DE`).

### 4.3 Hardware Frequency Offset vs Video Buffer
- The ZX Spectrum master clock in BulbuLator is $56.666667\text{ MHz} / 16 = 3.541667\text{ MHz}$ (standard Spectrum is $3.500000\text{ MHz}$).
- At 69,888 T-states/frame, the core frame rate is $50.676\text{ Hz}$.
- The HDMI controller scans out at strictly $50.000\text{ Hz}$.
- The beat frequency between $50.676\text{ Hz}$ and $50.000\text{ Hz}$ is $\approx 0.676\text{ Hz}$, which equals a period of **$\approx 1.48$ seconds**.
- We need to confirm whether the border flicker is a 1.48-second buffer skip in `fb_bufmgr3.v` or internal CPU timing slip.

---

## 5. Roadmap & Plan for Next Session

1. **Fix Clock Gating on T80pa (or switch to T80se)**:
   - Option A: Gate **both** `pc3M5` and `nc3M5` simultaneously when `contend == 0`, preserving `CEN_pol` phase in `T80pa`.
   - Option B: Instantiate `T80se` (single clock enable, as used by Potapov and MiSTer) with `T2Write = 1`.
2. **Synchronize Frame Buffer Swapping (`fb_bufmgr3`)**:
   - Verify whether `fb_bufmgr3` drops a frame every 1.5 seconds due to the $50.68\text{ Hz}$ vs $50.00\text{ Hz}$ frequency mismatch, and test genlock / synchronous swap.
3. **MiSTer-48 A/B Verification**:
   - Test building with `-tclargs mistert80` or MiSTer ULA backend to isolate whether the issue is Atlas-specific.
4. **Test SHOK Part 2 on Live Board**:
   - Confirm completely smooth, non-blinking border and solid central graphics.
