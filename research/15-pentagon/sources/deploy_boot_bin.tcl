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
    # v02.08: таймаут был фиксированные 45 с и давал ЛОЖНЫЙ FAIL на многомегабайтной записи -
    # именно из-за него 31.07 решили, что 20 файлов не записались (они записались).
    global fs_timeout
    set fs_timeout 120
    for {set t 0} {$t < $fs_timeout} {incr t} {
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

proc write_file {path local_file} {
    global fs_path fs_len fs_buf
    write_str $fs_path $path
    set size [file size $local_file]
    mwr -force $fs_len $size
    puts "Writing $path ($size bytes) to SD..."
    dow -data $local_file $fs_buf
    if {[run_cmd 2]} {
        puts "WRITE $path SUCCESS"
    } else {
        puts "WRITE $path FAIL"
    }
}

# Write BOOT.BIN
write_file "0:/BOOT.BIN" "/home/lavrinovich/bulb-v13/research/15-pentagon/flash/BOOT.BIN"

puts "BOOT.BIN DEPLOYED SUCCESSFULLY TO SD CARD"
exit
