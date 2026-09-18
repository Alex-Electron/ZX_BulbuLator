# Diagnostic PCAP loader: avoid XSDB's unstable multi-megabyte JTAG readback.
# The caller must verify the input .bit.bin SHA-256 before invoking this script.
# Success is still checked functionally by reading the configured PL VERSION.
set HERE [file dirname [file normalize [info script]]]
connect -url tcp:localhost:3121
configparams force-mem-accesses 1

if {[catch {targets -set -filter {name =~ "APU*"}}]} {
    targets -set -filter {name =~ "DAP*"}
}
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
after 200
proc r32b {a} { return [lindex [mrd -value $a] 0] }
set ver [r32b 0x40000000]
puts ">>> NES PL VERSION = [format 0x%08X $ver]  (ожидаем 0xB01BCE01)"
puts ">>> FB peek @0x0FF00000:"
foreach a {0x0FF00000 0x0FF00004 0x0FF00008 0x0FF0000C} { puts "   $a = [format 0x%08X [r32b $a]]" }
exit
