#!/usr/bin/env python3
"""Пульт к БулбуЛятору с хоста: нажать клавиши в оболочке и снять её экран.

Складывается из двух уже проверенных механизмов: мейлбокс-команда 11 (инжект скан-кода в очередь
оболочки) и канва интерфейса в DDR по 0x0F800000 (640x400 ARGB = 80x25 клеток шрифта 8x16).
Вместе они дают то, чего не хватало для самостоятельной работы на плате: ВИЖУ, что на экране
оболочки, и МОГУ по нему кликать - без владельца у монитора.

⚠ Инжектить коды надо УЖЕ СВЁРНУТЫЕ (стрелка вправо = 0xF4, а не пара E0,0x74): kbd_data_read
отдаёт значение из очереди ДО разбора префиксов E0/F0. Таблица KEYS ниже уже свёрнутая.
⚠ Не запускать, пока владелец работает в интерфейсе: в визарде маппинга ЛЮБАЯ клавиша = назначение
кнопки, то есть инжект молча перепишет его настройку.

  drive.py shot                       - только снимок
  drive.py keys F12 DOWN DOWN ENTER   - нажать по очереди, потом снимок
  drive.py keys --nodump ESC          - нажать без снимка
"""
import os
import subprocess
import sys

HOST = "thinkpad"
LOCAL = os.environ.get("DRIVE_LOCAL") == "1"   # запуск НА ThinkPad: без scp/ssh к себе
XSDB = "/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb"
HERE = os.path.dirname(os.path.abspath(__file__))

KEYS = {
    "UP": 0xF5, "DOWN": 0xF2, "LEFT": 0xEB, "RIGHT": 0xF4,
    "ENTER": 0x5A, "ESC": 0x76, "SPACE": 0x29, "TAB": 0x0D,
    "BS": 0x66, "PGUP": 0xFD, "PGDN": 0xFA, "HOME": 0xEC, "END": 0xE9,
    "INS": 0xF0, "DEL": 0xF1,
    "F1": 0x05, "F2": 0x06, "F3": 0x04, "F4": 0x0C, "F5": 0x03, "F6": 0x0B,
    "F7": 0x83, "F8": 0x0A, "F9": 0x01, "F10": 0x09, "F11": 0x78, "F12": 0x07,
    "A": 0x1C, "B": 0x32, "C": 0x21, "D": 0x23, "E": 0x24, "F": 0x2B, "G": 0x34,
    "H": 0x33, "I": 0x43, "J": 0x3B, "K": 0x42, "L": 0x4B, "M": 0x3A, "N": 0x31,
    "O": 0x44, "P": 0x4D, "Q": 0x15, "R": 0x2D, "S": 0x1B, "T": 0x2C, "U": 0x3C,
    "V": 0x2A, "W": 0x1D, "X": 0x22, "Y": 0x35, "Z": 0x1A,
    "0": 0x45, "1": 0x16, "2": 0x1E, "3": 0x26, "4": 0x25, "5": 0x2E,
    "6": 0x36, "7": 0x3D, "8": 0x3E, "9": 0x46,
}

HEAD = """connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc key {code} {
  foreach w [list $code [expr {0x200 | $code}]] {
    mwr -force 0x0F700010 $w
    mwr -force 0x0F700008 0
    mwr -force 0x0F700004 11
    for {set t 0} {$t < 40} {incr t} { after 50
      if {[expr {[lindex [mrd -force -value 0x0F700008] 0] & 0xFFFFFFFF}] != 0} break }
    after 120 }
  after 250 }
"""


def run_tcl(body, timeout=900):
    open("/tmp/_drive.tcl", "w").write(HEAD + body)
    if LOCAL:
        r = subprocess.run(["bash", "-c", "timeout %d %s /tmp/_drive.tcl 2>&1 | tail -5" % (timeout, XSDB)],
                           capture_output=True, text=True, timeout=timeout + 60)
        return r.stdout.strip()
    subprocess.run(["scp", "-q", "/tmp/_drive.tcl", HOST + ":/tmp/_drive.tcl"], check=True)
    r = subprocess.run(["ssh", HOST, "timeout %d %s /tmp/_drive.tcl 2>&1 | tail -5" % (timeout, XSDB)],
                       capture_output=True, text=True, timeout=timeout + 60)
    return r.stdout.strip()


def _need_font():
    if not os.path.exists("/tmp/vga866.h"):
        src = "/home/lavrinovich/bulb-v13/research/15-pentagon/arm/vga866.h"
        if LOCAL: subprocess.run(["cp", src, "/tmp/vga866.h"], check=True)
        else: subprocess.run(["scp", "-q", HOST + ":" + src, "/tmp/vga866.h"], check=True)


def shot(tag="shot"):
    _need_font()
    out = run_tcl('mrd -force -bin -file /tmp/osdc.bin 0x0F800000 256000\nputs SHOT_OK\n')
    if "SHOT_OK" not in out:
        print("снимок не снялся:", out); return None
    if not LOCAL: subprocess.run(["scp", "-q", HOST + ":/tmp/osdc.bin", "/tmp/osdc.bin"], check=True)
    txt = subprocess.run([sys.executable, os.path.join(HERE, "osd_ocr.py"), "/tmp/osdc.bin", "/tmp/vga866.h"],
                         capture_output=True, text=True).stdout
    print(txt)
    open("/tmp/%s.txt" % tag, "w").write(txt)
    return txt


def mkeys(args):
    """Клавиши В МАШИНУ (не в оболочку) через регистр 0xA8 {отпускание(бит8), скан-код}.

    Отдельный путь и отдельная таблица - потому что это ДРУГОЙ приёмник. Очередь cmd 11 кормит
    оболочку (её читает kbd_data_read), а матрицу Z80 наполняет только 0xA8, и он минует гейт OSD.
    Перепутать - значит нажимать в пустоту и искать несуществующий дефект.
    ⚠ Коды здесь СЫРЫЕ set-2, без свёртки: свёрткой префиксов занимается сама фабрика."""
    body = ""
    for a in args:
        code = int(a, 16) if a.startswith("0x") else KEYS.get(a.upper())
        if code is None:
            sys.exit("неизвестная клавиша машины: %s" % a)
        body += ("mwr -force 0x43C000A8 0x%02X\nafter 120\n"
                 "mwr -force 0x43C000A8 0x1%02X\nafter 200\n" % (code, code))
    body += "puts MKEYS_OK\n"
    out = run_tcl(body)
    print(out if "MKEYS_OK" in out else "инжект в машину не прошёл: " + out)


def main():
    if len(sys.argv) < 2 or sys.argv[1] == "shot":
        shot(); return
    if sys.argv[1] == "mkeys":
        mkeys(sys.argv[2:]); return
    if sys.argv[1] != "keys":
        sys.exit(__doc__)
    args = sys.argv[2:]
    nodump = "--nodump" in args
    args = [a for a in args if a != "--nodump"]
    body = ""
    for a in args:
        code = KEYS.get(a.upper()) if not a.startswith("0x") else int(a, 16)
        if code is None:
            sys.exit("неизвестная клавиша: %s" % a)
        body += "key 0x%02X\n" % code
    body += "puts KEYS_OK\n"
    out = run_tcl(body)
    if "KEYS_OK" not in out:
        print("инжект не прошёл:", out); return
    if not nodump:
        shot()


if __name__ == "__main__":
    main()
