# Building Step 15 from source

Languages: **English** · [Русский](BUILDING.ru.md)

This is the full path from a clean clone to a board that boots: the FPGA cores, the ARM shell firmware,
the boot image and the SD card. If you only want to try it, you don't need any of this: the prebuilt files
are in [`bitstreams/`](bitstreams/), and the main [README](../../README.md#try-it) says where they go.

Everything here was checked by doing it: a fresh `git clone`, then these commands, on
Ubuntu 26.04 with Vivado 2023.1. The ZX core built this way is identical, byte for byte, to
`bitstreams/ATLAS_B0198.bit.bin`.

## What you need

- **Linux.** The commands are bash. Vivado runs on Windows too, but the scripts here were not tried there.
- **Vivado 2023.1.** The free Standard edition covers the `XC7Z010`. It provides `vivado` and `bootgen`.
  Before building, run `source /tools/Xilinx/Vivado/2023.1/settings64.sh` (adjust the path to your install).
- **For the ARM firmware only:** Vitis 2023.1 (for `xsct` and the driver sources) and an `arm-none-eabi-gcc`
  with newlib, for example Ubuntu's `gcc-arm-none-eabi` and `libnewlib-arm-none-eabi` packages.
- `git`, `python3`, and about 1 GB of free disk for the clone and one build tree.

## 1. Get the sources

```sh
git clone https://github.com/Alex-Electron/ZX_BulbuLator.git
cd ZX_BulbuLator
./get_deps.sh
```

`get_deps.sh` fetches the third-party cores into `cores/` and `deps/`, each pinned to an exact commit:
the Atlas ZX core, the hdl-util HDMI core, the MiSTer ZX core (a few modules are shared with it) and the Digilent library. It only clones HDL and needs no Xilinx tools.

## 2. Build the FPGA cores

There are two cores, ZX and NES. Both are built from the same tree, and `sources/assemble.sh` gathers that
tree into `research/15-pentagon/sources/build/`. **`assemble.sh` wipes `sources/build/` every time**, so
copy a finished bitstream out before building the next one.

**The ZX core (Atlas): 48K, 128K and Pentagon.** This is the one that matters.

```sh
research/15-pentagon/build.sh
# -> research/15-pentagon/sources/build/bulbulator_zx_loader.bit
```

On a 16-thread laptop with 64 GB of RAM it takes about four minutes. When it finishes, check the log for two things. Timing must be met, and there
must be no `[Synth 8-9873]` warning: that one means two files defined a module with the same name and
the later one silently replaced the other (this once shipped a silent sound chip).

```sh
cd research/15-pentagon/sources/build
grep -i "timing constraints are" vivado.log     # expect: All user specified timing constraints are met.
grep "CRITICAL WARNING.*8-9873" vivado.log      # expect: nothing
```

**The NES / Dendy core:**

```sh
research/15-pentagon/sources/assemble.sh
cd research/15-pentagon/sources/build
vivado -mode batch -source build_nes.tcl
# -> bulbulator_zx_loader_nes.bit
```

The published `bitstreams/NES_CE29.bit.bin` is the NES core that runs on my board. The current sources build
CE30, which differs from it in the shared shell and has not been checked on the board yet.

To check your build against the published one, convert both to `.bit.bin` (below) and compare: the
`.bit` file itself carries the build date in its header, the `.bit.bin` does not.

**Convert a core for the card.** The shell loads cores into the FPGA at run time through PCAP, and PCAP
wants the `.bit.bin` format:

```sh
research/15-pentagon/flash/bit2bin.sh research/15-pentagon/sources/build/bulbulator_zx_loader.bit
# -> .../bulbulator_zx_loader.bit.bin  (goes to 0:/CORES/ATLAS.BIT.BIN)
```

## 3. Build the ARM shell firmware

The firmware is `arm/loader.elf`. The repo ships a prebuilt one; this is how to rebuild it.

It needs two things from outside the repo. **Vitis 2023.1**, for `xsct` and the Xilinx driver sources
(default path `/tools/XilinxVitis/Vitis/2023.1`, override with `VITIS=`). And an **`arm-none-eabi-gcc` with
newlib** in `PATH`: the published firmware was built with Ubuntu's `gcc-arm-none-eabi` 14.2.rel1 and
`libnewlib-arm-none-eabi` 4.6.0, not with the compiler inside Vitis.

```sh
research/15-pentagon/arm/bsp/make_bsp.sh      # platform + both BSPs -> research/15-pentagon/arm/bsp/ws
research/15-pentagon/arm/build_loader.sh      # -> research/15-pentagon/arm/loader.elf
```

`make_bsp.sh` takes about 30 seconds. It runs `xsct` on `bsp/create_platform.tcl` with the hardware
description `bsp/ebaz4205_ps7.xsa` and creates two domains: core 0 runs the shell (standalone, with FatFs
set for long names and exFAT), core 1 gets lwIP 2.1.3 for the network panel. Then it applies the two
patches in `bsp/patches/` to the core-0 drivers, which a board without a card-detect line needs: a shorter
SD timeout, and one re-initialise-and-retry when an SD read or write fails. `build_loader.sh` compiles
the shell against that workspace.

Options: `WS=<dir>` puts the workspace somewhere else (give the same `WS` to `build_loader.sh`), `FORCE=1`
regenerates an existing one, and `MAKE_XSA=1` first rebuilds the `.xsa` in Vivado from the PS7 settings in
`bsp/ps7_params.tcl` (processing system only, no bitstream, about 20 seconds).

With the compiler versions above the loadable image is identical to the published one, byte for byte
(compare `arm-none-eabi-objcopy -O binary` output). The `.elf` files themselves differ only in the debug
information, which records the absolute build paths. `build_loader.sh` writes its result over the prebuilt
`arm/loader.elf`, so after a build git shows that file as modified; that is expected.

**The first-stage loader** `flash/fsbl.bin` is shipped prebuilt. `make_bsp.sh` also builds a Zynq FSBL at
`$WS/ebaz/zynq_fsbl/fsbl.elf`, but with FCLK0 at the default instead of the 100 MHz the design wants. Its
PS7 init tables match the shipped file byte for byte, its code does not (the shipped one came from an
older compiler), and it has not been boot-tested, so use the shipped `fsbl.bin`. If you want to try:

```sh
cd $WS/ebaz/zynq_fsbl
sed -i -E 's/EMIT_MASKWRITE\(0XF8000170, 0x03F03F30U ?, ?0x00800800U\)/EMIT_MASKWRITE(0XF8000170, 0x03F03F30U ,0x00400400U)/g' ps7_init.c
rm -f *.o fsbl.elf && make
arm-none-eabi-objcopy -O binary fsbl.elf fsbl.bin
```

## 4. Build the boot image

`BOOT.BIN` is what the board's BootROM reads from the card: the first-stage loader (FSBL), a bitstream
and the firmware.

```sh
research/15-pentagon/flash/mkboot_zx.sh \
    research/15-pentagon/sources/build/bulbulator_zx_loader.bit  BOOT.BIN  [path/to/loader.elf]
```

Without the third argument it takes `arm/loader.elf`, the prebuilt firmware in the repo. The FSBL is
`flash/fsbl.bin`, the same one as in Step 14. The script needs `bootgen` (from `PATH`, or set `BOOTGEN`)
and `arm-none-eabi-objcopy`.

bootgen writes the bitstream's file name into the image, so a boot image differs from
`bitstreams/BOOT_B0198_v0.15.446.BIN` in those few bytes unless the input is named the same. Built from
the published files it matches byte for byte:

```sh
cp research/15-pentagon/bitstreams/ATLAS_B0198.bit /tmp/B0198.bit
research/15-pentagon/flash/mkboot_zx.sh /tmp/B0198.bit /tmp/BOOT.BIN
cmp /tmp/BOOT.BIN research/15-pentagon/bitstreams/BOOT_B0198_v0.15.446.BIN && echo identical
```

## 5. Put it on the board

**With a card reader (the simple way).** Format a microSD card as FAT32 and copy the files as the
[card table in the main README](../../README.md#try-it) shows: `BOOT.BIN` in the root, the `.bit.bin`
cores in `CORES/`, ROM sets in `ROMS/`. The full layout is in [`docs/SDCARD.ru.md`](docs/SDCARD.ru.md).
The board must be switched to boot from the card once, with one resistor: see
[Step 0](../00-setup/).

**When you update the ZX core, replace both `BOOT.BIN` and `CORES/ATLAS.BIT.BIN`.** A cold start brings the
core up from `BOOT.BIN`, and switching machines in the menu reloads it from `CORES/`. Update only one and
you will be running the old core half the time.

**Over JTAG, without taking the card out.** This needs a JTAG cable ([Step 0](../00-setup/)), `hw_server`
running on port 3121, and the firmware already running on the board with the navigator open: while a menu
is open or a tape is playing, the firmware does not serve the host at all. Three rules, each one paid for
with a board that would not boot:

1. write to a **temporary** name first;
2. check its size **in the directory listing**, not in the "written" field, which lies when the card is
   full;
3. only then rename it over the real file.

```sh
xsdb research/15-pentagon/tools/put_retry.tcl BOOT.BIN 0:/BOOT.NEW
xsdb research/15-pentagon/tools/card_ls.tcl 0:/
xsdb research/15-pentagon/tools/card_mv.tcl 0:/BOOT.BIN 0:/BOOT.BAK
xsdb research/15-pentagon/tools/card_mv.tcl 0:/BOOT.NEW 0:/BOOT.BIN
```

`put_retry.tcl` checks the transfer buffer before every attempt and reads the file back after writing,
because the firmware uses the same buffer for its own file reads.

**Never run `rst -system` on a running board.** The fabric keeps writing to DDR while the processor is in
reset, a half-finished burst gets stuck, and the picture freezes until you remove power.

## 6. Check what is running

The navigator's top line shows the firmware and the core build, for example `v0.15.446 / b0198`.
The same core number is readable at control-plane register `0x00` (`0xB01B0198`).
