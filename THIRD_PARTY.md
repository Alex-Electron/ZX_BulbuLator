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
| **`zx`** — multi-board ZX Spectrum **48K/128K** core, **no Pentagon** (theexperimentgroup / Atlas / UnAmigaReloaded; `Alex-Electron/zx` @ `407b653` ← `AtlasFPGA/zx` ← `UnAmigaReloaded-fpga/zx`) | the machine core | GPL (v3+ via JT49) | © theexperimentgroup / UnAmigaReloaded | fetched |
| ├ **JT49** — AY-3-8910 / YM2149 sound | in the core | **GPL-3.0-or-later** | © Jose Tejada (jotego) | fetched (via zx) |
| ├ **SAA1099** — SAA sound | in the core | GPL-2.0-or-later | © 2016 Sorgelig | fetched (via zx) |
| └ **T80** — Z80 CPU | in the core | permissive (Wallner) | © Daniel Wallner | fetched (via zx) |
| **ZX-Spectrum_MISTer** (`MiSTer-devel/ZX-Spectrum_MISTer` @ `9388aac`) — Step-15 optional native-48 backend uses `rtl/ula.sv` and `rtl/T80` only | alternative ULA + CPU backend | ULA: GPL-3.0-or-later; T80: permissive (Wallner) | © 2016 Sorgelig; © Daniel Wallner | fetched |
| **hdl-util/hdmi** (`Alex-Electron/hdmi` @ `fbade3d`) | HDMI TMDS + audio | Apache-2.0 OR MIT | © hdl-util contributors | fetched |
| **Digilent vivado-library / rgb2dvi** (@ `f4613ff`) | rgb2dvi IP (Steps 3-4 only) | Digilent licence (permissive) | © Digilent Inc. | fetched (sparse) |
| **AYUMI** — software AY emulation | music player (PSG) | MIT | © Peter Sovietov | vendored |
| **minimp3** — MP3 decoder | music / tape MP3 | CC0 (public domain) | © lieff | vendored |
| **speexdsp** — resampler | audio resample | BSD-3-Clause | © Xiph.Org Foundation | vendored |
| **`atlas-zx-ps2-watchdog/ps2.v`** — patched PS/2 decoder | keyboard fix | GPL-2.0-or-later | © Sorgelig; mods © 2026 A. Lavrinovich | vendored (modified GPL) |

