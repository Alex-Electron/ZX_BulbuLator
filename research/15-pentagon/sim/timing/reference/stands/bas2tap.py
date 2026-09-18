#!/usr/bin/env python3
"""bas2tap.py — minimal replacement for `mktap -b NAME AUTOSTART < prog.bas > out.tap`
(Jan Bobrowski's mktap, used by zxtests3/Makefile).

Input format (mktap style): a line starting with a number opens a BASIC line;
following lines without a number are appended to it with ':'.
Output: a TAP file with a single "Program:" header + data block.

Usage: bas2tap.py NAME AUTOSTART < prog.bas > prog.tap
"""
import re
import struct
import sys

# Sinclair BASIC keyword tokens 0xA3..0xFF (48K set; 0xA3/0xA4 are 128K SPECTRUM/PLAY)
KEYWORDS = {
    0xA3: "SPECTRUM", 0xA4: "PLAY",
    0xA5: "RND", 0xA6: "INKEY$", 0xA7: "PI", 0xA8: "FN", 0xA9: "POINT",
    0xAA: "SCREEN$", 0xAB: "ATTR", 0xAC: "AT", 0xAD: "TAB", 0xAE: "VAL$",
    0xAF: "CODE", 0xB0: "VAL", 0xB1: "LEN", 0xB2: "SIN", 0xB3: "COS",
    0xB4: "TAN", 0xB5: "ASN", 0xB6: "ACS", 0xB7: "ATN", 0xB8: "LN",
    0xB9: "EXP", 0xBA: "INT", 0xBB: "SQR", 0xBC: "SGN", 0xBD: "ABS",
    0xBE: "PEEK", 0xBF: "IN", 0xC0: "USR", 0xC1: "STR$", 0xC2: "CHR$",
    0xC3: "NOT", 0xC4: "BIN", 0xC5: "OR", 0xC6: "AND", 0xC7: "<=",
    0xC8: ">=", 0xC9: "<>", 0xCA: "LINE", 0xCB: "THEN", 0xCC: "TO",
    0xCD: "STEP", 0xCE: "DEF FN", 0xCF: "CAT", 0xD0: "FORMAT", 0xD1: "MOVE",
    0xD2: "ERASE", 0xD3: "OPEN #", 0xD4: "CLOSE #", 0xD5: "MERGE", 0xD6: "VERIFY",
    0xD7: "BEEP", 0xD8: "CIRCLE", 0xD9: "INK", 0xDA: "PAPER", 0xDB: "FLASH",
    0xDC: "BRIGHT", 0xDD: "INVERSE", 0xDE: "OVER", 0xDF: "OUT", 0xE0: "LPRINT",
    0xE1: "LLIST", 0xE2: "STOP", 0xE3: "READ", 0xE4: "DATA", 0xE5: "RESTORE",
    0xE6: "NEW", 0xE7: "BORDER", 0xE8: "CONTINUE", 0xE9: "DIM", 0xEA: "REM",
    0xEB: "FOR", 0xEC: "GO TO", 0xED: "GO SUB", 0xEE: "INPUT", 0xEF: "LOAD",
    0xF0: "LIST", 0xF1: "LET", 0xF2: "PAUSE", 0xF3: "NEXT", 0xF4: "POKE",
    0xF5: "PRINT", 0xF6: "PLOT", 0xF7: "RUN", 0xF8: "SAVE", 0xF9: "RANDOMIZE",
    0xFA: "IF", 0xFB: "CLS", 0xFC: "DRAW", 0xFD: "CLEAR", 0xFE: "RETURN",
    0xFF: "COPY",
}
# mktap-style spellings without the space (zxtests3 uses "GOSUB 2000")
ALIASES = {"GOSUB": 0xED, "GOTO": 0xEC, "DEFFN": 0xCE}
# longest first so "GO SUB" beats "GO", "INKEY$" beats "IN", "<=" beats "<"
KW_SORTED = sorted(list(KEYWORDS.items()) + [(t, k) for k, t in ALIASES.items()],
                   key=lambda kv: -len(kv[1]))
