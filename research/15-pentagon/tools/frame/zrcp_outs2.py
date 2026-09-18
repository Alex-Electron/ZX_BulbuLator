#!/usr/bin/env python3
"""Расписание OUT эталона в пошаговом режиме: enter-cpu-step, брейкпоинт OUTFIRED=1, run (блокируется), регистры + get-tstates, cpu-step, run..."""
import socket, re, sys, time
N=int(sys.argv[1]) if len(sys.argv)>1 else 500
s=socket.create_connection(("127.0.0.1",10000),timeout=60)
def rd(until=b"> "):
    buf=b""
    while not buf.endswith(until):
        c=s.recv(65536)
        if not c: break
        buf+=c
    return buf.decode("latin1")
def cmd(c): s.sendall((c+"\n").encode()); return rd()
rd()
cmd("disable-breakpoints"); cmd("exit-cpu-step"); time.sleep(0.5)
print(cmd("enter-cpu-step")[:80].strip().replace("\n"," | "))
cmd("set-breakpoint 1 OUTFIRED=1"); cmd("enable-breakpoints")
rows=[]
for i in range(N):
    r=cmd("run")
    g=cmd("get-registers"); t=cmd("get-tstates")
    pc=re.search(r"PC=([0-9a-fA-F]+)",g); af=re.search(r"AF=([0-9a-fA-F]+)",g); ts=re.search(r"(\d+)",t)
    if not pc: print("нет регистров:",g[:100]); break
    rows.append((int(pc.group(1),16), int(ts.group(1)) if ts else -1))
    cmd("cpu-step")
cmd("disable-breakpoints"); cmd("exit-cpu-step")
open("/tmp/esh_outs2.txt","w").write("\n".join("%04x %d"%r for r in rows))
import collections
print("OUT-ов:",len(rows),"уникальных PC:",len(set(r[0] for r in rows)))
print("первые 10:", ["%04x@%d"%r for r in rows[:10]])
# ключевые адреса (PC после OUT = адрес OUT + 2)
want={0x8039:"8037 первый чёрный",0x80fb:"80F9 белый верх (строка 292 у нас)",0x8439:"8437 белый экран стр0",0x843c:"843A чёрный стр1",0x844a:"8448 белый стр1 правый",0x844f:"844D чёрный стр1"}
for pc,t in rows:
    if pc in want: print("  %s: T=%d  строка %d фаза %d" % (want[pc],t,t//224,t%224))
