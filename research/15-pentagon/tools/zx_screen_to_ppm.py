#!/usr/bin/env python3
"""Convert a raw 6912-byte ZX Spectrum screen dump to a portable PPM image."""

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} screen.bin screen.ppm", file=sys.stderr)
        return 2

    src = pathlib.Path(sys.argv[1]).read_bytes()
    if len(src) < 6912:
        print(f"screen dump is {len(src)} bytes; expected at least 6912", file=sys.stderr)
        return 2

    width, height = 256, 192
    normal = (
        (0, 0, 0),
        (0, 0, 215),
        (215, 0, 0),
        (215, 0, 215),
        (0, 215, 0),
        (0, 215, 215),
        (215, 215, 0),
        (215, 215, 215),
    )
    bright = (
        (0, 0, 0),
        (0, 0, 255),
        (255, 0, 0),
        (255, 0, 255),
        (0, 255, 0),
        (0, 255, 255),
        (255, 255, 0),
        (255, 255, 255),
    )
    pixels = bytearray(width * height * 3)

    for y in range(height):
        for byte_x in range(32):
            bitmap_addr = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2) | byte_x
            bitmap = src[bitmap_addr]
            attr = src[6144 + (y >> 3) * 32 + byte_x]
            palette = bright if attr & 0x40 else normal
            ink = palette[attr & 0x07]
            paper = palette[(attr >> 3) & 0x07]
            for bit in range(8):
                color = ink if bitmap & (0x80 >> bit) else paper
                offset = (y * width + byte_x * 8 + bit) * 3
                pixels[offset : offset + 3] = bytes(color)

    pathlib.Path(sys.argv[2]).write_bytes(
        f"P6\n{width} {height}\n255\n".encode("ascii") + pixels
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
