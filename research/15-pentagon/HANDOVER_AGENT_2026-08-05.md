# AGENT HANDOVER — ZX BulbuLator (full project + live BDI/Elysium arc)

> **Written:** 2026-08-05 ~10:00 (ThinkPad, after daily session reset).  
> **Audience:** any next AI agent.  
> **Language of this file:** Russian (owner language) + English technical identifiers.  
> **Rule:** every claim about board state must be re-verified with a real tool (`mrd`, screenshot, `xsdb`) before acting. This document is a map, not a live instrument.

---

## 0. Read order (mandatory)

1. **This file** — executive map + where to continue.
2. `research/15-pentagon/HANDOVER_CURRENT.md` — detailed live ops (esp. §11 disk, §12 Elysium B0082–B0086).
3. `research/15-pentagon/BUILD_HISTORY.md` — one row per bitstream/FW.
4. Vault: `~/notes/Projects/Lichnoe/BulbuLator/STATUS.md` (truth center; may lag B0085/B0086 — see §4).
5. Vault: `state/current.md` (long journal).
6. Vault night plan: `2026-08-04-2300-night-roms-sound-plan.md`.
7. Code truth: **ThinkPad** `~/bulb-v13` branch `master` (Mac repo lags — do **not** push to Mac as source of truth).
8. Permanent gotchas: project `PROJECT_RULES.md` if present; also §9 of this file.

Obsidian copy of this handover:  
`~/notes/Projects/Lichnoe/BulbuLator/2026-08-05-0958-HANDOVER-agent.md`

---

## 1. What BulbuLator is

**Ultimate ZX Spectrum hardware emulator on EBAZ4205 (Zynq-7010),** porting MiST/MiSTer-class cores onto Xilinx with ARM (Cortex-A9) as control plane.

| Item | Value |
|---|---|
| Board | EBAZ4205, XC7Z010 (7010). One board also has reballed 7020 (future theremin, not primary here). |
| Goal cores | ZX 48/128, **Pentagon 1024**, NES/Dendy, later C64 / Atari / SMS… |
| Video | HDMI 720p50, tear-free DDR triple-buffer |
| UI | ZX-BulboNavigator (DOS Navigator style), true-color 640×400 OSD in DDR |
| Storage | SD FatFs; TRD via Beta Disk + WD1793 in PL; ARM sector server |
| GitHub | https://github.com/Alex-Electron/ZX_BulbuLator |
| Owner rule | Bump `BULB_FW` on every meaningful ARM build; PL `VERSION` on every RTL build. Never ship old version string. |

**Architecture decision (council):** direction **(c)** — put ARM to work (OSD, loaders, disk server, soft synth). Direction (b) DDR-backed large RAM opened after HP latency gate passed.

---

## 2. Where everything lives

### 2.1 Machines

| Role | Host |
|---|---|
| Build + JTAG + Vivado 2023.1 | **ThinkPad** `lavrinovich@` (Tailscale historically `100.122.161.112`) |
| JTAG | **Platform Cable USB II**, `hw_server :3121` (xvc-pico is dead) |
| Screen / PS2 keyboard | Attached to board; owner is eyes |
| Mac | Remote control only; corp peer Hermes; **not** code SoT for this tree |

### 2.2 Trees on ThinkPad

| Path | Role |
|---|---|
| `~/bulb-v13/` | **Active repo** (SoT) |
| `~/bulb-v13/research/00…05` | Board bring-up history |
| `…/06-zx-spectrum-128` … `14-color-osd` | Published steps (Step 14 closed in main) |
| `…/15-pentagon/` | **Current worktree** (Step 15+) |
| `…/15-pentagon/sources/` | RTL: `control_plane.v`, `bulbulator_zx_ddr_top.v`, `bulbulator_nes_top.v`, `beta_disk.v`, `wd1793.sv`, `ddr_mem.v`, … |
| `…/15-pentagon/arm/loader_main.c` | Bare-metal ARM firmware (huge single file) |
| `…/15-pentagon/artifacts/ZX_CPLANE/` | Built `.bit` / `.bit.bin` / BOOT variants |
| `…/15-pentagon/buildlogs/` | Synth + BDI debug (esp. `bdi-2026-08-04/`) |
| `…/15-pentagon/tools/` | `zxscr.py`, `nes_pick.py`, `nes_upload_gen.py`, … |
| `~/sdboot/ws/loader/` | Vitis workspace for linker/make |
| Vault | `~/notes/Projects/Lichnoe/BulbuLator/` |

