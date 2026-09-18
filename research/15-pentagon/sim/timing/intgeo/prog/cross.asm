; cross.asm - программа-крест для стенда tb_intgeo (собирать prog_build.sh: pasmo --bin, ORG 8000h).
; Всё в банке 2 (0x8000..0xBFFF, без контеншена): код, таблица IM2 0x9000..0x9100 = 0x91,
; обработчик по 0x9191, стек 0xBFF0. В экран пишется только маркер: (0x4000) = 0xA5 (бит 7 = 1,
; первый пиксель бумаги = чернила), атрибут (0x5800) = 0x38.
;   1) DI, бордюр 2 (красный), маркер, таблица IM2, обработчик
;   2) IM 2 (IMODE=2) или IM 1 (IMODE=1; стенд патчит ПЗУ 0x0038 -> JP 9191h плюс-аргументом ISRPATCH=9191)
;   3) A = 5, EI, HALT в цикле
;   4) обработчик: ПЕРВАЯ команда OUT (#FE),A - бордюр 5 (голубой) / 2 (красный) попеременно, XOR 7, EI, RETI
        org 8000h
IMODE   equ 2                   ; подменяется prog_build.sh
start:  di
        ld sp, 0bff0h
        ld a, 2
        out (0feh), a
        ld a, 0a5h
        ld (4000h), a
        ld a, 38h
        ld (5800h), a
        ld hl, 9000h            ; 257 байт 0x91 -> вектор всегда 0x9191
        ld de, 9001h
        ld bc, 256
        ld (hl), 91h
        ldir
        ld hl, isr
        ld de, 9191h
        ld bc, isr_end-isr
        ldir
        ld a, 90h
        ld i, a
        if IMODE = 2
        im 2
        else
        im 1
        endif
        ld a, 5
        ei
loop:   halt
        jr loop
isr:    out (0feh), a           ; 11 T: IORQ&WR с начала T2 цикла M3 (t80/RESULT.md §3)
        xor 7                   ; 5 <-> 2
        ei
        reti
isr_end:
