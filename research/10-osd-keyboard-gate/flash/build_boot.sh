#!/bin/bash
# build_boot.sh  -  build the SD-card BOOT.BIN (FSBL + OSD bitstream + the OSD ARM app), VM-free.
#
# Same two-step bootgen workaround as the earlier steps: Xilinx bootgen 2023.1 SEGFAULTs parsing ELF
# partitions on a modern glibc, so we hand it pre-extracted *.bin partitions and then patch the
# BootROM header's FSBL "Length of Image" (0x34) + total length (0x40) + checksum (0x48) by hand.
#
# Inputs (all local to flash/): fsbl.bin (reused unchanged since Step 6/7), ../bulbulator_zx_osd.bit
# (this step's bitstream), and osd.bin (the OSD ARM app: build it with `make -C ../arm` -> copy
# arm/osd.bin here, or use the osd.bin already shipped).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
BG=${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}
cd "$DIR"

"$BG" -arch zynq -image bulb_osd_sd_bin.bif -w -o BOOT_raw.bin

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
echo ">>> BOOT.BIN (with the OSD app) ready -> copy to the SD card's FAT 'boot' partition."
