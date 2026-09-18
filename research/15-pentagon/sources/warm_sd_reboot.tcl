# warm_sd_reboot.tcl - БЕЗОПАСНАЯ удалённая перезагрузка платы (без выдёргивания питания).
# Порядок критичен: QUIESCE (GP0+0x114=1) -> дождаться STATUS bit3 (все PL-мастера DDR встали)
# -> остановить ОБА Cortex-A9 -> rst -system -> BootROM грузится с SD. Сырой `rst -system` БЕЗ
# quiesce оставляет полуоткрытый бёрст в PS-овом AFI-FIFO S_AXI_HP0: hpw застревает на 1 и кадр
# замерзает при живом звуке, лечится только POR. Найдено 2026-07-29 (дважды: сначала как отказ,
# потом как рецепт).
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

set gp0       0x43C00000
set status    [expr {$gp0 + 0x08}]
set quiesce   [expr {$gp0 + 0x114}]

puts "PRE VERSION=[format 0x%08X [rd $gp0]]"
puts "PRE STATUS=[format 0x%08X [rd $status]]"
puts "PRE AC=[format 0x%08X [rd [expr {$gp0 + 0xAC}]]]"
puts "PRE B8=[format 0x%08X [rd [expr {$gp0 + 0xB8}]]]"

puts "REQUEST QUIESCE"
mwr -force $quiesce 1
set idle 0
for {set i 0} {$i < 10000} {incr i} {
    if {([rd $status] & 0x8) != 0} {
        set idle 1
        break
    }
    after 1
}
puts "QUIESCE idle=$idle status=[format 0x%08X [rd $status]] polls=$i"

if {!$idle} {
    puts "ERROR: AXI masters did not go idle; cancelling reset and releasing quiesce"
    mwr -force $quiesce 0
    exit 2
}

puts "STOP BOTH CORTEX CORES"
if {![catch {targets -set -filter {name =~ "*Cortex-A9*#1"}}]} {
    catch {stop}
}
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}

puts "SYSTEM RESET AFTER VERIFIED QUIESCE"
rst -system
after 1000

set selected 0
for {set i 0} {$i < 20} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}]} {
        set selected 1
        break
    }
    after 500
}
if {!$selected} {
    puts "ERROR: Cortex-A9#0 did not re-enumerate"
    exit 3
}

catch {con}
puts "BOOTROM/SD BOOT RELEASED; WAIT 20s"
after 20000

configparams force-mem-accesses 1
set version [rd $gp0]
set ac1 [rd [expr {$gp0 + 0xAC}]]
set b81 [rd [expr {$gp0 + 0xB8}]]
after 1500
set ac2 [rd [expr {$gp0 + 0xAC}]]
set b82 [rd [expr {$gp0 + 0xB8}]]

puts "POST VERSION=[format 0x%08X $version]"
puts "POST AC1=[format 0x%08X $ac1] AC2=[format 0x%08X $ac2]"
puts "POST B81=[format 0x%08X $b81] B82=[format 0x%08X $b82]"
puts "POST FIFO_OVERFLOW=[expr {($b82 >> 15) & 1}]"

if {1} {
    mrd -force -bin -file /tmp/warm_sd_reboot_frame.bin 0x0FF00000 15360
    puts "DUMP=/tmp/warm_sd_reboot_frame.bin"
} else {
    }

puts "QUIESCED_WARM_SD_REBOOT_OK"
exit
