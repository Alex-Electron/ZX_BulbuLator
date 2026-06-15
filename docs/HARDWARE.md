# Hardware

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: EU1L@mail.ru

## Board: EBAZ4205

The EBAZ4205 is a Zynq-7000 board pulled out of Ebang Bitcoin mining gear. It is
cheap and easy to find, which is the whole reason it was picked for this
project.

These boards come with one of two chips:

| Variant | Chip      | Role in this project                            |
|---------|-----------|-------------------------------------------------|
| 7010    | `XC7Z010` | Primary target, from 2026-06-15                 |
| 7020    | `XC7Z020` | Secondary; needs its own FSBL and a soldered J8 |

### Why the 7010 is primary

The 7010 is simply the version most people have. Building and testing against it
first keeps the work lined up with what is actually sitting on desks. The 7020
has more logic, but it is rarer and needs extra bring-up (a separate FSBL, the
J8 header soldered on), so it stays the secondary board for now.

PetaLinux 2024.1 already boots on the 7010 board here.

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
