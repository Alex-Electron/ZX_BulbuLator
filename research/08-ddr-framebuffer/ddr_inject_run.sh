#!/bin/bash
# ddr_inject_run.sh - PCAP-config the DDR-framebuffer bulbulator, then inject a .z80 via the ARM
# (zxinj) over the AXI control plane. The injected demo is captured through the DDR double buffer.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SNAP=${1:-}
[ -n "$SNAP" ] || { echo "usage: $(basename "$0") <snapshot.z80>  (bring your own 128K .z80)"; exit 1; }
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
BG="${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"

echo ">>> rebuild zxinj.elf embedding $(basename $SNAP) ..."
"$HERE/zxinj/build_inj.sh" "$SNAP" 2>&1 | tail -3
ls -la "$HERE/zxinj/zxinj.elf" | awk '{print "    elf",$5,"bytes"}'

echo ">>> bootgen DDR .bit.bin ..."
( cd "$HERE/flash" && "$BG" -arch zynq -image bulb_ddr_pcap.bif -w -process_bitstream bin ) >/tmp/bg.log 2>&1 && echo "    OK" || { echo bootgen FAIL; tail /tmp/bg.log; exit 1; }

pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
sudo -n bash -c "setsid $XVCD >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
[ "$(ss -ltn 2>/dev/null|grep -c :3121)" = 0 ] && { setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4; }
rm -f /tmp/hold.log
cat > /tmp/ht.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!$ok} { puts XVC_FAIL; exit 1 }
puts TARGET_OPEN
after 180000
TCL
setsid "$VLAB" -mode batch -source /tmp/ht.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E 'TARGET_OPEN|XVC_FAIL' /tmp/hold.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold.log || { echo XVC_FAIL; tail /tmp/hold.log; pkill -9 -x vivado_lab; exit 1; }

echo ">>> PCAP config DDR bit ..."
export PCAP_BIN="${PCAP_BIN:-$HERE/bulbulator_zx_ddr.bit.bin}"
"$XSDB" "$HERE/flash/pcap_load.tcl" 2>&1 | grep -E "PCFG_DONE|POST_CONFIG|FAIL"

echo ">>> dow + run the ARM injector ..."
cat > /tmp/zxinj_dow.tcl <<TCL
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
dow $HERE/zxinj/zxinj.elf
rwr cpsr 0x1d3
rwr pc 0x00200000
con
puts ">>> INJECTOR RUNNING -- demo should appear on HDMI via the DDR framebuffer"
TCL
"$XSDB" /tmp/zxinj_dow.tcl 2>&1 | grep -E "INJECTOR RUNNING|no target|Error"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> DDR-INJECT-RUN END"
