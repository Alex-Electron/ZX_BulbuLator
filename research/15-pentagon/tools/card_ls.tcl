# card_ls.tcl - листинг каталога на карте платы через почтовый ящик прошивки (команда 1).
#
#   xsdb tools/card_ls.tcl 0:/CORES
#
# Печатает имя, размер и тип (F - файл, D - каталог). Этим сверяют размер только что залитого файла:
# поле «записано» и признак «готово» почтового ящика при нехватке места врут, листинг - нет.
# Условия те же, что у put_retry.tcl: hw_server на :3121, прошивка работает, меню закрыто, лента не идёт.
# Имена длиннее 96 знаков в листинге обрезаются (буфер оболочки), сам файл при этом цел.
set p [expr {[llength $argv] ? [lindex $argv 0] : "0:/"}]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
set M 0x0F700000
proc wstr {a s} { for {set i 0} {$i < [string length $s]} {incr i} { scan [string index $s $i] %c c; mwr -force -size b [expr {$a+$i}] $c }; mwr -force -size b [expr {$a+[string length $s]}] 0 }
set ok 0
for {set t 0} {$t < 60 && !$ok} {incr t} {
  wstr [expr {$M+0x200}] $p
  mwr -force [expr {$M+0xC}] 0; mwr -force [expr {$M+8}] 0; mwr -force [expr {$M+4}] 1
  for {set k 0} {$k < 20} {incr k} { after 100; if {[mrd -force -value [expr {$M+8}]] != 0} { set ok 1; break } }
  if {!$ok} { after 1000 }
}
if {!$ok} { puts "listing: the mailbox did not answer (menu open or tape running?)"; exit 1 }
set err [expr {[mrd -force -value [expr {$M+0xC}]] & 0xFFFFFFFF}]
if {$err} { puts "listing $p: err=$err"; exit 1 }
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] card_ls_[pid].bin]
mrd -force -bin -file $tmp [expr {$M+0x800}] 3072
set f [open $tmp rb]; set raw [read $f]; close $f; file delete $tmp
set z [string first "\0" $raw]; if {$z >= 0} { set raw [string range $raw 0 [expr {$z-1}]] }
foreach line [split $raw "\n"] {
  set q [split [string trimright $line "\r"] "\t"]
  if {[llength $q] == 3} { puts [format "  %-40s %10s %s" [lindex $q 0] [lindex $q 1] [lindex $q 2]] }
}
