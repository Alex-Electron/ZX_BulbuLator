# kvm_probe.tcl - вечный опрос платы по JTAG для веб-КВМ.
#
# 🥇 ГЛАВНОЕ ПРО СКОРОСТЬ, ИЗМЕРЕНО: одно слово через JTAG стоит 17 мс, а блок 6912 байт - 119 мс.
# То есть чтение по одному регистру (их около тридцати) стоило полсекунды на проход и было ДОРОЖЕ
# самого кадра. Поэтому регистры читаются ПАКЕТАМИ в двоичные файлы, а разбирает их питон:
# четыре пакета + кадр вместо тридцати обращений.
#
# ОДНО подключение xsdb на весь сеанс: его старт стоит секунды. Файлы пишем во временные имена и
# переименовываем - веб-морда никогда не увидит недописанный кадр.
# Пауза по файлу /tmp/kvm/pause: два клиента xsdb не делят DAP, поэтому на время прошивки опрос
# отпускает канал сам (раньше приходилось убивать процесс, и у владельца пропадали кнопки).
connect -url tcp:localhost:3121
catch { targets -set -filter {name =~ "*Cortex-A9*#0"} }
catch { configparams force-mem-accesses 1 }

set D /tmp/kvm
file mkdir $D
set GP0 0x43C00000
set KMB 0x0F700000

proc kinj {code} {
    global GP0
    mwr -force [expr {$GP0+0xA8}] $code
    after 250                     ; # 120 мс не хватало: ПЗУ сканирует матрицу на 50 Гц и из четырёх
    mwr -force [expr {$GP0+0xA8}] [expr {$code | 0x100}]
    after 250                     ; # нажатий доходили два (замерено)
}

proc grab {name addr words} {
    global D
    mrd -force -bin -file $D/$name.tmp $addr $words
    file rename -force $D/$name.tmp $D/$name
}

proc poll_once {} {
    global D GP0 KMB

    # --- команды от веб-морды: ОЧЕРЕДЬ, а не одна (быстрые клики не должны затирать друг друга) ---
    if {[file exists $D/cmd]} {
        set fh [open $D/cmd r]; set body [read $fh]; close $fh
        file delete -force $D/cmd
        foreach line [split [string trim $body] "\n"] {
            set line [string trim $line]
            if {$line eq ""} continue
            if {[string match "key *" $line]} {
                kinj [expr {[lindex $line 1]}]
            } elseif {$line eq "reset"} {
                mwr -force [expr {$GP0+0x04}] 4; after 2500; mwr -force [expr {$GP0+0x04}] 0
            } elseif {[string match "poke *" $line]} {
                mwr -force [expr {[lindex $line 1]}] [expr {[lindex $line 2]}]
            }
        }
    }

    # --- экран машины: зеркало ZX, 6912 Б одним трансфером (119 мс - это и есть окно «рваности») ---
    grab scr.bin 0x40008000 1728

    # --- регистры пакетами ---
    grab r00.bin [expr {$GP0+0x000}] 4        ; # 0x00 VERSION, 0x04 CONTROL, 0x08 STATUS, 0x0C
    grab rA0.bin [expr {$GP0+0x0A0}] 8        ; # 0xA0..0xBC: 0xAC видео, 0xB8, 0xBC MACHINE_CFG
    grab r140.bin [expr {$GP0+0x140}] 16      ; # 0x140..0x17C: 0x150 MACH_DBG, 0x160 FDC, 0x170/0x174/0x17C
    grab mb.bin  [expr {$KMB+0x080}] 18       ; # мейлбокс 0x80..0xC4: вся диагностика General Sound

    set fh [open $D/ts.tmp w]; puts $fh [clock seconds]; close $fh
    file rename -force $D/ts.tmp $D/ts
}

while {1} {
    if {[file exists /tmp/kvm/pause]} {
        catch { disconnect }
        while {[file exists /tmp/kvm/pause]} { after 1000 }
        after 1000
        catch { connect -url tcp:localhost:3121 }
        catch { targets -set -filter {name =~ "*Cortex-A9*#0"} }
        catch { configparams force-mem-accesses 1 }
    }
    if {[catch { poll_once } err]} {
        catch { set fh [open $D/err.txt w]; puts $fh $err; close $fh }
        after 2000
        catch { targets -set -filter {name =~ "*Cortex-A9*#0"} }
        catch { configparams force-mem-accesses 1 }
    }
    after 150
}
