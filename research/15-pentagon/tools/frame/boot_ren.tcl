connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "ARM*#0"}
proc rd {a} { return [lindex [mrd -force -value $a] 0] }
proc wstr {a s} { set i 0; foreach c [split $s ""] { mwr -force -size b [expr {$a+$i}] [scan $c %c]; incr i }; mwr -force -size b [expr {$a+$i}] 0 }
proc cmdwait {c} { mwr -force 0x0F70000C 0; mwr -force 0x0F700008 0; mwr -force 0x0F700004 $c; for {set t 0} {$t < 300} {incr t} { after 100; if {[rd 0x0F700008] != 0} break }; return [list [rd 0x0F700008] [rd 0x0F70000C]] }
proc ren {a b} { wstr 0x0F700200 $a; wstr 0x0F700400 $b; set r [cmdwait 4]; puts "RENAME $a -> $b : done/err = $r" }
ren "0:/BOOT.BIN" "0:/BOOTV435.BAK"
ren "0:/BOOTTMP.BIN" "0:/BOOT.BIN"
wstr 0x0F700200 "0:/"; set r [cmdwait 1]; mrd -force -bin -file /tmp/list.bin 0x0F700800 8192
set f [open /tmp/list.bin rb]; set d [read $f]; close $f
foreach l [split [string map {"\0" "\n"} $d] "\n"] { if {[string match *BOOT* $l]} { puts "LIST: $l" } }
