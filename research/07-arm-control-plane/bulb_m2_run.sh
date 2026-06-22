#!/bin/bash
# bulb_m2_run.sh - Milestone 2 end-to-end, fully local on ThinkPad (Pico on USB):
#   bootgen .bit.bin -> ensure JTAG stack -> hold XVC -> PCAP-configure PL ->
#   xsdb: ARM HALTs the Z80 and paints the Spectrum screen red.
set -u
DIR=/home/lavrinovich/bulbulator
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
BG=/tools/Xilinx/Vivado/2023.1/bin/bootgen
cd "$DIR"

# 0) bootgen: .bit -> .bit.bin (PCAP-ready)
echo ">>> bootgen .bit.bin ..."
"$BG" -arch zynq -image bulb_pcap.bif -w -process_bitstream bin >/tmp/bootgen.log 2>&1 \
  && echo ">>> bootgen OK: $(ls -la $DIR/bulbulator_zx_z010.bit.bin)" \
  || { echo ">>> bootgen FAIL"; tail -20 /tmp/bootgen.log; exit 1; }

# 1) ensure the JTAG stack (exact-name pkill, never -f, to avoid self-kill)
pkill -9 -x vivado_lab 2>/dev/null; pkill -9 -x cs_server 2>/dev/null; pkill -9 -x rdi_xsdb 2>/dev/null; sleep 1
if [ "$(ss -ltn 2>/dev/null | grep -c :2542)" = "0" ]; then
  sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1; sudo -n rm -f /tmp/xvcd.log
  sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
fi
if [ "$(ss -ltn 2>/dev/null | grep -c :3121)" = "0" ]; then
  setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4
fi

# 2) hold the XVC target
rm -f /tmp/hold.log
cat > /tmp/hold_target.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!$ok} { puts "XVC_FAIL"; exit 1 }
puts "TARGET_OPEN"
after 1800000
TCL
setsid "$VLAB" -mode batch -source /tmp/hold_target.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E 'TARGET_OPEN|XVC_FAIL' /tmp/hold.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold.log || { echo ">>> FAIL: XVC not open"; cat /tmp/hold.log; pkill -9 -x vivado_lab; exit 1; }
echo ">>> XVC open; PCAP load (DDR + verify + PCAP config) ..."

# 3) PCAP-configure the PL with the integrated bitstream
export PCAP_BIN="$DIR/bulbulator_zx_z010.bit.bin"
"$XSDB" /home/lavrinovich/zx48/pcap_load.tcl 2>&1
echo ">>> PCAP done; HALT + paint screen ..."

# 4) ARM halts the Z80 and paints the screen
"$XSDB" "$DIR/m2_poke.tcl" 2>&1

pkill -9 -x vivado_lab 2>/dev/null
echo ">>> M2-RUN END"
