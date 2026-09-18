#!/usr/bin/env python3
"""Расписание OUT по коду (чистые такты) против событий BORDER сима за кадр: отклонение T_sim - T_code по ходу кадра."""
import re, sys
log=sys.argv[1]; frame_no=int(sys.argv[2]) if len(sys.argv)>2 else 1
ins={int(l[:4],16):l[5:].strip() for l in open("/tmp/esh1_dis.txt")}
def T(m):
    if m.startswith("OUT (C)"): return 12
    if m=="NOP": return 4
    if m.startswith("LD "):
        a=m[3:].split(",")
        if a[0] in ("BC","DE","HL","SP"): return 10
        if a[0]=="(HL)": return 7
        if a[1] in ("B","C","D","E","H","L","A") and a[0] in ("B","C","D","E","H","L","A"): return 4
        if a[0] in ("B","C","D","E","H","L","A"): return 7
    if m.startswith(("DEC ","INC ")): return 6 if m[4:] in ("BC","DE","HL","SP") else 4
    if m.startswith("EX "): return 4
    if m.startswith("XOR A"): return 4
    if m.startswith("IN A,("): return 11
    if m.startswith(("AND ","CP ")): return 7
    if m.startswith("JP "): return 10
    if m.startswith("JR "): return 12
    if m=="HALT": return 4
    return 4
reg={"L":7,"0":0,"A":0,"B":2,"C":6,"D":6,"E":4,"H":5}
t=8918; col=0; code=[]   # (T_end, new_colour) только при смене цвета; стартовый цвет бордюра перед лесенкой = 0 (чёрный) в устойчивом кадре
for a in sorted(x for x in ins if 0x8037<=x<0x9F7E):
    m=ins[a]; t+=T(m)
    if m.startswith("OUT (C)"):
        c=reg.get(m.split(",")[1],None)
        if c is not None and c!=col: code.append((t,col,c,a)); col=c
B=re.compile(r"BORDER (\d+)->(\d+)\s+k=\s*(\d+) T=\s*(\d+)\s+hUla=\s*(\d+) vCount=\s*(\d+)")
ev=[tuple(int(x) for x in m.groups()) for l in open(log,errors="replace") for m in [B.search(l)] if m]
frames=[]; cur=[]; pT=-1
for e in ev:
    if e[3]<pT and cur: frames.append(cur); cur=[]
    cur.append(e); pT=e[3]
frames.append(cur)
f=frames[frame_no]
print("код: смен цвета %d; сим кадр %d: смен %d" % (len(code),frame_no,len(f)))
# выравнивание: сим начинается с первой смены (устойчивый кадр: бордюр уже чёрный) - код тоже начинается с 0->7 если стартовый 0
i=j=0; out=[]
while i<len(code) and j<len(f):
    tc,ca,cb,addr=code[i]; a,b,k,Ts,h,v=f[j]
    if (ca,cb)!=(a,b):
        # рассинхрон - сдвинуть код
        i+=1; continue
    out.append((Ts-tc,Ts,tc,v,h,ca,cb,addr)); i+=1; j+=1
print("сопоставлено %d событий; первые/переходные:" % len(out))
prev=None
for d,Ts,tc,v,h,ca,cb,addr in out:
    if prev is None or d!=prev or v in (0,1,190,191,192,193):
        print("  dev=%+3d  T_sim=%5d T_code=%5d  vCount %3d hUla %3d  %d->%d  @%04x" % (d,Ts,tc,v,h,ca,cb,addr))
    prev=d
import collections
print("гистограмма отклонений:", sorted(collections.Counter(d for d,*_ in out).items()))
