# Inject apocalypse.nes (mapper 0, PRG 16K, CHR 8K) into already-loaded NES core, dump framebuffer.
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
set fp [open "/home/lavrinovich/nes_roms/nes-test-roms/other/apocalypse.nes" rb]
fconfigure $fp -translation binary
set rom [read $fp]; close $fp
binary scan $rom c* B
set prg 16384; set chr 8192; set off 16
puts ">>> PRG $prg"
mwr 0x40000110 0x9
for {set i 0} {$i < $prg} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$off+$i}]] & 0xFF}] }
puts ">>> CHR $chr"
mwr 0x40000110 0xB
set c [expr {$off+$prg}]
for {set i 0} {$i < $chr} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$c+$i}]] & 0xFF}] }
mwr 0x40000104 0; mwr 0x40000108 0
mwr 0x40000110 0x4
puts ">>> running"
after 500
mrd -bin -file /tmp/apo_fb0.bin 0x0FF00000 7680
mrd -bin -file /tmp/apo_fb1.bin 0x0FF10000 7680
puts ">>> APO_DONE"
exit
