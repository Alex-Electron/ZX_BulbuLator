# lock_test.tcl - проверка замка страничности после входа в загрузку: процессору подсовывается
# LD BC,#7FFD : LD A,#17 : OUT (C),A : JR $ (буфер принтера #5B00), затем читается MACH_DBG. Порты прибор НЕ пишет
# (только DIR/PC), иначе он сам обошёл бы замок. Запертая машина оставит #7FFD как был, открытая покажет #17.
# locktest.tcl - попытка программы сменить #7FFD после входа в загрузку: LD BC,#7FFD : LD A,#17 : OUT (C),A : JR $
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set G 0x43C00000
proc rd {a} { return [expr {[mrd -force -value $a] & 0xFFFFFFFF}] }
proc dbg {tag} { set m [rd 0x43C00150]; puts [format "%s: 7FFD=%02X EFF7=%02X" $tag [expr {($m>>6)&0x3F}] [expr {($m>>14)&0xFF}]] }
dbg "до"
mwr -force [expr {$G+0x04}] 1
for {set t 0} {$t < 200} {incr t} { if {[rd [expr {$G+0x08}]] & 1} break; after 5 }
mwr -force [expr {$G+0x10}] [expr {(5<<14)+0x1B00}]
foreach b {0x01 0xFD 0x7F 0x3E 0x17 0xED 0x79 0x18 0xFE} { mwr -force [expr {$G+0x14}] $b; for {set t 0} {$t < 100} {incr t} { if {!([rd [expr {$G+0x08}]] & 2)} break } }
set d [list 0 [expr {0x5C00<<16}] 0x5B00 0 0 0 0]
for {set k 0} {$k < 7} {incr k} { mwr -force [expr {$G+0x20+4*$k}] [lindex $d $k] }
mwr -force [expr {$G+0x44}] 2
mwr -force [expr {$G+0x04}] 0
after 400
dbg "после OUT (#7FFD),#17"
