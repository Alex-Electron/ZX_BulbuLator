# MP3 cassette probe. Usage:
#   xsdb jtag_mp3_speed_probe.tcl <0|1|2> <0|1|2> [directory] <filename>
# speed: 0=1x, 1=FAST8 (CPU-only), 2=SAFE4 (whole-core)
# quant: 0=force raw, 1=force per-block quantizer, 2=calibrated AUTO
#
# Run jtag_load_loader_reset.tcl first for every repetition.  Autoload forces
# the production MP3-tape route, then this script proves that a real tape run
# occurred (not normal music playback) and reports the immutable pulse result.
if {$argc != 3 && $argc != 4} {
    puts "usage: xsdb jtag_mp3_speed_probe.tcl <0|1|2> <0|1|2> ?directory? <filename>"
    exit 2
}
set speed [lindex $argv 0]
set quant [lindex $argv 1]
set dir "0:/loadtest/TurboLoadMP3"
if {$argc == 3} {
    set name [lindex $argv 2]
} else {
    set dir  [lindex $argv 2]
    set name [lindex $argv 3]
}
if {$speed != 0 && $speed != 1 && $speed != 2} { puts "speed must be 0, 1, or 2"; exit 2 }
if {$quant != 0 && $quant != 1 && $quant != 2} { puts "quant must be 0 (raw), 1 (force quant), or 2 (AUTO)"; exit 2 }

# Do not bake an address into the harness: the ARM ELF moves its globals as
# features evolve.  Resolve the current symbol before each fresh ARM load.
set here [file dirname [file normalize [info script]]]
# A copied harness lives in /tmp on the ThinkPad, while a checked-out harness
# lives under tools/.  BULB_LOADER_ELF keeps both uses exact and avoids stale
# hard-coded symbol addresses.
if {[info exists ::env(BULB_LOADER_ELF)]} {
    set elf $::env(BULB_LOADER_ELF)
} else {
    set elf [file normalize [file join $here .. arm loader.elf]]
}
set quant_addr ""
set dbg_addr ""
set qdbg_addr ""
foreach line [split [exec nm -n $elf] "\n"] {
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] opt_quant$} $line -> hex]} {
        set quant_addr "0x$hex"
    }
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] g_dbg$} $line -> hex]} {
        set dbg_addr "0x$hex"
    }
    if {[regexp {^([0-9A-Fa-f]+) [A-Za-z] g_pd_qdbg$} $line -> hex]} {
        set qdbg_addr "0x$hex"
    }
}
if {$quant_addr eq "" || $dbg_addr eq "" || $qdbg_addr eq ""} { puts "cannot resolve opt_quant/g_dbg/g_pd_qdbg in $elf"; exit 2 }

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
set KMB 0x0F700000
set DBG $dbg_addr
set QDBG $qdbg_addr
proc rd {a} { return [expr {[lindex [mrd -value $a] 0] & 0xFFFFFFFF}] }
proc putstr {addr s} {
    set v {}
    foreach ch [split $s ""] { scan $ch %c c; lappend v $c }
    lappend v 0
    mwr -size b $addr $v
}

stop
mwr [expr {$KMB+0x1c}] 0 ;# TAP/TZX speed does not participate
mwr [expr {$KMB+0x20}] $speed
mwr [expr {$KMB+0x24}] 0 ;# raw SYNC off: audio pulse stream is continuous
mwr [expr {$KMB+0x28}] 1
mwr [expr {$KMB+0x30}] 0
mwr [expr {$KMB+0x34}] 0
mwr $quant_addr $quant
putstr [expr {$KMB+0x100}] $dir
putstr [expr {$KMB+0x180}] $name
mwr $KMB 1
con

after 1000
set seen 0
set timed_out 1
for {set i 0} {$i < 1800} {incr i} {
    set on [rd [expr {$KMB+0x18}]]
    if {$on} { set seen 1 }
    if {$seen && !$on} { set timed_out 0; break }
    after 100
}
puts [format "VERSION=%08X MP3MODE=%u QUANT=%u TAPE=%s EOT_seen=%u timeout=%u" \
    [rd 0x40000000] $speed $quant $name $seen $timed_out]
puts [format "PULSE count=%u hash=%08X gaps=%u resumes=%u" \
    [rd 0x400000E4] [rd 0x400000E8] [rd 0x400000EC] [rd 0x400000F0]]
set trace_fc [rd 0x400000FC]
if {$trace_fc & 0x80000000} {
    puts [format "TRACE fe_count=%u cpu_hash=%08X PHASE valid=%u done=%u fallback=%u wait_lo=%u pc_hold=%04X" \
        [rd 0x400000F4] [rd 0x400000F8] \
        [expr {($trace_fc >> 31) & 1}] [expr {($trace_fc >> 30) & 1}] [expr {($trace_fc >> 29) & 1}] \
        [expr {($trace_fc >> 16) & 0xFF}] [expr {$trace_fc & 0xFFFF}]]
} else {
    puts [format "TRACE fe_count=%u cpu_hash=%08X ula_hash=%08X" \
        [rd 0x400000F4] [rd 0x400000F8] $trace_fc]
}
for {set i 0} {$i <= 17} {incr i} { puts [format "DBG%02d=%08X" $i [rd [expr {$DBG+4*$i}]]] }
puts [format "QDBG blocks=%u snapped=%u data=%u result=%u clusters=%u sync=%u pilot=%u blocks_ok=%u" \
    [rd $QDBG] [rd [expr {$QDBG+4}]] [rd [expr {$QDBG+8}]] [rd [expr {$QDBG+12}]] \
    [rd [expr {$QDBG+16}]] [rd [expr {$QDBG+20}]] [rd [expr {$QDBG+24}]] [rd [expr {$QDBG+28}]]]

# Safe Z80 PC/SP snapshot; REG0..3 otherwise expose pulse diagnostics.
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
