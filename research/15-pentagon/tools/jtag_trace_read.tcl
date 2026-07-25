# Read B0048's retained post-run IN-FE trace.  ROMTRAP must be disabled.
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {a} { return [expr {[lindex [mrd -value $a] 0] & 0xFFFFFFFF}] }
puts [format "VERSION=%08X TRACE fe_count=%u cpu_hash=%08X ula_hash=%08X" \
    [rd 0x40000000] [rd 0x400000F4] [rd 0x400000F8] [rd 0x400000FC]]
exit
