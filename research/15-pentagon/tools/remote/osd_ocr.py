#!/usr/bin/env python3
"""Прочитать ЭКРАН ОБОЛОЧКИ (навигатор, меню, диалоги) с платы как текст.

Зачем. Экран машины виден по зеркалу 0x40008000, а вот интерфейс оболочки до сих пор был слепой
зоной: без него любое вождение меню с хоста - тыканье наугад. Канва оболочки лежит в DDR по
0x0F800000, это 640x400 слов ARGB, ровно 80x25 клеток шрифта 8x16 (vga866.h, CP866). Значит её
можно снять по JTAG (~15 с на кадр) и распознать по тому же шрифту, которым она нарисована.

Распознавание точное, а не приблизительное: для каждой клетки берём два самых частых цвета
(фон и текст), строим битовую маску "пиксель != фон" и ищем ТОЧНОЕ совпадение с глифом. Совпадения
нет - печатаем '?', заливка одним цветом - пробел. Инверсия (курсор, выделение) ловится тем, что
маска строится от ПРЕОБЛАДАЮЩЕГО цвета, поэтому выделенная строка читается так же, как обычная.

Запуск: osd_ocr.py <канва.bin> [vga866.h]
"""
import sys
from collections import Counter

CP866 = (
    "                                "                                # 0x00-0x1F служебные
    " !\"#$%&'()*+,-./0123456789:;<=>?"
    "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
    "`abcdefghijklmnopqrstuvwxyz{|}~ "
    "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    "абвгдежзийклмноп"
    "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
    "└┴┬├─┼╞╟╚╔╩╦╠═╬╧"
    "╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
    "рстуфхцчшщъыьэюя"
    "Ёёc:$-·√№¤■ "
)


def load_font(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    body = txt[txt.index("{", txt.index("vga866")):]
    rows, cur = [], []
    num = ""
    depth = 0
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 2:
                cur = []
        elif ch == "}":
            if num:
                cur.append(int(num)); num = ""
            if depth == 2:
                rows.append(bytes(cur[:16]))
            depth -= 1
            if depth == 0:
                break
        elif ch.isdigit() or (ch == "x" and num) or (num.startswith("0x") and ch.lower() in "abcdef"):
            num += ch
        elif ch == ",":
            if num:
                cur.append(int(num, 0)); num = ""
        elif ch in " \n\t\r":
            if num and not num.startswith("0"):
                pass
    return rows


def main():
    canvas = open(sys.argv[1], "rb").read()
    font = load_font(sys.argv[2] if len(sys.argv) > 2 else "/tmp/vga866.h")
    if len(font) < 256:
        sys.exit("шрифт разобран не полностью: %d глифов" % len(font))
    # глиф -> символ; первый выигрывает, чтобы пустые слоты не перебивали пробел
    table = {}
    for code, g in enumerate(font):
        ch = CP866[code] if code < len(CP866) else "?"
        table.setdefault(bytes(g), ch)

    W = 640
    px = memoryview(canvas).cast("I")
    rows, bgs = [], []
    for cy in range(25):
        line, rowbg = [], []
        for cx in range(80):
            cell = [px[(cy * 16 + r) * W + cx * 8 + c] for r in range(16) for c in range(8)]
            cnt = Counter(cell)
            bg = cnt.most_common(1)[0][0]
            rowbg.append(bg)
            if len(cnt) == 1:
                line.append(" ")
                continue
            bits = bytes(
                sum(0x80 >> c for c in range(8) if cell[r * 8 + c] != bg) for r in range(16)
            )
            line.append(table.get(bits, "?"))
        rows.append("".join(line))
        bgs.append(rowbg)
    # Курсор/выделение шрифтом не видны - они цвет ФОНА. Помечаем слева '>' строку, у которой фон
    # массово отличается от преобладающего по всей канве: без этого «где стоит курсор» не прочитать.
    common = Counter(b for r in bgs for b in r).most_common(1)[0][0]
    out = []
    for cy in range(25):
        odd = sum(1 for b in bgs[cy] if b != common)
        out.append(("> " if odd >= 20 else "  ") + rows[cy].rstrip())
    print("\n".join(out))


if __name__ == "__main__":
    main()
