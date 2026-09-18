#!/usr/bin/env python3
"""Честный кадр машины: мейлбокс cmd 14 (v0.15.435) копирует три буфера кадра в FS_BUF за ~3 мс, дальше читаем копии
по JTAG сколько угодно. Возвращает список из 3 кадров (4bpp 384x302) и печатает, какие из них целые.
  snap14.py <метка>  -> /tmp/<метка>_b{0,1,2}.bin ; выбранный целый -> /tmp/zxframe.bin (для остальных скриптов)"""
import subprocess, sys, hashlib
import os
HOST=os.environ.get("SNAPHOST","thinkpad")   # локальный запуск: SNAPHOST=localhost; XSDB="/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
W,H=384,302; FSZ=W*H//2
TCL="""connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }
mwr -force 0x0F70000C 0; mwr -force 0x0F700008 0; mwr -force 0x0F700004 14
set d 0
for {set t 0} {$t < 100} {incr t} { after 100; set d [rd 0x0F700008]; if {$d != 0} break }
puts [format "cmd14 done=%%d err=%%d n=%%d" $d [rd 0x0F70000C] [rd 0x0F700014]]
mrd -force -bin -file /tmp/snap_b0.bin 0x0F900000 %d
mrd -force -bin -file /tmp/snap_b1.bin 0x0F910000 %d
mrd -force -bin -file /tmp/snap_b2.bin 0x0F920000 %d
puts SNAP_OK
""" % (FSZ//4, FSZ//4, FSZ//4)
def rows(raw):
    out=[]
    for y in range(H):
        base=y*(W//2); px=[]
        for i in range(W//2):
            b=raw[base+i]; px.append(b&0xF); px.append(b>>4)
        out.append(px)
    return out
def main():
    tag=sys.argv[1] if len(sys.argv)>1 else "snap"
    open("/tmp/_s14.tcl","w").write(TCL)
    subprocess.run(["scp","-q","/tmp/_s14.tcl",HOST+":/tmp/_s14.tcl"],check=True)
    out=subprocess.run(["ssh",HOST,"timeout 600 %s /tmp/_s14.tcl 2>&1 | tail -2"%XSDB],capture_output=True,text=True).stdout
    if "SNAP_OK" not in out: sys.exit("снимок не снялся: "+out)
    print(out.strip().split("\n")[0])
    frames=[]
    for k in range(3):
        subprocess.run(["scp","-q",HOST+":/tmp/snap_b%d.bin"%k,"/tmp/%s_b%d.bin"%(tag,k)],check=True)
        frames.append(open("/tmp/%s_b%d.bin"%(tag,k),"rb").read())
    h=[hashlib.md5(f).hexdigest()[:8] for f in frames]
    print("хеши копий:", h)
    # целостность: рваный буфер = тот, что отличается от обоих других (при движущейся картинке все три
    # разные - тогда берём копию, у которой нет резкого разрыва структуры между соседними строками)
    pick=0
    if h[0]==h[1]: pick=0
    elif h[0]==h[2]: pick=0
    elif h[1]==h[2]: pick=1
    else:
        # все разные: оценить «разрывы» - число строк, где число цветовых прогонов резко меняется
        def jumps(f):
            R=rows(f); prev=None; j=0
            for r in R:
                n=1+sum(1 for i in range(1,W) if r[i]!=r[i-1])
                if prev is not None and abs(n-prev)>12: j+=1
                prev=n
            return j
        js=[jumps(f) for f in frames]; pick=js.index(min(js)); print("разрывов по копиям:", js)
    open("/tmp/zxframe.bin","wb").write(frames[pick])
    print("выбрана копия", pick, "-> /tmp/zxframe.bin")
main()
