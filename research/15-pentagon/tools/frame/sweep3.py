#!/usr/bin/env python3
"""Тот же сдвиг, но КАЖДЫЙ шаг с чистого снапшота: smartload -> патч вектора -> кадр -> разбор."""
import os
import socket, os, time, bmpan, collections
SNA=os.environ.get("ZXSOFT", os.path.expanduser("~/ZX-Soft"))
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
os.makedirs("/tmp/sw3",exist_ok=True)
print(" k  +T | PC     | лев/прав różn | переходы в бордюрах (x -> сколько строк)")
for k in range(0,13):
    cmd("smartload %s"%SNA); time.sleep(1.2)
    cmd("write-memory 65280 255")
    cmd("write-memory 65279 %d"%((0xFFFF-k)&0xFF))
    time.sleep(1.0)
    reg=cmd("get-registers"); pc=reg.split("PC=")[1][:4] if "PC=" in reg else "????"
    p="/tmp/sw3/k%02d.bmp"%k
    if os.path.exists(p): os.remove(p)
    cmd("save-screen %s"%p); time.sleep(0.25)
    if not os.path.exists(p): print(k,"нет снимка"); continue
    w,h,px=bmpan.load(p)
    ne=sum(1 for y in range(h) if px[y][10]!=px[y][340])
    hx=collections.Counter()
    for y in range(h):
        for (a,b,c) in bmpan.segs(px[y],0,48)[1:]: hx['L%d'%a]+=1
        for (a,b,c) in bmpan.segs(px[y],304,w)[1:]: hx['R%d'%a]+=1
    print("%3d %4d | PC=%s | %3d | %s"%(k,4*k,pc,ne,sorted(hx.items(),key=lambda t:-t[1])[:6]))
cmd("smartload %s"%SNA)
