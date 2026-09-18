#!/usr/bin/env python3
"""Снять кадр машины из DDR (ZX: 4bpp, 384x302, 0x0FF00000) -> PNG + числа.
Один байт = ДВА пикселя, палитра ZX 16 цветов. Не путать с NES (8bpp 256x240).
  fb4bpp.py <метка>   - снять, сохранить <метка>.png и напечатать метрики
"""
import subprocess, sys, zlib, struct, collections
HOST = "thinkpad"
XSDB = "/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
W, H = 384, 302
WORDS = W * H // 8          # 4bpp -> 2 px/байт -> 8 px/слово
TCL = """connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
mrd -force -bin -file /tmp/zxframe.bin 0x0FF00000 %d
puts FB_OK
""" % WORDS
# 🥇 Полубайт кадра = {i, r, g, b} (fb_capture_rr.v:132): бит2 = R, бит1 = G, бит0 = B. Это НЕ порядок
# атрибута ZX (там бит1 = R, бит2 = G). Прежняя таблица шла в порядке ZX и перекрашивала красный бордюр
# в зелёный (btime 02.09) - виноват был декодер, не плата.
PAL = [(0,0,0),(0,0,0xC0),(0,0xC0,0),(0,0xC0,0xC0),(0xC0,0,0),(0xC0,0,0xC0),(0xC0,0xC0,0),(0xC0,0xC0,0xC0),
       (0,0,0),(0,0,0xFF),(0,0xFF,0),(0,0xFF,0xFF),(0xFF,0,0),(0xFF,0,0xFF),(0xFF,0xFF,0),(0xFF,0xFF,0xFF)]

def grab():
    open("/tmp/_fb.tcl","w").write(TCL)
    subprocess.run(["scp","-q","/tmp/_fb.tcl",HOST+":/tmp/_fb.tcl"],check=True)
    out = subprocess.run(["ssh",HOST,"timeout 300 %s /tmp/_fb.tcl 2>&1 | tail -2" % XSDB],
                         capture_output=True,text=True).stdout
    if "FB_OK" not in out: sys.exit("кадр не снялся: "+out)
    subprocess.run(["scp","-q",HOST+":/tmp/zxframe.bin","/tmp/zxframe.bin"],check=True)
    return open("/tmp/zxframe.bin","rb").read()

def png(rows, path, scale=2):
    def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    raw=b""
    for r in rows:
        line=b"".join(bytes(PAL[c]) for c in r for _ in range(scale))
        for _ in range(scale): raw += b"\x00"+line
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR",struct.pack(">IIBBBBB",W*scale,len(rows)*scale,8,2,0,0,0))
        + chunk(b"IDAT",zlib.compress(raw,9)) + chunk(b"IEND",b""))

def main():
    tag = sys.argv[1] if len(sys.argv)>1 else "fb"
    d = grab()
    rows=[]
    for y in range(H):
        r=[]
        for x in range(W//2):
            b=d[y*(W//2)+x]
            r.append(b>>4); r.append(b&15)
        rows.append(r)
    png(rows, "%s.png" % tag)
    # где бумага: столбец считаем «бумажным», если по кадру в нём встречается >2 разных цветов
    varied=[x for x in range(W) if len({rows[y][x] for y in range(40,H-40)})>2]
    x0,x1=(min(varied),max(varied)) if varied else (0,W-1)
    print("PNG %s.png  байт кадра %d" % (tag,len(d)))
    print("подвижная область по горизонтали: %d..%d (ширина %d)" % (x0,x1,x1-x0+1))
    # мультиколор: сколько РАЗНЫХ цветов в строке внутри этой области
    hist=collections.Counter()
    for y in range(H):
        n=len(set(rows[y][x0:x1+1]))
        hist[n]+=1
    print("цветов в строке (внутри области) -> строк:", dict(sorted(hist.items())))
    # бордюр слева/справа: последовательность цветов по строкам
    left=[rows[y][max(0,x0-6)] for y in range(H)]
    runs=[]
    for c in left:
        if runs and runs[-1][0]==c: runs[-1][1]+=1
        else: runs.append([c,1])
    print("левый бордюр, полосы (цвет x строк), первые 30:", [(c,n) for c,n in runs[:30]])
    print("всего полос в левом бордюре:", len(runs))
main()
