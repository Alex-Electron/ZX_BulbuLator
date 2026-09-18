# put_files.tcl - записать на карту произвольные файлы парами <локальный> <путь на карте>.
# Один сеанс на все файлы: у мейлбокса нет очереди, два одновременных писателя дают ложное
# расхождение и недостоверный файл (проверено на своей ошибке).
if {$argc < 2 || [expr {$argc % 2}] != 0} { puts "нужно: <локальный> <назначение> \[...\]"; exit 1 }
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
wstr 0x0F700200 "0:/"
set ping [cmd 1 60]
if {[lindex $ping 0] != 1} { puts "FAIL мейлбокс молчит"; exit 1 }

foreach {src dst} $argv {
    if {![file exists $src]} { puts "  нет файла: $src"; continue }
    set sz [file size $src]
    wstr 0x0F700200 $dst
    mwr -force 0x0F700010 $sz
    dow -data $src 0x0F900000
    set wr [cmd 2 9000]
    if {[lindex $wr 0] != 1 || [lindex $wr 1] != 0} {
        puts [format "  ОТКАЗ %-26s done=%d err=0x%X" $dst [lindex $wr 0] [lindex $wr 1]]
        continue
    }
    wstr 0x0F700200 $dst
    mwr -force 0x0F700010 [expr {$sz > 65536 ? $sz : 65536}]
    mwr -force 0x0F700014 0
    cmd 12 9000
    set got [rd 0x0F700014]
    puts [format "  %-26s %8d Б -> прочитано %8d  %s" $dst $sz $got \
        [expr {$got == $sz ? "OK" : "РАСХОЖДЕНИЕ"}]]
}
exit