Other dirs (`bulb-ce13-phasefix`, `bulb-v12`, `bulbulator/`) are older scratch — prefer `bulb-v13`.

### 2.3 Version constants (source tree as of 2026-08-05)

| Constant | File | Value in tree |
|---|---|---|
| ARM `BULB_FW` | `arm/loader_main.c` | **`v0.15.216`** |
| ZX PL `BUILD_VERSION` | `sources/bulbulator_zx_ddr_top.v` | **`0xB01B0086`** (active `localparam`; older IDs nearby commented) |
| NES PL | `sources/bulbulator_nes_top.v` | **`0xB01BCE30`** in source (SD may still hold CE27/CE29 — verify live) |

**Git:** `master`, **dirty** — B0082…B0086 RTL/ARM/HANDOVER/BUILD_HISTORY not fully committed. Do **not** rewrite history; commit only after owner-confirmed Elysium face+cubes+sound and regressions.

---

## 3. Completed arc (Steps 0 → 15 summary)

### Done and published / HW-proven

| Step | Result |
|---:|---|
| 0–5 | Power, JTAG Pico (later DLC10), LEDs, HDMI bars/audio |
| 6 | ZX Spectrum 128 runs (Atlas/T80), HDMI 720p50, AY/TS/beeper |
| 7 | ARM↔PL AXI control plane (halt, RAM write → red screen) |
| 8 | Tear-free DDR framebuffer (triple buffer, HP) |
| 9–11 | PS/2, OSD gate, file browser, `bulbulator.ini`, panel pos/opacity |
| 12 | Snapshot load `.z80`/`.sna` from F5; reset-on-load; SD harden |
| 13 | Music player (PSG/MP3/WAV via ARM → HDMI PCM) |
| 14 | Colour OSD + **ZX-BulboNavigator** (copy/move/delete, tape station, …) **CLOSED** main `6fe92f6`, v0.14.92 / PL `0xB01B0017` |

### Step 15+ (in progress tree `15-pentagon`)

Major closed milestones (all HW-measured at some point):

1. **Tape path** FAST/SAFE, BRAM FIFO, AUTO-ROM gate, MP3 hybrid, SMART load experiments — see BUILD_HISTORY through ~B0049 / v0.15.136.
2. **NES core** (NESTang lineage) CE19…CE30 line: joypad bit order, scale, control_plane extract, region NTSC/PAL/Dendy, 164 games on SD.
3. **Keyboard factory frame assemble** (CE28/B0065+): ext-bit + device-reply filter; shell diag reg `0x13C`.
4. **ZX joystick types** Kempston/Sinclair/Cursor → real P2 on Spectrum (ARM-only, v0.15.199).
5. **control_plane.v** = single machine-agnostic shell (PS7, HDMI pipe, OSD, PS/2, axi_ctl, QUIESCE).
6. **Pixel path timing closed** B0063/B0064 (incremental address gen; no per-pixel div on 74.25 MHz).
7. **Pentagon 1024 true megabyte** B0070: banks 8..63 in DDR via HP2 `ddr_mem.v`; base 128K stays BRAM.
8. **CDC fix extended RAM read** **B0074** — ack raced data; machine got previous byte 5–10%. Owner UMT was right. Machine-side test mandatory.
9. **ROM from SD** **B0073** + v0.15.207: 4×16K pages, content-detect layout, TR-DOS trap bit8, service page bit9.
10. **Beta Disk / WD1793** **B0075–B0077** + v0.15.208/209: TRD catalog, MAXBOOT, **ETUNES 7 plays** (592 sectors).
11. **Elysium path** B0082…**B0085**: ELYSTATE full load host≈671, demo runs (MEMWR + Stardust OCR). See §4–5.
12. **B0086**: HDMI BDI floppy activity icon (cosmetic), live VERSION confirmed.

