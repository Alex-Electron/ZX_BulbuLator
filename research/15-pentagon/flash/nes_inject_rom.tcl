# Universal NROM injector: reads iNES header, streams PRG then CHR into the NES BRAM, dumps framebuffer.
# ROM path via env NES_ROM (default smb.nes).
set path $env(NES_ROM)
set fp [open $path rb]; fconfigure $fp -translation binary
set rom [read $fp]; close $fp
binary scan $rom c* B
set prg [expr {([lindex $B 4] & 0xFF) * 16384}]
set chr [expr {([lindex $B 5] & 0xFF) * 8192}]
set trn [expr {([lindex $B 6] & 4) ? 512 : 0}]
set off [expr {16 + $trn}]
puts ">>> ROM=$path  PRG=$prg CHR=$chr trainer=$trn"
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
mwr 0x40000110 0x9
for {set i 0} {$i < $prg} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$off+$i}]] & 0xFF}] }
puts ">>> PRG streamed"
mwr 0x40000110 0xB
set c [expr {$off+$prg}]
for {set i 0} {$i < $chr} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$c+$i}]] & 0xFF}] }
puts ">>> CHR streamed"
mwr 0x40000104 0; mwr 0x40000108 0
mwr 0x40000110 0x4
puts ">>> running"
after 700
mrd -bin -file /tmp/rom_fb0.bin 0x0FF00000 7680
mrd -bin -file /tmp/rom_fb1.bin 0x0FF10000 7680
mrd -bin -file /tmp/rom_fb2.bin 0x0FF20000 7680
puts ">>> ROM_DONE"
exit
