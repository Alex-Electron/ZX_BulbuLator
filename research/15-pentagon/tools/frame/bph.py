#!/usr/bin/env python3
"""Свип фазы 8-px группы защёлки бордюра на ЖИВОЙ плате: ULA_TUNE2 бит8 = включить, биты 11:9 = фаза.
Метрика по честному кадру (cmd 14): сколько строк имеют переход в левом/правом бордюре и лев != прав."""
import os
import subprocess, sys, os
P=os.environ.get("BULB_TOOLS", os.path.expanduser("~/tools_0902"))
W,H=384,302
def setphase(v):
    tcl = ("connect -url tcp:localhost:3121\n"
           "targets -set -filter {name =~ \"*Cortex-A9*#0\"}\n"
           "configparams force-mem-accesses 1\n"
           "mwr -force 0x43C001C4 %d\n" % v)
    open("/tmp/bph.tcl","w").write(tcl)
    subprocess.run(["scp","-q","/tmp/bph.tcl","thinkpad:/tmp/bph.tcl"])
    subprocess.run(["ssh","thinkpad","/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb /tmp/bph.tcl"],
                   capture_output=True, text=True)
def frame(tag):
    subprocess.run([sys.executable,P+"/snap14.py",tag],capture_output=True,text=True)
    return open("/tmp/zxframe.bin","rb").read()
def rows(raw):
    out=[]
    for y in range(H):
        base=y*(W//2); px=[]
        for i in range(W//2):
            b=raw[base+i]; px.append(b&0xF); px.append(b>>4)
        out.append(px)
    return out
def segs(r,a,b):
    n=0
    for x in range(a+1,b):
        if r[x]!=r[x-1]: n+=1
    return n
print("фаза | переходов в лев.борд | в прав.борд | строк лев!=прав")
base = 0x1   # сохраняем прежний ula_tune2 бит0
for ph in range(8):
    setphase(base | (1<<8) | (ph<<9))
    R=rows(frame("bph%d"%ph))
    L=sum(segs(r,0,45) for r in R)
    Rr=sum(segs(r,301,384) for r in R)
    ne=sum(1 for r in R if r[10]!=r[340])
    print("  %d  | %5d | %5d | %4d" % (ph,L,Rr,ne))
setphase(base)
print("ручка снята (умолчание)")
