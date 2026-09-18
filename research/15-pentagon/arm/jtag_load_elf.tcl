if {$argc != 1} {
    puts "usage: xsdb jtag_load_elf.tcl <loader.elf>"
    exit 2
}

set elf [lindex $argv 0]
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
catch {stop}
# A plain dow+con after PCAP can resume in a pending IRQ and land in
# Xil_ExceptionNullHandler.  Reset CPU0 only; PL/DDR and the guest keep their
# state, unlike rst -system.
rst -processor
dow $elf
# The keyboard FIFO belongs to PL and deliberately survives CPU resets.  Drop
# keys accumulated while ARM was stopped, otherwise old NumLock/F12 presses
# replay immediately after con and appear as missed or double presses.
set flushed 0
while {$flushed < 128 && ([lindex [mrd -force -value 0x43C00058] 0] & 1) == 0} {
    mrd -force -value 0x43C00054
    after 1
    incr flushed
}
con
after 2000
set version [lindex [mrd -value 0x40000000] 0]
set pc [lindex [mrd -value 0x400000EC] 0]
puts [format "FPGA_VERSION 0x%08X" $version]
puts [format "ARM_PC       0x%08X" $pc]
puts [format "KBD_FLUSHED  %u" $flushed]
exit
