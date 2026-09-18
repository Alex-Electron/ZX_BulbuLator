#!/usr/bin/env python3
"""tap_inspect.py - разобрать .tap и найти места, где лента ломается о клавиатуру.

Зачем этот инструмент существует. 12.08.2026 владелец сообщил, что демка с порционной загрузкой
(SHOCK.TAP, ESI'92) просит нажать пробел для продолжения, а вместо продолжения получается BREAK -
проходило примерно раз из десяти и только очень быстрым тычком. Гадать по симптому было нельзя:
до этого я уже построил на пробеле один ложный диагноз (якобы фантомный Caps Shift). Разбор
самого файла дал ответ за минуты, поэтому разбор и оформлен инструментом, а не одноразовым скриптом.

Что он показывает:
  * структуру ленты: заголовки, длины, контрольные суммы, адреса загрузки;
  * текст программы BASIC с раскрытыми токенами - видно, как именно демка грузит части;
  * ЧТЕНИЯ ПОЛУРЯДА С ПРОБЕЛОМ (`LD A,$7F : IN A,($FE)` и родня). Это и есть проверка BREAK:
    подпрограмма ПЗУ LD-SAMPLE читает ровно этот полуряд и ровно его бит 0, поэтому зажатый пробел
    штатно рвёт LOAD на ЛЮБОМ настоящем Спектруме - демка тут ни при чём и чинить надо не её.

Как этим пользоваться, когда лента «не грузится с клавиатуры»:
  1. `tap_inspect.py лента.tap` - если у части есть ровно одно чтение полуряда $7F и сразу за ним
     возврат (`IM 1 / EI / RET`), значит часть отдаёт управление МГНОВЕННО по нажатию, без ожидания
     отпускания. Запас времени у человека - это только то, что машина успевает сделать до первого
     чтения BREAK в загрузчике ПЗУ.
  2. Посчитать этот запас (у SHOCK.TAP это два HALT и две очистки экрана LDIR по 6911 байт в
     shock.0, то есть ~83 мс детерминированно плюс кадровые ожидания и BASIC - около 120 мс).
  3. Сравнить с тем, что получается у нас. Если наш запас в разы меньше - виноват варп: см.
     `bulbulator_zx_ddr_top.v`, комментарий «ВАРП ОТПУСКАЕТСЯ, КОГДА ЛЕНТА МОЛЧИТ» (B0128).

Пример: python3 tap_inspect.py ~/tapes/SHOCK.TAP
"""
import re
import sys

TOKENS = (
    "RND INKEY$ PI FN POINT SCREEN$ ATTR AT TAB VAL$ CODE VAL LEN SIN COS TAN ASN ACS ATN LN EXP INT "
    "SQR SGN ABS PEEK IN USR STR$ CHR$ NOT BIN OR AND <= >= <> LINE THEN TO STEP DEF_FN CAT FORMAT "
    "MOVE ERASE OPEN# CLOSE# MERGE VERIFY BEEP CIRCLE INK PAPER FLASH BRIGHT INVERSE OVER OUT LPRINT "
    "LLIST STOP READ DATA RESTORE NEW BORDER CONTINUE DIM REM FOR GO_TO GO_SUB INPUT LOAD LIST LET "
    "PAUSE NEXT POKE PRINT PLOT RUN SAVE RANDOMIZE IF CLS DRAW CLEAR RETURN COPY"
).split()

# Чтения клавиатуры, которые ЛОМАЮТ загрузку. Полуряд $7F - тот самый, что читает LD-SAMPLE ПЗУ:
# биты B,N,M,Symbol Shift,ПРОБЕЛ, и BREAK смотрит именно бит 0 = пробел.
KEY_PATTERNS = (
    ("LD A,$7F : IN A,($FE)   - полуряд с ПРОБЕЛОМ (тот же, что у BREAK в ПЗУ)", b"\x3e\x7f\xdb\xfe", True),
    ("LD BC,$7FFE : IN A,(C)  - он же через BC", b"\x01\xfe\x7f\xed\x78", True),
    ("LD B,$7F : IN A,(C)     - он же, младший байт уже в C", b"\x06\x7f\xed\x78", True),
    ("CALL $0556 (LD_BYTES)   - часть зовёт загрузчик ПЗУ сама", b"\xcd\x56\x05", False),
    ("CALL $028E (KEY-SCAN)   - опрос клавиатуры через ПЗУ", b"\xcd\x8e\x02", False),
)

# Что стоит сразу ПОСЛЕ проверки: возврат без ожидания отпускания - главный признак.
RETURN_TAIL = (
    (b"\xed\x56\xfb\xc9", "IM 1 / EI / RET - возврат МГНОВЕННО, отпускания не ждёт"),
    (b"\xfb\xc9", "EI / RET - возврат МГНОВЕННО, отпускания не ждёт"),
    (b"\xc9", "RET - возврат МГНОВЕННО, отпускания не ждёт"),
)


def detokenise(b):
    out, i = [], 0
    kw = {0xA5 + n: " " + t.replace("_", " ") + " " for n, t in enumerate(TOKENS)}
    while i < len(b):
        c = b[i]
        if c == 0x0E:                       # пятибайтовое число после цифр - в тексте не нужно
            i += 6
            continue
        if c in kw:
            out.append(kw[c])
        elif 32 <= c < 127:
            out.append(chr(c))
        elif c == 0x0D:
            out.append("\n")
        elif c in (0x10, 0x11, 0x12, 0x13, 0x14) and i + 1 < len(b):
            out.append(""); i += 1          # управление цветом - для чтения не нужно
        elif c in (0x16, 0x17) and i + 2 < len(b):
            out.append("{AT %d,%d}" % (b[i+1], b[i+2]) if c == 0x16 else "{TAB}"); i += 2
        else:
            out.append("{%02X}" % c)
        i += 1
    return "".join(out)


