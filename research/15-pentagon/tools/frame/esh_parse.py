#!/usr/bin/env python3
"""BORDER-монитор стенда: по кадрам - такт первого OUT от INT (PF-строка = спад INT), и по строкам vCount фаза
перехода бордюра 0->7 (чёрный->белый). Верх (vCount < первой экранной) против экрана."""
import re, sys, collections
log=open(sys.argv[1],encoding="utf-8",errors="replace").read().split("\n")
B=re.compile(r"BORDER (\d+)->(\d+)\s+k=\s*(\d+) T=\s*(\d+)\s+hUla=\s*(\d+) vCount=\s*(\d+)")
INT=re.compile(r"^PF\s+(\d+):.*?\| IORQ: k=\s*(\d+)")   # не годится для T INT; берём отдельный признак ниже
events=[]
for l in log:
    m=B.search(l)
    if m: events.append(tuple(int(x) for x in m.groups()))
print("смен бордюра:",len(events))
if not events: sys.exit()
# кадры: vCount падает => новый кадр
frames=[]; cur=[]; pv=-1
for e in events:
    if e[5]<pv and cur: frames.append(cur); cur=[]
    cur.append(e); pv=e[5]
frames.append(cur)
print("кадров со сменами:",len(frames),"смен по кадрам:",[len(f) for f in frames])
for fi,f in enumerate(frames):
    if len(f)<100: continue
    wh=collections.defaultdict(list)
    for a,b,k,T,h,v in f:
        if b==7 and a==0: wh[v].append(h)
    rows=sorted(wh)
    # первый белый переход в строке
    first={v:min(wh[v]) for v in rows}
    groups=collections.defaultdict(list)
    for v in rows: groups[first[v]].append(v)
    def rng(ys):
        out=[]; s=ys[0]; p=ys[0]
        for y in ys[1:]:
            if y-p>2: out.append((s,p)); s=y
            p=y
        out.append((s,p)); return ",".join("%d..%d"%(u,v) for u,v in out)
    print("кадр %d: первый OUT k=%d T=%d hUla=%d vCount=%d; белых строк %d" % (fi, f[0][2], f[0][3], f[0][4], f[0][5], len(rows)))
    for h in sorted(groups): print("   hUla=%3d  vCount [%s]" % (h, rng(groups[h])))
