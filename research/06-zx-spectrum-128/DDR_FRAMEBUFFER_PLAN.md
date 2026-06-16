# DDR Framebuffer — architecture & build plan (Bulbulator ZX, EBAZ4205 7010)

Goal: move the video framebuffer from on-chip BRAM (full at 60/60, single-buffer → stationary
read/write tear band at top + corner) to **PS DDR, double/triple buffered** → tear-free + full overscan.
Principle: **don't reinvent** — reuse proven IP + the m1nl adapter + our hdl-util.

## Decided architecture (all proven blocks)
- **Read path (DDR→HDMI):** `v_frmbuf_rd` (Xilinx Video Frame Buffer Read, PG278, free with Vivado 2023.1)
  masters PS DDR via `S_AXI_HP0`, emits AXI4-Stream Video → **m1nl `hdmi_adapter.v`** (widened 10→11-bit
  cx/cy) → our **hdl-util/hdmi** (720p50, VIDEO_ID_CODE=19, + stereo audio — KEEP as-is, `hdmi_wrap.sv`).
- **Write path (Spectrum→DDR):** `v_frmbuf_wr` (companion IP) takes AXI4-Stream Video → writes DDR frame.
  A small **`zx_to_axis`** converter turns the Spectrum RGBI raster (r,g,b,i + blank/hsync/vsync, pe7M0)
  into AXI4-Stream Video (tdata=RGB888, tvalid, tuser=SOF, tlast=EOL).
- **Control (no OS):** a PL **AXI4-Lite master FSM** (`frmbuf_ctl`) configures both IPs (WIDTH/HEIGHT/
  STRIDE/FORMAT/FRM_BUFFER/ap_start, auto_restart) and **flips the buffer base addresses on vsync**
  (tear-free). No PS software, no app — keep the `idle.elf` boot.
- **PS7:** bare `PS7` primitive (as today, FCLK0=100). NEW: wire `S_AXI_HP0_*` to the frmbuf masters,
  `S_AXI_HP0_ACLK` ← clk_pixel (74.25). Two masters (rd+wr) → one HP via AXI **SmartConnect**, OR use
  HP0 for read + HP1 for write (simpler, both enabled, no interconnect).

## 🔑 Key proven facts (from 3 research sub-agents, 2026-06-16)
- **Enabling HP0 needs ZERO ps7_init change** — regenerated ps7_init is byte-identical to ours. HP slave
  ports are live once PS is out of reset + DDR up (our PCAP already proves DDR). Just connect + clock.
- **HP0 is AXI3**: 64-bit data, 6-bit IDs, 32-bit addr, AxLEN 4-bit (≤16-beat bursts), AxSIZE drive 3'b011.
  AxCACHE=4'b0011. Tie `S_AXI_HP0_RDISSUECAP1_EN`/`WRISSUECAP1_EN`=0; leave *COUNT outputs open. Don't
  drive ARESETN. v_frmbuf masters are AXI4 → SmartConnect/protocol-conv slices to AXI3 (16-beat).
- **HP0 clock = any PL clock** (has internal async FIFO) → use clk_pixel 74.25 → no extra CDC on read.
- **DDR = 256MB (0x0..0x0FFFFFFF).** PCAP loads bitstreams at 0x00100000 (~4MB). **Framebuffers high:**
  FB0=0x0FF00000, FB1=0x0FF10000, FB2=0x0FF20000 (64KB each for ~384×304×3; bump to 4MB slots @0x0F000000
  if storing full 720p). Reachable via HP0.
- **v_frmbuf_rd**: SAMPLES_PER_CLOCK=1 (→64-bit MM), MAX_COLS/ROWS≥512, HAS_RGB8/RGBX8, AXIMM_ADDR_WIDTH=32.
  Bare-metal regs (base B): WIDTH B+0x10, HEIGHT B+0x18, STRIDE B+0x20 (bytes, %8), VIDEO_FORMAT B+0x28
  (RGB8=20, RGBX8=10), FRM_BUFFER B+0x30, CTRL B+0x00 (bit0 ap_start, bit7 auto_restart). Flip buffer:
  write B+0x30 on ap_done/ap_ready → takes effect next SOF (tear-free). DDR byte order R,G,B.
- **`axi_dmac` is the fallback** (lighter, but cyclic mode can't change addr per frame → needs non-cyclic
  4-deep queue flip; only better under Linux, which is why m1nl uses it). We are no-OS → frmbuf wins.
- m1nl repos cloned on ThinkPad: `/home/lavrinovich/m1nl/ebaz4205-hdmi-demo` + `/home/lavrinovich/m1nl/adi-hdl`.
  Reusable: `hdl/library/hdmi_generator/hdmi_adapter.v` (widen cx/cy to 11-bit), EBAZ HDMI pin XDC.
- NOTE: m1nl only does the READ side (PS writes DDR, DMA reads to HDMI). We add the WRITE side (PL Spectrum
  → DDR via v_frmbuf_wr). Our existing `framebuffer.v` scaler logic (x2/pillarbox/palette) is reused in the
  read adapter or kept PL-side.

## Phased build (test stripes first, then Spectrum — user-approved)
- **Phase 1a (read-only, prove DDR→HDMI):** load a stripe pattern into DDR @0x0FF00000 via xsdb `dow`
  (Bronepoezd already does DDR writes) → `v_frmbuf_rd` + `frmbuf_ctl` (config only) + `hdmi_adapter`(11-bit)
  → hdl-util → HDMI. Pass = stripes from DDR on screen. Proves HP0 + frmbuf_rd + adapter + hdl-util.
- **Phase 1b (write+read+double-buffer):** add `v_frmbuf_wr` + a PL `pattern_gen` (moving stripes/box) →
  `zx_to_axis` → wr → DDR; `frmbuf_ctl` flips FB on vsync. Pass = smooth moving box, NO tear band.
- **Phase 2:** replace `pattern_gen` with the real Spectrum (`main` + `mem_zx`), RGBI→`zx_to_axis`, full
  overscan (384×304). Keep kbd/ear/audio. Tear-free Spectrum.
- **Phase 3:** integrate into the full design, rebuild, new BOOT.bin → SD.
Each phase: build on ThinkPad → bootgen .bit.bin → PCAP load (or SD) → user observes monitor.

## What stays the same
hdl-util/hdmi (video+audio), clock MMCMs (74.25/371.25 + 56.7 Spectrum), kbd_buttons (make-fixed),
mem_zx, ear/J19, the PCAP/SD flash flow, ps7_init (UNCHANGED). The working BRAM-framebuffer design stays
on SD as the known-good rollback until the DDR version is proven.
