#!/bin/bash
# make_tables.sh - собрать TABLES.md (полные таблицы parse.py по всем группам прогонов) из logs/.
cd "$(dirname "$0")"
L=logs
{
echo "# Полные таблицы стенда бордюра (сгенерировано make_tables.sh из logs/)"
echo
echo "Колонки: k - паддинг в T; wr - номер записи в ISR (2 = белый, 3 = красный через 24 T); кадр - номер кадра стенда;"
echo "T_pc/T_pe - импульсы pc3M5/pe3M5 в [E_int, E_wr); удерж. = T_pe-T_pc (контеншен IO); запись: строка/hc пикселя, начавшегося на фронте записи;"
echo "виден: строка/колонка (hc) первого пикселя нового цвета; Δpx = виден - запись; кол-бумага = колонка минус первая колонка бумаги (12 у 48K/128K, 14 у Пентагона)."
echo "Без --jitter одинаковые кадры свёрнуты; строка «РАЗНЫЕ значения по кадрам {1: 2}» для wr=1 означает лишь, что в первом кадре запись чёрного не меняла цвет (бордюр уже был чёрным)."
echo
for grp in "48 верхний бордюр (k 2240..2263)|48|logs/run_MACHINE=48_PROG=prog-k22[4-6]?.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "48 слева от бумаги (k 14267..14298)|48|logs/run_MACHINE=48_PROG=prog-k142[6-9]?.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "48 справа от бумаги (k 14412..14427)|48|logs/run_MACHINE=48_PROG=prog-k144??.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "48 нижний бордюр (k 58013..58036)|48|logs/run_MACHINE=48_PROG=prog-k580??.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "48 джиттер, 220 мс, k=2241 (все кадры)|48 --jitter|logs/run_MACHINE=48_PROG=prog-k2241.bin_ORG=8000_RUNUS=220000_QUIET=1_BMON=1.log" \
           "48 джиттер, 220 мс, k=14284 (все кадры)|48 --jitter|logs/run_MACHINE=48_PROG=prog-k14284.bin_ORG=8000_RUNUS=220000_QUIET=1_BMON=1.log" \
           "128 верхний бордюр (k 2240..2247)|128|logs/run_MACHINE=128_PROG=prog-k224?.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "128 слева от бумаги (k 14310..14317)|128|logs/run_MACHINE=128_PROG=prog-k1431?.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "PENT бордюр, строка 280 (k 9000..9009, PINTV=239)|PENT|logs/run_MACHINE=PENT_PROG=prog-k900?.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "PENT строка 0 = бордюр при paper_v=60 (k 17928..17937, PINTV=239) - колонка «кол-бумага» здесь не имеет смысла|PENT|logs/run_MACHINE=PENT_PROG=prog-k179??.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log" \
           "PENT у левого края бумаги, строка 60 (k 17928..17937, PINTV=299 как в прошивке)|PENT|logs/run_MACHINE=PENT_PROG=prog-k179??.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1_PINTV=299.log" \
           "PENT внутри бумаги, строка 249/250 (k 2240, PINTV=239)|PENT|logs/run_MACHINE=PENT_PROG=prog-k2240.bin_ORG=8000_RUNUS=76000_QUIET=1_BMON=1.log"; do
  title=${grp%%|*}; rest=${grp#*|}; margs=${rest%%|*}; glob=${rest#*|}
  echo "## $title"; echo
  files=$(ls $glob 2>/dev/null)
  if [ -z "$files" ]; then echo "(логов нет)"; echo; continue; fi
  python3 parse.py $margs $files
  echo
done
} > TABLES.md
echo "TABLES.md: $(wc -l < TABLES.md) строк"
