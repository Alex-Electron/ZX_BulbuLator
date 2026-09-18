#!/bin/bash
# sweep.sh <MACHINE> <RUNUS> <PAR> k1 k2 ... - собрать программы и прогнать параллельно.
cd "$(dirname "$0")"
M=$1; RUNUS=$2; PAR=$3; shift 3
for k in "$@"; do python3 gen_prog.py prog/k$k.bin $k; done
printf "%s\n" "$@" | xargs -P $PAR -I{} ./run_border.sh --wd=${M}_k{} MACHINE=$M PROG=prog/k{}.bin ORG=8000 RUNUS=$RUNUS QUIET=1 BMON=1
