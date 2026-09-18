# Handover: Menu "Yes/No" Bug + NES Browser Integration

**Date:** 2026-07-28  
**Board:** EBAZ4205 (Zynq 7010) — BulbuLator v0.15.147  
**User:** Александр  

---

## 1. Current State

### What Works
- **SD boot via JTAG:** Reliable pipeline: `build_loader.sh` → `build_boot.sh` → `sd_write_ws.tcl` → `rst -system`
- **Navigator:** Loads and displays correctly, file browsing works
- **Version:** Board boots v0.15.147 from SD card

### What's Broken

#### 🔴 BUG: Machine Selection Shows "YES/NO" Instead of Machine Names
When the user opens **Options → Machine → Machine**, the dropdown shows **YES/NO** instead of the expected machine names (ZX 128K / PENTAGON 1024K / ZX SPECTRUM 48K Atlas / ZX SPECTRUM 48K MiSTer).

#### 🟡 NES File Launch Not Yet Functional
Opening a `.nes` file from the browser does nothing visible. The NES FPGA bitstream is not loaded — the ZX Spectrum bitstream is active. `nes_load()` writes to NES-core AXI registers that don't exist in the ZX bitstream.

---

## 2. Analysis of the YES/NO Bug

### Source Code Appears Correct
The `opt_items[]` array in [loader_main.c](file:///home/lavrinovich/bulb-v13/research/15-pentagon/arm/loader_main.c) at index [20]:

```c
// Line ~4204
{"MACHINE", ITEM_CHOICE, &opt_defmachine, CH_MACHINE, N_MACHINES, machine_select_dialog, apply_machine},   /* [20] */
```

The `menu_item` struct (line ~4044):
```c
typedef struct {
    const char*        label;       // "MACHINE"
    item_kind          kind;        // ITEM_CHOICE
    int*               val;         // &opt_defmachine
    const char* const* choices;     // CH_MACHINE (should be {"ZX 128K", "PENTAGON 1024K", ...})
    int                nchoices;    // N_MACHINES = 4
    void              (*action)(void);   // machine_select_dialog
    void              (*onchange)(void); // apply_machine
    int                rmax;        // 0 (implicit)
    const char*        unit;        // NULL (implicit)
} menu_item;
```

The Machine submenu entries (lines ~4306, 4315, 4326) all reference `&opt_items[20]`:
```c
{"Machine", 0,0,NULL, NULL, &opt_items[20]},
```

### Hypotheses (NOT YET VERIFIED)

1. **Stale Object Files:** `build_loader.sh` compiles `main.c` with `-O0` but does NOT do `make clean`. If `main.o` doesn't get rebuilt (e.g., timestamp issue over NFS), the binary could contain old code. **→ Try: explicitly `rm src/main.o` before compile.**

2. **Struct Layout Mismatch:** The `menu_item` struct has 9 fields. If the designated initializer order doesn't match, or if there's a padding/alignment issue between the struct definition and the array initializer, fields could be shifted. The initializers use positional (not named) fields — a field count mismatch would silently shift `choices` to point at `CH_NOYES` from a neighboring entry. **→ Try: Add `__attribute__((packed))` or use named initializers `{.label="MACHINE", .kind=ITEM_CHOICE, ...}`.**

3. **Index [20] Shift at Link Time:** If another translation unit or header adds entries to `opt_items[]` or if `N_MACHINES` evaluates differently, the index could be off. **→ Try: Add a compile-time assert: `_Static_assert(&opt_items[20].choices == &CH_MACHINE_ref, "index 20 mismatch");`**

4. **Config File Corruption:** `BULBCFG.INI` on the SD card could have `defmachine=` set to an out-of-range value, causing `opt_defmachine` to be garbage. The `machine_select_dialog` or the menu renderer then reads past the array boundary. **→ Try: Delete `BULBCFG.INI` from the SD card and reboot.**

5. **`machine_select_dialog` vs Inline Choice Cycling:** When `action` is non-NULL for an `ITEM_CHOICE`, Enter opens the dialog. But if the menu renderer cycles the inline value on Left/Right arrows, and `opt_defmachine` has an invalid value, `choices[*val]` could read from the wrong array entirely. **→ Try: Initialize `opt_defmachine=0` unconditionally before config load.**

---

## 3. NES Integration Status

### What Exists in Committed Code
- `nes_load(const char* path)` — parses iNES header, streams PRG/CHR into NES core BRAM via AXI registers (`NES_LDCTL`, `NES_LD`, `NES_MAP0/1`)
- `nes_rom.c` — iNES/NES2.0 header parser
- `fs cmd 10` handler — calls `nes_load()` for remote/scripted loading
- NES FPGA bitstreams: multiple iterations in `artifacts/NES_B01BCE01/` (ce02→ce08), latest is `nes_ce08.bit.bin`
- 2-player joystick mapping (v0.15.146) already supports NES button layout

### What's Missing for Full NES Support
1. **NES not in `CH_MACHINE[]`** — no menu entry to switch FPGA to NES core
2. **No `.nes` handler in `browser_enter()`** — we added one (see diff below) but it needs the NES bitstream loaded first
3. **No `NES.BIT.BIN` on SD card** in `0:/CORES/` — needed for `pl_reload("NES")`
4. **Recommended flow:**
   - Add NES to `CH_MACHINE` / `MACHINE_TAG` / `CH_MACHINE_CORE` arrays (index 4, `N_MACHINES=5`)
   - `CH_MACHINE_CORE[4] = "NES"` → `apply_machine()` → `pl_reload("NES")` loads `0:/CORES/NES.BIT.BIN`
   - Copy `nes_ce08.bit.bin` → SD card as `0:/CORES/NES.BIT.BIN`
   - `.nes` handler in `browser_enter()` should first check if NES core is loaded (`g_cur_core`), and if not, switch to it before calling `nes_load()`

### Current Working Tree Diff
Only change to `loader_main.c` (vs committed `eaf812b`):
```diff
+        else if(cicmp(e,"nes")==0) {   /* v146: load .nes ROM into NES core BRAM */
+            char np[180]; int pp=0;
+            for(int i=0;curpath[i]&&pp<160;i++) np[pp++]=curpath[i];
+            if(pp && np[pp-1]!='/') np[pp++]='/';
+            for(int i=0;flist[bcursor][i]&&pp<179;i++) np[pp++]=flist[bcursor][i];
+            np[pp]=0;
+            nes_load(np);
+        }
```

---

## 4. Build Pipeline Reference

### Full Rebuild + Flash + Reboot (one-liner)
```bash
cd /home/lavrinovich/bulb-v13/research/15-pentagon/arm && \
  bash build_loader.sh && \
  cp loader.elf ../flash/ && \
  cd ../flash && \
  rm -f loader.bin && \
  arm-none-eabi-objcopy -O binary loader.elf loader.bin && \
  bash build_boot.sh && \
  cp BOOT.BIN /home/lavrinovich/sdboot/ws/BOOT.BIN
```

### JTAG Write + Reboot
```bash
killall hw_server 2>/dev/null; sleep 1
/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server >/tmp/hwsrv.log 2>&1 </dev/null &
sleep 3
/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb /home/lavrinovich/sdboot/ws/sd_write_ws.tcl
/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb -eval \
  'connect; targets -set -filter {name =~ "APU*"}; rst -system; after 500; puts "REBOOT DONE"'
```

### Key Paths
| What | Path |
|------|------|
| Loader source | `/home/lavrinovich/bulb-v13/research/15-pentagon/arm/loader_main.c` |
| Build script | `/home/lavrinovich/bulb-v13/research/15-pentagon/arm/build_loader.sh` |
| BOOT.BIN builder | `/home/lavrinovich/bulb-v13/research/15-pentagon/flash/build_boot.sh` |
| JTAG SD writer | `/home/lavrinovich/sdboot/ws/sd_write_ws.tcl` |
| SD writer binary | `/home/lavrinovich/sdboot/ws/sdwriter/src/main.c` |
| Vitis workspace | `/home/lavrinovich/sdboot/ws/` |
| NES bitstreams | `/home/lavrinovich/bulb-v13/research/15-pentagon/artifacts/NES_B01BCE01/` |
| ZX bitstream | `/home/lavrinovich/bulb-v13/research/15-pentagon/sources/build/bulbulator_zx_loader.bit` |

---

## 5. Debugging Priority

### Step 1: Fix the YES/NO Bug (CRITICAL)
This must be fixed before anything else. Suggested investigation:

1. **Force clean rebuild:**
   ```bash
   rm -f $WS/loader/Debug/src/main.o
   bash build_loader.sh
   ```

2. **Verify compiled binary has correct data:**
   ```bash
   arm-none-eabi-strings loader.elf | grep -i "pentagon\|ZX 128\|ZX SPECTRUM"
   ```
   If these strings are missing, the source wasn't compiled correctly.

3. **Check if `opt_defmachine` is out of range at runtime (JTAG):**
   ```tcl
   # opt_defmachine is at KMB+0x2C
   # KMB = KVM CONTROL MAILBOX base
   # Find KMB address: grep '#define KMB' loader_main.c
   connect; targets -set -filter {name =~ "APU*"}; stop
   mrd <KMB_ADDR+0x2C> 1
   ```

4. **Delete config and reboot:**
   Mount SD card, delete `BULBCFG.INI`, reboot.

### Step 2: NES Integration (AFTER menu fix)
Only proceed after the machine menu works correctly.

---

## 6. Important Notes

- **User's name is Александр** (NOT Алексей!)
- **Communication in Russian**, code/docs/commits in English
- The `sd_write_ws.tcl` uses a safe write strategy: write `BOOT.NEW` → verify → rename to `BOOT.BIN`
- `hw_server` must be restarted before JTAG operations (port binding issues)
- `build_loader.sh` compiles with `-O0` for main.c — watch for stale `.o` files
