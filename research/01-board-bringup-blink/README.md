# Step 1 — Board bring-up: self-clocked LED blink

The first thing to do with a fresh EBAZ4205 (Zynq-7010) is prove three things at
once: the board powers up, the JTAG path reaches the PL, and a bitstream
actually runs. This step does that with the smallest design that can't really go
wrong: a counter on the chip's own internal oscillator driving two LEDs in
anti-phase.

No PS code, no external clock, no DDR. If the two LEDs alternate, the board and
the whole flash toolchain are good.

## Prerequisites

### Boot mode: SD card

The board must be strapped to boot from the SD card. This matters because the PL
is programmed over JTAG while the PS is up, and a clean SD boot leaves the PS in
a known-good state.

The EBAZ4205 picks its boot source with a single 0-ohm strap resistor near the
MIO pins. From the factory it boots from NAND. To boot from SD:

* Solder the MicroSD socket if it is not populated (many boards ship without it).
* Move the boot-select resistor to the **SD** position. On this board that is
  **R2577** (moved off the NAND position, R2584). This drives the MIO[5:4] boot
  strap to the SD setting.

Designators vary by board revision (R2577 / R2584 / R2585 show up depending on
the batch), so check silkscreen against your board. The rule is the same: one
0-ohm resistor, NAND position vs SD position.

A green power LED on the board lights when 5V is applied.

### JTAG programmer

You need a JTAG programmer that Vivado can talk to. Any Vivado-compatible cable
works — a Digilent or Xilinx adapter, an FTDI-based one, or, what I use here, a
Raspberry Pi Pico running the xvc-pico firmware over XVC. It's just one of the
options.

If you take the Pico route, use the firmware with the "soft edges" patch (slow
slew rate + 2 mA drive); without it, dense bitstreams fail with BAD_PACKET. The
stack is then `xvcd-pico` (XVC server on :2542) → `hw_server` (:3121) →
`vivado_lab`, which is what `jtag_flash.sh` here drives. With any other cable you
can skip that and just use the Vivado Hardware Manager directly.

## What it does

`blink.v` instantiates `STARTUPE2` and taps its `CFGMCLK` output, the internal
configuration oscillator (roughly 50–65 MHz). A 27-bit counter runs off that
clock; bit 24 drives `led0`, its inverse drives `led1`. The two LEDs blink in
anti-phase at about 1–2 Hz.

Because the clock comes from inside the chip, this design depends on nothing
external. That is the whole point: it isolates "can we configure and run the PL"
from every other variable.

| Signal | Pin | Net on the shield |
|--------|-----|-------------------|
| led0   | D18 | LED (anti-phase A) |
| led1   | H18 | LED (anti-phase B) |

These are the same shield LEDs the HDMI demo uses (`led_lock` / `led_heart`).

## Build

Vivado 2023.1, part `xc7z010clg400-1`:

```
vivado -mode batch -source build_blink_z010.tcl
```

The result is `blink_z010.bit`, about 2,083,856 bytes. That size is the fixed
configuration length of the 7010, so it doubles as a sanity check that the build
targeted the right device.

A pre-built `blink_z010.bit` is included here.

## Flash

With the board on SD boot and the Pico attached:

```
bash jtag_flash.sh /path/to/blink_z010.bit
```

The script restarts the `xvcd-pico` + `hw_server` stack if needed, opens the XVC
target, finds the `xc7z010`, and programs it. Success looks like:

```
End of startup status: HIGH
PROGRAMMED=1
```

## Expected result

D18 and H18 alternate at about 1–2 Hz: one on while the other is off, swapping a
couple of times a second. That confirms power, the JTAG chain, PL configuration,
and a running clock — the foundation every later step builds on.

## Note for the next step

This blink runs on the internal oscillator on purpose. Designs that need the PS
clock (the HDMI demo runs its pixel clock off FCLK0) will not light up from a
plain SD boot, because the FSBL leaves FCLK0 at 50 MHz while the demo expects
100 MHz. Bringing FCLK0 up to 100 MHz over JTAG with `ps7_init` is its own
bring-up step.
