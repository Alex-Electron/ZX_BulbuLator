# Universal one-shot tape matrix cell: load a file, wait EOT, report the transport
# fingerprint, snapshot PC/SP AND dump the live 6912-byte screen mirror in the same
# run (the screen must be captured at EOT time - a late dump can show an unrelated
# later state, e.g. after a user reset).
#
# args: <filename> [dir] [sync] [fast] [wavfast] [scrout] [waitsec] [autostart]
#   filename - tape file on SD (in dir)
#   dir      - SD directory, default 0:/loadtest
#   sync     - KMB+0x24 raw Sync Loader bit, default 0
#   fast     - KMB+0x1c fast-load mode (0=1x 1=FAST8 2=SAFE4), default 1
#   wavfast  - KMB+0x20 WAV speed mode (0=1x 1=FAST8 2=SAFE4 3=AUTO 8->4), default 3
#   scrout   - screen dump path on this host, default /tmp/scr_verdict.bin
#   waitsec  - EOT wait cap in seconds, default 180 (use ~900 for 1x runs)
#   autostart- 1 = firmware starts the ROM loader, 0 = guest is already waiting
# Requires loader.elf already running (fresh via jtag_load_loader_reset.tcl).
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set KMB 0x0F700000
set here [file dirname [file normalize [info script]]]
if {[info exists ::env(BULB_LOADER_ELF)]} {
    set elf $::env(BULB_LOADER_ELF)
} else {
    set elf [file normalize [file join $here .. arm loader.elf]]
}
set DBG ""
set QDBG ""
foreach line [split [exec nm -n $elf] "\n"] {
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] g_dbg$} $line -> hex]} { set DBG "0x$hex" }
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] g_pd_qdbg$} $line -> hex]} { set QDBG "0x$hex" }
}
if {$DBG eq ""} { puts "cannot resolve g_dbg in $elf"; exit 2 }

if {$argc < 1} { puts "usage: jtag_tape_verdict.tcl <filename> \[dir sync fast wavfast scrout\]"; exit 2 }
set filename [lindex $argv 0]
set dir      "0:/loadtest";        if {$argc >= 2} { set dir     [lindex $argv 1] }
set sync     0;                    if {$argc >= 3} { set sync    [lindex $argv 2] }
set fast     1;                    if {$argc >= 4} { set fast    [lindex $argv 3] }
set wavfast  3;                    if {$argc >= 5} { set wavfast [lindex $argv 4] }
set scrout   "/tmp/scr_verdict.bin"; if {$argc >= 6} { set scrout [lindex $argv 5] }
set waitsec  180;                  if {$argc >= 7} { set waitsec [lindex $argv 6] }
set autostart 1;                   if {$argc >= 8} { set autostart [lindex $argv 7] }

proc rd {addr} { return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}] }
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] { scan $ch %c c; lappend v $c }
    lappend v 0
    mwr -size b $addr $v
}

stop
mwr [expr {$KMB+0x1c}] $fast
mwr [expr {$KMB+0x20}] $wavfast
mwr [expr {$KMB+0x24}] $sync
mwr [expr {$KMB+0x28}] $autostart
mwr [expr {$KMB+0x30}] 0 ;# ROM trap OFF
mwr [expr {$KMB+0x34}] 0 ;# Smart Load OFF
putstr [expr {$KMB+0x100}] $dir
putstr [expr {$KMB+0x180}] $filename
mwr $KMB 1
con

# Wait up to $waitsec s for ARM end-of-tape; poll only the ARM-owned flag (passive).
after 1000
set tape_seen 0
set eot_timeout 1
for {set i 0} {$i < [expr {$waitsec * 10}]} {incr i} {
    set on [rd [expr {$KMB+0x18}]]
    if {$on} { set tape_seen 1 }
    if {$tape_seen && !$on} { set eot_timeout 0; break }
    after 100
}
puts [format "VERSION    0x%08X" [rd 0x40000000]]
puts [format "TAPE       %s/%s" $dir $filename]
puts [format "OPTIONS    fast=%u wavfast=%u sync=%u auto=%u smart=%u tape_on=%u" \
    [rd [expr {$KMB+0x1c}]] [rd [expr {$KMB+0x20}]] [rd [expr {$KMB+0x24}]] \
    [rd [expr {$KMB+0x28}]] [rd [expr {$KMB+0x34}]] [rd [expr {$KMB+0x18}]]]
puts [format "EOT        seen=%u timeout=%u" $tape_seen $eot_timeout]
puts [format "FINGERPRINT count=%u hash=%08X gaps=%u resumes=%u" \
    [rd 0x400000E4] [rd 0x400000E8] [rd 0x400000EC] [rd 0x400000F0]]
for {set i 13} {$i <= 17} {incr i} {
    puts [format "DBG%02d      %08X" $i [rd [expr {$DBG+4*$i}]]]
}
if {$QDBG ne ""} {
    set q {}
    for {set i 0} {$i < 8} {incr i} { lappend q [format "%u" [rd [expr {$QDBG+4*$i}]]] }
    puts "QDBG       [join $q ,]"
}

# Give the guest a moment to draw its post-load state, then capture the screen
# mirror BEFORE anything else can disturb the machine.
after 3000
set f [open $scrout w]
fconfigure $f -translation binary
for {set w 0} {$w < 1728} {incr w 216} {
    set vals [mrd -value [expr {0x40008000 + $w*4}] 216]
    foreach v $vals { puts -nonewline $f [binary format i $v] }
}
close $f
puts [format "SCREEN     %s (%d bytes)" $scrout [file size $scrout]]

# Safe PC/SP snapshot (HALT -> ROMTRAP reg window -> restore).
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
