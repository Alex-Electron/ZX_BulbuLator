; ports.asm - чтение портов #FE, #FFFD, #BFFD, #7FFD в нижнем бордюре (пункты b, c задания).
; Сначала ~45 000 T ожидания (растр уходит на строки ~200 = нижний бордюр), затем серия IN с записью
; результатов в 0x8000.. (стенд печатает каждый IN монитором IOMON и дампит таблицу).
;   8000: IN A,(#FE) при A=#FF (все полуряды), OUT #FE бит4 = 0
;   8001: то же после OUT #FE с битом 4 = 1 (speaker)
;   8002: IN A,(#FE) при A=#FE (полуряд CS..V), бит4 = 0
;   8003: IN (#FFFD) после выбора регистра 7 и записи #3F через #BFFD    (ожидание: #3F)
;   8004: IN (#BFFD)                                                       (на 128K: плавающая шина)
;   8005: IN (#7FFD)                                                       (плавающая шина)
;   8006: IN (#FFFD) регистр 1 после записи #FF                            (настоящий AY: #0F)
;   8007: IN (#FFFD) регистр 6 после записи #FF                            (настоящий AY: #1F)
;   8008: IN (#FFFD) регистр 14 (порт A, вход не подключён)
;   8009: IN (#FFFD) после OUT #FFFD,#1F (адрес с ненулевыми битами 7:4 - AY его не защёлкивает,
;         остаётся регистр 14 -> ожидание = байт 8008)
;   800A: IN A,(#FF) в бордюре, A=#FF                                      (ожидание: #FF)
;   800B: IN A,(#BF) в бордюре, A=#FF                                      (ожидание: #FF)
;   800C: IN A,(#FE) при A=#FF, бит4 = 0, после серии (контроль)
        org 9000h
start:  di
        ld sp,8ff0h
        xor a
        out (0feh),a         ; бордюр чёрный, speaker=0, mic=0
        ld bc,1900
w0:     dec bc
        ld a,b
        or c
        jp nz,w0             ; 24 T * 1900 = 45 600 T -> строки ~203 (48K) / ~200 (128K)
        ld a,0ffh
        in a,(0feh)
        ld (8000h),a
        ld a,10h
        out (0feh),a         ; бит 4 = 1
        ld a,0ffh
        in a,(0feh)
        ld (8001h),a
        xor a
        out (0feh),a
        ld a,0feh
        in a,(0feh)
        ld (8002h),a
        ld bc,0fffdh
        ld a,7
        out (c),a
        ld b,0bfh
        ld a,3fh
        out (c),a
        ld b,0ffh
        in a,(c)
        ld (8003h),a
        ld b,0bfh
        in a,(c)
        ld (8004h),a
        ld b,7fh
        in a,(c)
        ld (8005h),a
        ld bc,0fffdh
        ld a,1
        out (c),a
        ld b,0bfh
        ld a,0ffh
        out (c),a
        ld b,0ffh
        in a,(c)
        ld (8006h),a
        ld bc,0fffdh
        ld a,6
        out (c),a
        ld b,0bfh
        ld a,0ffh
        out (c),a
        ld b,0ffh
        in a,(c)
        ld (8007h),a
        ld bc,0fffdh
        ld a,14
        out (c),a
        in a,(c)
        ld (8008h),a
        ld a,1fh
        out (c),a
        in a,(c)
        ld (8009h),a
        ld a,0ffh
        in a,(0ffh)
        ld (800ah),a
        ld a,0ffh
        in a,(0bfh)
        ld (800bh),a
        ld a,0ffh
        in a,(0feh)
        ld (800ch),a
        ld a,1
        out (0feh),a         ; бордюр синий = серия закончена
done:   jr done
