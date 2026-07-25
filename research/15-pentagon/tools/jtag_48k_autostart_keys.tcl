# Diagnose the 48K phantom LOAD command independently of ARM firmware.
#
# The Cortex-A9 is stopped, the selected 48K core is cold-reset, and the exact
# four-key sequence used by zx_tape_autostart() is written directly to
# KBD_INJECT.  Two trials compare the firmware timing with a deliberately slow
# timing.  A raw ZX screen is captured after every completed key.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set VERSION 0x40000000
set CONTROL 0x40000004
set STATUS  0x40000008
set MACHCFG 0x400000BC
set KBDINJ  0x400000A8
set SCRBASE 0x40008000

proc rd {addr} {
    return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}]
}

proc wait_mask {addr mask want limit_ms} {
    for {set n 0} {$n < $limit_ms} {incr n} {
        if {([rd $addr] & $mask) == $want} { return 1 }
        after 1
    }
    return 0
}

proc capture_screen {path} {
    set f [open $path w]
    fconfigure $f -translation binary
    for {set w 0} {$w < 1728} {incr w 216} {
        set vals [mrd -value [expr {0x40008000 + $w*4}] 216]
        foreach v $vals { puts -nonewline $f [binary format i $v] }
    }
    close $f
}

proc cold_boot {} {
    global CONTROL STATUS
    mwr $CONTROL 4
    set saw_busy [wait_mask $STATUS 4 4 1500]
    set done [wait_mask $STATUS 4 0 5000]
    mwr $CONTROL 0
    if {!$saw_busy || !$done} {
        error [format "RESET failed saw_busy=%d done=%d status=%08X" \
            $saw_busy $done [rd $STATUS]]
    }
    after 3000
}

proc tap_key {code hold_ms settle_ms} {
    global KBDINJ
    mwr $KBDINJ $code
    after $hold_ms
    mwr $KBDINJ [expr {0x100 | $code}]
    after $settle_ms
}

proc run_trial {tag hold_ms settle_ms} {
    cold_boot
    capture_screen [format "/tmp/%s_0_boot.bin" $tag]
    set codes {0x3B 0x54 0x54 0x5A}
    set names {J quote1 quote2 enter}
    for {set i 0} {$i < 4} {incr i} {
        tap_key [lindex $codes $i] $hold_ms $settle_ms
        after 150
        set out [format "/tmp/%s_%d_%s.bin" $tag [expr {$i+1}] [lindex $names $i]]
        capture_screen $out
        puts [format "KEY48_CAPTURE trial=%s step=%d key=%s screen=%s" \
            $tag [expr {$i+1}] [lindex $names $i] $out]
    }
}

stop
set ver [rd $VERSION]
set cfg [rd $MACHCFG]
puts [format "KEY48_BEGIN version=%08X machine_cfg=%08X" $ver $cfg]
if {$ver != 0xB01B004B || ($cfg & 3) != 2} {
    puts "KEY48_FAIL expected volatile B004B in native 48K mode"
    con
    exit 2
}

run_trial "b004b_key48_normal" 60 40
run_trial "b004b_key48_slow" 180 180

con
puts "KEY48_DONE"
exit
