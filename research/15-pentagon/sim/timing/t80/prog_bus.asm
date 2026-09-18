; Bus-cycle trace stand: memory write, port write, port read.
        org 0
        di              ; $0000
        ld sp,$c000     ; $0001
        ld hl,$4000     ; $0004
        ld a,$55        ; $0007
        ld (hl),a       ; $0009  trace starts here
        out ($fe),a     ; $000A
        ld bc,$7ffd     ; $000C
        out (c),a       ; $000F
        in a,($fe)      ; $0011  bus carries master-cycle counter -> A tells which cycle was latched
        ld ($4001),a    ; $0013
        in a,(c)        ; $0016
        ld ($4002),a    ; $0018
        ld a,$aa        ; $001B
        ld ($4003),a    ; $001D
        halt            ; $0020  trace ends here
