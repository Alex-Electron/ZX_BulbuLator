# Step 13 — Player: Universal ARM music synthesis over HDMI

Languages: **English** · [Русский](README.ru.md)

![The OSD file browser playing a .psg file, indicated by the play icon in the title bar](images/player-step13.jpg)

*A `.psg` track selected in the F5 browser. The ARM processor parses the file, soft-synthesises the AY-3-8910 chip, and streams PCM audio directly to the HDMI FIFO, while the ZX Spectrum core runs (or sits idle) in the background.*

Step 12 gave us a snapshot loader. But retro computers have an amazing music scene, and enjoying that music shouldn't require loading a specific player application inside the Spectrum itself. This step introduces a universal, machine-agnostic retro music player built directly into the ARM control plane. 

For the MVP, we start with `.psg` files (raw AY-3-8910 register dumps). Press **Enter** on a `.psg` file in the browser, and it plays over the HDMI output.

## Why software synthesis?

Initially, the plan was to inject AY register states from the file directly into the FPGA's real AY chip over the AXI bus (similar to how RAM is injected in Step 12). However, an architectural decision was made to take a different route: **the ARM software-emulates the sound chips and outputs raw PCM to the HDMI interface.**

Why this architecture?
- **No injection artifacts:** The core's real AY chip is left alone. We avoid state conflicts and squeals caused by fighting the Z80 for register access.
- **Machine agnostic:** The audio plays over HDMI regardless of what core is loaded. It will work even if you switch the FPGA to an NES or C64 core later.
- **Scalability:** It easily extends to formats the ZX core hardware lacks. Tracker modules (`.pt3`, `.mod`) and even General Sound (which would otherwise require its own Z80 and RAM in the FPGA) can be fully emulated on the idle ARM core.

## How it works: AYUMI + D-Cache + AXI FIFO

The player pipeline consists of several key components:

1. **AYUMI Soft-Synth:** We use the MIT-licensed AYUMI library, a highly accurate AY/YM software synthesizer. The ARM parses the `.psg` frames and feeds the 14 AY registers into AYUMI's state machine.
2. **D-Cache Foundation:** To make software synthesis run in real-time on the 666 MHz Cortex-A9, Data Cache (D-cache) is enabled. A custom linker script (`lscript.ld`) reserves a non-cacheable window at the top of DDR for the framebuffer and DMA, allowing the player application to run ~10x faster from cache without causing visual tearing or memory corruption.
3. **Tempo Lock:** The `player_pump()` function is called cooperatively in the main OSD loop. To prevent the song from sprinting ahead or dragging behind, the tempo is strictly locked to the real-time wall-clock (`XTime`) at the HDMI audio rate (47996 Hz), not to how fast the CPU can render.
4. **AXI Audio FIFO:** The ARM pushes 32-bit signed stereo samples `{R[15:0], L[15:0]}` to a new hardware FIFO in the PL.

## In the OSD

- **Play/Pause**: Press **Enter** or **Space** on a `.psg` file in the F5 browser to start. **Space** toggles pause/resume.
- **Stop**: Press **Backspace** to stop the player and hand audio control back to the FPGA core. **Esc** closes the OSD menu but lets the music keep playing in the background.
- **Auto-advance**: The player automatically advances to the next track when reaching the end of the file.
- **Indicator**: A small Play/Pause icon appears in the OSD title bar next to the firmware version.

## The control-plane registers

The AXI control plane adds three new registers for the audio path, and the version bumps to `0xB01B000B`:

| Addr | Name | R/W | Meaning |
|---|---|---|---|
| `0x00` | `VERSION` | R | `0xB01B000B` |
| `0x78` | `AUDIO_CTRL` | W | bit 0 = Player Active (mux player PCM to HDMI, mute fabric audio) |
| `0x7C` | `AUDIO_FIFO` | W | Push `{R[15:0], L[15:0]}` signed-16 PCM sample |
| `0x80` | `AUDIO_STAT` | R | bit 0 = empty, bit 1 = full |

When the player is active (`AUDIO_CTRL = 1`), the bitstream's audio multiplexer selects the ARM's PCM stream over the fabric core's audio.

## Build, flash, run

**Build the bitstream.** `./build.sh` → `bulbulator_zx_loader.bit`. This step adds the audio FIFO and multiplexer logic to `sources/axi_ctl.v` and the top module.

**Build the ARM loader app.** `cd arm && ./build_loader.sh` → `loader.elf`. As in the earlier steps, this still builds against a Vitis BSP workspace, bringing in the D-Cache configurations and linking the FatFs (xilffs) and SD driver (`xsdps`) objects directly.

**Flash over JTAG and run.** `./loader_run.sh` PCAP-configures the bitstream onto the board (converting it to a `.bit.bin` via `bootgen` to avoid plain JTAG configuration errors, as in Steps 6–12), then stops, loads, and runs the compiled `arm/loader.elf` on Cortex-A9 #0.

**Boot from SD (no host, no JTAG).** Copy `flash/BOOT.BIN` onto the card's FAT `boot` partition, strap the board for SD boot, and power on. To rebuild `BOOT.BIN` yourself, run `flash/build_boot.sh` (which packages the FSBL, the new bitstream, and the loader app together, including the glibc bootgen segfault workaround).

## Files

```
sources/axi_ctl.v                  control plane + AUDIO registers (VERSION 0xB01B0013)
sources/bulbulator_zx_ddr_top.v    full top: the Step 11/12 design + audio FIFO instantiation and HDMI mux
arm/player.c                       the universal music player (machine-agnostic ARM soft-synth)
arm/loader_main.c                  updated OSD app: F5 browser invokes player on .psg, draws icons
arm/lscript.ld                     custom linker script enabling D-Cache
arm/loader.elf                     prebuilt ARM app (firmware tag v0.13)
flash/BOOT.BIN                     ready SD image (FSBL + bitstream + loader app)
bulbulator_zx_loader.bit           prebuilt bitstream
```

*(Note: The AYUMI library source (`ayumi.c`, `ayumi.h`) is integrated into the `third_party/ayumi/` directory. It is a highly accurate emulation of the AY-3-8910 / YM2149 sound chips written by **Peter Sovietov** ([true-grue/ayumi](https://github.com/true-grue/ayumi), MIT License).)*