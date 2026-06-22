#!/bin/bash
# Bronepoezd runner for the Bulbulator ZX-128 bitstream: ensure JTAG stack, hold the
# XVC target, then xsdb pcap_load.tcl loads the .bit.bin into DDR (verified) and
# configures the PL via PCAP - bypassing the XVC config path (BAD_PACKET-immune).
set -u
VLAB=/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
HWS=/tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server
PCAP_BIN_ARG="${1:-/home/lavrinovich/bulbulator/bulbulator_zx_z010.bit.bin}"

# Drop stale JTAG clients (exact-name match, never -f, to avoid self-kill).
pkill -9 -x vivado_lab 2>/dev/null; pkill -9 -x cs_server 2>/dev/null; pkill -9 -x rdi_xsdb 2>/dev/null
sleep 1
# Bring up the daemon (sudo -n, passwordless) + hw_server only if not already listening.
if [ "$(ss -ltn 2>/dev/null | grep -c :2542)" = "0" ]; then
  sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1; sudo -n rm -f /tmp/xvcd.log
  sudo -n bash -c "setsid /home/lavrinovich/xvc-pico/daemon/xvcd-pico >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
fi
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
after 1800000
TCL
setsid "$VLAB" -mode batch -source /tmp/hold_target.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E 'TARGET_OPEN|XVC_FAIL' /tmp/hold.log 2>/dev/null && break; sleep 2; done
if ! grep -q TARGET_OPEN /tmp/hold.log 2>/dev/null; then echo ">>> FAIL: XVC target not open"; cat /tmp/hold.log; exit 1; fi
echo ">>> XVC target open; PCAP load (DDR + verify + PCAP) ..."
export PCAP_BIN="$PCAP_BIN_ARG"
echo ">>> bin: $PCAP_BIN"
"$XSDB" /home/lavrinovich/zx48/pcap_load.tcl 2>&1
pkill -9 -x vivado_lab 2>/dev/null
echo ">>> PCAP-RUN END"
