#!/usr/bin/env python3
"""make_result.py - собрать RESULT.md из фрагментов и разбора логов (запускать на ThinkPad в каталоге contention/)."""
import glob, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze import analyze_isr, load, FR_RE
from fuse_model import run_loop, prog_contrun, prog_contrun_out, run_contrun_rd, MACH

HERE = os.path.dirname(os.path.abspath(__file__))
FR = lambda n: open(os.path.join(HERE, n), encoding='utf-8').read()

ZONES48 = [(14325, 14350), (14455, 14470), (14555, 14570), (57110, 57125), (57335, 57350)]
ZONES128 = [(14355, 14375), (14485, 14495), (14585, 14595)]

def section3():
    out = ['## 3. (a)/(b) Таблицы «смещение T от INT → задержка» по командам', '',
           'Метод. Программа `prog/im2sweep.asm` в НЕконтендуемом ОЗУ 0x8000 (банк 2): `IM 2`, `EI; HALT`. Обработчик по',
           '0x8383 собирает стенд (`build_handler`): `JP` → паддинг PADT тактов (циклы `LD B,n/DJNZ` + `NOP/INC DE/LD E,n/LD R,A`,',
           'всё в 0x83xx) → `LD A,AVAL; LD BC,PORT` → измеряемая команда по 0x8400 → ещё 8 блоков `LD A,AVAL; паддинг с остатком',
           'j mod 8 (0,9,6,7,4,13,10,11 T); команда` → `NOP EI RET`. После задержки контеншена фаза выравнивается, поэтому блок j',
           'попадает в фазу j+const — за один кадр снимаются все 8 фаз узора, а PADT растёт на 1 с каждым прерыванием и даёт',
           'соседние t с шагом 1. Решётка `HALT` (4 T) удерживается: на `RET` стенд дописывает по 0x8370 компенсацию, чтобы путь',
           '«приём INT → следующий HALT» был кратен 4 (kacc одинаков во всех кадрах свипа, `SWEEP DONE ... kacc min/max`).',
           'Прибор (`ACCLOG=1`): каждый интервал шины с контендуемым адресом или циклом ввода-вывода — k импульса, начавшего его T1,',
           'hUla/vCount в этот момент, длина в `pe3M5`, число погашенных импульсов и их k. Сверка: `fuse_model.expect_access`',
           '(правила из задания) при t = k − 2. Полные таблицы всех доступов — `python3 analyze.py` в каталоге; здесь — зоны краёв',
           '(начало окна, конец окна первой строки, начало следующей строки, строки 191/192) и сводка по фазам.', '']
    logs = sorted(glob.glob(os.path.join(HERE, 'logs', 'run_*.log')))
    summ = []
    for p in logs:
        a, lines = load(p)
        if not ('ISR' in a and 'CHAIN' in a) or 'NOCOMP' in a or 'RESETUS' in a:
            continue
        if 'SWEEP=2_' in p or 'SWEEP=3_' in p:
            continue   # дымовые прогоны
        zones = ZONES128 if a.get('MACHINE') == '128' else ZONES48
        txt, rows = analyze_isr(p, zones=zones)
        out.append(txt)
        n_ok = sum(1 for r in rows if r['ok'])
        summ.append((a.get('MACHINE'), a.get('INSTR'), a.get('PORT', ''), a.get('HLV', ''), a.get('P7FFD', ''), len(rows), n_ok,
                     (rows[0]['t'], rows[-1]['t']) if rows else ('-', '-')))
    tbl = ['### Сводка по всем свипам', '', '| машина | команда | цель | доступов | совпало с моделью | расхождений | t мин..макс |', '|---|---|---|---|---|---|---|']
    for m, i, port, hlv, p7, n, ok, (t0, t1) in summ:
        tgt = f'порт {port or ("02FE" if i in ("OUTFE","INFE") else "7FFD")}' if i in ('OUTFE', 'INFE', 'OUTC', 'INC') else f'адрес {hlv or "4000"}'
        if m == '128': tgt += f' (7FFD={p7 or "00"})'
        tbl.append(f'| {m}K | {i} | {tgt} | {n} | {ok} | {n - ok} | {t0}..{t1} |')
    return '\n'.join(tbl + [''] + out)

def frames(pattern):
    res = {}
    for p in glob.glob(os.path.join(HERE, 'logs', pattern)):
        a, lines = load(p)
        res[os.path.basename(p)] = [tuple(int(x) for x in FR_RE.match(l).groups()) for l in lines if FR_RE.match(l)]
    return res

