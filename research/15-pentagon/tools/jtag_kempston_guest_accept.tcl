# Deterministic end-to-end JOY_STATE -> guest IN 31 acceptance.
#
# Unlike joymap_accept.tcl (AXI register/readback only), this installs a tiny
# Z80 loop in native-48 RAM:
#     DI
# loop: IN A,(0x1F)
#       LD (0x4000),A
#       JP loop
# The ULA fetches 0x4000 into screen-mirror byte 0, so JTAG can verify the
# value the real guest CPU observed without relying on a human or a game.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

set version [rd 0x40000000]
set caps    [rd 0x400000C0]
if {($caps & 1) == 0} {
    puts [format "KEMPSTON_GUEST_ACCEPT FAIL version=%08X caps=%08X reason=no_joy_state" $version $caps]
    exit 1
}

# Halt at a fabric-approved boundary and read the coherent 212-bit T80 vector.
mwr -force 0x40000004 1
for {set n 0} {$n < 2000} {incr n} {
    if {[rd 0x40000008] & 1} { break }
    after 1
}
if {([rd 0x40000008] & 1) == 0} {
    puts "KEMPSTON_GUEST_ACCEPT FAIL reason=halt_timeout"
    exit 1
}
mwr -force 0x400000E0 1
after 10
set regs {}
for {set k 0} {$k < 7} {incr k} {
    lappend regs [rd [expr {0x400000E4 + 4*$k}]]
}
mwr -force 0x400000E0 2
after 10
mwr -force 0x400000E0 0

# Physical bank 2 begins at AXI RAM address 0x8000 and backs guest 0x8000.
set program {0xF3 0xDB 0x1F 0x32 0x00 0x40 0xC3 0x01 0x80}
mwr -force 0x40000010 0x00008000
foreach byte $program {
    mwr -force 0x40000014 $byte
    for {set n 0} {$n < 1000} {incr n} {
        if {([rd 0x40000008] & 2) == 0} { break }
    }
}

# Resume at 0x8000 with maskable interrupts disabled. Preserve every other
# register so this also validates the production DIRSet path used by SNA/Z80.
set r2 [lindex $regs 2]
set r6 [lindex $regs 6]
lset regs 2 [expr {($r2 & 0xFFFF0000) | 0x8000}]
lset regs 6 [expr {$r6 & ~0x000C0000}]
for {set k 0} {$k < 7} {incr k} {
    mwr -force [expr {0x40000020 + 4*$k}] [lindex $regs $k]
}
mwr -force 0x40000044 2
after 10
mwr -force 0x40000004 0
after 80

set tests {
    0x00000000 0x00
    0x00000001 0x01
    0x00000002 0x02
    0x00000004 0x04
    0x00000008 0x08
    0x00000010 0x10
    0x00000020 0x20
    0x00000040 0x40
    0x00000080 0x80
    0x00100000 0x10
}
set ok 1
foreach {joy expected} $tests {
    mwr -force 0x40000100 $joy
    after 80
    set observed [expr {[rd 0x40008000] & 0xFF}]
    set pass [expr {$observed == $expected}]
    if {!$pass} { set ok 0 }
    puts [format "JOY=%08X guest_IN31=%02X expected=%02X %s" \
        $joy $observed $expected [expr {$pass ? "PASS" : "FAIL"}]]
}
mwr -force 0x40000100 0

puts [format "KEMPSTON_GUEST_ACCEPT %s version=%08X" [expr {$ok ? "PASS" : "FAIL"}] $version]
exit [expr {$ok ? 0 : 1}]
