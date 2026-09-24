#!/bin/bash
# run_tb.sh <tbname> [plusargs...]   — compile + run one of Sergey's testbenches in xsim
# Usage: ./run_tb.sh intgeo MACHINE=0
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null 2>&1
cd /tmp/ep4sim
TB=$1; shift
SNAP="snap_$TB"
LOG="logs/${TB}"
for a in "$@"; do LOG="${LOG}_${a//=/}"; done
LOG="${LOG}.log"

case "$TB" in
  intgeo|iowin|border|bsweep|geo2)
    SRCS="video.v tb_$TB.v" ;;
  intack|qflag)
    SRCS="T80_MCode.v T80_ALU.v T80_Reg.v T80.v T80se.v tb_$TB.v" ;;
  *) echo "unknown tb $TB"; exit 1 ;;
esac

if [ ! -f "xsim.dir/$SNAP/xsimk" ] || [ -n "$FORCE" ]; then
  rm -rf "xsim.dir/work_$TB"
  xvlog -work "work_$TB" -i /tmp/ep4sim $SRCS > "logs/xvlog_$TB.log" 2>&1 || { tail -30 "logs/xvlog_$TB.log"; exit 2; }
  xelab -L "work_$TB" "work_$TB.tb_$TB" -s "$SNAP" --timescale 1ns/1ps > "logs/xelab_$TB.log" 2>&1 || { tail -40 "logs/xelab_$TB.log"; exit 3; }
fi
ARGS=""
for a in "$@"; do ARGS="$ARGS -testplusarg $a"; done
xsim "$SNAP" -R $ARGS 2>&1 | tee "$LOG" | grep -v "^\(Time resolution\|source \|## \|INFO: \[USF\|xsim\|\*\*\|$\)"
