# warm_dow_elf.tcl <elf> - загрузить прошивку по JTAG, НЕ трогая карту.
# Зачем: пока прошивка не проверена, BOOT.BIN на карте должен остаться рабочим - переставить карту
# без владельца нельзя, а тёплая перезагрузка с карты всегда вернёт заведомо живую сборку.
# QUIESCE перед сбросом ОБЯЗАТЕЛЕН: сырой `rst -system` на живой плате оставляет полуоткрытый бёрст
# в S_AXI_HP0, и это лечится только снятием питания (то есть присутствием человека).
# Параметром, а не копией со правкой: копии-с-правкой в этом проекте уже дважды грузили не то.
if {$argc < 1} { puts "usage: xsdb warm_dow_elf.tcl <loader.elf>"; exit 1 }
set elf [lindex $argv 0]

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} { return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}] }

set gp0     0x43C00000
set status  [expr {$gp0 + 0x08}]
set quiesce [expr {$gp0 + 0x114}]

puts "PRE VERSION=[format 0x%08X [rd $gp0]]"

puts "REQUEST QUIESCE"
mwr -force $quiesce 1
set idle 0
for {set i 0} {$i < 10000} {incr i} {
    if {([rd $status] & 0x8) != 0} { set idle 1; break }
    after 1
}
puts "QUIESCE idle=$idle polls=$i"
if {!$idle} {
    puts "ERROR: PL-мастера не встали; сброс отменён"
    mwr -force $quiesce 0
    exit 2
}

if {![catch {targets -set -filter {name =~ "*Cortex-A9*#1"}}]} { catch {stop} }
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}

puts "SYSTEM RESET AFTER VERIFIED QUIESCE"
rst -system
after 1000

set selected 0
for {set i 0} {$i < 20} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}]} { set selected 1; break }
    after 500
}
if {!$selected} { puts "ERROR: Cortex-A9#0 не переобнаружился"; exit 3 }

puts "PS7 INIT"
source /home/lavrinovich/sdboot/ws/ebaz/hw/ps7_init.tcl
ps7_init
ps7_post_config

puts "DOWNLOAD $elf"
dow $elf
con
puts "RUNNING; WAIT 25s (в это время прошивка монтирует карту и поднимает сеть)"
after 25000

configparams force-mem-accesses 1
puts "POST VERSION=[format 0x%08X [rd $gp0]]"
# состояние сети из мейлбокса: KMB+0x60 статус, KMB+0x64 адрес
set kst [rd 0x0F700060]
set kip [rd 0x0F700064]
puts "NET STAT=[format 0x%08X $kst]"
puts "NET IP=[expr {$kip & 0xFF}].[expr {($kip >> 8) & 0xFF}].[expr {($kip >> 16) & 0xFF}].[expr {($kip >> 24) & 0xFF}]"
puts "WARM_DOW_OK"
exit
