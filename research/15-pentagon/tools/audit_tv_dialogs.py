#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_tv_dialogs.py - геометрия ДЕКЛАРАТИВНЫХ диалогов каркаса TV (arm/tv_ui.c).

Зачем отдельный сторож. tools/audit_dialogs.py проверяет ВМЕСТИМОСТЬ окна в канву (box_backup) и
смотрит только на loader_main.c. У диалогов tv_ui.c другая, куда более частая беда: у подписей
каркаса НЕТ клипа интерьера (clip_push в tv_ui.c не вызывается), поэтому слишком длинная подпись
молча вылезает за рамку окна на панель навигатора, а виджет ниже нужной строки залезает под кнопки.
Считать это глазами при каждой правке - гарантированная ошибка, вот и считает скрипт.

Правила каркаса (tv_ui.c:tv_dialog_init / tv_dialog_draw / tv_draw_buttons):
  - W зажимается в 20..78, H в 6..23; left=(80-W)/2, top=(25-H)/2, brow=top+H-3, тень на brow+1;
  - интерьер по x: 1 .. W-2;
  - последняя строка содержимого y = H-5 (пустая строка над кнопочной панелью - требование владельца);
  - радио и флажок = 4 клетки префикса + подпись; input_browse = ровно fw клеток (поле fw-4 + [v]).
Ширина подписи из переменной берётся по ОБЪЯВЛЕННОМУ размеру буфера (худший случай).
Вызовы внутри `for(...)` умножаются на число витков, если предел цикла - константа: иначе счётчик
виджетов врал бы там, где таблица рисуется циклом.

Запуск: python3 tools/audit_tv_dialogs.py     (плата и Vivado не нужны)
"""
import re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "arm", "tv_ui.c"), encoding="utf-8").read()
hdr = open(os.path.join(HERE, "..", "arm", "tv_ui.h"), encoding="utf-8").read()

defs = dict(re.findall(r'#define\s+([A-Za-z_]\w*)\s+(\d+)', src + "\n" + hdr))
def num(tok):
    tok = (tok or "").strip()
    if re.fullmatch(r'-?\d+', tok): return int(tok)
    return int(defs[tok]) if tok in defs else None

# размеры статических буферов, включая объявления списком: static char a[N], b[N];
bufs = {}
for m in re.finditer(r'static\s+char\s+([^;]+);', src):
    for decl in m.group(1).split(','):
        dm = re.match(r'\s*(\w+)\s*\[\s*([A-Za-z0-9_]+)\s*\]\s*(?:\[\s*([A-Za-z0-9_]+)\s*\])?', decl)
        if dm: bufs[dm.group(1)] = dm.group(3) or dm.group(2)

def expr(e):
    """Предел цикла бывает выражением из #define: RSD_SLOTS+1, 2*N. Считаем его, подставив define-ы."""
    e = (e or "").strip()
    try:
        return int(eval(re.sub(r'\b[A-Za-z_]\w*\b', lambda m: defs.get(m.group(0), "None"), e),
                        {"__builtins__": {}}, {}))
    except Exception:
        return None

# массивы подписей: static const char* const NAME[..] = { "a", "b" } -> берём САМУЮ ДЛИННУЮ
strarr = {}
for m in re.finditer(r'static\s+const\s+char\s*\*\s*const\s+(\w+)\s*\[[^\]]*\]\s*=\s*\{([^}]*)\}', src):
    lits = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2))
    if lits: strarr[m.group(1)] = max(len(re.sub(r'\\x[0-9A-Fa-f]{2}|\\.', '.', x)) for x in lits)

def strwidth(arg):
    arg = (arg or "").strip()
    if arg.startswith('"'):
        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', arg)
        w = 0
        for p in parts:
            w += len(re.sub(r'\\x[0-9A-Fa-f]{2}|\\.', '.', p))
        return w, "literal"
    base = arg.split('[')[0].strip().lstrip('&')
    if base in strarr: return strarr[base], "array %s (худшая подпись)" % base
    if base in bufs:
        n = num(bufs[base])
        return (n - 1 if n else None), "buffer %s" % bufs[base]
    return None, "unknown"

