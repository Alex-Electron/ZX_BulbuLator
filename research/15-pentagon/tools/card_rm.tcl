# card_rm.tcl - удалить файл или ПУСТОЙ каталог на карте (команда 3). xsdb card_rm.tcl 0:/PATH
set p [lindex $argv 0]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
set M 0x0F700000
proc wstr {a s} { for {set i 0} {$i < [string length $s]} {incr i} { scan [string index $s $i] %c c; mwr -force -size b [expr {$a+$i}] $c }; mwr -force -size b [expr {$a+[string length $s]}] 0 }
for {set t 0} {$t < 60} {incr t} {
  wstr [expr {$M+0x200}] $p
  mwr -force [expr {$M+8}] 0; mwr -force [expr {$M+0xC}] 0; mwr -force [expr {$M+4}] 3
  for {set k 0} {$k < 20} {incr k} { after 100; if {[mrd -force -value [expr {$M+8}]] != 0} break }
  if {[mrd -force -value [expr {$M+8}]] != 0} { puts "rm $p err=[mrd -force -value [expr {$M+0xC}]]"; exit }
  after 1000
}
puts "rm: мейлбокс не ответил"
