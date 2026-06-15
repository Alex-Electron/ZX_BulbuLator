# HDMI 1280x720 demo with buttons for xc7z010clg400-1.
# Expected bitstream size ~2,083,867 bytes.
# Build from this script's directory; expects pattern_gen.v, clkgen.v, hdmi.xdc
# alongside it (the runner copies pattern_gen3.v -> pattern_gen.v, clkgen2.v ->
# clkgen.v, hdmi_btn720.xdc -> hdmi.xdc).
set root [file normalize [file dirname [info script]]]
create_project -force hdmi720_z010 $root/proj -part xc7z010clg400-1
# Needs Digilent's rgb2dvi IP. Point this at your vivado-library checkout
# (set VIVADO_LIBRARY, or it defaults to ~/vivado-library).
set viv_lib [expr {[info exists ::env(VIVADO_LIBRARY)] ? $::env(VIVADO_LIBRARY) : "$::env(HOME)/vivado-library"}]
set_property ip_repo_paths $viv_lib [current_project]
update_ip_catalog
add_files $root/pattern_gen3.v
add_files $root/clkgen2.v
add_files -fileset constrs_1 $root/hdmi_btn720.xdc

create_bd_design design_1

set ck [create_bd_cell -type module -reference clkgen ck]

set cw [create_bd_cell -type ip -vlnv [lindex [lsort [get_ipdefs -all *:clk_wiz:*]] end] cw]
set_property -dict [list CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {100.000} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {371.250} CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true}] $cw
puts ">>> clk_wiz: M=[get_property CONFIG.MMCM_CLKFBOUT_MULT_F $cw] D=[get_property CONFIG.MMCM_DIVCLK_DIVIDE $cw] OUT1div=[get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $cw] OUT2div=[get_property CONFIG.MMCM_CLKOUT1_DIVIDE $cw]"

set rg [create_bd_cell -type ip -vlnv [lindex [get_ipdefs -all *rgb2dvi*] 0] rg]
set_property -dict [list CONFIG.kGenerateSerialClk {false} CONFIG.kRstActiveHigh {true}] $rg

set pg [create_bd_cell -type module -reference pattern_gen pg]

set inv [create_bd_cell -type ip -vlnv [lindex [lsort [get_ipdefs -all *util_vector_logic*]] end] inv]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $inv

connect_bd_net [get_bd_pins ck/fclk0]      [get_bd_pins cw/clk_in1]
connect_bd_net [get_bd_pins cw/clk_out1]   [get_bd_pins pg/pclk] [get_bd_pins rg/PixelClk]
connect_bd_net [get_bd_pins cw/clk_out2]   [get_bd_pins rg/SerialClk]
connect_bd_net [get_bd_pins cw/locked]     [get_bd_pins inv/Op1]
connect_bd_net [get_bd_pins inv/Res]       [get_bd_pins rg/aRst]
connect_bd_net [get_bd_pins pg/vid_data]   [get_bd_pins rg/vid_pData]
connect_bd_net [get_bd_pins pg/vde]        [get_bd_pins rg/vid_pVDE]
connect_bd_net [get_bd_pins pg/hsync]      [get_bd_pins rg/vid_pHSync]
connect_bd_net [get_bd_pins pg/vsync]      [get_bd_pins rg/vid_pVSync]

make_bd_pins_external -name TMDS_Clk_p  [get_bd_pins rg/TMDS_Clk_p]
make_bd_pins_external -name TMDS_Clk_n  [get_bd_pins rg/TMDS_Clk_n]
make_bd_pins_external -name TMDS_Data_p [get_bd_pins rg/TMDS_Data_p]
make_bd_pins_external -name TMDS_Data_n [get_bd_pins rg/TMDS_Data_n]
make_bd_pins_external -name btn0 [get_bd_pins pg/btn0]
make_bd_pins_external -name btn1 [get_bd_pins pg/btn1]
make_bd_pins_external -name btn2 [get_bd_pins pg/btn2]
make_bd_pins_external -name btn3 [get_bd_pins pg/btn3]
make_bd_pins_external -name led_heart [get_bd_pins pg/led_heart]
# cw/locked already drives the inverter (rgb2dvi reset), so make_bd_pins_external
# silently refuses to also export it. Add an explicit output port and fan the
# existing 'locked' net out to it so D18 (a real on-board LED) shows MMCM lock.
create_bd_port -dir O led_lock
connect_bd_net [get_bd_pins cw/locked] [get_bd_port led_lock]

save_bd_design
validate_bd_design
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top
set wrap [lindex [glob -nocomplain $root/proj/*.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v $root/proj/*.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v] 0]
puts ">>> wrapper: $wrap"
add_files -norecurse $wrap
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts ">>> START IMPL [clock format [clock seconds] -format %H:%M:%S]"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts ">>> IMPL STATUS=[get_property STATUS [get_runs impl_1]] PROGRESS=[get_property PROGRESS [get_runs impl_1]]"
set bit [glob -nocomplain $root/proj/hdmi720_z010.runs/impl_1/design_1_wrapper.bit]
if {$bit ne ""} { file copy -force [lindex $bit 0] $root/hdmi720_z010.bit }
puts ">>> DONE bit=[file exists $root/hdmi720_z010.bit] size=[expr {[file exists $root/hdmi720_z010.bit] ? [file size $root/hdmi720_z010.bit] : 0}]"
