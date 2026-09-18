#!/bin/bash
# wave4.sh - минимум kacc для обеих чётностей hc: фаза решётки HALT меняется длиной сброса (RESETUS, 1 мкс = 3.5 T)
cd "$(dirname "$0")"
R=./run.sh
S="MACHINE=48 PROG=prog/im2sweep.bin ORG=8000 ISR=1 CHAIN=8 ACCLOG=1 QUIET=1 INSTR=RD PADT=14282 SWEEP=1 NOCOMP=1 RUNUS=40000"
for r in 6 7 8 9; do
  $R --wd=k$r $S RESETUS=$r &
  $R --wd=kh$r $S RESETUS=$r HCINIT=1 &
done
wait
echo "WAVE4 DONE"
