# m2_poke.tcl - Milestone 2: ARM halts the Z80 and paints the Spectrum screen.
# Runs against the already-held XVC target after the PL is PCAP-configured.
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
proc r32 {a} { return [lindex [mrd -value $a] 0] }

puts "VERSION = [r32 0x40000000]   (expect B01B0002)"

# 1) HALT the Z80 and wait for the freeze to settle.
mwr 0x40000004 0x00000001
set t 0
while {([r32 0x40000008] & 0x1) == 0} { incr t; if {$t > 3000} { puts ">>> HALT_ACK TIMEOUT"; break } }
puts "STATUS after HALT = [r32 0x40000008]   (bit0 = HALT_ACK, bit1 = RAM_BUSY)"

# 2) Paint the whole displayed screen RED by filling bank-5 attributes (768 bytes @ 0x15800)
#    with 0x10 = PAPER 2 (red), INK 0 (black). RAM_ADDR auto-increments per RAM_DATA write.
mwr 0x40000010 0x00015800
for {set i 0} {$i < 768} {incr i} { mwr 0x40000014 0x00000010 }
puts ">>> 768 attribute bytes written. Screen should now be RED, Z80 still halted."
puts "RAM_ADDR now = [r32 0x40000010]   (should be 0x15B00)"
puts ">>> M2 POKE DONE"
