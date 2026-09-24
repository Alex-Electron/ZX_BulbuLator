#!/bin/bash
# run.sh - собрать (при необходимости) и запустить стенд tb_intgeo в xsim.
#   ./run.sh [--build] [--sim-only] [--wd=<имя>] NAME=VAL ...
# Список исходников = harness/run.sh (build.tcl, цель Atlas); отличие одно: вместо tb_zx.sv читается
# наш tb_intgeo.sv, а gen/wd1793_xsim.sv берётся ГОТОВЫЙ из харнеса (его делает harness/run.sh).
# Плюс-аргументы харнеса + intgeo: HCINIT=<n> (начальное hc растра), ISRPATCH=<hex> (JP по 0x0038).
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null
HERE=$(cd "$(dirname "$0")" && pwd)
HAR=$HERE/../harness
SRC=$HERE/../../../sources
ZX=$SRC/build/zx/src
cd "$HERE"
mkdir -p logs
[ -e rom128.hex ] || ln -s ../../../sources/build/rom128.hex rom128.hex
[ -e gen ] || ln -s ../harness/gen gen

BUILD=0; SIMONLY=0; ARGS=(); TAG=""; WD=""
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --sim-only) SIMONLY=1 ;;
    --wd=*) WD="${a#--wd=}" ;;
    *=*) ARGS+=("-testplusarg" "$a"); TAG="${TAG}_${a//\//-}" ;;
    *) echo "непонятный аргумент $a"; exit 1 ;;
  esac
done
[ -d xsim.dir/tb_intgeo ] || BUILD=1
[ $SIMONLY = 1 ] && BUILD=0

if [ $BUILD = 1 ]; then
  [ -f "$HAR/gen/wd1793_xsim.sv" ] || { echo "нет $HAR/gen/wd1793_xsim.sv - сначала harness/run.sh --build"; exit 1; }
  echo "== компиляция tb_intgeo (список файлов = harness/run.sh)"
  xvhdl "$ZX/T80/T80_Pack.vhd" "$ZX/T80/T80_Reg.vhd" "$ZX/T80/T80_MCode.vhd" "$ZX/T80/T80_ALU.vhd" \
        "$SRC/t80_bulb/T80.vhd" "$ZX/T80/T80pa.vhd" > logs/xvhdl.log
  xvlog "$ZX"/JT49/*.v > logs/xvlog_jt49.log
  xvlog -sv --relax "$ZX/saa1099.sv" "$HAR/gen/wd1793_xsim.sv" > logs/xvlog_sv.log
  xvlog --relax "$SRC/atlas_core/main.v" "$ZX/cpu.v" "$SRC/atlas_core/video.v" "$SRC/turbosound_bulb.v" \
        "$ZX/specdrum.v" "$ZX/audio.v" "$SRC/atlas_core/memory.v" "$ZX/keyboard.v" \
        "$SRC/usd_bulb.v" "$ZX/spi.v" "$SRC/beta_disk.v" "$SRC/nemo_ide.v" "$SRC/kempston_mouse.v" \
        "$SRC/gs_flow.v" "$SRC/mem_zx_bulb.v" > logs/xvlog_core.log
  xvlog -sv tb_intgeo.sv > logs/xvlog_tb.log
  xelab tb_intgeo -s tb_intgeo --timescale 1ps/1fs > logs/xelab.log
  grep -c "ERROR" logs/xelab.log >/dev/null && { echo "ошибки в logs/xelab.log"; grep ERROR logs/xelab.log; exit 1; } || true
  echo "== компиляция готова"
fi

LOG="$HERE/logs/run${TAG:-_default}.log"
if [ -n "$WD" ]; then
  mkdir -p "wd/$WD"; rm -rf "wd/$WD/xsim.dir"; cp -r xsim.dir "wd/$WD/xsim.dir"; cd "wd/$WD"
  ln -sfn ../../rom128.hex rom128.hex; ln -sfn ../../prog prog
fi
T0=$(date +%s.%N)
xsim tb_intgeo -R "${ARGS[@]}" | tee "$LOG"
T1=$(date +%s.%N)
printf "wall: %.1f s\n" "$(echo "$T1 - $T0" | bc)" | tee -a "$LOG"
