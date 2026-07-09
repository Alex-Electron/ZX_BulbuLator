# Third-party components & licences

BulbuLator itself is licensed **GPL-2.0-or-later** (see [LICENSE](LICENSE)). It builds on
several third-party components. Cores marked *fetched* are **not** stored in this repo — they
are pulled, pinned by exact commit, by [`get_deps.sh`](get_deps.sh); those pinned sources are
the *corresponding source* for any prebuilt binaries shipped here. Components marked *vendored*
live under [`third_party/`](third_party/).

## Effective licence of a distributed bitstream
A built `.bit` / `BOOT.BIN` links the GPL cores below. Because **JT49 is GPL-3.0-or-later**, any
distributed bitstream is effectively **GPL-3.0-or-later**. Our own sources are GPL-2.0-or-later,
which permits this combination.

## Components

| Component | Role | Licence | Copyright | How |
|---|---|---|---|---|
| **This project** (ARM firmware, our RTL, scripts, docs, board-top) | the platform | GPL-2.0-or-later | © 2026 Alexander Lavrinovich | in repo |
| **Atlas `zx`** — ZX Spectrum / Pentagon core (`Alex-Electron/zx` @ `407b653`, downstream of `sorgelig/ZX_Spectrum-128K_MIST`) | the machine core | GPL-2.0-or-later | © 2016-2019 Sorgelig & contributors | fetched |
| ├ **JT49** — AY-3-8910 / YM2149 sound | in the core | **GPL-3.0-or-later** | © Jose Tejada (jotego) | fetched (via zx) |
| ├ **SAA1099** — SAA sound | in the core | GPL-2.0-or-later | © 2016 Sorgelig | fetched (via zx) |
| └ **T80** — Z80 CPU | in the core | permissive (Wallner-style) | © Daniel Wallner / Sorgelig | fetched (via zx) |
| **hdl-util/hdmi** (`Alex-Electron/hdmi` @ `fbade3d`) | HDMI TMDS + audio | Apache-2.0 OR MIT | © hdl-util contributors | fetched |
| **Digilent vivado-library / rgb2dvi** (@ `f4613ff`) | rgb2dvi IP (Steps 3-4 only) | Digilent licence (permissive) | © Digilent Inc. | fetched (sparse) |
| **AYUMI** — software AY emulation | music player (PSG) | MIT | © Peter Sovietov | vendored |
| **minimp3** — MP3 decoder | music / tape MP3 | CC0 (public domain) | © lieff | vendored |
| **speexdsp** — resampler | audio resample | BSD-3-Clause | © Xiph.Org Foundation | vendored |
| **`atlas-zx-ps2-watchdog/ps2.v`** — patched PS/2 decoder | keyboard fix | GPL-2.0-or-later | © Sorgelig; mods © 2026 A. Lavrinovich | vendored (modified GPL) |

## External hardware (referenced, not redistributed)
- **Murmulator — *Tape Load Reader*** front-end circuit (tape input): GPL-3.0, © AlexEkb4ever
  ([schematics](https://github.com/AlexEkb4ever/MURMULATOR_classical_scheme)). An external add-on
  wired to the board; credited and linked, not shipped here.

## Notes
- `assemble.sh` overlays `third_party/atlas-zx-ps2-watchdog/ps2.v` onto the fetched core so a clean
  clone reproduces the on-hardware keyboard fix; the file stays GPL-2.0-or-later.
- To reproduce a shipped binary: `./get_deps.sh` (pins every core by commit) then build — see the
  per-step build scripts.
