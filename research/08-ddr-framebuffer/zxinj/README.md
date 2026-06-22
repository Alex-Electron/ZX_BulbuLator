# zxinj — bare-metal ARM .z80 snapshot injector

This is the Cortex-A9 (PS) side of the "load a demo over AXI" path. It halts the
Z80, streams a 128K `.z80` snapshot's RAM pages + paging/border ports + Z80
registers into the running Spectrum over the AXI control plane, then resumes — the
demo comes up on the live core (see [`../ddr_inject_run.sh`](../ddr_inject_run.sh)).

Bring your own 128K `.z80` (we don't ship copyrighted demos):

```
./build_inj.sh path/to/your-demo.z80     # -> zxinj.elf  (snapshot embedded)
```

Needs `arm-none-eabi-gcc` (from Vitis; override with `ARM_GCC=`) and `xxd`. The
generated `z80_blob.c` and `zxinj.elf` are build artifacts (git-ignored).

| File | What it is |
|------|------------|
| `main.c` | the injector: parses .z80 v3 (RLE), writes RAM/ports/regs via the AXI map |
| `crt0.S` | bare-metal startup (no libc) |
| `inject.ld` | linker script (load address for the ELF) |
| `build_inj.sh` | embed your snapshot + cross-compile |
