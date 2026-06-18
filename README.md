# BulbuLator

Languages: **English** · [Русский](README.ru.md)

![BulbuLator — ZX Spectrum on Zynq-7010 (EBAZ4205)](docs/images/splash.jpg)

Developed by: Alexander Lavrinovich<br>
GitHub: https://github.com/Alex-Electron<br>
Email: lavrinovich.alex@gmail.com<br>
Co-author: AI<br>
Russian translation: DeepL

A hardware ZX Spectrum emulator on a Xilinx Zynq SoC: bring up an open ZX Spectrum
core on the cheap, easy-to-find EBAZ4205 board, reworking it for the Xilinx
architecture along the way. The published build runs on the open **Atlas `zx`**
core; the MiST / MiSTer cores stay as a fallback for the machines Atlas doesn't cover.

![EBAZ4205 board wired to the HDMI/audio and buttons expansion shield](docs/images/board.jpg)

*The EBAZ4205 (Zynq-7010) next to the HDMI / audio + buttons shield, powered up
and running.*

![The ZX Spectrum 128 boot menu running on the board over HDMI](docs/images/spectrum-128-menu.jpg)

*And here it is working — the genuine © 1986 Sinclair ZX Spectrum 128 boot menu
(Tape Loader / 128 BASIC / Calculator / 48 BASIC / Tape Tester) on the EBAZ4205 over
HDMI. The full build is [Step 6](research/06-zx-spectrum-128/).*

The biggest change from the original cores is memory. MiST drives an external
SDRAM controller; here the Spectrum RAM sits in on-chip BRAM and is reached over
AXI, which takes a lot of timing and routing pain off the table on this board.

This repo is a working notebook and an idea record. It fills up as things get
checked on real hardware.

## Target board

The board is the EBAZ4205 with the Zynq-7010 (`XC7Z010`), the most common version
of this board on the second-hand market. Everything here is built and tested
against it. There are also boards with a custom-soldered `XC7Z020` (more logic,
but pricier) — see [`docs/HARDWARE.md`](docs/HARDWARE.md) for details.

## What it should do

The cores: ZX Spectrum 48K, 128K, and Pentagon 128 with accurate INT timing
(320 lines per frame).

For input there is a PS/2 keyboard on two FPGA pins, Kempston and Sinclair
joysticks, and Dendy / Sega gamepads.

Sound covers the AY-3-8912 / YM2149F, Turbo Sound (two AY chips), General Sound,
and the beeper, with output over I²S and HDMI audio.

Storage is where it gets fun. Virtual `.trd` / `.scl` disks through a WD1793
TR-DOS, DivMMC / ESXDOS, and the part I most want to build: routing the WD1793
signals out to GPIO through a 3.3V→5V level shifter so a real floppy drive can
hang off the board.

Video is VGA and HDMI with CRT-style scanlines; the expansion shield for that is
already built and working. And since the EBAZ4205 has on-board Ethernet, the ARM
side can run an FTP server so games drop in over the network instead of going
back and forth on an SD card.

The longer list, including the ideas pulled from MiST / MiSTer / TSConf (OSD
menu, save states, tape emulation, ROM switcher, soft-USB, fast-forward), is in
[`docs/CONCEPT.md`](docs/CONCEPT.md).

## Status

Where things stand right now:

The **ZX Spectrum 128 now runs on the board** ([Step 6](research/06-zx-spectrum-128/)):
the original 128 boot menu over 720p50 HDMI with sound, the four shield buttons
driving the menu, tape loading through an audio pin, and standalone SD boot — the
display checks out against ZEsarUX. It's built on the open-source Atlas `zx` core;
the dense bitstream loads over PCAP, since plain JTAG configuration trips a
`BAD_PACKET` bug on this setup. [Step 7](research/07-arm-control-plane/) then wakes up the
idle ARM with an AXI control plane — it can now **halt the Z80 and read/write the Spectrum's
memory live** (the ARM paints the screen while the CPU is frozen), the foundation for loading
games from SD. [Step 8](research/08-ddr-framebuffer/) then makes the video **tear-free** by
buffering the ZX frame in PS DDR — triple-buffered, swapped on the HDMI vblank — the first real
use of that AXI-HP path to DDR. [Step 9](research/09-ps2-keyboard/) adds a real PS/2 keyboard with
a normalised control-key map (reset / NMI). Next is the on-screen menu and SD game loader on the
ARM, then bigger machines.

