#!/usr/bin/env python3
"""Собрать протокол Timing Tests: периодический OCR экрана, накопление уникальных блоков."""
import subprocess, time, sys, re
seen=[]; last=None
N=int(sys.argv[1]) if len(sys.argv)>1 else 60
for i in range(N):
    out=subprocess.run([sys.executable,"zocr.py"],capture_output=True,text=True).stdout
    lines=[l.rstrip() for l in out.split("\n")]
    for l in lines:
        if not l.strip(): continue
        if l not in seen: seen.append(l)
    time.sleep(3)
print("\n".join(seen))
