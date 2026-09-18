#!/usr/bin/env python3
"""parse.py - разбор логов стенда бордюра (BM-строки) в таблицы markdown.
   parse.py <MACHINE> [--jitter] logs/run_*.log ...
Единицы: T = импульсы pc3M5/pe3M5 в [E_int, E_wr); колонка = hc пикселя (0..447/455); линия = vc.
Δpx = (vis_line - wr_line)*LINE + vis_col - wr_col, где wr_col = пиксель, начавшийся на фронте записи."""
import re, sys, collections

def colour_name(c):   # код монитора {i,r,g,b}
    i, r, g, b = (c >> 3) & 1, (c >> 2) & 1, (c >> 1) & 1, c & 1
    zx = (g << 2) | (r << 1) | b
    return zx

def parse(path):
    ev = []
    for ln in open(path, encoding='utf-8', errors='replace'):
        if not ln.startswith('BM '): continue
        kind = ln.split()[1]
        d = dict(re.findall(r'(\w+)=(-?[0-9a-fA-Fx]+)', ln))
        mc = re.search(r'colour=(\d+)->(\d+)', ln)
        if mc: d['c_old'], d['c_new'] = int(mc.group(1)), int(mc.group(2))
        ev.append((kind, d))
    return ev

def q_to_code(q):
    q = int(q, 16); g, r, b = (q >> 2) & 1, (q >> 1) & 1, q & 1
    return (r << 2) | (g << 1) | b   # {i=0,r,g,b}

def analyse(path, LINE):
    ev = parse(path)
    m = re.search(r'k(\d+)\.bin', path); k = int(m.group(1)) if m else -1
    ints = [d for kind, d in ev if kind == 'INT']
    cirq = [d for kind, d in ev if kind == 'CIRQ']
    rows = []
    # для каждой записи: первая PIX после неё с новым цветом == записанному
    for idx, (kind, d) in enumerate(ev):
        if kind != 'WR' or int(d['int']) == 0: continue
        want = q_to_code(d['q'])
        vis = None; latch = None; wrend = None
        for kind2, d2 in ev[idx+1:]:
            if kind2 == 'WR': break
            if kind2 == 'WREND' and wrend is None: wrend = d2
            if kind2 == 'LATCH' and latch is None: latch = d2
            if kind2 == 'PIX':
                new = d2['c_new']
                if new == want and d2['wr_tpc'] == d['T_pc']:
                    vis = d2; break
        r = dict(k=k, intn=int(d['int']), wr=int(d['wr']), frame=int(d['frame']), wr_line=int(d['line']), wr_hc=int(d['hc']),
                 T_pc=int(d['T_pc']), T_pe=int(d['T_pe']), T_pc_c=int(d['T_pc_c']), q=int(d['q'],16)&7,
                 contend=d['contend'], cn=d['cn'])
        if latch is None:
            vis = None   # запись не сменила цвет (border уже был таким) - защёлка не сработала
        if vis:
            r.update(vis_line=int(vis['line']), vis_col=int(vis['col']), px_since_wr=int(vis['px_since_wr']))
            r['dpx'] = (r['vis_line'] - r['wr_line']) * LINE + r['vis_col'] - r['wr_hc']
        else:
            r.update(vis_line=None, vis_col=None, dpx=None, px_since_wr=None)
        r['wrend_hc'] = int(wrend['hc']) if wrend else None
        r['latch_hc'] = int(latch['hc']) if latch else None
        r['latch_ce'] = int(latch['ce']) if latch else None
        rows.append(r)
    return k, ints, cirq, rows

def fmt(v): return '-' if v is None else str(v)

if __name__ == '__main__':
    M = sys.argv[1]; args = sys.argv[2:]
    jitter = '--jitter' in args; args = [a for a in args if a != '--jitter']
    LINE = 456 if M == '128' else 448
    PAPER0 = 14 if M == 'PENT' else 12
    allrows = []
    for p in sorted(args, key=lambda s: int(re.search(r'k(\d+)\.bin', s).group(1))):
        k, ints, cirq, rows = analyse(p, LINE)
        allrows.append((k, ints, cirq, rows))
    # шапка: положение INT
    k0, ints, cirq, rows = allrows[0]
    print(f"INT (сырой Video.irq) виден: " + '; '.join(f"#{d['n']}: line={d['line']} hc={d['hc']} ce={d['ce']}" for d in ints[:3]))
    print(f"cpu_irq виден через T_pc={cirq[0]['T_pc_since_int']} после /INT (hc={cirq[0]['hc']})" if cirq else '')
    print()
    print("| k | wr | кадр | T_pc от /INT | T_pe от /INT | удерж. T | запись: строка/hc | wr_hc mod 8 | цвет | виден: строка/кол | Δpx | кол−бумага | кол mod 8 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k, ints, cirq, rows in allrows:
        sel = rows if jitter else [r for r in rows if r['wr'] in (2, 3)]
        # без --jitter: свернуть одинаковые кадры
        seen = set()
        for r in sel:
            key = (r['wr'], r['T_pc'], r['wr_hc'], r['vis_col'], r['vis_line'])
            if not jitter and key in seen: continue
            seen.add(key)
            rel = None if r['vis_col'] is None else r['vis_col'] - PAPER0
            print(f"| {k} | {r['wr']} | {r['frame']} | {r['T_pc']} | {r['T_pe']} | {r['T_pe']-r['T_pc']} | {r['wr_line']}/{r['wr_hc']} | {r['wr_hc']%8} | {r['q']} | {fmt(r['vis_line'])}/{fmt(r['vis_col'])} | {fmt(r['dpx'])} | {fmt(rel)} | {fmt(None if r['vis_col'] is None else r['vis_col']%8)} |")
    if not jitter:
        print()
        print("Проверка стабильности по кадрам (число разных (T_pc, wr_hc, vis) на k/wr):")
        for k, ints, cirq, rows in allrows:
            var = collections.defaultdict(set)
            for r in rows: var[r['wr']].add((r['T_pc'], r['wr_hc'], r['vis_line'], r['vis_col']))
            bad = {w: len(s) for w, s in var.items() if len(s) > 1}
            if bad: print(f"  k={k}: РАЗНЫЕ значения по кадрам: {bad}")
        print("  (если строк выше нет - все кадры дали одно и то же)")
