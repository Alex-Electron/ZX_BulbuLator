# BulbuLator

![BulbuLator — ZX Spectrum on Zynq-7010 (EBAZ4205)](docs/images/splash.jpg)

Developed by: Alexander Lavrinovich<br>
GitHub: https://github.com/Alex-Electron<br>
Email: EU1L@mail.ru

A hardware ZX Spectrum emulator on a Xilinx Zynq SoC. The plan is to take the
MiST / MiSTer Spectrum cores and bring them up on the cheap, easy-to-find
EBAZ4205 board, reworking them for the Xilinx architecture along the way.

![EBAZ4205 board wired to the HDMI/audio and buttons expansion shield](docs/images/board.jpg)

*The EBAZ4205 (Zynq-7010) next to the HDMI / audio + buttons shield, powered up
and running.*

The biggest change from the original cores is memory. MiST drives an external
SDRAM controller; here the Spectrum RAM sits in on-chip BRAM and is reached over
AXI, which takes a lot of timing and routing pain off the table on this board.

This repo is a working notebook and an idea record. It fills up as things get
checked on real hardware.

## Target board

The primary board, from 2026-06-15 on, is the EBAZ4205 with the Zynq-7010
(`XC7Z010`). It is the most common version of this board on the second-hand
market, so the cores get built and tested against it first. The 7020
(`XC7Z020`) is a secondary target; it needs its own FSBL and the J8 header
soldered on. Details are in [`docs/HARDWARE.md`](docs/HARDWARE.md).

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

A snapshot is below; the live state lives in [`docs/STATUS.md`](docs/STATUS.md).

The 128K core (A-Z80 / T80) is imported and the top module builds in Vivado. The
HDMI / audio shield is up and putting out a clean 50 Hz (720×576@50Hz). On-board
buttons are mapped to keyboard half-rows (QAOP + Space), enough to play games.
Flashing the dense bitstreams used to fail until a Raspberry Pi Pico running
custom XVC firmware (slow slew, 2 mA drive) sorted it out. Next job is a full
physical PS/2 keyboard through the matrix logic.

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
- **[Step 4 — HDMI with button-switched patterns](research/04-hdmi-buttons/).**
  The full 7020 demo brought up on the 7010: a bouncing square plus colour bars,
  gradient, and checkerboard, switched live with the four shield buttons.

More steps get added as I get them working.

## License

[MIT](LICENSE) © Alexander Lavrinovich
