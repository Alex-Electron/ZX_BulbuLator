# BulbuLator tape-loading handover — v0.15.78 through v0.15.110

**Written:** 2026-07-15  
**Scope:** all tape-loader work introduced during the v0.15.78 → v0.15.110 sequence, including the 2026-07-14/15 Critical Mass investigation.  
**Audience:** an engineer starting from zero on this repository and on the EBAZ4205/ThinkPad JTAG setup.

> Important current status: the board is intentionally left in the original **ZX 128K** configuration with no tape running. v0.15.110 contains an experimental 48K model-selection path which is **not safe to use yet**. Do not select `ZX Spectrum 48K` in the UI and do not write `MACHINE_CFG=2` through JTAG on a running core.

---

## 1. What BulbuLator is and where this work lives

BulbuLator is a Zynq-7010 based Spectrum implementation:

- the **ARM Cortex-A9** runs the file browser, FatFs, TZX/TAP parser, audio/UI and pulse producer;
- the **FPGA** contains the Atlas Spectrum core, an ARM-to-FPGA asynchronous tape FIFO, the precise tape replay engine and HDMI/display logic;
- the custom tape implementation is a *real pulse path*: ARM parses a tape image into `{EAR level, duration in Z80 T-states}` records; FPGA replays them in the Spectrum clock domain; the Spectrum core reads EAR through its normal `IN A,(0xFE)` path.

The active source tree is:

```text
/Users/alex/Yandex.Disk.localized/DIY/EBAZ4205/
  BulbuLator/research/15-pentagon/
```

The actual hardware build/JTAG host is the ThinkPad:

```text
ssh thinkpad
~/bulb-v13/research/15-pentagon
```

The tree is not a normal clean Git worktree. Do not use `git reset`, `git checkout`, or assume `git diff` describes all local work.

### Main files

| File | Responsibility |
|---|---|
| `arm/loader_main.c` | ARM app, tape parser/generator, UI, mailbox, JTAG diagnostics |
| `sources/tape_player.v` | FPGA pulse FIFO consumer; holds/replays `{level,duration}` at CPU T-state rate |
| `sources/bulbulator_zx_ddr_top.v` | Atlas-core integration, EAR mux, tape timing, warp/sync/starvation logic |
| `sources/axi_ctl.v` | ARM GP0 register map/control plane |
| `sources/assemble.sh` / `sources/build.tcl` | FPGA source assembly and Vivado build |
| `flash/pcap_load.tcl` | reliable PCAP programming procedure |
| `arm/build_loader.sh` | ARM compile wrapper; assumes ThinkPad BSP paths |
| `tools/jtag_critical_mass_status.tcl` | new read-only post-run status probe |

The Atlas core itself is outside this sub-tree:

```text
BulbuLator/cores/zx/src/main.v
BulbuLator/cores/zx/src/memory.v
BulbuLator/cores/zx/src/keyboard.v
```

Atlas `main` already has a native `model` input: `0 = 48K`, `1 = 128K`.

---

## 2. Baseline at v0.15.78

v0.15.78 is the practical baseline for this handover. The tape design already existed and had these invariants:

1. ARM produces pulse records into a software SPSC ring.
2. ARM ISR transfers ring records to the FPGA FIFO (`TAPE_FIFO`, GP0 `0xA0`).
3. `tape_player.v` consumes the FIFO only on the core’s T-state enable.
4. The core EAR mux selects `tape_ear` while tape run/mux are enabled.
5. Warp and Sync Loader are optional controls; the unaccelerated pulse stream must be valid without either.

The principal problem through the later revisions was not merely “does a file parse?” but preserving exact loader-visible timing across:

- pauses between blocks;
- custom/turbo loaders which poll `0xFE` directly;
- ARM/FPGA FIFO gaps;
- fast mode and end-of-tape release;
- ZX 128K versus 48K ROM/model assumptions.

---

## 3. Tape control plane and diagnostics

### ARM GP0 registers

Base: `0x40000000`.

| Address | Name | Meaning |
|---:|---|---|
| `+0x00` | VERSION | FPGA version, read-only |
| `+0x04` | CONTROL | bit 0 HALT; bit 2 reset+wipe request |
| `+0x08` | STATUS | bit 0 HALT_ACK; bit 1 RAM_BUSY; bit 2 reset busy |
| `+0x9C` | TAPE_CTRL | run, EAR mux, mute, fast mode, sync, more-data |
| `+0xA0` | TAPE_FIFO | write `{level[31], duration[23:0]}` |
| `+0xA4` | TAPE_STATUS | full/playing/byte-wait/sampling status |
| `+0xB0` | SMP_CNT | core `0xFE` sample counter |
| `+0xBC` | MACHINE_CFG | bit 0 Pentagon; v0.15.110 added bit 1 48K (unsafe switch path, see section 10) |
| `+0xEC` | ROMTRAP register bank | low 16 bits of register 2 are useful as live PC observation |

