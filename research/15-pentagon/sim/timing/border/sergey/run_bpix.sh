#!/bin/bash
# run_bpix.sh [plusargs] - собрать (при отсутствии снапшота) и прогнать tb_bpix на нетронутом /tmp/ep4/video.v
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd "$(dirname "$0")"
mkdir -p logs
LOG=logs/bpix; for a in "$@"; do LOG="${LOG}_${a//=/}"; done; LOG="$LOG.log"
if [ ! -f xsim.dir/snap_bpix/xsimk ] || [ -n "$FORCE" ]; then
  xvlog -i /tmp/ep4 /tmp/ep4/video.v tb_bpix.v > logs/xvlog.log 2>&1 || { tail -20 logs/xvlog.log; exit 2; }
  xelab work.tb_bpix -s snap_bpix --timescale 1ns/1ps > logs/xelab.log 2>&1 || { tail -30 logs/xelab.log; exit 3; }
fi
ARGS=""; for a in "$@"; do ARGS="$ARGS -testplusarg $a"; done
xsim snap_bpix -R $ARGS > "$LOG" 2>&1
grep -E "^(MACHINE|RAW|E1|PAPER|N=|DONE|TIMED)" "$LOG"