| **NES core** — 6502 + PPU + APU + mappers | NES / Dendy machine | GPL | © 2012-2013 Ludvig Strigeus; NES_MiSTer contributors (GreyRogue et al.); NESTang adaptation © nand2mario | fetched + our wrapper (`nes_wrap.v`, `nes_video.v`, `nes_mem_bram.v` © 2026 A. Lavrinovich) |
| ├ **T65** — 6502 CPU | in the NES core | permissive (Wallner-style) | © Daniel Wallner and contributors | fetched (via NES core) |
| **z80emu** ([anotherlin/z80emu](https://github.com/anotherlin/z80emu) v1.1.3) — Z80 interpreter on the ARM, used for the General Sound card | GS card CPU | "This code is free, do whatever you want with it" (upstream header) | © 2012-2017 Lin Ke-Fong | vendored; `z80user.h` replaced by our binding — see `research/15-pentagon/arm/z80emu/ВЕНДОРЕНО.md` |
| **Terminus** (`CyrKoi-TerminusBoldVGA16`) — the 8×16 CP866 OSD font | shell text | **SIL OFL 1.1** | © Dimitar Zhekov and contributors | vendored as `arm/vga866.h` (bitmap extracted) |
| **zxtests** by Jan Bobrowski — `DELAY`, `ALIGNINT`, `FRAME_TIME`, `INT_TIME`, `EI_PREFIX` and the stime/btime frame bodies | Pentagon timing test tapes (`research/15-pentagon/tools/penttest/`) | GPL / LGPL (per the file headers) | © Jan Bobrowski | vendored (IM2 table address changed in `instint.asm`) |
| **FatFs** (via the Xilinx `xilffs` BSP library) — FAT16/FAT32 on the SD card | file service | BSD-style 1-clause (ChaN) | © ChaN | build dependency, not vendored here |

### ROM sets and device firmware — see [`research/15-pentagon/roms/PROVENANCE.md`](research/15-pentagon/roms/PROVENANCE.md)

`research/15-pentagon/roms/` ships the ROM sets the machine was actually tested against. **None of
them is our work**, the project licence does not cover them, and we are not the rights holders. The
manifest names, per file, what is inside (identified from the files themselves, not from their
names), who the author is, and the single modification we made — one corrupted TR-DOS page restored
from a clean 5.03. Where we could not establish authorship with confidence, the manifest says so
instead of guessing.

Summary of the rights holders: Sinclair 48K/128K ROMs © **Amstrad plc** (redistribution with
emulators permitted with acknowledgement); **TR-DOS** © Technology Research Ltd; **Gluk Reset
Service** by *Mr Gluk*; **Proteus** / **FATALL** / the PentoGraf sets by PentoGraf and the respective
authors; **esxDOS** by the esxDOS team; **General Sound** card firmware by the General Sound
developers. If you hold rights to any of these and want a file removed, open an issue.

## Chiptune playback engines (selected 2026-08-09, see [`research/15-pentagon/CHIPTUNE_ENGINE.md`](research/15-pentagon/CHIPTUNE_ENGINE.md))

Every entry below was built for the real target — `arm-none-eabi-gcc 14.2.1`, bare-metal newlib,
`-mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard` — before being selected. All licences are
GPL-2.0-or-later compatible; none of them raises the firmware above GPL-2.0-or-later.

| Component | Role | Licence | Copyright | Version / pin | How |
|---|---|---|---|---|---|
| **libxmp** ([libxmp/libxmp](https://github.com/libxmp/libxmp)) — 61 loaders, 90+ tracker formats (MOD/XM/S3M/IT/MED/MTM/669/FAR/OKT/PSM/ULT/DBM/AMF…) | module player | **MIT** | © 1996-2026 Claudio Matsuoka, Hipolito Carraro Jr | 4.7.2 @ `a13276d` | to vendor |
| **cRSID**, Rockbox edition ([Rockbox](https://github.com/Rockbox/rockbox) `lib/rbcodec/codecs/cRSID/`) — full C64 (6510 + CIA + VIC + IRQ/NMI), integer-only, 1/2/3 SID, no C64 ROMs needed | SID player | **GPL-2.0-or-later** (Rockbox tree; upstream grant is Hermit's "do what you want, but credit me") | © Mihaly Horvath (Hermit); Rockbox packaging © Wolfram Sang et al. | rockbox master @ `49600dd` | to vendor |
| **game-music-emu (libgme)** ([libgme/game-music-emu](https://github.com/libgme/game-music-emu)) — NSF/NSFe, GBS, HES, KSS, SPC, SAP, GYM, VGM, `.ay`. Built **without** the MAME YM2612 core (Nuked OPN2 instead) | console chiptune | **LGPL-2.1-or-later** | © Shay Green (blargg) and contributors | @ `fe8da4b` | to vendor |
| ├ **emu2413** (bundled in libgme `gme/ext/`) — YM2413 / VRC7 | in libgme | MIT | © 2001-2019 Mitsutaka Okazaki | with libgme | to vendor (via libgme) |
| └ **Nuked OPN2** (bundled in libgme `Ym2612_Nuked.cpp`) — YM2612 | in libgme | LGPL-2.1-or-later | © 2017 Alexey Khokholov (Nuke.YKT) | with libgme | to vendor (via libgme) |
| **ayfly** ([l29ah/ayfly](https://github.com/l29ah/ayfly)) — ZX AY replays PT1/PT2/PT3/STC/STP/ASC/PSC/SQT/PSG/VTX/YM/AY + `lha.cpp` (VTX/YM depacker). Forked: host glue, `ay.cpp`/`Filter3.cpp` and the bundled `z80ex` dropped in favour of our AYUMI + z80emu | ZX tracker music | **GPL-2.0-or-later** | © 2008 Deryabin Andrew | @ `c1ff6d5` | to vendor (modified GPL) |
| **StSound** ([arnaud-carre/StSound](https://github.com/arnaud-carre/StSound)) — Atari ST `.ym` (YM2..YM6, digidrums, sync-buzzer) + own LZH depacker | YM player | **MIT** | © 1995-2021 Arnaud Carré | @ `d1876bc` | to vendor |
| **ahx2play** ([8bitbubsy/ahx2play](https://github.com/8bitbubsy/ahx2play)) — Amiga AHX/THX | Amiga chiptune | **BSD-3-Clause** | © 2021-2024 Olav Sørensen | @ `6861c29` | to vendor |
| **fc14play** ([8bitbubsy/fc14play](https://github.com/8bitbubsy/fc14play)) — Future Composer 1.4 | Amiga chiptune | **BSD-3-Clause** | © 2026 Olav Sørensen | @ `48900bd` | to vendor |
| **pocketmod** ([rombankzero/pocketmod](https://github.com/rombankzero/pocketmod)) — 7 KB MOD replay, no libc beyond `memset`, zero allocation (pre-heap boot jingle / fallback) | fallback MOD | **MIT** | © 2018 rombankzero | @ `33ac2ba` | to vendor |
| **sndh-player / AtariAudio** ([arnaud-carre/sndh-player](https://github.com/arnaud-carre/sndh-player)) — Atari ST `.sndh` (YM2149 + MK68901 + STE DAC), carries Musashi 68000 | SNDH player (planned, last in order) | **MIT** (Musashi: MIT, © Karl Stenerud) | © 2025 Arnaud Carré | @ `19c814b` | planned |
| **pt3_lib** ([deater/vmw-meter](https://github.com/deater/vmw-meter) `ay-3-8910/pt3/`) — 6 KB PT3-only replay, fallback for the ayfly fork | fallback PT3 | GPL-2.0 / BSD (dual) | © Vince Weaver | @ `886a6ca` | fallback, not yet vendored |

Deliberately **rejected** (details and measurements in `CHIPTUNE_ENGINE.md`): TinySID (redistribution
forbidden), WebSid / Tiny'R'Sid (CC BY-NC-SA, NonCommercial — GPL-incompatible), DUMB (extra
"clause 4"), hxcmod (no SPDX), libvgm (no repo-level licence file), `kss-drivers` (third-party
binaries), ZXTune (LGPL-3.0 would force GPL-3 distribution), libresidfp / reSIDfp (768 KB of tables
vs 512 KB L2, >100 % of one core per chip), libsidplayfp as a whole (exceptions + iostream, needs
real C64 ROMs), libopenmpt (C++17 + STL, 1.5-2.5 MB), libmodplug, libmikmod.

## External hardware (referenced, not redistributed)
- **Murmulator — *Tape Load Reader*** front-end circuit (tape input): GPL-3.0, © AlexEkb4ever
  ([schematics](https://github.com/AlexEkb4ever/MURMULATOR_classical_scheme)). An external add-on
  wired to the board; credited and linked, not shipped here.

## Notes
- The Atlas `zx` core remains the Step-15 128K/Pentagon backend. Step 15 also has a compile-time
  native-48 experiment around the pinned official MiSTer ULA/T80; it preserves BulbuLator's own
  ARM/AXI, memory, tape, input and HDMI platform instead of importing the MiSTer framework.
- `assemble.sh` overlays `third_party/atlas-zx-ps2-watchdog/ps2.v` onto the fetched core so a clean
  clone reproduces the on-hardware keyboard fix; the file stays GPL-2.0-or-later.
- To reproduce a shipped binary: `./get_deps.sh` (pins every core by commit) then build — see the
  per-step build scripts.
