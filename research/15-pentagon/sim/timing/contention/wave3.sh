#!/bin/bash
# wave3.sh - (d) повтор фазы cpuck после сброса; kacc-минимум при перевёрнутой чётности hc; свободные фазы hc
cd "$(dirname "$0")"
R=./run.sh
H="PROG=../../../harness/prog/marker_5000.bin ORG=5000 FRAMESTAT=1 QUIET=1"
$R --wd=g1 MACHINE=48 $H WINLINE=100 CPUCKINIT=1 RUNUS=45000 &
$R --wd=g2 MACHINE=48 PROG=prog/im2sweep.bin ORG=8000 ISR=1 CHAIN=8 ACCLOG=1 QUIET=1 INSTR=RD PADT=14282 SWEEP=4 NOCOMP=1 HCINIT=1 RUNUS=100000 &
$R --wd=g3 MACHINE=48 PROG=prog/im2sweep.bin ORG=8000 ISR=1 CHAIN=8 ACCLOG=1 QUIET=1 INSTR=RD PADT=14282 SWEEP=4 NOCOMP=1 RUNUS=100000 &
wait
echo "WAVE3 DONE"
