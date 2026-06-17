# Research

Languages: **English** · [Русский](README.ru.md)

Bring-up notes and experiments for the EBAZ4205 (Zynq-7010), each as a
self-contained step with sources and a ready-to-flash bitstream. These are the
building blocks the BulbuLator cores sit on top of, written down as they get
verified on real hardware.

| Step | What it covers |
|------|----------------|
| [00 — Setup & wiring](00-setup/) | From a bare board: power, boot-mode strap, JTAG programmer (real cable or Pico), installing the software, and flashing a bitstream |
| [01 — Board bring-up: LED blink](01-board-bringup-blink/) | Power, JTAG → PL path, and a running bitstream, using only the chip's internal oscillator |
| [02 — Buttons drive the LEDs](02-buttons-and-leds/) | Reading the four shield buttons (active-low, synchronized) and using them to change the LEDs |
| [03 — Primitive HDMI: colour bars](03-hdmi-bars/) | First picture on screen — eight 720p colour bars, clocked from the PS (the level-shifter / `ps7_post_config` lesson) |
| [04 — HDMI with button-switched patterns](04-hdmi-buttons/) | A bouncing square and four patterns (bars, gradient, checkerboard) the shield buttons switch between |
| [05 — HDMI audio: the square beeps](05-hdmi-beep/) | First sound — the bouncing square beeps over HDMI audio when it hits a wall, using the hdl-util/hdmi core |
| [06 — A ZX Spectrum 128](06-zx-spectrum-128/) | It all comes together: a real ZX Spectrum 128 on the board — HDMI video + audio, the shield buttons drive the boot menu, it loads games from tape through a pin, and boots from SD. Built on the Atlas `zx` core |
| [07 — Waking up the ARM: a PS↔PL control plane](07-arm-control-plane/) | An AXI register interface so the idle ARM can halt the Z80 and read/write the Spectrum's memory live — the foundation for SD game loading. A clean superset of Step 6 |
| [08 — Tear-free video: a DDR double-buffered framebuffer](08-ddr-framebuffer/) | Buffers the 51 KB ZX frame in PS DDR (triple-buffered, swapped on the HDMI vblank) so border-effect demos and shadow-screen flips stop tearing — the first real use of the AXI-HP path to DDR |

Steps 0–5 are the runway; Step 6 is the first actual machine. From here the
bring-up notes turn into porting cores (more accuracy, more demos, and eventually
bigger machines that need PS DDR).