### JTAG-coherent mailbox in non-cacheable DDR

Base: `KMB = 0x0F700000`.

| Offset | Symbol | Meaning |
|---:|---|---|
| `+0x00` | `g_autotrig` | start selected path from JTAG |
| `+0x04/+0x08/+0x0C` | `g_fs_cmd/done/err` | file-system command state |
| `+0x10/+0x14` | `g_fs_len/g_fs_n` | FS transfer/listing counters |
| `+0x18` | `g_tape_on` | ARM considers tape playback active |
| `+0x1C` | `opt_fastload` | TZX/TAP speed: 0 off, 1 fast 8x, 2 safe 4x |
| `+0x24` | `opt_tapesync` | Sync Loader flag |
| `+0x28` | `opt_autostart` | auto-start flag |
| `+0x2C` | `opt_defmachine` | 0 128K, 1 Pentagon, 2 experimental 48K |
| `+0x30` | `opt_romtrap` | retired; must remain off |
| `+0x34` | `opt_smartload` | Smart Load control |
| `+0x100` | `g_autodir` | JTAG directory text |
| `+0x180` | `g_autoname` | JTAG filename text |
| `+0x200` | `g_fs_path` | path buffer |

The mailbox is non-cacheable. Prefer it to stale normal ARM globals when driving the board through JTAG.

### v0.15.108+ debug symbols

For the v0.15.110 ELF:

```text
g_dbg      = 0x0015879C
g_fe_trace = 0x001E0480
```

`g_dbg` fields relevant to a run:

| Index | Meaning |
|---:|---|
| 0 | ISR/progress tick diagnostic |
| 1..4 | producer/ring/delivered-pulse diagnostics; `d03` produced and `d04` delivered must agree at EOT |
| 10 | number of segments dispatched |
| 11 | source offset at last segment entry |
| 12 | last standard data length where applicable |
| 15 | end-of-run tick snapshot |

`g_fe_trace[n]` captures `SMP_CNT` immediately when segment `n` is dispatched. It proves that the Spectrum kept reading EAR through specific transitions; it is not a general success oracle.

---

## 4. Work introduced after v0.15.78

### 4.1 Pulse-pause and end-of-tape work

The tape path previously treated inter-block timing too much like UI timing. The work after v0.15.78 changed this direction:

- TZX block pauses are emitted into the actual EAR waveform rather than only delaying the ARM/UI.
- The old forced 500 ms minimum around a short TZX pause was removed.
- Tail handling keeps the EAR mux active until queued/FIFO pulses drain, rather than stopping when ARM finishes producing.
- The code keeps explicit fast-tail handling and starvation protection; these are separate from format parsing.

The relevant parser/generator is in `tape_load_seg()` and `tape_pump()` in `arm/loader_main.c`.

### 4.2 Smart Load safety change

Smart Load is not a universal TZX decoder. It is intended only for standard ROM loader behaviour. The work retained/clarified this rule:

- Smart must not silently become the path for turbo/custom EAR loaders.
- A custom loader must receive real pulse playback.
- ROM-trap is retired/disabled: do not attempt to revive it as a shortcut. Its register injection model cannot faithfully reconstruct the live CPU carry/ALU state needed by the ROM return path.

### 4.3 Exact TZX pause implementation (v0.15.106–v0.15.107 sequence)

An early hypothesis about holding LOW was wrong/incomplete. It was superseded by `tape_push_pause()`:

```text
for non-zero pause:
  retain the level following the final data pulse for 1 ms (3500 T-states)
  force/hold EAR LOW for the remaining duration
for zero pause:
  emit nothing
```

This matches the playback shape used by ZEsarUX `playtzx.c`: one millisecond at the current/opposite-to-final-pulse amplitude, then LOW for the remainder. The current code ends a pause with `g_ear_lvl = 0`.

This matters because Critical Mass contains a deliberate 1 ms header-to-data gap. Stretching it to 500 ms changes the recording and may make its loader time out.

### 4.4 Segment/FE tracing (v0.15.108)

Added `g_fe_trace[]` and extra `g_dbg[]` values described above. This instrumentation is intentionally passive: it does not change the waveform. It was needed because “the image reached the FPGA” and “the custom loader is still sampling it” are different questions.

