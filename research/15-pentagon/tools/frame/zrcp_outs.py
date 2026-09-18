#!/usr/bin/env python3
"""Расписание OUT-ов на эталоне: брейкпоинт OUTFIRED=1, на каждом срабатывании PC, A, TSTATESP, SCANLINE; затем run."""
import socket, re, sys, time
N=int(sys.argv[1]) if len(sys.argv)>1 else 400
s=socket.create_connection(("127.0.0.1",10000),timeout=20); s.settimeout(20)
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
print(cmd("enable-breakpoints")[:120].strip()); print(cmd("set-breakpoint 1 OUTFIRED=1")[:120].strip())
rows=[]
for i in range(N):
    if i: cmd("cpu-step")   # иначе OUTFIRED остаётся истинным и брейкпоинт срабатывает на том же месте
    r=cmd("run")   # блокируется до срабатывания
    g=cmd("get-registers")
    pc=re.search(r"PC=([0-9a-fA-F]+)",g); a=re.search(r"AF=([0-9a-fA-F]+)",g)
    tsr=cmd("get-tstates"); m=re.search(r"(\d+)",tsr); tsv=int(m.group(1)) if m else -1
    class _M:
        def __init__(s,v): s.v=v
        def group(s,i): return str(s.v)
    ts=_M(tsv); tl=_M(tsv%224 if tsv>=0 else -1); sc=_M(tsv//224 if tsv>=0 else -1)
    if not pc: print("нет регистров:",g[:200]); break
    rows.append((int(pc.group(1),16), int(a.group(1),16)>>8 if a else -1, int(ts.group(1)) if ts else -1, int(tl.group(1)) if tl else -1, int(sc.group(1)) if sc else -1))
cmd("disable-breakpoints")
open("/tmp/esh_outs.txt","w").write("\n".join("%04x %02x %d %d %d"%r for r in rows))
print("собрано OUT-ов:",len(rows)); print("PC   A  TSTATESP TSTATESL SCANLINE"); 
for r in rows[:12]: print("%04x %02x %6d %4d %4d"%r)
print("..."); 
for r in rows[-6:]: print("%04x %02x %6d %4d %4d"%r)
