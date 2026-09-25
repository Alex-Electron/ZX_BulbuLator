#!/bin/bash
# build.sh - собрать PENTTEST: pasmo (--alocal), затем лента penttest.tap.
set -e
cd "$(dirname "$0")"
pasmo --alocal --bin ft6000.asm ft6000.bin
pasmo --alocal --bin ftc000.asm ftc000.bin
pasmo --alocal --bin penttest.asm penttest.bin
python3 mktap.py penttest.bin penttest.tap
# растровые тесты (stime/btime с перебором T): одна программа, две ленты с разным входом
pasmo --alocal --bin rastime.asm rastime.bin
python3 mktap.py rastime.bin rastime.tap rastime 32768 "RASTIME - stime sweep; timing core by Jan Bobrowski (GPL)"
python3 mktap.py rastime.bin rasbord.tap rasbord 32771 "RASBORD - btime sweep; timing core by Jan Bobrowski (GPL)"
# счётчик кадров для замера частоты с хоста (host/frate.py)
pasmo --bin framerate/fcount.asm framerate/fcount.bin
python3 mktap.py framerate/fcount.bin framerate/fcount.tap fcount 32768 "FCOUNT - frame counter for host clock measurement"