Step 16 (owner boundary): **C64 core + web KVM** — only after Step 15 closed (NES polish + all Spectrum cores recheck + real Pentagon + disk).

---

## 4. LIVE BOARD STATE (best known 2026-08-04 night → verify today)

| Object | Best known | Notes |
|---|---|---|
| Last successful Elysium-class demo path | **ZX B0085** volatile PCAP | ELYSTATE host=671, demo executes |
| Last built ZX bit | **B0086** `atlas_b0086.bit.bin` | SHA256 `cd4d30e5eabb05c45023a177e114f37f402692acfa60423473d026904eeb4f00`, size 1204288 |
| B0085 bit.bin SHA256 | `b48e2730515b3f4a65eaa4a3df43e29e39e54422e660810b6c41ed8691f0ce9c` | size 1151488 |
| Persistent SD boot (safe rollback) | Historically **B0078 + v0.15.214** family; also BOOT_ZX_B0078_V216.BIN in artifacts | **Do not overwrite** until owner signs off B0085/86 |
| ARM source | **v0.15.216** | Tree dirty; confirm live with splash / `nm` + symbol |
| MACHINE_CFG Pentagon+TRDOS trap | **`0x101`** (bit0 pentagon, bit8 TR-DOS trap) | Address **`GP0+0xBC`**. **Not** 0xB8 (KBD_DIAG / machine-dependent) |
| Default machine | pent1024, romset often `PENTGLUK.ROM` | ini on SD |
| Disk images on SD | `0:/DISKS/{ETUNES7,ELYSTATE,ELYSIUM}.TRD` | |

**hw_server** was listening on `:3121` when this handover was written.

**STATUS.md in vault still headlines B0077/v0.15.209** — it does **not** yet record B0084–B0086. Prefer BUILD_HISTORY + HANDOVER_CURRENT §12 + this file until STATUS is rewritten.

---

## 5. BDI / Elysium arc — what was wrong and what fixed it

### 5.1 Pipeline of defects (chronological)

