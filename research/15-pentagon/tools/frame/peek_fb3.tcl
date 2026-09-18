connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "ARM*#0"}
puts "canvas 0x0F800000: [mrd -force -value 0x0F800000 4]"
puts "canvas +0x2000:    [mrd -force -value 0x0F802000 4]"
puts "path field mbox:   [mrd -force -value 0x0F700200 4]"
puts "VERSION 0x43C00000: [mrd -force -value 0x43C00000 1]"
set h1 [mrd -force -value 0x43C000AC 1]
after 500
set h2 [mrd -force -value 0x43C000AC 1]
puts "hpw/act: $h1 -> $h2"
puts "VGEOM 0x43C00064: [mrd -force -value 0x43C00064 1]"
puts "FB0 row60 x0..: [mrd -force -value 0x0FF02D00 8]"
puts "FB0 row60 x64: [mrd -force -value 0x0FF02D20 8]"
puts "FB0 row200 x64: [mrd -force -value 0x0FF09620 8]"
puts "FSB row60 x64: [mrd -force -value 0x0F902D20 8]"
