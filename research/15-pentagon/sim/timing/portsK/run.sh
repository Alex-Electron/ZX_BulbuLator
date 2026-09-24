#!/bin/bash
# run.sh - собрать (при необходимости) и запустить стенд tb_ports (наследник harness/tb_zx.sv) в xsim.
#   ./run.sh [--build] [--debug] [--sim-only] [--wd=<имя>] NAME=VAL ...
# Список файлов и порядок компиляции - как в harness/run.sh (build.tcl, цель Atlas), отличие одно:
# стенд tb_ports.sv из этого каталога. Лог - logs/run_<аргументы>.log.
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../../sources_k
ZX=$SRC/build/zx/src
cd "$HERE"
mkdir -p logs
[ -e rom128.hex ] || ln -s ../../../sources/build/rom128.hex rom128.hex

BUILD=0; DEBUG=""; SIMONLY=0; ARGS=(); TAG=""; WD=""
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --debug) DEBUG="--debug typical"; BUILD=1 ;;
    --sim-only) SIMONLY=1 ;;
    --wd=*) WD="${a#--wd=}" ;;
    *=*) ARGS+=("-testplusarg" "$a"); TAG="${TAG}_${a//\//-}" ;;
    *) echo "непонятный аргумент $a"; exit 1 ;;
  esac
done
[ -d xsim.dir/tb_ports ] || BUILD=1
# 🥇 ПЕРЕСОБИРАТЬ, ЕСЛИ ИСХОДНИК НОВЕЕ СНИМКА. Раньше условие было только "снимка нет вообще",
# и после ЛЮБОЙ правки RTL стенд молча гонял СТАРЫЙ образ. Оплачено 10.09: правка B0180 (своя фаза
# штрафа у выборки команды) "не дала эффекта" - на самом деле она просто не была скомпилирована,
# и целый свип ручки ушёл в мусор. Признак этой мины: ручка, доходящая до симулятора
# (видно в командной строке -testplusarg), не меняет НИ ОДНОГО числа даже на крайних значениях.
if [ $BUILD = 0 ] && [ -f xsim.dir/tb_ports/xsimk ]; then
  for f in "$SRC"/atlas_core/*.v "$SRC"/*.v "$SRC"/t80_bulb/*.vhd "$ZX"/T80/*.vhd "$ZX"/cpu.v tb_ports.sv; do
    [ -e "$f" ] || continue
    if [ "$f" -nt xsim.dir/tb_ports/xsimk ]; then
      echo "== исходник новее снимка ($f) -> ПЕРЕСБОРКА"; BUILD=1; break
    fi
  done
fi
[ $SIMONLY = 1 ] && BUILD=0

if [ $BUILD = 1 ]; then
  echo "== компиляция (список файлов = harness/run.sh = build.tcl, цель Atlas)"
  xvhdl "$ZX/T80/T80_Pack.vhd" "$ZX/T80/T80_Reg.vhd" "$ZX/T80/T80_MCode.vhd" "$ZX/T80/T80_ALU.vhd" \
        "$SRC/t80_bulb/T80.vhd" "$ZX/T80/T80pa.vhd" > logs/xvhdl.log
  xvlog "$ZX"/JT49/*.v > logs/xvlog_jt49.log
  # wd1793.sv: та же генерация копии для xsim, что в harness/run.sh (см. гочу 2 в harness/README.md)
  mkdir -p gen
  python3 - "$SRC/wd1793.sv" gen/wd1793_xsim.sv <<'PY'
import sys, re
src = open(sys.argv[1]).read()
m = re.findall(r'^reg\s+scan_active\s*=\s*0;\s*$', src, re.M)
assert len(m) == 1, 'wd1793.sv: объявление scan_active не найдено ровно один раз - править run.sh'
src = re.sub(r'^reg\s+scan_active\s*=\s*0;\s*$', '// (объявление scan_active перенесено вверх для xsim - см. run.sh)', src, flags=re.M)
anchor = 'assign dout      = q;'
assert src.count(anchor) == 1, 'wd1793.sv: якорь assign dout не найден - править run.sh'
src = src.replace(anchor, 'reg scan_active = 0;   // перенесено из хвоста файла для xsim (см. run.sh)\n' + anchor)
open(sys.argv[2], 'w').write('// СГЕНЕРИРОВАНО run.sh из sources/wd1793.sv - НЕ ПРАВИТЬ, НЕ КЛАСТЬ В СБОРКУ VIVADO\n' + src)
PY
  xvlog -sv --relax "$ZX/saa1099.sv" gen/wd1793_xsim.sv > logs/xvlog_sv.log
  xvlog --relax "$SRC/atlas_core/main.v" "$ZX/cpu.v" "$SRC/atlas_core/video.v" "$SRC/turbosound_bulb.v" \
        "$ZX/specdrum.v" "$ZX/audio.v" "$SRC/atlas_core/memory.v" "$ZX/keyboard.v" \
        "$SRC/usd_bulb.v" "$ZX/spi.v" "$SRC/beta_disk.v" "$SRC/nemo_ide.v" "$SRC/kempston_mouse.v" \
        "$SRC/gs_flow.v" "$SRC/mem_zx_bulb.v" > logs/xvlog_core.log
  xvlog -sv tb_ports.sv > logs/xvlog_tb.log
  xelab tb_ports -s tb_ports --timescale 1ps/1fs $DEBUG > logs/xelab.log
  grep -c "ERROR" logs/xelab.log >/dev/null && { echo "ошибки в logs/xelab.log"; grep ERROR logs/xelab.log; exit 1; } || true
  echo "== компиляция готова"
fi

LOG="$HERE/logs/run${TAG:-_default}.log"
if [ -n "$WD" ]; then
  mkdir -p "wd/$WD"; rm -rf "wd/$WD/xsim.dir"; cp -r xsim.dir "wd/$WD/xsim.dir"; cd "wd/$WD"
  ln -sfn ../../rom128.hex rom128.hex; ln -sfn ../../prog prog
fi
T0=$(date +%s.%N)
xsim tb_ports -R "${ARGS[@]}" | tee "$LOG"
T1=$(date +%s.%N)
printf "wall: %.1f s\n" "$(echo "$T1 - $T0" | bc)" | tee -a "$LOG"
