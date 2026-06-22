#!/bin/bash
# Reliable two-part flash for the PS-clocked HDMI design:
#   1) program the PL over JTAG with vivado_lab (robust, with retries)
#   2) bring up the PS clock with xsdb: ps7_init (FCLK0 = 100 MHz) + ps7_post_config
#      (enable the PS->PL level shifters), so the already-loaded design lights up.
# This deliberately avoids the xsdb `fpga -file` path, which is flaky on dense
# bitstreams. Run from this directory. Override paths with VIVADO_LAB / XSDB /
# HW_SERVER / XVCD_PICO.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIT="${1:-$HERE/hdmi_beep_z010.bit}"
PS7="$HERE/ps7_init_fclk.tcl"
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"

# Bring up the XVC stack if it isn't running.
if [ "$(ss -ltn 2>/dev/null | grep -c :2542)" = "0" ]; then
  sudo -n pkill -9 -f xvcd-pico 2>/dev/null; sleep 1; sudo -n rm -f /tmp/xvcd.log
  sudo -n bash -c "setsid '$XVCD' >/tmp/xvcd.log 2>&1 </dev/null &"; sleep 3
fi
if [ "$(ss -ltn 2>/dev/null | grep -c :3121)" = "0" ]; then
  setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4
fi

echo "=== 1) program the PL (vivado_lab) ==="
echo "set BITFILE {$BIT}" > /tmp/prog.tcl
cat >> /tmp/prog.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} {set ok 1;break}; catch {close_hw_target}; after 2000 }
if {!$ok} { puts "XVC_FAIL"; exit 1 }
set pl ""
foreach d [get_hw_devices] { if {[string match -nocase *7z010* [get_property PART $d]]} { current_hw_device $d; set pl $d } }
if {$pl eq ""} { puts "NO_7Z010"; exit 1 }
set_property PROGRAM.FILE $BITFILE $pl
for {set a 1} {$a<=3} {incr a} { puts ">> program attempt $a"; if {![catch {program_hw_devices $pl}]} break; after 2000 }
TCL
timeout 200 "$VLAB" -mode batch -source /tmp/prog.tcl -nojournal -nolog 2>&1 \
  | grep -aiE "program attempt|startup status|XVC_FAIL|NO_7Z010"

echo "=== 2) bring up the PS clock (xsdb: ps7_init + ps7_post_config) ==="
# Hold the XVC cable so hw_server exposes the Cortex-A9 to xsdb.
cat > /tmp/hold.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} break; catch {close_hw_target}; after 2000 }
puts "XVC_HELD"
after 60000
TCL
setsid "$VLAB" -mode batch -source /tmp/hold.tcl -nojournal -nolog >/tmp/hold.log 2>&1 &
HOLD=$!
sleep 14
cat > /tmp/ps7.tcl <<TCL
connect -url tcp:localhost:3121
after 1500
ta -set -nocase -filter {name =~ "*Cortex-A9*#0"}
stop
source $PS7
ps7_init
puts ">> PS7_INIT_DONE (FCLK0=100)"
ps7_post_config
puts ">> PS7_POST_CONFIG_DONE (level shifters on)"
con
TCL
timeout 90 "$XSDB" /tmp/ps7.tcl 2>&1 \
  | grep -aiE "PS7_INIT_DONE|PS7_POST_CONFIG_DONE|error|fail"

# Tidy up the JTAG client processes so the next run starts clean.
kill "$HOLD" 2>/dev/null
pkill -9 -f vivado_lab 2>/dev/null; pkill -9 -x cs_server 2>/dev/null; pkill -9 -f rdi_xsdb 2>/dev/null
echo "=== DONE ==="
