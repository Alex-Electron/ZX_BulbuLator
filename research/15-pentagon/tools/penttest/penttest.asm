; penttest.asm - PENTAGON TIMING TEST для BulbuLator (и любого Пентагона 128/1024).
; Самопроверяющаяся программа по образцу Timing Tests 48K: каждый тест печатает измеренное значение
; и PASS/FAIL, в конце итог. Эталонные значения и их источники - README.md рядом.
;
; Точность до такта даёт код Яна Бобровского (zxtests3, лицензия GPL): DELAY, ALIGNINT, FRAME_TIME,
; INT_TIME и EI_PREFIX из minfo. Они взяты без изменений, кроме адреса таблицы IM2 (instint.asm).
; Сборка: pasmo --alocal (метки с подчёркиванием локальны), см. build.sh.
;
; Карта памяти: код с #8000 (банк 2, всегда на месте), таблица IM2 #BD00..#BE00, обработчик #BEBE,
; таблица проверки вектора #BB00..#BC00, ловушка #B9B9. Копии замера кадра - по #6000 (банк 5) и #C000
; (подключаемые банки). Бейсик-загрузчик делает CLEAR 24575, так что #6000..#FFFF свободны.

	org 32768

FT6	equ 6000h		; копия замера кадра в банке 5
FTC	equ 0C000h		; копия замера кадра в подключаемом банке
VTAB	equ 0BBh		; I для проверки вектора
TRAP	equ 0B9B9h

entry:
	ld (savesp),sp
	ld a,2
	call SYS_CHAN
	xor a
	ld (npass),a
	ld (nfail),a
	ld (nbanks),a
	ld hl,t_title
	call PRINT
	call INSTINT

; ---- 1. длина кадра ----
	ld hl,t_frame
	call PRINT
	call FRAME_TIME
	ld hl,(FRAMET)
	call report_frame

; ---- 2. стабильность: восемь замеров подряд одинаковы ----
	ld hl,t_stab
	call PRINT
	ld hl,(FRAMET)
	ld (ftref),hl
	xor a
	ld (bad),a
	ld b,8
_st	push bc
	call FRAME_TIME
	ld hl,(FRAMET)
	ld de,(ftref)
	and a
	sbc hl,de
	jr z,_st1
	ld a,1
	ld (bad),a
_st1	pop bc
	djnz _st
	ld hl,t_8same
	call PRINT
	ld a,(bad)
	call verdict_a

; ---- 3. EI как префикс ----
	ld hl,t_eipx
	call PRINT
	call EI_PREFIX
	cp 1
	ld hl,t_no
	jr c,_ei_no
	ld hl,t_yes
	jr z,_ei_yes
	ld hl,t_fail_s
_ei_no	call PRINT
	ld a,1
	call verdict_a
	jr _ei_done
_ei_yes	call PRINT
	xor a
	call verdict_a
_ei_done

; ---- 4. длительность INT: опция машины (36 умолчание / 32 / 44) ----
	ld hl,t_itime
	call PRINT
	call INT_TIME
	jr c,_it_fail
	ex de,hl
	push hl
	and a
	call PRDEC
	ld hl,t_itopt
	call PRINT
	pop hl
	ld a,l
	ld b,a
	ld a,h
	or a
	jr nz,_it_bad
	ld a,b
	cp 32
	jr z,_it_ok
	cp 36
	jr z,_it_ok
	cp 44
	jr z,_it_ok
_it_bad	ld a,1
	call verdict_a
	jr _it_done
_it_ok	xor a
	call verdict_a
	jr _it_done
_it_fail ld hl,t_fail_s
	call PRINT
	ld a,1
	call verdict_a
_it_done

; ---- 5. вектор IM2: в цикле подтверждения на шине #FF ----
	ld hl,t_vect
	call PRINT
	call VECTOR_TEST
	call verdict_a

; ---- 6. порт #FF: опция машины. #FF - плавающей шины нет; ATTRIBUTE - на бумаге отдаётся атрибут ----
	ld hl,t_ff
	call PRINT
	call PORTFF_TEST		; hl = чтений не-#FF, de = из них НЕ атрибут экрана
	ld a,d
	or e
	jr nz,_ff_bad
	ld a,h
	or l
	jr nz,_ff_attr
	ld hl,t_allff
	call PRINT
	xor a
	call verdict_a
	jr _ff_done
