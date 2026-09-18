; fbus.asm - свип плавающей шины: после каждого прерывания обработчик ждёт W1 (до первой строки
; бумаги), потом ровно (8+k) T, читает порт, кладёт результат в 0x8000+k; затем ждёт W2 (до строки
; ~100), снова (8+k) T, читает порт, кладёт в 0x8080+k; k++ раз в кадр. Экран заполняет стенд
; (SCRFILL=1). Код в неконтендящемся банке 2 (0x9000), стек 0x8FF0, таблица IM2 0x9F00..0xA000 = 0x9E
; -> обработчик по 0x9E9E. Значения задаются при сборке (pasmo --equ): PORTHI/PORTLO, MODE
; (0: LD A,PORTHI : IN A,(PORTLO); 1: LD BC : IN A,(C)), W1/W1F4/W1F1 и W2/W2F4/W2F1 - грубая
; (24 T/итерация) и тонкая (4 T на nop, 9 T на ld r,a) части ожидания. Собирать prog/build.sh.
; Тактовый бюджет постоянен для всех k (см. fbus_gen.py) и добит PADT до кратного 4 T (без учёта
; циклов по 24 T: 533 + 9*(W1F1+W2F1) + PADT-такты), поэтому фаза приёма INT из HALT одна на все
; кадры; момент защёлки данных измеряет стенд (IOMON), k - только номер кадра/ячейки.
kvar    equ 80feh            ; страница 0x80 обязательна: ld l,(hl) даёт адрес 0x8000+k
frames  equ 80ffh
        org 9000h
start:  di
        ld sp,8ff0h
        ld a,BORDER
        out (0feh),a
        ld hl,9f00h          ; таблица IM2: 257 байт 0x9E
        ld de,9f01h
        ld bc,256
        ld (hl),9eh
        ldir
        ld a,9fh
        ld i,a
        im 2
        ei
loop:   halt
        jr loop

dispatch:                    ; A = k -> jp stub_k (41 T до входа в заглушку)
        add a,a
        ld l,a
        ld h,jtab/256
        ld a,(hl)
        inc l
        ld h,(hl)
        ld l,a
        jp (hl)

isr_main:
        ld a,(kvar)
        cp KMAX
        jp nc,isr_done
        ld bc,W1
d1:     dec bc
        ld a,b
        or c
        jp nz,d1
        if W1F4 > 0
        rept W1F4
        nop
        endm
        endif
        if W1F1 > 0
        rept W1F1
        ld r,a
        endm
        endif
        ld a,(kvar)
        call dispatch
        ld hl,kvar
        ld l,(hl)
        ld (hl),a            ; 0x8000+k
        ld hl,W2
d2:     dec hl
        ld a,h
        or l
        jp nz,d2
        if W2F4 > 0
        rept W2F4
        nop
        endm
        endif
        if W2F1 > 0
        rept W2F1
        ld r,a
        endm
        endif
        ld a,(kvar)
        call dispatch
        ld hl,kvar
        ld l,(hl)
        set 7,l
        ld (hl),a            ; 0x8080+k
        ld hl,kvar
        inc (hl)
        ; PADT: добивка длины обработчика до кратного 4 T. Без неё сетка HALT (4 T) уезжает
        ; относительно /INT на (длина mod 4) T каждый кадр, и защёлка k-го кадра ложится на
        ; 2 T за шаг с заворотом раз в 4 кадра (оплачено калибровкой cal48: 533 T = 1 mod 4).
        if PADT = 1
        ld r,a               ; 9 T
        endif
        if PADT = 2
        inc de               ; 6 T
        endif
        if PADT = 3
        ld e,0               ; 7 T
        endif
isr_done:
        ld hl,frames
        inc (hl)
        ei
        reti

        include "fbus_stubs.inc"

        org 9e9eh
isr:    jp isr_main
        ; 9f00..a000 - таблица IM2, заполняется кодом (в бинарнике до 0x9EA1)
