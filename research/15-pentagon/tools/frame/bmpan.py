#!/usr/bin/env python3
"""Разбор BMP-экрана ZEsarUX (352x304): границы цветовых сегментов в ЛЕВОМ бордюре по строкам."""
import struct, sys, collections
def load(p):
    d=open(p,'rb').read()
    off=struct.unpack_from('<I',d,10)[0]
    w,h=struct.unpack_from('<ii',d,18)
    bpp=struct.unpack_from('<H',d,28)[0]
    assert bpp==24,(bpp,)
    flip = h>0; h=abs(h)
    row=(w*3+3)//4*4
    px=[]
    for y in range(h):
        yy = h-1-y if flip else y
        base=off+yy*row
        px.append([d[base+3*x+2]<<16 | d[base+3*x+1]<<8 | d[base+3*x] for x in range(w)])
    return w,h,px
def segs(r,a,b):
    out=[]; s=a
    for x in range(a+1,b):
        if r[x]!=r[x-1]: out.append((s,x-1,r[s])); s=x
    out.append((s,b-1,r[s])); return out
if __name__=="__main__":
    for p in sys.argv[1:]:
        w,h,px=load(p)
        print("==",p,w,"x",h)
        # где бумага? колонки, где по всей высоте бывает много цветов -> найдём по строке 150
        # у ZEsarUX 352x304: бумага 48..303
        PAP0,PAP1=48,304
        hx=collections.Counter()
        for y in range(h):
            for (s,e,c) in segs(px[y],0,PAP0)[1:]: hx[s]+=1
        print(" переходы в ЛЕВОМ бордюре по x:", sorted(hx.items())[:20])
        hx=collections.Counter()
        for y in range(h):
            for (s,e,c) in segs(px[y],PAP1,w)[1:]: hx[s]+=1
        print(" переходы в ПРАВОМ бордюре по x:", sorted(hx.items())[:20])
        # построчно: первая граница в левом бордюре
        rowfirst={}
        for y in range(h):
            ss=segs(px[y],0,PAP0)
            rowfirst[y]= ss[1][0] if len(ss)>1 else None
        # печать компактно диапазонами
        prev=None; start=None; outl=[]
        for y in range(h):
            v=rowfirst[y]
            if v!=prev:
                if prev is not None: outl.append("%d-%d:%s"%(start,y-1,prev))
                prev=v; start=y
        outl.append("%d-%d:%s"%(start,h-1,prev))
        print(" первая граница лев.бордюра по строкам:", " ".join(outl[:40]))
