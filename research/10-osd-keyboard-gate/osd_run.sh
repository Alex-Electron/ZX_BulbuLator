#!/bin/bash
# osd_run.sh - flash the OSD + keyboard-gate bitstream over JTAG (PCAP "armoured train"), then
# load + run the OSD ARM app (arm/osd.elf) on Cortex-A9 #0. The Spectrum comes up on HDMI and the
# OSD is live: F1/F12 open the menu, Esc/F12 close it (the gate diverts the keyboard to the ARM).
#
# Tool paths overridable via env (VIVADO_LAB / XSDB / HW_SERVER / BOOTGEN / XVCD_PICO).
# (For SD boot with no host, flash/BOOT.BIN does all of this on its own - see README.)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
BG="${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"

# 1. bootgen the PCAP .bit.bin (dense bitstreams fail over plain JTAG config on this board)
echo ">>> bootgen .bit.bin ..."
( cd "$HERE/flash" && "$BG" -arch zynq -image bulb_osd_pcap.bif -w -process_bitstream bin ) >/tmp/bg.log 2>&1 \
  && echo "    OK $(ls -la $HERE/bulbulator_zx_osd.bit.bin|awk '{print $5}') bytes" \
  || { echo bootgen FAIL; tail /tmp/bg.log; exit 1; }

# 2. build the ARM app if needed
[ -f "$HERE/arm/osd.elf" ] || ( cd "$HERE/arm" && make ) || { echo "build arm/osd.elf first"; exit 1; }

# 3. bring up xvcd-pico + hw_server, open the JTAG target
pkill -9 -x vivado_lab 2>/dev/null; sleep 1
if [ "$(ss -ltn 2>/dev/null|grep -c :2542)" = 0 ]; then
  sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
  sudo -n bash -c "setsid $XVCD >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
fi
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

# 4. PCAP-config the PL
echo ">>> PCAP config ..."
export PCAP_BIN="$HERE/bulbulator_zx_osd.bit.bin"
"$XSDB" "$HERE/flash/pcap_load.tcl" 2>&1 | grep -E "PS7_INIT|PCFG_DONE|POST_CONFIG|FAIL|DDR"

# 5. load + run the OSD ARM app, read back VERSION (expect 0xB01B0006)
echo ">>> load arm/osd.elf ..."
cat > /tmp/runosd.tcl <<TCL
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
catch {stop}
puts "VERSION [format 0x%08X [lindex [mrd -value 0x40000000] 0]]"
dow $HERE/arm/osd.elf
con
after 1500
puts "OSD_CTRL [format 0x%08X [lindex [mrd -value 0x40000048] 0]]"
puts "MACHINE_ID [format 0x%08X [lindex [mrd -value 0x40000060] 0]]"
TCL
"$XSDB" /tmp/runosd.tcl 2>&1 | grep -E "VERSION|OSD_CTRL|MACHINE_ID|no target"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> OSD-RUN END - press F1/F12 on the PS/2 keyboard"
