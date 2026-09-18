# get_files.tcl - прочитать с карты файлы парами <путь на карте> <локальный>.
# Зеркало put_files.tcl. Гоча (оплачена испорченным bulbulator.ini 31.07): поле `len` у команды 12 -
# это ЗАПРОШЕННЫЙ ЛИМИТ, а не размер файла; не выставишь - прочитаешь остаток от прошлой операции.
# Сколько прочитано ФАКТИЧЕСКИ - в поле `n` (+0x14), по нему и режем файл.
# Пары можно передать и списком в файле: get_files.tcl -list <файл>, строки "<карта>\t<локальный>".
# Так надёжнее: у наших файлов бывают пробелы и скобки в именах (модули Amiga), а argv их разрывает.
set pairs {}
if {$argc == 2 && [lindex $argv 0] eq "-list"} {
    set f [open [lindex $argv 1] r]
    foreach line [split [read $f] "\n"] {
        if {[string trim $line] eq ""} continue
        set parts [split $line "\t"]
        lappend pairs [lindex $parts 0] [lindex $parts 1]
    }
    close $f
} elseif {$argc >= 2 && [expr {$argc % 2}] == 0} {
    set pairs $argv
} else { puts "нужно: <путь на карте> <локальный> \[...\]  или  -list <файл>"; exit 1 }
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }
proc wstr {a s} {
    for {set i 0} {$i < [string length $s]} {incr i} {
        scan [string index $s $i] %c c
        mwr -force -size b [expr {$a+$i}] $c
    }
    mwr -force -size b [expr {$a+[string length $s]}] 0
}
proc cmd {c tmo} {
    mwr -force 0x0F70000C 0
    mwr -force 0x0F700008 0
    mwr -force 0x0F700004 $c
    for {set t 0} {$t < $tmo} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }
    return [list [rd 0x0F700008] [rd 0x0F70000C]]
}

puts [format "VERSION=0x%08X" [rd 0x43C00000]]
set bad 0
foreach {src dst} $pairs {
    wstr 0x0F700200 $src
    mwr -force 0x0F700010 4194304            ;# лимит с запасом; ФАКТ смотрим в n
    set r [cmd 12 600]
    set n [rd 0x0F700014]
    if {[lindex $r 0] != 1 || [lindex $r 1] != 0 || $n == 0} {
        puts [format "  %-40s ОТКАЗ done=%s err=%s n=%d" $src [lindex $r 0] [lindex $r 1] $n]
        incr bad
        continue
    }
    # У mrd счётчик - В СЛОВАХ, а не в байтах (оплачено: файл вычитывался вчетверо длиннее,
    # ELYSTATE.TRD 655360 -> 2621440, хвост - чужая память). Читаем с округлением вверх и режем
    # файл до фактического числа байт из поля n.
    mrd -force -bin -file $dst 0x0F900000 [expr {($n + 3) / 4}]
    exec truncate -s $n $dst
    puts [format "  %-40s %8d Б -> %s" $src $n $dst]
}
puts "готово, отказов $bad"
exit
