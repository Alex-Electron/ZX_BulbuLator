#!/bin/bash
# verify_all.sh - приёмочные прогоны параллельно (каждый в своём wd/<имя> со своей копией снапшота),
# затем сводка. Снапшот должен быть уже собран (./run.sh --build ...).
#   маркер-программа 100 мс на 48/128/PENT (CHECKMARK=1), та же программа в КОНТЕНДЯЩЕМСЯ ОЗУ 48К
#   (ORG=5000, банк 5) и настоящее ПЗУ 5 мс на 48/128/PENT (PCTRACE=40).
cd "$(dirname "$0")"
./prog/build.sh || exit 1
rm -rf wd
./run.sh --sim-only --wd=m48   MACHINE=48   PROG=prog/marker_8000.bin ORG=8000 CHECKMARK=1 RUNUS=100000 >/dev/null 2>&1 &
./run.sh --sim-only --wd=m128  MACHINE=128  PROG=prog/marker_8000.bin ORG=8000 CHECKMARK=1 RUNUS=100000 >/dev/null 2>&1 &
./run.sh --sim-only --wd=mpent MACHINE=PENT PROG=prog/marker_8000.bin ORG=8000 CHECKMARK=1 RUNUS=100000 >/dev/null 2>&1 &
./run.sh --sim-only --wd=c48   MACHINE=48   PROG=prog/marker_5000.bin ORG=5000 CHECKMARK=1 RUNUS=100000 >/dev/null 2>&1 &
./run.sh --sim-only --wd=r48   MACHINE=48   RUNUS=5000 PCTRACE=40 >/dev/null 2>&1 &
./run.sh --sim-only --wd=r128  MACHINE=128  RUNUS=5000 PCTRACE=40 >/dev/null 2>&1 &
./run.sh --sim-only --wd=rpent MACHINE=PENT RUNUS=5000 PCTRACE=40 >/dev/null 2>&1 &
wait
echo "=== готово: $(date)"
for f in logs/run_MACHINE=*.log; do
  echo "#### $f"
  grep -m1 "^tb_zx: MACHINE" "$f"
  grep -A4 "^   1 |" "$f" | head -5
  grep -A9 "^ИТОГ" "$f" | grep -v "^=="
  grep "^wall" "$f"
done
