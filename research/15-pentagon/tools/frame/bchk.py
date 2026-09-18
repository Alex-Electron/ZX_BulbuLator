#!/usr/bin/env python3
import os
import subprocess, sys
P=os.environ.get("BULB_TOOLS", os.path.expanduser("~/tools_0902"))
W,H=384,302
def setr(v):
    open("/tmp/bph.tcl","w").write("connect -url tcp:localhost:3121\ntargets -set -filter {name =~ \"*Cortex-A9*#0\"}\nconfigparams force-mem-accesses 1\nmwr -force 0x43C001C4 %d\n"%v)
    subprocess.run(["scp","-q","/tmp/bph.tcl","thinkpad:/tmp/bph.tcl"])
    subprocess.run(["ssh","thinkpad","/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb /tmp/bph.tcl"],capture_output=True,text=True)
def snap(tag):
    subprocess.run([sys.executable,P+"/snap14.py",tag],capture_output=True,text=True)
    raw=open("/tmp/zxframe.bin","rb").read()
    return [[ (raw[y*(W//2)+x//2]&0xF) if x%2==0 else (raw[y*(W//2)+x//2]>>4) for x in range(W)] for y in range(H)]
for ph in [int(a) for a in sys.argv[1:]] or [3,6,4]:
    setr(0x1 | (1<<8) | (ph<<9))
    R=snap("chk%d"%ph)
    Lc=len(set(R[y][10] for y in range(H)))
    Pc=len(set(R[y][150] for y in range(60,240)))
    tr=sum(1 for y in range(H) for x in range(1,45) if R[y][x]!=R[y][x-1])
    ne=sum(1 for y in range(H) if R[y][10]!=R[y][340])
    # где кончается бумага слева/справа
    first=[x for x in range(W) if len(set(R[y][x] for y in range(60,240)))>1]
    print("фаза %d: цветов лев.борд=%2d, цветов бумага=%2d, переходов=%3d, лев!=прав=%3d, активные столбцы %d..%d"
          % (ph,Lc,Pc,tr,ne,first[0] if first else -1, first[-1] if first else -1))
    print("        лев.борд по строкам 96..112:", [R[y][10] for y in range(96,113)])
setr(0x1)
