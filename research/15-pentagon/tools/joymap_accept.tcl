# JOYMAP stage-1 hardware acceptance (JOY_STATE -> Kempston port), passive+deterministic.
# Requires a bitstream with the JOY_STATE register (LOAD_CAPS bit0 = 1, e.g. 0x4A+) and an ARM
# loader running. Writes each of the 8 generic-pad bits to JOY_STATE@GP0+0x100 and reads it back;
# a guest BASIC `IN 31` (or a Kempston game) is the human-facing confirmation. This script only
# proves the ARM->fabric register path + readback; the ULA->port wiring is proven by the game.
#
# NOTE: this does NOT exercise the keyboard->joymap ARM path (that needs live PS/2). It validates
# the hardware contract. For the full wizard, use the guest EXOLON/Kempston test by hand.
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc rd {addr} { return [expr {[lindex [mrd -value $addr] 0] & 0xFFFFFFFF}] }

set ver  [rd 0x40000000]
set caps [rd 0x400000C0]
puts [format "VERSION=0x%08X  LOAD_CAPS=0x%X  (bit0=JOY_STATE present)" $ver $caps]
if {($caps & 1) == 0} { puts "!! JOY_STATE capability bit not set - wrong bitstream"; exit 1 }

set names {R L D U FIRE FIRE2 FIRE3 BIT7}
set ok 1
for {set b 0} {$b < 8} {incr b} {
    set m [expr {1 << $b}]
    mwr 0x40000100 $m
    after 20
    set rb [rd 0x40000100]
    set good [expr {$rb == $m}]
    if {!$good} { set ok 0 }
    puts [format "bit%d %-5s : wrote 0x%02X readback 0x%08X  %s" \
        $b [lindex $names $b] $m $rb [expr {$good ? "OK" : "MISMATCH"}]]
}
# player-2 half ([31:16])
mwr 0x40000100 0x00100000
after 20
puts [format "player2 FIRE (bit20): readback 0x%08X" [rd 0x40000100]]
mwr 0x40000100 0
puts [expr {$ok ? "JOYMAP_HW_ACCEPT PASS" : "JOYMAP_HW_ACCEPT FAIL"}]
exit
