#!/usr/bin/env python3
"""Reusable ZX Spectrum screen renderer for the 6912-byte mirror (GP0+0x8000 dump).

Shared by the tape verdict tooling and the snow multi-frame differ so the pixel
decode lives in exactly one place. 6144 bytes bitmap (interleaved ZX layout) +
768 bytes attributes; emits a P6 PPM (feed to ffmpeg for PNG).

CLI:  zxscr.py <in.bin> <out.ppm> [scale]
API:  render(data:bytes, scale:int=2) -> bytes(ppm)
      attr_cells(data:bytes) -> list[int] of 768 attribute bytes
"""
import sys

_PAL  = [(0,0,0),(0,0,215),(215,0,0),(215,0,215),(0,215,0),(0,215,215),(215,215,0),(215,215,215)]
_PALB = [(0,0,0),(0,0,255),(255,0,0),(255,0,255),(0,255,0),(0,255,255),(255,255,0),(255,255,255)]

def render(d, scale=2):
    W, H, S = 256, 192, scale
    img = bytearray(W*S*H*S*3)
    for y in range(H):
        base = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
        arow = 6144 + (y >> 3)*32
        for xc in range(32):
            b = d[base | xc]
            a = d[arow + xc]
            ink, paper, bright = a & 7, (a >> 3) & 7, (a >> 6) & 1
            pal = _PALB if bright else _PAL
            for bit in range(8):
                c = pal[ink] if (b >> (7-bit)) & 1 else pal[paper]
                x = xc*8 + bit
                for dy in range(S):
                    row = (y*S+dy)*W*S
                    for dx in range(S):
                        o = (row + x*S+dx)*3
                        img[o:o+3] = bytes(c)
    return b"P6\n%d %d\n255\n" % (W*S, H*S) + bytes(img)

def column_fingerprint(d):
    """Per 8-px column (32 of them), a hash of its 192 bitmap bytes. Snow corrupts
    specific COLUMNS; comparing this vector across frames tells static-snow (same
    columns dirty every frame) from flicker (dirty set wanders)."""
    cols = []
    for xc in range(32):
        h = 0
        for y in range(192):
            base = ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)
            h = (h*131 + d[base | xc]) & 0xFFFFFFFF
        cols.append(h)
    return cols

if __name__ == "__main__":
    d = open(sys.argv[1], "rb").read()
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    open(sys.argv[2], "wb").write(render(d, scale))
    print(f"rendered {sys.argv[1]} -> {sys.argv[2]} ({len(d)}B, scale {scale})")
