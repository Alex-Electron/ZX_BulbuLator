; Копия замера кадра (FRAME_TIME Бобровского) для исполнения по #6000: +0 JP FRAME_TIME, +3 адрес FRAMET.
; По ней penttest проверяет, нет ли тактов ожидания при исполнении из этого места памяти.
	org 06000h
	jp FRAME_TIME
	defw FRAMET
include frametime.asm
include delay.asm