## Learning the board

I'm figuring this board out as I go — Zynq, the EBAZ4205, and FPGA work in
general are new ground for me — so this repo doubles as a lab notebook. Instead
of dropping a finished emulator, the plan is to bring the board up one small,
verified experiment at a time and write down what actually happened, dead ends
included. When something only works after three tries, that's the part worth
recording.

Each step is self-contained: sources, a ready-to-flash bitstream, and notes on
what it proves and what tripped me up. They live in [`research/`](research/).

So far:

- **[Step 0 — Setup & wiring](research/00-setup/).** Starting from a bare board:
  power, the SD boot-mode strap, hooking up a JTAG programmer (a normal cable or
  a Raspberry Pi Pico), installing Vivado, and flashing a bitstream — enough for
  someone with no FPGA background to get to a blinking LED.
- **[Step 1 — LED blink](research/01-board-bringup-blink/).** The smallest "is
  this board even alive" test: a counter on the chip's internal oscillator
  blinking two LEDs in anti-phase. It proved that power, JTAG, and PL
  configuration all work. Along the way I learned that dense bitstreams only
  flash cleanly with the patched ("soft edges") Pico firmware, and that a design
  clocked from the PS stays dark until FCLK0 is brought up over JTAG — which is
  exactly why the blink runs off the internal oscillator instead.
- **[Step 2 — Buttons drive the LEDs](research/02-buttons-and-leds/).** Adds
  input: the four shield buttons freeze the blink, force the LEDs on or off, or
  speed them up. Small lessons in active-low inputs, two-flop synchronizers, and
  gating a counter.
- **[Step 3 — Primitive HDMI: colour bars](research/03-hdmi-bars/).** First
  picture on the screen — eight 720p colour bars. The first design that needs the
  PS for a clean pixel clock, and the one where I learned FCLK0 only reaches the
  fabric after `ps7_post_config` enables the PS→PL level shifters.
- **[Step 4 — HDMI with button-switched patterns](research/04-hdmi-buttons/).** A
  bouncing square plus colour bars, gradient, and checkerboard, switched live with
  the four shield buttons.
- **[Step 5 — HDMI audio: the square beeps](research/05-hdmi-beep/).** First sound:
  the bouncing square plays a beep over HDMI audio every time it hits a wall,
  using the open-source hdl-util/hdmi core for the TMDS and audio packets.
- **[Step 6 — A ZX Spectrum 128](research/06-zx-spectrum-128/).** It all comes
  together: a real ZX Spectrum 128 on the board, built on the open-source Atlas
  `zx` core — 720p50 HDMI video and sound, the four shield buttons drive the boot
  menu, it loads games from tape through a pin, and it boots from SD on its own.
  The hard-won lessons are in the notes: an inverted keyboard `make` bit that made
  the menu run in circles, floating buttons that needed pull-ups, the original
  128 ROM (with Tape Tester) vs the +2 one, and a dense bitstream that only
  configures over PCAP, not plain JTAG.
