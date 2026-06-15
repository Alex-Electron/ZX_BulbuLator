# Hardware

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: EU1L@mail.ru

## Board: EBAZ4205

The EBAZ4205 is a Zynq-7000 board pulled out of Ebang Bitcoin mining gear. It is
cheap and easy to find, which is the whole reason it was picked for this project.

The target is the **Zynq-7010** (`XC7Z010`) version — the most common one on the
second-hand market, so building and testing against it keeps the work lined up
with what most people actually have in hand. Everything here targets
`xc7z010clg400-1`.

PetaLinux 2024.1 already boots on the board here.

## Expansion shield

There is a custom HDMI / audio shield, built and working. It puts out a clean
50 Hz PAL-style signal (720×576@50Hz) with no flicker and carries the I²S audio
path.

## Programming and JTAG

The larger 128K bitstreams would not flash reliably over plain XVC; they kept
dying with bad-packet errors. The fix was a Raspberry Pi Pico running custom XVC
firmware with a slow slew rate and 2 mA drive strength. With that firmware the
128K cores flash over JTAG / XVC in a couple of seconds, first try.

Synthesis and bootgen (Vivado, Vitis, the JTAG daemons) run on a ThinkPad.
Flashing happens locally through the Pico.
