#!/usr/bin/env python3
"""gen_prog.py - программа Z80 для стенда бордюра (байты пишутся напрямую, ассемблер не нужен).

Раскладка (ORG 0x8000, неконтендящееся ОЗУ - банк 2 у 48K/128K/Пентагона; NOP-слайд может уходить
в 0xC000+ - банк 0, тоже неконтендящийся):
  0x8000  main: DI; LD SP,7FF0h; XOR A; OUT (FE),A; атрибуты 0x5800..0x5AFF = 0x28 (бумага 5 = cyan,
          чернила 0; битмап нулевой -> вся бумага cyan); LD A,81h; LD I,A; IM 2; EI; loop: HALT; JR loop
  0x8100  таблица IM2 (257 байт 0x84) -> вектор 0x8484
  0x8484  ISR:  XOR A; OUT (FE),A            ; базовый цвет 0 (чёрный), запись через 12 T от M1 ISR
                <паддинг k T>                ; NOP*n + один «остаток» (LD A,I = 9 / INC HL = 6 / LD A,n = 7)
                LD A,7; OUT (FE),A           ; белый
                LD A,2; INC HL; OUT (FE),A   ; красный, фронт записи ровно через 24 T после белого
                <хвост 0/9/6/7 T: (94+k+хвост) кратно 4>; EI; RETI
Использование: gen_prog.py <out.bin> <k>
"""
import sys

def padding(k):
    r = k % 4
    if r == 0:
        return b'\x00' * (k // 4)
    if r == 1:
        assert k >= 9, k
        return b'\x00' * ((k - 9) // 4) + b'\xED\x57'          # LD A,I  (9 T)
    if r == 2:
        assert k >= 6, k
        return b'\x00' * ((k - 6) // 4) + b'\x23'              # INC HL  (6 T)
    assert k >= 7, k
    return b'\x00' * ((k - 7) // 4) + b'\x3E\x00'              # LD A,0  (7 T)

def build(k):
    img = bytearray()
    main = bytes([
        0xF3,                   # DI
        0x31, 0xF0, 0x7F,       # LD SP,7FF0h
        0xAF,                   # XOR A
        0xD3, 0xFE,             # OUT (FE),A        ; бордюр 0
        0x21, 0x00, 0x58,       # LD HL,5800h
        0x11, 0x01, 0x58,       # LD DE,5801h
        0x01, 0xFF, 0x02,       # LD BC,767
        0x36, 0x28,             # LD (HL),28h       ; атрибут: бумага 5 (cyan), чернила 0
        0xED, 0xB0,             # LDIR
        0x3E, 0x81,             # LD A,81h
        0xED, 0x47,             # LD I,A
        0xED, 0x5E,             # IM 2
        0xFB,                   # EI
        0x76,                   # loop: HALT
        0x18, 0xFD,             # JR loop
    ])
    img += main
    img += b'\x00' * (0x100 - len(img))
    img += b'\x84' * 257                        # 0x8100..0x8200 -> вектор 0x8484
    img += b'\x00' * (0x484 - len(img))
    assert len(img) == 0x484
    isr = bytes([0xAF, 0xD3, 0xFE])             # XOR A; OUT (FE),A   (база: чёрный)
    isr += padding(k)
    isr += bytes([0x3E, 0x07, 0xD3, 0xFE])      # LD A,7; OUT (FE),A  (белый)
    isr += bytes([0x3E, 0x02, 0x23, 0xD3, 0xFE])# LD A,2; INC HL; OUT (FE),A (красный, +24 T)
    # Хвост: длина ISR от приёма (19 T IM2) до RETI = 94 + k T. Чтобы фаза HALT-цикла относительно
    # /INT не гуляла от кадра к кадру (кадр = кратное 4 T, HALT/JR = кратные 4), доводим её до кратного 4.
    tail = (2 - k) % 4
    isr += {0: b'', 1: b'\xED\x57', 2: b'\x23', 3: b'\x3E\x00'}[tail]   # 9 / 6 / 7 T
    isr += bytes([0xFB, 0xED, 0x4D])            # EI; RETI
    img += isr
    assert 0x8000 + len(img) <= 0x10000, 'программа не влезает в 32 КБ'
    return bytes(img)

if __name__ == '__main__':
    out, k = sys.argv[1], int(sys.argv[2])
    open(out, 'wb').write(build(k))
