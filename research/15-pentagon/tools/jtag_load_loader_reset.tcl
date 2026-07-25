# Load the ARM tape loader after a PCAP reconfiguration.
# A processor reset is mandatory: hot-loading the ELF can leave A9 #0 in an
# exception handler, in which case the JTAG autoload mailbox is never served.
if {$argc != 1} {
    puts "usage: xsdb jtag_load_loader_reset.tcl <loader.elf>"
    exit 2
}

connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
rst -processor
after 1000
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
dow [lindex $argv 0]
con
after 4000
puts [format "FPGA_VERSION 0x%08X" [lindex [mrd -value 0x40000000] 0]]
exit
