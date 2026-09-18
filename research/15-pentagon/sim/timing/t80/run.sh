#!/bin/bash
# Стенд процессора: сборка программ Z80, компиляция xsim, прогон. Запуск: ./run.sh [HIER]
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh
cd "$(dirname "$0")"
SRC=$HOME/bulb-v13/research/15-pentagon/sources
mkdir -p work
for p in prog_qflag prog_int prog_bus prog_dur; do
  pasmo --bin $p.asm work/$p.bin
  python3 bin2hex.py work/$p.bin work/$p.hex
done
cd work
rm -rf xsim.dir *.pb *.log *.jou
xvhdl $SRC/build/zx/src/T80/T80_Pack.vhd $SRC/build/zx/src/T80/T80_Reg.vhd \
      $SRC/build/zx/src/T80/T80_MCode.vhd $SRC/build/zx/src/T80/T80_ALU.vhd \
      $SRC/t80_bulb/T80.vhd $SRC/build/zx/src/T80/T80pa.vhd
xvlog $SRC/build/zx/src/cpu.v
if [ "$1" = "HIER" ]; then xvlog -sv -d HIER ../tb_cpu.sv; else xvlog -sv ../tb_cpu.sv; fi
xelab tb_cpu -s tb_cpu --debug typical -timescale 1ns/1ps
xsim tb_cpu -R > ../run.log 2>&1; tail -3 ../run.log
