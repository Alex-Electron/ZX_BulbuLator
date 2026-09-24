# Bulbulator Step 14 (14.0 colour OSD) - Step 13 player design + a DDR-backed TRUE-COLOUR OSD layer.
#   cd build && vivado -mode batch -source build.tcl                  ;# faithful (ULA snow on)
#   cd build && vivado -mode batch -source build.tcl -tclargs nosnow  ;# no-snow variant
#
# vs Step 13 the delta: a new osd_ddr_rd.v reads an ARGB8888 OSD canvas from DDR over its OWN AXI-HP1
# port (a simplified fb_line_disp clone) and the top alpha-blends it over the 1bpp OSD output for a
# full per-pixel true-colour OSD (Winamp-style skins). axi_ctl gains OSD_DDR_BASE (0x94) + OSD_CTRL
# bit1 DDR_OSD_EN + LOAD_CAPS (0xC0, reserved). VERSION 0xB01B0019.

set NOSNOW    [expr {[lsearch -exact $argv nosnow] >= 0}]
set MISTERT80 [expr {[lsearch -exact $argv mistert80] >= 0}]
set MISTER48   [expr {[lsearch -exact $argv mister48] >= 0}]
set HYBRID     [expr {[lsearch -exact $argv hybrid] >= 0}]
if {$MISTER48 || $HYBRID} { set MISTERT80 1 }

