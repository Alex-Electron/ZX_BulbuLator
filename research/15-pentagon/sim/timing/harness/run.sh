#!/bin/bash
# run.sh - собрать (при необходимости) и запустить стенд tb_zx в xsim.
#   ./run.sh [--build] [--debug] [--sim-only] NAME=VAL ...
# Примеры:
#   ./run.sh --build MACHINE=48 RUNUS=45000
#   ./run.sh MACHINE=PENT PROG=prog/marker_8000.bin ORG=8000 CHECKMARK=1 RUNUS=100000
#   ./run.sh MACHINE=128 ROM=/path/to/rom.bin RUNUS=5000 PCTRACE=1
# Все NAME=VAL уходят в xsim как -testplusarg (см. шапку tb_zx.sv). Лог - в logs/<метка>.log.
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../../sources
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
    --wd=*) WD="${a#--wd=}" ;;          # отдельный рабочий каталог wd/<имя> - для ПАРАЛЛЕЛЬНЫХ прогонов
    *=*) ARGS+=("-testplusarg" "$a"); TAG="${TAG}_${a//\//-}" ;;
    *) echo "непонятный аргумент $a"; exit 1 ;;
  esac
done
[ -d xsim.dir/tb_zx ] || BUILD=1
[ $SIMONLY = 1 ] && BUILD=0

if [ $BUILD = 1 ]; then
  echo "== компиляция (список файлов = build.tcl, цель Atlas, без топа/HDMI/clock_zx)"
  # T80: пять апстримных файлов + НАШ форк T80.vhd (апстримный zx/src/T80/T80.vhd не читать!)
  xvhdl "$ZX/T80/T80_Pack.vhd" "$ZX/T80/T80_Reg.vhd" "$ZX/T80/T80_MCode.vhd" "$ZX/T80/T80_ALU.vhd" \
        "$SRC/t80_bulb/T80.vhd" "$ZX/T80/T80pa.vhd" > logs/xvhdl.log
  xvlog "$ZX"/JT49/*.v > logs/xvlog_jt49.log
  # --relax ОБЯЗАТЕЛЕН: wd1793.sv использует q/A_DATA до объявления (VRFC 10-3380), а main.v
  # объявляет svc_nmi/nemo_dev_slave/nemo_drq_live ПОСЛЕ первого использования в портах (VRFC 10-2938).
  # Синтез Vivado это ест молча, xvlog без --relax отказывается. Исходники не трогаем.
  # wd1793.sv: `reg scan_active` объявлен у строки ~1055, а используется с ~104 и ВНУТРИ generate
  # (строка ~129): xelab не может разрешить неявное genblk1.scan_active. Копия для xsim генерируется
  # из ЖИВОГО исходника при каждой сборке с одним изменением - объявление перенесено вверх.
  # Файл gen/wd1793_xsim.sv не править и не класть в сборку Vivado.
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
  xvlog -sv tb_zx.sv > logs/xvlog_tb.log
  # --timescale: у исходников машины нет `timescale, у стенда есть (1ps/1fs) - xelab иначе отказывается
  xelab tb_zx -s tb_zx --timescale 1ps/1fs $DEBUG > logs/xelab.log
  grep -c "ERROR" logs/xelab.log >/dev/null && { echo "ошибки в logs/xelab.log"; grep ERROR logs/xelab.log; exit 1; } || true
  echo "== компиляция готова"
fi

LOG="$HERE/logs/run${TAG:-_default}.log"
if [ -n "$WD" ]; then
  # xsim пишет служебные файлы в cwd; два одновременных прогона в одном каталоге мешают друг другу.
  # xsim.dir КОПИРУЕТСЯ, а не линкуется: xsim пишет свою команду запуска (с плюс-аргументами!) в
  # xsim.dir/tb_zx/xsim_script.tcl и потом её же исполняет - общий снапшот у параллельных прогонов
  # подменял друг другу аргументы (оплачено перепутанными логами 28.08).
  mkdir -p "wd/$WD"; rm -rf "wd/$WD/xsim.dir"; cp -r xsim.dir "wd/$WD/xsim.dir"; cd "wd/$WD"
  ln -sfn ../../rom128.hex rom128.hex; ln -sfn ../../prog prog
fi
T0=$(date +%s.%N)
xsim tb_zx -R "${ARGS[@]}" | tee "$LOG"
T1=$(date +%s.%N)
printf "wall: %.1f s\n" "$(echo "$T1 - $T0" | bc)" | tee -a "$LOG"
