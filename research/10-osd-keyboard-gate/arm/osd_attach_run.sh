#!/bin/bash
# Re-attach to the XVC/JTAG target (board already configured) and run an xsdb tcl. Arg1 = tcl path.
# Tool paths overridable via env (VIVADO_LAB / XSDB / HW_SERVER / XVCD_PICO).
set -u
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"
TCL="$1"
pkill -9 -x vivado_lab 2>/dev/null; sleep 1
if [ "$(ss -ltn 2>/dev/null | grep -c :2542)" = 0 ]; then
  sudo -n pkill -9 -x xvcd-pico 2>/dev/null; sleep 1
  sudo -n bash -c "setsid $XVCD >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
fi
[ "$(ss -ltn 2>/dev/null | grep -c :3121)" = 0 ] && { setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4; }
cat > /tmp/ht.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 3000 }
if {!$ok} { puts XVC_FAIL; exit 1 }
puts TARGET_OPEN
after 120000
TCL
rm -f /tmp/hold.log
setsid "$VLAB" -mode batch -source /tmp/ht.tcl -nojournal -nolog >/tmp/hold.log 2>&1 </dev/null &
for i in $(seq 1 40); do grep -q -E "TARGET_OPEN|XVC_FAIL" /tmp/hold.log 2>/dev/null && break; sleep 2; done
grep -q TARGET_OPEN /tmp/hold.log || { echo XVC_FAIL; tail /tmp/hold.log; pkill -9 -x vivado_lab; exit 1; }
echo TARGET_READY
"$XSDB" "$TCL" 2>&1
pkill -9 -x vivado_lab 2>/dev/null
echo ATTACH_RUN_END
