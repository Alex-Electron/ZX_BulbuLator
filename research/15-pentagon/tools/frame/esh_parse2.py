#!/usr/bin/env python3
import re, sys, collections
B=re.compile(r"BORDER (\d+)->(\d+)\s+k=\s*(\d+) T=\s*(\d+)\s+hUla=\s*(\d+) vCount=\s*(\d+)")
ev=[tuple(int(x) for x in m.groups()) for l in open(sys.argv[1],errors="replace") for m in [B.search(l)] if m]
# кадры по T (такты от INT): T падает => новый INT
frames=[]; cur=[]; pT=-1
for e in ev:
    if e[3]<pT and cur: frames.append(cur); cur=[]
    cur.append(e); pT=e[3]
frames.append(cur)
print("смен:",len(ev),"кадров (по INT):",len(frames),"смен по кадрам:",[len(f) for f in frames])
for fi,f in enumerate(frames):
    print("--- кадр %d: T первой смены %d (vCount %d hUla %d), последней %d" % (fi, f[0][3], f[0][5], f[0][4], f[-1][3]))
    rows=collections.defaultdict(list)
    for a,b,k,T,h,v in f: rows[v].append("%d>%d@%d"%(a,b,h))
    # порядок строк ULA внутри кадра: 248..311, потом 0..247 (INT на 248?) - печатаем в порядке появления
    order=[]
    for a,b,k,T,h,v in f:
        if v not in order: order.append(v)
    pick=[v for v in order if (v>=280 or v<=12 or 186<=v<=210)]
    for v in pick: print("   vCount %3d: %s" % (v, " ".join(rows[v])))
    # статистика по фазе первого 0>7 в строке: верх (v>=248) против экрана (v<192)
    top=collections.Counter(); pap=collections.Counter(); bot=collections.Counter()
    for a,b,k,T,h,v in f:
        if a==0 and b==7:
            (top if v>=248 else pap if v<192 else bot)[h]+=1
    print("   0>7 верх(v>=248):",sorted(top.items())," экран:",sorted(pap.items())," низ:",sorted(bot.items()))
    top=collections.Counter(); pap=collections.Counter(); bot=collections.Counter()
    for a,b,k,T,h,v in f:
        if a==7 and b==0:
            (top if v>=248 else pap if v<192 else bot)[h]+=1
    print("   7>0 верх:",sorted(top.items())," экран:",sorted(pap.items())," низ:",sorted(bot.items()))
