connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

# Fixed non-cacheable mailbox shared with the KVM host interface.
set fs_cmd  0x0F700004
set fs_done 0x0F700008
set fs_err  0x0F70000C
set fs_n    0x0F700014
set fs_path 0x0F700200
set fs_out  0x0F700800

# Ask the running firmware to list the SD-card root directory.
set path "0:/"
for {set i 0} {$i < [string length $path]} {incr i} {
    scan [string index $path $i] %c ch
    mwr -force -size b [expr {$fs_path + $i}] $ch
}
mwr -force -size b [expr {$fs_path + [string length $path]}] 0
mwr -force $fs_done 0
mwr -force $fs_err 0
mwr -force $fs_cmd 1

set done 0
for {set i 0} {$i < 100} {incr i} {
    after 50
    set done [rd $fs_done]
    if {$done != 0} { break }
}

set err [rd $fs_err]
set n [rd $fs_n]
puts [format "FS_DONE 0x%08X" $done]
puts [format "FS_ERR  %u" $err]
puts [format "FS_N    %u" $n]
if {$done == 1 && $err == 0 && $n > 0} {
    set dump_n $n
    if {$dump_n > 8192} { set dump_n 8192 }
    mrd -force -bin -file /tmp/v118_root.bin $fs_out $dump_n
}
exit
