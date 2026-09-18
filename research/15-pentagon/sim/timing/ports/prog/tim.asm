; tim.asm - микротест длительности команд T80 (форк t80_bulb) в неконтендящемся ОЗУ 0x9000.
; Каждая измеряемая команда обрамлена NOP; стенд печатает все циклы шины (BUSALL=1), длительность
; команды = разность меток времени соседних выборок M1 / 282352.94 пс (16 тактов мастера = 1 T).
; Ожидание по документации Z80 указано в комментариях.
        org 9000h
start:  di                  ; 4
        ld sp,8ff0h         ; 10
        nop                 ; 4
        nop                 ; 4
        ld a,i              ; 9
        nop
        inc de              ; 6
        nop
        ld e,0              ; 7
        nop
        ld r,a              ; 9
        nop
        ld a,0ffh           ; 7
        in a,(0ffh)         ; 11
        nop
        ld bc,0fffdh        ; 10
        in a,(c)            ; 12
        nop
        ld a,(8000h)        ; 13
        nop
        cp 5                ; 7
        nop
        call subr           ; 17 (+ret 10)
        nop
        ld hl,sub2          ; 10
        jp (hl)             ; 4
sub2:   nop
        ld l,(hl)           ; 7
        nop
        ld (hl),a           ; 7
        nop
        ld hl,8100h
        inc (hl)            ; 11
        nop
        set 7,l             ; 8
        nop
        ld b,3              ; 7
dj:     djnz dj             ; 13,13,8
        nop
        jr nxt              ; 12
nxt:    nop
        jp nz,nxt2          ; 10
nxt2:   nop
        ld bc,2
        dec bc              ; 6
        ld a,b              ; 4
        or c                ; 4
        nop
        out (0feh),a        ; 11
        nop
        ld a,(hl)           ; 7
        nop
        ex (sp),hl          ; 19
        nop
        ld a,(bc)           ; 7
        nop
        add a,0             ; 7
        nop
        ld (8001h),a        ; 13
        nop
        ld hl,(8000h)       ; 16
        nop
        ei                  ; 4
        halt                ; 4 (потом NOP-ы по 4)
subr:    nop
        ret                 ; 10
