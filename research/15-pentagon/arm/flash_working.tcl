connect
catch { targets -set -filter {name =~ "*APU*"} }
rst -system
after 1000

# Stop CPUs
targets -set -filter {name =~ "*Cortex-A9*#0"}
stop
catch { targets -set -filter {name =~ "*Cortex-A9*#1"}; stop }

set elf [lindex $argv 0]
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
dow $elf
con
after 2000

# To read memory, we MUST stop the CPU first!
stop
after 10
set version [lindex [mrd -value 0x40000000] 0]
puts [format "FPGA_VERSION 0x%08X" $version]
con

exit
