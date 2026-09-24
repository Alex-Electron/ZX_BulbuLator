#!/bin/bash
# mkboot_zx.sh - собрать BOOT.BIN для загрузки с карты: FSBL + битстрим ZX + прошивка оболочки.
#
#   flash/mkboot_zx.sh <битстрим.bit> <выход BOOT.BIN> [loader.elf]
#
#   <битстрим.bit>  путь к .bit (например sources/build/bulbulator_zx_loader.bit или
#                   bitstreams/ATLAS_B0196.bit). Для совместимости со старыми вызовами голое имя ищется
#                   ещё и в ../artifacts/ZX_CPLANE/.
#   [loader.elf]    прошивка ARM; по умолчанию ../arm/loader.elf.
#
# Нужны bootgen (Vivado 2023.1: переменная BOOTGEN или bootgen в PATH), arm-none-eabi-objcopy и python3.
# FSBL берётся из flash/fsbl.bin рядом с этим скриптом.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 2 ] || { echo "usage: $0 <bitstream.bit> <out BOOT.BIN> [loader.elf]" >&2; exit 2; }
BIT="$1"; OUT="$2"; ELF="${3:-$DIR/../arm/loader.elf}"
[ -f "$BIT" ] || BIT="$DIR/../artifacts/ZX_CPLANE/$1"
[ -f "$BIT" ] || { echo "no bitstream: $1" >&2; exit 1; }
[ -f "$ELF" ] || { echo "no firmware: $ELF" >&2; exit 1; }
[ -f "$DIR/fsbl.bin" ] || { echo "no $DIR/fsbl.bin" >&2; exit 1; }
BG="${BOOTGEN:-$(command -v bootgen || echo /tools/Xilinx/Vivado/2023.1/bin/bootgen)}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIT=$(cd "$(dirname "$BIT")" && pwd)/$(basename "$BIT")

arm-none-eabi-objcopy -O binary "$ELF" "$TMP/loader.bin"
cat > "$TMP/zxboot.bif" <<BIF
the_ROM_image: {
  [bootloader, load = 0x0, startup = 0x0] $DIR/fsbl.bin
  $BIT
  [load = 0x00100000, startup = 0x00100000] $TMP/loader.bin
}
BIF
"$BG" -arch zynq -image "$TMP/zxboot.bif" -w -o "$TMP/raw.bin" >/dev/null
# Поля длины FSBL в заголовке (0x34 и 0x40) ставятся в настоящий размер fsbl.bin, затем пересчитывается
# контрольная сумма заголовка (0x48). Так собирались все образы этого шага, проверенные на плате.
python3 - "$TMP/raw.bin" "$DIR/fsbl.bin" "$OUT" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
fl = len(open(sys.argv[2], "rb").read())
struct.pack_into("<I", d, 0x34, fl); struct.pack_into("<I", d, 0x40, fl)
s = sum(struct.unpack("<I", d[o:o+4])[0] for o in range(0x20, 0x48, 4)) & 0xFFFFFFFF
struct.pack_into("<I", d, 0x48, (~s) & 0xFFFFFFFF)
open(sys.argv[3], "wb").write(d)
print("%s: %d bytes (fsbl=%#x)" % (sys.argv[3], len(d), fl))
PY
