#!/bin/bash
# build_boot.sh  -  build the SD-card BOOT.BIN (FSBL + DDR bitstream + idle), VM-free.
#
# Xilinx bootgen 2023.1 SEGFAULTS when it has to parse ELF partitions on a modern glibc
# (Ubuntu's 2.43 vs the 2023.1 tools). Two-step workaround:
#   1. Hand bootgen pre-extracted *.bin partitions (no ELF parsing) -> it builds the image,
#      but for a .bin FSBL it leaves the BootROM header's "Length of Image" field = 0.
#   2. Patch that field (0x34) + the total-image-length (0x40) to the real FSBL size, and
#      recompute the BootROM header checksum (0x48 = ~sum(words 0x20..0x44)).
#
# fsbl.bin / idle.bin here are the loadable PT_LOAD segments of the Step-6/7 fsbl.elf / idle.elf
# (extracted with: objcopy -O binary, or a 12-line ELF program-header slice). The resulting
# BootROM header is byte-identical to a known-good bootgen-on-VM image (verified by checksum).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
BG=${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}
cd "$DIR"

"$BG" -arch zynq -image bulb_ddr_sd_bin.bif -w -o BOOT_raw.bin

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
echo ">>> BOOT.BIN ready -> copy to the SD card's FAT 'boot' partition (rename to BOOT.BIN)."
