#!/usr/bin/env python3
"""esh1 честным кадром: cmd 14 -> три копии -> для КАЖДОЙ копии начало широкой (>=300 px) полосы по строкам.
Целые копии = совпавшие хеши; рваная показывается отдельно. Вопрос: верх (строки до бумаги) и экран на одном x?"""
import os, subprocess, sys, hashlib
S = os.environ.get("SNAP_DIR", os.path.expanduser("~/bulb-snap"))  # каталог для снимков; переопределяется переменной SNAP_DIR
W,H=384,302
tag=sys.argv[1] if len(sys.argv)>1 else "esh"
r=subprocess.run([sys.executable,S+"/snap14.py",tag],capture_output=True,text=True); print(r.stdout.strip().split("\n")[0])
def row(raw,y):
    base=y*(W//2); px=[]
    for i in range(W//2):
        b=raw[base+i]; px.append(b&0xF); px.append(b>>4)
    return px
for k in range(3):
    raw=open("/tmp/%s_b%d.bin"%(tag,k),"rb").read()
    seen={}
    for y in range(H):
        r=row(raw,y); nz=[x for x,c in enumerate(r) if c!=0]
        if not nz: continue
        a,b=nz[0],nz[-1]
        if b-a+1<300: continue
        seen.setdefault(a,[]).append(y)
    parts=[]
    for a in sorted(seen):
        ys=seen[a]
        # разбить на непрерывные диапазоны строк (шаг 2 у esh1)
        rng=[]; s=ys[0]; p=ys[0]
        for y in ys[1:]:
            if y-p>2: rng.append((s,p)); s=y
            p=y
        rng.append((s,p))
        parts.append("x=%d [%s]" % (a, ",".join("%d..%d"%(u,v) for u,v in rng)))
    print("  копия %d (%s): %s" % (k, hashlib.md5(raw).hexdigest()[:8], " | ".join(parts)))
