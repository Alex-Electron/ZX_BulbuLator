# Бронепоезд: заливка битстрима в DDR с верификацией + конфигурация PL через PCAP (DevC)
connect -url tcp:localhost:3121
configparams force-mem-accesses 1
# Системный сброс: после SD-boot ядро крутит заглушку с MMU, а её код/таблицы
# затёрты прошлой заливкой. Сброс возвращает MMU off; стопим ядра раньше,
# чем BootROM успеет загрузить FSBL с карты.
targets -set -filter {name =~ "APU*"}
catch {rst -system}
after 50
targets -set -filter {name =~ "*Cortex-A9*#1"}
catch {stop}
targets -set -filter {name =~ "*Cortex-A9*#0"}
catch {stop}
after 200
cd /home/lavrinovich/hdmi720pl
source ps7_init_fclk.tcl
ps7_init
puts ">>> PS7_INIT DONE (PLL+DDR подняты)"

set BIN  /home/lavrinovich/zx48/zx48.bit.bin
if {[info exists ::env(PCAP_BIN)]} { set BIN $::env(PCAP_BIN) }
file delete -force /tmp/rb.bin
set ADDR 0x00100000
set size  [file size $BIN]
set words [expr {$size / 4}]
puts ">>> Заливаю $size байт в DDR @$ADDR"

set ok 0
for {set pass 1} {$pass <= 5} {incr pass} {
  puts ">>> Заливка+верификация, проход $pass"
  dow -data $BIN $ADDR
  mrd -bin -file /tmp/rb.bin $ADDR $words
  set f1 [open $BIN rb];      set d1 [read $f1]; close $f1
  set f2 [open /tmp/rb.bin rb]; set d2 [read $f2]; close $f2
  if {[string equal $d1 $d2]} { puts ">>> ВЕРИФИКАЦИЯ DDR OK (проход $pass)"; set ok 1; break }
  set n [string length $d1]; set diffs 0
  for {set i 0} {$i < $n} {incr i 4096} {
    if {![string equal [string range $d1 $i [expr {$i+4095}]] [string range $d2 $i [expr {$i+4095}]]]} { incr diffs }
  }
  puts ">>> Расхождение в $diffs блоках по 4К — повтор"
}
if {!$ok} { puts ">>> DDR_FAIL: заливка не сошлась за 5 проходов"; exit 1 }

proc r32 {a} { return [lindex [mrd -value $a] 0] }
# DevC: unlock, выключить loopback, включить PCAP_PR|PCAP_MODE
mwr 0xF8007034 0x757BDF0D
mwr 0xF8007080 [expr {[r32 0xF8007080] & ~0x10}]
set ctrl [expr {[r32 0xF8007000] | 0x0C000000}]
mwr 0xF8007000 $ctrl
# Цикл PROG_B: очистить PL
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
mwr 0xF8007000 [expr {$ctrl & ~0x40000000}]
set t 0
while {([r32 0xF8007014] & 0x10) != 0} { incr t; if {$t > 2000} { puts ">>> FAIL: INIT не упал"; exit 1 } }
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
set t 0
while {([r32 0xF8007014] & 0x10) == 0} { incr t; if {$t > 2000} { puts ">>> FAIL: INIT не поднялся"; exit 1 } }
puts ">>> PROG_B-цикл пройден, PL очищена, INIT=1"
# DMA через PCAP
mwr 0xF800700C 0xFFFFFFFF
mwr 0xF8007018 [expr {$ADDR | 1}]
mwr 0xF800701C 0xFFFFFFFF
mwr 0xF8007020 $words
mwr 0xF8007024 0
puts ">>> PCAP DMA запущен ($words слов)"
set t 0
while {([r32 0xF800700C] & 0x2000) == 0} { incr t; if {$t > 30000} { puts ">>> FAIL: DMA timeout, INT_STS=[format 0x%08X [r32 0xF800700C]]"; exit 1 } }
puts ">>> DMA DONE"
set t 0
while {([r32 0xF800700C] & 0x4) == 0} { incr t; if {$t > 30000} { puts ">>> FAIL: PCFG_DONE timeout, INT_STS=[format 0x%08X [r32 0xF800700C]]"; exit 1 } }
puts ">>> PCFG_DONE=1: ПЛИС СКОНФИГУРИРОВАНА ЧЕРЕЗ PCAP!"
ps7_post_config
puts ">>> POST_CONFIG DONE — Спектрум должен быть на экране"
