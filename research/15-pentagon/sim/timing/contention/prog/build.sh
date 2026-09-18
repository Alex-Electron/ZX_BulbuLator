#!/bin/bash
# build.sh - собрать программы стенда контеншена (pasmo, все под org 8000h).
cd "$(dirname "$0")"
for f in im2sweep contrun contrun_rd contrun_out; do
  pasmo --bin $f.asm $f.bin && echo "$f.bin: $(stat -c %s $f.bin) байт" || exit 1
done