def args_split(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([": depth += 1
        if ch in ")]": depth -= 1
        if ch == ',' and depth == 0: out.append(cur); cur = ""
        else: cur += ch
    out.append(cur)
    return [a.strip() for a in out]


def range_of(e, loopvars):
    """Координата из цикла - выражение вида 14+s или 22+col*10. Возвращает (min,max) по ВСЕМ виткам
    активных циклов: подставлять один и тот же индекс во все переменные нельзя, у вложенных циклов
    свои диапазоны (так тул однажды насчитал x=212 там, где максимум 62)."""
    e = (e or "").strip()
    if re.fullmatch(r'-?\d+', e): return (int(e), int(e))
    names = [n for n in set(re.findall(r'\b[A-Za-z_]\w*\b', e)) if n not in defs]
    ranges = []
    for n in names:
        cnt = dict(loopvars).get(n)
        if cnt is None: return (None, None)
        ranges.append((n, cnt))
    vals = []
    def walk(i, env):
        if i == len(ranges):
            try:
                vals.append(int(eval(re.sub(r'\b[A-Za-z_]\w*\b',
                            lambda m: str(env.get(m.group(0), defs.get(m.group(0), "None"))), e),
                            {"__builtins__": {}}, {})))
            except Exception:
                vals.append(None)
            return
        n, cnt = ranges[i]
        for v in range(cnt):
            env[n] = v; walk(i + 1, env)
    walk(0, {})
    if not vals or any(v is None for v in vals): return (None, None)
    return (min(vals), max(vals))

ADD = re.compile(r'tv_dialog_add_(label|check|radio|input_browse|input)\s*\(([^;]*?)\)\s*;', re.S)

fails = 0
for fm in re.finditer(r'\nvoid\s+(tv_\w+_dialog)\s*\(void\)\s*\{', src):
    fname = fm.group(1)
    rest = src[fm.end():]
    end = rest.find("\n}\n")
    body = rest[:end if end > 0 else len(rest)]

    im = re.search(r'tv_dialog_init\s*\(\s*&\w+\s*,\s*"(?:[^"\\]|\\.)*"\s*,\s*(\d+)\s*,\s*(\d+)\s*\)', body)
    if not im:
        print("%-26s tv_dialog_init не найден - пропуск" % fname); continue
    Wr, Hr = int(im.group(1)), int(im.group(2))
    W = min(max(Wr, 20), 78); H = min(max(Hr, 6), 23)
    left, top = (80 - W)//2, (25 - H)//2
    brow, ymax = top + H - 3, H - 5
    print("=== %s   W=%d H=%d%s  left=%d top=%d brow=%d  интерьер x=1..%d, y=1..%d"
          % (fname, W, H, "" if (W, H) == (Wr, Hr) else " (ЗАЖАТО с %dx%d!)" % (Wr, Hr),
             left, top, brow, W - 2, ymax))
    if (W, H) != (Wr, Hr):
        print("   ОТКАЗ: init зажал окно - вся раскладка считалась по другим числам"); fails += 1

    # множитель циклов: считаем витки for(...; X < N; ...) с константным N
    lines = body.split("\n")
    mult = [1] * len(lines)
    lv   = [[] for _ in lines]     # какие переменные циклов действуют на строке
    stack = []          # (глубина_фигурных, множитель) - циклы с телом в {}
    single = []         # множители циклов БЕЗ {}: тело - одна инструкция, возможно на следующих строках
    depth = 0
    for i, ln in enumerate(lines):
        fo = re.search(r'for\s*\(\s*(?:int\s+)?(\w+)\s*=\s*0\s*;\s*\w+\s*<\s*([^;]+?)\s*;', ln)
        pend = expr(fo.group(2)) if fo else None
        var  = fo.group(1) if fo else None
        m = 1
        for (_, _, mm) in stack: m *= mm
        for (_, mm) in single:   m *= mm
        mult[i] = m
        lv[i] = [(n, c) for (n, _, c) in stack] + list(single)
        if pend:
            tail = ln.rsplit(')', 1)[1] if ')' in ln else ''
            if '{' in ln.split("for", 1)[1]:                 # тело в фигурных скобках
                stack.append((var, depth + ln.count("{") - ln.count("}"), pend))
            elif ';' in tail:                                # цикл целиком в одну строку
                mult[i] *= pend; lv[i] = lv[i] + [(var, pend)]
            else:                                            # тело - инструкция НА СЛЕДУЮЩИХ строках
                single.append((var, pend))
        elif single and (';' in ln or '}' in ln):             # инструкция кончилась - множитель снимаем
            single = []
        depth += ln.count("{") - ln.count("}")
        while stack and depth < stack[-1][1]: stack.pop()

    # СЧЁТ ВИДЖЕТОВ - построчно, а не по общему разбору: вызов с sizeof() внутри и переносами строк
    # ловится регуляркой ненадёжно, а просчитаться в счётчике нельзя - переполнение каркас глотает молча.
    nwidgets = nbuttons = 0
    for i, ln in enumerate(lines):
        k = mult[i]
        nwidgets += k * ln.count("tv_dialog_add_label")
        nwidgets += k * ln.count("tv_dialog_add_check")
        nwidgets += k * ln.count("tv_dialog_add_radio")
        nwidgets += k * ln.count("tv_dialog_add_input(")
        nwidgets += k * 2 * ln.count("tv_dialog_add_input_browse")   # поле + кнопка [v]
        nbuttons += k * ln.count("tv_dialog_add_button")
    for cm in ADD.finditer(body):
        line_no = body[:cm.start()].count("\n")
        k = mult[line_no] if line_no < len(mult) else 1
        kind, a = cm.group(1), args_split(cm.group(2))
        x, y = num(a[1]) if len(a) > 1 else None, num(a[2]) if len(a) > 2 else None
        tag = (a[3] if len(a) > 3 else "?").strip()[:34]
        if kind in ("label", "check", "radio"):
            w, how = strwidth(a[3] if len(a) > 3 else "")
            if w is not None and kind != "label": w += 4
        else:
            w, how = num(a[3] if len(a) > 3 else ""), "field"
        # координаты из циклов - выражения (14+s, 22+col*10): проверяем ВСЕ витки
        vars_here = lv[line_no] if line_no < len(lv) else []
        x0, x1 = (x, x) if x is not None else range_of(a[1], vars_here)
        y0, y1 = (y, y) if y is not None else range_of(a[2], vars_here)
        if x0 is None or y0 is None:
            print("   ? координаты не посчитать      %-14s %s" % (kind, tag)); continue
        if y0 < 1 or y1 > ymax:
            print("   ОТКАЗ y=%d..%d (предел %d)      %-14s %s" % (y0, y1, ymax, kind, tag)); fails += 1
        if w is None:
            print("   ? ширина неизвестна            %-14s %s" % (kind, tag)); continue
        if x0 < 1 or x1 + w - 1 > W - 2:
            print("   ОТКАЗ x=%d..%d ширина %-3d -> край %-3d (предел %d)  %-14s %s (%s)"
                  % (x0, x1, w, x1 + w - 1, W - 2, kind, tag, how)); fails += 1
    tvw, tvb = num("TV_MAX_WIDGETS") or 32, num("TV_MAX_BUTTONS") or 4
    print("   виджетов %d/%d, кнопок %d/%d" % (nwidgets, tvw, nbuttons, tvb))
    if nwidgets > tvw: print("   ОТКАЗ: переполнение TV_MAX_WIDGETS (каркас глотает лишние МОЛЧА)"); fails += 1
    if nbuttons > tvb: print("   ОТКАЗ: переполнение TV_MAX_BUTTONS"); fails += 1

print("\nИТОГ: %s" % ("ОТКАЗОВ %d" % fails if fails else "все диалоги влезают в свои окна"))
sys.exit(1 if fails else 0)
