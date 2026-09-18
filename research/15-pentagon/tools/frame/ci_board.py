#!/usr/bin/env python3
"""CONTINT на плате: снять кадр из DDR и вывести переходы цвета бордюра по строкам.
Кадр 384x302 4bpp, полубайт {i,r,g,b}: синий = 1, жёлтый = 6. Столбец -> hUla: x<52 -> 396+x, иначе x-52."""
import os, subprocess, sys
S = os.environ.get("SNAP_DIR", os.path.expanduser("~/bulb-snap"))  # каталог для снимков; переопределяется переменной SNAP_DIR
tag=sys.argv[1] if len(sys.argv)>1 else "contint_board"
# честный кадр: cmd 14 (v0.15.435) через snap14.py; прямое чтение 0x0FF00000 даёт смесь кадров
r=subprocess.run([sys.executable, S+"/snap14.py", tag], capture_output=True, text=True); print(r.stdout.strip())
raw=open("/tmp/zxframe.bin","rb").read(); W,H=384,302
def row(y):
    base=y*(W//2); px=[]
    for i in range(W//2):
        b=raw[base+i]; px.append(b&0xF); px.append(b>>4)
    return px
def x2h(x): return (396+x) if x<52 else (x-52)
tr={}; rows_t=[]
for y in range(H):
    r=row(y)
    left=r[0]; right=r[W-1]
    if left in (1,6) and right in (1,6) and left!=right:
        x=next(i for i in range(W) if r[i]==right)
        tr.setdefault(x,[]).append(y); rows_t.append((y,x))
ft=None
for y in range(H):
    if any(c==0 for c in row(y)[65:321]): ft=y; break
print("ПЛАТА: строк перехода %d; первая строка текста бумаги = %s (бумага ~ %s..%s)" % (len(rows_t), ft, ft, (ft+191) if ft else "-"))
for x in sorted(tr): ys=tr[x]; print("  x=%3d (hUla %3d): строки %s" % (x, x2h(x), ",".join(map(str,ys))))
