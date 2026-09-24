# card_mv.tcl - переименовать файл на карте платы через почтовый ящик прошивки (команда 4).
#
#   xsdb tools/card_mv.tcl 0:/OLD.NAME 0:/NEW.NAME
#
# Нужен запущенный hw_server на :3121 и работающая прошивка с открытым навигатором: пока открыто меню
# или идёт лента, почтовый ящик не обслуживается, и скрипт повторяет команду до минуты.
# Пути пишутся в ящик ПОБАЙТНО (mwr -size b): запись словом по невыровненному адресу отдаёт пустой путь.
# Типичное применение - последний шаг безопасной заливки: put_retry.tcl во временный файл, сверка размера
# листингом каталога, затем это переименование поверх рабочего файла.
set a [lindex $argv 0]; set b [lindex $argv 1]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
set M 0x0F700000
proc wstr {a s} { for {set i 0} {$i < [string length $s]} {incr i} { scan [string index $s $i] %c c; mwr -force -size b [expr {$a+$i}] $c }; mwr -force -size b [expr {$a+[string length $s]}] 0 }
for {set t 0} {$t < 60} {incr t} {
  wstr [expr {$M+0x200}] $a; wstr [expr {$M+0x400}] $b
  mwr -force [expr {$M+8}] 0; mwr -force [expr {$M+0xC}] 0; mwr -force [expr {$M+4}] 4
  for {set k 0} {$k < 20} {incr k} { after 100; if {[mrd -force -value [expr {$M+8}]] != 0} break }
  if {[mrd -force -value [expr {$M+8}]] != 0} { puts "rename $a -> $b err=[mrd -force -value [expr {$M+0xC}]]"; exit }
  after 1000
}
puts "rename: мейлбокс не ответил"
