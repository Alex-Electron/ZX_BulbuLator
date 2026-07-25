# Load a Step-15 snapshot through the production ARM mailbox and capture N raw
# 6912-byte screen-mirror frames while it runs.
#
# Usage:
#   xsdb jtag_snapshot_frames.tcl <sd_dir> <file.sna> <out_prefix> \
#                                ?frames=1? ?settle_ms=3000? ?gap_ms=120?
#
# Example:
#   xsdb jtag_snapshot_frames.tcl 0:/loadtest sna48k-snow.sna \
#                                /tmp/mister_snow 8 3000 120

if {$argc < 3 || $argc > 6} {
    puts "usage: jtag_snapshot_frames.tcl <sd_dir> <file.sna> <out_prefix> ?frames? ?settle_ms? ?gap_ms?"
    exit 2
}
set sd_dir    [lindex $argv 0]
set filename  [lindex $argv 1]
set prefix    [lindex $argv 2]
set frames    1
set settle_ms 3000
set gap_ms    120
if {$argc >= 4} { set frames    [lindex $argv 3] }
if {$argc >= 5} { set settle_ms [lindex $argv 4] }
if {$argc >= 6} { set gap_ms    [lindex $argv 5] }
if {$frames < 1 || $frames > 64 || $settle_ms < 0 || $gap_ms < 0} {
    puts "bad frames/settle_ms/gap_ms"
    exit 3
}

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set KMB 0x0F700000

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
proc capture_screen {path} {
    set f [open $path w]
    fconfigure $f -translation binary
    for {set w 0} {$w < 1728} {incr w 216} {
        set vals [mrd -force -value [expr {0x40008000 + $w*4}] 216]
        foreach v $vals {
            puts -nonewline $f [binary format i $v]
        }
    }
    close $f
}

stop
mwr -force 0x400000BC 2
mwr -force [expr {$KMB+0x28}] 1
mwr -force [expr {$KMB+0x34}] 0
putstr [expr {$KMB+0x100}] $sd_dir
putstr [expr {$KMB+0x180}] $filename
mwr -force $KMB 1
con
after $settle_ms

for {set n 0} {$n < $frames} {incr n} {
    set path [format "%s_%02u.bin" $prefix $n]
    capture_screen $path
    puts [format "SNAP_FRAME index=%u version=%08X machine=%08X file=%s bytes=%u" \
        $n [rd 0x40000000] [rd 0x400000BC] $path [file size $path]]
    if {$n + 1 < $frames} { after $gap_ms }
}
exit
