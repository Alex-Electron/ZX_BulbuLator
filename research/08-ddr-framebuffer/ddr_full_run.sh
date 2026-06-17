#!/bin/bash
set -u
DIR=/home/lavrinovich/ddrfb
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
BG=/tools/Xilinx/Vivado/2023.1/bin/bootgen
cd "$DIR"
echo ">>> bootgen .bit.bin ..."
"$BG" -arch zynq -image bulb_ddr_pcap.bif -w -process_bitstream bin >/tmp/bg.log 2>&1 && echo "    OK $(ls -la $DIR/bulbulator_zx_ddr.bit.bin|awk "{print \$5}") bytes" || { echo bootgen FAIL; tail /tmp/bg.log; exit 1; }
pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
[ "$(ss -ltn 2>/dev/null|grep -c :3121)" = 0 ] && { setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4; }
rm -f /tmp/hold.log
cat > /tmp/ht.tcl <<TCL
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {\$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!\$ok} { puts XVC_FAIL; exit 1 }
puts TARGET_OPEN
after 180000
TCL
setsid "$VLAB" -mode batch -source /tmp/ht.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E "TARGET_OPEN|XVC_FAIL" /tmp/hold.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold.log || { echo XVC_FAIL; tail /tmp/hold.log; pkill -9 -x vivado_lab; exit 1; }
echo ">>> PCAP config ..."
export PCAP_BIN="$DIR/bulbulator_zx_ddr.bit.bin"
"$XSDB" /home/lavrinovich/zx48/pcap_load.tcl 2>&1 | grep -E "PS7_INIT|PCFG_DONE|POST_CONFIG|FAIL|DDR"
echo ">>> read axi_ctl VERSION (expect 0xB01B0004) ..."
cat > /tmp/rv.tcl <<TCL
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
puts "VERSION [format 0x%08X [lindex [mrd -value 0x40000000] 0]]"
TCL
"$XSDB" /tmp/rv.tcl 2>&1 | grep -E "VERSION|no target"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> DDR-FULL-RUN END"
