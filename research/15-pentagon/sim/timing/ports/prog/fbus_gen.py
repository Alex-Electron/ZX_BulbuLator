#!/usr/bin/env python3
# fbus_gen.py - генерирует fbus_stubs.inc: KMAX заглушек точной задержки и таблицу переходов.
# Заглушка k: задержка ровно (8+k) T -> чтение порта -> пауза ровно (P-k) T (без порчи A) -> RET.
# Сумма задержек постоянна для всех k, поэтому длина обработчика не зависит от k и фаза приёма
# прерывания из HALT одна на все кадры (кадр = кратное 4 T на всех трёх машинах).
# Такты Z80: nop 4, ld a,i 9, inc de 6, ld e,n 7, ld r,a 9 (A не трогает), ld a,n 7, in a,(n) 11,
#            ld bc,nn 10, in a,(c) 12, ret 10.
import sys
KMAX = int(sys.argv[1]) if len(sys.argv) > 1 else 48
P = 56                       # пауза после IN = P-k T; для k=KMAX-1 остаётся 9 T = минимум (ld r,a)
assert P - (KMAX - 1) >= 9

def delay_pre(n):            # ровно n T, n >= 8, портит A, DE, флаги
    a, b = divmod(n, 4)
    if b == 0: return ["nop"] * a
    if b == 1: return ["nop"] * (a - 2) + ["ld a,i"]
    if b == 2: return ["nop"] * (a - 1) + ["inc de"]
    return ["nop"] * (a - 1) + ["ld e,0"]

def delay_post(n):           # ровно n T, n >= 9, A не трогает (портит R, DE, флаги - нет: ld r,a флаги не трогает)
    a, b = divmod(n, 4)
    if b == 0: return ["nop"] * a
    if b == 1: return ["nop"] * (a - 2) + ["ld r,a"]
    if b == 2: return ["nop"] * (a - 1) + ["inc de"]
    return ["nop"] * (a - 1) + ["ld e,0"]

out = ["; СГЕНЕРИРОВАНО fbus_gen.py - не править руками", f"KMAX equ {KMAX}", f"PPAD equ {P}", ""]
out.append("        org ($ + 255) and 0ff00h   ; таблица переходов в одной странице (inc l без переноса)")
out.append("jtab:")
for k in range(KMAX):
    out.append(f"        dw stub_{k}")
out.append("")
for k in range(KMAX):
    out.append(f"stub_{k}:")
    for ins in delay_pre(8 + k):
        out.append("        " + ins)
    out.append("        if MODE = 0")
    out.append("        ld a,PORTHI")
    out.append("        in a,(PORTLO)")
    out.append("        else")
    out.append("        ld bc,PORTHI*256+PORTLO")
    out.append("        in a,(c)")
    out.append("        endif")
    for ins in delay_post(P - k):
        out.append("        " + ins)
    out.append("        ret")
open("fbus_stubs.inc", "w").write("\n".join(out) + "\n")
print(f"fbus_stubs.inc: KMAX={KMAX} P={P}")
