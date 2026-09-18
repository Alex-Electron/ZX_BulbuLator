; ports_fb.asm - по восемь чтений подряд каждого порта В БУМАГЕ (строки ~100..103), чтобы попасть во
; все 8 фаз узора плавающей шины: шаг между чтениями = in a,(c) 12 + ld (hl),a 7 + inc l 4 = 23 T
; (23 mod 8 = 7 -> фазы 0,7,6,5,4,3,2,1). Результаты:
;   8000..8007: IN (#BFFD)   8010..8017: IN (#7FFD)   8020..8027: IN (#FFFD), выбран R7 = #3F
;   8030..8037: IN A,(#FF) A=#FF (in a,(n) 11 + ld (hl),a 7 + inc l 4 = 22 T, 22 mod 8 = 6 -> 4 фазы)
;   8040..8047: IN A,(#BF) A=#FF   8050..8057: IN A,(#FE) A=#FF
;   8060: IN (#FFFD) после OUT #FFFD,#01 и OUT #FFFD,#17 (адрес со старшим полубайтом 1):
;         настоящий AY адрес #17 НЕ защёлкивает -> остаётся R1 = #0F; если маскирует до 4 бит -> R7 = #3F
        org 9000h
start:  di
        ld sp,8ff0h
        xor a
        out (0feh),a
        ld bc,0fffdh
        ld a,7
        out (c),a
        ld b,0bfh
        ld a,3fh
        out (c),a            ; R7 = #3F
        ld bc,1500
w0:     dec bc
        ld a,b
        or c
        jp nz,w0             ; 24 T * 1500 = 36 000 T -> строка ~97 (48K)
        ld hl,8000h
        ld bc,0bffdh
        rept 8
        in a,(c)
        ld (hl),a
        inc l
        endm
        ld l,10h
        ld b,7fh
        rept 8
        in a,(c)
        ld (hl),a
        inc l
        endm
        ld l,20h
        ld b,0ffh
        rept 8
        in a,(c)
        ld (hl),a
        inc l
        endm
        ld l,30h
        rept 8
        ld a,0ffh
        in a,(0ffh)
        ld (hl),a
        inc l
        endm
        ld l,40h
        rept 8
        ld a,0ffh
        in a,(0bfh)
        ld (hl),a
        inc l
        endm
        ld l,50h
        rept 8
        ld a,0ffh
        in a,(0feh)
        ld (hl),a
        inc l
        endm
        ld bc,0fffdh
        ld a,1
        out (c),a
        ld a,17h
        out (c),a
        in a,(c)
        ld (8060h),a
        ld a,1
        out (0feh),a         ; бордюр синий = серия закончена
done:   jr done