### 4.5 ZEsarUX standard-timing A/B test (v0.15.109) — reverted

v0.15.109 temporarily changed standard block constants to values observed in ZEsarUX source:

```text
pilot count: 8064 / 3220
zero half-wave: 885 T-states
```

Hardware result: Critical Mass still terminated at the same error-area PC (`0x25E5`) in the 128K setup. This experiment did **not** solve the problem.

The current v0.15.110 source reverted both the generator and duration accounting to the project’s canonical values:

```text
standard header pilot count: 8063
standard data pilot count:   3223
pilot duration:              2168
sync:                         667 / 735
zero:                         855
one:                         1710
```

Do not reintroduce a timing constant in only one location: `tape_load_seg()` and `tape_total_T()` must agree.

---

## 5. Critical Mass case study

### File and integrity

Correct SD path:

```text
0:/loadtest/CUSTOM LOADER/Critical Mass (1985)(Durell)[a2].tzx
```

Source file on the Mac:

```text
/Users/alex/Yandex.Disk.localized/DIY/ZX/ZX-Soft/CUSTOM LOADER/
Critical Mass (1985)(Durell)[a2].tzx
```

Size: 47431 bytes.

The source image and a readback from the board SD card have the identical SHA-256:

```text
04cd6519530f53d5eaaa3127cdd063498a9fdd85b22d789a02fe73273a0765c9
```

Therefore re-uploading that file is not a valid repair action.

### TZX structure

| Segment | Offset | ID | Description |
|---:|---:|---|---|
| 0 | `0x000A` | `0x10` | standard header, BASIC `LOGO ERBE` |
| 1 | `0x0022` | `0x10` | standard data, 1146 bytes |
| 2 | `0x04A1` | `0x10` | standard header, BASIC `CRITICAL` |
| 3 | `0x04B9` | `0x10` | standard data, 1010 bytes |
| 4 | `0x08B0` | `0x10` | standard CODE header, start `0xFA24` |
| 5 | `0x08C8` | `0x10` | standard CODE data, 1332 bytes |
| 6 | `0x0E01` | `0x11` | turbo header, pause 484 ms |
| 7 | `0x0E27` | `0x11` | turbo data, 6914 bytes, pause 3200 ms |
| 8 | `0x293C` | `0x11` | turbo header, pause 13 ms |
| 9 | `0x2962` | `0x11` | turbo data, 36818 bytes, no pause |

The custom code loaded at `0xFA24` was extracted and disassembled. It directly polls port `0xFE` and invokes ROM routines; this is not a case for Smart Load or ROM trap.

### 128K results

With normal pulse mode (`FAST=OFF`, `SYNC=OFF`, `SMART=OFF`) the 128K test reached end of waveform delivery, but the observed failure PC was:

```text
PC = 0x25E5
```

That was repeatable before and after the v0.15.109 timing experiment. The user observed `Tape loading error`.

### Experimental 48K result

Using the v0.15.110 experimental 48K selector, Critical Mass progressed differently:

- after 6.5 s it was already at segment 8, PC `0x2011` instead of `0x25E5`;
- it reached segment 10, the final 36818-byte turbo data block;
- at end of tape `g_tape_on=0`, `g_dbg[10]=11`;
- produced and delivered entries agreed: `g_dbg[3]=g_dbg[4]=0x000C4A5C` (805468);
- subsequent observed PCs were around `0x1FF2` and `0x2024`, not the original error path.

This is useful evidence that the loader/model hypothesis deserves a future controlled test. It is **not** a license to use the present 48K implementation, because the mode-switch procedure itself is unsafe.

---

## 6. Corpus audit: `CUSTOM LOADER`

Three parallel static audits examined the supplied corpus.

### Counts

| Item | Count |
|---|---:|
| TZX files | 38 |
| Total size | about 2.23 MB |
| standard data blocks `0x10` | 181 |
| turbo data blocks `0x11` | 248 |
| pure tone `0x12` | 9 |
| pulse sequence `0x13` | 38 |
| pure data `0x14` | 38 |
| pause/stop blocks `0x20` | 22 |

The corpus contains no direct recording, CSW, generalized data, jump/call/select control flow blocks. Structurally, the existing normal pulse parser covers all used waveform block types.

### Compatibility conclusions

