# Step 6 — A ZX Spectrum 128 on the EBAZ4205

This is the big one. Steps 0–5 were the runway: power, JTAG, blink, buttons, HDMI
video, HDMI audio. Here it all comes together into a **real, timing-accurate ZX
Spectrum 128** running on a ~$10 board — HDMI video and sound, the four shield
buttons drive the boot menu, and it **loads games from tape** through an audio pin.
Put the SD card in and it boots the Spectrum on its own.

The display has been checked side by side against **ZEsarUX** (a reference emulator)
and matches — including the ULA quirks the timing test programs poke at.

## What it does

- **The original 128 boot menu** (the "toastrack" © 1986 Sinclair ROM): Tape Loader,
  128 BASIC, Calculator, 48 BASIC, **Tape Tester**.
- **HDMI video, 720p50**, the Spectrum picture in a 4:3 pillarbox with the **border**
  (so border effects survive).
- **HDMI audio**: AY/YM (128 sound chip) + beeper + tape-load sound, in the HDMI stream.
- **Menu navigation from the shield buttons**: P19 = down, T19 = up, U20 = Enter,
  U19 = Break.
- **Tape loading from an audio source**: feed a TAP/WAV player into pin **J19** and
  `LOAD ""` / the Tape Loader picks it up.
- **Boots from SD** (FSBL configures the PL from `BOOT.BIN`), or over JTAG.

## Not reinventing the wheel

The Spectrum itself is the open-source **Atlas `zx`** core (T80 Z80, the ULA, AY via
JT49, 48K/128K, contention/timing inside the core). We didn't rewrite any of that — we
**forked it** and added a one-line build fix, then wrote only the *board* around it:

