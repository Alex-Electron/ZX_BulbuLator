connect -url tcp:localhost:3121
puts "=== TARGETS ==="
puts [targets]
targets -set -filter {name =~ "*Cortex-A9*#0"}
puts "=== BEFORE STOP ==="
puts [targets]
catch {stop} stopmsg
puts "STOP: $stopmsg"
puts "=== REGISTERS ==="
catch {rrd pc} pcmsg
puts "PC: $pcmsg"
catch {rrd cpsr} cpsrmsg
puts "CPSR: $cpsrmsg"
catch {mrd -force 0x0015895C 4} memmsg
puts "MEM: $memmsg"
catch {con} conmsg
puts "CON: $conmsg"
exit
