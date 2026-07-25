# Capture N consecutive screen-mirror frames of the CURRENTLY RUNNING program.
# Purely passive: reads only the 6912-byte mirror window (GP0+0x8000). Does NOT
# reset, load, or touch machine state - safe to run while a demo is on screen.
#
# args: [nframes] [gap_ms] [prefix]
#   nframes - how many frames to grab (default 5)
#   gap_ms  - delay between grabs in ms (default 400; ~20 ZX frames)
#   prefix  - host output path prefix (default /tmp/snow_f); files <prefix>N.bin
#
# Pair with tools/snow_diff.py on the host: static-snow vs flicker verdict.
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set nframes 5
set gap_ms  400
set prefix  "/tmp/snow_f"
if {$argc >= 1} { set nframes [lindex $argv 0] }
if {$argc >= 2} { set gap_ms  [lindex $argv 1] }
if {$argc >= 3} { set prefix  [lindex $argv 2] }

for {set n 0} {$n < $nframes} {incr n} {
    set f [open "$prefix$n.bin" w]
    fconfigure $f -translation binary
    for {set w 0} {$w < 1728} {incr w 216} {
        set vals [mrd -value [expr {0x40008000 + $w*4}] 216]
        foreach v $vals { puts -nonewline $f [binary format i $v] }
    }
    close $f
    puts "captured frame $n -> $prefix$n.bin"
    if {$n < $nframes-1} { after $gap_ms }
}
puts "SNOW_CAPTURE_DONE $nframes frames"
exit
