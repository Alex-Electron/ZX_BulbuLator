#!/bin/bash
# build.sh - собрать программы Z80 (pasmo). Аргументы: имя варианта и equ-параметры, см. таблицу ниже.
#   ./build.sh                       -> все варианты
# Варианты fbus (--equ): порт, режим и ожидания под машину (калибровка - см. RESULT.md).
set -e
cd "$(dirname "$0")"
python3 fbus_gen.py 48
pasmo --bin ports.asm ports.bin && echo "ports.bin: $(stat -c %s ports.bin) байт"
# имя  PORTHI PORTLO MODE W1 W1F4 W1F1 W2 W2F4 W2F1 BORDER
while read -r name hi lo mode w1 w1f4 w1f1 w2 w2f4 w2f1 border; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue;; esac
  # длина обработчика без циклов = 533 + 9*(W1F1+W2F1) + 4*(W1F4+W2F4) T; PADT добивает её до кратного 4
  padt=$(( (4 - (1 + w1f1 + w2f1) % 4) % 4 ))
  pasmo --bin --equ PORTHI=$hi --equ PORTLO=$lo --equ MODE=$mode --equ W1=$w1 --equ W1F4=$w1f4 --equ W1F1=$w1f1 \
        --equ W2=$w2 --equ W2F4=$w2f4 --equ W2F1=$w2f1 --equ BORDER=$border --equ PADT=$padt fbus.asm fbus_$name.bin
  echo "fbus_$name.bin: $(stat -c %s fbus_$name.bin) байт  ($hi:$lo mode=$mode W1=$w1+$w1f4*4+$w1f1*9 W2=$w2+$w2f4*4+$w2f1*9 PADT=$padt)"
done < variants.txt