- 17 images use only standard blocks and are candidates for Smart Load, but at least five still advertise/use custom loading behaviour (`A Stroll`, `Ball Breaker 2`, `Deviants`, `Letris`, `Locomotion`); Smart must fall back to pulse playback when direct EAR access occurs.
- 21 images contain obvious turbo/custom timing and require pulse playback.
- The high-risk group includes Critical Mass, Black Lamp/Bleepload, Freddy Hardest 1/2, Lode Runner and Star Wars `[a]`.
- `FAST 8x` is **not certified** for custom/turbo tapes. Until an actual per-title hardware matrix exists, the only defensible compatibility setting is `FAST=OFF`.
- `SAFE 4x` may be tested later; it is not a substitute for a pass matrix.

### Unresolved parser semantic issue

20 out of 22 `0x20` blocks have pause value zero. In TZX this means **STOP TAPE**, not “insert a 500 ms silence and continue”. Current code does:

```c
g_seg_pause_T = pause ? pause*3500u : 1750000u;
```

This is semantically wrong for STOP TAPE. A future implementation must stop transport and provide an explicit user/host resume action, preserving the next block pointer. Do not silently claim complete TZX compliance before fixing this.

---

## 7. FPGA timing architecture relevant to future fixes

`sources/tape_player.v` receives a record whose top bit is the absolute EAR level and whose low 24 bits are duration. On `t_en`:

1. while `cnt > 1`, it decrements and holds current EAR;
2. when a record ends, it loads the next record and sets `tape_ear` to that record’s level;
3. if no data exists, it marks not busy and holds last level until run is removed.

In `bulbulator_zx_ddr_top.v`:

```verilog
wire tape_advance = pe3M5_core & (~tsync_s[1] | sync_hold);
```

The EAR input to Atlas is:

```verilog
.ear(tape_earmux_sp ? tape_ear : sp_ear)
```

This means pulse time is tied to Spectrum T-states, not ARM wall time. Do not “fix” a loader by adding random ARM delays or by changing the FPGA replay clock to wall-clock time.

The FIFO/producer diagnostics have already demonstrated that Critical Mass’s raw delivery was starvation-free. Further work should focus on machine/ROM compatibility, TZX semantics, and controlled wave/CPU timing probes—not SD throughput guesses.

---

## 8. Build and program procedure

### ARM build (ThinkPad only)

```sh
ssh thinkpad
cd ~/bulb-v13/research/15-pentagon
bash arm/build_loader.sh
cp -f /home/lavrinovich/sdboot/ws/loader/Debug/loader.elf arm/loader.elf
```

The Mac-side script cannot be used as a standalone build because it expects `/home/lavrinovich/sdboot/...` BSP paths.

### FPGA build

```sh
cd ~/bulb-v13/research/15-pentagon
source /tools/Xilinx/Vivado/2023.1/settings64.sh
bash build.sh
cp -f sources/build/bulbulator_zx_loader.bit bulbulator_zx_loader.bit
cd flash
/tools/Xilinx/Vivado/2023.1/bin/bootgen -arch zynq \
  -image bulb_loader_pcap.bif -w -process_bitstream bin
```

`build.sh` invokes `sources/assemble.sh`. It recreates `sources/build`, links the external Atlas/HDMI cores, and copies the local `sources/*.v` files into the Vivado staging directory.

### Reliable PCAP programming

The plain JTAG configuration route is not the trusted path. Use PCAP:

```sh
pkill -9 -x vivado_lab || true
source /tools/Xilinx/Vivado_Lab/2023.1/settings64.sh
setsid vivado_lab -mode batch -source /tmp/hold.tcl -nojournal -nolog \
  >/tmp/hold.log 2>&1 </dev/null &

cd ~/bulb-v13/research/15-pentagon
PCAP_BIN=$PWD/bulbulator_zx_loader.bit.bin \
  /tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb flash/pcap_load.tcl
```

Do not proceed until the log contains all of:

```text
ВЕРИФИКАЦИЯ DDR OK
PCFG_DONE=1
POST_CONFIG DONE
```

The recurring `bind 127.0.0.1:9119: Address already in use` message is normally harmless in this setup.

### ARM launch

Existing `/tmp/run108.tcl` remains a convenient loader launch script. Its old name does not mean it loads an old ELF; it downloads the current file at:

```text
/home/lavrinovich/bulb-v13/research/15-pentagon/arm/loader.elf
```

Before trusting diagnostic addresses after a new ARM build, run:

```sh
nm -n arm/loader.elf | rg 'g_dbg$|g_fe_trace$'
```

---

## 9. Artifacts actually built during this session

The v0.15.110 ELF was copied back into the local workspace:

```text
arm/loader.elf
SHA-256 0cd55503428fa9f353fbc686fc51c9f0fb39a7d21f757625196c9060e43a3dd2
```

The FPGA source instance reported:

