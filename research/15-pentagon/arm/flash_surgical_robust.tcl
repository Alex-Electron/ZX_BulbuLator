connect
catch { targets -set -filter {name =~ "*DAP*"} }
catch { targets -set -filter {name =~ "*APU*"} }
rst -system
# Let the SD card boot completely and initialize DDR, then hang the bus
after 3000

# The AXI bus is now hung. DAP should be visible again.
targets -set -filter {name =~ "*DAP*"}
# Unlock SLCR: write 0xDF0D to 0xF8000008
mwr -force 0xF8000008 0x0000DF0D
after 10
# Assert FPGA resets (FPGA0..3) via FPGA_RST_CTRL (0xF8000240) to unhang AXI
mwr -force 0xF8000240 0x0000000F
after 100

# Now the AXI bus is un-hung, so APU/Cortex targets should be visible
catch { targets -set -filter {name =~ "*Cortex-A9*#0"}; stop; after 50 }
catch { targets -set -filter {name =~ "*Cortex-A9*#1"}; stop; after 50 }

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
