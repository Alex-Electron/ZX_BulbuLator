#!/bin/bash
# Generic: program xc7z010 PL with a given .bit over XVC-JTAG (vivado_lab).
# Self-heals the xvcd-pico + hw_server stack. Usage: jtag_flash.sh /path/to.bit
# Logs to /tmp/flash_z010.log
exec > /tmp/flash_z010.log 2>&1
BIT="${1:?need bit path}"
# Override these for your machine: VIVADO_LAB, HW_SERVER, XVCD_PICO.
VLAB="${VIVADO_LAB:-$(command -v vivado_lab || echo /tools/Xilinx/Vivado_Lab/2023.1/bin/vivado_lab)}"
HWS="${HW_SERVER:-$(dirname "$VLAB")/hw_server}"
XVCD="${XVCD_PICO:-$HOME/xvc-pico/daemon/xvcd-pico}"

echo "=== flashing: $BIT ($(date +%T)) ==="
if [ "$(ss -ltn 2>/dev/null | grep -c :2542)" = "0" ]; then
  echo "restart xvcd-pico"
  sudo -n pkill -9 -f xvcd-pico 2>/dev/null; sleep 1; sudo -n rm -f /tmp/xvcd.log
  sudo -n bash -c "setsid '$XVCD' >/tmp/xvcd.log 2>&1 </dev/null &"
  sleep 3
fi
if [ "$(ss -ltn 2>/dev/null | grep -c :3121)" = "0" ]; then
  echo "restart hw_server"; setsid "$HWS" >/tmp/hwsrv.log 2>&1 </dev/null & sleep 4
fi
echo "ports: 2542=$(ss -ltn 2>/dev/null | grep -c :2542) 3121=$(ss -ltn 2>/dev/null | grep -c :3121)"

echo "set BITFILE {$BIT}" > /tmp/prog.tcl
cat >> /tmp/prog.tcl <<'TCL'
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 0} {$i<8} {incr i} {
  if {![catch {open_hw_target -xvc_url localhost:2542}]} { set ok 1; break }
  catch {close_hw_target}; after 2000
}
if {!$ok} { puts "XVC_FAIL"; exit 1 }
set pl ""
foreach d [get_hw_devices] {
  if {[string match -nocase *7z010* [get_property PART $d]]} { current_hw_device $d; set pl $d }
}
if {$pl eq ""} { puts "NO_7Z010"; exit 1 }
set_property PROGRAM.FILE $BITFILE $pl
set done 0
for {set a 1} {$a<=3} {incr a} {
  puts ">> attempt $a"
  if {[catch {program_hw_devices $pl} e]} { puts ">> att$a ERR: $e"; after 2000 } else { set done 1; break }
}
puts "PROGRAMMED=$done"
TCL
timeout 300 "$VLAB" -mode batch -source /tmp/prog.tcl -nojournal -nolog 2>&1 \
  | grep -aiE "attempt|startup status|XVC_FAIL|NO_7Z010|PROGRAMMED|done!|^ERROR"
echo "=== xvcd.log tail ==="; sudo -n tail -2 /tmp/xvcd.log 2>/dev/null
echo "=== DONE $(date +%T) ==="
