#!/usr/bin/env python3
"""Трасса команд эталона: брейкпоинт PC=<start>, затем N одиночных шагов (пошаговый режим) с записью PC, T в кадре, текста команды."""
import socket, re, sys
start=int(sys.argv[1],16); N=int(sys.argv[2]); out=sys.argv[3]
s=socket.create_connection(("127.0.0.1",10000),timeout=30)
def rd(until=b"command> "):
    buf=b""
    while not buf.endswith(until):
        c=s.recv(65536)
        if not c: break
        buf+=c
    return buf.decode("latin1")
def cmd(c): s.sendall((c+"\n").encode()); return rd()
rd(); cmd("disable-breakpoints"); cmd("set-breakpoint 1 PC=%dH"%start if False else "set-breakpoint 1 PC=%d"%start); cmd("enable-breakpoints")
r=cmd("run"); cmd("disable-breakpoints"); cmd("enter-cpu-step")
rows=[]
for i in range(N):
    g=cmd("get-registers"); t=cmd("get-tstates")
    pc=re.search(r"PC=([0-9a-fA-F]+)",g); ts=re.search(r"(\d+)",t)
    st=cmd("cpu-step").replace("command> ","").strip()
    rows.append("%s %s %s"%(pc.group(1) if pc else "????", ts.group(1) if ts else "-1", st.split("\n")[0][:40]))
cmd("exit-cpu-step")
open(out,"w").write("\n".join(rows)); print("шагов:",len(rows)); print("\n".join(rows[:6])); print("..."); print("\n".join(rows[-3:]))
