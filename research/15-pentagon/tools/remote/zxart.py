#!/usr/bin/env python3
"""Нарисовать кадр Спектрума полурядными блоками - для экранов с ЧУЖИМ шрифтом.

zxshot.py читает текст по шрифту ПЗУ и на своём шрифте софта отдаёт сплошные '#'. Здесь наоборот:
пикселей не распознаём, а показываем как есть, две строки пикселей в один символ. Читать глазами.

  zxart.py [файл.bin] [первая_строка] [последняя_строка]
"""
import sys

f = sys.argv[1] if len(sys.argv) > 1 else "/tmp/zxscr.bin"
y0 = int(sys.argv[2]) if len(sys.argv) > 2 else 0
y1 = int(sys.argv[3]) if len(sys.argv) > 3 else 191
scr = open(f, "rb").read()
rows = []
for y in range(192):
    third, row, cr = y // 64, y % 8, (y % 64) // 8
    line = ""
    for x in range(32):
        b = scr[third * 2048 + row * 256 + cr * 32 + x]
        line += "".join("#" if b & (0x80 >> i) else "." for i in range(8))
    rows.append(line)
out = []
for y in range(y0, min(y1, 190), 2):
    a, b = rows[y], rows[y + 1]
    s = "".join(("█" if a[x] == "#" and b[x] == "#" else "▀" if a[x] == "#"
                 else "▄" if b[x] == "#" else " ") for x in range(256))
    out.append("%3d|%s" % (y, s.rstrip()))
print("\n".join(out))
