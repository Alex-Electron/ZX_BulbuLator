# B004D/v140 Sinclair ULA Early/Late control-plane smoke test.
#
# Uses the non-cacheable ARM mailbox, exactly like KVM automation. It selects
# native 48K and 128K, verifies Type 1/Early, switches to Type 2/Late,
# then restores 48K Early. No SD/flash writes are performed.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set VERSION  0x40000000
set MACHCFG  0x400000BC
set OPT_MACH 0x0F70002C
set OPT_LATE 0x0F70003C

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

proc wait_cfg {want limit_ms} {
    global MACHCFG
    for {set n 0} {$n < $limit_ms} {incr n} {
        if {[rd $MACHCFG] == $want} { return 1 }
        after 1
    }
    return 0
}

set ver [rd $VERSION]
if {$ver != 0xB01B004D} {
    puts [format "ULA_FAIL wrong FPGA version=%08X" $ver]
    exit 2
}

# Select 48K through the guarded ARM transition and request the default Type 1.
mwr -force $OPT_LATE 0
mwr -force $OPT_MACH 2
if {![wait_cfg 2 7000]} {
    puts [format "ULA48_FAIL EARLY cfg=%08X opt_machine=%u opt_late=%u" \
        [rd $MACHCFG] [rd $OPT_MACH] [rd $OPT_LATE]]
    exit 3
}
puts [format "ULA48_EARLY_OK cfg=%08X" [rd $MACHCFG]]

# v140 watches OPT_LATE coherently and reapplies the same machine without a wipe.
mwr -force $OPT_LATE 1
if {![wait_cfg 6 2000]} {
    puts [format "ULA48_FAIL LATE cfg=%08X opt_late=%u" [rd $MACHCFG] [rd $OPT_LATE]]
    exit 4
}
puts [format "ULA48_LATE_OK  cfg=%08X" [rd $MACHCFG]]

# 128K uses the same real Ferranti ULA phase option: Early=0, Late=4.
mwr -force $OPT_LATE 0
mwr -force $OPT_MACH 0
if {![wait_cfg 0 7000]} {
    puts [format "ULA128_FAIL EARLY cfg=%08X opt_machine=%u opt_late=%u" \
        [rd $MACHCFG] [rd $OPT_MACH] [rd $OPT_LATE]]
    exit 5
}
puts [format "ULA128_EARLY_OK cfg=%08X" [rd $MACHCFG]]

mwr -force $OPT_LATE 1
if {![wait_cfg 4 2000]} {
    puts [format "ULA128_FAIL LATE cfg=%08X opt_late=%u" [rd $MACHCFG] [rd $OPT_LATE]]
    exit 6
}
puts [format "ULA128_LATE_OK  cfg=%08X" [rd $MACHCFG]]

# Restore the shipping-compatible 48K Early default.
mwr -force $OPT_LATE 0
mwr -force $OPT_MACH 2
if {![wait_cfg 2 7000]} {
    puts [format "ULA48_FAIL RESTORE cfg=%08X opt_late=%u" [rd $MACHCFG] [rd $OPT_LATE]]
    exit 7
}
puts [format "ULA48_RESTORE_OK cfg=%08X" [rd $MACHCFG]]
exit
