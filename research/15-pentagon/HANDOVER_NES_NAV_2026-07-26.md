# HANDOVER (полный, детальный): BulbuLator Navigator + NES — 2026-07-26

**Дата эстафеты:** 2026-07-26 (сессия остановлена owner’ом: «стоп»).  
**Плата:** Digilent/EBAZ4205, Zynq-7010 (xc7z010), dual Cortex-A9, PS DDR 256MB.  
**Роли ядер:** CPU0 = game loader + OSD navigator (`loader.elf`); CPU1 = net_kvm (в этой сессии eth GIC не закрывали).  
**JTAG:** Xilinx Platform Cable USB → ThinkPad `hw_server` **:3121**.

---

## 0. Где живёт код (истина)

| Роль | Путь |
|------|------|
| **Live source ARM** | ThinkPad `/home/lavrinovich/bulb-v13/research/15-pentagon/arm/loader_main.c` |
| Build script | `…/arm/build_loader.sh` |
| Output ELF (Vitis app) | `~/sdboot/ws/loader/Debug/loader.elf` |
| Deploy copy | `…/15-pentagon/arm/loader.elf` (**всегда `cp` после build**) |
| ATLAS PL bit (cold boot) | `…/sources/build/bulbulator_zx_loader.bit` |
| ATLAS `.bit.bin` (PCAP) | `…/bulbulator_zx_loader.bit.bin` (~1.1 MB, root 15-pentagon) |
| NES PL bit.bin (PCAP) | `…/sources/build/bulbulator_zx_loader_nes.bit.bin` (~953 KB), VERSION **0xB01BCE08** |
| NES top RTL | `…/sources/bulbulator_nes_top.v` |
| axi_ctl NES regs | `…/sources/axi_ctl.v` (`ifdef NES_CORE`) |
| Deploy TCL | `/tmp/run_hdmi_nav.tcl` (часто) |
| FCLK init | `…/flash/ps7_init_fclk.tcl` (**FCLK0=100 MHz**, не kvm ~25 MHz) |
| Mac mirror | `…/DIY/EBAZ4205/BulbuLator/research/15-pentagon/` (не всегда sync с ThinkPad) |
| Этот handover | `HANDOVER_NES_NAV_2026-07-26.md` + `HANDOVER_CURRENT.md` |

**Последний известный ELF:** `arm/loader.elf` **1305020** bytes, mtime **Jul 26 19:08**.  
**Флаг:** `#define NES_R1_UI_OFF 0` в source → load path **включён** (ветка `#if NES_R1_UI_OFF` выключена компилятором).  
**SD cores:** фоновая заливка `ATLAS.BIT.BIN` + `NES.BIT.BIN` **оборвана** (exit 1). **Проверить карту.**

---

## 1. Цель сессии (owner)

1. DN-навигатор на HDMI, list SD.  
2. Переключение машин: 128K / Pentagon / 48 Atlas / 48 MiSTer / **NES**.  
3. Enter по `.nes` (танчики / Tank 1990) → load.  
4. F11 = reboot **выбранной** машины.  
5. Screen X/Y = HDMI window; Offset H/V = pan; Paper = Pentagon.  
6. Явные статусы ошибок (NEED CORES / LOAD E / …), не «молча ничего».

---

## 2. Архитектура

```
┌─────────────────────────────────────────────────────────────┐
│ CPU0 loader.elf                                             │
│  FatFs SD ──► pl_reload(PCAP) ──► 0:/CORES/*.BIT.BIN       │
│  browser Enter .nes ──► nes_ensure_core ──► nes_load       │
│  F12 ──► open_browser ──► atlas_ensure_ui (host ATLAS)     │
│  KMB 0x0F700000 JTAG FS (cmd 1/2/5/9/10)                   │
└───────────────┬─────────────────────────────────────────────┘
                │ GP0 0x40000000
┌───────────────▼─────────────────────────────────────────────┐
│ PL bitstream (одна из)                                       │
│  ATLAS  VERSION 0xB01B0061 — Spectrum+ULA+OSD+PS2+HP0/1    │
│  NES    VERSION 0xB01BCE08 — NESTang NROM BRAM + video       │
│         PS2 STUB, HP1 OSD IDLE, HP0 write fragile            │
└───────────────┬─────────────────────────────────────────────┘
                │ HP0 write FB 0x0FF00000 (triple, stride 0x10000)
                │ HP1 read OSDC 0x0F800000 (только полноценный ATLAS)
                ▼
              HDMI 720p
```

