# put_again.tcl - записать на карту то, что УЖЕ лежит в буфере мейлбокса, повторяя команду.
# Данные по JTAG идут минуты; если предыдущая попытка не смогла отдать команду (владелец работает в
# интерфейсе - файловая служба зовётся только из главного цикла), повторный dow не нужен.
# ⚠ Буфер сначала СВЕРЯЕТСЯ с локальным файлом в трёх точках: иначе можно записать мусор.
if {$argc != 2} { puts "нужно: <локальный> <путь на карте>"; exit 1 }
set src [lindex $argv 0]
set dst [lindex $argv 1]
set sz [file size $src]
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
# сверка буфера с файлом: начало, середина, конец
set f [open $src rb]
set bad 0
foreach off [list 0 [expr {$sz/2 & ~3}] [expr {($sz-64) & ~3}]] {
    seek $f $off
    binary scan [read $f 16] iu4 want
    set got {}
    for {set i 0} {$i < 4} {incr i} { lappend got [rd [expr {0x0F900000 + $off + $i*4}]] }
    for {set i 0} {$i < 4} {incr i} {
        if {[lindex $want $i] != [lindex $got $i]} {
            puts "буфер РАСХОДИТСЯ на смещении [expr {$off + $i*4}]: ждали [format 0x%08X [lindex $want $i]], в памяти [format 0x%08X [lindex $got $i]]"
            set bad 1
        }
    }
}
close $f
if {$bad} { puts "нужен повторный dow - выхожу, чтобы не записать мусор"; exit 1 }
puts "буфер сверен в трёх точках - совпадает; файл $sz Б"
wstr 0x0F700200 $dst
set ok 0
for {set try 1} {$try <= 60} {incr try} {
    mwr -force 0x0F70000C 0
    mwr -force 0x0F700008 0
    mwr -force 0x0F700010 $sz
    mwr -force 0x0F700004 2
    for {set t 0} {$t < 600} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }
    set d [rd 0x0F700008]; set e [rd 0x0F70000C]; set n [rd 0x0F700014]
    if {$d == 1} { puts "попытка $try: ГОТОВО, записано $n Б"; set ok 1; break }
    puts "попытка $try: done=$d err=[format 0x%X $e] - интерфейс занят, жду"
    after 5000
}
if {!$ok} { puts "НЕ ВЗЯЛА"; exit 1 }
exit