def basic_lines(b):
    out, i = [], 0
    while i + 4 <= len(b):
        num = (b[i] << 8) | b[i+1]
        size = b[i+2] | (b[i+3] << 8)
        if num > 9999 or size == 0 or i + 4 + size > len(b):
            break
        out.append((num, detokenise(b[i+4:i+4+size]).rstrip("\n")))
        i += 4 + size
    return out


def blocks(data):
    """Разобрать .tap на блоки. Отдаёт (флаг, тело_без_флага_и_суммы, сумма_сошлась, заголовок)."""
    i, hdr = 0, None
    while i + 2 <= len(data):
        ln = data[i] | (data[i+1] << 8)
        blk = data[i+2:i+2+ln]
        if len(blk) < ln or ln < 2:
            yield ("обрыв", i, ln, len(blk))
            return
        chk = 0
        for x in blk[:-1]:
            chk ^= x
        ok = (chk == blk[-1])
        body = blk[1:-1]
        if blk[0] == 0 and len(body) == 17:
            hdr = {
                "type": body[0],
                "name": bytes(body[1:11]).decode("latin1"),
                "len": body[11] | (body[12] << 8),
                "p1": body[13] | (body[14] << 8),
                "p2": body[15] | (body[16] << 8),
            }
            yield ("header", i, hdr, ok)
        else:
            yield ("data", i, (blk[0], body, hdr), ok)
            hdr = None
        i += 2 + ln


def main(path):
    data = open(path, "rb").read()
    print("файл: %s, %d байт" % (path, len(data)))
    print()
    hostile = []
    n = 0
    for item in blocks(data):
        kind = item[0]
        if kind == "обрыв":
            print("!! обрыв на смещении %d: заявлено %d байт, есть %d" % (item[1], item[2], item[3]))
            break
        n += 1
        if kind == "header":
            _, off, h, ok = item
            tn = {0: "PROGRAM", 1: "NUM ARRAY", 2: "CHR ARRAY", 3: "CODE"}.get(h["type"], "?")
            extra = ""
            if h["type"] == 0:
                extra = "  автостарт=%s" % ("нет" if h["p1"] >= 32768 else h["p1"])
            elif h["type"] == 3:
                extra = "  адрес=%d (0x%04X)" % (h["p1"], h["p1"])
            print("[%3d] @%-6d ЗАГОЛОВОК %-9s '%s' %6d Б%s%s"
                  % (n, off, tn, h["name"], h["len"], extra, "" if ok else "   СУММА НЕ СОШЛАСЬ"))
            continue

        _, off, (flag, body, h), ok = item
        name = h["name"].strip() if h else "(без заголовка)"
        addr = h["p1"] if (h and h["type"] == 3) else 0
        print("[%3d] @%-6d ДАННЫЕ    '%s' %6d Б, флаг 0x%02X%s"
              % (n, off, name, len(body), flag, "" if ok else "   СУММА НЕ СОШЛАСЬ"))

        if h and h["type"] == 0:
            prog = body[:h["p2"]] if 0 < h["p2"] <= len(body) else body
            for num, txt in basic_lines(prog):
                print("        %4d %s" % (num, txt))
            continue

        for label, pat, is_break in KEY_PATTERNS:
            for m in re.finditer(re.escape(pat), body):
                a = addr + m.start()
                tail = body[m.start() + len(pat):m.start() + len(pat) + 12]
                note = ""
                if is_break:
                    # что стоит сразу после проверки: ищем возврат в ближайших байтах
                    for rp, rn in RETURN_TAIL:
                        k = tail.find(rp)
                        if 0 <= k <= 8:
                            note = " -> " + rn
                            hostile.append((name, a))
                            break
                    if not note:
                        # Возврата в окне нет - это НЕ значит, что часть ждёт отпускания: выход
                        # часто спрятан за переходом (JP/JR на процедуру выхода). Печатаем хвост,
                        # чтобы решение принимал человек, а не эвристика.
                        note = " -> выход не опознан, хвост: " + " ".join("%02X" % x for x in tail[:8])
                print("        0x%04X  %s%s" % (a, label, note))

    print()
    if hostile:
        print("ВНИМАНИЕ: части, которые отдают управление МГНОВЕННО по пробелу, без ожидания отпускания:")
        for name, a in hostile:
            print("   '%s' по адресу 0x%04X" % (name, a))
        print()
        print("Следствие: сразу после такой части идёт LOAD, а ПЗУ первым же делом читает тот же")
        print("полуряд и видит пробел ещё нажатым -> BREAK. Запас у человека - только то, что машина")
        print("успевает сделать между отпусканием и первым чтением BREAK. Если у нас этот запас")
        print("заметно меньше, чем на живой машине, виноват варп, а не клавиатура: варп обязан")
        print("отпускаться, когда лента молчит (bulbulator_zx_ddr_top.v, B0128).")
    else:
        print("Мест, чувствительных к зажатому пробелу, не найдено.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("применение: tap_inspect.py <файл.tap>")
    main(sys.argv[1])