| Core | Change | Outcome |
|---|---|---|
| B0077 | First working BDI: sector server, FDC_CTL shadow levels, +1 sector offset fix | ETUNES OK; Elysium title only (~155 sec) then stall |
| B0082 | READ ADDRESS = free-running 300 rpm / 16 IDs (not synthetic `ra_sector`) | Escapes SEEK↔C0 loop; hundreds of sectors; **phase-dependent** face fail |
| B0083 | Diagnostic **ring** of 12 BDI events (no WD functional change) | Face-hang ring captured; `bdi_always` bit10 **rejected** (#FE alias kills kbd + border) |
| B0084 | Exact ports `#1F/#3F/#5F/#7F/#FF`; **`bdi_session` until reset**; img_mounted handshake; RA CRC; HLT | session survives after leaving TR-DOS ROM; still hang paths |
| **B0085** | **#FF readback** = real Beta bits (SIDE/HLT/DS…); **DRQ ~32 µs/byte**; lost-data ~8 ms; sticky HLT | **ELYSTATE full load host=671; demo runs** |
| B0086 | `bdi_activity_icon.v` on HDMI bottom-right | Cosmetic; VERSION live |

### 5.2 Root causes worth tattooing

1. **Sector +1 race** (early): write strobe and address increment same cycle → shift by one byte.
2. **FDC_CTL levels wiped** by sector-feed command → ready bit cleared every sector.
3. **READ ADDRESS must be rotational**, independent of Sector Register (custom loaders).
4. **`trdos_on` drops** on M1 outside ROM → BDI ports vanish mid-loader unless **`bdi_session`**.
5. **Partial decode `sys_sel`** with `bdi_always` aliases **#FE** → keyboard + beeper/border corrupt. Never ship partial always-open BDI.
6. **#FF readback wrong** (always DS=3 style) → Elysium post-load dies after reading side/drive.
7. **DRQ too fast** → loader misses bytes / lost-data / silent stop while title still animates.
8. **Acceptance of RAM:** machine must self-test all banks; ARM-only read misses CDC on machine path (B0074 lesson).
9. **Screenshots > font OCR** for loaders (custom fonts). Tool: mirror `0x40008000` 1728 B → `tools/zxscr.py`.

### 5.3 Face-hang ring signature (B0083, still educational)

After READ SECTOR data drain → SEEK `0x18` → READ ADDRESS `0xC0` → one `#FF` read → **no Data `#7F`**, FDC ends INTRQ=1 DRQ=0 BUSY=0, MEMWR frozen. Logs: `buildlogs/bdi-2026-08-04/face_hang{,_ring.log,.png}`.

### 5.4 Still open on disk path

- Owner **visual** confirm: Elysium face + 3D cubes + sound stable (not only OCR/MEMWR).
- Multi-drive A/B/C/D, Force Interrupt, READ TRACK polish.
- Occasional post-demo escape to 48K BASIC (seen since B0082) — watch.
- ETUNES/AY subjective “music OK” — owner asked for **peak meter** proof; never claim music OK without peak meter / owner ears.
- **Persist** B0085 or B0086 to `0:/CORES/ATLAS.BIT.BIN` + BOOT only after owner OK.
- Git commit of dirty tree after that.
- SAA1099 `#FF` vs BDI conflict — night plan notes gate by `bdi_open` (sources may already partially address via `bdi_open` export); verify before claiming SAA OK.

---

## 6. Night plan 2026-08-04 (started, incomplete)

File: vault `2026-08-04-2300-night-roms-sound-plan.md`

| Task | Status |
|---|---|
| B0086 floppy icon | Done, live |
| Document B0086 in BUILD_HISTORY + HANDOVER | BUILD_HISTORY row exists; vault STATUS lagging |
| Offline ROM set classification | Started (signatures OK) |
| Live ROM audit all sets on board | **Not done** |
| SAA#FF gate vs BDI | Planned B0087; partial source work |
| AY/PCM peak telemetry | **Not done** |
| General Sound phase-1 (ARM stub + ports) | **Not done** |
| OPL3 / MIDI survey | Sketch only in night plan |

Machine matrix: Atlas 128 / Pentagon1024 / Atlas48 / MiSTer48 / NES. MiSTer48 historically lagged shell (rebuild required when shell features change).

---

## 7. What the next agent should do (ordered)

### P0 — Continuity of Elysium / BDI

1. `xsdb` connect → `mrd 0x43C00000` (VERSION), `mrd 0x43C000BC` (MACHINE_CFG), confirm ARM splash version.
2. If not on B0085/B0086: PCAP load `artifacts/ZX_CPLANE/atlas_b0085.bit.bin` or b0086 **without** killing good SD BOOT; remount TRD after PCAP (stale host counters).
3. Run `0:/DISKS/ELYSTATE.TRD` then `ELYSIUM.TRD`: TR-DOS → RUN; capture screens + host count + MEMWR growth + ring if hang.
4. If green for owner: persist bit + BOOT, update STATUS.md top, commit dirty tree with owner identity only.
5. If red: extend ring (READ ADDRESS end reason, lost-data, ready) — do **not** re-enable `bdi_always` partial decode.

### P1 — Night sound / ROM

6. Live ROM audit table (boot / TR-DOS / CAT / service).
7. Finish SAA vs BDI decode gate; tiny PL bump.
8. AY peak meter register (prove audio path).
9. GS ports skeleton + ARM co-proc mix into existing PCM path (BRAM full → DDR samples).

### P2 — Backlog (do not start unless owner redirects)

| ID | Work |
|---|---|
| B | Shell buffers LUTRAM→BRAM (~2.3k LUT) |
| C | Per-core palette (blocks Atari) |
| D | Wider input contract |
| E | NES cartridge in DDR (opens ~15k ROMs) |
| F | Already partially done as Pentagon 1024 |
| — | C64 = Step 16 (license: FPGA64 restricted; plan T65+Kawari+CIA) |
| — | Web/Ethernet KVM native DHCP |
| — | Save-states (need bidirectional RAM/reg read on axi_ctl) |

---

## 8. Recipes (copy-paste)

### 8.1 Build ARM

```bash
cd ~/bulb-v13/research/15-pentagon/arm
# bump BULB_FW in loader_main.c first
./build_loader.sh          # must print BUILD_OK
# elf lands via script into workspace / local loader.elf
```

### 8.2 Build ZX bitstream (~40–45 min)

```bash
cd ~/bulb-v13/research/15-pentagon
# set BUILD_VERSION in sources/bulbulator_zx_ddr_top.v
# ONLY one synth at a time (shared sources/build/)
bash build.sh              # or project /tmp/build_zx_*.sh if present
# bit.bin → artifacts/ZX_CPLANE/atlas_bXXXX.bit.bin
```

### 8.3 Safe warm reboot / QUIESCE

```bash
# NEVER raw rst -system without QUIESCE (GP0+0x114, wait STATUS bit3)
# leaves half-open HP0 burst → only POR recovers
xsdb ~/bulb-v13/research/15-pentagon/sources/warm_sd_reboot.tcl
```

### 8.4 Screen grab

```bash
# after connect target A9#0
# mrd -bin -file /tmp/s.bin 0x40008000 1728
python3 ~/bulb-v13/research/15-pentagon/tools/zxscr.py /tmp/s.bin /tmp/s.ppm 2
ffmpeg -y -i /tmp/s.ppm /tmp/s.png
```

### 8.5 Mailbox FS (`0x0F700000`)

| Off | Field |
|---|---|
| +0 | kick |
| +4 | cmd |
| +8 | done |
| +C | err — **clear before each cmd** |
| +10 | len — for READ = **request limit**, not file size |
| +14 | n = actual bytes |
| +0x200 / +0x400 | path / path2 |
| +0x800 | listing out |
| data buf | `0x0F900000` |

Cmds: 1 LIST, 2 WRITE, 3 DEL, 4 REN, 5 MKDIR, 6 COPY, 7 APPEND, 9 PL RELOAD, 10 NES LOAD, 11 KEY INJECT, 12 READ.

**Gotchas:** OSD open → mailbox silent; Esc inject closes menu but **not** during joy-map wizard. Machine DDR window `0x0FE00000` sits inside FS buffer range — large mailbox reads can trash extended RAM banks.

### 8.6 Disk auto-mount sketch

```text
wstr 0x0F700100 "0:/DISKS"
wstr 0x0F700180 "ELYSTATE.TRD"
mwr  0x0F700000 1
# TR-DOS menu: 4× Down (0x72) + Enter (0x5A); RUN key 0x2D
# disk log: mrd 0x0F700040 (+ last LBAs)
```

### 8.7 BDI ring dump (B0083+)

Select slot via `FDC_CTL` low nibble 4..15, word via bit10; read `FDC_STAT2` (`0x16C`). Prefer dump **only at confirmed hang** — dump path may disturb HOST counter (observed 6→584).

---

## 9. Permanent gotchas (abbreviated)

1. Version bump every build (`BULB_FW` + PL VERSION).
2. QUIESCE before system reset / PCAP path that resets PS interconnect.
3. Menu index audit `MENU_IX_EXPECT` — append options only at end of table.
4. Never put input logic on machine-dependent `0xB8`.
5. Prefixed PS/2 sequences: factory cook preferred; inject path bypasses prefix FSM.
6. `joymap_eval` must run under open OSD or joy freezes at 0.
7. ini host edits: full key=value rewrite + byte verify; never append blind.
8. Competitive pre-synth review for silent bugs (ROM_PAGES default, loading sticky reset, ungated address inc).
9. Git author only: Alexander Lavrinovich; no AI co-author trailers on public commits.
10. Owner: never claim music OK without peak meter / clear evidence.

---

## 10. Register cheat sheet (GP0 base `0x43C00000`)

| Off | Name | Notes |
|---|---|---|
| 0x00 | VERSION | e.g. `0xB01B0086` |
| 0x04 | CONTROL | halt, reset+wipe bit2, … |
| 0x08 | STATUS | reset_busy, QUIESCE ack bit3, … |
| 0x54 | KBD_DATA | cooked frame when CAPS bit3 |
| 0x60 | MACHINE_ID | who core is (not VERSION) |
| 0xB8 | machine-dep diag | **not** MACHINE_CFG |
| 0xBC | MACHINE_CFG | pentagon, region, trdos trap, bdi_always bit10, … |
| 0x13C | shell PS/2 diag | answer FIFO counters |
| 0x144 | ROM_LDCNT | facts written |
| 0x14C | MEM_STAT | was 34→32 packing bug historically |
| 0x150 | MACH_DBG | agnostic debug slot |
| 0x154… | ROM load ports | page write path |
| 0x160… | FDC sector bridge | + 0x16C ring/stat2 |
| 0x114 | QUIESCE | see warm_sd_reboot |

Exact field bits: read `axi_ctl.v` + `beta_disk.v` headers — source wins over memory.

---

## 11. Resources / timing (last measured points)

| Build | LUT | BRAM | Timing |
|---|---|---|---|
| B0074 | ~13432 (76%) | 58.5/60 | closed |
| B0077 | ~13980 (79%) | 59/60 | closed |
| B0083 | 14314 (81.3%) | 59/60 | WNS +0.377 |
| B0085/86 | ~similar / check synth log | 59/60 | met |
| NES CE28 era | ~14708 | 44.5 | met |

**BRAM almost full** — new sample RAM (GS) must use DDR, not BRAM.

---

## 12. Related vault docs (index)

| Doc | Topic |
|---|---|
| `INDEX.md` | Project charter + high-level status |
| `STATUS.md` | Status center (update after you verify board) |
| `state/current.md` | Long journal |
| `state/PENTAGON_1024_DESIGN.md` | Megabyte design (note: old WAIT wording corrected in STATUS) |
| `state/PENTAGON_ROM_TRDOS_PLAN.md` | ROM/TR-DOS plan |
| `DISK_SERVER_PLAN.md` | Longer disk architecture |
| `state/NES_MASTER_PLAN.md` | NES |
| `state/C64_MATERIAL.md` | C64 assets on Mac/ThinkPad |
| `state/COUNCIL_2026-08-02.md` | Council findings |
| `CHIP_7010_EMULATION_CEILING.md` | LUT ceiling |
| Kanban | `BulbuLator-Kanban.md` (partially stale vs STATUS) |

---

## 13. Explicit non-goals for next agent

- Do not start C64 synthesis until Step 15 disk+Elysium signed off.
- Do not enable `bdi_always` with partial #FE decode.
- Do not “fix” music by assumption.
- Do not push dirty Mac mirror as SoT.
- Do not invent board VERSION without `mrd`.
- Do not run two Vivado builds sharing `sources/build/` concurrently.

---

## 14. One-line current mission

> **Prove B0085/B0086 Elysium path to owner eyes (face + cubes + sound), persist it, then finish ROM audit + SAA gate + AY peak + GS phase-1 — without breaking ETUNES/TR-DOS/keyboard/#FE.**

---

*End of agent handover. Update this file or write `HANDOVER_AGENT_<date>.md` after each major arc; keep BUILD_HISTORY one-line-per-build forever.*
