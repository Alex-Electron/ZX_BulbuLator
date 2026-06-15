# BulbuLator

Developed by: Alexander Lavrinovich<br>
GitHub: https://github.com/Alex-Electron<br>
Email: EU1L@mail.ru

A hardware ZX Spectrum emulator on a Xilinx Zynq SoC. The plan is to take the
MiST / MiSTer Spectrum cores and bring them up on the cheap, easy-to-find
EBAZ4205 board, reworking them for the Xilinx architecture along the way.

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

## License

[MIT](LICENSE) © Alexander Lavrinovich
