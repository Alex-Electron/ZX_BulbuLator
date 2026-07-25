connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

# Fixed non-cacheable control-mailbox options: force the one-variable 1x/manual test.
mwr -force 0x0F70001C 0
mwr -force 0x0F700024 0
mwr -force 0x0F700028 0
mwr -force 0x0F700034 0

puts [format "FAST  %u" [lindex [mrd -force -value 0x0F70001C] 0]]
puts [format "SYNC  %u" [lindex [mrd -force -value 0x0F700024] 0]]
puts [format "AUTO  %u" [lindex [mrd -force -value 0x0F700028] 0]]
puts [format "SMART %u" [lindex [mrd -force -value 0x0F700034] 0]]
exit
