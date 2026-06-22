#!/bin/sh
# build_inj.sh - build the bare-metal ARM .z80 snapshot injector, zxinj.elf.
#
# Bring your own 128K .z80 snapshot — we don't ship copyrighted demos:
#   ./build_inj.sh path/to/your-demo.z80
#
# It embeds that snapshot and produces zxinj.elf here. The PS (Cortex-A9) loads the
# ELF over JTAG/xsdb (see ../../../ddr_inject_run.sh), which halts the Z80, streams
# the snapshot's RAM pages + ports + registers in over AXI, and resumes — the demo
# runs on the live Spectrum. Needs arm-none-eabi-gcc (from Vitis) + xxd.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SNAP=${1:?usage: ./build_inj.sh <snapshot.z80>  (bring your own 128K .z80)}
[ -f "$SNAP" ] || { echo "snapshot not found: $SNAP" >&2; exit 1; }
GCC=${ARM_GCC:-arm-none-eabi-gcc}
cd "$HERE"
# embed the snapshot as z80_data[] / z80_data_len (a stable symbol name, whatever the file is called)
cp "$SNAP" snapshot.z80
xxd -i snapshot.z80 | sed 's/snapshot_z80/z80_data/g' > z80_blob.c
rm -f snapshot.z80
"$GCC" -mcpu=cortex-a9 -marm -ffreestanding -nostdlib -O2 -Wall \
  crt0.S main.c z80_blob.c -T inject.ld -o zxinj.elf
echo ">>> built $HERE/zxinj.elf from $SNAP"