| Piece | Where it comes from |
|---|---|
| ZX Spectrum core | [AtlasFPGA/zx](https://github.com/AtlasFPGA/zx) → our fork [**Alex-Electron/zx** `ebaz4205-vivado`](https://github.com/Alex-Electron/zx/tree/ebaz4205-vivado) |
| Z80 | T80 (Daniel Wallner), inside the Atlas core |
| AY-3-8910 / YM2149 | JT49 (Jose Tejada / jotego), inside the Atlas core |
| HDMI encode + audio | [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (MIT/Apache), same as Steps 3–5 |
| The board-top | this repo (`sources/`) |

The one fix in the fork: Vivado's VHDL is stricter than the ISE the core targeted, and
rejected a 4-bit literal AND-ed with a 9-bit signal in T80's ALU. Widening it to a
9-bit literal is the whole change — see the fork's `ebaz4205-vivado` branch.

## How it's wired

```mermaid
flowchart LR
    FCLK["PS FCLK0 100 MHz"] --> M1["MMCM: 56.7 MHz<br/>Spectrum + enables"]
    FCLK --> M2["MMCM: 74.25 / 371.25<br/>HDMI"]
    M1 --> CORE["Atlas zx core<br/>(model=128K)"]
    CORE -->|"memA / memQ"| MEM["mem_zx<br/>ROM + 128K RAM + screen"]
    MEM -->|"memD / vmmD"| CORE
    CORE -->|"RGBI + sync (7 MHz)"| FB["framebuffer<br/>capture → 720p50 scaler"]
    M2 --> FB
    FB -->|"rgb 24-bit"| HDMI["hdl-util/hdmi"]
    CORE -->|"laudio/raudio 11-bit"| HDMI
    M2 --> HDMI
    HDMI -->|"TMDS"| OUT["HDMI: 720p50 + audio"]
    BTN["buttons P19/T19/U20/U19"] --> KBD["kbd_buttons<br/>→ scan codes"]
    KBD -->|"strb/make/code"| CORE
    J19["J19 tape-in"] -->|"ear"| CORE
```

Our board modules (all in `sources/`):

- **`clock_zx.v`** — FCLK0 → an MMCM at ~56.7 MHz (the 128K master), plus the
  `pe7M0/ne7M0/pe3M5/ne3M5` clock enables the core needs.
- **`mem_zx.v`** — the memory the core's external bus expects, in Block RAM: the 32 KB
  +2-style ROM pair (here the toastrack 128 ROM), the 128 KB RAM, and a small screen
  buffer for the video fetch.
- **`framebuffer.v`** — captures the core's actual rendered **RGBI output pixel by
  pixel** (so the border and any border effects are kept, not re-drawn from screen RAM),
  and reads it back at 720p50 with a ×2 / pillarbox scale and the ZX palette.
- **`kbd_buttons.v`** — debounces the four buttons and turns each press into a single
  PS/2 scan-code *tap* the core's keyboard accepts.
- **`bulbulator_zx_top.v`** — ties it together with the proven HDMI stack from Step 5
  and the bare PS7 (for FCLK0). `hdmi_wrap.sv` is the thin stereo wrapper around hdl-util.

It fills the 7010 almost exactly: **60 of 60 Block RAM tiles**, ~20% of the LUTs.

## The things that bit us

The honest part. None of these were in the plan.

- **The keyboard ran in circles.** Two presses and the menu cursor would spin forever.
  The cause was one inverted bit: the Atlas core's `make` signal is **0 = pressed,
  1 = released** (its PS/2 layer sets `make` on the `F0` *release* prefix). We'd sent it
  the other way, so every "release" actually *held* the key down and the ROM auto-repeated.
  One line, a whole evening.
- **The buttons floated.** They're active-low and need an internal **pull-up** in the
  XDC; without it the released pin drifts and the debounce sees phantom presses.
- **The bitstream wouldn't flash over JTAG.** Steps 0–5 flashed fine, but this one
  always failed with `BAD_PACKET_ERROR` (`CONFIG_STATUS` bit 29), even compressed. It's
  not the size — it's that a **dense, BRAM-heavy** config stream trips a bug in the
  XVC-over-Pico path on this setup, while sparse demo bitstreams sail through. The fix is
  to skip JTAG configuration entirely and load over **PCAP**: DMA the bitstream into DDR
  (with read-back verification), then have the PS configure the PL from there. See
  `bulb_pcap_run.sh`. This is the "armoured train" route.
- **The first ROM had no Tape Tester.** The ROM the Atlas core ships is the grey +2
  (Amstrad) one; its menu is different. The original 128 *toastrack* ROM is the one with
  "Tape Tester" — fetched and converted by `sources/get_rom.sh`.
- **`bootgen` for the SD image segfaulted** on the build host (a botched tool move). The
  working `bootgen` was on a different machine — so `BOOT.BIN` (FSBL + bitstream + a tiny
  idle app) was built there. The FSBL sets FCLK0 = 100 MHz and configures the PL via PCAP
  at power-on — which is also why SD-boot dodges the JTAG `BAD_PACKET` problem for free.

## Build it yourself

You need Vivado 2023.1 (full, for synthesis) and the part `xc7z010clg400-1`.

```bash
cd sources/
git clone -b ebaz4205-vivado https://github.com/Alex-Electron/zx        # the Atlas core, with the T80 fix
git clone https://github.com/hdl-util/hdmi                              # the HDMI core
bash get_rom.sh                                                         # downloads + builds rom128.hex
vivado -mode batch -source build_bulbulator_zx.tcl                      # → bulbulator_zx_z010.bit
```

The layout the build expects (Atlas fork in `sources/zx/`, hdl-util in `sources/hdmi/`)
is documented at the top of `build_bulbulator_zx.tcl`. A prebuilt
**`bulbulator_zx_z010.bit`** is included if you just want to flash.

## Flash it — two ways

**SD card (standalone, recommended).** Take the [`flash/BOOT.BIN`](flash/) file from this
step and copy it to the **top level (root) of the SD card** — it must be named `BOOT.BIN`
and sit in the root, **not** inside any folder. (The `flash/` above is just where the file
lives in this repo; you do **not** create a `flash` folder on the card.) The card needs a
single **FAT32** partition — most micro-SD cards are already FAT32, so usually you just
drop the file on; otherwise format it FAT32 first. Then set the board to SD boot (see
[Step 0](../00-setup/)), insert the card, and power on — the Spectrum comes up by itself.
`BOOT.BIN` = Zynq FSBL + our bitstream + a do-nothing app; the FSBL brings up the
clocks/DDR and configures the PL. The Zynq BootROM only reads `BOOT.BIN` from the root of
the first FAT partition, so nothing else on the card matters.

**JTAG / PCAP (no SD).** Because the dense bitstream won't take plain JTAG config, use the
PCAP loader (load to DDR with verification, then PS configures the PL):

```bash
bash bulb_pcap_run.sh bulbulator_zx_z010.bit.bin   # .bit.bin via: bootgen -process_bitstream bin
```

`PCFG_DONE=1` means the PL is up. (`flash/ps7_init_fclk.tcl` + `flash/pcap_load.tcl` are
the PS-side helpers.)

## Run it

- **Menu:** T19/P19 move the cursor, U20 selects, U19 is Break.
- **Load a game from tape:** wire your TAP/WAV player's output to **J19** (= `DATA2-09`)
  and ground; on the Spectrum pick *Tape Loader* (or `LOAD ""`), start the audio, and the
  loading stripes appear. J19 is a 3.3 V digital input with a pull-down — a line-level
  signal may be too quiet; use a hot/headphone-level output, or a small comparator
  front-end if it won't latch.
- **LEDs:** H18 blinks (alive); D18 (lock) stays off — cosmetic, the shield LED is
  active-low against a steady "locked" level.

Note on the framebuffer: it's a single buffer. Because the Spectrum frame rate (~50 Hz)
and 720p50 are nearly identical, the read/write seam parks off-screen and the picture is
stable and correct (matches ZEsarUX). A DDR double/triple-buffer is **not needed** for
this core; the researched plan is kept in
[`DDR_FRAMEBUFFER_PLAN.md`](DDR_FRAMEBUFFER_PLAN.md) for when a bigger machine (Pentagon
1024, NES with large ROMs, …) actually needs PS DDR.

## Files

```
sources/   our board-top (clock_zx, mem_zx, framebuffer, kbd_buttons, top, hdmi_wrap),
           the XDC, the portable build script, and get_rom.sh
flash/     BOOT.BIN (SD), ps7_init_fclk.tcl + pcap_load.tcl (PCAP)
bulbulator_zx_z010.bit   prebuilt bitstream
bulb_pcap_run.sh         PCAP ("armoured train") loader
DDR_FRAMEBUFFER_PLAN.md  researched-but-not-needed DDR framebuffer plan
```

## Credits & licences

- **Atlas `zx` core** — [AtlasFPGA/zx](https://github.com/AtlasFPGA/zx); our build fork
  [Alex-Electron/zx](https://github.com/Alex-Electron/zx). Contains **T80** (Daniel
  Wallner) and **JT49** (Jose Tejada). Please see the upstream project for its terms;
  we redistribute only our board-top + a forked, attributed copy of the core.
- **HDMI**: [hdl-util/hdmi](https://github.com/hdl-util/hdmi) by Sameer Puri & contributors
  (MIT / Apache-2.0).
- **128 ROM**: the © 1986 Sinclair/Amstrad ZX Spectrum 128 ROM, distributed under
  Amstrad's permission for emulation; fetched (not shipped) by `get_rom.sh` from the
  [fbzx](https://github.com/rastersoft/fbzx) project.
- Our board-top and scripts are this project's own work.
