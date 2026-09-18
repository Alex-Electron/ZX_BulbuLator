#!/usr/bin/env python3
"""Прочитать ЭКРАН МАШИНЫ (Спектрума) как текст: зеркало 0x40008000 -> символы по шрифту ПЗУ.

Дополняет osd_ocr.py: тот показывает интерфейс оболочки, этот - что видит сам Спектрум. Вместе они
закрывают вождение платы с хоста целиком.

⚠ Шрифт берётся из rom128.hex со смещения 0x7D00 - это верно, только пока в странице 1 стоит
48 BASIC. После заливки чужого набора ПЗУ шрифт надо брать из файла набора (страница 1 + 0x3D00),
иначе экран прочитается мусором, а вывод будет выглядеть убедительно.

  zxshot.py [метка]     - снять кадр, напечатать 24x32 и сохранить копию в /tmp/<метка>.txt
"""
import subprocess
import sys

HOST = "thinkpad"
XSDB = "/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
TCL = """connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
mrd -force -bin -file /tmp/zxscr.bin 0x40008000 1728
puts ZX_OK
"""


def font():
    import os
    if not os.path.exists("/tmp/rom128.hex"):
        subprocess.run(["scp", "-q", HOST + ":/home/lavrinovich/bulb-v13/research/15-pentagon/sources/build/rom128.hex",
                        "/tmp/rom128.hex"], check=True)
    rom = bytearray()
    for ln in open("/tmp/rom128.hex"):
        for tok in ln.split():
            try:
                rom.append(int(tok, 16))
            except ValueError:
                pass
    tab = {}
    for c in range(32, 128):
        tab.setdefault(bytes(rom[0x7D00 + (c - 32) * 8: 0x7D00 + (c - 32) * 8 + 8]), chr(c))
    return tab


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "zx"
    open("/tmp/_zx.tcl", "w").write(TCL)
    subprocess.run(["scp", "-q", "/tmp/_zx.tcl", HOST + ":/tmp/_zx.tcl"], check=True)
    out = subprocess.run(["ssh", HOST, "timeout 120 %s /tmp/_zx.tcl 2>&1 | tail -3" % XSDB],
                         capture_output=True, text=True).stdout
    if "ZX_OK" not in out:
        sys.exit("кадр не снялся: " + out)
    subprocess.run(["scp", "-q", HOST + ":/tmp/zxscr.bin", "/tmp/zxscr.bin"], check=True)
    scr = open("/tmp/zxscr.bin", "rb").read()
    tab = font()
    # Курсор в ПЗУ-меню и выделение в софте - это АТРИБУТ (инверсия), а не другие пиксели: по одному
    # рисунку знакомест его не видно вовсе. Поэтому строку с необычным атрибутом помечаем слева '>'.
    from collections import Counter
    attr = scr[6144:6912]
    common = Counter(attr).most_common(1)[0][0]
    lines = []
    for y in range(24):
        s = ""
        for x in range(32):
            g = bytes(scr[((y // 8) * 2048) + (r * 256) + ((y % 8) * 32) + x] for r in range(8))
            s += tab.get(g, "#" if any(g) else " ")
        odd = sum(1 for x in range(32) if attr[y * 32 + x] != common)
        lines.append(("> " if odd else "  ") + s.rstrip())
    txt = "\n".join(lines)
    print(txt)
    open("/tmp/%s.txt" % tag, "w").write(txt)


if __name__ == "__main__":
    main()
