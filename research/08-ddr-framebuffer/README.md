# Step 8 — Tear-free video: a DDR double-buffered framebuffer

Steps 6 and 7 put a real, timing-accurate ZX Spectrum 128 on screen and woke the ARM up to
drive it. But the video had one honest flaw: a **single on-chip framebuffer**. The Spectrum
core renders into a BRAM at its own ~50.02 Hz, and the HDMI side scans it out at exactly
50.000 Hz. Those two rates are *not* locked, so the read pointer slowly drifts through the
write pointer — and on any frame where the picture changes (a border effect, a demo, a
shadow-screen flip) you see a **horizontal tear seam crawling down the screen**.

On the menu and most games you never notice. On a border-effect demo like *Mescaline
Synesthesia* it is impossible to miss: a bright line marching top-to-bottom, over and over.

This step fixes it the right way. The 256×192 screen plus border is only **~51 KB** as a
4-bit-per-pixel source frame, so it fits trivially in PS DDR. We **double/triple-buffer that
source frame in DDR** and only ever swap which buffer the scanout reads **on the HDMI vblank**.
The scanout always sees a *complete, stable* frame — no tearing, ever — including across
bank-5 ↔ bank-7 shadow-screen switches. The on-chip BRAM upscaler (pillarbox, palette,
720p50) is reused unchanged, so on-chip memory usage stays exactly where it was: **60/60 BRAM**.

The result is verified on hardware: *Mescaline* and the `ula128` timing test run with **no tear
seam**, the shadow screen switches cleanly, and the frame-rate beat (50.02 vs 50.000 Hz) is
down to an imperceptible micro-stutter every ~50 s instead of a constant moving line.

## The pipeline

Everything that was a single BRAM `framebuffer` is now a chain across two clock domains and
PS DDR, glued together with the **AXI-HP** port whose latency we measured back in Step 7:

```
 Spectrum (spclk ~56.7 MHz)                         fclk100 (100 MHz)                 HDMI (clk_pixel 74.25 MHz)
 ┌───────────────┐   ┌────────────┐   ┌──────────┐   ┌──────────┐   ┌────────────┐    ┌──────────┐   ┌──────────┐
 │ video.v RGBI  │──▶│ fb_capture │──▶│ async    │──▶│ fb_wr_axi│──▶│  PS DDR    │◀──│ fb_loader │──▶│fb_display│──▶ HDMI
 │ (the core)    │   │  _rr       │   │  _fifo   │   │ (HP0 wr) │   │ 3 buffers  │   │ (HP0 rd)  │   │+upscaler │
 └───────────────┘   └────────────┘   └──────────┘   └──────────┘   └────────────┘    └──────────┘   └──────────┘
                       re-raster        gray-code      16-beat        51 KB ×3        once per          BRAM, x2
                       to 360/line      CDC FIFO       bursts         @0x0FF0_0000     vblank            pillarbox
                                                                          ▲
                                                   fb_bufmgr3 ── swaps the read pointer on HDMI vblank ──┘
                                                  (triple buffer: the writer never waits on the reader)
```

- **`fb_capture_rr`** (Spectrum domain) re-rasters the core's video to exactly **360 pixels × 288
  lines = 6480 64-bit words per frame**, via a ping-pong line buffer. This matters: the core's
  vblank lines (`vCount 248..255`) carry *zero* non-blank pixels, so a naïve packer would push
  ~6300 words and the streamed frame would scroll diagonally. Padding every line to a fixed 360
  keeps the frame word-aligned (geometry identical to the Step-6 `framebuffer.v`).
- **`async_fifo`** is a classic dual-clock gray-code FIFO (distributed RAM, FWFT) — the safe CDC
  from the Spectrum clock to `fclk100`.
- **`fb_wr_axi`** drains the FIFO to PS DDR over **S_AXI_HP0 (write)** as 16-beat INCR bursts.
- **`fb_bufmgr3`** is a MiSTer-`ascal`-style **triple buffer**. Because a live capture can't be
  paused, the writer must always have a free buffer — three buffers guarantee that, so the
  writer never stalls and the reader always gets the latest complete frame. The displayed
  buffer is latched **only on the HDMI vblank**.
- **`fb_loader`** reads the displayed buffer back over **S_AXI_HP0 (read)** into the display BRAM
  once per frame (during vblank), and **`fb_display`** is the unchanged Step-6 upscaler.

Read and write share one HP0 port (independent AR/R and AW/W channels), so no interconnect.
Total DDR traffic is under **8 MB/s** against the ~800 MB/s the port sustains — a rounding error.

