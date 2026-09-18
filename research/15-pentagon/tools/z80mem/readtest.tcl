connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set G 0x43C00000
proc rd {a} { return [expr {[lindex [mrd -force -value $a] 0] & 0xFFFFFFFF}] }
proc wr {a v} { mwr -force $a $v }
# --- код Z80: банк 8 в окно 0xC000, записать B0..B7, прочитать обратно в экран,
#     затем «запись+сразу чтение», контроль в BRAM-банке, изолированное чтение после паузы
set code {0x3E 0x40 0x01 0xFD 0x7F 0xED 0x79 0x21 0x00 0xC0 0x11 0x00 0x40 0x06 0x00 0x7E 0x12 0x23 0x13 0x10 0xFA 0x21 0x00 0xC0 0x11 0x00 0x41 0x06 0x00 0x7E 0x12 0x23 0x13 0x10 0xFA 0x3E 0xE7 0x32 0x00 0x4A 0x18 0xFE}
# --- 1. сброс+вайп, затем HALT
wr [expr {$G+0x04}] 0x4
for {set t 0} {$t < 200} {incr t} { after 20; if {[rd [expr {$G+0x08}]] & 0x4} break }
for {set t 0} {$t < 400} {incr t} { after 20; if {!([rd [expr {$G+0x08}]] & 0x4)} break }
wr [expr {$G+0x04}] 0x1
for {set t 0} {$t < 200} {incr t} { after 10; if {[rd [expr {$G+0x08}]] & 0x1} break }
puts [format "STATUS после HALT = 0x%08X" [rd [expr {$G+0x08}]]]
# --- 2. код в банк 2 (окно 0x8000)
wr [expr {$G+0x10}] [expr {2 << 14}]
set n 0
foreach b $code { if {[string match "0x*" $b]} { wr [expr {$G+0x14}] $b; incr n } }
puts "залито байт кода: $n"
# --- 3. регистры: PC=0x8000, SP=0xBFFF, прерывания выключены, 7FFD=0
wr [expr {$G+0x3C}] 0x00
wr [expr {$G+0x40}] 0x00
wr [expr {$G+0x44}] 0x1
wr [expr {$G+0x20}] 0x00000000
wr [expr {$G+0x24}] [expr {0xBFFF << 16}]
wr [expr {$G+0x28}] 0x00008000
wr [expr {$G+0x2C}] 0x00000000
wr [expr {$G+0x30}] 0x00000000
wr [expr {$G+0x34}] 0x00000000
wr [expr {$G+0x38}] 0x00000000
wr [expr {$G+0x44}] 0x2
# --- 4. пуск
wr [expr {$G+0x04}] 0x0
after 400
puts [format "MACH_DBG=0x%08X (банк=%d 7FFD=0x%02X)  MEM_STAT=0x%08X" [rd [expr {$G+0x150}]] [expr {[rd [expr {$G+0x150}]] & 0x3F}] [expr {([rd [expr {$G+0x150}]]>>6)&0x3F}] [rd [expr {$G+0x14C}]]]
# --- 5. что ПРОЧИТАЛА машина (зеркало экрана)
after 1000
mrd -bin -file /tmp/z80res.bin 0x40008000 1728
# --- 6. что ЛЕЖИТ В DDR по банку 8
puts [format "DDR банк8 +0x00 = 0x%08X  +0x04 = 0x%08X   (ждём A3A2A1A0/B3B2B1B0 стиль)" [rd 0x0FE20000] [rd 0x0FE20004]]
puts [format "DDR банк8 +0x100 = 0x%08X   (младший байт ждём 0x5A)" [rd 0x0FE20100]]
exit
