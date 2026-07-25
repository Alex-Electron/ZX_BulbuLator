# Copy one host file to the board SD card through the running Step-15 ARM
# file-service mailbox. The tape engine must be idle.
#
# Usage: xsdb jtag_fs_put.tcl <local_file> <0:/destination>

if {$argc != 2} {
    puts "usage: jtag_fs_put.tcl <local_file> <0:/destination>"
    exit 2
}
set local  [lindex $argv 0]
set sdpath [lindex $argv 1]
if {![file exists $local] || [file size $local] > 0x00600000} {
    puts "missing file or too large for one FS mailbox WRITE"
    exit 3
}

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set KMB 0x0F700000
set BUF 0x0F900000

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] {
        scan $ch %c c
        lappend v $c
    }
    lappend v 0
    mwr -force -size b $addr $v
}

if {[rd [expr {$KMB+0x18}]]} {
    puts "FS_PUT_REFUSED tape_busy=1"
    exit 4
}

set size [file size $local]
dow -data $local $BUF
mwr -force [expr {$KMB+0x10}] $size
putstr [expr {$KMB+0x200}] $sdpath
mwr -force [expr {$KMB+0x08}] 0
mwr -force [expr {$KMB+0x04}] 2

for {set n 0} {$n < 600} {incr n} {
    set done [rd [expr {$KMB+0x08}]]
    if {$done == 1} {
        puts [format "FS_PUT_OK bytes=%u path=%s" [rd [expr {$KMB+0x14}]] $sdpath]
        exit
    }
    if {$done == 0xE} {
        puts [format "FS_PUT_ERROR fr=%u path=%s" [rd [expr {$KMB+0x0C}]] $sdpath]
        exit 5
    }
    after 100
}
puts "FS_PUT_TIMEOUT"
exit 6
