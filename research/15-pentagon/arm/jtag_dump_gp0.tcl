connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}]
}

for {set i 0} {$i < 64} {incr i} {
    puts [format "GP%02X 0x%08X" [expr {$i*4}] [rd [expr {0x40000000 + 4*$i}]]]
}
exit
