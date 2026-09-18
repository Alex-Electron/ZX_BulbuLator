; contrun_rd.asm - вариант (c): LD A,(HL) / INC L / DJNZ в контендуемом ОЗУ 0x6000, HL=0x4000.
        org 8000h
        di
        ld hl,body
        ld de,6000h
        ld bc,bodyend-body
        ldir
        jp 6000h
body:
        ld hl,4000h        ; 10 T
        ld b,0             ; 7 T  (256 итераций)
inner:  ld a,(hl)          ; 7 T   pc:4 hl:3
        inc l              ; 4 T
        djnz inner         ; 13/8 T (pc:4 pc+1:3 pc+1:1x5 [+5])
        jp 6000h           ; 10 T
bodyend:
