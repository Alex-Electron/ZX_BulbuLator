# put_big.tcl - записать на карту БОЛЬШОЙ файл кусками: <локальный> <путь на карте>.
#
# Зачем отдельный писатель. `put_files.tcl` кладёт файл в буфер ЦЕЛИКОМ (`dow` в 0x0F900000), и на
# образе в 48 МБ это упирается в «Memory write error at 0x10000000. MMU section translation fault»:
# буфер столько не держит. Здесь файл идёт кусками - первый командой WRITE (2), остальные APPEND (7).
#
# ⚠ Кусок 4 МБ, и это не «на глаз»: окно памяти машины начинается с 0x0FE00000 и лежит ВНУТРИ
# 6-МБ диапазона буфера. Кусок больше 5 МБ затёр бы расширенные банки Пентагона (гоча проекта).
if {$argc != 2} { puts "нужно: <локальный> <путь на карте>"; exit 1 }
set src [lindex $argv 0]
set dst [lindex $argv 1]
if {![file exists $src]} { puts "нет файла: $src"; exit 1 }

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

set CH [expr {4 * 1024 * 1024}]
set sz [file size $src]
puts [format "VERSION=0x%08X  файл %d Б, кусками по %d" [rd 0x43C00000] $sz $CH]

set fh [open $src rb]
set off 0
set part 0
while {$off < $sz} {
    set n [expr {($sz - $off) > $CH ? $CH : ($sz - $off)}]
    seek $fh $off
    set blob [read $fh $n]
    set tmp "/tmp/_chunk.bin"
    set oh [open $tmp wb]; puts -nonewline $oh $blob; close $oh
    dow -data $tmp 0x0F900000
    wstr 0x0F700200 $dst
    mwr -force 0x0F700010 $n
    set r [cmd [expr {$off == 0 ? 2 : 7}] 9000]
    if {[lindex $r 0] != 1 || [lindex $r 1] != 0} {
        puts [format "  ОТКАЗ на куске %d (смещение %d): done=%s err=0x%X" $part $off [lindex $r 0] [lindex $r 1]]
        close $fh; exit 2
    }
    incr off $n
    incr part
    puts [format "  кусок %2d: %8d / %8d Б" $part $off $sz]
}
close $fh
puts "записано, теперь сверьте размер ЛИСТИНГОМ каталога (поле n доверять нельзя)"
exit
