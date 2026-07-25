# B0053 native-48 interrupt-acceptance sweep.
#
# Usage:
#   xsdb jtag_b0053_int_sweep.tcl ?irq_min irq_max ula_delta?
# Defaults sweep IRQ_DELTA=-256..255, ULA_DELTA=0 for all three useful sources:
#   0 legacy pc3M5 register, 1 raw ULA /INT, 2 opposite-half nc3M5 register.
#
# The timing SNA must already be running. B0053 applies each config at VSYNC and FREEZE captures the
# first subsequent interrupt acknowledge. TRACE0/1/2/TRACE0 is retried until ACK_SEQ is coherent.

set irq_min -256
set irq_max 255
set ula_delta 0
if {$argc >= 1} { set irq_min [lindex $argv 0] }
if {$argc >= 2} { set irq_max [lindex $argv 1] }
if {$argc >= 3} { set ula_delta [lindex $argv 2] }
if {$irq_min < -256 || $irq_max > 255 || $irq_min > $irq_max ||
    $ula_delta < -32 || $ula_delta > 31} {
    puts "usage: jtag_b0053_int_sweep.tcl ?irq_min(-256..255) irq_max(-256..255) ula_delta(-32..31)?"
    exit 2
}

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1

proc rd {addr} {
    return [expr {[lindex [mrd -force -value $addr] 0] & 0xFFFFFFFF}]
}
proc sx6 {v} {
    set x [expr {$v & 0x3F}]
    return [expr {$x >= 32 ? $x - 64 : $x}]
}
proc sx9 {v} {
    set x [expr {$v & 0x1FF}]
    return [expr {$x >= 256 ? $x - 512 : $x}]
}
proc cfgword {epoch irq_delta ula_delta source} {
    return [expr {(0xC0000000 |
                  (($epoch & 0x3F) << 24) |
                  (($irq_delta & 0x1FF) << 15) |
                  (($ula_delta & 0x3F) << 9) |
                  (($source & 3) << 7)) & 0xFFFFFFFF}]
}

set VERSION 0x40000000
set MACHCFG 0x400000BC
set TUNER   0x400000C4
set ROMTRAP 0x400000E0
set TRACE0  0x400000F4
set TRACE1  0x400000F8
set TRACE2  0x400000FC

set version [rd $VERSION]
if {$version != 0xB01B0053} {
    puts [format "B0053_REQUIRED version=%08X" $version]
    exit 3
}
if {([rd $MACHCFG] & 3) != 2} {
    puts [format "NATIVE48_REQUIRED machine_cfg=%08X" [rd $MACHCFG]]
    exit 4
}
mwr -force $ROMTRAP 0

puts "epoch,irq_delta,ula_delta,source,ack_seq,valid,missed,v_ack,h_ack,raw_age,selected_age,pc,r,raw_seq,levels,phase_flags,trace0,trace1,trace2"
set epoch 0
for {set source 0} {$source <= 2} {incr source} {
    for {set irq_delta $irq_min} {$irq_delta <= $irq_max} {incr irq_delta} {
        set epoch [expr {($epoch + 1) & 0x3F}]
        set cfg [cfgword $epoch $irq_delta $ula_delta $source]
        mwr -force $TUNER $cfg

        set coherent 0
        set t0a 0
        set t0b 0
        set t1 0
        set t2 0
        for {set waitn 0} {$waitn < 500} {incr waitn} {
            after 2
            set t0a [rd $TRACE0]
            if {(($t0a >> 23) & 1) == 0} { continue }
            if {[sx9 [expr {$t0a >> 11}]] != $irq_delta ||
                [sx6 [expr {$t0a >> 5}]] != $ula_delta ||
                (($t0a >> 20) & 3) != $source} { continue }
            set t1 [rd $TRACE1]
            set t2 [rd $TRACE2]
            set t0b [rd $TRACE0]
            if {(($t0a >> 24) & 0xFF) == (($t0b >> 24) & 0xFF)} {
                set coherent 1
                break
            }
        }

        if {!$coherent} {
            puts [format "%u,%d,%d,%u,0,0,1,0,0,127,127,0000,00,00,00,00,%08X,%08X,%08X" \
                $epoch $irq_delta $ula_delta $source $t0a $t1 $t2]
            continue
        }

        set ack_seq [expr {($t0a >> 24) & 0xFF}]
        set valid [expr {($t0a >> 23) & 1}]
        set missed [expr {($t0a >> 22) & 1}]
        set v_ack [expr {($t1 >> 23) & 0x1FF}]
        set h_ack [expr {($t1 >> 14) & 0x1FF}]
        set raw_age [expr {($t1 >> 7) & 0x7F}]
        set selected_age [expr {$t1 & 0x7F}]
        set pc [expr {($t2 >> 16) & 0xFFFF}]
        set r [expr {($t2 >> 8) & 0xFF}]
        set raw_seq [expr {$t2 & 0xFF}]
        set levels [expr {($t0a >> 1) & 0xF}]
        set phase_flags [expr {$t0a & 0x1}]
        puts [format "%u,%d,%d,%u,%u,%u,%u,%u,%u,%u,%u,%04X,%02X,%02X,%X,%X,%08X,%08X,%08X" \
            $epoch $irq_delta $ula_delta $source $ack_seq $valid $missed $v_ack $h_ack \
            $raw_age $selected_age $pc $r $raw_seq $levels $phase_flags $t0a $t1 $t2]
    }
}
exit
