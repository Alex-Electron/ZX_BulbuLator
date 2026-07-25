# WAV tape A/B probe. Usage: xsdb jtag_wav_speed_probe.tcl <1|2|3> <filename>
# 1=FAST8 CPU-only, 2=SAFE4 whole-core, 3=B0044 WAV AUTO 8->4 experiment.
# The caller must reset-load loader.elf
# before every run.  This only records an objective post-EOT state; the mirrored
# screen must be inspected separately for guest success.
if {$argc != 2} {
    puts "usage: xsdb jtag_wav_speed_probe.tcl <1|2> <filename>"
    exit 2
}
set mode [lindex $argv 0]
set name [lindex $argv 1]
if {$mode != 1 && $mode != 2 && $mode != 3} { puts "mode must be 1 (FAST8), 2 (SAFE4), or 3 (AUTO 8->4)"; exit 2 }

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set KMB 0x0F700000
set DBG 0x00158F18
proc rd {a} { return [expr {[lindex [mrd -value $a] 0] & 0xFFFFFFFF}] }
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] { scan $ch %c c; lappend v $c }
    lappend v 0
    mwr -size b $addr $v
}

stop
mwr [expr {$KMB+0x1c}] 0 ;# TAP/TZX speed irrelevant here
mwr [expr {$KMB+0x20}] $mode
mwr [expr {$KMB+0x24}] 0
mwr [expr {$KMB+0x28}] 1
mwr [expr {$KMB+0x30}] 0
mwr [expr {$KMB+0x34}] 0
putstr [expr {$KMB+0x100}] "0:/loadtest/TurboLoad"
putstr [expr {$KMB+0x180}] $name
mwr $KMB 1
con

after 1000
set seen 0
set timeout 1
for {set i 0} {$i < 1800} {incr i} {
    set on [rd [expr {$KMB+0x18}]]
    if {$on} { set seen 1 }
    if {$seen && !$on} { set timeout 0; break }
    after 100
}
puts [format "VERSION=%08X WAVMODE=%u TAPE=%s EOT_seen=%u timeout=%u" \
    [rd 0x40000000] $mode $name $seen $timeout]
puts [format "PULSE count=%u hash=%08X gaps=%u resumes=%u" \
    [rd 0x400000E4] [rd 0x400000E8] [rd 0x400000EC] [rd 0x400000F0]]
for {set i 13} {$i <= 17} {incr i} { puts [format "DBG%02d=%08X" $i [rd [expr {$DBG+4*$i}]]] }

# Safe Z80 PC/SP snapshot; REG0..3 otherwise expose diagnostics.
mwr 0x40000004 1
for {set i 0} {$i < 1000} {incr i} { if {[rd 0x40000008] & 1} { break }; after 1 }
mwr 0x400000E0 1
after 10
set r1 [rd 0x400000E8]
set r2 [rd 0x400000EC]
puts [format "Z80 PC=%04X SP=%04X" [expr {$r2 & 0xFFFF}] [expr {($r1 >> 16) & 0xFFFF}]]
mwr 0x400000E0 2
after 10
mwr 0x400000E0 0
mwr 0x40000004 0
exit
