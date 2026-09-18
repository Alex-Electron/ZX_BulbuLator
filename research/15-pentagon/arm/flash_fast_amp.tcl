connect
targets -set -filter {name =~ "*DAP*"}
rst -system
after 100

catch {
    targets -set -filter {name =~ "*Cortex-A9*#1"}
    stop
    after 100
}
catch {
    targets -set -filter {name =~ "*Cortex-A9*#0"}
    stop
    after 100
}

set elf [lindex $argv 0]
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
rst -processor
dow $elf
con
after 2000
set version [lindex [mrd -value 0x40000000] 0]
puts [format "FPGA_VERSION 0x%08X" $version]
exit
