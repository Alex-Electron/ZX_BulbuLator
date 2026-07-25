# Canonical Critical Mass TZX FAST8 smoke/regression test.
# Optional argument: `1` selects Sync Loader; default is `0` (continuous).
# Requires loader.elf already running; uses the non-cacheable KVM mailbox.
# This reports transport fingerprint and the Z80 PC execution proxy.  It does
# not claim HDMI/screen verification.
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set KMB 0x0F700000
# Resolve diagnostics from the actual ELF: feature additions move globals, and
# a stale fixed address can turn an otherwise valid transport run into a false
# post-mortem verdict.
set here [file dirname [file normalize [info script]]]
if {[info exists ::env(BULB_LOADER_ELF)]} {
    set elf $::env(BULB_LOADER_ELF)
} else {
    set elf [file normalize [file join $here .. arm loader.elf]]
}
set DBG ""
foreach line [split [exec nm -n $elf] "\n"] {
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] g_dbg$} $line -> hex]} {
        set DBG "0x$hex"
    }
}
if {$DBG eq ""} { puts "cannot resolve g_dbg in $elf"; exit 2 }
set sync 0
set filename "CriticalMass-canonical.tzx"
if {$argc >= 1} { set sync [lindex $argv 0] }
if {$argc >= 2} { set filename [lindex $argv 1] }
proc rd {addr} { return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}] }
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] { scan $ch %c c; lappend v $c }
    lappend v 0
    mwr -size b $addr $v
}

stop
mwr [expr {$KMB+0x1c}] 1 ;# FAST8 CPU-only
mwr [expr {$KMB+0x24}] $sync ;# optional Sync Loader mode
mwr [expr {$KMB+0x28}] 1 ;# deterministic autostart setup
mwr [expr {$KMB+0x30}] 0 ;# ROM trap OFF
mwr [expr {$KMB+0x34}] 0 ;# Smart Load OFF
putstr [expr {$KMB+0x100}] "0:/loadtest"
putstr [expr {$KMB+0x180}] $filename
mwr $KMB 1
con

# Wait up to 120 s for the ARM-owned end-of-tape flag.  This never reads the
# player FIFO/counters while the guest is loading, so it cannot perturb the
# transport timing under test.
after 1000
set tape_seen 0
set eot_timeout 1
for {set i 0} {$i < 1200} {incr i} {
    set on [rd [expr {$KMB+0x18}]]
    if {$on} { set tape_seen 1 }
    if {$tape_seen && !$on} { set eot_timeout 0; break }
    after 100
}
puts [format "VERSION    0x%08X" [rd 0x40000000]]
puts [format "TAPE       %s" $filename]
puts [format "OPTIONS    fast=%u sync=%u auto=%u smart=%u tape_on=%u" \
    [rd [expr {$KMB+0x1c}]] [rd [expr {$KMB+0x24}]] [rd [expr {$KMB+0x28}]] \
    [rd [expr {$KMB+0x34}]] [rd [expr {$KMB+0x18}]]]
if {[rd [expr {$KMB+0x1c}]] == 1 && [rd [expr {$KMB+0x24}]]} {
    puts "SYNC_MODE  ON + AUTO-ROM (same FAST8 effective marked-ROM gate)"
} elseif {[rd [expr {$KMB+0x1c}]] == 1} {
    puts "SYNC_MODE  AUTO-ROM (FAST8 forces exact PC=056B gate only for marked standard blocks)"
} elseif {[rd [expr {$KMB+0x24}]]} {
    puts "SYNC_MODE  ON"
} else {
    puts "SYNC_MODE  OFF"
}
puts [format "EOT        seen=%u timeout=%u" $tape_seen $eot_timeout]
puts [format "FINGERPRINT count=%u hash=%08X gaps=%u resumes=%u" \
    [rd 0x400000E4] [rd 0x400000E8] [rd 0x400000EC] [rd 0x400000F0]]
for {set i 13} {$i <= 17} {incr i} {
    puts [format "DBG%02d      %08X" $i [rd [expr {$DBG+4*$i}]]]
}
puts [format "ROMTRAP    %08X" [rd 0x400000E0]]
# REG0..3 are multiplexed to diagnostics while ROMTRAP is off, so use the
# hardware-safe snapshot protocol only after the fingerprint was captured.
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
catch {con}
exit
