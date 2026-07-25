if {$argc != 1} {
    puts "usage: xsdb jtag_load_elf.tcl <loader.elf>"
    exit 2
}

set elf [lindex $argv 0]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
catch {stop}
rst -processor
dow $elf
con
after 2000
set version [lindex [mrd -value 0x40000000] 0]
set pc [lindex [mrd -value 0x400000EC] 0]
puts [format "FPGA_VERSION 0x%08X" $version]
puts [format "ARM_PC       0x%08X" $pc]
exit
