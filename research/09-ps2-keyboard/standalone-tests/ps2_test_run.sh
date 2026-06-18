#!/bin/bash
# ps2_test_run.sh - PCAP-config the PS/2 read test, then poll the scancode register live.
# Mirrors ddr_full_run.sh (armoured-train PCAP) + a read loop. Run on ThinkPad (board + Pico here).
set -u
DIR=/home/lavrinovich/ps2test
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
BG=/tools/Xilinx/Vivado/2023.1/bin/bootgen
cd "$DIR"

echo ">>> bootgen .bit.bin ..."
"$BG" -arch zynq -image ps2_test_pcap.bif -w -process_bitstream bin >/tmp/bg2.log 2>&1 \
  && echo "    OK $(ls -la $DIR/ps2_test.bit.bin|awk "{print \$5}") bytes" \
  || { echo bootgen FAIL; tail /tmp/bg2.log; exit 1; }

pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
[ "$(ss -ltn 2>/dev/null|grep -c :3121)" = 0 ] && { setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4; }

rm -f /tmp/hold2.log
cat > /tmp/ht2.tcl <<TCL
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {\$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!\$ok} { puts XVC_FAIL; exit 1 }
puts TARGET_OPEN
after 180000
TCL
setsid "$VLAB" -mode batch -source /tmp/ht2.tcl -nojournal -nolog >/tmp/hold2.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E "TARGET_OPEN|XVC_FAIL" /tmp/hold2.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold2.log || { echo XVC_FAIL; tail /tmp/hold2.log; pkill -9 -x vivado_lab; exit 1; }

echo ">>> PCAP config ..."
export PCAP_BIN="$DIR/ps2_test.bit.bin"
"$XSDB" /home/lavrinovich/zx48/pcap_load.tcl 2>&1 | grep -E "PS7_INIT|PCFG_DONE|POST_CONFIG|FAIL|ВЕРИФИ"

echo ">>> PS/2 read loop — НАЖИМАЙ КЛАВИШИ (окно ~80 c) ..."
cat > /tmp/ps2read.tcl <<TCL
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
puts "VERSION [format 0x%08X [lindex [mrd -value 0x40000000] 0]]"
set last -1
for {set i 0} {\$i < 1600} {incr i} {
  set s [lindex [mrd -value 0x40000004] 0]
  if {\$s != \$last} { set last \$s; puts "PS2 scancode=[format 0x%02X [expr {\$s & 0xFF}]] bytes=[expr {(\$s>>8)&0xFFFF}]" }
  after 50
}
puts PS2_READ_END
TCL
"$XSDB" /tmp/ps2read.tcl 2>&1 | grep -E "VERSION|PS2|no target"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> PS2-TEST-RUN END"
