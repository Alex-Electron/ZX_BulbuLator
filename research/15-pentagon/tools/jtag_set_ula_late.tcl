# Set the current Sinclair machine's ULA Early/Late option through the
# non-cacheable firmware mailbox and verify the resulting MACHINE_CFG.
# args: 0 (Early) or 1 (Late)
if {$argc != 1 || ([lindex $argv 0] != 0 && [lindex $argv 0] != 1)} {
    puts "usage: jtag_set_ula_late.tcl <0|1>"
    exit 2
}
set late [lindex $argv 0]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}
set OPT_MACH 0x0F70002C
set OPT_LATE 0x0F70003C
set MACHCFG  0x400000BC
set machine [rd $OPT_MACH]
if {$machine == 1} {
    puts "ULA_SET_FAIL Pentagon has no Sinclair Early/Late option"
    exit 3
}
set want [expr {($machine == 2 ? 2 : 0) | ($late ? 4 : 0)}]
mwr -force $OPT_LATE $late
for {set n 0} {$n < 2000} {incr n} {
    if {[rd $MACHCFG] == $want} {
        puts [format "ULA_SET_OK machine=%u late=%u cfg=%08X" $machine $late [rd $MACHCFG]]
        exit
    }
    after 1
}
puts [format "ULA_SET_FAIL machine=%u late=%u cfg=%08X want=%08X" \
    $machine $late [rd $MACHCFG] $want]
exit 4
