#!/bin/bash
set -e
source /tools/Xilinx/Vivado/2023.1/settings64.sh >/dev/null
SRC=$HOME/bulb-v13/research/15-pentagon/sources; ZX=$SRC/build/zx/src
cd "$(dirname "$0")"
xvhdl "$ZX/T80/T80_Pack.vhd" "$ZX/T80/T80_Reg.vhd" "$ZX/T80/T80_MCode.vhd" "$ZX/T80/T80_ALU.vhd" \
      "$SRC/t80_bulb/T80.vhd" "$ZX/T80/T80pa.vhd" > xvhdl.log
xvlog -sv "$ZX/cpu.v" tb_intack.sv > xvlog.log
xelab -timescale 1ns/1ps -debug typical tb_intack -s tb_intack > xelab.log
xsim tb_intack -R | grep -v "^\$\|^INFO\|^Time res\|^run\|^exit\|^source"
