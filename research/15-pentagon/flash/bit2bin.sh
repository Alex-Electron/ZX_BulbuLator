#!/bin/bash
# bit2bin.sh <файл.bit> - превратить битстрим в .bit.bin, который оболочка грузит в ПЛИС через PCAP
# (так лежат ядра в 0:/CORES/). Результат кладётся рядом: <файл.bit>.bin.
# Нужен bootgen из Vivado 2023.1 (переменная BOOTGEN или bootgen в PATH).
set -eu
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <bitstream.bit>" >&2; exit 2; }
BIT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
BG="${BOOTGEN:-$(command -v bootgen || echo /tools/Xilinx/Vivado/2023.1/bin/bootgen)}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "all: { $BIT }" > "$TMP/core.bif"
( cd "$TMP" && "$BG" -arch zynq -image core.bif -w -process_bitstream bin ) >/dev/null
ls -l "$BIT.bin"
