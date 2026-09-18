#!/usr/bin/env python3
"""fuse_model.py - опубликованная модель контеншена (Sinclair FAQ / Fuse) для сверки с RTL.

Единицы: t = T-состояния от прерывания (t=0 - первый такт кадра, как в Fuse: tstates после INT).
48K:  первый контендуемый такт 14335, строка 224 T, 192 строки бумаги, в строке первые 128 T несут узор
      6,5,4,3,2,1,0,0 (по 8 T), остальные 96 T - 0.
128K: первый контендуемый такт 14361, строка 228 T, тот же узор.
Контендуемые адреса: 0x4000-0x7FFF; у 128K ещё 0xC000-0xFFFF при вставленном банке 1/3/5/7.
Порты: старший байт адреса порта проверяется как адрес памяти (contended или нет), A0 выбирает ULA:
      N:1,C:3 / N:4 / C:1,C:3 / C:1,C:1,C:1,C:1 (C:n = задержка узора перед n тактами, N = без задержки).
Модель начисляет задержку ОДИН раз на начало каждого такта/цикла из таблицы (как Fuse).
"""
PATTERN = [6, 5, 4, 3, 2, 1, 0, 0]
MACH = {
    '48':  dict(base=14335, line=224, frame=69888),
    '128': dict(base=14361, line=228, frame=70908),
}


def delay(t, mach='48'):
    m = MACH[mach]
    r = t - m['base']
    if r < 0:
        return 0
    ln, x = divmod(r, m['line'])
    if ln >= 192 or x >= 128:
        return 0
    return PATTERN[x % 8]


def contended_addr(a, mach='48', bank_c000=0):
    if 0x4000 <= a <= 0x7FFF:
        return True
    if mach == '128' and a >= 0xC000 and (bank_c000 & 1):
        return True
    return False


# --- ожидание для интервала шины «адрес = цель», начавшегося в t (T1) ------------------------------
def expect_access(instr, t, mach='48', port=0x7FFD, aval=0x02, bank_c000=0):
    """Возвращает (ожидаемая суммарная задержка, ожидаемая длина интервала в T) для измеряемой команды."""
    d = lambda tt: delay(tt, mach)
    if instr in ('RD', 'WR'):
        dd = d(t)
        return dd, 3 + dd
    if instr == 'INCHL':                       # hl:3 hl:1 hl:3
        d1 = d(t); t1 = t + d1 + 3
        d2 = d(t1); t2 = t1 + d2 + 1
        d3 = d(t2)
        return d1 + d2 + d3, 7 + d1 + d2 + d3
    if instr in ('OUTFE', 'INFE', 'OUTC', 'INC'):
        pa = ((aval << 8) | 0xFE) if instr in ('OUTFE', 'INFE') else port
        hi_c = contended_addr(pa, mach, bank_c000)
        a0 = pa & 1
        if not hi_c and a0 == 0:               # N:1, C:3
            dd = d(t + 1); return dd, 4 + dd
        if not hi_c and a0 == 1:               # N:4
            return 0, 4
        if hi_c and a0 == 0:                   # C:1, C:3
            d1 = d(t); t1 = t + d1 + 1; d2 = d(t1); return d1 + d2, 4 + d1 + d2
        # hi_c and a0 == 1: C:1 x4
        tot = 0; tt = t
        for _ in range(4):
            dd = d(tt); tot += dd; tt += dd + 1
        return tot, 4 + tot
    raise ValueError(instr)


# --- плотные циклы в контендуемом ОЗУ (c) ----------------------------------------------------------
def run_loop(prog, mach='48', frames=6, t0=0, bank_c000=0):
    """prog: список команд; команда = список циклов (addr, len, kind) kind: 'mem' | 'io' | 'int'
    (int = внутренний такт, начисляется по адресу как mem). Возвращает список по кадрам:
    (число M1 в кадре, суммарная задержка в кадре, число исполненных команд)."""
    m = MACH[mach]
    t = t0
    end = frames * m['frame']
    per_frame = []
    fr = 0; m1 = 0; lost = 0; ninstr = 0
    pc_i = 0
    def io_cost(a, tt):
        hi_c = contended_addr(a, mach, bank_c000); a0 = a & 1
        if not hi_c and a0 == 0:
            dd = delay(tt + 1, mach); return dd, 4 + dd
        if not hi_c and a0 == 1:
            return 0, 4
        if hi_c and a0 == 0:
            d1 = delay(tt, mach); t1 = tt + d1 + 1; d2 = delay(t1, mach); return d1 + d2, 4 + d1 + d2
        tot = 0; x = tt
        for _ in range(4):
            dd = delay(x, mach); tot += dd; x += dd + 1
        return tot, 4 + tot
    while t < end:
        ins = prog[pc_i]
        for ci, (a, ln, kind) in enumerate(ins):
            f = t // m['frame']
            while f > fr:
                per_frame.append((m1, lost, ninstr)); m1 = lost = ninstr = 0; fr += 1
            if kind == 'io':
                dd, tot = io_cost(a, t - fr * m['frame'])
                lost += dd; t += tot
            else:
                dd = delay(t - fr * m['frame'], mach) if contended_addr(a, mach, bank_c000) else 0
                if ci == 0 and kind == 'mem' and ln == 4:
                    m1 += 1
                lost += dd; t += dd + ln
        ninstr += 1
        pc_i = ins_next(prog, pc_i, ins)
    per_frame.append((m1, lost, ninstr))
    return per_frame


