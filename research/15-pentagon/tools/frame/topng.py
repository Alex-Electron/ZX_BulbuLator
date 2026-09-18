import zlib, struct, sys, bmpan
def png(path, w, h, px):
    raw=b"".join(b"\x00"+b"".join(bytes([(c>>16)&255,(c>>8)&255,c&255]) for c in row) for row in px)
    def chunk(t,d): 
        c=t+d; return struct.pack(">I",len(d))+c+struct.pack(">I",zlib.crc32(c)&0xffffffff)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(raw,6))+chunk(b"IEND",b""))
if __name__=="__main__":
    w,h,px=bmpan.load(sys.argv[1]); png(sys.argv[2],w,h,px); print("ok",w,h)
