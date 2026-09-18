#!/bin/bash
# BOOT.BIN с ZX-ядром ATLAS (аргумент = имя .bit в artifacts/ZX_CPLANE) + текущей прошивкой.
set -e
BIT="$1"; OUT="$2"
DIR="$HOME/bulb-v13/research/15-pentagon/flash"; BG=/tools/Xilinx/Vivado/2023.1/bin/bootgen
cd "$DIR"
cat > /tmp/zxboot.bif <<BIF
the_ROM_image: {
  [bootloader, load = 0x0, startup = 0x0] fsbl.bin
  ../artifacts/ZX_CPLANE/$BIT
  [load = 0x00100000, startup = 0x00100000] loader.bin
}
BIF
rm -f loader.bin
arm-none-eabi-objcopy -O binary ../arm/loader.elf loader.bin
"$BG" -arch zynq -image /tmp/zxboot.bif -w -o /tmp/BOOT_raw_zx.bin >/dev/null
python3 - "$OUT" <<PY
import struct,sys
d=bytearray(open("/tmp/BOOT_raw_zx.bin","rb").read())
fl=len(open("fsbl.bin","rb").read())
struct.pack_into("<I",d,0x34,fl); struct.pack_into("<I",d,0x40,fl)
s=sum(struct.unpack("<I",d[o:o+4])[0] for o in range(0x20,0x48,4)) & 0xFFFFFFFF
struct.pack_into("<I",d,0x48,(~s)&0xFFFFFFFF)
open(sys.argv[1],"wb").write(d)
print("%s: %d байт (fsbl=%#x)" % (sys.argv[1], len(d), fl))
PY
rm -f /tmp/BOOT_raw_zx.bin
