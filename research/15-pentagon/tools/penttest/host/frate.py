#!/usr/bin/env python3
"""frate.py <секунд> <тактов в кадре> - частота кадров машины: FRAMES из зеркала экрана (fcount.tap
копирует его в 16384..16386) против глобального таймера ARM (0xF8F00200, CPU/2 = 333.333 МГц).
Оба числа читаются ОДНИМ скриптом xsdb подряд, ничего не останавливая."""
import subprocess, sys, time, re
X = "/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
TCL = """connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }
set g0 [rd 0xF8F00200]
set f [rd 0x40008000]
set g1 [rd 0xF8F00200]
set hi [rd 0xF8F00204]
puts "G0=$g0 F=$f G1=$g1 HI=$hi"
disconnect
"""
def sample():
    open("/tmp/_fr.tcl", "w").write(TCL)
    t = time.time()
    o = subprocess.run([X, "/tmp/_fr.tcl"], capture_output=True, text=True).stdout
    v = {k: int(x) for k, x in re.findall(r"(\w+)=(\d+)", o)}
    g = (v["HI"] << 32) | ((v["G0"] + v["G1"]) // 2)
    return g, v["F"] & 0xFFFFFF, t, v["G1"] - v["G0"]
secs = float(sys.argv[1]); tpf = int(sys.argv[2])
g0, f0, t0, w0 = sample()
time.sleep(secs)
g1, f1, t1, w1 = sample()
if g1 < g0: sys.exit("таймер перевалил, повторить")
dt = (g1 - g0) / 333.333333e6
df = (f1 - f0) & 0xFFFFFF
fps = df / dt
print("кадров %d за %.3f с (часы хоста %.3f с, окно чтения %d/%d тиков)" % (df, dt, t1 - t0, w0, w1))
print("частота кадров %.4f Гц -> такт процессора %.5f МГц (при %d T/кадр)" % (fps, fps * tpf / 1e6, tpf))
