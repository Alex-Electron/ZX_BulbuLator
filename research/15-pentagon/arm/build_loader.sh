#!/bin/bash
# loader.elf build for BulbuLator Step 13 (snapshot loader + F5 file browser + options + the universal
# music player: loader_main.c + player.c + third_party/ayumi, linked with -lm).
# Compiles against the standalone BSP and links the xilffs (FatFs) objects directly,
# bypassing the broken platform-generate/FSBL (xilffs objects exist but aren't archived into libxil.a).
# NOTE: this still needs the Vitis 2023.1 BSP workspace ($WS) - the ARM app is not yet clean-clone
# buildable (xsdps + FatFs aren't vendored into the repo); see the README's honest note. The xsdps /
# xilffs BSP sources carry the Step-11/12 hardening patches (diskio re-init + trimmed timeouts).
# All paths overridable via env.
set -e
source /tools/XilinxVitis/Vitis/2023.1/settings64.sh 2>/dev/null || true
WS="${WS:-/home/lavrinovich/sdboot/ws}"
BSP=$WS/ebaz/ps7_cortexa9_0/standalone_domain/bsp/ps7_cortexa9_0
BSP1=$WS/ebaz/ps7_cortexa9_1/ps7_cortexa9_1/bsp/ps7_cortexa9_1                 # v233: тут лежит собранный lwIP 2.1.3
LW=$BSP1/libsrc/lwip213_v1_0/src
LWINC="-I$BSP1/include -I$BSP1/include/lwip -I$LW/lwip-2.1.3/src/include -I$LW/contrib/ports/xilinx/include"
XF=$BSP/libsrc/xilffs_v5_0/src
ARMD="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$ARMD/loader_main.c}"
TP="$ARMD/../../../third_party"
APPDIR="${APPDIR:-$WS/loader}"

cp -f "$SRC" "$APPDIR/src/main.c"
# General Sound: ядро на ARM + вендоренный эмулятор Z80 (z80emu, "do whatever you want with it")
cp -f "$ARMD/gs_arm.c" "$APPDIR/src/gs_arm.c"
cp -f "$ARMD/divmmc_fs.c" "$ARMD/divmmc_fs.h" "$APPDIR/src/"   # v327
mkdir -p "$APPDIR/src/z80emu"
cp -f "$ARMD"/z80emu/*.c "$ARMD"/z80emu/*.h "$APPDIR/src/z80emu/"
cp -f "$ARMD/gs_z80user.h" "$APPDIR/src/z80emu/z80user.h"   # наша привязка вместо тестовой из поставки
cp -f "$ARMD/tv_ui.h" "$ARMD/tv_ui.c" "$APPDIR/src/"
cp -f "$ARMD/rom_ident.h" "$ARMD/rom_ident.c" "$APPDIR/src/"   # v384: распознаватель страниц ПЗУ (#include-ится в main.c)
cp -f "$ARMD/net_kvm.c" "$APPDIR/src/net_kvm.c"   # v233: веб-КВМ, подключается #include-ом в main.c
cp -f "$ARMD/vga866.h" "$APPDIR/src/vga866.h"          # Step 14.4: CP866 VGA 8x16 font (DOS-Navigator OSD)
cp -f "$ARMD/nes_rom.c" "$APPDIR/src/nes_rom.c"   # v146: iNES parser (#included by main.c)
cp -f "$ARMD/player.c" "$APPDIR/src/player.c"          # universal music player (Step 13.2)
cp -f "$ARMD/mp3dec.c" "$ARMD/mp3dec.h" "$APPDIR/src/"        # Step 14.3: shared MP3 source (music + tape)
cp -f "$TP/minimp3/minimp3.h" "$APPDIR/src/"                  # minimp3 (public-domain MP3 decoder, CC0)
cp -f "$TP/speexdsp/resample.c" "$TP/speexdsp/arch.h" "$TP/speexdsp/fixed_generic.h" \
      "$TP/speexdsp/speex_resampler.h" "$APPDIR/src/"         # speexdsp polyphase resampler (BSD) - audiophile WAV/MP3 -> 47996
cp -f "$TP/ayumi/ayumi.c" "$TP/ayumi/ayumi.h" "$APPDIR/src/"   # AYUMI soft-AY (MIT)
cp -f "$ARMD/lscript.ld" "$APPDIR/src/lscript.ld"      # vendored linker script: reserves the top-of-DDR
                                                       # non-cacheable window (D-cache foundation, Step 13)
cp -f "$XF/diskio.c" "$APPDIR/src/diskio_bulb.c"
patch --batch --forward --silent "$APPDIR/src/diskio_bulb.c" "$ARMD/xilffs_diskio_ready_guard.patch"
cd "$APPDIR/Debug"

echo "=== compile ==="
# v02.08: main.c ПЕРЕВЕДЁН НА -O2. Всё остальное собиралось так с самого начала; вся история про
# «нечёткость ввода» мерялась на НЕоптимизированном коде, и это был самый дешёвый оставшийся выигрыш.
# Предусловие сделано: g_tape_drain стал volatile (иначе -O2 вправе закешировать его и повесить ленту).
arm-none-eabi-gcc -Wall -O2 -g3 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I"$BSP/include" $LWINC -o src/main.o ../src/main.c
arm-none-eabi-gcc -Wall -O2 -g3 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -DOUTSIDE_SPEEX -DFIXED_POINT -DRANDOM_PREFIX=bulb \
  -I"$BSP/include" -I../src -o src/player.o ../src/player.c
arm-none-eabi-gcc -O2 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -DOUTSIDE_SPEEX -DFIXED_POINT -DRANDOM_PREFIX=bulb \
  -o src/resample.o ../src/resample.c
arm-none-eabi-gcc -O2 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I"$BSP/include" -I../src -o src/mp3dec.o ../src/mp3dec.c
arm-none-eabi-gcc -O2 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -o src/ayumi.o ../src/ayumi.c
arm-none-eabi-gcc -Wall -O2 -g3 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I"$BSP/include" -o src/diskio_bulb.o ../src/diskio_bulb.c
arm-none-eabi-gcc -O2 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I../src -I../src/z80emu -o src/gs_arm.o ../src/gs_arm.c
arm-none-eabi-gcc -O2 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I../src/z80emu -o src/z80emu.o ../src/z80emu/z80emu.c
arm-none-eabi-gcc -Wall -O2 -g3 -c -fmessage-length=0 \
  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I"$BSP/include" -I../src -o src/divmmc_fs.o ../src/divmmc_fs.c


echo "=== link (main.o + player + ayumi + xilffs objs + libxil.a[xsdps]) ==="
arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,../src/lscript.ld \
  -L"$BSP/lib" -L"$BSP1/lib" -o loader.elf \
  src/main.o src/player.o src/mp3dec.o src/resample.o src/ayumi.o src/diskio_bulb.o src/gs_arm.o src/z80emu.o src/divmmc_fs.o "$XF/ff.o" "$XF/ffunicode.o" "$XF/ffsystem.o" \
  -Wl,--start-group,-lxil,-llwip4,-lgcc,-lc,-lm,--end-group

ls -la loader.elf
echo "BUILD_OK - copy loader.elf into the repo: cp loader.elf <repo>/research/12-snapshot-loader/arm/loader.elf"
cp -f "$APPDIR/Debug/loader.elf" "$ARMD/loader.elf"   # auto-copy into the repo (kills the stale-elf trap)