## Bugs worth writing down

This took a few hardware iterations. The non-obvious ones:

1. **The vblank lines scroll the picture.** Streaming to DDR needs *exactly* 6480 words/frame; the
   core's 8 vblank lines give 0 → the frame came up short and crawled diagonally. Fix: the
   re-raster line buffer (`fb_capture_rr`) pads every line to 360.
2. **Startup FIFO overflow.** The HP write path is only live after the FSBL/PCAP enables the PS↔PL
   level shifters; the capture started immediately and overran the FIFO before that, dropping
   words and desyncing the frame. Fix: gate the capture until the loader has read its first frame
   (proof the HP path is up), and start it on a frame boundary.
3. **The writer overwrote the displayed buffer.** `fb_wr_axi` re-latched the buffer base in the
   same cycle the manager advanced it → it used the *old* base → the writer painted the buffer the
   scanout was still showing, top-to-bottom (a seam crawling down, then a jump). Fix: wait a few
   cycles for the pointer to settle.
4. **The async FIFO needs registered `full`/`empty`.** A combinational `full` feeds the write
   pointer which feeds `full` — a combinational loop. The textbook Cummings design registers them.

## What you see, and the output window

The captured 360×288 contains the 256×192 screen, the ZX border, and (because the ULA scanline
wraps) the *left* border tucked onto the right. The output window is cropped in `fb_display`
(display-side only, the 6480-word capture contract untouched): it drops the 8-line black vblank
strip at the top and a thin black strip at the right edge, and keeps the screen plus a clean
border — important, because the **border is real content** (the `ula128` test draws its timing
stripes there). The displayed window is 356×249 source → ×2 → 712×498, framed in a dark-grey
pillarbox inside 1280×720.

## Build from source

`sources/` has the whole set. The flow (run on the build host where Vivado lives):

```
vivado -mode batch -source sources/build_bulbulator_ddr.tcl
```

It reads, in order: the hdl-util/HDMI core + `hdmi_wrap.sv`; the forked Atlas ZX core (T80 / JT49
/ SAA + the Verilog core, from `Alex-Electron/zx`); the EBAZ glue (`clock_zx`, `mem_zx`,
`kbd_buttons`); the Step-7 control plane (`axi_ctl`, `inject_cdc`); the DDR-framebuffer chain
(`fb_capture_rr`, `async_fifo`, `fb_wr_axi`, `fb_bufmgr3`, `fb_loader`, `fb_display`); and the
top `bulbulator_zx_ddr_top.v`. `get_rom.sh` fetches `rom128.hex` (the toastrack ROM, see Step 6).
The paths at the top of the `.tcl` point at the build host's layout — edit them to match yours.

The DDR-framebuffer path was brought up in isolation first, in `standalone-tests/`: Phase 1a
(prove DDR→HDMI read), then Phase 2a (the full capture→FIFO→DDR→triple-buffer chain driven by a
synthetic raster on the real Spectrum clock). Same discipline as Step 7's `m1-handshake-test`.

## Run it

**Over JTAG (PCAP "armoured train"):** `ddr_full_run.sh` configures the dense bitstream via PCAP
(it's BAD_PACKET-immune, same as Steps 6–7). `ddr_inject_run.sh <snapshot.z80>` additionally
injects a `.z80` over the Step-7 control plane so you can watch a demo (e.g. Mescaline) come up
tear-free.

**From SD (no JTAG):** copy `flash/BOOT.BIN` to the FAT `boot` partition of the card (set the
board to SD boot — the R2577 strap, see Step 0), power on, and the 128 menu comes up on HDMI.
`flash/build_boot.sh` rebuilds that `BOOT.BIN` (FSBL + bitstream + idle) VM-free — see the script
header for the bootgen-on-modern-glibc workaround.

## Files

```
bulbulator_zx_ddr.bit     the bitstream (Atlas ZX-128 + Step-7 control plane + DDR framebuffer)
ddr_full_run.sh           PCAP-configure the bitstream over JTAG
ddr_inject_run.sh         PCAP-configure + inject a .z80 demo over the control plane
sources/                  all RTL + the build .tcl + .xdc (DDR chain + shared glue + core deps list)
flash/                    BOOT.BIN (SD image) + build_boot.sh + bifs + fsbl.bin/idle.bin + pcap_load.tcl
standalone-tests/         Phase 1a / Phase 2a bring-up harnesses for the DDR path
images/                   hardware photos
```
