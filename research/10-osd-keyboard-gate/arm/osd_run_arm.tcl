# Load + run the bare-metal OSD app on the ARM over JTAG (no SD boot needed).
# The bitstream must already be on the board (flash it first with ../osd_run.sh, PCAP).
# osd.elf is taken from next to this script (build it with `make` in this dir).
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
catch {stop}
puts "VERSION [format 0x%08X [lindex [mrd -value 0x40000000] 0]]"
set HERE [file dirname [file normalize [info script]]]
dow [file join $HERE osd.elf]
con
after 1500
puts "OSD_CTRL [format 0x%08X [lindex [mrd -value 0x40000048] 0]]"
puts "MACHINE_ID [format 0x%08X [lindex [mrd -value 0x40000060] 0]]"
puts "ARM_OSD_DONE"
