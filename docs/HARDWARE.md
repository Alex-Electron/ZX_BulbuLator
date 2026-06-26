# Hardware

Languages: **English** · [Русский](HARDWARE.ru.md)

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: lavrinovich.alex@gmail.com

## Board: EBAZ4205

The EBAZ4205 is a Zynq-7000 board pulled out of Ebang Bitcoin mining gear. It is
cheap and easy to find, which is the whole reason it was picked for this project.

The target is the **Zynq-7010** (`XC7Z010`) version — the most common one on the
second-hand market, so building and testing against it keeps the work lined up
with what most people actually have in hand. Everything here targets
`xc7z010clg400-1`.

There are also boards out there with a **custom-soldered `XC7Z020`** in place of
the 7010 — the same board, but with more programmable logic. You can buy those
too; they cost more, since the bigger chip is an aftermarket rework rather than
how these boards originally shipped. (I have one of those as well.) The package
is identical (`clg400`), so the pinout matches and a 7020 build is just a change
of `-part`.

PetaLinux 2024.1 already boots on the board here.

## Board resources

The EBAZ4205 was a mining control board, so it is well equipped for the price:

| | EBAZ4205 |
|---|---|
| SoC | Xilinx Zynq-7000 `XC7Z010` (`clg400`, -1 speed grade) |
| Processor (PS) | dual-core ARM Cortex-A9, 666 MHz |
| DDR3 (on the PS) | 256 MB |
| NAND flash | 128 MB |
| Ethernet | 10/100, IP101GA PHY (25 MHz crystal) |
| microSD | on-board slot — the boot device for this project |
| PS reference clock | 33.33 MHz; the design brings up a 100 MHz PL fabric clock (FCLK0) |
| Power | 5–12 V |
| Factory boot | NAND; strapped to SD here |
| LEDs | two on-board (used for the bring-up blink) |

The programmable logic is where the chip choice bites. The `XC7Z010` is a small
part, and the dense ZX build already fills its Block RAM:

| Programmable logic | `XC7Z010` (target) | `XC7Z020` (reworked board) |
|---|---|---|
| Logic cells | 28,000 | 85,000 |
| LUTs | 17,600 | 53,200 |
| Flip-flops | 35,200 | 106,400 |
| Block RAM | 60 × 36 Kb (2.1 Mb) | 140 × 36 Kb (4.9 Mb) |
| DSP slices | 80 | 220 |

The Spectrum's RAM sits in that Block RAM (60/60 used on the current build), which
is why moving the RAM off an external SDRAM controller and into on-chip BRAM
matters so much here. The 256 MB DDR3 carries the triple-buffered framebuffer over
AXI instead. The 7020 boards roughly triple every fabric number,
which is the headroom a 16-bit machine would need — but the package and pinout are
identical, so a 7020 build is only a change of `-part`.

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
