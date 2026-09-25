#!/usr/bin/env python3
"""rsweep.py <mode s|b> <снимков> [y0 x0] - серия снимков cmd 14 растровых тестов rastime/rasbord и разбор.
Один сеанс xsdb: cmd 14, затем из каждой копии кадра читаются только строки клетки, двух полосок T и четыре
строки над бумагой. Кадр засчитывается, если верхняя и нижняя полоски совпали, метка «всегда чёрный» есть и
стоит флажок «кадр измерительный». Итог - по каждому T счёт кадров."""
import subprocess, sys, os, collections, re
X = "/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
mode = sys.argv[1]; N = int(sys.argv[2])
y0 = int(sys.argv[3]) if len(sys.argv) > 3 else 62
x0 = int(sys.argv[4]) if len(sys.argv) > 4 else 65
W = 384; RB = W // 2
ROWS = [y0 - 4, y0 - 3, y0 - 2, y0 - 1, y0, y0 + 8, y0 + 176]
os.makedirs("/tmp/rs", exist_ok=True)
for f in os.listdir("/tmp/rs"): os.remove("/tmp/rs/" + f)
tcl = ['connect -url tcp:localhost:3121', 'targets -set -filter {name =~ "*Cortex-A9*#0"}',
       'configparams force-mem-accesses 1',
       'proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }',
       'for {set s 0} {$s < %d} {incr s} {' % N,
       ' mwr -force 0x0F70000C 0; mwr -force 0x0F700008 0; mwr -force 0x0F700004 14',
       ' for {set t 0} {$t < 50} {incr t} { after 20; if {[rd 0x0F700008] != 0} break }',
       ' set nb [rd 0x0F700014]; if {$nb < 3 || $nb > 5} { set nb 3 }',
       ' for {set k 0} {$k < $nb} {incr k} {']
for y in ROWS:
    tcl.append('  mrd -force -bin -file /tmp/rs/s${s}_b${k}_y%d.bin [expr {0x0F900000 + $k*0x10000 + %d}] %d' % (y, y * RB, RB // 4))
tcl += [' }', ' after [expr {50 + int(rand()*400)}]', '}', 'puts SWEEP_OK', 'disconnect']
open("/tmp/_rs.tcl", "w").write("\n".join(tcl) + "\n")
o = subprocess.run([X, "/tmp/_rs.tcl"], capture_output=True, text=True).stdout
if "SWEEP_OK" not in o: sys.exit("серия не прошла: " + o[-500:])
def px(buf, x):
    b = buf[x // 2]; return (b & 15) if x % 2 == 0 else (b >> 4)
def bar(buf):
    v = sum(1 << c for c in range(16) if px(buf, x0 + 8 * c + 3) == 0)
    return v, px(buf, x0 + 8 * 16 + 3) == 0, px(buf, x0 + 8 * 17 + 3) == 0
stat = collections.defaultdict(collections.Counter); used = rej = 0
files = collections.defaultdict(dict)
for f in os.listdir("/tmp/rs"):
    m = re.match(r"s(\d+)_b(\d+)_y(\d+)\.bin", f)
    files[(int(m.group(1)), int(m.group(2)))][int(m.group(3))] = open("/tmp/rs/" + f, "rb").read()
for key, fr in sorted(files.items()):
    tb, bb = bar(fr[y0 + 8]), bar(fr[y0 + 176])
    if not (tb[0] == bb[0] and tb[1] and bb[1] and bb[2]): rej += 1; continue
    T = tb[0]; used += 1
    if mode == "s":
        c = collections.Counter(px(fr[y0], x0 + i) for i in range(8))
        stat[T]["visible" if c.get(4, 0) == 8 else "absent" if c.get(6, 0) == 8 else "mixed"] += 1
    else:
        found = None
        for y in ROWS[:4]:
            reds = [x for x in range(W) if px(fr[y], x) == 4]
            if reds: found = (y - y0, reds[0], reds[-1]); break
        stat[T][found] += 1
print("кадров засчитано %d, отброшено %d" % (used, rej))
for T in sorted(stat):
    if mode == "s":
        print("T=%d  %s" % (T, dict(stat[T])))
    else:
        items = []
        for k, n in stat[T].items():
            if k is None: items.append("нет красного x%d" % n); continue
            dy, xa, xb = k
            # такт, на котором OUT попал бы ровно в левый край бумаги строкой выше (как у btime)
            bt = T - (dy + 1) * 224 - (xa - x0) / 2
            items.append("строка %+d x=%d..%d (btime-экв %.1f) x%d" % (dy, xa - x0, xb - x0, bt, n))
        print("T=%d  %s" % (T, "; ".join(items)))
