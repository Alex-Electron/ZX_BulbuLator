#!/usr/bin/env python3
"""nes_upload_gen.py - сгенерировать xsdb-скрипт, который заливает стейдж ромов на SD платы
через мейлбокс файловой службы (JTAG, без выдёргивания карты).

    python3 nes_upload_gen.py <стейдж на ThinkPad> [префикс на карте] > /tmp/putnes.tcl
    xsdb /tmp/putnes.tcl        # ~13 минут на 164 файла / 11.6 МБ

Стейдж должен уже лежать НА ThinkPad (dow читает файл локально):
    rsync -a <стейдж>/ thinkpad:nesup_stage/

Три гочи мейлбокса, каждая однажды стоила данных - все обойдены здесь:
  1. `err` (+0xC) прошивка НЕ обнуляет при успехе -> обнуляем перед каждой командой, иначе примешь
     удачную запись за провал (я так «потерял» 20 файлов, которые легли нормально).
  2. Мейлбокс молчит, пока открыт OSD (процессор не в главном цикле). НЕ инжектим Esc: если владелец
     в визарде маппинга, любая клавиша станет назначением кнопки. Вместо этого терпеливо ждём.
  3. Путь на карте должен быть < 77 знаков - предел браузера прошивки (curpath + имя < 78).
     Фильтрует nes_pick.py, здесь только проверяется.
"""
import os, sys, json

CARD_PREFIX_DEFAULT = "0:/NES"
MAX_PATH = 77


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 1
    stage = sys.argv[1].rstrip("/")
    card = (sys.argv[2] if len(sys.argv) > 2 else CARD_PREFIX_DEFAULT).rstrip("/")

    sel_file = os.path.join(stage, "_selection.json")
    if os.path.exists(sel_file):
        sel = [(d[1], d[5]) for d in json.load(open(sel_file))]
    else:                                              # без списка - обходим стейдж
        sel = []
        for dp, dn, fn in os.walk(stage):
            for f in sorted(fn):
                if f.lower().endswith(".nes"):
                    rel = os.path.relpath(os.path.join(dp, f), stage).replace(os.sep, "/")
                    sel.append((rel, os.path.getsize(os.path.join(dp, f))))
        sel.sort()

    too_long = [d for d, _ in sel if len(card + "/" + d) >= MAX_PATH]
    if too_long:
        sys.stderr.write("ПРЕДУПРЕЖДЕНИЕ: %d путей >= %d знаков, браузер их не откроет:\n  %s\n"
                         % (len(too_long), MAX_PATH, "\n  ".join(too_long[:5])))

    dirs = set(os.path.dirname(d) for d, _ in sel)
    alld = set()
    for d in dirs:
        parts = [p for p in d.split("/") if p]
        for i in range(1, len(parts) + 1):
            alld.add("/".join(parts[:i]))
    order = sorted(alld, key=lambda p: (p.count("/"), p))

    L = []
    a = L.append
    a("connect -url tcp:localhost:3121")
    a('targets -set -filter {name =~ "*Cortex-A9*#0"}')
    a("configparams force-mem-accesses 1")
    a("proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }")
    a("proc wstr {a s} { for {set i 0} {$i < [string length $s]} {incr i} "
      "{ scan [string index $s $i] %c c; mwr -force -size b [expr {$a+$i}] $c }; "
      "mwr -force -size b [expr {$a+[string length $s]}] 0 }")
    a("# ГОЧА 1: err не обнуляется прошивкой на успехе -> обнуляем сами")
    a("proc cmd {c tmo} { mwr -force 0x0F70000C 0; mwr -force 0x0F700008 0; mwr -force 0x0F700004 $c; "
      "for {set t 0} {$t < $tmo} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }; "
      "return [list [rd 0x0F700008] [rd 0x0F70000C]] }")
    a("# ГОЧА 2: ждём, пока служба ответит; OSD НЕ трогаем (владелец может быть в визарде маппинга)")
    a('puts "ждём файловую службу (до 20 минут)"')
    a("set ready 0")
    a("for {set w 0} {$w < 240} {incr w} { set r [cmd 1 20]; "
      "if {[lindex $r 0] != 0} { set ready 1; break }; after 5000 }")
    a('if {!$ready} { puts "служба не ответила - СТОП"; exit 1 }')
    a('puts "служба отвечает"')
    for d in order:
        a("wstr 0x0F700200 {%s/%s}" % (card, d))
        a("cmd 5 60")
    a('puts "каталоги готовы, пишу файлы"')
    a("set n 0; set bad 0; set bytes 0")
    for i, (dest, size) in enumerate(sel):
        a("wstr 0x0F700200 {%s/%s}" % (card, dest))
        a("mwr -force 0x0F700010 %d" % size)
        a("dow -data {%s/%s} 0x0F900000" % (stage, dest))
        a("set r [cmd 2 300]")
        a('if {[lindex $r 0] != 1 || [lindex $r 1] != 0} { incr bad; '
          'puts "  ОШИБКА %d: done=[lindex $r 0] err=[format 0x%%X [lindex $r 1]]" } '
          'else { incr n; incr bytes %d }' % (i, size))
        if (i + 1) % 25 == 0:
            a('puts "  ... $n записано, $bad ошибок, $bytes байт"')
    a('puts "ИТОГ: $n из %d, ошибок $bad, $bytes байт"' % len(sel))
    a("exit")
    sys.stdout.write("\n".join(L) + "\n")
    sys.stderr.write("сгенерировано: %d файлов, %d каталогов\n" % (len(sel), len(order)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
