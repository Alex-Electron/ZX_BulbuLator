; intlat - такты от фронта /INT до подтверждения прерывания и до первого OUT, процессор в HALT.
; PAD (0..3 NOP) сдвигает фазу входа в HALT = развёртка по 4-тактовой сетке приёма.
; IM2: I=0C3h, таблица 0C300h..0C401h = 0C5h -> вектор 0C3FFh -> обработчик 0C5C5h.
        org  0C000h
start:  di
        ld   sp,0BF00h
        ld   a,0C3h
        ld   i,a
        im   2
        ei
        if PAD > 0
        nop
        endif
        if PAD > 1
        nop
        endif
        if PAD > 2
        nop
        endif
        halt
        ld   a,2
        out  (0FEh),a          ; маркер 1: первый OUT после пробуждения
        ld   a,7
        out  (0FEh),a          ; маркер 2
        di
loop:   jr   loop

        org  0C300h
        defs 0C402h-0C300h, 0C5h

        org  0C5C5h
handler:
        ei
        ret
