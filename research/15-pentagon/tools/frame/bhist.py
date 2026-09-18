#!/usr/bin/env python3
import os
import subprocess, sys, collections
P=os.environ.get("BULB_TOOLS", os.path.expanduser("~/tools_0902"))
W,H=384,302
def setr(v):
    open("/tmp/bph.tcl","w").write("connect -url tcp:localhost:3121\ntargets -set -filter {name =~ \"*Cortex-A9*#0\"}\nconfigparams force-mem-accesses 1\nmwr -force 0x43C001C4 %d\n"%v)
    subprocess.run(["scp","-q","/tmp/bph.tcl","thinkpad:/tmp/bph.tcl"])
    subprocess.run(["ssh","thinkpad","/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb /tmp/bph.tcl"],capture_output=True,text=True)
def snap(tag):
    subprocess.run([sys.executable,P+"/snap14.py",tag],capture_output=True,text=True)
    raw=open("/tmp/zxframe.bin","rb").read()
    assert len(raw)==W*H//2
    return [[ (raw[y*(W//2)+x//2]&0xF) if x%2==0 else (raw[y*(W//2)+x//2]>>4) for x in range(W)] for y in range(H)]
for ph in [int(a) for a in sys.argv[1:]]:
    setr(0x1 if ph<0 else (0x1 | (1<<8) | (ph<<9)))
    R=snap("h%d"%ph)
    h=collections.Counter()
    for y in range(H):
        for x in range(1,45):
            if R[y][x]!=R[y][x-1]: h[x]+=1
    print("фаза %2d: гистограмма x переходов лев.бордюра: %s" % (ph, sorted(h.items())[:8]))
setr(0x1)
