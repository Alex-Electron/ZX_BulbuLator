# atlas-zx-ps2-watchdog — patched `ps2.v`

This is the **`ps2.v`** module of the open **Atlas `zx`** core (the core the whole
project builds on, fetched by `get_deps.sh` from `Alex-Electron/zx`, a fork of
[AtlasFPGA](https://github.com/AtlasFPGA)), carrying one local change.

## The patch: PS/2 watchdog resync

The stock receiver could lose bit alignment on a PS/2 glitch or a dropped clock
edge, which showed up as "fuzzy keys" — a keypress ignored, or a hotkey that took
two or three tries. This version adds a **watchdog that resyncs the bit counter on
a mid-byte timeout (> ~400 µs between edges)**, so a partial or corrupted frame is
discarded instead of shifting every following key. On hardware the fuzzy-key
behaviour is gone.

## Why it lives here

`get_deps.sh` fetches the Atlas core pinned to a commit that predates this fix, so
a clean clone would build without it. Rather than maintain a separate core fork
just for one file, the step's bitstream assembler
(`research/14-color-osd/sources/assemble.sh`) **overlays this file onto the fetched
core** (`cores/zx/src/ps2.v`) before synthesis. A clean clone therefore reproduces
the exact bitstream that runs on the board:

```
./get_deps.sh
cd research/14-color-osd/sources && ./assemble.sh   # overlays this ps2.v
cd build && vivado -mode batch -source build.tcl
```

The Atlas core ships without an explicit licence file; this single module is
redistributed here under the same terms as the upstream core, solely to keep the
research step self-contained and reproducible.
