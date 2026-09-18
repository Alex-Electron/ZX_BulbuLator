connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set fs_cmd  0x0F700004
set fs_done 0x0F700008
set fs_err  0x0F70000C
set fs_len  0x0F700010
set fs_path 0x0F700200
set fs_buf  0x0F900000

proc write_str {addr str} {
    for {set i 0} {$i < [string length $str]} {incr i} {
        scan [string index $str $i] %c ch
        mwr -force -size b [expr {$addr + $i}] $ch
    }
    mwr -force -size b [expr {$addr + [string length $str]}] 0
}

proc run_cmd {cmd} {
    global fs_cmd fs_done fs_err
    mwr -force $fs_done 0
    mwr -force $fs_cmd $cmd
    set done 0
    for {set t 0} {$t < 5} {incr t} {
        after 1000
        set done [expr {[lindex [mrd -force -value $fs_done] 0] & 0xFFFFFFFF}]
        if {$done != 0} { break }
    }
    set err [expr {[lindex [mrd -force -value $fs_err] 0] & 0xFFFFFFFF}]
    if {$done != 1 || $err != 0} {
        puts "CMD $cmd FAIL (done: $done, err: $err)"
        return 0
    }
    return 1
}

# Write TEST.TXT
write_str $fs_path "0:/TEST.TXT"
mwr -force $fs_len 5
write_str $fs_buf "HELLO"
if {[run_cmd 2]} {
    puts "WRITE TEST.TXT SUCCESS"
} else {
    puts "WRITE TEST.TXT FAIL"
}
exit
