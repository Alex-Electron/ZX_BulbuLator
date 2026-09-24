#!/bin/bash
# run_batch2.sh <список> [PAR] - строки "MACHINE k RUNUS [EXTRA=VAL ...]"; ждёт окончания run_batch.sh, потом гонит.
cd "$(dirname "$0")"
LIST=$1; PAR=${2:-16}
while pgrep -f "run_batch.sh" >/dev/null; do sleep 15; done
while read -r M K R X; do [ -n "$K" ] && python3 gen_prog.py prog/k$K.bin $K; done < "$LIST"
xargs -P "$PAR" -L 1 bash -c 'X=("${@:3}"); ./run_border.sh --wd=${0}_k${1}_${2}_${X[*]// /_} MACHINE=$0 PROG=prog/k$1.bin ORG=8000 RUNUS=$2 QUIET=1 BMON=1 "${X[@]}"' < "$LIST"
