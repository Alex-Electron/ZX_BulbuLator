; СГЕНЕРИРОВАНО fbus_gen.py - не править руками
KMAX equ 48
PPAD equ 56

        org ($ + 255) and 0ff00h   ; таблица переходов в одной странице (inc l без переноса)
jtab:
        dw stub_0
        dw stub_1
        dw stub_2
        dw stub_3
        dw stub_4
        dw stub_5
        dw stub_6
        dw stub_7
        dw stub_8
        dw stub_9
        dw stub_10
        dw stub_11
        dw stub_12
        dw stub_13
        dw stub_14
        dw stub_15
        dw stub_16
        dw stub_17
        dw stub_18
        dw stub_19
        dw stub_20
        dw stub_21
        dw stub_22
        dw stub_23
        dw stub_24
        dw stub_25
        dw stub_26
        dw stub_27
        dw stub_28
        dw stub_29
        dw stub_30
        dw stub_31
        dw stub_32
        dw stub_33
        dw stub_34
        dw stub_35
        dw stub_36
        dw stub_37
        dw stub_38
        dw stub_39
        dw stub_40
        dw stub_41
        dw stub_42
        dw stub_43
        dw stub_44
        dw stub_45
        dw stub_46
        dw stub_47

stub_0:
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_1:
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_2:
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_3:
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_4:
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_5:
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_6:
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_7:
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_8:
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_9:
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_10:
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_11:
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_12:
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_13:
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_14:
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_15:
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_16:
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_17:
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_18:
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_19:
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_20:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_21:
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_22:
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_23:
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_24:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_25:
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_26:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_27:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_28:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_29:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_30:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        inc de
        ret
stub_31:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        ld r,a
        ret
stub_32:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        nop
        ret
stub_33:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        ld e,0
        ret
stub_34:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        inc de
        ret
stub_35:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        ld r,a
        ret
stub_36:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        nop
        ret
stub_37:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        ld e,0
        ret
stub_38:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        inc de
        ret
stub_39:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        ld r,a
        ret
stub_40:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        nop
        ret
stub_41:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        ld e,0
        ret
stub_42:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        inc de
        ret
stub_43:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        ld r,a
        ret
stub_44:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        nop
        nop
        ret
stub_45:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld a,i
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        ld e,0
        ret
stub_46:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        inc de
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        nop
        inc de
        ret
stub_47:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        ld e,0
        if MODE = 0
        ld a,PORTHI
        in a,(PORTLO)
        else
        ld bc,PORTHI*256+PORTLO
        in a,(c)
        endif
        ld r,a
        ret
