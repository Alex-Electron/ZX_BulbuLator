# Read-only post-run probe for the Critical Mass regression image.
connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {a} { return [lindex [mrd -value $a] 0] }
puts [format "machine_cfg=%08X model=%08X tape_on=%08X pc=%04X" [rd 0x400000BC] [rd 0x0F70002C] [rd 0x0F700018] [expr {[rd 0x400000EC] & 0xFFFF}]]
for {set i 0} {$i < 16} {incr i} {
    puts [format "d%02d=%08X" $i [rd [expr {0x0015879C + 4*$i}]]]
}
for {set i 0} {$i < 11} {incr i} {
    puts [format "fe%02d=%08X" $i [rd [expr {0x001E0480 + 4*$i}]]]
}
