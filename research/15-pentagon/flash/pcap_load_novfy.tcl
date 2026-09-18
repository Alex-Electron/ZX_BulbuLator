# Diagnostic PCAP loader: avoid XSDB's unstable multi-megabyte JTAG readback.
# The caller must verify the input .bit.bin SHA-256 before invoking this script.
# Success is still checked functionally by reading the configured PL VERSION.
set HERE [file dirname [file normalize [info script]]]
connect -url tcp:localhost:3121
configparams force-mem-accesses 1

if {[catch {targets -set -filter {name =~ "APU*"}}]} {
    targets -set -filter {name =~ "DAP*"}
}
# ====== v02.08 ОБЯЗАТЕЛЬНЫЙ QUIESCE ПЕРЕД СБРОСОМ (совет консулов) ======
# Сырой `rst -system` на ЖИВОЙ плате оставляет полуоткрытый бёрст в AFI-FIFO порта S_AXI_HP0:
# кадр в DDR замерзает при живом ядре и живом звуке, и это НЕ лечится ни перепрошивкой, ни
# FPGA_RST_CTRL - только холодным стартом. Правильная последовательность лежала рядом, в
# sources/warm_sd_reboot.tcl, но сюда её не перенесли. Просим ядро остановить своих DDR-мастеров
# и ждём подтверждения (STATUS бит3); если подтверждения нет - продолжаем, но громко предупреждаем.
catch {
    mwr -force 0x43C00114 1
    set quiesced 0
    for {set q 0} {$q < 2000} {incr q} {
        after 1
        if {[expr {[lindex [mrd -force -value 0x43C00008] 0] & 8}] != 0} { set quiesced 1; break }
    }
}
# STATUS = GP0+0x08 (сверено с sources/warm_sd_reboot.tcl:15), бит3 = все PL-мастера DDR встали.
if {![info exists quiesced] || !$quiesced} {
    puts "ОТКАЗ: QUIESCE не подтверждён - сброс НЕ делаем."
    puts "Иначе полуоткрытый бёрст залипнет в AFI-FIFO и лечиться будет только холодным стартом."
    puts "Если плата заведомо мертва и это осознанно, снимите проверку вручную."
    exit 1
}
puts "QUIESCE ok"
catch {rst -system}
after 50
targets -set -filter {name =~ "*Cortex-A9*#1"}
catch {stop}
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
after 200
source [file join $HERE ps7_init_fclk.tcl]
ps7_init

set BIN [file join $HERE .. bulbulator_zx_osd.bit.bin]
if {[info exists ::env(PCAP_BIN)]} { set BIN $::env(PCAP_BIN) }
set ADDR 0x00100000
set size [file size $BIN]
set words [expr {$size / 4}]
puts ">>> PCAP no-readback: writing $size verified bytes to DDR @$ADDR"
dow -data $BIN $ADDR

proc r32 {a} { return [lindex [mrd -value $a] 0] }
mwr 0xF8007034 0x757BDF0D
mwr 0xF8007080 [expr {[r32 0xF8007080] & ~0x10}]
set ctrl [expr {[r32 0xF8007000] | 0x0C000000}]
mwr 0xF8007000 $ctrl
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
mwr 0xF8007000 [expr {$ctrl & ~0x40000000}]
set t 0
while {([r32 0xF8007014] & 0x10) != 0} { incr t; if {$t > 2000} { puts ">>> FAIL: INIT did not fall"; exit 1 } }
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
set t 0
while {([r32 0xF8007014] & 0x10) == 0} { incr t; if {$t > 2000} { puts ">>> FAIL: INIT did not rise"; exit 1 } }

mwr 0xF800700C 0xFFFFFFFF
mwr 0xF8007018 [expr {$ADDR | 1}]
mwr 0xF800701C 0xFFFFFFFF
mwr 0xF8007020 $words
mwr 0xF8007024 0
set t 0
while {([r32 0xF800700C] & 0x2000) == 0} { incr t; if {$t > 30000} { puts ">>> FAIL: DMA timeout"; exit 1 } }
set t 0
while {([r32 0xF800700C] & 0x4) == 0} { incr t; if {$t > 30000} { puts ">>> FAIL: PCFG_DONE timeout"; exit 1 } }
ps7_post_config
puts ">>> PCAP_DONE_NO_READBACK"
exit
