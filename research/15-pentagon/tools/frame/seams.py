#!/usr/bin/env python3
"""Признак правильности картинки, НЕ зависящий от фазы анимации.

Снят с эталона (Fuse 1.6, точный 48K, снапшот SHOCK часть 2): в каждой строке экрана левый бордюр
одноцветен, правый одноцветен, и цвета РАВНЫ - это одна горизонтальная полоса. В верхнем и нижнем
бордюре строка одноцветна во всю ширину. Любое отклонение = разрыв или лесенка.

  seams.py fuse <png> <x0> <y0>        эталон Fuse: окно 320x240, бумага с (32,24)
  seams.py ours <bin> [px0] [px1]      наш кадр 384x302 4bpp; бумага по умолчанию 12..267
"""
import sys, collections
sys.path.insert(0, __file__.rsplit("/",1)[0])
import pngread

ZXPAL = {(0,0,0):0,(0,0,0xC0):1,(0xC0,0,0):2,(0xC0,0,0xC0):3,(0,0xC0,0):4,(0,0xC0,0xC0):5,
         (0xC0,0xC0,0):6,(0xC0,0xC0,0xC0):7,(0,0,0xFF):9,(0xFF,0,0):10,(0xFF,0,0xFF):11,
         (0,0xFF,0):12,(0,0xFF,0xFF):13,(0xFF,0xFF,0):14,(0xFF,0xFF,0xFF):15}
def nearest(rgb):
    if rgb in ZXPAL: return ZXPAL[rgb]
    return min(ZXPAL.items(), key=lambda kv: sum((a-b)**2 for a,b in zip(kv[0], rgb)))[1]

def nruns(seq):
    n = 1
    for i in range(1, len(seq)):
        if seq[i] != seq[i-1]: n += 1
    return n

def report(lines, pl, pr, pt, pb, width):
    """pl,pr - первый и последний столбец БУМАГИ; pt,pb - первая и последняя строка бумаги."""
    bad_l = bad_r = bad_eq = bad_edge = 0
    rows_l = collections.Counter(); rows_r = collections.Counter()
    for y in range(pt, pb+1):
        L = lines[y]
        left  = L[0:pl]
        right = L[pr+1:width]
        rows_l[nruns(left)] += 1; rows_r[nruns(right)] += 1
        if nruns(left)  != 1: bad_l += 1
        if nruns(right) != 1: bad_r += 1
        if nruns(left) == 1 and nruns(right) == 1 and left[0] != right[0]: bad_eq += 1
    for y in list(range(0, pt)) + list(range(pb+1, len(lines))):
        if nruns(lines[y][0:width]) != 1: bad_edge += 1
    print("строк экрана %d, бумага x %d..%d, строки %d..%d, ширина учёта %d" % (pb-pt+1, pl, pr, pt, pb, width))
    print("  ЛЕВЫЙ бордюр не одноцветен:  %4d строк   (прогонов -> строк: %s)" % (bad_l, dict(sorted(rows_l.items()))))
    print("  ПРАВЫЙ бордюр не одноцветен: %4d строк   (прогонов -> строк: %s)" % (bad_r, dict(sorted(rows_r.items()))))
    print("  цвет левого != цвет правого:  %4d строк" % bad_eq)
    print("  верх/низ бордюра не одноцветны во всю ширину: %d строк из %d" % (bad_edge, len(lines)-(pb-pt+1)))

def main():
    if sys.argv[1] == "fuse":
        png, x0, y0 = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        w, h, rows = pngread.read(png)
        lines = [[nearest((rows[y][3*x], rows[y][3*x+1], rows[y][3*x+2])) for x in range(x0, x0+320)]
                 for y in range(y0, y0+240)]
        report(lines, 32, 287, 24, 215, 320)
    else:
        raw = open(sys.argv[2], "rb").read()
        pl = int(sys.argv[3]) if len(sys.argv) > 3 else 12
        pr = int(sys.argv[4]) if len(sys.argv) > 4 else 267
        W, H = 384, 302
        lines = []
        for y in range(H):
            base = y*(W//2); px = []
            for i in range(W//2):
                b = raw[base+i]; px.append(b & 0xF); px.append(b >> 4)
            lines.append(px)
        # видимая ширина строки: отбросить чёрный хвост кадра (он не бордюр, а вне строки)
        vis = W
        while vis > pr+2 and all(lines[y][vis-1] == 0 for y in range(H)): vis -= 1
        # строки бумаги: там, где в диапазоне бумаги больше одного цвета по вертикали
        pt, pb = None, None
        for y in range(H):
            seg = lines[y][pl:pr+1]
            if nruns(seg) > 1:
                if pt is None: pt = y
                pb = y
        print("видимая ширина строки %d, строки бумаги найдены как %s..%s" % (vis, pt, pb))
        if pt is None: sys.exit("бумага не найдена - кадр однородный, машина не в этой части демки")
        report(lines, pl, pr, pt, pb, vis)
main()
