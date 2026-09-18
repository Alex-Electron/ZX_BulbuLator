; im2sweep.asm - каркас для свипа контеншена. Живёт в НЕконтендуемом ОЗУ (0x8000, банк 2).
; Обработчик IM2 по 0x8383 стенд tb_cont.sv СОБИРАЕТ САМ (паддинг + измеряемая команда),
; здесь только каркас: таблица векторов 0x8100..0x8200 = 0x83, EI, HALT-цикл по 0x8360,
; компенсация фазы решётки HALT по 0x8370 (пишет стенд: 0..2 байта + JP 8360h).
; Патчи стенда: org+2/3 = HL, org+6/7 = IX, org+9 = байт в 7FFD (HLV/IXV/P7FFD).
        org 8000h
start:  di
        ld hl,4000h        ; org+1: 21 lo hi  -> указатель на контендуемую память
        ld ix,4000h        ; org+4: DD 21 lo hi
        ld a,0             ; org+8: 3E nn     -> байт для 7FFD (128K: банк в 0xC000)
        ld bc,7ffdh
        out (c),a
        ld sp,0BFF0h
        ld a,81h
        ld i,a
        im 2
        push hl
        ld hl,8100h
        ld de,8101h
        ld bc,0100h
        ld (hl),83h
        ldir
        pop hl
        ld de,0
        ei
        jp loop
        org 8360h
loop:   halt               ; 8360
        jp 8370h           ; 8361 -> компенсация стенда -> JP 8360h