```text
ARM firmware string: v0.15.110
FPGA VERSION:        0xB01B0038
PCAP bit.bin SHA-256:
6e16cdc1c86729a6020e038dd009f1b69894ae63769710161bbb96e607e9ab43
```

Vivado v0.15.110 build completed with zero errors and zero critical warnings; its DRC produced pre-existing non-fatal warnings, principally DSP pipelining suggestions and Atlas RAM asynchronous-control warnings.

---

## 10. The v0.15.110 48K regression: exact failure and required repair

### What was added

The following uncommitted source changes added a third model option:

| File | Change |
|---|---|
| `arm/loader_main.c` | `CH_MACHINE` expanded to 128K / Pentagon / 48K; `N_MACHINES=3`; UI/profile/defaults; 48K auto-start keystrokes; `MACHINE_CFG=2` for 48K |
| `sources/axi_ctl.v` | `ctl_model48` output from `MACHINE_CFG bit1` |
| `sources/bulbulator_zx_ddr_top.v` | 2-FF CDC `model48_s`; Atlas `.model(core_model_sp)` rather than constant 128K |

The 48K BASIC auto-start sequence is valid in principle:

```text
J                    => LOAD keyword
Symbol Shift + P     => quote
Symbol Shift + P     => quote
Enter
```

The Atlas keyboard map has a convenient injected scan code `0x54` for quote (`Symbol Shift + P`).

### Why the implementation is unsafe

The existing `apply_machine()` sequence writes `MACHINE_CFG` before calling `machine_reset()` on a changed profile. While the core is executing, changing `model` changes ROM and RAM paging behavior immediately. Manual JTAG testing also wrote:

```text
mwr 0x0F70002C 2
mwr 0x400000BC 2
```

against a running CPU. That can produce corrupted execution/screen output, which the user observed as garbage/memory corruption.

### Correct repair choices

**Preferred short-term recovery:** remove all 48K additions and restore the constant core connection:

```verilog
.model(1'b1)
```

Then rebuild/reflash a conservative 128K bitstream and resume tape work without model switching.

**If retaining 48K:** implement an atomic machine transition. The minimum safe state machine is:

```text
1. request HALT through CONTROL bit0
2. wait for STATUS.HALT_ACK
3. update MACHINE_CFG (Pentagon/model bits) while CPU is stopped
4. pulse reset+wipe through CONTROL bit2
5. wait for STATUS.reset_busy asserted then deasserted
6. apply machine profile/paging settings
7. release HALT
```

It must also be used at boot when persisted config requests 48K. Add a readable `MACHINE_CFG` case to `axi_ctl.v`; current readback returns `DEADBEEF` because `IDX_MACHCFG` has no read case.

Do not test the retained 48K implementation through raw JTAG writes again. Drive the actual guarded ARM transition or build a dedicated test bitstream.

---

## 11. What not to claim or do

1. Do not claim all 38 images load perfectly. Their static block types are covered, but there is no hardware pass matrix.
2. Do not claim FAST 8x compatibility for custom/turbo loaders.
3. Do not use Smart Load or ROM trap for a turbo/custom loader.
4. Do not treat a successful FIFO count as a game-load success.
5. Do not re-upload Critical Mass as a fix; its SD copy was already exact.
6. Do not change Atlas `model` while the CPU executes.
7. Do not use a single `fb_capture` frame immediately after reset as proof of physical HDMI corruption; in this session it could retain an old visual image while the user’s physical display was normal.

---

## 12. Recommended continuation order

1. **Stabilize first.** Revert or correctly guard the v0.15.110 48K branch; build and boot a clean 128K baseline. Verify normal UI/video on the physical monitor.
2. **Add testable TZX semantics.** Implement proper `0x20 pause=0` stop/resume rather than 500 ms continuation. Add host-level parser/waveform regression tests for all 38 files.
3. **Define success probes.** For each hardware test record file hash, model, fmode, sync/smart settings, final PC, `g_tape_on`, `g_dbg[3/4/10]`, FE trace and a human screen result.
4. **Build hardware matrix at normal speed.** Test the 38 corpus images one-by-one in pulse mode, beginning with Critical Mass and the high-risk custom titles.
5. **Only then test acceleration.** SAFE 4x first, FAST 8x second; record per-title allow/deny outcomes rather than applying a global promise.
6. **Revisit 48K only as an isolated feature.** First implement the guarded transition and readback, then repeat Critical Mass from a clean state.

The practical safe handoff point is: **ZX 128K, normal pulse path, no Smart/ROM trap, no experimental model switch.**
