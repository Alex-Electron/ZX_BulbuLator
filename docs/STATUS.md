# Status

> Developed by: Alexander Lavrinovich · GitHub: https://github.com/Alex-Electron · Email: lavrinovich.alex@gmail.com

Last updated: 2026-06-17

## Done

A real ZX Spectrum 128 runs on the EBAZ4205 (7010): the 128 boot menu over 720p50
HDMI with sound, the four shield buttons driving the menu, tape loading through an
audio pin, and standalone SD boot — built on the open-source Atlas `zx` core, with the
display checked against ZEsarUX (Step 6). The dense bitstream loads over PCAP, since
plain JTAG configuration trips a `BAD_PACKET` bug on this setup. The ARM is no longer
idle: an AXI control plane lets the PS halt the Z80 and read or write the Spectrum's
memory live (Step 7). And the video is tear-free now — the ZX frame is triple-buffered
in PS DDR and swapped only on the HDMI vblank, so border demos and shadow-screen flips
stop tearing (Step 8). Demos and timing tests inject over the control plane and come up
clean: mescaline, esh2, the ula128 timing test.

## Doing

Running demos and 128-timing tests over the control plane and checking them on real
hardware; turning the ARM's halt-and-poke into a proper bare-metal `.sna` / `.z80` SD
loader.

## Next

The `.sna` loader on the ARM (bank-7 paging + the I/O ports), then the bigger machines
the proven PS DDR path now unlocks — Pentagon 1024, NES with large ROMs.
