connect
# Try to select DAP or APU just to have A target for system reset
if { [catch { targets -set -filter {name =~ "*DAP*"} }] } {
    targets -set -filter {name =~ "*APU*"}
}
rst -system
after 1000

# After reset, APU should be visible
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
