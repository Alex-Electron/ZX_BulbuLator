#!/usr/bin/env python3
"""SHOCK ч.2 честным кадром: N снимков cmd 14; в каждом три СОСЕДНИХ кадра.
(а) мерцание: строки, где бордюрные столбцы (x<64, x>=320) различаются между копиями одного снимка;
(б) положение полос: для каждой строки границы цветовых сегментов в левом бордюре, правом бордюре и в бумаге -
    расхождение «где кончается полоса в бордюре и где в бумаге» = шов;
(в) сводка по снимкам."""
import os
import subprocess, sys, hashlib, collections
P=os.environ.get("BULB_TOOLS", os.path.expanduser("~/tools_0902"))
W,H=384,302; PAP0,PAP1=64,320; ROW0,ROW1=55,247
N=int(sys.argv[1]) if len(sys.argv)>1 else 3
tag=sys.argv[2] if len(sys.argv)>2 else "shock"
def rows(raw):
    out=[]
    for y in range(H):
        base=y*(W//2); px=[]
        for i in range(W//2):
            b=raw[base+i]; px.append(b&0xF); px.append(b>>4)
        out.append(px)
    return out
def segs(r,a,b):
    out=[]; s=a
    for x in range(a+1,b):
        if r[x]!=r[x-1]: out.append((s,x-1,r[s])); s=x
    out.append((s,b-1,r[s])); return out
for n in range(1,N+1):
    t="%s%d"%(tag,n)
    r=subprocess.run([sys.executable,P+"/snap14.py",t],capture_output=True,text=True)
    first=r.stdout.strip().split("\n")[0]
    R=[rows(open("/tmp/%s_b%d.bin"%(t,k),"rb").read()) for k in range(3)]
    hs=[hashlib.md5(open("/tmp/%s_b%d.bin"%(t,k),"rb").read()).hexdigest()[:8] for k in range(3)]
    print("=== снимок %d: %s; хеши %s" % (n, first, hs))
    def bsig(r): return (tuple(r[:PAP0]),tuple(r[PAP1:]))
    flick=[y for y in range(H) if len({bsig(R[k][y]) for k in range(3)})>1]
    pflick=[y for y in range(ROW0,ROW1) if len({tuple(R[k][y][PAP0:PAP1]) for k in range(3)})>1]
    print("  строк с РАЗНЫМ бордюром между соседними кадрами: %d %s" % (len(flick), (flick[:8]+["..."]+flick[-4:]) if len(flick)>12 else flick))
    print("  строк с разной бумагой: %d" % len(pflick))
    # где бордюр различается - показать сами различия для первых 3 строк
    for y in flick[:3]:
        print("    стр %3d: лев %s" % (y, [segs(R[k][y],0,PAP0) for k in range(3)]))
    # (б) швы: строки экрана, где в левом бордюре и в начале бумаги цвет полосы одинаков/различен
    seam=collections.Counter()
    for y in range(ROW0,ROW1):
        r=R[0][y]
        lb=r[PAP0-1]; pb=r[PAP0]; rb=r[PAP1-1]; rbb=r[PAP1]
        seam[("лев", lb==pb)]+=1; seam[("прав", rb==rbb)]+=1
    print("  цвет на границе бордюр|бумага совпадает: лев %d/%d, прав %d/%d" % (seam[("лев",True)],ROW1-ROW0,seam[("прав",True)],ROW1-ROW0))
    # (б') позиции переходов в левом бордюре по строкам (копия 0): гистограмма x
    hx=collections.Counter()
    for y in range(H):
        for (s,e,c) in segs(R[0][y],0,PAP0)[1:]: hx[s]+=1
    print("  переходы в левом бордюре по x (копия 0):", sorted(hx.items())[:16])
    hx=collections.Counter()
    for y in range(H):
        for (s,e,c) in segs(R[0][y],PAP1,W)[1:]: hx[s]+=1
    print("  переходы в правом бордюре по x:", sorted(hx.items())[:16])
