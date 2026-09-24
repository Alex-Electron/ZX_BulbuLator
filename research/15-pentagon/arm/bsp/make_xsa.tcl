# make_xsa.tcl - Vivado 2023.1 batch script: write the hardware handoff (.xsa) the ARM BSP is generated from.
#
#   vivado -mode batch -nojournal -nolog -source make_xsa.tcl -tclargs <out.xsa>
#
# The design is the Zynq PS7 alone, configured by ps7_params.tcl, with FCLK_CLK0 wired to M_AXI_GP0_ACLK.
# No PL logic, no synthesis, no bitstream: the BSP only needs the PS description (xparameters.h,
# driver list) and the FSBL only needs ps7_init.c. The machine bitstreams are built separately.
if {[llength $argv] != 1} { puts "usage: ... -tclargs <out.xsa>"; exit 2 }
set out  [file normalize [lindex $argv 0]]
set here [file dirname [file normalize [info script]]]
set tmp  [file join [file dirname $out] .make_xsa_tmp]
file delete -force $tmp
source [file join $here ps7_params.tcl]

create_project -force ebaz4205_ps7 $tmp -part xc7z010clg400-1
create_bd_design ebaz4205_ps7
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict $PS7_PARAMS $ps
set_property -dict $PS7_PARAMS_LATE $ps
make_bd_intf_pins_external [get_bd_intf_pins ps7/DDR] [get_bd_intf_pins ps7/FIXED_IO]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
validate_bd_design
save_bd_design

set bd [get_files ebaz4205_ps7.bd]
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]
set_property top ebaz4205_ps7_wrapper [current_fileset]
update_compile_order -fileset sources_1

write_hw_platform -fixed -force -file $out
close_project
file delete -force $tmp
puts ">>> XSA DONE: $out"
