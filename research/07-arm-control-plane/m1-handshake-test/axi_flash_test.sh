#!/bin/bash
# axi_flash_test.sh - Milestone 1 AXI GP0 handshake test, fully local on ThinkPad.
# Pico on ThinkPad USB; xvcd-pico (:2542) + hw_server (:3121) already running.
# Model: vivado_lab opens+holds the XVC target so hw_server has the JTAG chain,
# then xsdb runs ps7_init (FCLK0 -> GP0 clock), programs the PL, and does mrd/mwr.
set -u
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb

# 1) vivado_lab: open + hold the XVC target.
rm -f /tmp/hold.log
cat > /tmp/hold_target.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!$ok} { puts "XVC_FAIL"; exit 1 }
puts "TARGET_OPEN"
after 240000
TCL
setsid $VLAB -mode batch -source /tmp/hold_target.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &

echo ">> waiting for XVC target..."
for i in $(seq 1 45); do grep -q -E 'TARGET_OPEN|XVC_FAIL' /tmp/hold.log 2>/dev/null && break; sleep 2; done
if ! grep -q TARGET_OPEN /tmp/hold.log 2>/dev/null; then
    echo ">> FAIL: XVC target did not open"; tail -20 /tmp/hold.log; pkill -9 -f hold_target.tcl; exit 1
fi
echo ">> XVC target open, running xsdb..."

# 2) xsdb: stop A9, ps7_init, program PL, GP0 register round-trip.
cat > /tmp/axi.tcl <<'TCL'
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
stop
cd /home/lavrinovich/vm-migrate/hdmi720pl
source ps7_init_fclk.tcl
ps7_init
ps7_post_config
puts ">>> PS7_INIT DONE (FCLK0 up -> GP0 clock live)"
if {[catch {fpga -file /home/lavrinovich/axi_test/bulb_axi_test.bit} e]} {
    puts ">>> fpga -file FAILED: $e  (if BAD_PACKET, fall back to PCAP)"
} else {
    puts ">>> PL CONFIGURED"
}
after 200
proc r32 {a} { return [lindex [mrd -value $a] 0] }
puts "VERSION  0x40000000 = [r32 0x40000000]   expect B01B0001"
mwr 0x40000004 0x00000001
puts "CONTROL  0x40000004 = [r32 0x40000004]   expect 00000001 (LED D18 on)"
mwr 0x40000008 0xCAFEF00D
puts "SCRATCH  0x40000008 = [r32 0x40000008]   expect CAFEF00D"
puts "COUNTER  0x4000000C = [r32 0x4000000C]"
puts "COUNTER  0x4000000C = [r32 0x4000000C]   expect a different value"
puts ">>> AXI TEST DONE"
TCL
$XSDB /tmp/axi.tcl 2>&1
pkill -9 -f hold_target.tcl 2>/dev/null
echo ">>> END"
