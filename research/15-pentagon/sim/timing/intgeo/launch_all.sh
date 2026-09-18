#!/bin/bash
# launch_all.sh - все прогоны геометрии INT параллельно (каждый в своём wd/, см. гочу харнеса №6).
cd "$(dirname "$0")"
./run.sh --build MACHINE=48 RUNUS=100 QUIET=1 > logs/build_check.log 2>&1 || { echo "сборка упала"; exit 1; }
P="PROG=prog/cross_im2.bin ORG=8000 RUNUS=110000"
run() { local wd=$1; shift; nohup ./run.sh --sim-only --wd=$wd "$@" > logs/launch_$wd.log 2>&1 & }
run m48     MACHINE=48   $P
run m128    MACHINE=128  $P
run pentA   MACHINE=PENT $P PINTV=239 PAPERV=60 PAPERH=2
run pentB   MACHINE=PENT $P PINTV=299 PAPERV=60 PAPERH=2
run pentC   MACHINE=PENT $P PINTV=239 PAPERV=0  PAPERH=2
run pentD   MACHINE=PENT $P PINTV=239 PAPERV=24 PAPERH=64
run m48L    MACHINE=48   $P ULALATE=1
run m128L   MACHINE=128  $P ULALATE=1
run m48H    MACHINE=48   $P HCINIT=1
run m48im1  MACHINE=48   PROG=prog/cross_im1.bin ORG=8000 RUNUS=110000 ISRPATCH=9191
wait
echo "все прогоны завершены"
