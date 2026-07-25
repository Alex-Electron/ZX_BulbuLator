connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

# Symbols from the v0.15.115 stream-integrity diagnostic ELF.
# SHA-256: 0d73877b76b9b8d437aa699d626f7ca8a74313927c3ed6d5be41d39ed3f97c0d
set dbg 0x0015895C
for {set i 0} {$i < 18} {incr i} {
    set v [rd [expr {$dbg + 4*$i}]]
    puts [format "DBG%02d 0x%08X %u" $i $v $v]
}

puts [format "FPGA_VERSION 0x%08X" [rd 0x40000000]]
puts [format "TAPE_CTRL    0x%08X" [rd 0x4000009C]]
puts [format "TAPE_STATUS  0x%08X" [rd 0x400000A4]]
puts [format "Z80_PC       0x%04X" [expr {[rd 0x400000EC] & 0xFFFF}]]
puts [format "TAPE_ON      %u" [rd 0x0F700018]]
puts [format "FAST/SYNC/AUTO/SMART %u/%u/%u/%u" \
    [rd 0x0F70001C] [rd 0x0F700024] [rd 0x0F700028] [rd 0x0F700034]]
exit
