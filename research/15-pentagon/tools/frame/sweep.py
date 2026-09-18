#!/usr/bin/env python3
"""Сдвиг ВСЕЙ демки по тактам на эталоне: вектор IM2 (FEFF/FF00) ведём на FFFF-k, где
k NOP-ов + RET = +4k T к каждому кадру. Для каждого сдвига - снимок и разбор бордюра."""
import socket, sys, os, time, bmpan, collections
s=socket.create_connection(("127.0.0.1",10000),timeout=30); s.settimeout(30)
def rd(u=b"command> "):
    b=b""
    while not b.endswith(u):
        try: c=s.recv(65536)
        except socket.timeout: break
        if not c: break
        b+=c
    return b.decode("latin1")
def cmd(c):
    s.sendall((c+"\n").encode()); return rd()
rd()
cmd("write-memory 65280 255")            # FF00 = FF (старший байт вектора)
KS=[int(x) for x in sys.argv[1].split(",")] if len(sys.argv)>1 else list(range(0,57,2))
os.makedirs("/tmp/sw",exist_ok=True)
print(" k  +T | строк лев!=прав | x переходов в бордюрах (гистограмма)")
for k in KS:
    lo=(0xFFFF-k)&0xFF
    cmd("write-memory 65279 %d"%lo)
    time.sleep(0.35)
    p="/tmp/sw/k%03d.bmp"%k
    if os.path.exists(p): os.remove(p)
    cmd("save-screen %s"%p); time.sleep(0.2)
    if not os.path.exists(p): print(k,"нет снимка"); continue
    w,h,px=bmpan.load(p)
    ne=[y for y in range(h) if px[y][10]!=px[y][340]]
    hx=collections.Counter()
    for y in range(h):
        for (a,b,c) in bmpan.segs(px[y],0,48)[1:]: hx[('L',a)]+=1
        for (a,b,c) in bmpan.segs(px[y],304,w)[1:]: hx[('R',a)]+=1
    print("%3d %4d | %3d | %s"%(k,4*k,len(ne),sorted(hx.items())[:10]))
cmd("write-memory 65279 255")
