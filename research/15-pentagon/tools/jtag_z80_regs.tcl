# Non-destructive live Z80 register snapshot.
# HALT the guest through the control plane, switch REG0..REG6 to the CPU window,
# read one coherent 212-bit image, then restore the previous running state.

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}

set was_halted [expr {[rd 0x40000004] & 1}]
mwr -force 0x40000004 1
for {set n 0} {$n < 1000} {incr n} {
    if {[rd 0x40000008] & 1} { break }
    after 1
}
mwr -force 0x400000E0 1
after 10
set r0 [rd 0x400000E4]
set r1 [rd 0x400000E8]
set r2 [rd 0x400000EC]
set r3 [rd 0x400000F0]
set r4 [rd 0x400000F4]
set r5 [rd 0x400000F8]
set r6 [rd 0x400000FC]

set A  [expr {$r0 & 0xFF}]
set F  [expr {($r0 >> 8) & 0xFF}]
set I  [expr {$r1 & 0xFF}]
set R  [expr {($r1 >> 8) & 0xFF}]
set SP [expr {($r1 >> 16) & 0xFFFF}]
set PC [expr {$r2 & 0xFFFF}]
set BC [expr {($r2 >> 16) & 0xFFFF}]
set DE [expr {$r3 & 0xFFFF}]
set HL [expr {($r3 >> 16) & 0xFFFF}]
set IX [expr {$r4 & 0xFFFF}]
set IY [expr {($r6 >> 0) & 0xFFFF}]
set IM [expr {($r6 >> 16) & 3}]
set IFF1 [expr {($r6 >> 18) & 1}]
set IFF2 [expr {($r6 >> 19) & 1}]

puts [format "Z80_REGS PC=%04X SP=%04X AF=%02X%02X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X I=%02X R=%02X IM=%u IFF=%u%u RAW=%08X,%08X,%08X,%08X,%08X,%08X,%08X" \
    $PC $SP $A $F $BC $DE $HL $IX $IY $I $R $IM $IFF1 $IFF2 \
    $r0 $r1 $r2 $r3 $r4 $r5 $r6]

mwr -force 0x400000E0 2
after 10
mwr -force 0x400000E0 0
if {!$was_halted} { mwr -force 0x40000004 0 }
exit
