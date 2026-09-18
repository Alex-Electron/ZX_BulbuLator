#!/usr/bin/env python3
# sweep_table.py - разобрать лог стенда tb_ports (свип fbus.asm) в markdown-таблицу.
#   python3 sweep_table.py <лог> <машина 48|128|PENT> <порт>
# Каждый кадр даёт два IORD: нечётный = первая защёлка (W1), чётный = вторая (W2). Колонки: k, T от
# спада /INT (pe3M5 в момент защёлки T80 = последний nc3M5 цикла IN), vCount/hCount растра в этот
# момент, байт D на шине, расшифровка по заливке SCRFILL (битмап {0,треть,кол} / атрибут
# {1,строка[0],0,кол}), ожидание по опубликованному узору 48K (данные на T = B+8n+0..3 от опорного
# B = 14336(+224*100), FF иначе) и совпадение.
import re, sys
log, mach, port = sys.argv[1], sys.argv[2], sys.argv[3]
base = {'48': 14336, '128': 14362, 'PENT': None}[mach]
tpl  = {'48': 224, '128': 228, 'PENT': 224}[mach]
rows = []
for l in open(log, errors='replace'):
    m = re.search(r'IORD #(\d+) A=([0-9a-f]+) D=([0-9a-f]+) vduQ=([0-9a-f]+) nc3M5=(\d+) \| latch: hc=(\d+) vc=(\d+) h_rel=(\d+) v_rel=(\d+) \| from INT: latch \d+ mclk \((\d+) pe3M5', l)
    if m:
        n = int(m.group(1)); rows.append(dict(n=n, k=(n-1)//2, w=1 if n % 2 else 2, a=m.group(2), d=int(m.group(3),16),
            q=int(m.group(4),16), nc=int(m.group(5)), hc=int(m.group(6)), vc=int(m.group(7)), hr=int(m.group(8)), vr=int(m.group(9)), T=int(m.group(10))))
def decode(b):
    if b == 0xFF: return 'FF'
    if b & 0x80: return f'атр кол {b & 0x1F} (строка[0]={(b>>6)&1})'
    return f'битмап кол {b & 0x1F} (треть {(b>>5)&3})'
def expect(T, line):
    t = T - (base + tpl*line)
    if t < 0 or t >= 128: return 'FF', 0xFF
    n, ph = divmod(t, 8)
    return [f'битмап кол {2*n}', f'атр кол {2*n}', f'битмап кол {2*n+1}', f'атр кол {2*n+1}', 'FF','FF','FF','FF'][ph], None
for w, line in ((1, 0), (2, 100)):
    sel = [r for r in rows if r['w'] == w]
    if not sel: continue
    if mach == 'PENT':
        print(f"\n### Пентагон, порт {port}, защёлка {w} ({'бордюр, строка 293' if w==1 else 'бумага, строка 60 = v_rel 0'})\n")
        print("| k | T от /INT | vCount | hCount | h_rel | v_rel | D (что получил Z80) | vduQ (что дала бы плавающая шина) |")
        print("|---|---|---|---|---|---|---|---|")
        for r in sel:
            print(f"| {r['k']} | {r['T']} | {r['vc']} | {r['hc']} | {r['hr']} | {r['vr']} | {r['d']:02X} | {r['q']:02X} = {decode(r['q'])} |")
        continue
    print(f"\n### {mach}K, порт {port}, строка {line} (опорная точка B = {base + tpl*line} = {base}{' + '+str(tpl)+'*'+str(line) if line else ''})\n")
    print("| k | T от /INT | T − B | vCount | hCount | D | расшифровка (наш узор) | ожидание (узор от B) | совпало |")
    print("|---|---|---|---|---|---|---|---|---|")
    hits = tot = 0
    for r in sel:
        e, _ = expect(r['T'], line)
        d = decode(r['d'])
        ok = (d.startswith(e) if e != 'FF' else d == 'FF')
        hits += ok; tot += 1
        print(f"| {r['k']} | {r['T']} | {r['T'] - base - tpl*line:+d} | {r['vc']} | {r['hc']} | {r['d']:02X} | {d} | {e} | {'да' if ok else 'НЕТ'} |")
    print(f"\nСовпадений с узором от B: {hits} из {tot}.")
    # узор дословно
    print("\nНаш узор дословно (T от /INT : байт): " + ", ".join(f"{r['T']}:{r['d']:02X}" for r in sel))
