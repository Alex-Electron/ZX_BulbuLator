# Load a snapshot through the firmware's real KVM/browser path, select the
# Sinclair ULA phase, then capture the live 6912-byte ZX screen mirror.
#
# args: <filename> [dir] [late] [screen.bin]
#   late: 0 = Type 1/Early, 1 = Type 2/Late
# No SD or flash writes are performed.

if {$argc < 1} {
    puts "usage: jtag_snapshot_phase_capture.tcl <filename> \[dir late screen.bin\]"
    exit 2
}
set filename [lindex $argv 0]
set dir "0:/loadtest"; if {$argc >= 2} { set dir [lindex $argv 1] }
set late 0;            if {$argc >= 3} { set late [lindex $argv 2] }
set scrout "/tmp/snapshot_phase.bin"; if {$argc >= 4} { set scrout [lindex $argv 3] }

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set KMB       0x0F700000
set MACHCFG   0x400000BC
set OPT_MACH  0x0F70002C
set OPT_LATE  0x0F70003C
set AUTODIR   0x0F700100
set AUTONAME  0x0F700180
set SCRBASE   0x40008000

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] { scan $ch %c c; lappend v $c }
    lappend v 0
    mwr -force -size b $addr $v
}
proc wait_value {addr want limit_ms} {
    for {set n 0} {$n < $limit_ms} {incr n} {
        if {[rd $addr] == $want} { return 1 }
        after 1
    }
    return 0
}

# Native 48K, chosen ULA phase. Firmware performs the guarded model transition.
mwr -force $OPT_LATE $late
mwr -force $OPT_MACH 2
set want [expr {$late ? 6 : 2}]
if {![wait_value $MACHCFG $want 7000]} {
    puts [format "SNAP_PHASE_FAIL cfg=%08X want=%08X" [rd $MACHCFG] $want]
    exit 3
}

# g_autotrig is deliberately generic: autoload_tape dispatches snapshots to
# load_snapshot(), so this exercises the same loader as an Enter in Navigator.
putstr $AUTODIR $dir
putstr $AUTONAME $filename
mwr -force $KMB 1
if {![wait_value $KMB 0 5000]} {
    puts "SNAP_PHASE_FAIL trigger was not consumed"
    exit 4
}
after 4000

set f [open $scrout w]
fconfigure $f -translation binary
for {set w 0} {$w < 1728} {incr w 216} {
    set vals [mrd -force -value [expr {$SCRBASE + $w*4}] 216]
    foreach v $vals { puts -nonewline $f [binary format i $v] }
}
close $f
puts [format "SNAP_PHASE_OK version=%08X cfg=%08X late=%u screen=%s bytes=%u" \
    [rd 0x40000000] [rd $MACHCFG] $late $scrout [file size $scrout]]
exit
