#!/bin/bash
# ddr_inject_run.sh - PCAP-config the DDR-framebuffer bulbulator, then inject a .z80 via the ARM
# (zxinj) over the AXI control plane. The injected demo is captured through the DDR double buffer.
set -u
DIR=/home/lavrinovich/ddrfb
ZXINJ=/home/lavrinovich/zxinj
SNAP=${1:-/home/lavrinovich/zxinj/mescaline.z80}
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
BG=/tools/Xilinx/Vivado/2023.1/bin/bootgen

echo ">>> rebuild zxinj.elf embedding $(basename $SNAP) ..."
cd "$ZXINJ"
cp -f "$SNAP" /tmp/snap.z80
xxd -i /tmp/snap.z80 | sed 's/__tmp_snap_z80/z80_data/g; s/_tmp_snap_z80/z80_data/g' > z80_blob.c
arm-none-eabi-gcc -mcpu=cortex-a9 -marm -ffreestanding -nostdlib -O2 crt0.S main.c z80_blob.c -T inject.ld -o zxinj.elf 2>&1 | tail -3
ls -la zxinj.elf | awk '{print "    elf",$5,"bytes"}'

echo ">>> bootgen DDR .bit.bin ..."
cd "$DIR"
"$BG" -arch zynq -image bulb_ddr_nosnow_pcap.bif -w -process_bitstream bin >/tmp/bg.log 2>&1 && echo "    OK" || { echo bootgen FAIL; tail /tmp/bg.log; exit 1; }

pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
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
export PCAP_BIN="$DIR/bulbulator_zx_ddr_nosnow.bit.bin"
"$XSDB" /home/lavrinovich/zx48/pcap_load.tcl 2>&1 | grep -E "PCFG_DONE|POST_CONFIG|FAIL"

echo ">>> dow + run the ARM injector ..."
cat > /tmp/zxinj_dow.tcl <<'TCL'
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
dow /home/lavrinovich/zxinj/zxinj.elf
rwr cpsr 0x1d3
rwr pc 0x00200000
con
puts ">>> INJECTOR RUNNING -- demo should appear on HDMI via the DDR framebuffer"
TCL
"$XSDB" /tmp/zxinj_dow.tcl 2>&1 | grep -E "INJECTOR RUNNING|no target|Error"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> DDR-INJECT-RUN END"
