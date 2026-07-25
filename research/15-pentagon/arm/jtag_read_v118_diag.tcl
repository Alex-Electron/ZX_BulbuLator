connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

# Symbols from the v0.15.118 Critical-Mass tail-release diagnostic ELF.
# SHA-256: a624f9f9f1356eccf659ab4e3c8b71cf0a3ddb1b7277bfb10f4737bc486c68af
set dbg 0x001588DC
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
puts [format "MEMWR_CNT     %u" [rd 0x400000AC]]

# Raw port-FE read count captured when each TZX segment starts. This identifies
# the first block at which the guest stopped sampling the tape.
set fe_trace 0x001E0480
for {set i 0} {$i < 16} {incr i} {
    puts [format "FE%02d 0x%08X %u" $i [rd [expr {$fe_trace + 4*$i}]] [rd [expr {$fe_trace + 4*$i}]]]
}
exit
