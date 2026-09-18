#!/usr/bin/env python3
"""Прочитать ТЕКСТ с экрана ZX по зеркалу (6912 Б) + шрифт из файла ПЗУ.
   zxtext.py <зеркало.bin> <файл_ПЗУ> <смещение_шрифта_hex>"""
import sys
scr = open(sys.argv[1], 'rb').read()
rom = open(sys.argv[2], 'rb').read()
off = int(sys.argv[3], 16)
font = {}
for c in range(32, 128):
    g = rom[off + (c - 32) * 8: off + (c - 32) * 8 + 8]
    font.setdefault(bytes(g), chr(c))
rows = []
for cy in range(24):
    line = ''
    for cx in range(32):
        cell = bytes(scr[((cy & 0x18) << 8) | ((cy & 7) << 5) | (y << 8) | cx] for y in range(8))
        line += font.get(cell, ' ' if cell == b'\0' * 8 else '?')
    rows.append(line.rstrip())
print('\n'.join('%2d|%s' % (i, r) for i, r in enumerate(rows) if r))
