#!/usr/bin/env python3
"""make_tb.py - делает tb_border.sv из ../harness/tb_zx.sv: переименовывает модуль и вставляет монитор
бордюра перед endmodule. Харнес не правится. Запускать из каталога border/."""
import re, sys
src = open('../harness/tb_zx.sv', encoding='utf-8').read()
assert src.count('module tb_zx;') == 1
src = src.replace('module tb_zx;', 'module tb_border;   // копия harness/tb_zx.sv + монитор бордюра (см. bm_monitor.sv)')
mon = open('bm_monitor.sv', encoding='utf-8').read()
idx = src.rfind('endmodule')
assert idx > 0
out = src[:idx] + mon + '\n' + src[idx:]
open('tb_border.sv', 'w', encoding='utf-8').write(out)
print('tb_border.sv:', len(out.splitlines()), 'строк')
