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

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

check_sha256() {
    got=$(sha256_file "$1")
    if [ "$got" != "$2" ]; then
        echo "$1: SHA-256 mismatch: got $got, expected $2" >&2
        exit 1
    fi
}

# The URL may move, but a build must never silently consume different ROM bytes.
check_sha256 128-0.rom 3ba308f23b9471d13d9ba30c23030059a9ce5d4b317b85b86274b132651d1425
check_sha256 128-1.rom 8d93c3342321e9d1e51d60afcd7d15f6a7afd978c231b43435a7c0757c60b9a3

# ROM 0 first (the machine cold-boots into it = the menu), then ROM 1.
cat 128-0.rom 128-1.rom > combined128.rom
check_sha256 combined128.rom c1ff621d7910105d4ee45c31e9fd8fd0d79a545c78b66c69a562ee1ffbae8d72

# mem_zx.v reads rom128.hex with $readmemh — one hex byte per line, 32768 bytes.
od -An -v -tx1 combined128.rom | tr ' ' '\n' | grep -v '^$' > rom128.hex

echo "rom128.hex: $(wc -l < rom128.hex) bytes (expect 32768)"
echo "first byte: $(head -1 rom128.hex) (expect f3 = DI, the reset entry)"
