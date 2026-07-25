# B004B 48K cold-reset acceptance probe.
#
# Selects the 48K machine through the same coherent mailbox used by the KVM,
# lets firmware perform its guarded model transition, then performs three
# fabric RESET+wipe cycles. After each boot it captures the raw 6912-byte ZX
# screen mirror to /tmp/b004b_48_boot_N.bin on the JTAG host.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set KMB     0x0F700000
set VERSION 0x40000000
set CONTROL 0x40000004
set STATUS  0x40000008
set MACHCFG 0x400000BC
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

# Ask the running v137 firmware to execute its guarded 48K transition.
stop
mwr [expr {$KMB + 0x2C}] 2
con
after 6000
stop

set ver [rd $VERSION]
set cfg [rd $MACHCFG]
set opt [rd [expr {$KMB + 0x2C}]]
puts [format "BOOT48_SELECT version=%08X machine_cfg=%08X opt_defmachine=%u" $ver $cfg $opt]
if {$ver != 0xB01B004B || ($cfg & 3) != 2 || $opt != 2} {
    puts "BOOT48_FAIL guarded machine selection did not latch"
    con
    exit 2
}

for {set cycle 1} {$cycle <= 3} {incr cycle} {
    # CONTROL bit2 is a one-aclk reset request. It starts the complete 128K RAM
    # sweep and then holds the selected core in reset before releasing it.
    mwr $CONTROL 4
    set saw_busy [wait_mask $STATUS 4 4 1500]
    set done     [wait_mask $STATUS 4 0 5000]
    mwr $CONTROL 0
    if {!$saw_busy || !$done} {
        puts [format "BOOT48_FAIL cycle=%d saw_busy=%d done=%d status=%08X" \
            $cycle $saw_busy $done [rd $STATUS]]
        con
        exit 3
    }

    after 3000
    set out [format "/tmp/b004b_48_boot_%d.bin" $cycle]
    capture_screen $out
    puts [format "BOOT48_OK cycle=%d cfg=%08X status=%08X screen=%s" \
        $cycle [rd $MACHCFG] [rd $STATUS] $out]
}

con
exit
