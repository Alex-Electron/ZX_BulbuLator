#!/bin/bash
# build_boot.sh  -  build the SD-card BOOT.BIN (FSBL + loader bitstream + the loader ARM app), VM-free.
#
# Same two-step bootgen workaround as the earlier steps: Xilinx bootgen 2023.1 SEGFAULTs parsing ELF
# partitions on a modern glibc, so we hand it pre-extracted *.bin partitions and then patch the BootROM
# header's FSBL "Length of Image" (0x34) + total length (0x40) + checksum (0x48) by hand.
#
# Inputs (all local to flash/): fsbl.bin (reused unchanged since Step 6/7), ../bulbulator_zx_loader.bit
# (this step's bitstream), and loader.bin (the loader ARM app, loaded at 0x00100000). loader.bin is
# shipped; to regenerate it from the prebuilt ELF:
#     arm-none-eabi-objcopy -O binary ../arm/loader.elf loader.bin
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
BG=${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}
cd "$DIR"

[ -f loader.bin ] || arm-none-eabi-objcopy -O binary ../arm/loader.elf loader.bin

"$BG" -arch zynq -image bulb_loader_sd_bin.bif -w -o BOOT_raw.bin

python3 - <<'PY'
import struct
d = bytearray(open('BOOT_raw.bin','rb').read())
fsbl_len = len(open('fsbl.bin','rb').read())           # 0x18010
struct.pack_into('<I', d, 0x34, fsbl_len)              # Length of Image
struct.pack_into('<I', d, 0x40, fsbl_len)              # Total Image Length
s = sum(struct.unpack('<I', d[o:o+4])[0] for o in range(0x20,0x48,4)) & 0xFFFFFFFF
struct.pack_into('<I', d, 0x48, (~s) & 0xFFFFFFFF)     # BootROM header checksum
open('BOOT.BIN','wb').write(d)
print("BOOT.BIN: %d bytes, FSBL length=%#x, header checksum recomputed" % (len(d), fsbl_len))
PY
rm -f BOOT_raw.bin
echo ">>> BOOT.BIN (with the loader app) ready -> copy to the SD card's FAT 'boot' partition."
