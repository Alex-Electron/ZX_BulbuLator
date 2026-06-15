# Research

Bring-up notes and experiments for the EBAZ4205 (Zynq-7010), each as a
self-contained step with sources and a ready-to-flash bitstream. These are the
building blocks the BulbuLator cores sit on top of, written down as they get
verified on real hardware.

| Step | What it covers |
|------|----------------|
| [00 — Setup & wiring](00-setup/) | From a bare board: power, boot-mode strap, JTAG programmer (real cable or Pico), installing the software, and flashing a bitstream |
| [01 — Board bring-up: LED blink](01-board-bringup-blink/) | Power, JTAG → PL path, and a running bitstream, using only the chip's internal oscillator |

More steps get added here as the bring-up continues (FCLK0 over JTAG, HDMI
output, buttons, sound, and so on).
