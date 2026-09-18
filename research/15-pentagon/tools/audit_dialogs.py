#!/usr/bin/env python3
# Аудит всех окон: влезает ли фон в буфер сохранения (BOXSAVE_W x BOXSAVE_H).
# Обрезка там МОЛЧАЛИВАЯ, и именно она даёт артефакты после закрытия окна.
import re

P = "/home/lavrinovich/bulb-v13/research/15-pentagon/arm/loader_main.c"
src = open(P, encoding="utf-8").read()
lines = src.split("\n")

# v231: буфер накрывает всю канву -> предел = размер канвы в клетках
CAPW, CAPH = 80, 25
if re.search(r"#define BOXSAVE_W \((\d+)\*8\)", src):
    CAPW = int(re.search(r"#define BOXSAVE_W \((\d+)\*8\)", src).group(1))
if re.search(r"#define BOXSAVE_H \((\d+)\*16\)", src):
    CAPH = int(re.search(r"#define BOXSAVE_H \((\d+)\*16\)", src).group(1))
print(f"предел буфера: {CAPW} колонок x {CAPH} строк\n")

# ---- 1) статические окна: ищем ближайшее вверх присваивание W/H в той же функции
def find_dim(idx, name):
    """ищем 'name = <expr>' выше строки idx, не выходя за начало функции"""
    for i in range(idx, max(0, idx - 40), -1):
        L = lines[i]
        if re.match(r"^static\s.*\(", L) and i != idx:
            break
        m = re.search(r"\b" + name + r"\s*=\s*([^,;]+)", L)
        if m:
            return m.group(1).strip(), i + 1
    return None, None


print("=== окна с геометрией в коде ===")
print(f"{'строка':>7}  {'буфер':<8} {'W':<22} {'H':<22} вердикт")
for i, L in enumerate(lines):
    m = re.search(r"box_backup\(&g_bs\[(\w+)\]\s*,\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)", L)
    if not m:
        continue
    slot, cx, cy, cw, chh = [x.strip() for x in m.groups()]
    wexpr, wln = find_dim(i, "W")
    hexpr, hln = find_dim(i, "H")
    verdict = "?"
    if cw.startswith("W") and wexpr and wexpr.isdigit():
        w = int(wexpr) + 2
        verdict = f"W+2={w} " + ("OK" if w <= CAPW else f"НЕ ВЛЕЗАЕТ (>{CAPW})")
    print(f"{i+1:>7}  g_bs[{slot}]  {str(wexpr):<22} {str(hexpr):<22} {verdict}")

# ---- 2) выпадающие подменю: высота = число строк
print("\n=== выпадающие меню: сколько строк ===")
for m in re.finditer(r"static\s+const\s+MenuItem\s+(\w+)\[\]\s*=\s*\{(.*?)\n\};", src, re.S):
    name, body = m.group(1), m.group(2)
    rows = len(re.findall(r"^\s*\{", body, re.M))
    print(f"  {name:<24} строк {rows:>3}   рамка+тень -> {rows + 4:>3}   " +
          ("OK" if rows + 4 <= CAPH else f"ВЫШЕ ПРЕДЕЛА ({CAPH})"))

# ---- 3) пер-машинные подменю (они строятся из массивов ссылок на opt_items)
print("\n=== подменю машин (ссылки на opt_items) ===")
for m in re.finditer(r"static\s+const\s+\w+\s+(\w*(?:mach|machine)\w*)\[\]\s*=\s*\{(.*?)\n\};", src, re.S | re.I):
    name, body = m.group(1), m.group(2)
    rows = len(re.findall(r"^\s*\{", body, re.M))
    print(f"  {name:<24} строк {rows:>3}   рамка+тень -> {rows + 4:>3}   " +
          ("OK" if rows + 4 <= CAPH else f"ВЫШЕ ПРЕДЕЛА ({CAPH})"))

