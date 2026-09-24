#!/bin/bash
# build.sh - собрать marker.asm под каждый нужный ORG (pasmo, абсолютные адреса внутри программы).
cd "$(dirname "$0")"
for ORG in 8000 5000; do
  sed "s/^\( *\)org .*/\1org 0${ORG}h/" marker.asm > marker_${ORG}.asm.tmp
  pasmo --bin marker_${ORG}.asm.tmp marker_${ORG}.bin && rm marker_${ORG}.asm.tmp
  echo "marker_${ORG}.bin: $(stat -c %s marker_${ORG}.bin) байт"
done
rm -f marker.bin
