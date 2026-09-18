#!/usr/bin/env python3
"""OCR экрана ZX из памяти эмулятора по ZRCP + шрифт ПЗУ 0x3D00. Инверсия распознаётся."""
import socket, sys
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
def mem(a,n):
    out=b""
    while n>0:
        k=min(n,1024)
        r=cmd("read-memory %d %d"%(a,k)).strip().split("\n")[0].strip()
        out+=bytes.fromhex(r); a+=k; n-=k
    return out
font=mem(15616,768)
glyphs={}
for i in range(96):
    glyphs[bytes(font[i*8:i*8+8])]=chr(32+i)
scr=mem(16384,6144)
def addr(cx,cy):
    return ((cy&0x18)<<8) | ((cy&7)<<5) | cx
lines=[]
for cy in range(24):
    row=""
    for cx in range(32):
        g=bytes(scr[addr(cx,cy)+0x100*k] for k in range(8))
        c=glyphs.get(g)
        if c is None:
            inv=bytes(255-x for x in g)
            c=glyphs.get(inv)
            c = ("["+c+"]") if c else "?"
        row+=c
    lines.append(row.rstrip())
print("\n".join(l for l in lines))
