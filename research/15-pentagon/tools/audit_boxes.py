#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сторож каркаса окон: КАЖДОЕ окно обязано сохранять свой фон в стеке.

Зачем. Исключения из этого правила у нас дважды выливались в жалобы владельца на артефакты:
подменю, оставшееся на фоне (слоты фона делились между окнами), и «окно копирования исчезло, а
прогрессбар бежал» (окно закрывалось полной перерисовкой канвы вместо возврата своего фона).
Оба раза дефект был не в отрисовке, а в том, что окно жило не по общему правилу.

Окно = вызов dn_win_draw. Законные способы сохранить фон: box_push в том же теле функции, dlg_open
(общий каркас делает это сам) либо box_recapture (движок меню пересохраняет уровни).

Запуск: python3 tools/audit_boxes.py [путь к arm/]
Код возврата 1, если найдено окно вне каркаса.
"""
import os, re, sys

# Законные исключения - с объяснением, почему фон им не нужен.
WHITELIST = {
    "dn_win_draw":    "это сама функция рисования рамки, а не окно",
    "tv_dialog_draw": "фон сохраняет tv_dialog_exec, который её и зовёт",
    "dn_help":        "не окно поверх навигатора, а отдельный вид на весь экран (browser_on=0)",
}

def audit(arm_dir):
    bad = []
    for fname in ("loader_main.c", "tv_ui.c"):
        path = os.path.join(arm_dir, fname)
        if not os.path.exists(path):
            continue
        src = open(path, encoding="utf-8").read().split("\n")
        heads = [i for i, l in enumerate(src)
                 if re.match(r'^\w[\w \*]*\**\w+\s*\([^;]*\)\s*\{?\s*$', l) and not l.strip().startswith("//")]
        for i in heads:
            j = i + 1
            while j < len(src) and not src[j].startswith("}"):
                j += 1
            body = "\n".join(src[i:j + 1])
            if "dn_win_draw(" not in body:
                continue
            name = re.sub(r'^[\w \*]*?(\w+)\s*\(.*$', r'\1', src[i])
            saved = any(k in body for k in ("box_push", "dlg_open", "box_recapture"))
            if saved:
                print(f"  {fname}:{i+1:<6d} {name:28s} фон в стеке")
            elif name in WHITELIST:
                print(f"  {fname}:{i+1:<6d} {name:28s} исключение: {WHITELIST[name]}")
            else:
                print(f"  {fname}:{i+1:<6d} {name:28s} ❌ ФОН НЕ СОХРАНЯЕТСЯ")
                bad.append((fname, i + 1, name))
    if bad:
        print("\nОКНА ВНЕ КАРКАСА:", ", ".join(f"{f}:{l} {n}" for f, l, n in bad))
        print("Лечить не подкраской поведения, а box_push/box_pop - как у всех остальных окон.")
        return 1
    print("\nИТОГ: все окна на каркасе (исключения перечислены и объяснены)")
    return 0

if __name__ == "__main__":
    sys.exit(audit(sys.argv[1] if len(sys.argv) > 1 else
                   os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "arm")))
