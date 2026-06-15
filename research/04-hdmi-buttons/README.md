# Step 4 — HDMI with button-switched patterns

Step 3 put a still image on the screen. This adds interactivity: the four shield
buttons change what's drawn. It's the full demo that first ran on the 7020,
rebuilt for the 7010. Same video path as Step 3 (PS7 → FCLK0 → MMCM → rgb2dvi),
same flash recipe — only the pattern generator is richer.

## What's on screen

A dark-blue **960×720 window centred on the screen** with a bouncing 144×144
square (the default mode), its colour cycling every frame. The four buttons:

| Button | Pin | Press to… |
|--------|-----|-----------|
| KEY1   | P19 | cycle the pattern: square → colour bars → gradient → checkerboard |
| KEY2   | T19 | invert the colours |
| KEY3   | U20 | slow the animation down |
| KEY4   | U19 | speed it up |

Buttons are edge-triggered with ~14 ms debounce, so a single press acts once
(not hold-to-act like Step 2). The mapping is by FPGA pin; physical KEY labels on
a shield may differ (see [Step 0](../00-setup/#expansion-board-reference)).

## Why it's a centred window, not full screen

The HDMI *signal* is full 1280×720, but the demo only draws content inside a
centred **960×720** region (exactly **4:3**) and fills the sides with black —
"pillarboxing". Retro content is 4:3; stretching it across a 16:9 panel would
make everything look fat, so the black side bars keep the proportions right, like
a CRT. To go full width instead, set `WX0=0` and `WW=1280` in
[`pattern_gen3.v`](pattern_gen3.v) and rebuild.

## Build

Same block design as Step 3 (it reuses `clkgen2.v`, the `clk_wiz` MMCM, and
Digilent's `rgb2dvi`), with [`pattern_gen3.v`](pattern_gen3.v) as the pattern
source and [`hdmi_btn720.xdc`](hdmi_btn720.xdc) adding the four button pins.

```
export VIVADO_LIBRARY=~/vivado-library
vivado -mode batch -source build_720pl_z010.tcl
```

Part `xc7z010clg400-1`, output ~2,083,867 bytes. A prebuilt `hdmi720_z010.bit` is
included.

## Flash

PS-clocked like Step 3, so it uses the same reliable two-part recipe (program the
PL with `vivado_lab`, then `ps7_init` + `ps7_post_config` over `xsdb`):

```
bash flash_demo.sh hdmi720_z010.bit
```

`End of startup status: HIGH`, then `PS7_INIT_DONE` and `PS7_POST_CONFIG_DONE`.
See [Step 3](../03-hdmi-bars/) for the why behind that sequence, and
[Step 0](../00-setup/) for the JTAG setup. With a normal SD boot the FSBL brings
the PS clock up for you.

## Expected result

The bouncing square appears in the centred window with H18 blinking. KEY1 cycles
through the four patterns, KEY2 inverts, KEY3/KEY4 change speed. Input plus a real
picture — the board is now genuinely interactive.
