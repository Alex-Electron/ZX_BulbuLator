#!/bin/bash
# bg.sh - запустить прогон run.sh в фоне (nohup, свой wd), чтобы не зависеть от ssh-сессии.
#   ./bg.sh <wd-имя> NAME=VAL ...   -> лог logs/run_<аргументы>.log, stdout в wd/<имя>/nohup.out
cd "$(dirname "$0")"
WD=$1; shift
mkdir -p "wd/$WD"
nohup setsid ./run.sh --sim-only --wd="$WD" "$@" > "wd/$WD/nohup.out" 2>&1 &
echo "started $WD pid $!"
