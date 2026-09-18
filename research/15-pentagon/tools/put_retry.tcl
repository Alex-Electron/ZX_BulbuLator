# put_retry.tcl - положить файл на карту БЕЗОПАСНО: буфер сверяется перед каждой попыткой, а
# записанный файл читается обратно и сверяется.
#
# 🥇 Оплачено испорченным BOOT.BIN и незагружающейся платой 20.08. Буфер мейлбокса (0x0F900000) -
# ОБЩИЙ с файловой службой прошивки. `dow` образа идёт минуты, потом команда записи может ждать
# свободного интерфейса ещё минуты - и за это время прошивка читает в ТОТ ЖЕ буфер свой файл.
# У нас это был набор ПЗУ (ровно 65536 Б, читается при сбросе машины и смене набора): на карту легли
# 64 КБ кода Z80 плюс остаток образа. Размер файла правильный, мейлбокс отчитался успехом, а BootROM
# такой заголовок не принял - плата не загрузилась И заперла отладочный доступ (ядра видны как
# Running, но память по JTAG не читается вовсе, лечится только холодным старом).
# Отсюда два обязательных правила, встроенные ниже:
#   1) сверять буфер НЕПОСРЕДСТВЕННО перед каждой попыткой записи, а не один раз после dow;
#   2) проверять РЕЗУЛЬТАТ - читать файл обратно (cmd 12) и сверять, а не верить полям done/n.
if {$argc != 2} { puts "нужно: <локальный> <путь на карте>"; exit 1 }
set src [lindex $argv 0]
set dst [lindex $argv 1]
if {![file exists $src]} { puts "нет файла: $src"; exit 1 }
set sz [file size $src]
if {$sz > 4194304} { puts "файл больше 4 МБ - нужен put_big.tcl"; exit 1 }

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }
proc wstr {a s} {
    for {set i 0} {$i < [string length $s]} {incr i} { scan [string index $s $i] %c c; mwr -force -size b [expr {$a+$i}] $c }
    mwr -force -size b [expr {$a+[string length $s]}] 0
}
# Точки сверки: начало обязательно (именно его затирает чужое чтение), плюс середина и конец.
proc probes {sz} {
    set p [list 0 4 8 12 [expr {$sz/2 & ~3}] [expr {($sz-64) & ~3}]]
    for {set o 0x1000} {$o < $sz && $o <= 0x20000} {set o [expr {$o*2}]} { lappend p [expr {$o & ~3}] }
    return $p
}
proc buf_ok {src sz base} {
    set f [open $src rb]
    set bad 0
    foreach off [probes $sz] {
        seek $f $off
        binary scan [read $f 4] iu w
        set got [expr {[lindex [mrd -force -value [expr {$base + $off}]] 0] & 0xFFFFFFFF}]
        if {($w & 0xFFFFFFFF) != $got} { set bad 1; break }
    }
    close $f
    return [expr {!$bad}]
}
proc send {src} { dow -data $src 0x0F900000 }

puts "VERSION=[format 0x%08X [rd 0x43C00000]]  файл $sz Б"
puts "данные в буфер (минуты)..."
send $src
wstr 0x0F700200 $dst
set ok 0
for {set try 1} {$try <= 60} {incr try} {
    if {![buf_ok $src $sz 0x0F900000]} {
        puts "попытка $try: БУФЕР ИСПОРЧЕН файловой службой прошивки - отправляю данные заново"
        send $src
    }
    mwr -force 0x0F70000C 0
    mwr -force 0x0F700008 0
    mwr -force 0x0F700010 $sz
    mwr -force 0x0F700004 2
    for {set t 0} {$t < 600} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }
    set d [rd 0x0F700008]
    if {$d == 1} { puts "попытка $try: записано [rd 0x0F700014] Б"; set ok 1; break }
    puts "попытка $try: done=$d err=[format 0x%X [rd 0x0F70000C]] - интерфейс занят, жду"
    after 5000
}
if {!$ok} { puts "НЕ ВЗЯЛА"; exit 1 }

# ---- проверка РЕЗУЛЬТАТА: читаем файл обратно и сверяем начало (там и была порча) ----
set lim 65536
if {$sz < $lim} { set lim $sz }
mwr -force 0x0F70000C 0
mwr -force 0x0F700008 0
mwr -force 0x0F700010 $lim
mwr -force 0x0F700004 12
for {set t 0} {$t < 600} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }
if {[rd 0x0F700008] != 1} { puts "ПРОВЕРКА НЕ ВЫПОЛНЕНА: чтение файла не прошло (done=[rd 0x0F700008])"; exit 1 }
set n [rd 0x0F700014]
puts "прочитано обратно $n Б из $lim"
set f [open $src rb]
set bad 0
foreach off [list 0 4 8 12 256 1024 4096 16384 32768 65532] {
    if {$off >= $lim} continue
    seek $f $off
    binary scan [read $f 4] iu w
    set got [expr {[lindex [mrd -force -value [expr {0x0F900000 + $off}]] 0] & 0xFFFFFFFF}]
    if {($w & 0xFFFFFFFF) != $got} {
        puts "РАСХОЖДЕНИЕ на смещении $off: ждали [format 0x%08X [expr {$w & 0xFFFFFFFF}]], в файле [format 0x%08X $got]"
        set bad 1
    }
}
close $f
if {$bad} { puts "ФАЙЛ НА КАРТЕ ИСПОРЧЕН - НЕ переименовывать поверх боевого!"; exit 1 }
puts "ГОТОВО: файл записан и сверен по началу файла"
exit
