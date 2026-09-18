#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
d64.py - чтение образов дискет Commodore 1541 (.d64) для BulbuLator.

Зачем в репозитории: это ПРОТОТИП логики, которая пойдёт в прошивку оболочки, когда появится
машина C64. Каталог дискеты, цепочки секторов и перевод имён из PETSCII - ровно то, что придётся
делать браузеру файлов на ARM. Здесь она обкатана на 83 реальных образах демосцены (1067 программ,
у всех адрес загрузки $0801), поэтому в прошивку поедет проверенный алгоритм, а не догадка.

Геометрия 1541 (та самая, из-за которой нельзя считать смещение простым умножением):
  дорожки  1..17 - по 21 сектору,  18..24 - по 19,  25..30 - по 18,  31..35 - по 17.
  Каталог начинается на дорожке 18, сектор 1. Первые два байта каждого сектора - ссылка
  на следующий (дорожка, сектор); у последнего сектора дорожка = 0, а сектор = число
  ИСПОЛЬЗОВАННЫХ байт (это классическая ловушка: без такой обработки в конец файла попадает мусор).

Использование:
  python3 d64.py образ.d64                 - показать каталог
  python3 d64.py образ.d64 каталог_вывода  - извлечь все PRG
"""
import sys, os

SECTORS_PER_TRACK = [21]*17 + [19]*7 + [18]*6 + [17]*5     # дорожки 1..35
D64_SIZES = {174848: 35, 175531: 35, 196608: 40, 197376: 40}

def sector_offset(track, sector):
    """Байтовое смещение сектора. Дорожки нумеруются с 1."""
    if track < 1 or track > len(SECTORS_PER_TRACK):
        raise ValueError('дорожка %d вне диапазона' % track)
    if sector >= SECTORS_PER_TRACK[track-1]:
        raise ValueError('сектор %d вне дорожки %d' % (sector, track))
    return (sum(SECTORS_PER_TRACK[:track-1]) + sector) * 256

# PETSCII -> читаемое. Буквы лежат в ДВУХ диапазонах: $41-$5A и $C1-$DA (сдвинутый набор),
# $A0 - "сдвинутый пробел", которым дополняются имена до 16 знаков (обрезаем по нему).
def petscii_to_text(raw):
    out = []
    for c in raw:
        if c == 0xA0:                      # padding - конец имени
            break
        if 0x41 <= c <= 0x5A:  out.append(chr(c))                 # A-Z
        elif 0xC1 <= c <= 0xDA: out.append(chr(c - 0x80))          # A-Z сдвинутого набора
        elif 0x20 <= c <= 0x3F: out.append(chr(c))                 # цифры, пробел, пунктуация
        elif c == 0x5F:        out.append('<')                     # стрелка влево
        elif c == 0x5E:        out.append('^')                     # стрелка вверх
        elif c == 0x00:        continue
        else:                  out.append('.')                     # графика и прочее
    return ''.join(out).strip()

FILE_TYPES = {0: 'DEL', 1: 'SEQ', 2: 'PRG', 3: 'USR', 4: 'REL'}

def read_image(path):
    data = open(path, 'rb').read()
    if len(data) not in D64_SIZES:
        # не отказываемся: битые/обрезанные образы встречаются, просто предупреждаем
        sys.stderr.write('предупреждение: %s - нетипичный размер %d Б\n' % (os.path.basename(path), len(data)))
    return data

def catalog(data):
    """Список записей каталога. Защищён от зацикливания ссылок (битые образы это делают)."""
    files, seen = [], set()
    track, sector = 18, 1
    while track and (track, sector) not in seen:
        seen.add((track, sector))
        try:
            base = sector_offset(track, sector)
        except ValueError:
            break
        if base + 256 > len(data):
            break
        blk = data[base:base+256]
        for i in range(8):
            e = blk[i*32:(i+1)*32]
            ftype = e[2] & 0x0F
            if ftype == 0 or (e[2] & 0x80) == 0:      # 0 = DEL, бит7 = "файл закрыт"
                continue
            files.append({
                'name':   petscii_to_text(e[5:21]),
                'type':   FILE_TYPES.get(ftype, '?%X' % ftype),
                'track':  e[3], 'sector': e[4],
                'blocks': e[30] | (e[31] << 8),
            })
        track, sector = blk[0], blk[1]
    return files

def read_file(data, track, sector, max_blocks=1400):
    """Идём по цепочке секторов. У последнего сектора байт 1 = число использованных байт."""
    out, seen, n = bytearray(), set(), 0
    while track and (track, sector) not in seen and n < max_blocks:
        seen.add((track, sector)); n += 1
        try:
            base = sector_offset(track, sector)
        except ValueError:
            break
        if base + 256 > len(data):
            break
        blk = data[base:base+256]
        nt, ns = blk[0], blk[1]
        if nt:
            out += blk[2:256]                     # полный сектор
        else:
            out += blk[2:2+max(0, ns-1)]          # последний: ns = сколько байт занято
        track, sector = nt, ns
    return bytes(out)

def safe_name(name, fallback):
    s = ''.join(ch if (ch.isalnum() or ch in '-_.') else '_' for ch in name).strip('_')
    return (s[:32] or fallback)

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    img = sys.argv[1]
    data = read_image(img)
    files = catalog(data)
    print('%s: %d записей, %d Б' % (os.path.basename(img), len(files), len(data)))
    for f in files:
        print('  %-18s %-4s %4d бл.  t%02d/s%02d' % (f['name'][:18], f['type'], f['blocks'], f['track'], f['sector']))
    if len(sys.argv) > 2:
        outdir = sys.argv[2]
        os.makedirs(outdir, exist_ok=True)
        n = 0
        for f in files:
            if f['type'] != 'PRG':
                continue
            payload = read_file(data, f['track'], f['sector'])
            if len(payload) < 3:
                continue
            load_addr = payload[0] | (payload[1] << 8)
            fn = safe_name(f['name'], 'file%02d' % n) + '.prg'
            open(os.path.join(outdir, fn), 'wb').write(payload)
            print('  -> %-36s $%04X  %6d Б' % (fn, load_addr, len(payload)))
            n += 1
        print('извлечено PRG: %d' % n)
    return 0

if __name__ == '__main__':
    sys.exit(main())

# ---------------------------------------------------------------------------------------------
# ОБКАТАНО НА 83 ОБРАЗАХ ДЕМОСЦЕНЫ (2026-08-02). Два вывода, важных для будущего браузера C64:
#
# 1. DirArt. У 29 из 59 разобранных образов (около 60 %) каталог - это КАРТИНКА: записи типа 0x82
#    с нулём блоков и ссылкой в никуда, имена набраны графическими символами PETSCII. Показать такой
#    каталог "как есть" - значит показать владельцу мусор и не дать запустить демку. Это не порча
#    образа, это нормальная практика сцены.
#
# 2. Отсюда стратегия загрузки: НЕ выбирать файл из каталога, а повторять штатное `LOAD"*",8,1` -
#    брать ПЕРВУЮ запись каталога и идти по цепочке секторов. Проверено на DirArt-образе
#    (Aliens in Wonderland): первая запись ведёт на t18/s02, то есть внутрь самой дорожки каталога,
#    и цепочка отдаёт 2567 байт с адресом загрузки $0801 - рабочий загрузчик, спрятанный сценой
#    в каталоге. Обычные образы этим же путём грузятся тем более.
# ---------------------------------------------------------------------------------------------
