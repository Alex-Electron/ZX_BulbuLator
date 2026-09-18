#!/bin/bash
# run.sh - стенд контеншена: копия харнеса tb_zx.sv + cont_instr.svh (см. шапку), xsim.
#   ./run.sh [--build] [--wd=имя] NAME=VAL ...     (аргументы харнеса + аргументы cont_instr.svh)
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null
HERE=$(cd "$(dirname "$0")" && pwd)
HARN=$HERE/../harness
SRC=$HERE/../../../sources
ZX=$SRC/build/zx/src
cd "$HERE"
mkdir -p logs gen
[ -e rom128.hex ] || ln -s ../../../sources/build/rom128.hex rom128.hex

BUILD=0; ARGS=(); TAG=""; WD=""
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --wd=*) WD="${a#--wd=}" ;;
    *=*) ARGS+=("-testplusarg" "$a"); TAG="${TAG}_${a//\//-}" ;;
    *) echo "непонятный аргумент $a"; exit 1 ;;
  esac
done
[ -d xsim.dir/tb_cont ] || BUILD=1

if [ $BUILD = 1 ]; then
  echo "== компиляция (тот же список файлов, что harness/run.sh)"
  [ -e "$HARN/gen/wd1793_xsim.sv" ] || { echo "нет $HARN/gen/wd1793_xsim.sv - сначала harness/run.sh --build"; exit 1; }
  sed -e 's/^module tb_zx;/module tb_cont;/' -e 's/^endmodule/`include "cont_instr.svh"\nendmodule/' "$HARN/tb_zx.sv" > gen/tb_cont.sv
  grep -q 'module tb_cont;' gen/tb_cont.sv && grep -q 'cont_instr.svh' gen/tb_cont.sv || { echo "sed не нашёл якоря в tb_zx.sv"; exit 1; }
  xvhdl "$ZX/T80/T80_Pack.vhd" "$ZX/T80/T80_Reg.vhd" "$ZX/T80/T80_MCode.vhd" "$ZX/T80/T80_ALU.vhd" \
        "$SRC/t80_bulb/T80.vhd" "$ZX/T80/T80pa.vhd" > logs/xvhdl.log
  xvlog "$ZX"/JT49/*.v > logs/xvlog_jt49.log
  xvlog -sv --relax "$ZX/saa1099.sv" "$HARN/gen/wd1793_xsim.sv" > logs/xvlog_sv.log
  xvlog --relax "$SRC/atlas_core/main.v" "$ZX/cpu.v" "$SRC/atlas_core/video.v" "$SRC/turbosound_bulb.v" \
        "$ZX/specdrum.v" "$ZX/audio.v" "$SRC/atlas_core/memory.v" "$ZX/keyboard.v" \
        "$SRC/usd_bulb.v" "$ZX/spi.v" "$SRC/beta_disk.v" "$SRC/nemo_ide.v" "$SRC/kempston_mouse.v" \
        "$SRC/gs_flow.v" "$SRC/mem_zx_bulb.v" > logs/xvlog_core.log
  xvlog -sv -i "$HERE" gen/tb_cont.sv > logs/xvlog_tb.log || { cat logs/xvlog_tb.log; exit 1; }
  xelab tb_cont -s tb_cont --timescale 1ps/1fs > logs/xelab.log || { grep -i error logs/xelab.log; exit 1; }
  grep -q "ERROR" logs/xelab.log && { grep ERROR logs/xelab.log; exit 1; } || true
  echo "== компиляция готова"
fi

LOG="$HERE/logs/run${TAG:-_default}.log"
if [ -n "$WD" ]; then
  mkdir -p "wd/$WD"; rm -rf "wd/$WD/xsim.dir"; cp -r xsim.dir "wd/$WD/xsim.dir"; cd "wd/$WD"
  ln -sfn ../../rom128.hex rom128.hex; ln -sfn ../../prog prog
fi
T0=$(date +%s.%N)
xsim tb_cont -R "${ARGS[@]}" > "$LOG" 2>&1 || true
T1=$(date +%s.%N)
printf "wall: %.1f s\n" "$(echo "$T1 - $T0" | bc)" >> "$LOG"
tail -n 3 "$LOG"
