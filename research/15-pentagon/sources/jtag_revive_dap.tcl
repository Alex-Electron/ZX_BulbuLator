# jtag_revive_dap.tcl - ОЖИВИТЬ ПЛАТУ, когда ядра исчезли из JTAG (без снятия питания).
#
# Признак отказа: `targets` показывает только
#     1  DAP (APB AP transaction error, DAP status 0x30000021)
#     2  xc7z010
# то есть отладочный APB мёртв, Cortex-ов нет, память через DAP не читается
# («Context does not support memory read»), значит и QUIESCE не записать.
#
# Что РАБОТАЕТ: `rst -system`, поданный на цель **DAP**. Дальше BootROM берёт образ с карты.
# Что НЕ работает (проверено 2026-08-05):
#   * `rst -por`      -> «por not supported for target» (на Zynq-7000 через xsdb POR недоступен)
#   * `rst -system` на цели `xc7z010` -> «Invalid reset type»
#   * доступ к памяти через DAP -> «Unsupported command»
# Если пропала и цепочка целиком - сначала поднять сервер:
#   /tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server -s tcp::3121
#
# Чем это НЕ является: лечением полуоткрытого бёрста в S_AXI_HP0 (замёрзший кадр при живом звуке) -
# там по-прежнему нужен настоящий POR. Это другой отказ: умерший отладочный APB.
connect -url tcp:localhost:3121

if {[catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}]} {
    puts "ЯДРА НЕ ВИДНЫ - оживляю через DAP"
    targets -set -filter {name =~ "DAP*"}
    rst -system
    after 4000
    set ok 0
    for {set i 0} {$i < 30} {incr i} {
        if {![catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}]} { set ok 1; break }
        after 500
    }
    if {!$ok} { puts "НЕ ПОМОГЛО - нужен человек и питание"; exit 4 }
    puts "ядра вернулись"
} else {
    puts "ядра видны, сброс не требуется"
}

configparams force-mem-accesses 1
catch {con}
puts "ОТПУЩЕН; загрузка с карты, ждём 25 с"
after 25000

proc rd {addr} { return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}] }
set gp0 0x43C00000
puts "VERSION=[format 0x%08X [rd $gp0]]"
set a1 [rd [expr {$gp0 + 0xAC}]]
after 1500
set a2 [rd [expr {$gp0 + 0xAC}]]
puts "HPW=[format 0x%08X $a1] -> [format 0x%08X $a2] (растёт = кадр живой)"
puts "REVIVE_OK"
exit
