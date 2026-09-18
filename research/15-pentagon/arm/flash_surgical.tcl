connect
targets -set -filter {name =~ "*DAP*"}
rst -system
# Let the SD card boot completely and initialize DDR
after 3000

# The AXI bus is now hung by the buggy firmware.
# We will access the DAP (which can bypass the hung AXI to reach PS registers)
# Unlock SLCR: write 0xDF0D to 0xF8000008
mwr -force 0xF8000008 0x0000DF0D
after 10
# Assert FPGA resets (FPGA0..3) via FPGA_RST_CTRL (0xF8000240)
mwr -force 0xF8000240 0x0000000F
after 50
# Stop the CPUs now that the bus is un-hung
targets -set -filter {name =~ "*Cortex-A9*#0"}
stop
after 50
targets -set -filter {name =~ "*Cortex-A9*#1"}
stop
after 50

# Deassert FPGA resets
mwr -force 0xF8000240 0x00000000
after 50

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
