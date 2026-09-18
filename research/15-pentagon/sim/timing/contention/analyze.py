#!/usr/bin/env python3
"""analyze.py - разбор логов стенда контеншена (logs/run_*.log) и сверка с fuse_model.py.

Якорь: t = k - KACC0, где k - номер импульса pe3M5 от спада Video.irq (k=1 - первый после спада),
KACC0 = 2 - самое раннее k приёма прерывания процессором (измерено: kacc min = 2 во всех прогонах 48K/128K).
В этих единицах t=0 = первый такт кадра по Fuse (прерывание принято, если команда кончилась на t=0).
"""
import re, sys, glob, os
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuse_model import expect_access, delay, MACH

KACC0 = 2
ACC_RE = re.compile(r'^ACC k=(\d+) kacc=(-?\d+) hUla=(\d+) vCount=(\d+) a=([0-9a-f]{4})\s+(IO|MEM)-(RD|WR) pe=(\d+) pc=(\d+) lost=(\d+) lostk=(.*)$')
FR_RE = re.compile(r'^FRAME (\d+): pe3M5=(\d+) pc3M5=(\d+) потеряно=(\d+) \(в строках бумаги (\d+)\) M1=(\d+) первый потерянный k в кадре=(-?\d+) kacc=(-?\d+)')


def args_of(lines):
    for l in lines:
        if l.startswith('# xsim'):
            return dict(re.findall(r'-testplusarg (\w+)=(\S+)', l))
    return {}


def load(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = [l.rstrip('\n') for l in f]
    return args_of(lines), lines


def analyze_isr(path, zones=None, full=False):
    a, lines = load(path)
    mach = '128' if a.get('MACHINE') == '128' else '48'
    instr = a.get('INSTR', 'RD')
    port = int(a.get('PORT', '7FFD'), 16); aval = int(a.get('AVAL', '02'), 16)
    hlv = int(a.get('HLV', '4000'), 16); p7ffd = int(a.get('P7FFD', '0'), 16)
    if instr in ('RD', 'WR', 'INCHL'):
        tgt = hlv; kind = 'MEM'
    elif instr in ('OUTFE', 'INFE'):
        tgt = (aval << 8) | 0xFE; kind = 'IO'
    else:
        tgt = port; kind = 'IO'
    rows = []; kacc_line = ''
    for l in lines:
        m = ACC_RE.match(l)
        if m:
            k, kacc, hula, vc, ad, kd, rw, pe, pc, lost, lostk = m.groups()
            if int(ad, 16) != tgt or kd != kind or int(kacc) < 0:   # до первого /INT k не привязан к прерыванию
                continue
            k = int(k); t = k - KACC0
            exp_lost, exp_len = expect_access(instr, t, mach, port, aval, p7ffd & 7)
            rows.append(dict(k=k, t=t, hula=int(hula), vc=int(vc), lost=int(lost), pe=int(pe), pc=int(pc),
                             exp=exp_lost, explen=exp_len, ok=(int(lost) == exp_lost and int(pe) == exp_len), lostk=lostk.strip()))
        if l.startswith('SWEEP DONE'):
            kacc_line = l
    rows.sort(key=lambda r: r['t'])
    # дубликаты по t (одинаковый t из разных кадров) - сверить одинаковость
    byt = defaultdict(list)
    for r in rows: byt[r['t']].append(r)
    n_ok = sum(1 for r in rows if r['ok']); n_bad = len(rows) - n_ok
    hdr = f"### {mach}K {instr}" + (f" порт {tgt:04X}" if kind == 'IO' else f" адрес {tgt:04X}") + (f" (7FFD={p7ffd:02X})" if mach == '128' else '')
    out = [hdr, '', f"Лог: `{os.path.basename(path)}`; {len(rows)} доступов к цели, совпали с моделью: {n_ok}, расхождений: {n_bad}; "
           f"диапазон t: {rows[0]['t'] if rows else '-'}..{rows[-1]['t'] if rows else '-'}; {kacc_line}", '']
    if n_bad:
        out.append('Расхождения:'); out.append('')
        out.append('| t | k | hUla | vCount | потеряно RTL | ожидание Fuse | длина RTL | длина ожид. | потерянные k |')
        out.append('|---|---|---|---|---|---|---|---|---|')
        for r in rows:
            if not r['ok']:
                out.append(f"| {r['t']} | {r['k']} | {r['hula']} | {r['vc']} | {r['lost']} | {r['exp']} | {r['pe']} | {r['explen']} | {r['lostk']} |")
        out.append('')
    sel = rows if full else [r for r in rows if zones and any(z0 <= r['t'] <= z1 for z0, z1 in zones)]
    if sel:
        out.append('| t (T от INT) | k | hUla | vCount | потеряно (RTL) | ожидание (Fuse) | длина интервала RTL / ожид. | совп. | потерянные k |')
        out.append('|---|---|---|---|---|---|---|---|---|')
        seen = set()
        for r in sel:
            key = (r['t'], r['lost'], r['pe'])
            if key in seen: continue
            seen.add(key)
            out.append(f"| {r['t']} | {r['k']} | {r['hula']} | {r['vc']} | {r['lost']} | {r['exp']} | {r['pe']} / {r['explen']} | {'да' if r['ok'] else 'НЕТ'} | {r['lostk']} |")
        out.append('')
    # гистограмма по фазе (t - base) mod 8 внутри окна
    base = MACH[mach]['base']
    ph = defaultdict(set)
    for r in rows:
        rel = r['t'] - base
        if rel >= 0 and (rel % MACH[mach]['line']) < 128 and (rel // MACH[mach]['line']) < 192:
            ph[rel % 8].add((r['lost'], r['exp']))
    if ph:
        out.append('Потери по фазе начала T1 (t − ' + str(base) + ') mod 8 внутри окна (RTL/модель, все встреченные пары): ' +
                   ', '.join(f"{p}: {'/'.join(f'{a}/{b}' for a, b in sorted(ph[p]))}" for p in sorted(ph)))
        out.append('')
    return '\n'.join(out), rows


def analyze_frames(path):
    a, lines = load(path)
    out = [f"### {a.get('MACHINE')} {os.path.basename(path)}", '']
    frs = [FR_RE.match(l).groups() for l in lines if FR_RE.match(l)]
    if frs:
        out.append('| кадр | pe3M5 | pc3M5 | потеряно | в строках бумаги | M1 | первый потерянный k | kacc |')
        out.append('|---|---|---|---|---|---|---|---|')
        for g in frs:
            out.append('| ' + ' | '.join(g) + ' |')
        out.append('')
    win = False
    for l in lines:
        if l.startswith('WINLINE'): win = True
        if win:
            out.append('    ' + l)
            if 'первый импульс pe3M5 с vduC=1 на строке' in l: win = False
        if l.startswith('CONT ИТОГ') or l.startswith('tb_cont: cpuck') or l.startswith('tb_cont: hc'):
            out.append(l)
    out.append('')
    return '\n'.join(out), frs


if __name__ == '__main__':
    logs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs', 'run_*.log')))
    for p in logs:
        a, lines = load(p)
        if 'ISR' in a and 'CHAIN' in a:
            txt, rows = analyze_isr(p, zones=[(14325, 14350), (14455, 14470), (14555, 14570), (14355, 14375), (14485, 14495),
                                              (14585, 14595), (57110, 57125), (57335, 57350)])
            print(txt)
        elif 'FRAMESTAT' in a:
            txt, frs = analyze_frames(p)
            print(txt)
