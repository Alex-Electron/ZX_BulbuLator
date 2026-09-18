# gs_diag2.tcl - снять прибор «где карта теряет звук» (прошивка v0.15.332).
#
# Что показывает. Счётчики исполнения ключевых мест ПРОШИВКИ КАРТЫ gs105b:
#   HSEND   - карта ждёт, пока машина заберёт байт ответа. Пока она там, её главный цикл НЕ зовёт
#             ENGINE, то есть кольцо квантов (54.6 мс звука) не пополняется.
#   QTFAULT - кольцо опустело, прерывание вернулось БЕЗ EI: защёлкиваний сэмплов нет, ЦАП держит
#             последний уровень. Это и есть слышимая дыра.
#   QTPLAY  - проигрывание возобновлено (IM 1 / EI).
#
# 🥇 Само попадание в QTFAULT НОРМАЛЬНО (на хостовом стенде без опроса вовсе - 58 раз в секунду).
#    Вердикт выносится по ДЛИНЕ дыры, а не по счётчику.
#
# Как снимать A/B:
#   1) xsdb; connect; targets -set -filter {name =~ "ARM*#0"}
#   2) source gs_diag2.tcl
#   3) gs2_reset            ;# обнулить
#      ... играет ИГРА (ZYNAP), 60 секунд ...
#      gs2_read             ;# записать числа
#   4) gs2_reset
#      ... играет Z-PLAYER, тот же модуль, окно трекера открыто, 60 секунд ...
#      gs2_read
# Ожидание при подтверждении диагноза: у игры дыра max - доли миллисекунды, у плеера - единицы и
# десятки миллисекунд, а HSEND у игры около нуля.

set KMB 0x0F700000

proc gs2_rd {off} { return [lindex [mrd -force [expr {0x0F700000 + $off}]] 1] }

proc gs2_reset {} {
    mwr -force 0x0F705A88 1
    puts "счётчики обнулены (прошивка подтвердит, обнулив 0x5A88 в 0)"
}

proc gs2_read {} {
    set hsend   [expr 0x[gs2_rd 0x5A64]]
    set hget    [expr 0x[gs2_rd 0x5A68]]
    set htail   [expr 0x[gs2_rd 0x5A6C]]
    set qtf     [expr 0x[gs2_rd 0x5A70]]
    set qtp     [expr 0x[gs2_rd 0x5A74]]
    set holes   [expr 0x[gs2_rd 0x5A78]]
    set holemax [expr 0x[gs2_rd 0x5A7C]]
    set holesum [expr 0x[gs2_rd 0x5A80]]
    set smpout  [expr 0x[gs2_rd 0x5A84]]

    set sec     [expr {$smpout / 47996.0}]
    set maxms   [expr {$holemax / 47.996}]
    set summs   [expr {$holesum / 47.996}]
    set pct     [expr {$smpout > 0 ? 100.0 * $holesum / $smpout : 0.0}]
    # один оборот ожидания HSEND = 34 такта Z80 (IN 11 + OR 4 + RET P 5 + RRCA 4 + JP 10)
    set hsms    [expr {$hsend * 34.0 / 12000.0}]

    puts [format "прошло:            %.1f с (%u сэмплов ЦАП)" $sec $smpout]
    puts [format "ДЫРА самая длинная: %.1f мс      <-- главное число" $maxms]
    puts [format "дыр всего:         %u, суммарно %.0f мс = %.1f%% времени" $holes $summs $pct]
    puts [format "QTFAULT / QTPLAY:  %u / %u" $qtf $qtp]
    puts [format "HSEND:             %u оборотов = %.0f мс времени карты (%.1f%%)" $hsend $hsms \
                 [expr {$sec > 0 ? 100.0 * $hsms / ($sec * 1000.0) : 0.0}]]
    puts [format "HGET / HTAIL2:     %u / %u" $hget $htail]
}

puts "gs_diag2 загружен. Команды: gs2_reset, gs2_read"
