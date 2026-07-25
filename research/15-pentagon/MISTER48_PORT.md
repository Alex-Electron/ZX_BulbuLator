# MiSTer native-48 backend experiment

Status: experimental, volatile PCAP only. It must not be placed in `BOOT.BIN`
until the Atlas/MiSTer comparison battery passes and the owner gives an
explicit persistent-flash GO.

## Purpose

This experiment answers a narrow question with hardware evidence: do the
MiSTer ULA raster, contention, interrupt and CPU-enable phases fix the native
48K timing/snow behavior that remains wrong in the modified Atlas backend?

It does not port the complete MiSTer `emu` top. BulbuLator keeps its existing:

- Zynq PS and AXI control plane;
- ARM Navigator, SD, tape parser and snapshot loader;
- `mem_zx` ROM/RAM/screen shadow;
- tape FIFO/player and EAR mux;
- PS/2 event merger and keyboard gate;
- framebuffer, HDMI, OSD, audio transport and JTAG screen mirror.

Only the machine backend is changed at synthesis time.

## Pinned upstream

Repository: `ZX-Spectrum_MISTer`

Commit: `9388aac649c881140c061fab85d5cf37336cf802`

Files used by the experiment:

- `rtl/ula.sv` — GPL-3.0-or-later, Sorgelig;
- `rtl/T80/T80pa.vhd`;
- `rtl/T80/T80.vhd`;
- `rtl/T80/T80_Pack.vhd`;
- `rtl/T80/T80_MCode.vhd`;
- `rtl/T80/T80_ALU.vhd`;
- `rtl/T80/T80_Reg.vhd`.

The T80 files retain their permissive upstream notice. The BulbuLator project
is already GPL-2.0-or-later and distributed bitstreams are already effectively
GPL-3.0-or-later through JT49, so the ULA licence is compatible. A production
merge must add this upstream and pin to `THIRD_PARTY.md`/dependency fetching.

The MiSTer framework is deliberately excluded: `emu`, `hps_io`, Altera PLL,
SDRAM/DDRAM, video mixer/HDMI, tape/TZX player, disks, DivMMC, GS, AY/SAA and
MiSTer's snapshot loader are not part of this port.

## Compile-time targets

`build.tcl -tclargs mistert80`

- version `B01B0054`;
- changes only Atlas T80pa v0247 to the MiSTer T80pa v0250 source set;
- leaves the Atlas ULA/memory and all board glue unchanged;
- output `bulbulator_zx_loader_mistert80.bit`.

Hardware result on 2026-07-24: boot and original
`0:/loadtest/sna48k-timing.sna` execute, but the screen is still the exact
Type-1 image SHA-256
`f5fe2b24d28f05ce3d62f8553e48ab85d0600643ce69c8527eadb0c9ca9be197`.
Therefore the T80 revision alone is not the cause.

`build.tcl -tclargs mister48`

- version `B01B0059` (B0055 was the first boot/timing smoke artifact; B0056
  proved the fetch-source mirror but also exposed why a snow renderer must
  store the fetched byte at its nominal raster destination; B0057 proved the
  raster observer and exposed a missing `vc[4:3]` term in the diagnostic
  attribute destination, corrected in B0058; B0059 adds a phase-safe
  CPU-only FAST8 handoff and drives tape duration from the exact CE presented
  to T80);
- uses `mister48_core.sv`, MiSTer ULA and MiSTer T80pa v0250;
- fixed native 48K map for the first smoke bit;
- output `bulbulator_zx_loader_mister48.bit`.

## Interface map

| MiSTer backend | BulbuLator |
|---|---|
| `clk_sys` | `spclk` (~56.667 MHz) |
| `ce_7mp`, `ce_7mn` | existing `pe7M0`, `ne7M0` |
| ULA `ce_cpu_sp/sn` | T80pa `CEN_p/n`, gated only by ARM CPU halt |
| reset | `~sp_reset_n` for ULA, `sp_reset_n` for T80pa |
| CPU ROM/RAM | existing `mem_zx` |
| `vram_addr/dout` | existing `mem_zx` screen-shadow read port |
| keyboard matrix | existing Step-15 PS/2/ARM event adapter |
| Kempston | existing `joy_sp`, read at port low six bits `0x1F` |
| tape input | existing `tape_earmux_sp ? tape_ear : sp_ear` |
| video RGBI/sync/blank | existing framebuffer/HDMI chain |
| register snapshot | compatible 212-bit T80 `REG/DIR/DIRSet` |

Physical native-48 memory mapping stays compatible with ARM injection:

```text
0000-3FFF -> 48 BASIC ROM (ROM pair page 1)
4000-7FFF -> RAM bank 5
8000-BFFF -> RAM bank 2
C000-FFFF -> RAM bank 0
```

## Acceptance sequence

1. Confirm `B01B0055`, native-48 BASIC cold boot and keyboard.
2. Load the original timing SNA and compare its screen/hash with Atlas. B0055
   boots and renders the exact Type-1 screen, demonstrating that MiSTer's fixed
   48K timing profile is itself detected as Type 1; “Early” is therefore not,
   by itself, evidence that the core is broken.
3. Load `sna48k-snow.sna`; require a stable image matching a reference
   emulator, not a merely non-crashing picture. B0058 passes: eight
   consecutive rendered frames exactly match the initial SNA screen SHA
   `3aae4c8c7c66f412537e1432de90d6519c3f23862cd24dfd6fd27043b9283bd5`,
   with a live guest CPU and `snow_diff.py` verdict `CLEAN`.
4. Verify Kempston `IN 31`, EAR and beeper.
5. Verify a normal 48K TAP at 1x before enabling any warp. B0058 passes
   `CAVE48K.TAP`: `638916/FF7A8101/gaps=1/resumes=0`, PC in game code and
   screen SHA `1d03cbb3...`. SAFE4 produces the exact same fingerprint and
   byte-for-byte same screen.
6. Rebuild exact ULA-fetch screen-mirror strobes and ROM-trap/tape diagnostics.
7. Add SAFE4 whole-core warp, then separately qualify FAST8. SAFE4 passed on
   B0058. B0059 implements the separate phase-safe CPU-only FAST8 adapter and
   is awaiting routed hardware qualification.
8. Keep Atlas 128K/Pentagon until the native-48 backend is proven.

Failure of the MiSTer experiment is safe: all board programming is volatile,
and a power cycle returns to the unchanged persistent production image.
