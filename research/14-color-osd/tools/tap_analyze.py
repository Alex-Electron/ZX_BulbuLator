#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tap_analyze.py - dump the block structure of a ZX .tap file to diagnose loading behaviour.

A .tap is a flat sequence of blocks: [len_lo][len_hi][ N bytes ]. The N bytes start with a flag
byte (0x00 = ROM header, 0xFF = ROM data) and end with an XOR checksum. Standard ROM loading
replays each block as pilot+sync+data pulses. Non-standard flags, bad checksums, or unusual block
sizes hint at why a particular tape misbehaves (multi-load, custom loader, headerless turbo, etc.).
Contact: lavrinovich.alex@gmail.com
"""
import sys, os

HDR_TYPE = {0: "Program", 1: "Num array", 2: "Char array", 3: "Bytes/Code"}

def analyze(path):
    data = open(path, "rb").read()
    print("== %s  (%d bytes) ==" % (os.path.basename(path), len(data)))
    p = 0; blk = 0; total_data = 0
    while p + 2 <= len(data):
        n = data[p] | (data[p+1] << 8)
        body = data[p+2 : p+2+n]
        if n == 0:
            print("  [%2d] @%-6d len=0  (EMPTY block - suspicious)" % (blk, p)); p += 2; blk += 1; continue
        if len(body) < n:
            print("  [%2d] @%-6d len=%d  TRUNCATED (only %d bytes left)" % (blk, p, n, len(body))); break
        flag = body[0]
        chk_stored = body[-1] if n >= 2 else None
        chk_calc = 0
        for b in body[:-1]: chk_calc ^= b
        chk_ok = (chk_calc == chk_stored) if n >= 2 else False
        ftxt = {0x00: "HEADER", 0xFF: "DATA"}.get(flag, "flag=0x%02X (NON-STANDARD)" % flag)
        note = "" if chk_ok else "  ** CHECKSUM MISMATCH (calc %02X vs %02X) **" % (chk_calc, chk_stored if chk_stored is not None else 0)
        extra = ""
        if flag == 0x00 and n >= 19:                       # ROM header: type, 10-char name, len, p1, p2
            htype = body[1]; name = bytes(body[2:12]).decode("latin1").rstrip()
            blen = body[13] | (body[14] << 8)
            extra = "  type=%s name='%s' datalen=%d" % (HDR_TYPE.get(htype, "?%d" % htype), name, blen)
        print("  [%2d] @%-6d len=%-6d %s%s%s" % (blk, p, n, ftxt, extra, note))
        if flag == 0xFF or flag not in (0x00, 0xFF): total_data += n
        p += 2 + n; blk += 1
    tail = len(data) - p
    print("  -> %d blocks, %d data bytes; %s" % (blk, total_data,
          ("clean end" if tail == 0 else "%d trailing bytes (not a whole block!)" % tail)))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: tap_analyze.py <file.tap> [more.tap ...]"); sys.exit(1)
    for f in sys.argv[1:]:
        analyze(f); print()
