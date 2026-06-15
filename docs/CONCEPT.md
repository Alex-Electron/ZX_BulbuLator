# Concept

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: EU1L@mail.ru

BulbuLator takes the MiST / MiSTer ZX Spectrum cores and brings them up on the
EBAZ4205 board (Zynq-7000). The main architectural difference from the original
cores is memory: instead of the external SDRAM controller MiST uses, the
Spectrum RAM sits in on-chip BRAM and is reached over AXI. That alone removes a
whole class of timing and routing problems on this board.

## Cores

Three to start with: ZX Spectrum 48K, ZX Spectrum 128K, and Pentagon 128. The
Pentagon needs accurate INT timing, which means 320 lines per frame.

## Input devices

PS/2 keyboard first. It runs on two FPGA pins with 1N4148 diodes and a 10k
pull-up to 3.3V. After that come the joysticks (Kempston on DB9, Sinclair) and
Dendy / Sega gamepads, read either through 74HC165 shift registers or directly.

## Sound

Four sources. The AY-3-8912 / YM2149F is the standard 128K chip. Turbo Sound
adds a second AY for FM. General Sound can either run as an emulated GS Z80 with
its sample memory inside the FPGA, or move onto the ARM Cortex-A9 with output
over I²S. The beeper is the plain 48K speaker.

## Storage and filesystem

Virtual disks come first: a VG93 / WD1793 TR-DOS where the ARM reads `.trd` and
`.scl` images off the SD card and feeds them to the FPGA over AXI. DivMMC /
ESXDOS covers the modern boot path with an SD card emulated inside.

The part I most want to build is the physical floppy drive. Route the WD1793
signals (`STEP`, `DIR`, `WDATA`, `WGATE`, and the rest) out to GPIO through a
3.3V→5V level shifter, and a real 3.5" or 5.25" drive can be plugged straight
in.

## Video

VGA and HDMI. The expansion shield for it is already built and working.
Scanlines reproduce the look of a CRT.

## Scalability

An expansion shield with a cross-bus (ZX BUS / Nemo Bus) so physical Spectrum
peripheral cards can be used.

## Ideas pulled from MiST / MiSTer / TSConf

1. OSD menu. A translucent file picker drawn over the Spectrum image. The FPGA
   draws it; the ARM sends the menu text over AXI.
2. Save states. Stop a game, dump the Z80 state and all RAM to the SD card
   through the ARM, and pick it up again later.
3. Tape emulation. Load `.tap` / `.tzx` files by trapping the ROM load routines
   or by replaying the audio signal into the tape port. An audio input pin lets
   a phone or cassette player feed in a real signal.
4. ROM switcher. Swap ROMs on the fly: Classic 48, 128, +3e, OpenSE BASIC, Gluk
   Reset Service.
5. Soft-USB. If PS/2 turns out to be too limiting, put a USB 1.1 host controller
   in FPGA logic with no extra PHY chip and read modern keyboards and gamepads
   that way.
6. Fast-forward. Lift the 3.5 MHz Z80 limit and run the FPGA up to 56 MHz to
   skip loading screens and long computations.
7. Networking. The board has physical Ethernet, so run an FTP server on the ARM
   and copy games in over the network without touching the SD card.