def section_c():
    txt = FR('RESULT_c.md')
    fr = frames('run_MACHINE=48_PROG=prog-contrun_out.bin_ORG=8000_FRAMESTAT=1_QUIET=1_RUNUS=90000.log')
    per = run_loop(prog_contrun_out()[0], '48')
    if fr:
        f = list(fr.values())[0]
        rtl_lost = ' / '.join(str(x[3]) for x in f[1:4]); rtl_m1 = ' / '.join(str(x[5]) for x in f[1:4])
        tpi_rtl = 69888 * 3 / f[1][5] if len(f) > 1 else 0
    else:
        rtl_lost = rtl_m1 = 'нет данных'; tpi_rtl = 0
    mdl_lost = ' / '.join(str(x[1]) for x in per[1:4]); mdl_m1 = ' / '.join(str(x[0]) for x in per[1:4])
    tpi_mdl = 69888 * 3 / per[1][0]
    txt = txt.replace('CONTRUN_OUT_RTL', rtl_lost).replace('CONTRUN_OUT_M1', rtl_m1).replace('CONTRUN_OUT_MODEL_M1', mdl_m1)
    txt = txt.replace('CONTRUN_OUT_MODEL', mdl_lost).replace('CONTRUN_OUT_TPI', f'{tpi_rtl:.2f} / {tpi_mdl:.2f} / 28')
    h1 = glob.glob(os.path.join(HERE, 'logs', 'run_*contrun_out*ACCLOG*.log'))
    note = ''
    if h1:
        a, lines = load(h1[0])
        acc = [l for l in lines if l.startswith('ACC')]
        io = sum(1 for l in acc if 'IO-' in l); mem = sum(1 for l in acc if 'MEM-' in l)
        note = f'в нём {io} интервалов ввода-вывода (порты 02FE/07FE) и всего {mem} интервалов памяти по 0x6000-0x6008 (по одному на байт: `LDIR` и первый проход) — цикл действительно жил в 0x8000.'
    return txt.replace('H1_NOTE', note)

def section_d():
    txt = FR('RESULT_d.md')
    rows = []
    for p in sorted(glob.glob(os.path.join(HERE, 'logs', 'run_*RESETUS=*.log'))):
        a, lines = load(p)
        isr = [l for l in lines if l.startswith('ISR')]
        m = re.search(r'kacc=(-?\d+)', isr[0]) if isr else None
        rows.append((a.get('RESETUS'), 'перевёрнутая (hc=1)' if 'HCINIT' in a else 'обычная (hc=0)', m.group(1) if m else '-'))
    if rows:
        t = ['', 'Минимум kacc при разных фазах решётки `HALT` (фаза меняется длиной сброса RESETUS: 1 мкс = 3.5 T; `NOCOMP=1`, первый /INT):', '',
             '| RESETUS, мкс | чётность hc | kacc первого прерывания |', '|---|---|---|']
        for r, par, k in sorted(rows, key=lambda x: (x[1], int(x[0]))):
            t.append(f'| {r} | {par} | {k} |')
        ks = {}
        for r, par, k in rows:
            if k != '-': ks.setdefault(par, []).append(int(k))
        t.append('')
        t.append('Длина сброса фазу решётки НЕ сдвинула (все четыре значения дали одну фазу: T80 выходит из сброса в одной и той же '
                 'фазе своей решётки относительно растра), но сравнение при РАВНОЙ фазе показательно: обычная чётность → kacc = '
                 + '/'.join(map(str, ks.get('обычная (hc=0)', []))) + ', перевёрнутая → kacc = '
                 + '/'.join(map(str, ks.get('перевёрнутая (hc=1)', []))) + '. При перевёрнутой чётности спад /INT совпадает с '
                 'импульсом `pe3M5`, `irq` (`main.v:180`) защёлкивается на этом же импульсе и T80 принимает прерывание на импульс '
                 'раньше: минимум kacc = 1 против 2. Окно на импульсах при этом осталось на тех же k (36738), то есть относительно '
                 'программы, синхронизированной по /INT, контеншен встал бы на ОДИН ТАКТ ПОЗЖЕ (первый такт с задержкой t = 14336). '
                 'В стенде по умолчанию (и, по коду, в железе) чётность обычная, и цифры разделов 3-4 сняты для неё.')
        txt = txt.replace('KACC_HCINIT_NOTE', '\n'.join(t))
    else:
        txt = txt.replace('KACC_HCINIT_NOTE', 'Минимум kacc для перевёрнутой чётности не измерен.')
    return txt

if __name__ == '__main__':
    parts = [FR('RESULT_head.md'), FR('RESULT_win.md'), section3(), section_c(), section_d(), FR('RESULT_tail.md')]
    open(os.path.join(HERE, 'RESULT.md'), 'w', encoding='utf-8').write('\n'.join(parts))
    print('RESULT.md written', sum(len(p) for p in parts), 'bytes')