### 2.1 Реестр машин (ARM)

| idx | UI label | ini TAG | FPGA core | SD bit |
|-----|----------|---------|-----------|--------|
| 0 | ZX 128K | zx128 | ATLAS | (cold flash bit) + optional `ATLAS.BIT.BIN` |
| 1 | PENTAGON 1024K | pent1024 | ATLAS | same bitstream, MACHINE_CFG |
| 2 | ZX SPECTRUM 48K (Atlas) | zx48 | ATLAS | MACHINE_CFG |
| 3 | ZX SPECTRUM 48K (MiSTer) | zx48mr | MISTER48 | `0:/CORES/MISTER48.BIT.BIN` |
| 4 | NES / DENDY | nes | NES | `0:/CORES/NES.BIT.BIN` |

- `g_cur_core` — что **реально** в PL: `"ATLAS"` / `"NES"` / `"MISTER48"`.  
- `opt_defmachine` — выбор меню (KMB+0x2C).  
- Boot detect: `REG_VERSION & 0xFFFF`: `0x0059` → MISTER48; **`(cv & 0xFF00) == 0xCE00`** → NES; else ATLAS.

### 2.2 GP0 NES (только NES bit)

| Offset | Macro | Назначение |
|--------|-------|------------|
| +0x104 | NES_MAP0 | mapper_flags[31:0] |
| +0x108 | NES_MAP1 | mapper_flags[63:32] |
| +0x10C | NES_LD | byte → BRAM, auto-inc |
| +0x110 | NES_LDCTL | bit0 load, bit1 CHR, bit2 reset pulse, bit3 rewind |

Чтение unmapped часто `0xDEADBEEF` (write-only).

### 2.3 Debug на NES PL

- **GP0+0xAC:** `{hpw[31:16], nes_act[15:0]}`  
  - `nes_act`↑ = пиксели/vid_wr_ce  
  - `hpw`↑ = успешные HP0 AW — **на R1 часто ~1** → **чёрный HDMI** / stale FB  
- **GP0+0xB8 (CE08 sticky):** vram_ce / nametable_wr / cpu_wr — часто cpu_wr без фона (VBlank/$2002/NMI).

### 2.4 KVM mailbox (JTAG FS)

| Offset | Symbol | |
|--------|--------|--|
| +0x04 | g_fs_cmd | 1 LIST, 2 WRITE, 3 DEL, 4 REN, 5 MKDIR, 6 COPY, 7 APPEND, 9 PCAP, 10 NES_LOAD |
| +0x08 | g_fs_done | 0 work, 1 OK, **0xE** err |
| +0x0C | g_fs_err | FatFs / pl / nes codes |
| +0x10 | g_fs_len | размер WRITE |
| +0x200 | g_fs_path | path1 |
| +0x400 | g_fs_path2 | path2 |
| +0x800 | g_fs_out | LIST text (cp866) |
| 0x0F900000 | FS_BUF | `dow -data` payload |

FatFs, с чем билились: **12 = FR_NOT_ENABLED**, **13 = FR_NO_FILESYSTEM**.

### 2.5 Память / FB / OSD

| Region | Addr | |
|--------|------|--|
| NC window | 0x0F700000..0x0FFFFFFF | 9 MB non-cacheable |
| KMB | 0x0F700000 | mailbox |
| OSDC ARGB | 0x0F800000 | 640×400 DN canvas |
| FS_BUF | 0x0F900000 | PCAP/stream staging |
| Game FB0 | 0x0FF00000 | triple buffer, stride 0x10000 |

Defaults UI: `opt_scr_x=256`, `opt_scr_y=58`, `opt_x=320`, `opt_y=160` (nav).  
`fb_wipe_black()`: zero 0x0FF00000 size 0x30000 + DCache flush.

---

## 3. Поток load `.nes` при `NES_R1_UI_OFF == 0`

