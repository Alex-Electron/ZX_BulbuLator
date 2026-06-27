#!/bin/bash
# loader.elf build for BulbuLator Step 12 (snapshot loader + F5 file browser + options/config).
# Compiles loader_main.c against the standalone BSP and links the xilffs (FatFs) objects directly,
# bypassing the broken platform-generate/FSBL (xilffs objects exist but aren't archived into libxil.a).
# NOTE: this still needs the Vitis 2023.1 BSP workspace ($WS) - the ARM app is not yet clean-clone
# buildable (xsdps + FatFs aren't vendored into the repo); see the README's honest note. The xsdps /
# xilffs BSP sources carry the Step-11/12 hardening patches (diskio re-init + trimmed timeouts).
# All paths overridable via env.
set -e
source /tools/XilinxVitis/Vitis/2023.1/settings64.sh 2>/dev/null || true
WS="${WS:-/home/lavrinovich/sdboot/ws}"
BSP=$WS/ebaz/ps7_cortexa9_0/standalone_domain/bsp/ps7_cortexa9_0
XF=$BSP/libsrc/xilffs_v5_0/src
SRC="${SRC:-$(cd "$(dirname "$0")" && pwd)/loader_main.c}"
APPDIR="${APPDIR:-$WS/loader}"

cp -f "$SRC" "$APPDIR/src/main.c"
cd "$APPDIR/Debug"

echo "=== compile ==="
arm-none-eabi-gcc -Wall -O0 -g3 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I"$BSP/include" -o src/main.o ../src/main.c

echo "=== link (main.o + xilffs objs + libxil.a[xsdps]) ==="
arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,../src/lscript.ld \
  -L"$BSP/lib" -o loader.elf \
  src/main.o "$XF/ff.o" "$XF/ffunicode.o" "$XF/ffsystem.o" "$XF/diskio.o" \
  -Wl,--start-group,-lxil,-lgcc,-lc,--end-group

ls -la loader.elf
echo "BUILD_OK - copy loader.elf into the repo: cp loader.elf <repo>/research/12-snapshot-loader/arm/loader.elf"
