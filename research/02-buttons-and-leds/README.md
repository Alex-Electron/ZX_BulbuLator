# Step 2 — Buttons drive the LEDs

Step 1 proved a bitstream runs on the board. This one adds *input*: the four
shield buttons now change what the two LEDs do. Same idea as before — clocked
from the chip's internal oscillator (`STARTUPE2` / `CFGMCLK`), no PS, no external
clock — so it flashes and runs exactly like Step 1.

## What the buttons do

The buttons are **active-low** with internal pull-ups: not pressed reads as 1,
pressed pulls the pin to 0. The bitstream ties each **FPGA pin** to a function;
hold a button and:

| FPGA pin | Net  | Hold it and… |
|----------|------|--------------|
| P19      | btn0 | the blink **freezes** (the counter stops, LEDs hold their state) |
| T19      | btn1 | **both LEDs on** |
| U20      | btn2 | **both LEDs off** |
| U19      | btn3 | the blink runs **faster** |

With nothing pressed, the LEDs blink in anti-phase, same as Step 1. The LEDs are
D18 and H18, the same two as Step 1.

> **Note.** The mapping above is by **FPGA pin**, which is what the bitstream
> fixes. Which physical button (the silkscreen KEY1–KEY4) reaches which pin
> depends on how your expansion board is wired, so go by the pin — wire the
> buttons to P19/T19/U20/U19 and they behave as listed.

## How it works

A few small ideas, each worth knowing:

- **Active-low input.** A press is a 0, so the code flips each pin to an
  active-high "pressed" signal (`~btn`).
- **Two-flop synchronizers.** The buttons are asynchronous to the clock, so each
  one goes through two flip-flops before it's used. That's the standard guard
  against metastability.
- **Gating a counter.** "Freeze" isn't a separate mode — KEY1 just stops the
  blink counter from incrementing (`if (!k1) cnt <= cnt + 1`), so the LEDs hold
  wherever they were.
- **A priority mux** decides the output: ON override wins, then OFF override,
  otherwise the (possibly frozen) blink drives the LEDs.

There's deliberately **no debounce** here. Every action is hold-to-act, so a few
milliseconds of contact bounce at press or release just flickers briefly and
doesn't matter. Edge-triggered actions (toggle on each press) would need
debounce — a good thing to add in a later step.

See [`buttons_leds.v`](buttons_leds.v) and [`buttons_leds.xdc`](buttons_leds.xdc).

## Build

Vivado 2023.1, part `xc7z010clg400-1`:

```
vivado -mode batch -source build_buttons_z010.tcl
```

You get `buttons_leds_z010.bit`, about 2,083,863 bytes — the 7010's fixed
configuration length, same as Step 1. A pre-built copy is included here.

## Flash

Exactly as in Step 1 — see [Step 0](../00-setup/) for the full how-to. Quickest:
open the bitstream in the Vivado Hardware Manager and program the `xc7z010`, or
use the helper script:

```
bash ../01-board-bringup-blink/jtag_flash.sh buttons_leds_z010.bit
```

Look for `End of startup status: HIGH`.

## Expected result

With nothing pressed, D18 and H18 alternate. Hold KEY1 and they freeze; KEY2
forces both on; KEY3 forces both off; KEY4 speeds the blink up. Inputs reach the
fabric and change its behaviour — the next thing the board needs to be useful.
