# Step 3 — Primitive HDMI: colour bars

Languages: **English** · [Русский](README.ru.md)

The first picture on the screen. Eight static vertical colour bars at 1280x720,
output over HDMI. No animation, no menu — the simplest thing that proves the
whole video path works.

This is the first step that needs the **PS** (the ARM side), and that turned out
to be the hard part. Steps 1 and 2 ran entirely in the PL on the chip's internal
oscillator. HDMI needs a clean, exact pixel clock (74.25 MHz for 720p), and the
only stable clock on this board comes from the PS, derived from the 33.333 MHz
crystal.

**Why not take the crystal directly?** On the EBAZ4205 the 33.333 MHz crystal is
wired only to the PS clock input — there's no board trace from it to a
clock-capable PL pin. The PS PLLs make every clock, and the PL gets them over the
FCLK0–3 lines. So "clock from the crystal" *is* what happens here: crystal →
IO-PLL → FCLK0 → PL. The internal oscillator (CFGMCLK) used in Steps 1–2 needs no
crystal but drifts too much for video. The only way to feed the PL a crystal-
clean clock without the PS would be to wire an external oscillator onto a
clock-capable PL pin (some DATA-header pins are MRCC) — a hardware mod.

## How the video is built

```
crystal 33.333 MHz → PS (IO-PLL) → FCLK0 100 MHz
   → PS7 stub (clkgen.v) → clk_wiz / MMCM
       ├─ 74.25 MHz  (pixel)  → pattern_gen (bars) + rgb2dvi
       └─ 371.25 MHz (×5)     → rgb2dvi (TMDS serialiser)
   → TMDS out → HDMI → monitor
```

- [`pattern_bars.v`](pattern_bars.v) — 720p timing and eight fixed colour bars
  (white, yellow, cyan, green, magenta, red, blue, black). It also blinks
  `led_heart` (H18) off the pixel clock, ~1 Hz, as a "the clock is alive" sign.
- [`clkgen2.v`](clkgen2.v) — a bare `PS7` primitive that just taps FCLK0.
- The `clk_wiz` MMCM and Digilent's `rgb2dvi` come from IP (see Build).

The TMDS pins follow the shield's **"family B"** wiring — clock on **F19/F20**.
The other pinout in the wild ("family A", H16/H17) gives a blank screen here,
since H16/H17 are the UART on this board. Full pinout and the gotcha are in the
[Step 0 expansion-board reference](../00-setup/#expansion-board-reference).

## The lesson: FCLK0 needs the level shifters

This took several tries. Programming the PL and even setting FCLK0 to 100 MHz
with `ps7_init` gave a **blank screen** — the pixel clock simply wasn't reaching
the fabric (the H18 heartbeat stayed dark).

The missing piece was **`ps7_post_config`**, which enables the PS→PL **level
shifters** (`LVL_SHFTR_EN`). FCLK0 was being generated the whole time, but
without the level shifters on, it never crossed from the PS into the PL. The
working order is the same one an FSBL uses on boot: bring the clocks up, load the
PL, then enable the level shifters.

[`flash_stripes.sh`](flash_stripes.sh) does this over JTAG in two reliable parts:

1. **Program the PL with `vivado_lab`** (`program_hw_devices`, with retries). This
   is the robust path. An earlier version used xsdb's `fpga -file` and it failed
   intermittently on the dense bitstream (`DONE PIN is not HIGH`), so it's gone.
2. **Bring up the PS clock with `xsdb`:** `ps7_init` (FCLK0 = 100 MHz from
   [`ps7_init_fclk.tcl`](ps7_init_fclk.tcl)) then `ps7_post_config` (level
   shifters). The already-loaded MMCM re-locks on the new clock and the bars
   appear.

With a normal SD boot, the FSBL does all of part 2 for you, so you'd only load
the PL.

## Build

Needs Vivado 2023.1 and Digilent's **rgb2dvi** IP (from `vivado-library`). Point
the build at your checkout, then run it:

```
export VIVADO_LIBRARY=~/vivado-library
vivado -mode batch -source build_stripes_z010.tcl
```

Target part `xc7z010clg400-1`, output ~2,083,867 bytes. A prebuilt
`hdmi_stripes_z010.bit` is included.

## Flash

```
bash flash_stripes.sh hdmi_stripes_z010.bit
```

You should see `End of startup status: HIGH` from part 1, then `PS7_INIT_DONE`
and `PS7_POST_CONFIG_DONE` from part 2. (Any Vivado-supported JTAG cable works;
see [Step 0](../00-setup/). The script is written for the Pico/xvc-pico setup.)

## Expected result

Eight vertical colour bars fill the screen, rock steady (the clock is crystal-
derived, so the monitor locks cleanly). **H18 blinks ~1 Hz** — that's the pixel
clock heartbeat, the clearest sign the clock made it into the fabric.

> On the test board the **D18** lock LED stayed dark even though everything else
> worked — a cosmetic quirk of that output, not a clock problem (a steady,
> synced picture and a blinking H18 already prove the MMCM is locked).
