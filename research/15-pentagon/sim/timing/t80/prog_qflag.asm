; Q-flag stand: what SCF/CCF do to XF/YF (bits 3 and 5 of F).
; Same two cases as ep4spectrum tb_qflag.v (A and B), plus extra cases.
; Results go to ports $01..$07 as OUT (n),A.
        org 0
        di
        ld sp,$c000
; case A: F=$28 A=$00 via POP AF (no flag computation), then SCF. Zilog -> $29, "XY from A" -> $01
        ld hl,$0028
        push hl
        pop af
        scf
        push af
        pop bc
        ld a,c
        out ($01),a
; case B: F=$00 A=$28 via POP AF, then SCF. Zilog -> $29, "XY from A" -> $29
        ld hl,$2800
        push hl
        pop af
        scf
        push af
        pop bc
        ld a,c
        out ($02),a
; case C: flags computed by CP directly before SCF (Zilog Q=F), A=0, XY come from operand $28.
;         Zilog -> XY=(Q^F)|A = 0 ; "F|A without Q" -> keeps XY ; "XY from A" -> 0
        ld a,0
        ld b,$28
        cp b
        scf
        push af
        pop bc
        ld a,c
        out ($03),a
; case C0: same CP, F BEFORE SCF (reference)
        ld a,0
        ld b,$28
        cp b
        push af
        pop bc
        ld a,c
        out ($04),a
; case A': F=$28 A=$00 via POP AF, then CCF. Zilog -> $29, "XY from A" -> $01
        ld hl,$0028
        push hl
        pop af
        ccf
        push af
        pop bc
        ld a,c
        out ($05),a
; case B': F=$00 A=$28 via POP AF, then CCF. Zilog -> $29, "XY from A" -> $29
        ld hl,$2800
        push hl
        pop af
        ccf
        push af
        pop bc
        ld a,c
        out ($06),a
; case D: F=$29 (X,Y,C) A=$00 via POP AF, then CCF. C->0, H<-old C=1. Zilog -> $38, "XY from A" -> $10
        ld hl,$0029
        push hl
        pop af
        ccf
        push af
        pop bc
        ld a,c
        out ($07),a
        halt
