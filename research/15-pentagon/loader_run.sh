#!/bin/bash
# loader_run.sh - flash bitstream over JTAG (PCAP), then load + run loader.elf on Cortex-A9 #0.
# HDMI + OSD live: F5 browser, F9 options, F1 help, F12/Esc close.
# (SD boot without host: flash/BOOT.BIN — see README.)
#
# JTAG: Xilinx Platform Cable USB II → hw_server :3121 only.
# Tool paths: VIVADO_LAB / XSDB / HW_SERVER / BOOTGEN.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VLAB="${VIVADO_LAB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab}"
XSDB="${XSDB:-/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
BG="${BOOTGEN:-/tools/Xilinx/Vivado/2023.1/bin/bootgen}"

[ -f "$HERE/arm/loader.elf" ] || { echo "arm/loader.elf missing - see arm/build_loader.sh"; exit 1; }

# 1. bootgen the PCAP .bit.bin
echo ">>> bootgen .bit.bin ..."
( cd "$HERE/flash" && "$BG" -arch zynq -image bulb_loader_pcap.bif -w -process_bitstream bin ) >/tmp/bg.log 2>&1 \
  && echo "    OK $(ls -la $HERE/bulbulator_zx_loader.bit.bin 2>/dev/null | awk '{print $5}') bytes" \
  || { echo bootgen FAIL; tail /tmp/bg.log; exit 1; }

# 2. hw_server for Platform Cable (USB JTAG) on :3121
if [ "$(ss -ltn 2>/dev/null | grep -c :3121)" = 0 ]; then
  echo ">>> starting hw_server ..."
  setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null &
  sleep 5
fi
[ "$(ss -ltn 2>/dev/null | grep -c :3121)" = 0 ] && { echo "hw_server FAIL: :3121 down"; exit 1; }
echo ">>> hw_server OK :3121"

# 3. PCAP-config the PL (pcap_load.tcl connects to 3121)
echo ">>> PCAP config ..."
export PCAP_BIN="$HERE/bulbulator_zx_loader.bit.bin"
"$XSDB" "$HERE/flash/pcap_load.tcl" 2>&1 | grep -E "PS7_INIT|PCFG_DONE|POST_CONFIG|FAIL|DDR" || true

# 4. load + run the loader ARM app
echo ">>> load arm/loader.elf ..."
cat > /tmp/runloader.tcl <<TCL
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
catch {stop}
puts "VERSION [format 0x%08X [lindex [mrd -value 0x40000000] 0]]"
dow $HERE/arm/loader.elf
con
after 1500
puts "MACHINE_ID [format 0x%08X [lindex [mrd -value 0x40000060] 0]]"
TCL
"$XSDB" /tmp/runloader.tcl 2>&1 | grep -E "VERSION|MACHINE_ID|no target"
echo ">>> LOADER-RUN END - F5 browser / F9 options / F1 help on PS/2 keyboard"
