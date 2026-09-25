#!/usr/bin/env python3
"""mktap.py <code.bin> <out.tap> [имя] [USR] [REM] - лента: Бейсик-загрузчик + блок кода по #8000.
Без необязательных аргументов - лента PENTTEST, как раньше."""
import sys, struct
def num(n):                       # число в Бейсике: цифры ASCII + 0x0E + 5 байт целого
    return str(n).encode() + bytes([0x0E, 0, 0, n & 255, n >> 8, 0])
def line(no, body): body += b"\r"; return struct.pack(">H", no) + struct.pack("<H", len(body)) + body
CLEAR, LOAD, CODE, RANDOMIZE, USR, REM = 0xFD, 0xEF, 0xAF, 0xF9, 0xC0, 0xEA
NAME = sys.argv[3] if len(sys.argv) > 3 else "penttest"
USRA = int(sys.argv[4]) if len(sys.argv) > 4 else 32768
NOTE = sys.argv[5] if len(sys.argv) > 5 else "PENTTEST - Pentagon timing test; timing core by Jan Bobrowski (GPL)"
prog = line(1, bytes([REM]) + b" " + NOTE.encode())
prog += line(10, bytes([CLEAR]) + num(24575) + b":" + bytes([LOAD]) + b'""' + bytes([CODE]) + b":" + bytes([RANDOMIZE, USR]) + num(USRA))
def block(flag, data):
    c = flag
    for b in data: c ^= b
    d = bytes([flag]) + data + bytes([c])
    return struct.pack("<H", len(d)) + d
def header(typ, name, length, p1, p2):
    return bytes([typ]) + name.ljust(10).encode()[:10] + struct.pack("<HHH", length, p1, p2)
code = open(sys.argv[1], "rb").read()
tap = block(0, header(0, NAME, len(prog), 10, len(prog))) + block(0xFF, prog)
tap += block(0, header(3, NAME, len(code), 32768, 32768)) + block(0xFF, code)
open(sys.argv[2], "wb").write(tap); print(sys.argv[2], len(tap), "bytes, code", len(code))
