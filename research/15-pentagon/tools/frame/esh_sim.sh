#!/bin/bash
# esh1 в стенде: два корня (Early/Late), фон. Лог BORDER-монитора -> разбор первого белого OUT по строкам.
cd /tmp/ula1/mk
for L in 0 1; do
  R=/tmp/ula1/esh_l$L; mkdir -p $R
  ( ROOT=$R ./xrun.sh --build MACHINE=48 ULALATE=$L PROG=/tmp/ula1/esh1_prog.bin ORG=4000 RUNUS=95000 QUIET=1 > $R/run.log 2>&1; echo "ГОТОВО L=$L код $?" >> $R/run.log ) &
done
wait
for L in 0 1; do echo "=== ULALATE=$L ==="; tail -3 /tmp/ula1/esh_l$L/run.log; done
