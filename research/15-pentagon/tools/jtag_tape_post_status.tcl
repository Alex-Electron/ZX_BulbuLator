# Read-only end-of-tape report plus the established safe Z80 PC/SP snapshot.
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set KMB 0x0F700000
set DBG 0x00158F18
proc rd {addr} { return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}] }
puts [format "VERSION    0x%08X" [rd 0x40000000]]
puts [format "OPTIONS    fast=%u sync=%u auto=%u smart=%u tape_on=%u" \
    [rd [expr {$KMB+0x1c}]] [rd [expr {$KMB+0x24}]] [rd [expr {$KMB+0x28}]] \
    [rd [expr {$KMB+0x34}]] [rd [expr {$KMB+0x18}]]]
puts [format "FINGERPRINT count=%u hash=%08X gaps=%u resumes=%u" \
    [rd 0x400000E4] [rd 0x400000E8] [rd 0x400000EC] [rd 0x400000F0]]
for {set i 13} {$i <= 17} {incr i} {
    puts [format "DBG%02d      %08X" $i [rd [expr {$DBG+4*$i}]]]
}
puts [format "ROMTRAP    %08X" [rd 0x400000E0]]
# CPU snapshot registers share addresses with diagnostics while ROMTRAP is off.
mwr 0x40000004 1
for {set i 0} {$i < 1000} {incr i} {
    if {[rd 0x40000008] & 1} { break }
    after 1
}
mwr 0x400000E0 1
after 10
set r1 [rd 0x400000E8]
set r2 [rd 0x400000EC]
puts [format "Z80        PC=%04X SP=%04X" [expr {$r2 & 0xFFFF}] [expr {($r1 >> 16) & 0xFFFF}]]
mwr 0x400000E0 2
after 10
mwr 0x400000E0 0
mwr 0x40000004 0
exit
