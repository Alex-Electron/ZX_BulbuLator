# Reverse-engineering probe for a matrix-free 48K ROM LOAD launcher.
#
# Let the stock ROM create LOAD "" once through its known-good keyboard path,
# halt before Enter, capture the exact live register vector, then run a tiny
# RAM copier that moves the 48K sysvars/editing area to screen RAM for passive
# readback.  The board is cold-reset back to a clean 48K prompt before exit.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

set VERSION 0x40000000
set CONTROL 0x40000004
set STATUS  0x40000008
set RAMA    0x40000010
set RAMD    0x40000014
set DIR0    0x40000020
set COMMIT  0x40000044
set KBDINJ  0x400000A8
set MACHCFG 0x400000BC
set ROMTRAP 0x400000E0

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

proc cold_boot {} {
    global CONTROL STATUS
    mwr $CONTROL 4
    set saw [wait_mask $STATUS 4 4 1500]
    set done [wait_mask $STATUS 4 0 5000]
    mwr $CONTROL 0
    if {!$saw || !$done} { error "reset/wipe handshake failed" }
    after 3000
}

proc tap_key {code} {
    global KBDINJ
    mwr $KBDINJ $code
    after 60
    mwr $KBDINJ [expr {0x100 | $code}]
    after 100
}

proc write_phys {phys bytes} {
    global RAMA RAMD STATUS
    mwr $RAMA $phys
    foreach b $bytes {
        mwr $RAMD $b
        after 1
        if {![wait_mask $STATUS 2 0 100]} { error "RAM write stuck" }
    }
}

stop
set ver [rd $VERSION]
set cfg [rd $MACHCFG]
puts [format "LINECTX48_BEGIN version=%08X machine_cfg=%08X" $ver $cfg]
if {$ver != 0xB01B004B || ($cfg & 3) != 2} {
    puts "LINECTX48_FAIL expected volatile B004B in native 48K mode"
    con
    exit 2
}

cold_boot
tap_key 0x3B
tap_key 0x54
tap_key 0x54

# Freeze at the ROM editor with LOAD "" present and read the exact CPU vector.
mwr $CONTROL 1
if {![wait_mask $STATUS 1 1 1000]} { error "no HALT_ACK" }
mwr $ROMTRAP 1
after 20
set regs {}
for {set k 0} {$k < 7} {incr k} {
    lappend regs [rd [expr {0x400000E4 + 4*$k}]]
}
mwr $ROMTRAP 0
after 20
for {set k 0} {$k < 7} {incr k} {
    puts [format "LINECTX48_REG%d=%08X" $k [lindex $regs $k]]
}

# 0x8000: LD HL,5C00 / LD DE,4000 / LD BC,0300 / LDIR / HALT / JR -3.
write_phys 0x08000 {0x21 0x00 0x5C 0x11 0x00 0x40 0x01 0x00 0x03 0xED 0xB0 0x76 0x18 0xFD}

# Preserve the exact captured vector; replace only PC with the copier address.
set r2 [lindex $regs 2]
set regs [lreplace $regs 2 2 [expr {($r2 & 0xFFFF0000) | 0x8000}]]
for {set k 0} {$k < 7} {incr k} {
    mwr [expr {$DIR0 + 4*$k}] [lindex $regs $k]
}
mwr $COMMIT 2
mwr $CONTROL 0
after 250

set out "/tmp/b004b_48_line_context.bin"
set f [open $out w]
fconfigure $f -translation binary
set vals [mrd -value 0x40008000 192]
foreach v $vals { puts -nonewline $f [binary format i $v] }
close $f
puts [format "LINECTX48_DUMP=%s bytes=%d" $out [file size $out]]

cold_boot
puts "LINECTX48_RESTORED"
con
exit