_ff_attr push hl
	ld hl,t_attr
	call PRINT
	pop hl
	and a
	call PRDEC
	ld a,' '
	rst 16
	xor a
	call verdict_a
	jr _ff_done
_ff_bad	ex de,hl
	and a
	call PRDEC
	ld hl,t_notff
	call PRINT
	ld a,1
	call verdict_a
_ff_done

; ---- 7. страничность: сколько банков различимо ----
	ld hl,t_ram
	call PRINT
	call BANKS_TEST			; (nbanks) = 8/16/32/64, a = 0 если размер - степень двойки
	push af
	ld a,(nbanks)
	ld l,a
	ld h,0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl			; *16 КБ
	and a
	call PRDEC
	ld hl,t_kb
	call PRINT
	pop af
	call verdict_a

; ---- 8. контеншена нет: замер кадра из банка 5 (#6000) и из каждого банка по #C000 ----
	ld hl,t_cont
	call PRINT
	ld hl,ft6_img
	ld de,FT6
	ld bc,ft6_len
	ldir
	call FT6
	ld hl,(FT6+3)
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call report_frame

	ld hl,t_contc
	call PRINT
	xor a
	ld (bad),a
	ld (curbank),a
_cb	ld a,(curbank)
	cp 2
	jr z,_cb_next			; банк 2 - это наш код по #8000
	cp 5
	jr z,_cb_next			; банк 5 - экран и копия #6000
	call PAGE_A
	ld hl,ftc_img
	ld de,FTC
	ld bc,ftc_len
	ldir
	call FTC
	ld hl,(FTC+3)
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,10h
	call OUT7FFD
	ld hl,38912			; 71680 - 32768
	and a
	sbc hl,de
	jr z,_cb_next
	ld a,1				; провал: напечатать номер банка и значение
	ld (bad),a
	push de
	ld a,(curbank)
	ld l,a
	ld h,0
	and a
	call PRDEC
	ld a,'='
	rst 16
	pop hl
	ld de,32768
	add hl,de
	call PRDEC
	ld a,' '
	rst 16
_cb_next
	ld a,(nbanks)
	ld b,a
	ld a,(curbank)
	inc a
	ld (curbank),a
	cp b
	jr c,_cb
	ld a,(bad)
	or a
	jr nz,_cb_bad
	ld hl,t_allok
	call PRINT
_cb_bad	ld a,(bad)
	call verdict_a

; ---- итог ----
	ld hl,t_sum
	call PRINT
	ld a,(npass)
	ld l,a
	ld h,0
	and a
	call PRDEC
	ld hl,t_passed
	call PRINT
	ld a,(nfail)
	ld l,a
	ld h,0
	and a
	call PRDEC
	ld hl,t_failed
	call PRINT
	ld a,10h
	call OUT7FFD
	ld a,3Fh
	ld i,a
	im 1
	ei
	ld sp,(savesp)
	ret

;-------------------------------------------------------------------------------------------------
; report_frame: hl = FRAMET (длина кадра - 32768). Печатает длину, сверяет с 71680.
report_frame:
	ld de,32768
	add hl,de			; перенос = бит 16
	push af
	push hl
	call PRDEC			; печатает с учётом переноса (6 знаков)
	ld a,' '
	rst 16
	pop hl
	pop af
	jr nc,_rf_bad			; 71680 > 65535 - перенос обязан быть
	ld de,71680-65536
	and a
	sbc hl,de
	jr nz,_rf_bad
	xor a
	jr verdict_a
_rf_bad	ld a,1
; verdict_a: a = 0 -> зелёный PASS, иначе красный FAIL; конец строки
verdict_a:
	or a
	jr nz,_v_fail
	ld hl,npass
	inc (hl)
	ld c,4
	ld hl,t_pass
	jr _v_pr
_v_fail	ld hl,nfail
	inc (hl)
	ld c,2
	ld hl,t_failw
_v_pr	ld a,16
	rst 16
	ld a,c
	rst 16
	call PRINT
	call SYS_TEMPS
	ld a,13
	rst 16
	ret

; OUT7FFD: a -> #7FFD
OUT7FFD:
	ld bc,7FFDh
	out (c),a
	ret

; PAGE_A: подключить банк a (0..63) по #C000, ПЗУ 48 BASIC.
; Пентагон 1024: банк[5:0] = {7FFD[5], 7FFD[7], 7FFD[6], 7FFD[2:0]}
PAGE_A:
	ld b,a
	and 7
	or 10h
	ld c,a
	ld a,b
	and 8
	jr z,_p1
	ld a,c
	or 40h
	ld c,a
_p1	ld a,b
	and 16
	jr z,_p2
	ld a,c
	or 80h
	ld c,a
_p2	ld a,b
	and 32
	jr z,_p3
	ld a,c
	or 20h
	ld c,a
_p3	ld a,c
	jr OUT7FFD

; BANKS_TEST: сколько банков по #C000 различимо. Подпись {n^#A5, ~n} кладётся по #F000 банка n (смещение
; #3000: у банка 2 это #B000, у банка 5 - #7000, оба свободны, код и экран не задеваются). Пишем по УБЫВАНИЮ
; 63..0: при меньшем объёме ОЗУ банки выше зеркалят нижние, и настоящий банк записывается последним.
; Объём N = первый банк, прочитавший не свою подпись. Затем каждый банк k >= N обязан честно зеркалить
; банк k & (N-1), а N - быть 8/16/32/64. a = 0 если всё так.
BANKS_TEST:
	di
	ld e,63
_bw	push de
	ld a,e
	call PAGE_A
	pop de
	ld a,e
	xor 0A5h
	ld (0F000h),a
	ld a,e
	cpl
	ld (0F001h),a
	ld a,e
	or a
	jr z,_bw_done
	dec e
	jr _bw
_bw_done
	ld e,0
_bf	ld a,e
	cp 64
	jr nc,_bf_end
	ld d,e				; какой банк подключать
	call _chk			; z = банк d читает подпись e
	jr nz,_bf_end
	inc e
	jr _bf
_bf_end	ld a,e
	ld (nbanks),a
	cp 8
	jr c,_bt_bad			; меньше 128К
	ld b,a
	dec a
	and b
	jr nz,_bt_bad			; не степень двойки
	ld a,(nbanks)
	dec a
	ld c,a				; маска N-1
	ld a,(nbanks)
	ld e,a
_ba	ld a,e
	cp 64
	jr nc,_bt_ok
	ld d,e				; подключаем банк k ...
	ld a,e
	and c
	push de
	ld e,a				; ... и ждём в нём подпись банка k & (N-1)
	call _chk
	pop de
	jr nz,_bt_bad
	inc e
	jr _ba
_bt_ok	ld a,10h
	call OUT7FFD
	ei
	xor a
	ret
_bt_bad	ld a,10h
	call OUT7FFD
	ei
	ld a,1
	ret
; _chk: подключить банк d, сравнить #F000/#F001 с подписью банка e. z = совпало. Портит a, b, hl.
_chk	push bc
	push de
	ld a,d
	call PAGE_A
	pop de
	pop bc
	ld a,e
	xor 0A5h
	ld hl,0F000h
	cp (hl)
	ret nz
	ld a,e
	cpl
	inc hl
	cp (hl)
	ret

; VECTOR_TEST: таблица #BB00..#BC00 заполнена #B9 (любой вектор -> ловушка #B9B9), и только слово по
; смещению #FF указывает на правильный обработчик. a = 0 при векторе #FF.
VECTOR_TEST:
	di
	ld hl,trap_code
	ld de,TRAP
	ld bc,trap_len
	ldir
	ld hl,VTAB*256
	ld de,VTAB*256+1
	ld (hl),0B9h
	ld bc,256
	ldir
	ld hl,vec_ok
	ld (VTAB*256+0FFh),hl
	xor a
	ld (vres),a
	ld a,VTAB
	ld i,a
	im 2
	ei
	halt
	di
	ld a,0BDh			; вернуть основную таблицу
	ld i,a
	im 1
	ei
	ld a,(vres)
	cp 2
	ld a,0
	ret z
	inc a
	ret
vec_ok	push af
	ld a,2
	ld (vres),a
	pop af
	ei
	reti
trap_code
	push af
	ld a,1
	ld (vres),a
	pop af
	ei
	reti
trap_len equ $-trap_code

; PORTFF_TEST: 8000 чтений IN A,(#FF) подряд (~6 кадров, все фазы растра). Перед замером в таблицу
; PFTAB (#BA00, 256 Б) отмечаются все значения, которые есть в атрибутах экрана #5800..#5AFF: в режиме
; ATTRIBUTE порт обязан отдавать только их (или #FF вне бумаги). hl = чтений не-#FF, de = из них чужих.
PFTAB	equ 0BA00h
PORTFF_TEST:
	di
	ld hl,PFTAB
	ld b,0
_pz	ld (hl),0
	inc l
	djnz _pz
	ld hl,5800h
	ld bc,768
_pm	ld e,(hl)
	ld d,PFTAB/256
	ld a,1
	ld (de),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,_pm
	ld ix,0
	ld hl,0
	ld (pfbad),hl
	ld bc,8000
_pf	ld a,0FFh
	in a,(0FFh)
	cp 0FFh
	jr z,_pf1
	inc ix
	ld e,a
	ld d,PFTAB/256
	ld a,(de)
	or a
	jr nz,_pf1
	ld hl,(pfbad)
	inc hl
	ld (pfbad),hl
_pf1	dec bc
	ld a,b
	or c
	jr nz,_pf
	ei
	push ix
	pop hl
	ld de,(pfbad)
	ret

;-------------------------------------------------------------------------------------------------
; EI_PREFIX и INT_TIME - дословно из minfo.asm (Jan Bobrowski, GPL)
EI_PREFIX:
	ld hl,_int
	push hl
	call ALIGNINT
	di			; 4
	ld bc,32768-46-42+1	; 14
	call DELAY		; n+14
	ld bc,(FRAMET)		; n+34
	call DELAY		; n+ft+34
	xor a			; n+ft+38
	ei			; n+ft+42
	inc a
	di
	inc a
	ret
_int	im 1
	ei
	ret

INT_TIME:
_start equ 48
_instw equ 12
	ld hl,_int
	push hl
	call ALIGNINT
	ld bc,32768-46-20-24+_start-_instw*4
	ld de,_start
_loop
	call DELAY
	ld bc,(FRAMET)
	call DELAY
	nop
	rept _instw-1
	defb 0xDD
	endm
	nop
	ld bc, 32768 - _instw*4 - 60 - 1
	dec de
	ld a,d
	or e
	jr nz,_loop
	ret
_int
	im 1
	ld a,e
	xor _start
	cp 1
	ret

;-------------------------------------------------------------------------------------------------
t_title	defb 16,5,'PENTAGON TIMING TEST v2',13,16,7,'BulbuLator; core: J.Bobrowski',13,13,0
t_frame	defb 'Frame time: ',0
t_stab	defb 'Stable: ',0
t_8same	defb '8 frames same ',0
t_eipx	defb 'EI is prefix: ',0
t_itime	defb 'INT time: ',0
t_itopt	defb ' (32/36/44) ',0
t_vect	defb 'IM2 vector #FF: ',0
t_ff	defb 'Port #FF: ',0
t_allff	defb 'always #FF ',0
t_notff	defb ' not attr ',0
t_attr	defb 'attributes ',0
t_ram	defb 'RAM banks: ',0
t_kb	defb 'K ',0
t_cont	defb 'No contention @6000: ',0
t_contc	defb 'Banks @C000: ',0
t_allok	defb 'all 71680 ',0
t_yes	defb 'yes ',0
t_no	defb 'no ',0
t_fail_s defb 'test failed ',0
t_pass	defb 'PASS',0
t_failw	defb 'FAIL',0
t_sum	defb 13,'Result: ',0
t_passed defb ' passed, ',0
t_failed defb ' failed',13,0

savesp	defw 0
ftref	defw 0
pfbad	defw 0
bad	defb 0
npass	defb 0
nfail	defb 0
nbanks	defb 0
curbank	defb 0
vres	defb 0

ft6_img	incbin "ft6000.bin"
ft6_len	equ $-ft6_img
ftc_img	incbin "ftc000.bin"
ftc_len	equ $-ftc_img

include print.asm
include delay.asm
include instint.asm
include frametime.asm
include alignint.asm

SYS_TEMPS equ 0x0D4D
SYS_CHAN equ 0x1601

end entry