- **[Step 7 — Waking up the ARM](research/07-arm-control-plane/).** The other half of
  the chip — the ARM — sat idle through Step 6. This adds an AXI register interface so the
  PS can **halt the Z80 and read/write the Spectrum's memory live**. Two milestones on
  hardware: the bare-metal AXI handshake (built and proven *first*, before integrating), then
  the ARM freezing the Z80 and painting its screen straight over the bus. It's the
  [speccy2010](https://github.com/mborik/speccy2010) blueprint on Zynq, and the foundation for
  loading games from SD. The bitstream is a clean superset of Step 6 — nothing regressed.
- **[Step 8 — Tear-free video](research/08-ddr-framebuffer/).** The single on-chip framebuffer
  tore on border-effect demos — the Spectrum's ~50.02 Hz and HDMI's 50.000 Hz aren't locked, so
  the read pointer drifts through the write pointer. This buffers the whole 51 KB ZX frame in PS
  DDR — a MiSTer-style triple buffer — and swaps the scanout only on the HDMI vblank, so the
  picture is tear-free everywhere, including bank-5/bank-7 shadow-screen flips. It's the first
  real use of the Step-7 AXI-HP path to PS DDR, and on-chip BRAM stays 60/60.
- **[Step 9 — A real PS/2 keyboard](research/09-ps2-keyboard/).** A PS/2 keyboard on two pins,
  muxed with the four buttons — the Atlas core already had the receiver and the matrix decoder,
  the buttons just faked the key-taps. Plus a normalised control-key map: `F11` = hard/cold reset
  (wipes RAM), `Ctrl+Alt+Del` = soft reset, `Ctrl+Alt+Ins` = NMI. The lesson worth keeping: a
  reset must not reset the DDR video pipeline — an AXI-HP master reset mid-burst hangs and freezes
  the picture. The on-screen menu and SD game loader come next.

More steps get added as I get them working.

## Changelog

- **2026-06-18 — Step 9: a real PS/2 keyboard.** A PS/2 keyboard on two pins, muxed with the four
  buttons (the Atlas core already shipped `ps2.v` + `keyboard.v`); a normalised key map — `F11`
  hard/cold reset with a RAM wipe, `Ctrl+Alt+Del` soft, `Ctrl+Alt+Ins` NMI — and an SD-bootable
  image. The OSD menu and SD game loader are the next chapter.
- **2026-06-17 — Step 8: tear-free DDR framebuffer.** The ZX frame is triple-buffered in PS DDR
  over AXI-HP and swapped only on the HDMI vblank — no more tear seam on border demos or
  shadow-screen flips. Verified with the `ula128` timing test and the *Mescaline* / `esh2`
  border demos; on-chip BRAM unchanged at 60/60.
- **2026-06-16 — Step 7: waking up the ARM.** An AXI PS↔PL control plane — the ARM can now
  halt the Z80 and write the Spectrum's memory, proven live on HDMI (the ARM paints the
  screen while the CPU is frozen). The bare-metal handshake first, then halt + screen-poke.
  Zero edits to the Atlas core; the foundation for SD game loading.
- **2026-06-16 — Step 6: a ZX Spectrum 128.** The first real machine on the board —
  128 boot menu, 720p50 HDMI video + sound, the buttons driving the menu, tape
  loading through a pin, and standalone SD boot, on the Atlas `zx` core.
- **2026-06-15 — Steps 0–5: board bring-up.** Setup & wiring, LED blink, buttons,
  HDMI colour bars, button-switched patterns, and HDMI audio — the runway the
  Spectrum sits on.
- **2026-06-15 — Project start.** Idea recorded; targeting the EBAZ4205 (Zynq-7010).

## License

[MIT](LICENSE) © Alexander Lavrinovich

The MIT licence covers this project's own work (the board-top, scripts, and notes).
The cores it builds on keep their own licences — see each step's credits and the
upstream projects ([Atlas `zx`](https://github.com/AtlasFPGA/zx),
[hdl-util/hdmi](https://github.com/hdl-util/hdmi)).

The tape input uses the *Tape Load Reader* front-end circuit from the
[Murmulator](https://murmulator.ru/) project
([schematics](https://github.com/AlexEkb4ever/MURMULATOR_classical_scheme), GPL-3.0) — an
external hardware add-on wired to the board, credited and linked here, not redistributed.