```
browser_enter
  if ext == "nes" → load_nes_rom()
    path = curpath + "/" + flist[bcursor]
    nes_ensure_core()
      if g_cur_core=="NES": return 0
      find 0:/CORES/NES.BIT.BIN (alts: nes.bit.bin, BULBULATOR_…)
      pl_reload → PCAP
      g_cur_core="NES"; opt_defmachine=4
      fb_wipe_black(); optional OSD if browser_on
    opt_nes_cart = path
    nes_load(path)   // iNES → MAP → PRG → CHR → reset
    on fail: nes_finish_to_host("LOAD E 0x..")
    on ok:   nes_finish_to_host("CART OK - BACK HOST")
      atlas_ensure_ui()  // PCAP ATLAS.BIT.BIN if needed + ZX128 profile + kbd_init
      open_browser()
```

**Почему всегда host после cart:** NES R1 bit **stub PS/2** (`kbd_fifo_empty=1`) и **HP1 OSD idle** → F12 **физически не доходит** и nav **не рисуется**. Stay on NES = brick.

При `NES_R1_UI_OFF == 1` (safe): PCAP запрещён; Enter только `CART SAVED`; machine NES → rollback.

---

## 4. Что сделано в ARM (чеклист)

### Host / navigator

| | |
|--|--|
| `sd_mount_retry()` | до 6× `f_mount` с delay |
| `ui_geometry_defaults()` | clamp scr/nav/crop; apply_scr/crop/pos |
| `open_browser` | atlas_ensure + geometry + OSDC + sd_scan |
| boot | geometry; bootnav scan; geometry again |
| `config_load` | mount через retry |
| `atlas_ensure_ui` | PCAP ATLAS; bad profile → force zx128; reinit+kbd only if PCAP or bad profile; **не** reset на каждом F12 |
| `machine_cfg_word` | NES encoding только если PL=NES |
| boot guard | defmachine==nes → force 0 перед apply_machine |
| F11 | `machine_hard_reboot` |

### NES ARM

| | |
|--|--|
| `nes_ensure_core` / `nes_load` / `load_nes_rom` / `nes_boot_default` | PCAP + cart |
| `nes_finish_to_host` | host UI after cart |
| VERSION `0xCExx` | g_cur_core NES |
| `opt_nes_cart` / ini `nes_cart=` | boot cart |
| `fb_wipe_black` | убрать призраки 128K |

### SD / ROM (JTAG FS, когда успевали)

- `0:/NES/tank1990.nes`, `tanchiki.nes`, `BOOT.NES`  
- Уже были: Tank 1990 (Ch)…, Contra, SMB, 1200-in-1  
- `0:/CORES/NES.BIT.BIN` (ранний stage OK)  
- `0:/CORES/ATLAS.BIT.BIN` — **финальный stage failed**

---

## 5. Симптомы owner → причины

| Симптом | Причина |
|---------|---------|
| Enter танчики — «ничего» | нет NES.BIT.BIN; status NEED CORES |
| Окно меняется, призраки 128K | PCAP NES + crop 256×240 + stale Spectrum FB |
| Чёрный, F12 мёртв | stay NES: no kbd, no OSD, no video |
| Чёрный + белая полоса, nav кривой | ATLAS PL + defmachine=4 / crop NES / SCR / wipe |
| NO CARD | f_mount fail после thrash |
| «Зачем PCAP каждый раз» | host return thrash ATLAS↔NES (R1 safety) |
| «NES не грузится» | был `NES_R1_UI_OFF 1` или fail cores/host return |
| DAP error | hang; только full rst-system |

---

## 6. NES bitstream — блокер (RTL)

Без этого ARM «играбельный NES» невозможен.

### P0 — Input / UI escape
- Реальный **PS/2 → kbd FIFO** (как в `bulbulator_zx_ddr_top.v`), не stub.  
- Или **HP1 OSD** на NES.  
- Тогда F12 на NES → local nav или `atlas_ensure_ui`.

### P0 — Video
- **hpw** не растёт: `fb_wr_axi` / HP reset (история CE04 writefix).  
- CE08 sticky: **VBlank $2002 / NMI** — игры не пишут nametable.

### P1
- Stay-on-NES multi-cart без PCAP (когда kbd+video OK).  
- Убрать `nes_finish_to_host` в playable mode.

### P2
- Mappers > NROM; joy Dendy.

**Tank 1990:** mapper 0, PRG 32K, CHR 8K — NROM, для R1 core подходит.

---

## 7. Процедуры

### 7.1 Cold recover host

