#!/bin/bash
# ps2_read_only.sh - re-attach XVC and read the PS/2 status register. NO re-flash (PL stays
# configured from the PCAP load until power-cycle). Full xsdb output for diagnosis.
set -u
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
[ "$(ss -ltn 2>/dev/null|grep -c :3121)" = 0 ] && { setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4; }
rm -f /tmp/hold3.log
cat > /tmp/ht3.tcl <<TCL
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {\$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!\$ok} { puts XVC_FAIL; exit 1 }
puts TARGET_OPEN
after 180000
TCL
setsid "$VLAB" -mode batch -source /tmp/ht3.tcl -nojournal -nolog >/tmp/hold3.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E "TARGET_OPEN|XVC_FAIL" /tmp/hold3.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold3.log || { echo XVC_FAIL; tail /tmp/hold3.log; pkill -9 -x vivado_lab; exit 1; }
echo ">>> read (ПЛ уже сконфигурирована) — НАЖИМАЙ КЛАВИШИ ~80c ..."
cat > /tmp/ps2read.tcl <<TCL
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
after 500
puts "=== targets ==="
targets
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
if {[catch {mrd -value 0x40000000} ver]} { puts "ERR_VER: \$ver" } else { puts "VERSION [format 0x%08X [lindex \$ver 0]]" }
set last -1
for {set i 0} {\$i < 1600} {incr i} {
  if {[catch {mrd -value 0x40000004} s]} { puts "ERR_RD: \$s"; break }
  set v [lindex \$s 0]
  if {\$v != \$last} { set last \$v; puts "PS2 scancode=[format 0x%02X [expr {\$v & 0xFF}]] bytes=[expr {(\$v>>8)&0xFFFF}]" }
  after 50
}
puts PS2_READ_END
TCL
"$XSDB" /tmp/ps2read.tcl 2>&1
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> READ-ONLY END"
