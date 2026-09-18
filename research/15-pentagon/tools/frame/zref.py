#!/usr/bin/env python3
"""Снять N экранов эталона ZEsarUX по ZRCP (эмулятор уже запущен на 10000)."""
import socket, sys, time, os
N   = int(sys.argv[1]) if len(sys.argv)>1 else 6
tag = sys.argv[2] if len(sys.argv)>2 else "shock"
out = sys.argv[3] if len(sys.argv)>3 else "/tmp/ref"
os.makedirs(out, exist_ok=True)
s=socket.create_connection(("127.0.0.1",10000),timeout=30); s.settimeout(30)
def rd(until=b"command> "):
    buf=b""
    while not buf.endswith(until):
        try: c=s.recv(65536)
        except socket.timeout: break
        if not c: break
        buf+=c
    return buf.decode("latin1")
def cmd(c):
    s.sendall((c+"\n").encode()); return rd()
rd()
for i in range(N):
    p="%s/%s%02d.bmp"%(out,tag,i)
    if os.path.exists(p): os.remove(p)
    r=cmd("save-screen %s"%p)
    time.sleep(0.25)
    print(i, os.path.exists(p), os.path.getsize(p) if os.path.exists(p) else 0, r.strip()[:60])
