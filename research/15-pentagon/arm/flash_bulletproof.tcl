connect
catch { targets -set -filter {name =~ "*DAP*"} }
catch { targets -set -filter {name =~ "*APU*"} }
rst -system
after 3000

set is_hung 0
if { [catch { targets -set -filter {name =~ "*APU*"} }] } {
    targets -set -filter {name =~ "*DAP*"}
    mwr -force 0xF8000008 0x0000DF0D
    after 10
    mwr -force 0xF8000240 0x0000000F
    after 100
    set is_hung 1
}

targets -set -filter {name =~ "*Cortex-A9*#0"}
stop
after 50
catch { targets -set -filter {name =~ "*Cortex-A9*#1"}; stop; after 50 }

if {$is_hung} {
    targets -set -filter {name =~ "*DAP*"}
    mwr -force 0xF8000240 0x00000000
    after 50
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
