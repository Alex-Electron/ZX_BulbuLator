; Known-duration stand.
        org 0
        di              ; 4
        ld sp,$c000     ; 10
        nop             ; 4
        ld hl,$4000     ; 10
        ld a,(hl)       ; 7
        ld (hl),a       ; 7
        out ($fe),a     ; 11
        in a,($fe)      ; 11
        ld bc,$7ffd     ; 10
        out (c),a       ; 12
        in a,(c)        ; 12
        jp l1           ; 10
        nop
l1:     ld b,3          ; 7
l2:     djnz l2         ; 13,13,8
        ld hl,$4000     ; 10
        ld de,$5000     ; 10
        ld bc,3         ; 10
        ldir            ; 21,21,16
        ld a,$28        ; 7
        inc a           ; 4
        ld a,($4000)    ; 13
        ld ($4000),a    ; 13
        push hl         ; 11
        pop hl          ; 10
        call c1         ; 17 (+ ret 10)
        ld ix,$4000     ; 14
        ld (ix+1),a     ; 19
        scf             ; 4
        jr nc,l4        ; 7 (not taken)
l4:     jr c,l5         ; 12 (taken)
l5:     ex (sp),hl      ; 19
        add a,(hl)      ; 7
        ld a,(ix+1)     ; 19
        halt            ; 4 per iteration
c1:     ret             ; 10
