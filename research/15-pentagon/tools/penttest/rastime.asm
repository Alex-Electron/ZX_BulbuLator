; rastime.asm - растровые тесты для снимков кадра с хоста: stime и btime Яна Бобровского (zxtests, GPL),
; которые САМИ перебирают такт T. На каждое T - блок из KFR кадров: выравнивание по INT (ALIGNINT), затем
; тело кадра ДОСЛОВНО как у оригинала, поэтому T значит ровно то же, что в stime/btime:
;   stime (USR 32768): в кадре пишется #00 в 16384, а на такте T (начало машинного цикла записи) - #FF.
;                      Клетка (0,0) - красные чернила на жёлтой бумаге: красные 8 точек = запись успела.
;   btime (USR 32771): на такте T (начало цикла OUT) бордюр становится красным, через 12 T - белым.
; Текущее T рисуется двоичной полоской в строках знакомест 22 и 1 (столбцы 0..15, младший бит слева), столбец 16 -
; метка «всегда чёрный», столбец 17 (только верхняя линия) - «кадр измерительный»: его ставит тело кадра,
; а снимают между блоками, поэтому переходные кадры хост отбрасывает. Разбор - rastime.py.
; Добавки к телу кадра (метка 20 T + счётчик 28 T) кратны 4 тактам: фаза входа в HALT остаётся как у оригинала.
; Выход - любая клавиша.

	org 32768

	jp STIME		; 32768
	jp BTIME		; 32771
T0S	dw 17970		; 32774 первое T для stime
NS	db 32			; 32776 сколько значений
T0B	dw 17740		; 32777 первое T для btime
NBT	db 48			; 32779

KFR	equ 16
BAR	equ 50C0h		; строка знакомест 22, линия 0, столбец 0
VALID	equ 50D1h		; столбец 17, линия 0
BART	equ 4020h		; копия полоски: строка знакомест 1

STIME:	ld a,1
	out (0FEh),a		; бордюр синий: бумага отличима от бордюра
	ld a,38h
	call SETUP
	ld a,32h		; клетка (0,0): бумага 6 жёлтая, чернила 2 красные
	ld (5800h),a
	ld hl,(T0S)
	ld a,(NS)
	ld b,0
	jr RUN
BTIME:	ld a,7
	out (0FEh),a		; бордюр белый, красная полоска на нём
	ld a,30h		; бумага жёлтая: отличима от белого бордюра
	call SETUP
	ld hl,(T0B)
	ld a,(NBT)
	ld b,1
RUN:	ld (TBEG),hl
	ld (TN),a
	ld a,b
	ld (MODE),a
	xor a
	ld (TI),a
	call INSTINT
	call FRAME_TIME
	call SWEEP
	ld a,3Fh
	ld i,a
	im 1
	ei
	ret

; SETUP: экран в ноль, атрибуты = a, полоска T (строка 22, столбцы 0..17) - чёрное на белом
SETUP:	push af
	ld hl,4000h
	ld de,4001h
	ld bc,6143
	ld (hl),0
	ldir
	pop af
	ld hl,5800h
	ld de,5801h
	ld bc,767
	ld (hl),a
	ldir
	ld hl,5AC0h
	call _sa0
	ld hl,5820h
_sa0	ld b,18
_sa	ld (hl),38h
	inc hl
	djnz _sa
	ret

; DRAWBAR: полоска T = (TCUR), 16 бит младшим слева, во всех восьми линиях; столбец 16 - всегда чёрный.
; Рисуется дважды: в строке знакомест 22 и в строке 1 - снимок из «рваного» буфера (верх от одного кадра,
; низ от другого) хост узнаёт по несовпадению двух полосок.
DRAWBAR:
	ld hl,BAR
	call _bar
	ld hl,BART
_bar	ld de,(TCUR)
	ld b,16
_db	srl d
	rr e
	sbc a,a
	call _col
	inc l
	djnz _db
	ld a,0FFh
_col	push hl
	push bc
	ld b,8
_dl	ld (hl),a
	inc h
	djnz _dl
	pop bc
	pop hl
	ret

SWEEP:
BLOCK:	xor a
	ld (VALID),a
	ld hl,(TBEG)
	ld a,(TI)
	ld e,a
	ld d,0
	add hl,de
	ld (TCUR),hl
	call DRAWBAR
	ld a,KFR
	ld (FCNT),a
	ld hl,(TCUR)
	ld a,(MODE)
	or a
	jr nz,BBLOCK
	ld bc,-106
	add hl,bc
	ld (T1),hl
	call ALIGNINT
NEXT_S:			; 46 - дальше дословно stime
	im 1
	ld de,16384
	xor a
	ld (de),a
	ld bc,(T1)
	call DELAY
	ld a,0FFh
	ld (de),a		; цикл записи начинается на T
	ld hl,0F41Fh
	ld bc,(T1)
	and a
	sbc hl,bc
	ld b,h
	ld c,l
	call DELAY
	ld a,0FFh		; +7  метка «кадр измерительный»
	ld (VALID),a		; +13
	xor a
	in a,(0FEh)
	inc a
	and 1Fh
	ret nz
	ld hl,FCNT		; +10
	dec (hl)		; +11
	jr z,NEXTBLK		; +7
	im 2
	ld bc,NEXT_S
	push bc
	halt

BBLOCK:	ld bc,-(95+7)
	add hl,bc
	ld (T1),hl
	call ALIGNINT
NEXT_B:			; 46 - дальше дословно btime
	im 1
	ld bc,(T1)
	call DELAY
	ld c,0FEh
	ld e,07
	ld a,02
	out (0FEh),a		; цикл OUT начинается на T
	out (c),e
	ld hl,0F413h
	ld bc,(T1)
	and a
	sbc hl,bc
	ld b,h
	ld c,l
	call DELAY
	ld a,0FFh		; +7
	ld (VALID),a		; +13
	ld a,0
	in a,(0FEh)
	inc a
	and 1Fh
	ret nz
	ld hl,FCNT		; +10
	dec (hl)		; +11
	jr z,NEXTBLK		; +7
	im 2
	ld bc,NEXT_B
	push bc
	halt

NEXTBLK:
	ld a,(TN)
	ld b,a
	ld a,(TI)
	inc a
	cp b
	jr c,_nb
	xor a
_nb	ld (TI),a
	jp BLOCK

	include delay.asm
	include instint.asm
	include frametime.asm
	include alignint.asm

T1	dw 0
TCUR	dw 0
TBEG	dw 0
TN	db 0
TI	db 0
MODE	db 0
FCNT	db 0
