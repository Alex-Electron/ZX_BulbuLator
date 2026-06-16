#!/bin/bash
# Fetch the original ZX Spectrum 128 ("toastrack", (C) 1986 Sinclair Research) ROM
# and convert it to rom128.hex for the build.
#
# We do NOT ship the ROM binary here — it is fetched from the fbzx project. The
# Spectrum 128 ROM is distributed under Amstrad's long-standing permission to
# redistribute the Sinclair/Amstrad ROMs for emulation use.
#
# Why this ROM and not the one the Atlas core ships: the Atlas rom.hex is the grey
# +2 (Amstrad) ROM, whose boot menu has no "Tape Tester". The original 128 toastrack
# ROM does: its menu is Tape Loader / 128 BASIC / Calculator / 48 BASIC / Tape Tester.
set -e
# Our fork of rastersoft/fbzx, kept so this keeps working if upstream moves.
BASE=https://raw.githubusercontent.com/Alex-Electron/fbzx/master/data/spectrum-roms

curl -fsSL -o 128-0.rom "$BASE/128-0.rom"   # ROM 0: 128 editor + boot menu (has Tape Tester)
curl -fsSL -o 128-1.rom "$BASE/128-1.rom"   # ROM 1: the 48 BASIC ROM

# ROM 0 first (the machine cold-boots into it = the menu), then ROM 1.
cat 128-0.rom 128-1.rom > combined128.rom

# mem_zx.v reads rom128.hex with $readmemh — one hex byte per line, 32768 bytes.
od -An -v -tx1 combined128.rom | tr ' ' '\n' | grep -v '^$' > rom128.hex

echo "rom128.hex: $(wc -l < rom128.hex) bytes (expect 32768)"
echo "first byte: $(head -1 rom128.hex) (expect f3 = DI, the reset entry)"
