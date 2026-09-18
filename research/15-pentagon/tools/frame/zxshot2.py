#!/usr/bin/env python3
"""Как zxshot.py, но узнаёт и ИНВЕРСНЫЕ знакоместа (в ПЗУ-шрифте их нет, а софт ими выделяет).
Инверсный символ печатается в квадратных скобках, чтобы его было видно."""
import subprocess, sys
from collections import Counter
HOST="thinkpad"; XSDB="/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
TCL="""connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
mrd -force -bin -file /tmp/zxscr.bin 0x40008000 1728
puts ZX_OK
"""
def font():
    import os
    if not os.path.exists("/tmp/rom128.hex"):
        subprocess.run(["scp","-q",HOST+":/home/lavrinovich/bulb-v13/research/15-pentagon/sources/build/rom128.hex","/tmp/rom128.hex"],check=True)
    rom=bytearray()
    for ln in open("/tmp/rom128.hex"):
        for tok in ln.split():
            try: rom.append(int(tok,16))
            except ValueError: pass
    norm,inv={},{}
    for c in range(32,128):
        g=bytes(rom[0x7D00+(c-32)*8:0x7D00+(c-32)*8+8])
        norm.setdefault(g,chr(c))
        inv.setdefault(bytes(b^0xFF for b in g),chr(c))
    return norm,inv
def main():
    tag=sys.argv[1] if len(sys.argv)>1 else "zx"
    open("/tmp/_zx.tcl","w").write(TCL)
    subprocess.run(["scp","-q","/tmp/_zx.tcl",HOST+":/tmp/_zx.tcl"],check=True)
    out=subprocess.run(["ssh",HOST,"timeout 120 %s /tmp/_zx.tcl 2>&1 | tail -3"%XSDB],capture_output=True,text=True).stdout
    if "ZX_OK" not in out: sys.exit("кадр не снялся: "+out)
    subprocess.run(["scp","-q",HOST+":/tmp/zxscr.bin","/tmp/zxscr.bin"],check=True)
    scr=open("/tmp/zxscr.bin","rb").read()
    norm,inv=font(); attr=scr[6144:6912]; common=Counter(attr).most_common(1)[0][0]
    lines=[]
    for y in range(24):
        s=""
        for x in range(32):
            g=bytes(scr[((y//8)*2048)+(r*256)+((y%8)*32)+x] for r in range(8))
            if g in norm: s+=norm[g]
            elif g in inv: s+="["+inv[g]+"]"
            else: s+="#" if any(g) else " "
        odd=sum(1 for x in range(32) if attr[y*32+x]!=common)
        lines.append(("> " if odd else "  ")+s.rstrip())
    txt="\n".join(lines); print(txt); open("/tmp/%s.txt"%tag,"w").write(txt)
main()
