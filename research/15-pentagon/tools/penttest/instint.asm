
INSTINT:

_ireg  equ 0xBD   ; PENTTEST: таблица в банке 2 - по #C000 подключаются другие банки
_iproc equ 0xBE   ; обработчик по #BEBE

	ld de, _iproc<<8|_iproc
	ld hl, _intproc
	ld bc, _intpend-_intproc
	ldir
	inc b
	ld hl, _ireg<<8|0
	ld de, _ireg<<8|1
	ld (hl), _iproc
	ld a,h
	ldir
	ld i,a
	ret

_intproc		; 20T+
	inc sp		; 26T+
	inc sp		; 32T+
	ei		; 36T+
	ret		; 46T+
_intpend
