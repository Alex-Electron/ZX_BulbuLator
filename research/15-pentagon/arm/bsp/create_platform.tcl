# create_platform.tcl - xsct script: the Vitis 2023.1 platform the ARM shell (loader.elf) builds against.
#
#   xsct create_platform.tcl <workspace_dir> <hw.xsa>
#
# Recreates the hand-made workspace that used to live only on the build machine:
#   platform  ebaz                                 (from the .xsa next to this script)
#   domain    zynq_fsbl        ps7_cortexa9_0      (boot domain, auto-created; builds the Zynq FSBL)
#   domain    standalone_domain ps7_cortexa9_0     standalone 8.1 + xilffs 5.0 (use_lfn=1, enable_exfat=true)
#   domain    ps7_cortexa9_1   ps7_cortexa9_1      standalone 8.1 + lwip213 1.0 (lwip_dhcp, dhcp_does_arp_check)
# Every other BSP parameter stays at the Vitis default (stdin/stdout = ps7_uart_1).
# The source patches (patches/*.patch) are applied afterwards by make_bsp.sh, which then rebuilds the BSP.
if {[llength $argv] != 2} {
    puts "usage: xsct create_platform.tcl <workspace_dir> <hw.xsa>"
    exit 2
}
set ws  [file normalize [lindex $argv 0]]
set xsa [file normalize [lindex $argv 1]]
file mkdir $ws
setws $ws

platform create -name ebaz -hw $xsa -os standalone -proc ps7_cortexa9_0
# the default domain created above is "standalone_domain" on ps7_cortexa9_0
domain active standalone_domain
bsp setlib -name xilffs -ver 5.0
bsp config use_lfn 1
bsp config enable_exfat true

# core 1: network (web KVM) - build_loader.sh links liblwip4.a from this domain
domain create -name ps7_cortexa9_1 -os standalone -proc ps7_cortexa9_1
domain active ps7_cortexa9_1
bsp setlib -name lwip213 -ver 1.0
bsp config lwip_dhcp true
bsp config dhcp_does_arp_check true

platform write
platform generate
puts ">>> PLATFORM DONE: $ws/ebaz"
