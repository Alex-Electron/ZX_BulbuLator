# Status

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: lavrinovich.alex@gmail.com

Last updated: 2026-06-15

## Done

The ZX Spectrum 128K core (A-Z80 / T80) is imported and its top module builds in
Vivado 2023.1 on the ThinkPad. The HDMI / audio shield is up and outputs a clean
50 Hz, 720×576@50Hz, with no flicker. On-board buttons are mapped to keyboard
half-rows (QAOP + Space); the Space/M split works and the game Ringo loads and
plays. Flashing the dense bitstreams is solved: a Pi Pico running custom XVC
firmware (slow slew, 2 mA drive) gets the 128K cores onto the board over JTAG in
seconds, first try. The toolchain (Vivado, Vitis, JTAG daemons) now lives on the
ThinkPad.

## Doing

Moving the primary target over to the 7010 board and re-checking the cores on
it.

## Next

Wire up a full physical PS/2 keyboard through the matrix logic (`zx_kbd.sv`).
