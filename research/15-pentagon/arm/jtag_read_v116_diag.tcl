connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

# v0.15.116 = exact known-good v0.15.17 codebase plus passive stream hashes.
# SHA-256: 47402f4c2afdd9e88ebcb5c28193b508be42b6309eab7965f7fc4d3a0019c853
set dbg 0x0014E854
for {set i 0} {$i < 18} {incr i} {
    set v [rd [expr {$dbg + 4*$i}]]
    puts [format "DBG%02d 0x%08X %u" $i $v $v]
}

puts [format "FPGA_VERSION 0x%08X" [rd 0x40000000]]
puts [format "TAPE_CTRL    0x%08X" [rd 0x4000009C]]
puts [format "TAPE_STATUS  0x%08X" [rd 0x400000A4]]
puts [format "Z80_PC       0x%04X" [expr {[rd 0x400000EC] & 0xFFFF}]]
exit
