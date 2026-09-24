#!/bin/bash
# Сверка СВЕЖЕСТИ: что в дереве, что в каталоге сборки, что в ПЛИС, что на карте.
#
# 🥇 Зачем. 13.08 половина отказов оказалась не в коде, а в несвежести:
#   * на карте лежало ядро MiSTer-48, отставшее на семьдесят сборок, и правка ленты «не работала»;
#   * каталог `sources/build/` держал до-фиксовую копию `video.v`, а `build.tcl` запускают ИЗ него -
#     синтез собрал бы ядро без правки МОЛЧА;
#   * ядро B0131 работает на плате и не существует в ветке master.
# Каждый раз это выглядело как дефект логики и съедало часы. Проверка стоит секунды.
#
# Запуск: ./tools/check_fresh.sh        (нужен ssh-доступ к плате через hw_server на :3121)
set -u
REPO="$HOME/bulb-v13/research/15-pentagon"
SRC="$REPO/sources"
BUILD="$SRC/build"
XSDB=/tools/Xilinx/Vivado_Lab/2023.1/bin/xsdb
bad=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'РАСХОЖДЕНИЕ: %s\n' "$*"; bad=1; }

say "=== 1. Каталог сборки против исходников ==="
# build.tcl запускают ИЗ build/, поэтому синтез видит ИМЕННО эти копии, а не то, что мы правили.
for f in atlas_core/video.v atlas_core/main.v atlas_core/memory.v bulbulator_zx_ddr_top.v \
         axi_ctl.v control_plane.v fb_capture_rr.v kempston_mouse.v mister48_core.sv; do
    if [ ! -f "$BUILD/$f" ]; then say "  нет в build: $f (норма, если не собирали)"; continue; fi
    if ! cmp -s "$SRC/$f" "$BUILD/$f"; then
        warn "build/$f СТАРЕЕ исходника -> синтез соберёт БЕЗ правки. Лечение: ./sources/assemble.sh"
    fi
done
[ $bad -eq 0 ] && say "  каталог сборки совпадает с исходниками"

say ""
say "=== 2. Версия ядра в исходнике (продакшн-ветка) ==="
grep -n "localparam \[31:0\] BUILD_VERSION" "$SRC/bulbulator_zx_ddr_top.v" | grep -v "^.*//" | head -4

say ""
say "=== 3. Что не закоммичено ==="
n=$(cd "$HOME/bulb-v13" && git status --short -- research/15-pentagon | wc -l)
say "  изменённых/новых файлов: $n"
[ "$n" -gt 0 ] && warn "работа не в истории: одна упавшая машина = потеря дня"

say ""
say "=== 4. Что реально в ПЛИС и в памяти платы ==="
cat > /tmp/_fresh.tcl <<'EOF'
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
puts "ЯДРО [format 0x%08X [lindex [mrd -force -value 0x43C00000] 0]]"
puts "MACHINE_CFG [format 0x%08X [lindex [mrd -force -value 0x43C000BC] 0]]"
puts "LOAD_CAPS [format 0x%08X [lindex [mrd -force -value 0x43C000C0] 0]]"
EOF
if timeout 90 "$XSDB" /tmp/_fresh.tcl 2>/dev/null | grep -E "^ЯДРО|^MACHINE_CFG|^LOAD_CAPS"; then :; else
    warn "плата недоступна (hw_server поднят? /tools/Xilinx/Vivado_Lab/2023.1/bin/hw_server -s tcp::3121)"
fi

say ""
say "=== 5. Ядра на карте против артефактов ==="
cat > /tmp/_cores.tcl <<'EOF'
connect -url tcp:localhost:3121
targets -set -filter {name =~ "*Cortex-A9*#0"}
configparams force-mem-accesses 1
proc wstr {addr str} {
  for {set i 0} {$i < [string length $str]} {incr i} {
    scan [string index $str $i] %c ch
    mwr -force -size b [expr {$addr + $i}] $ch }
  mwr -force -size b [expr {$addr + [string length $str]}] 0 }
wstr 0x0F700200 "0:/CORES"
mwr -force 0x0F700008 0
mwr -force 0x0F700004 1
for {set t 0} {$t < 30} {incr t} { after 300
  if {[expr {[lindex [mrd -force -value 0x0F700008] 0] & 0xFFFFFFFF}] != 0} break }
set s ""
for {set i 0} {$i < 4000} {incr i} {
  set b [expr {[lindex [mrd -force -size b -value [expr {0x0F700800 + $i}]] 0] & 0xFF}]
  if {$b == 0} break
  append s [format %c $b] }
puts $s
EOF
timeout 200 "$XSDB" /tmp/_cores.tcl 2>/dev/null | grep -E "BIT.BIN|BAK|\.BIN" | while IFS=$'\t' read -r nm sz rest; do
    printf '  %-24s %10s' "$nm" "$sz"
    if ls "$REPO/artifacts/ZX_CPLANE/"*.bit.bin >/dev/null 2>&1 &&
       [ -n "$(find "$REPO/artifacts/ZX_CPLANE" -name '*.bit.bin' -size "${sz}c" 2>/dev/null | head -1)" ]; then
        printf '  <- совпал с артефактом\n'
    else
        printf '  <- в артефактах такого размера НЕТ (ядро могло отстать)\n'
    fi
done

say ""
if [ $bad -eq 0 ]; then say "ИТОГ: расхождений не найдено"; else say "ИТОГ: ЕСТЬ РАСХОЖДЕНИЯ - см. выше, тесты запускать рано"; fi
exit $bad
