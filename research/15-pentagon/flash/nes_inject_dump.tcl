# Inject full_palette.nes into the (already PCAP-loaded) NES core BRAM via JTAG, replicating
# nes_load(): PRG (sel0) then CHR (sel1) streamed to NES_LD 0x4000010C, mapper=0, reset pulse.
# full_palette.nes header verified: mapper 0, PRG 32768, CHR 8192, no trainer.
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
set fp [open "/home/lavrinovich/nes_roms/nes-test-roms/full_palette/full_palette.nes" rb]
fconfigure $fp -translation binary
set rom [read $fp]; close $fp
binary scan $rom c* B
set prg 32768; set chr 8192; set off 16
puts ">>> streaming PRG ($prg B) ..."
mwr 0x40000110 0x9
for {set i 0} {$i < $prg} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$off+$i}]] & 0xFF}] }
puts ">>> streaming CHR ($chr B) ..."
mwr 0x40000110 0xB
set c [expr {$off+$prg}]
for {set i 0} {$i < $chr} {incr i} { mwr 0x4000010C [expr {[lindex $B [expr {$c+$i}]] & 0xFF}] }
mwr 0x40000104 0
mwr 0x40000108 0
mwr 0x40000110 0x4
puts ">>> released reset, running..."
after 400
mrd -bin -file /tmp/nes_fb0.bin 0x0FF00000 7680
mrd -bin -file /tmp/nes_fb1.bin 0x0FF10000 7680
mrd -bin -file /tmp/nes_fb2.bin 0x0FF20000 7680
puts ">>> INJECT_DUMP_DONE"
exit
