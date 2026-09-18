#!/usr/bin/env python3
"""Образ для стенда tb_ula из 48K .SNA: ОЗУ 4000..FFFF + заглушка в 4000 (экран, для бордюра безвредно),
восстанавливающая регистры из заголовка SNA и прыгающая на PC со стека (RETN). Запуск стенда:
ROOT=<dir> xrun.sh MACHINE=48 ULALATE=0 PROG=<out.bin> ORG=4000 RUNUS=90000 QUIET=1 ; разбор - esh_parse2.py <лог>.
НЕ ЗАПУСКАЛСЯ - подготовлен 02.09 вечером, проверить заглушку в симе (первые события BORDER)."""
import sys,struct
d=open(sys.argv[1],"rb").read(); assert len(d)==49179, "ожидается 48K SNA"
I=d[0]; HLa,DEa,BCa,AFa=struct.unpack("<HHHH",d[1:9]); HL,DE,BC,IY,IX=struct.unpack("<HHHHH",d[9:19]); IFF2=d[19]; AF,SP=struct.unpack("<HH",d[21:25]); IM=d[25]; border=d[26]
ram=bytearray(d[27:]); pc=ram[SP-0x4000]|(ram[SP-0x4000+1]<<8); SP2=(SP+2)&0xFFFF
print("SNA: PC=%04x SP=%04x AF=%04x BC=%04x DE=%04x HL=%04x IX=%04x IY=%04x I=%02x IM=%d IFF2=%d border=%d"%(pc,SP,AF,BC,DE,HL,IX,IY,I,IM,IFF2,border))
def ld16(op,v): return bytes([op,v&0xFF,v>>8])
st=bytearray(); st+=ld16(0x31,0x5B00); st+=bytes([0x3E,I,0xED,0x47])
st+=bytes([0xED,0x5E]) if IM==2 else (bytes([0xED,0x56]) if IM==1 else bytes([0xED,0x46]))
st+=bytes([0xD9])+ld16(0x01,BCa)+ld16(0x11,DEa)+ld16(0x21,HLa)+bytes([0xD9])   # EXX ; BC' DE' HL' ; EXX
st+=ld16(0x01,AFa)+bytes([0xC5,0xF1,0x08])                                       # AF' : LD BC ; PUSH BC ; POP AF ; EX AF,AF'
st+=ld16(0x01,AF)+bytes([0xC5,0xF1])                                             # AF
st+=ld16(0x01,BC)+ld16(0x11,DE)+ld16(0x21,HL)+bytes([0xDD])+ld16(0x21,IX)+bytes([0xFD])+ld16(0x21,IY)
st+=bytes([0x3E,border&7,0xD3,0xFE])+ld16(0x31,SP2)+bytes([0xFB] if IFF2 else [0xF3])+ld16(0xC3,pc)
img=bytearray(ram); img[0:len(st)]=st
open(sys.argv[2],"wb").write(img); print("образ %s: %d байт, заглушка %d байт"%(sys.argv[2],len(img),len(st)))
