#!/bin/bash
# prog_build.sh - собрать cross.asm под IM 2 (cross_im2.bin) и IM 1 (cross_im1.bin), ORG 8000h.
cd "$(dirname "$0")"
for M in 2 1; do
  sed "s/^IMODE   equ .*/IMODE   equ $M/" cross.asm > cross_im$M.asm.tmp
  pasmo --bin cross_im$M.asm.tmp cross_im$M.bin && rm cross_im$M.asm.tmp
  echo "cross_im$M.bin: $(stat -c %s cross_im$M.bin) байт"
done