# hdl-util/hdmi core + our thin stereo wrapper.
read_verilog -sv [glob hdmi/src/*.sv]
read_verilog -sv hdmi_wrap.sv

# Atlas core: VHDL T80, JT49, the SV SAA, then the Verilog core sources.
# The `mistert80` diagnostic target swaps ONLY the CPU RTL for the T80pa v0250
# files used by the pinned MiSTer ZX Spectrum core.  ULA, memory, ARM control
# plane and every board-facing interface remain byte-for-byte identical.  This
# gives us a clean hardware A/B before attempting the wider MiSTer ULA port.
if {$MISTERT80} {
  read_vhdl [list \
    mister_t80/T80_Pack.vhd mister_t80/T80_Reg.vhd \
    mister_t80/T80_MCode.vhd mister_t80/T80_ALU.vhd \
    mister_t80/T80.vhd mister_t80/T80pa.vhd]
} else {
  # 🥇 ФОРК ПРОЦЕССОРА, а не правка общего файла. `zx` - симлинк на cores/zx, который делят шаги
  # 06..14: правка там молча сменила бы процессор и у них. Поэтому T80.vhd лежит форком в
  # sources/t80_bulb/ (B0128: NMI за 11 тактов вместо 13), а апстримный ВЫКИНУТ из списка ПО ИМЕНИ.
  # Иначе получилась бы ровно подмена модуля, оплаченная немым SAA1099: два файла с одним именем
  # архитектуры, побеждает прочитанный позже, и лог сказал бы это только строкой [Synth 8-9873].
  # Проверка после сборки: в логе НЕТ 8-9873 на entity T80, и есть ровно один t80_bulb/T80.vhd.
  set T80_SRC {}
  foreach f [lsort [glob zx/src/T80/*.vhd]] {
    if {[file tail $f] eq "T80.vhd"} { continue }
    lappend T80_SRC $f
  }
  lappend T80_SRC t80_bulb/T80.vhd
  if {[llength $T80_SRC] != 6} {
    error "T80: ожидалось 6 файлов, получено [llength $T80_SRC] - список чтения процессора битый: $T80_SRC"
  }
  read_vhdl $T80_SRC
}
read_verilog [glob zx/src/JT49/*.v]
# B0087: НАСТОЯЩИЙ SAA1099 (Sorgelig/MiSTer по SAASound). Раньше сюда же читался zx/src/saa.v -
# ЗАГЛУШКА с тем же именем модуля (out_l=out_r=0), и она перекрывала этот файл. В логе стояло
# CRITICAL WARNING [Synth 8-9873] overwriting previous definition of module 'saa1099', и в
# битстрим уходил НЕМОЙ чип - молчала вся SAA-музыка (E-TUNES 7 и прочие рипы с SAM Coupe).
# saa.v из списка чтения убран. НЕ добавлять обратно.
read_verilog -sv zx/src/saa1099.sv
read_verilog [list \
  atlas_core/main.v zx/src/cpu.v atlas_core/video.v turbosound_bulb.v \
  zx/src/specdrum.v zx/src/audio.v zx/src/dprs.v zx/src/dsg.v \
  atlas_core/memory.v zx/src/keyboard.v atlas_core/ps2.v usd_bulb.v zx/src/spi.v \
  beta_disk.v \
  nemo_ide.v kempston_mouse.v divmmc_card.v]
# B0075 дисковод: наш экземпляр WD1793 (объявления вынесены из generate - иначе Vivado не собирает)
read_verilog -sv wd1793.sv
if {$MISTER48 || $HYBRID} {
  read_verilog -sv [list mister48/ula.sv mister48_core.sv hybrid_zx_core.sv]
}

# EBAZ glue + control plane + DDR chain (line-buffer display) + OSD compositor + DDR-RGB OSD + the top.
read_verilog [list clock_zx.v mem_zx_bulb.v kbd_buttons.v \
  axi_ctl.v inject_cdc.v \
  fb_capture_rr.v async_fifo.v gs_wq_fifo.v gs_flow.v fb_wr_axi.v fb_bufmgr5.v fb_line_disp.v osd_compositor.v \
  osd_ddr_rd.v tape_bram_fifo.v tape_player.v ps2_tx.v \
  ddr_probe.v ddr_mem.v control_plane.v bdi_activity_icon.v bulbulator_zx_ddr_top.v]
read_xdc bulbulator_ddr.xdc

if {$HYBRID} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define HYBRID_CORE
  set BIT bulbulator_zx_loader_hybrid.bit
} elseif {$MISTER48} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define MISTER48_CORE
  set BIT bulbulator_zx_loader_mister48.bit
} elseif {$NOSNOW && $MISTERT80} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define {NO_SNOW MISTER_T80_AB}
  set BIT bulbulator_zx_loader_mistert80_nosnow.bit
} elseif {$NOSNOW} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define NO_SNOW
  set BIT bulbulator_zx_loader_nosnow.bit
} elseif {$MISTERT80} {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1 -verilog_define MISTER_T80_AB
  set BIT bulbulator_zx_loader_mistert80.bit
} else {
  synth_design -top bulbulator_zx_ddr_top -part xc7z010clg400-1
  set BIT bulbulator_zx_loader.bit
}
puts ">>> ==== UTIL after synth (xc7z010: 17600 LUT, 35200 FF, 60 BRAM, 80 DSP) ===="
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {Slice LUTs|Slice Registers|Block RAM Tile|DSPs|BUFG|MMCM} $line]} { puts $line }
}
# B0089: дизайн подошёл к потолку разводки (87 % LUT), и на дефолтных директивах пиксельный тракт
# OSD стал давать WNS -0.157 нс - падает РАЗВОДКА (9.8 нс из 13.2), а не логика. Усиленные проходы -
# штатный способ дожать краевой дизайн. Стратегический выход другой: перенести буферы оболочки из
# LUTRAM в BRAM (~2.3k LUT) - он же нужен под TurboSound-FM.
opt_design
# B0114: пограничный путь пиксельного домена (osd_i/pos_q -> rgb24_osd, 13 уровней логики,
# три четверти задержки - трассировка) при Explore не закрылся (WNS -0.411). Логика та же,
# размещение другое.
# 🥇 B0122 ЛЕСЕНКА ДИРЕКТИВ РАЗМЕЩЕНИЯ. На 91 % LUT и BRAM 60/60 размещение иногда не сходится
# вообще («ERROR: [Place 30-99] Placer failed with error: failed to commit all instances»), и это
# НЕ лотерея: повтор того же прогона даёт тот же отказ байт-в-байт (B0122, два прогона, 16029 LUT).
# Значит нужен другой раскладчик, а не другая попытка. Порядок: сначала проверенная временем
# ExtraTimingOpt (на ней закрывались B0114..B0121), потом две директивы, специально сделанные под
# перегруженный кристалл — они разгоняют логику по площади ценой тайминга.
# ПОЛНАЯ ЗАГРУЗКА МАШИНЫ. У ThinkPad 16 ядер, а Vivado по умолчанию берёт 8 - на сборках по
# 35-40 минут это заметная разница. Размещение и трассировку сам инструмент всё равно ограничивает
# восемью потоками, зато синтез и DRC масштабируются. Каждый параметр в catch: набор имён зависит от
# версии, и отсутствующий параметр не должен ронять сборку.
foreach {p v} {general.maxThreads 16 synth.maxThreads 8 place.maxThreads 8
               route.maxThreads 8 phys.maxThreads 8 drc.maxThreads 8 bitgen.maxThreads 8} {
    if {[catch {set_param $p $v} e]} { puts ">>> параметр $p не принят: $e" }
}
puts ">>> потоков: general.maxThreads = [get_param general.maxThreads]"

# 🥇 ПОРЯДОК ВАЖЕН: лесенка берёт первую директиву, которая РАЗЛОЖИЛА, а не ту, что закрывает
# тайминг. На этой схеме ExtraTimingOpt даёт WNS +0.095 (B0125), а Explore на том же нетлисте
# раскладывает успешно, но выдаёт -0.421 (B0126, правка в две константы). Поэтому проверенная
# временем ExtraTimingOpt идёт ПЕРВОЙ, остальные - только как спасение от «не разложилось вовсе».
set PLACE_DIRS {ExtraTimingOpt Explore AltSpreadLogic_high SpreadLogic_high}
set placed 0
foreach dir $PLACE_DIRS {
    puts ">>> ==== PLACE попытка: -directive $dir ===="
    if {![catch {place_design -directive $dir} perr]} { set placed 1; set PLACE_USED $dir; break }
    puts ">>> размещение с $dir не сошлось:"
    puts ">>>   $perr"
}
if {!$placed} { puts ">>> ВСЕ ДИРЕКТИВЫ РАЗМЕЩЕНИЯ ОТКАЗАЛИ - логику надо резать, а не пересобирать"; exit 1 }
puts ">>> ==== РАЗМЕЩЕНО директивой $PLACE_USED ===="
phys_opt_design -directive Explore
# B0115 (прогон Б): setup промахнулся на 24 пс на ОДНОМ пути пиксельного домена
# (shell/osd_i/pos_q -> od_r, 13 уровней, 9.5 нс из 13.1 - ТРАССИРОВКА). Размещение оставляем
# (один нарушенный конец из 49658), меняем ТОЛЬКО маршрутизатор: NoTimingRelaxation запрещает
# ему ослаблять требования при неудаче схождения - ровно наш случай на 24 пс.
# Прогон А (route AggressiveExplore + лишний проход phys_opt) сделал ХУЖЕ: -0.080, 2 пути.
route_design -directive NoTimingRelaxation
# 🥇 B0121 КОНТРОЛЬНАЯ ТОЧКА СРАЗУ ПОСЛЕ ТРАССИРОВКИ - СТРАХОВКА ОТ ПОЛИРОВКИ.
# Разводка здесь ПОЛНАЯ и легальная. Всё, что идёт ниже - только полировка тайминга, и она имеет
# право сделать хуже: post-route phys_opt переставляет ячейки уже по разведённому дизайну и иногда
# оставляет физические связи `VCC -> SLICE.CLK` недотрассированными. Битстрим на этом падает
# (DRC RTSTAT-9: Partially routed physical-only nets ... GLOBAL_LOGIC1), а починить такую связь
# `route_design -physical_nets` НЕ МОЖЕТ по построению: тактовый вход нельзя вести по сети VCC
# (проверено 12.08: «Unroutable connection Type 1: Vcc Source->SLICEL.CLK, Num Open nets: 4»).
# Потерянные 35 минут сборки того не стоят - держим точку отката.
write_checkpoint -force bulbulator_zx_loader_routed_prephys.dcp
phys_opt_design -directive AggressiveExplore
puts ">>> ==== CLOCKS (must list fclk100 + 3 derived + clk_audio; empty = the old unconstrained lottery) ===="
puts [report_clocks -return_string]
puts ">>> ==== CHECK_TIMING no_clock (must be 0 unconstrained endpoints) ===="
puts [check_timing -override_defaults no_clock -return_string]
puts ">>> ==== TIMING ===="
puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 4]
puts ">>> ==== HOLD TIMING (required for negedge-to-posedge ZX enable analysis) ===="
puts [report_timing_summary -no_header -return_string -delay_type min -max_paths 20]
write_checkpoint -force bulbulator_zx_loader_routed.dcp
# B0121: если полировка испортила физические цепи - молча откатываемся на разводку до неё.
# Полировка это ТОЛЬКО тайминг, а он и до неё сходился; собранный битстрим важнее лишних пикосекунд.
if {[catch {write_bitstream -force $BIT} err]} {
    puts ">>> ПОЛИРОВКА ИСПОРТИЛА РАЗВОДКУ, битстрим не записался:"
    puts ">>>   $err"
    puts ">>> откат на контрольную точку сразу после трассировки"
    close_design
    open_checkpoint bulbulator_zx_loader_routed_prephys.dcp
    puts ">>> ==== ТАЙМИНГ ПОСЛЕ ОТКАТА ===="
    puts [report_timing_summary -no_header -return_string -delay_type max -max_paths 4]
    write_bitstream -force $BIT
}
puts ">>> DONE bit=$BIT size=[file size $BIT]"
