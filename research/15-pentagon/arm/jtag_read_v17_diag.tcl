connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}]
}

# Symbols from the exact known-good v0.15.17 ELF
# SHA-256: 052279813228a41396f384a9b512fd671268988197937b32e32cd259d7fe1b19
set dbg 0x0014E78C
for {set i 0} {$i < 16} {incr i} {
    set v [rd [expr {$dbg + 4*$i}]]
    puts [format "DBG%02d 0x%08X %u" $i $v $v]
}

puts [format "FPGA_VERSION 0x%08X" [rd 0x40000000]]
puts [format "TAPE_CTRL    0x%08X" [rd 0x4000009C]]
puts [format "TAPE_STATUS  0x%08X" [rd 0x400000A4]]
puts [format "Z80_PC       0x%04X" [expr {[rd 0x400000EC] & 0xFFFF}]]
puts [format "TAPE_ON      %u" [rd 0x001D4104]]
puts [format "BLK_PTR      %u" [rd 0x001D410C]]
puts [format "PULSE_W      %u" [rd 0x001F4444]]
puts [format "PULSE_R      %u" [rd 0x001F4448]]

for {set i 0} {$i < 64} {incr i} {
    puts [format "GP%02X 0x%08X" [expr {$i*4}] [rd [expr {0x40000000 + 4*$i}]]]
}
exit
