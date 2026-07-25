# Start the stock Sinclair 48K ROM's complete LOAD "" command without typing.
#
# This is deliberately NOT a jump to LD_BYTES (0x0556): that routine consumes
# one already-described block and requires live alternate flags, IX, DE and a
# valid caller stack.  Instead, after a real cold boot has initialized the
# 48K system variables, install a tokenized BASIC direct line and resume at
# LINE_RUN (0x1B8A).  The ROM parser then reaches SAVE_ETC/LD_BYTES normally.
#
# Preconditions: volatile B004B, native 48K selected, stock 128-1.rom.
# The Cortex-A9 is stopped during the probe so firmware cannot interfere.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set VERSION 0x40000000
set CONTROL 0x40000004
set STATUS  0x40000008
set RAMA    0x40000010
set RAMD    0x40000014
set DIR0    0x40000020
set P7FFD   0x4000003C
set PFE     0x40000040
set COMMIT  0x40000044
set ROMTRAP 0x400000E0
set MACHCFG 0x400000BC

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

# Native 48K 0x4000..0x7FFF is backed by physical bank 5.
proc write_bank5 {zxaddr bytes} {
    global RAMA RAMD STATUS
    set phys [expr {(5 << 14) + ($zxaddr - 0x4000)}]
    mwr $RAMA $phys
    foreach b $bytes {
        mwr $RAMD $b
        after 1
        if {![wait_mask $STATUS 2 0 100]} {
            error [format "RAM write stuck at ZX %04X" $zxaddr]
        }
        incr zxaddr
    }
}

stop
set ver [rd $VERSION]
set cfg [rd $MACHCFG]
puts [format "ROMLOAD48_BEGIN version=%08X machine_cfg=%08X" $ver $cfg]
if {$ver != 0xB01B004B || ($cfg & 3) != 2} {
    puts "ROMLOAD48_FAIL expected volatile B004B in native 48K mode"
    con
    exit 2
}

# Real cold boot: let ROM initialize the canonical 48K sysvars, then take bus.
mwr $CONTROL 4
set saw_busy [wait_mask $STATUS 4 4 1500]
set reset_done [wait_mask $STATUS 4 0 5000]
mwr $CONTROL 0
if {!$saw_busy || !$reset_done} {
    puts "ROMLOAD48_FAIL reset/wipe handshake"
    con
    exit 3
}
after 3000
mwr $CONTROL 1
if {![wait_mask $STATUS 1 1 1000]} {
    puts "ROMLOAD48_FAIL no HALT_ACK"
    con
    exit 4
}

# These are not guessed defaults: jtag_48k_line_context_dump.tcl measured the
# exact post-editor state on this ROM after it had formed LOAD "" normally.
# E_LINE=5CCC; K_CUR points to CR; workspace begins after the 0x80 marker.
write_bank5 0x5CCC {0xEF 0x22 0x22 0x0D 0x80}
write_bank5 0x5C59 {0xCC 0x5C} ;# E_LINE
write_bank5 0x5C5B {0xCF 0x5C} ;# K_CUR
write_bank5 0x5C61 {0xD1 0x5C} ;# WORKSP
write_bank5 0x5C63 {0xD1 0x5C} ;# STKBOT
write_bank5 0x5C65 {0xD1 0x5C} ;# STKEND
write_bank5 0x5C3B {0x0C}      ;# FLAGS measured after normal editor input
write_bank5 0x5C44 {0x00}      ;# NSPPC measured after normal editor input

# Preserve the live register context of the freshly booted ROM.  Enabling the
# register window while IJ_CTRL already holds HALT is passive; ROMTRAP remains
# off when the CPU resumes and is never used to fake LD_BYTES carry state.
mwr $ROMTRAP 1
after 20
set regs {}
for {set k 0} {$k < 7} {incr k} {
    lappend regs [rd [expr {0x400000E4 + 4*$k}]]
}
mwr $ROMTRAP 0
after 20
set r2 [lindex $regs 2]
set regs [lreplace $regs 2 2 [expr {($r2 & 0xFFFF0000) | 0x1B8A}]]
for {set k 0} {$k < 7} {incr k} {
    mwr [expr {$DIR0 + $k*4}] [lindex $regs $k]
}
mwr $P7FFD 0x30
mwr $PFE 7
mwr $COMMIT 1
mwr $COMMIT 2
mwr $CONTROL 0

after 1000
puts [format "ROMLOAD48_READY status=%08X machine_cfg=%08X" [rd $STATUS] [rd $MACHCFG]]
con
exit