def ins_next(prog, i, ins):
    nxt = getattr(ins, 'jump', None)
    return nxt if nxt is not None else (i + 1) % len(prog)


class I(list):
    """команда = список циклов; .jump = индекс следующей команды (для JP/DJNZ-моделей)"""
    def __init__(self, cycles, jump=None):
        super().__init__(cycles); self.jump = jump


def prog_contrun(org=0x6000):
    # LD A,(6100) / LD A,(6101) / LD (6102),A / NOP x4 / JP 6000   (contrun.hex Сергея Потапова)
    p = org
    P = []
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (p + 2, 3, 'mem'), (0x6100, 3, 'mem')])); p += 3
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (p + 2, 3, 'mem'), (0x6101, 3, 'mem')])); p += 3
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (p + 2, 3, 'mem'), (0x6102, 3, 'mem')])); p += 3
    for _ in range(4):
        P.append(I([(p, 4, 'mem')])); p += 1
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (p + 2, 3, 'mem')], jump=0))
    return P, 8   # M1 на итерацию


def prog_contrun_out(org=0x6000):
    # LD A,2 ; inner: OUT (FE),A ; XOR 5 ; JP inner   (порт 0x02FE / 0x07FE)
    p = org
    P = [I([(p, 4, 'mem'), (p + 1, 3, 'mem')])]; p += 2
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (0x02FE, 4, 'io')])); p += 2   # старший байт 2 или 7: оба не контендуемы
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem')])); p += 2
    P.append(I([(p, 4, 'mem'), (p + 1, 3, 'mem'), (p + 2, 3, 'mem')], jump=1))
    return P, 3


def run_contrun_rd(mach='48', frames=6):
    """LD HL,4000 / LD B,0 / inner: LD A,(HL) / INC L / DJNZ inner / JP 6000 - с состоянием B, поэтому отдельно."""
    m = MACH[mach]; org = 0x6000
    t = 0; end = frames * m['frame']; fr = 0; m1 = 0; lost = 0; ninner = 0; per = []
    def cyc(a, ln, is_m1=False):
        nonlocal t, m1, lost, fr, ninner
        f = t // m['frame']
        while f > fr:
            per.append((m1, lost, ninner)); m1 = lost = ninner = 0; fr += 1
        dd = delay(t - fr * m['frame'], mach) if contended_addr(a, mach) else 0
        if is_m1: m1 += 1
        lost += dd; t += dd + ln
    while t < end:
        p = org
        cyc(p, 4, True); cyc(p + 1, 3); cyc(p + 2, 3); p += 3          # LD HL,4000
        cyc(p, 4, True); cyc(p + 1, 3); p += 2                          # LD B,0
        inner = p
        b = 0
        while True:
            hl = 0x4000
            cyc(inner, 4, True); cyc(hl, 3)                             # LD A,(HL)
            cyc(inner + 1, 4, True)                                     # INC L
            cyc(inner + 2, 5, True); cyc(inner + 3, 3)                  # DJNZ: pc:5 (выборка 5 T), pc+1:3, [pc+1:1 x5]
            b = (b - 1) & 0xFF
            ninner += 1
            if b != 0:
                for _ in range(5): cyc(inner + 3, 1)
            else:
                break
            if t >= end: break
        if t >= end: break
        p = inner + 4
        cyc(p, 4, True); cyc(p + 1, 3); cyc(p + 2, 3)                   # JP 6000
    per.append((m1, lost, ninner))
    return per


if __name__ == '__main__':
    import sys
    for mach in ('48', '128'):
        print(f'== {mach}K: первый такт с задержкой: ', next(t for t in range(20000) if delay(t, mach) > 0),
              ' узор от него:', [delay(MACH[mach]['base'] + i, mach) for i in range(16)],
              ' конец окна первой строки:', [(MACH[mach]['base'] + 126 + i, delay(MACH[mach]['base'] + 126 + i, mach)) for i in range(4)])
    for name, (P, m1_per) in (('contrun', prog_contrun()), ('contrun_out', prog_contrun_out())):
        for mach in ('48', '128'):
            per = run_loop(P, mach)
            print(f'{name} {mach}K по кадрам (M1, потеряно, команд):', per[1:5],
                  ' -> T/итерацию:', [round(MACH[mach]['frame'] * m1_per / x[0], 3) for x in per[1:5]])
    per = run_contrun_rd('48')
    print('contrun_rd 48K (M1, потеряно, внутр. итераций):', per[1:5], ' -> T/внутр. итерацию:', [round(69888 / x[2], 3) for x in per[1:5]])
