; Interrupt acceptance cost stand.
; $0009 patched to $5E by the bench for IM 2; $000B patched to $76 (HALT) for the halted variant.
        org 0
        di              ; $0000
        ld sp,$c000     ; $0001
        ld a,$80        ; $0004
        ld i,a          ; $0006
        im 1            ; $0008  ED 56  (ED 5E = IM 2)
        ei              ; $000A
        nop             ; $000B  (HALT for the halted variant)
        ; $000C.. : NOP slide (zero fill) up to the IM1 handler
        org $38
        out ($fe),a     ; IM 1 handler
        jr $
        org $66
        out ($fe),a     ; NMI handler
        jr $
        org $8000
        defw $9000      ; IM 2 table: I=$80, vector byte $00 -> handler at $9000
        org $9000
        out ($fe),a     ; IM 2 handler
        jr $
