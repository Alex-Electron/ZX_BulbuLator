connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}]
}

set dbg 0x0015889C
for {set i 0} {$i < 16} {incr i} {
    puts [format "DBG%02d 0x%08X %u" $i [rd [expr {$dbg + 4*$i}]] [rd [expr {$dbg + 4*$i}]]]
}

puts [format "FPGA_VERSION 0x%08X" [rd 0x40000000]]
puts [format "TAPE_CTRL    0x%08X" [rd 0x4000009C]]
puts [format "TAPE_STATUS  0x%08X" [rd 0x400000A4]]
puts [format "Z80_PC       0x%04X" [expr {[rd 0x400000EC] & 0xFFFF}]]
puts [format "TAPE_ON      %u" [rd 0x0F700018]]
puts [format "FAST/SYNC/AUTO/SMART %u/%u/%u/%u" \
    [rd 0x0F70001C] [rd 0x0F700024] [rd 0x0F700028] [rd 0x0F700034]]
for {set i 0} {$i < 64} {incr i} {
    puts [format "GP%02X 0x%08X" [expr {$i*4}] [rd [expr {0x40000000 + 4*$i}]]]
}
mrd -force -bin -file /tmp/critical_mass_dump.tzx 0x001A01A0 47431
exit