```bash
export PATH=/tools/XilinxVitis/Vitis/2023.1/bin:$PATH
export _JAVA_OPTIONS="-XX:-UseContainerSupport"
cd /home/lavrinovich/bulb-v13/research/15-pentagon/arm
bash build_loader.sh
cp -f /home/lavrinovich/sdboot/ws/loader/Debug/loader.elf ./loader.elf
xsct /tmp/run_hdmi_nav.tcl
```

**Обязательно:** `ps7_init_fclk.tcl` (100 MHz).  
После thrash: `rst -system` + full ps7_init + bit + dow (см. recover tcl в `/tmp`).

### 7.2 JTAG checks

```
mrd 0x40000000          # VERSION
mrd 0x0F70002C          # opt_defmachine
mrd 0x40000048          # OSD_CTRL bit1
FS LIST 0:/             # DONE=1
на NES: mrd 0x400000AC  # hpw vs nes_act
```

### 7.3 Stage cores (после boot loader)

```
MKDIR 0:/CORES
WRITE ATLAS.bit.bin → 0:/CORES/ATLAS.BIT.BIN
WRITE NES.bit.bin   → 0:/CORES/NES.BIT.BIN
LIST 0:/CORES
```

Без **ATLAS.BIT.BIN** `atlas_ensure_ui` / `nes_finish_to_host` → fail → brick после NES.

### 7.4 Build pitfalls

1. ELF в Debug/; deploy читает `arm/loader.elf` — **всегда cp**.  
2. Implicit `apply_pint`/`apply_paper` — нужны fwd.  
3. Patch script `raise` до `write_text` теряет все правки.  
4. `ui_geometry_defaults` clamp **не** лечит `scr_x=0` (0 in-range) — harden optional.

---

## 8. ini / config

`0:/bulbulator.ini`:
- `defmachine=nes` → boot guard → zx128.  
- `nes_cart=…` — default cart.  
- `scr_x`/`scr_y` per machine; **0,0** = top-left (не clamp’ится как invalid).

---

## 9. Политика UI (согласовать с owner)

| Режим | Поведение |
|-------|-----------|
| **R1 safe** (`NES_R1_UI_OFF 1`) | Нет PCAP NES; host жив; status OFF |
| **R1 experiment** (`NES_R1_UI_OFF 0`, **сейчас в source**) | PCAP+cart, потом host; игры на HDMI может не быть |
| **R2 playable** | Stay NES, multi-cart, F12 host или OSD on NES |

---

## 10. Next (приоритет)

### Host
1. Recover + F12 + SD list.  
2. LIST `0:/CORES` — доложить ATLAS+NES bit.bin.  
3. ini `defmachine=zx128`.  
4. Optional: force scr defaults if both 0.

### NES (RTL first)
1. PS/2 FIFO.  
2. VBlank/NMI + hpw.  
3. OSD or documented host escape with kbd.  
4. Stay-on-NES + multi-cart.

### Не делать
- Leave user on NES R1 без kbd.  
- PCAP NES без ATLAS.BIT.BIN.  
- machine_reset каждый F12.

---

## 11. Хронология

1. UI/menu/network (контекст).  
2. NES load path + SD ROMs + ensure core.  
3. Ghosts 128K → wipe + geometry.  
4. Stay NES → F12 brick.  
5. Host return after cart → thrash, F12 жив.  
6. R1 OFF → nav OK, NES «не грузится».  
7. Source снова OFF=0; stage cores aborted.  
8. Stop → handover.

---

## 12. Связанные docs

- `HANDOVER_CURRENT.md` (25.07): Dual-Engine 48K Atlas; NES CE04/CE08.  
- `artifacts/NES_B01BCE01/CORRECTION.md`: false positive video (stale ZX FB).  
- `HANDOVER_STEP15.md`: machines, PCAP, menus.

---

## 13. Итог одной фразой

**Host/navigator можно стабилизировать ARM-ом; playable NES упирается в Round-1 bitstream (PS/2, OSD, HP video / VBlank). ARM PCAP+cart+return-host — готовый каркас; cores на SD после стопа нужно проверить/доложить.**
'''

base = Path("<репозиторий>/research/15-pentagon")
base.mkdir(parents=True, exist_ok=True)
(base / "HANDOVER_NES_NAV_2026-07-26.md").write_text(content)
(base / "HANDOVER_CURRENT.md").write_text(content)
print("Mac OK", len(content.splitlines()), "lines", len(content), "bytes")
Path("/tmp/HANDOVER_NES_NAV_FULL.md").write_text(content)
print("tmp OK")