ALNUM = re.compile(r"[A-Za-z0-9$]")
NUM_RE = re.compile(r"\d+(\.\d*)?([Ee][+-]?\d+)?|\.\d+([Ee][+-]?\d+)?")


def zx_number(text):
    """5-byte ZX Spectrum numeric form for a literal."""
    v = float(text)
    if v == int(v) and 0 <= int(v) <= 65535:
        n = int(v)
        return bytes([0x00, 0x00, n & 0xFF, (n >> 8) & 0xFF, 0x00])
    if v == 0:
        return bytes(5)
    sign = 0x80 if v < 0 else 0
    v = abs(v)
    e = 0
    while v >= 1.0:
        v /= 2.0
        e += 1
    while v < 0.5:
        v *= 2.0
        e -= 1
    m = int(round(v * (1 << 32)))
    if m >= (1 << 32):
        m >>= 1
        e += 1
    m &= 0x7FFFFFFF
    m |= sign << 24
    return bytes([e + 128]) + struct.pack(">I", m)


def tokenize(src):
    out = bytearray()
    i = 0
    n = len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(ord(c))
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(ord(c))
            i += 1
            continue
        # keyword?
        matched = False
        for tok, kw in KW_SORTED:
            if src.startswith(kw, i):
                # word keywords need a boundary before and after
                if kw[0].isalpha():
                    before_ok = (i == 0) or not ALNUM.match(src[i - 1])
                    j = i + len(kw)
                    after_ok = (j >= n) or not ALNUM.match(src[j])
                    if not (before_ok and after_ok):
                        continue
                out.append(tok)
                i += len(kw)
                if i < n and src[i] == " ":
                    i += 1  # the listing space after a keyword is not stored
                if tok == 0xEA:  # REM: rest of line is literal
                    out.extend(src[i:].encode("latin-1"))
                    i = n
                matched = True
                break
        if matched:
            continue
        # number literal (not part of an identifier)
        m = NUM_RE.match(src, i)
        if m and (i == 0 or not re.match(r"[A-Za-z$]", src[i - 1])):
            lit = m.group(0)
            out.extend(lit.encode("ascii"))
            out.append(0x0E)
            out.extend(zx_number(lit))
            i = m.end()
            continue
        out.append(ord(c))
        i += 1
    return bytes(out)


def parse_bas(text):
    lines = []  # (number, content)
    cur = None
    for raw in text.splitlines():
        if not raw.strip():
            continue
        m = re.match(r"\s*(\d+)\s(.*)$", raw) or re.match(r"\s*(\d+)$", raw)
        if m:
            if cur:
                lines.append(cur)
            num = int(m.group(1))
            body = m.group(2).strip() if m.lastindex and m.lastindex >= 2 else ""
            cur = [num, body]
        else:
            if cur is None:
                raise SystemExit("continuation line before any numbered line: %r" % raw)
            cur[1] = cur[1] + ":" + raw.strip() if cur[1] else raw.strip()
    if cur:
        lines.append(cur)
    return lines


def tap_block(flag, data):
    body = bytes([flag]) + data
    chk = 0
    for b in body:
        chk ^= b
    body += bytes([chk])
    return struct.pack("<H", len(body)) + body


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    name = sys.argv[1][:10].ljust(10)
    autostart = int(sys.argv[2])
    prog = bytearray()
    for num, body in parse_bas(sys.stdin.read()):
        data = tokenize(body) + b"\r"
        prog += struct.pack(">H", num) + struct.pack("<H", len(data)) + data
    header = bytes([0]) + name.encode("latin-1") + struct.pack("<HHH", len(prog), autostart, len(prog))
    sys.stdout.buffer.write(tap_block(0x00, header) + tap_block(0xFF, bytes(prog)))


if __name__ == "__main__":
    main()
