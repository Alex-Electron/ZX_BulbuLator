#!/usr/bin/env python3
"""pasmo .bin (org 0) -> 65536-line $readmemh file"""
import sys
data = open(sys.argv[1], 'rb').read()
data = data + b'\0' * (65536 - len(data))
with open(sys.argv[2], 'w') as f:
    for b in data:
        f.write('%02x\n' % b)
print('%s: %d bytes' % (sys.argv[1], len(open(sys.argv[1],'rb').read())))
