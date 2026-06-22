#!/bin/bash
# ddrfb_p2a_run.sh - Phase 2a: PCAP-config the capture-path bit. A synthetic ULA (spclk) is captured
# through the FIFO/CDC into DDR and scanned out tear-free. PASS = colour bars scroll smoothly on HDMI.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DIR="$HERE"
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
BG="${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"
cd "$DIR"

echo ">>> bootgen .bit.bin ..."
"$BG" -arch zynq -image ddrfb_p2a_pcap.bif -w -process_bitstream bin >/tmp/bg.log 2>&1 \
  && echo "    OK $(ls -la $DIR/ddrfb_p2a.bit.bin | awk '{print $5}') bytes" \
  || { echo ">>> bootgen FAIL"; tail -8 /tmp/bg.log; exit 1; }

pkill -9 -x vivado_lab 2>/dev/null; sleep 1
sudo -n pkill -9 -x "$XVCD" 2>/dev/null; sleep 1
sudo -n bash -c "setsid $XVCD >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
if [ "$(ss -ltn 2>/dev/null | grep -c :3121)" = "0" ]; then
  setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4
fi
rm -f /tmp/hold.log
cat > /tmp/hold_target.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!$ok} { puts "XVC_FAIL"; exit 1 }
puts "TARGET_OPEN"
after 180000
TCL
setsid "$VLAB" -mode batch -source /tmp/hold_target.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E 'TARGET_OPEN|XVC_FAIL' /tmp/hold.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold.log || { echo ">>> XVC FAIL"; tail /tmp/hold.log; pkill -9 -x vivado_lab; exit 1; }

echo ">>> PCAP config the Phase-2a bit ..."
export PCAP_BIN="$DIR/ddrfb_p2a.bit.bin"
"$XSDB" "$HERE/../flash/pcap_load.tcl" 2>&1 | grep -E "PS7_INIT|PCFG_DONE|POST_CONFIG|FAIL|DDR"

echo ">>> read GP0 status (capture+loader liveness + FIFO high-water) ..."
cat > /tmp/ddrfb_post.tcl <<'TCL'
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
proc r {a} { return [format 0x%08X [lindex [mrd -value $a] 0]] }
puts "VERSION   [r 0x40000000]   (expect 0xB01BDDF3)"
puts "LD_FRAMES [r 0x4000000C]"
puts "WR_FRAMES [r 0x40000018]"
puts "BUFSTATE  [r 0x4000001C]   ({ready,disp,wr} 2b each)"
puts "FIFO_MAX  [r 0x40000020]   (capture FIFO high-water; must stay well below 64)"
after 500
puts "--- after 500ms ---"
puts "LD_FRAMES [r 0x4000000C]   (should climb ~25)"
puts "WR_FRAMES [r 0x40000018]   (should climb ~25)"
puts "BUFSTATE  [r 0x4000001C]"
puts "FIFO_MAX  [r 0x40000020]"
TCL
"$XSDB" /tmp/ddrfb_post.tcl 2>&1 | grep -E "VERSION|LD_FRAMES|WR_FRAMES|BUFSTATE|FIFO_MAX|---|Error|no target"
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> DDRFB-P2A-RUN END"
