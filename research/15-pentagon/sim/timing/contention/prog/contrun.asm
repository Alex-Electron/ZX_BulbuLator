; contrun.asm - плотный цикл в КОНТЕНДУЕМОМ ОЗУ 0x6000 (копия contrun.hex Сергея Потапова,
; /tmp/ep4/simulation/modelsim/contrun.hex: LD A,(6100) / LD A,(6101) / LD (6102),A / 4 NOP / JP 6000).
; Стартует из 0x8000 (JP из ПЗУ), копирует тело цикла в 0x6000 и уходит туда навсегда (DI).
        org 8000h
        di
        ld hl,body
        ld de,6000h
        ld bc,bodyend-body
        ldir
        jp 6000h
body:
        ld a,(6100h)       ; 13 T: pc:4 pc+1:3 pc+2:3 nn:3
        ld a,(6101h)       ; 13 T
        ld (6102h),a       ; 13 T
        nop                ; 4
        nop                ; 4
        nop                ; 4
        nop                ; 4
        jp 6000h           ; 10  -> 65 T на итерацию без контеншена
bodyend:
