#!/bin/bash
# run_batch.sh <список> [PAR] - строки вида "MACHINE k RUNUS"; собирает программы и гонит прогоны параллельно.
cd "$(dirname "$0")"
LIST=$1; PAR=${2:-16}
while read -r M K R; do [ -n "$K" ] && python3 gen_prog.py prog/k$K.bin $K; done < "$LIST"
xargs -P "$PAR" -L 1 bash -c './run_border.sh --wd=${0}_k${1}_${2} MACHINE=$0 PROG=prog/k$1.bin ORG=8000 RUNUS=$2 QUIET=1 BMON=1' < "$LIST"
