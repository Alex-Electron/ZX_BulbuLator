#!/bin/bash
# Супервизор опроса: xsdb ВЫЛЕТАЕТ, когда цель исчезает из JTAG (прошивка, rst -system), и никакой
# catch внутри скрипта этого не спасает - процесс просто кончается. Поэтому поднимаем заново.
while true; do
  /tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb ~/gskvm/kvm_probe.tcl >> /tmp/kvm_probe.log 2>&1
  echo "--- probe exited $(date +%T), restart in 5s" >> /tmp/kvm_probe.log
  sleep 5
done
