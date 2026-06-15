#!/bin/bash
# Flash the PS-clocked HDMI bars demo over XVC-JTAG, in the canonical Zynq order:
#   ps7_init (clocks, FCLK0=100 MHz)  ->  fpga -file (load PL)  ->  ps7_post_config
#   (enable the PS->PL level shifters, without which FCLK0 never reaches the PL).
# Run from this directory. Override paths with VIVADO_LAB / XSDB / XVCD_PICO.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIT="${1:-$HERE/hdmi_stripes_z010.bit}"
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

# A held XVC target gives hw_server the JTAG chain so xsdb can see the Cortex-A9.
cat > /tmp/hold.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
for {set i 0} {$i<8} {incr i} { if {![catch {open_hw_target -xvc_url localhost:2542}]} break; catch {close_hw_target}; after 2000 }
puts "XVC_HELD"
after 90000
TCL
setsid "$VLAB" -mode batch -source /tmp/hold.tcl -nojournal -nolog >/tmp/hold.log 2>&1 &
HOLD=$!
sleep 14

cat > /tmp/seq.tcl <<TCL
connect -url tcp:localhost:3121
after 1500
ta -set -nocase -filter {name =~ "*Cortex-A9*#0"}
stop
source $PS7
ps7_init
puts ">> PS7_INIT_DONE"
ta -set -nocase -filter {name =~ "*xc7z010*"}
fpga -file $BIT
puts ">> FPGA_PROGRAMMED"
ta -set -nocase -filter {name =~ "*Cortex-A9*#0"}
ps7_post_config
puts ">> PS7_POST_CONFIG_DONE"
con
TCL
timeout 180 "$XSDB" /tmp/seq.tcl 2>&1 \
  | grep -aiE "PS7_INIT_DONE|FPGA_PROGRAMMED|PS7_POST_CONFIG_DONE|error|fail"
kill "$HOLD" 2>/dev/null
